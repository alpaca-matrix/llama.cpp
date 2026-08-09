# One-shot health panel for the llama-server box.
#
# Answers "is anything wrong that needs me?" in a few seconds, over two SSH
# round trips (the LXC, then the Proxmox host). Everything it reports is a
# fact read off the box - there are no synthetic requests, so it is safe to
# run while the server is serving, and it never restarts or changes anything.
#
# The thresholds encode failures this box has actually had:
#   - uninterruptible-D children pinning GTT/VRAM (twice cost a power cycle)
#   - silent CPU fallback after RADV cannot open the render node (25 -> 4 t/s)
#   - amdgpu compute-ring timeouts / ErrorDeviceLost at context depth
#   - a model still loading when a request arrives (router force-kills it)
#
# usage: .\status.ps1 [-Deep] [-Hours 24] [-Watch] [-Interval 5]
#   -Deep      also walks /root/models for its on-disk size (several seconds)
#   -Hours     log-scan window, default 24
#   -Watch     redraw the panel every -Interval seconds until Ctrl+C
#   -Interval  seconds between refreshes in watch mode, default 5
[CmdletBinding()]
param(
    [switch]$Deep,
    [int]$Hours = 24,
    [switch]$Watch,
    [int]$Interval = 5
)

$ErrorActionPreference = 'Stop'

$LxcHost = 'root@192.168.254.250'
$PveHost = 'root@192.168.254.222'
$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519_llamalxc"
$RepoDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ---------------------------------------------------------------- ssh helper

# Payloads go over the wire base64-encoded. Passing a multi-line script as an
# ssh argument means it survives two levels of shell quoting plus PowerShell's
# CRLF line endings; base64 makes all of that a non-issue.
function Invoke-Remote {
    param([string]$Target, [string]$Script, [int]$TimeoutSec = 25)

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $out = ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new `
               -i $KeyPath $Target "echo $b64 | base64 -d | bash"
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

function ConvertFrom-KeyValue {
    param([string[]]$Lines)
    $h = @{}
    foreach ($line in $Lines) {
        if ($line -match '^([a-z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

# ------------------------------------------------------------- remote probes

$lxcScript = @"
set -u
P() { printf '%s=%s\n' "`$1" "`$2"; }
HOURS=$Hours
DEEP=$(if ($Deep) { 1 } else { 0 })

P svc "`$(systemctl is-active llama-server 2>/dev/null)"
ts=`$(systemctl show llama-server -p ActiveEnterTimestamp --value 2>/dev/null)
if [ -n "`$ts" ]; then P svc_uptime "`$(( `$(date +%s) - `$(date -d "`$ts" +%s) ))"; else P svc_uptime -1; fi

d=/sys/class/drm/card0/device
P gtt_used   "`$(cat `$d/mem_info_gtt_used   2>/dev/null || echo 0)"
P gtt_total  "`$(cat `$d/mem_info_gtt_total  2>/dev/null || echo 0)"
P vram_used  "`$(cat `$d/mem_info_vram_used  2>/dev/null || echo 0)"
P vram_total "`$(cat `$d/mem_info_vram_total 2>/dev/null || echo 0)"
P mem_avail_kb "`$(awk '/MemAvailable/{print `$2}' /proc/meminfo)"

# Uninterruptible sleep is the signature of a teardown deadlock: the child
# cannot be reaped by SIGKILL and holds its GPU allocations until a power
# cycle. A single sample is not evidence - ordinary disk I/O shows up as D for
# a few milliseconds, and a model unload does it constantly. Only a PID that is
# still in D a second later is worth reporting.
snap() { ps -eo stat=,pid=,rss=,comm= | awk '`$1 ~ /^D/ {print `$2"|"`$3"|"`$4}'; }
s1=`$(snap); sleep 2; s2=`$(snap)
stuck=''
for e in `$s1; do
  pid=`${e%%|*}
  case "`$s2" in *"`$pid|"*) stuck="`$stuck `$(echo "`$e" | awk -F'|' '{printf "%s(%s, %d MB)", `$3, `$1, `$2/1024}')" ;; esac
done
P dstate "`$stuck"

