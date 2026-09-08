#!/bin/bash
# Run a benchmark while watching for anything that would invalidate it.
#
# Three ways a number on this box comes out wrong while looking plausible:
#  1. Competing load. A download or a second benchmark steals the memory
#     bandwidth that generation is bound by. bench.sh warns about this; this
#     script refuses to start.
#  2. Thermal or power throttling. The iGPU shares a package power budget with
#     8 Zen4 cores, so a sustained run can drop sclk without any error.
#  3. ANOTHER PROXMOX GUEST. pve2 hosts 15 guests and this LXC is one of them;
#     they share the host's memory controller, which is the exact resource
#     generation is bound by. Nothing inside the container can see them, so
#     this check has to reach the host, and when it cannot it says so loudly
#     rather than passing silently.
#
# Samples sensors throughout and reports the range, so a suspicious result can
# be attributed rather than guessed at.
#
# usage: ./bench-guard.sh <command...>
#   ./bench-guard.sh ./probe-server.sh coder 6
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $0 <command...>" >&2; exit 2; }

# --- refuse to run against competing load ---
BUSY=""
pgrep -x aria2c    >/dev/null && BUSY="$BUSY aria2c(download)"
pgrep -x ninja     >/dev/null && BUSY="$BUSY ninja(build)"
pgrep -x cc1plus   >/dev/null && BUSY="$BUSY cc1plus(compile)"
pgrep -x llama-bench >/dev/null && BUSY="$BUSY llama-bench"
if [ -n "$BUSY" ]; then
  echo "REFUSING: competing load ->$BUSY" >&2
  echo "Memory bandwidth is the bottleneck here; results would be wrong." >&2
  exit 1
fi

# --- refuse to run alongside another Proxmox guest ---
# This container has no key to pve2 by design, so the check normally runs from
# whatever drives the eval. Set PVE_HOST (and give this container a key) to have
# the script enforce it directly; SKIP_PVE_CHECK=1 acknowledges the gap.
PVE_HOST="${PVE_HOST:-}"
SELF_CT="${SELF_CT:-250}"
if [ -n "$PVE_HOST" ]; then
  GUESTS=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$PVE_HOST" \
      'pct list 2>/dev/null | awk "NR>1 && \$2==\"running\" {print \"CT\"\$1}"; qm list 2>/dev/null | awk "NR>1 && \$3==\"running\" {print \"VM\"\$1}"' 2>/dev/null) || {
    echo "REFUSING: PVE_HOST=$PVE_HOST set but unreachable - cannot prove the box is quiet" >&2
    exit 1
  }
  OTHER=$(echo "$GUESTS" | grep -v "^CT${SELF_CT}$" | tr '\n' ' ' | sed 's/ *$//')
  if [ -n "$OTHER" ]; then
    echo "REFUSING: other Proxmox guests running ->$OTHER" >&2
    echo "They share pve2's memory controller with this container." >&2
    exit 1
  fi
  echo "pve2: CT$SELF_CT is the only running guest"
elif [ "${SKIP_PVE_CHECK:-0}" != "1" ]; then
  echo "WARNING: cannot see pve2 from inside this container - other guests would" >&2
  echo "         steal memory bandwidth invisibly. Verify from the host with" >&2
  echo "         'pct list' and 'qm list' before trusting this number." >&2
fi

SAMPLES=$(mktemp); trap 'rm -f "$SAMPLES"' EXIT
(
  while :; do
    python3 - <<'PY'
import glob
def rd(p, div=1000.0):
    try: return int(open(p).read().strip())/div
    except Exception: return None
t = {}
for n in glob.glob("/sys/class/hwmon/hwmon*/name"):
    d, nm = n.rsplit("/", 1)[0], open(n).read().strip()
    if nm in ("k10temp", "amdgpu", "spd5118"):
        v = rd(d + "/temp1_input")
        if v is not None:
            t[nm] = max(t.get(nm, 0), v)
        if nm == "amdgpu":
            w = rd(d + "/power1_average", 1e6)
            if w: t["W"] = w
sclk = 0
try:
    for line in open("/sys/class/drm/card0/device/pp_dpm_sclk"):
        if "*" in line: sclk = int(line.split(":")[1].strip().replace("Mhz", "").replace("*", "").strip())
except Exception: pass
print(f"{t.get('amdgpu',0):.1f} {t.get('k10temp',0):.1f} {t.get('spd5118',0):.1f} {t.get('W',0):.1f} {sclk}")
PY
    sleep 2
  done
) >> "$SAMPLES" 2>/dev/null &
MON=$!
trap 'kill $MON 2>/dev/null; rm -f "$SAMPLES"' EXIT

"$@"
RC=$?

kill $MON 2>/dev/null || true
sleep 1

echo
python3 - "$SAMPLES" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 5]
if not rows:
    print("thermals: no samples"); raise SystemExit
gpu = [float(r[0]) for r in rows]; cpu = [float(r[1]) for r in rows]
mem = [float(r[2]) for r in rows]; pw  = [float(r[3]) for r in rows]
clk = [int(r[4])   for r in rows if int(r[4]) > 0]
print(f"thermals over {len(rows)} samples:")
print(f"  GPU  {min(gpu):5.1f} - {max(gpu):5.1f} C     CPU  {min(cpu):5.1f} - {max(cpu):5.1f} C"
      f"     DIMM {min(mem):5.1f} - {max(mem):5.1f} C")
print(f"  GPU power {min(pw):.1f} - {max(pw):.1f} W")
if clk:
    print(f"  GPU sclk  {min(clk)} - {max(clk)} MHz")
# Phoenix throttles near 95-100C GPU / 95C Tctl; DDR5 near 85C.
warn = []
if max(gpu) >= 90: warn.append(f"GPU {max(gpu):.0f}C near thermal limit")
if max(cpu) >= 90: warn.append(f"CPU {max(cpu):.0f}C near thermal limit")
if max(mem) >= 82: warn.append(f"DIMM {max(mem):.0f}C near limit - memory throttling would hit bandwidth directly")
# sustained load should sit at the top sclk state; dropping while hot is the tell
if clk and max(clk) > 0 and min(clk) < max(clk) * 0.7 and max(gpu) >= 85:
    warn.append(f"sclk fell to {min(clk)} MHz from {max(clk)} while hot - throttling")
print("  VERDICT: " + ("; ".join(warn) if warn else "no throttling, result is trustworthy"))
PY
exit $RC