models=`$(curl -s -m 8 http://127.0.0.1:8080/v1/models || true)
P health "`$(curl -s -m 6 http://127.0.0.1:8080/health || true)"
P build "`$(curl -s -m 6 http://127.0.0.1:8080/props 2>/dev/null | sed -n 's/.*"build_info":"\([^"]*\)".*/\1/p')"

# MODELS_JSON goes through the environment, not stdin: python3 reading a
# heredoc would shadow a piped stdin and silently parse the wrong thing.
if [ -n "`$models" ]; then
  MODELS_JSON="`$models" python3 <<'PYEOF'
import json, os
try:
    d = json.loads(os.environ["MODELS_JSON"])
except Exception:
    raise SystemExit
rows = d.get("data", [])
busy = [m["id"] + ":" + m["status"]["value"]
        for m in rows if m["status"]["value"] != "unloaded"]
print("aliases=" + ",".join(m["id"] for m in rows))
print("resident=" + ",".join(busy))
print("first_loaded=" + next((m["id"] for m in rows
                              if m["status"]["value"] == "loaded"), ""))
PYEOF
fi

# slot occupancy is only meaningful for a model that is actually resident
first=`$(MODELS_JSON="`$models" python3 -c 'import json,os
try: d=json.loads(os.environ["MODELS_JSON"])
except Exception: raise SystemExit
print(next((m["id"] for m in d.get("data",[]) if m["status"]["value"]=="loaded"),""))' 2>/dev/null)
if [ -n "`$first" ]; then
  s=`$(curl -s -m 6 "http://127.0.0.1:8080/slots?model=`$first" || true)
  P slots_total "`$(printf '%s' "`$s" | grep -o '"id":' | wc -l)"
  P slots_busy  "`$(printf '%s' "`$s" | grep -o '"is_processing":true' | wc -l)"
  P slots_ctx   "`$(printf '%s' "`$s" | sed -n 's/.*"n_ctx":\([0-9]*\).*/\1/p')"

  # progress of whichever slot is actually mid-request right now - /slots is a
  # live snapshot from the task queue, so this is real, not inferred from logs
  SLOTS_JSON="`$s" python3 <<'PYEOF'
import json, os
try:
    slots = json.loads(os.environ["SLOTS_JSON"])
except Exception:
    raise SystemExit
busy = next((sl for sl in slots if sl.get("is_processing")), None)
if busy:
    # next_token comes back as a one-element array, not an object
    nt = (busy.get("next_token") or [{}])[0]
    n_decoded = nt.get("n_decoded", 0)
    phase = "generating" if n_decoded > 0 else "prompt_eval"
    print("prog_phase=" + phase)
    print("prog_id_slot=" + str(busy.get("id", "")))
    print("prog_id_task=" + str(busy.get("id_task", "")))
    print("prog_n_decoded=" + str(n_decoded))
    print("prog_n_remain=" + str(nt.get("n_remain", -1)))
    print("prog_n_prompt_tokens=" + str(busy.get("n_prompt_tokens", 0)))
    print("prog_n_prompt_tokens_processed=" + str(busy.get("n_prompt_tokens_processed", 0)))
    print("prog_n_prompt_tokens_cache=" + str(busy.get("n_prompt_tokens_cache", 0)))
PYEOF
fi

# One pass over the journal for every log-derived fact. Timestamps come back as
# epoch seconds so a DeviceLost can be correlated against the restart that
# preceded it - the known benign case is the first request after a restart
# losing the device to the teardown/load race, and that must not read the same
# as a depth-triggered device loss under real traffic.
LOGWIN=`$HOURS python3 <<'PYEOF'
import os, re, subprocess
from datetime import datetime

hours = int(os.environ["LOGWIN"])
try:
    out = subprocess.run(
        ["journalctl", "-u", "llama-server", "--since", "-%dh" % hours,
         "--no-pager", "-o", "short-unix"],
        capture_output=True, text=True, timeout=60).stdout
except Exception:
    raise SystemExit

starts, lost, ring, oom = [], [], [], []
tg = pp = last_ts = None
for line in out.splitlines():
    m = re.match(r"^(\d+)", line)
    if not m:
        continue
    t, low = int(m.group(1)), line.lower()
    if "started llama-server" in low:
        starts.append(t)
    if "devicelost" in low:
        lost.append(t)
    if re.search(r"ring \S+ timeout|gpu reset", low):
        ring.append(t)
    if "out of memory" in low or "failed to allocate" in low or "enomem" in low:
        oom.append(t)
    if "print_timing" in low:
        last_ts = t
        r = re.search(r"([0-9.]+) tokens per second", line)
        if r:
            if "prompt eval time" in low:
                pp = r.group(1)
            else:
                tg = r.group(1)

# within 3 min of a restart = the load-race quirk, not a depth incident
boot = sum(1 for t in lost if any(0 <= t - s <= 180 for s in starts))
print("n_starts=%d" % len(starts))
print("n_devicelost=%d" % len(lost))
print("n_devicelost_boot=%d" % boot)
print("n_ringtimeout=%d" % len(ring))
print("n_oom=%d" % len(oom))
if tg: print("tg=" + tg)
if pp: print("pp=" + pp)
if last_ts:
    print("last_req=" + datetime.fromtimestamp(last_ts).strftime("%b %d %H:%M"))
PYEOF

set -- `$(df -B1 / | tail -1)
P disk_avail "`$4"
pct=`$5; P disk_pct "`${pct%\%}"
if [ "`$DEEP" = "1" ]; then P models_bytes "`$(du -sb /root/models 2>/dev/null | cut -f1)"; fi

P mesa "`$(dpkg-query -W -f='`${Version}' mesa-vulkan-drivers 2>/dev/null)"
P git_head "`$(git -C /root/llama.cpp rev-parse --short=7 HEAD 2>/dev/null)"
P git_dirty "`$(git -C /root/llama.cpp status --porcelain 2>/dev/null | wc -l)"
P ini_box "`$(md5sum /etc/llama/router.ini 2>/dev/null | cut -d' ' -f1)"
P ini_repo "`$(md5sum /root/llama.cpp/deploy/radeon-780m/router.ini 2>/dev/null | cut -d' ' -f1)"
"@

$pveScript = @"
set -u
P() { printf '%s=%s\n' "`$1" "`$2"; }
P uptime "`$(cut -d. -f1 /proc/uptime)"
dm=`$(dmesg -T 2>/dev/null || true)
P n_amdgpu "`$(printf '%s' "`$dm" | grep -ciE 'amdgpu.*(timeout|reset|error|failed)' || true)"
P last_amdgpu "`$(printf '%s' "`$dm" | grep -iE 'amdgpu.*(timeout|reset|error|failed)' | tail -1 | cut -c1-110)"
P load "`$(cut -d' ' -f1-3 /proc/loadavg)"
"@

# Gathers both SSH probes with no console output of its own, so a caller can
# hold the previous frame on screen for the whole round trip and only touch
# the display once a complete new set of metrics exists. Returns $null on
# an unreachable LXC, otherwise @{ L = <hashtable>; H = <hashtable or $null> }.
function Get-StatusData {
    $lxcRaw = Invoke-Remote -Target $LxcHost -Script $lxcScript
    $pveRaw = Invoke-Remote -Target $PveHost -Script $pveScript

    if ($null -eq $lxcRaw) { return $null }

    return @{
        L = ConvertFrom-KeyValue $lxcRaw
        H = if ($pveRaw) { ConvertFrom-KeyValue $pveRaw } else { $null }
    }
}

# Renders one already-gathered snapshot. Returns 0/1/2 (healthy/warnings/failures)
# so watch mode can flag the same thing a one-shot run would exit with.
function Show-StatusPanel {
    param($L, $H)

$script:rows = @()
$script:actions = @()

# ------------------------------------------------------------------ renderer

function Add-Row {
    param([string]$Name, [string]$State, [string]$Text)
    $script:rows += [pscustomobject]@{ Name = $Name; State = $State; Text = $Text }
}
function Add-Action { param([string]$Text) $script:actions += $Text }

function Get-Num {
    param([string]$Value, [double]$Default = 0)
    $n = 0.0
    if ([double]::TryParse($Value, [ref]$n)) { return $n }
    return $Default
}
function Format-GiB { param([double]$Bytes) return ('{0:N1}' -f ($Bytes / 1GB)) }
function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return 'unknown' }
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalDays -ge 1) { return ('{0}d {1}h' -f [int]$t.TotalDays, $t.Hours) }
    if ($t.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$t.TotalHours, $t.Minutes) }
    return ('{0}m' -f [int]$t.TotalMinutes)
}

# --- service ---------------------------------------------------------------
$svc = $L['svc']
$svcUp = Format-Duration (Get-Num $L['svc_uptime'] -1)
if ($svc -ne 'active') {
    Add-Row 'SERVICE' 'FAIL' "systemd says '$svc'"
    Add-Action "llama-server is not active. Check: journalctl -u llama-server -n 80"
}
elseif ($L['health'] -notmatch '"status":"ok"') {
    Add-Row 'SERVICE' 'WARN' "active $svcUp, but /health did not answer ok"
    Add-Action 'Service is up but /health is not ok - the router may be wedged.'
}
else {
    Add-Row 'SERVICE' 'OK' "active, up $svcUp  |  build $($L['build'])"
}

# Restarts are normal here - deploys are deliberate and often clustered into one
# session. What is not normal is many starts while the current uptime is short,
# which is the shape of a service that keeps dying and being revived.
$starts = [int](Get-Num $L['n_starts'])
$upSec = Get-Num $L['svc_uptime'] -1
if ($starts -gt 3 -and $upSec -ge 0 -and $upSec -lt 3600) {
    Add-Row 'RESTARTS' 'WARN' "$starts starts in ${Hours}h, current uptime only $(Format-Duration $upSec)"
    Add-Action "llama-server has started $starts times in ${Hours}h and has only been up $(Format-Duration $upSec) - that is a restart loop, not deploy activity. Check: journalctl -u llama-server -n 120"
}
elseif ($starts -gt 1) {
    Add-Row 'RESTARTS' 'OK' "$starts starts in ${Hours}h, stable for $(Format-Duration $upSec)"
}

# --- resident model --------------------------------------------------------
$resident = $L['resident']
$aliasCount = if ($L['aliases']) { ($L['aliases'] -split ',').Count } else { 0 }
$loading = $resident -and ($resident -notmatch ':loaded')

if (-not $resident) {
    Add-Row 'MODEL' 'OK' "nothing resident  |  $aliasCount aliases configured (models-max 1)"
}
elseif ($loading) {
    Add-Row 'MODEL' 'WARN' "$(($resident -split ':')[0]) is loading - not ready to serve"
    Add-Action "A model is mid-load. Do NOT send a request until the journal shows 'model loaded' + 'listening' - the router will force-kill a loading child and deadlock the GPU."
}
else {
    $name = ($resident -split ':')[0]
    $busy = [int](Get-Num $L['slots_busy'])
    $tot = [int](Get-Num $L['slots_total'])
    $ctx = [int](Get-Num $L['slots_ctx'])
    # /slots races a load or unload in progress and comes back empty; reporting
    # "0/0 busy" would read as an idle server rather than as no answer
    if ($tot -gt 0) {
        $ctxTxt = if ($ctx -gt 0) { "  |  ctx $('{0:N0}' -f $ctx)" } else { '' }
        Add-Row 'MODEL' 'OK' "$name resident  |  $busy/$tot slots busy$ctxTxt"
    }
    else {
        Add-Row 'MODEL' 'OK' "$name resident  |  slot state unavailable (load in flight?)"
    }
}

# --- active request progress ------------------------------------------------
# A live read of /slots, not an inference from logs - if a prompt is really
# being worked on right now, these counters differ between two runs of this
# script a few seconds apart.
if ($L['prog_phase']) {
    $slotId  = $L['prog_id_slot']
    $taskId  = $L['prog_id_task']
    if ($L['prog_phase'] -eq 'prompt_eval') {
        $procNow  = [int](Get-Num $L['prog_n_prompt_tokens_processed'])
        $cacheHit = [int](Get-Num $L['prog_n_prompt_tokens_cache'])
        $kvSoFar  = [int](Get-Num $L['prog_n_prompt_tokens'])
        Add-Row 'PROGRESS' 'OK' "slot $slotId / task $taskId  |  prompt eval  |  $procNow new tokens processed  |  $cacheHit reused from cache  |  $('{0:N0}' -f $kvSoFar) tokens in KV so far"
    }
    else {
        $decoded = [int](Get-Num $L['prog_n_decoded'])
        $remain  = [int](Get-Num $L['prog_n_remain'] -1)
        $remainTxt = if ($remain -ge 0) { "$remain left of budget" } else { 'no n_predict limit' }
        Add-Row 'PROGRESS' 'OK' "slot $slotId / task $taskId  |  generating  |  $('{0:N0}' -f $decoded) tokens decoded  |  $remainTxt"
    }
}

# --- GPU memory ------------------------------------------------------------
$gttU = Get-Num $L['gtt_used']; $gttT = Get-Num $L['gtt_total']
$vrU = Get-Num $L['vram_used']; $vrT = Get-Num $L['vram_total']
$poolU = $gttU + $vrU; $poolT = $gttT + $vrT
$freeGiB = ($poolT - $poolU) / 1GB
$memTxt = "GTT $(Format-GiB $gttU)/$(Format-GiB $gttT) GiB  |  VRAM $(Format-GiB $vrU)/$(Format-GiB $vrT) GiB  |  $('{0:N1}' -f $freeGiB) GiB free"

if ($poolT -le 0) {
    Add-Row 'GPU MEM' 'WARN' 'amdgpu sysfs counters unreadable'
}
elseif ($freeGiB -lt 4) {
    Add-Row 'GPU MEM' 'FAIL' $memTxt
    Add-Action "Only $('{0:N1}' -f $freeGiB) GiB left in the 76 GiB pool. Do not load a second model; an allocation failure here is what strands a child in D-state."
}
elseif ($freeGiB -lt 10 -and $resident) {
    Add-Row 'GPU MEM' 'WARN' $memTxt
}
else {
    Add-Row 'GPU MEM' 'OK' $memTxt
}

# A model that is resident but holding almost no VRAM means RADV never got the
# render node and llama.cpp fell back to CPU - the failure that reads as a 6x
# slowdown and nothing else. Cross-checked against observed tg below.
if ($resident -and -not $loading -and $vrT -gt 0 -and ($vrU / 1GB) -lt 2) {
    Add-Row 'BACKEND' 'FAIL' "model resident but only $(Format-GiB $vrU) GiB VRAM in use"
    Add-Action 'Looks like silent CPU fallback (RADV could not open /dev/dri/renderD128). Confirm with llama-bench - the backend column must say Vulkan, not CPU.'
}

# --- stranded processes ----------------------------------------------------
if ($L['dstate'] -and $L['dstate'].Trim()) {
    # Paging a 20-60 GiB GGUF in parks the child in D for whole seconds at a
    # time, so D is only evidence of a strand when no load is in flight.
    if ($loading) {
        Add-Row 'PROCS' 'OK' "D-state present but a load is in flight (expected page-in): $($L['dstate'].Trim())"
    }
    else {
        Add-Row 'PROCS' 'FAIL' "uninterruptible-D: $($L['dstate'].Trim())"
        Add-Action 'A process is stuck in uninterruptible sleep with no load in flight. If it is a llama-server child it is holding GTT/VRAM that SIGKILL cannot reclaim - a hard power cycle of pve2 is the only known fix. Re-run this script once to confirm before acting.'
    }
}
else {
    Add-Row 'PROCS' 'OK' 'no uninterruptible-D processes'
}

# --- host ------------------------------------------------------------------
if ($null -eq $H) {
    Add-Row 'HOST' 'WARN' 'pve2 (192.168.254.222) did not answer'
}
else {
    $amd = [int](Get-Num $H['n_amdgpu'])
    $hostUp = Format-Duration (Get-Num $H['uptime'])
    if ($amd -gt 0) {
        Add-Row 'HOST' 'WARN' "pve2 up $hostUp  |  $amd amdgpu messages in dmesg  |  load $($H['load'])"
        Add-Action "pve2 dmesg has $amd amdgpu error/timeout lines. Last: $($H['last_amdgpu'])"
    }
    else {
        Add-Row 'HOST' 'OK' "pve2 up $hostUp  |  dmesg clean  |  load $($H['load'])"
    }
}

# --- log signatures --------------------------------------------------------
$dl = [int](Get-Num $L['n_devicelost'])
$dlBoot = [int](Get-Num $L['n_devicelost_boot'])
$dlReal = $dl - $dlBoot
$rt = [int](Get-Num $L['n_ringtimeout'])
$oom = [int](Get-Num $L['n_oom'])

$logTxt = "${Hours}h: $dl DeviceLost"
if ($dlBoot -gt 0) { $logTxt += " ($dlBoot on the known restart race)" }
$logTxt += "  |  $rt ring-timeout/reset  |  $oom alloc-failure"

if (($dlReal + $rt + $oom) -gt 0) {
    Add-Row 'LOGS' 'WARN' $logTxt
    if ($rt -gt 0 -or $dlReal -gt 0) {
        Add-Action "Device loss under traffic is back ($dlReal DeviceLost away from a restart, $rt ring timeouts). That signature tracks context depth, not the model - check amdgpu.lockup_timeout=10000,60000,10000,10000 is still on the pve2 kernel cmdline."
    }
    if ($oom -gt 0) { Add-Action 'Allocation failures in the journal - the pool is being oversubscribed.' }
}
elseif ($dl -gt 0) {
    # only the benign flavour: the first request after a restart racing the load
    Add-Row 'LOGS' 'OK' $logTxt
}
else {
    Add-Row 'LOGS' 'OK' "${Hours}h clean: no DeviceLost, ring timeout or alloc failure"
}

# --- throughput ------------------------------------------------------------
$tg = Get-Num $L['tg']; $pp = Get-Num $L['pp']
if ($tg -le 0) {
    Add-Row 'PERF' 'OK' "no completed request in the last ${Hours}h"
}
else {
    $perfTxt = "last request  tg $('{0:N1}' -f $tg) t/s  |  pp $('{0:N0}' -f $pp) t/s  |  $($L['last_req'])"
    # every alias here serves >13 t/s; single digits means CPU, not a slow model
    if ($tg -lt 8) {
        Add-Row 'PERF' 'FAIL' $perfTxt
        Add-Action "tg of $('{0:N1}' -f $tg) t/s is below anything this box serves on GPU - suspect CPU fallback."
    }
    else {
        Add-Row 'PERF' 'OK' $perfTxt
    }
}

# --- disk ------------------------------------------------------------------
$availGiB = (Get-Num $L['disk_avail']) / 1GB
$pct = [int](Get-Num $L['disk_pct'])
$diskTxt = "$('{0:N0}' -f $availGiB) GiB free  |  ${pct}% used"
if ($L['models_bytes']) { $diskTxt += "  |  /root/models $('{0:N0}' -f ((Get-Num $L['models_bytes']) / 1GB)) GiB" }
if ($availGiB -lt 25) {
    Add-Row 'DISK' 'FAIL' $diskTxt
    Add-Action "Only $('{0:N0}' -f $availGiB) GiB free - too little to stage another GGUF. Prune superseded weights in /root/models."
}
elseif ($availGiB -lt 90) {
    Add-Row 'DISK' 'WARN' $diskTxt
    Add-Action "$('{0:N0}' -f $availGiB) GiB free. A new 35B UD-Q4 is ~21 GiB and a 120B is ~60 GiB - prune /root/models before the next fetch."
}
else {
    Add-Row 'DISK' 'OK' $diskTxt
}

# --- config drift ----------------------------------------------------------
$driftBits = @()
$cfgState = 'OK'
if ($L['ini_box'] -and $L['ini_repo'] -and $L['ini_box'] -ne $L['ini_repo']) {
    $driftBits += '/etc/llama/router.ini differs from the checkout'
    $cfgState = 'WARN'
    Add-Action 'The live router.ini does not match the box checkout - something was scp''d in directly. Reconcile before the next git pull, or the pull will not change what is served.'
}
else { $driftBits += 'router.ini matches the checkout' }

$dirty = [int](Get-Num $L['git_dirty'])
if ($dirty -gt 0) {
    $driftBits += "$dirty dirty file(s) in /root/llama.cpp"
    $cfgState = 'WARN'
    Add-Action "The box checkout has $dirty modified file(s); git pull --ff-only will refuse. Run: git -C /root/llama.cpp checkout -- ."
}
Add-Row 'CONFIG' $cfgState ($driftBits -join '  |  ')

# --- build identity --------------------------------------------------------
$boxHead = $L['git_head']
$buildCommit = if ($L['build'] -match '-(\w+)$') { $Matches[1] } else { '' }
$localHead = ''
try { $localHead = (git -C $RepoDir rev-parse --short=7 HEAD) } catch { }

$buildBits = @("build-vk2 @ $buildCommit  |  checkout @ $boxHead  |  Mesa $($L['mesa'])")
$buildState = 'OK'
if ($buildCommit -and $boxHead -and -not $boxHead.StartsWith($buildCommit) -and -not $buildCommit.StartsWith($boxHead)) {
    $buildState = 'WARN'
    Add-Action "The serving binary was built from $buildCommit but the checkout is at $boxHead - tree changes since then are not in the running server. Rebuild with deploy/radeon-780m/build.sh when convenient."
}
if ($localHead -and $boxHead -and -not $localHead.StartsWith($boxHead) -and -not $boxHead.StartsWith($localHead)) {
    $buildBits += "local repo @ $localHead"
    if ($buildState -eq 'OK') { $buildState = 'WARN' }
    Add-Action "The box is at $boxHead but this repo is at $localHead - push, then git -C /root/llama.cpp pull --ff-only."
}
Add-Row 'BUILD' $buildState ($buildBits -join '  |  ')

# ------------------------------------------------------------------- output

$colors = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
$worst = 'OK'
foreach ($r in $rows) {
    if ($r.State -eq 'FAIL') { $worst = 'FAIL' }
    elseif ($r.State -eq 'WARN' -and $worst -ne 'FAIL') { $worst = 'WARN' }
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
Write-Host ''
Write-Host '  llama-server  ' -NoNewline -ForegroundColor White
Write-Host '192.168.254.250:8080' -NoNewline -ForegroundColor DarkGray
Write-Host ("{0,26}" -f $stamp) -ForegroundColor DarkGray
Write-Host '  ----------------------------------------------------------------' -ForegroundColor DarkGray

foreach ($r in $rows) {
    Write-Host '   ' -NoNewline
    Write-Host ('{0,-9}' -f $r.Name) -NoNewline -ForegroundColor Cyan
    Write-Host ('{0,-6}' -f $r.State) -NoNewline -ForegroundColor $colors[$r.State]
    Write-Host $r.Text
}

Write-Host '  ----------------------------------------------------------------' -ForegroundColor DarkGray
if ($actions.Count -eq 0) {
    Write-Host '   nothing needs action.' -ForegroundColor Green
}
else {
    Write-Host "   needs action ($($actions.Count)):" -ForegroundColor $colors[$worst]
    foreach ($a in $actions) {
        Write-Host '     - ' -NoNewline -ForegroundColor $colors[$worst]
        Write-Host $a
    }
}
Write-Host ''

# 0 healthy, 1 warnings, 2 failures - so it can gate a scheduled check later
switch ($worst) { 'FAIL' { return 2 } 'WARN' { return 1 } default { return 0 } }
}

# --------------------------------------------------------------------- driver

function Write-Unreachable {
    Write-Host ''
    Write-Host '  FAIL  cannot reach the LXC over SSH (192.168.254.250).' -ForegroundColor Red
    Write-Host '        ICMP can fail on this network while SSH works, so test with ssh, not ping.' -ForegroundColor DarkGray
}

if ($Watch) {
    try { [Console]::CursorVisible = $false } catch { }
    try {
        while ($true) {
            # gathered against whatever frame is still on screen - the display
            # only changes once, atomically, right below
            $data = Get-StatusData

            Clear-Host
            if ($null -eq $data) { Write-Unreachable } else { Show-StatusPanel -L $data.L -H $data.H | Out-Null }
            Write-Host "  watching every ${Interval}s - Ctrl+C to stop" -ForegroundColor DarkGray

            Start-Sleep -Seconds $Interval
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
        Write-Host ''
        Write-Host '  stopped watching.' -ForegroundColor DarkGray
    }
}
else {
    Write-Host ''
    Write-Host '  probing 192.168.254.250 ...' -ForegroundColor DarkGray -NoNewline
    $data = Get-StatusData
    Write-Host "`r                              `r" -NoNewline

    if ($null -eq $data) {
        Write-Unreachable
        exit 2
    }
    exit (Show-StatusPanel -L $data.L -H $data.H)
}
