# Radeon 780M / Ryzen 8745H deployment

Measured configuration for an AMD Ryzen 7 8745H (Zen 4) with Radeon 780M iGPU
(RDNA3, gfx1103) and 96 GB DDR5-5600, running in an unprivileged Proxmox LXC.

All settings here were derived from benchmarks on this exact hardware. Numbers
are reproducible with `bench.sh`.

## Hardware envelope

| | |
|---|---|
| CPU | Ryzen 7 8745H, 8C/16T, AVX-512 + VNNI + BF16 |
| iGPU | Radeon 780M, 12 CU RDNA3, `fp16` + `KHR_coopmat`, no FP4 |
| RAM | 2x48 GB DDR5-5600 dual channel |
| Measured read bandwidth | 59.4 GB/s (peak at 8 threads; 16 threads is slower) |
| GPU-addressable | 16 GiB VRAM carveout + 60 GiB GTT = 76 GiB |

Token generation is bandwidth-bound on this platform. The 59.4 GB/s figure sets
the ceiling: generation speed is roughly bandwidth / bytes-read-per-token, so
MoE models with few active parameters massively outperform dense models of the
same file size. A dense 27B runs at ~4 t/s; a 35B MoE with 3B active runs at
~22 t/s from the same 16-20 GiB on disk.

## What actually mattered

Ranked by measured effect:

| Change | Effect |
|---|---|
| MTP speculative decoding (`spec-type = draft-mtp`) | +35-45% generation on code |
| `spec-draft-n-max = 6` (default 3) | +32% generation on top of MTP; 8 regresses |
| Mesa 25.2.8 -> 26.1.6 (kisak PPA) | +13-22% prompt processing |
| `ubatch-size = 2048` (retune after Mesa change) | +10-20% on long prompts |
| KV cache `q8_0` | +5-7% generation, half the KV memory |
| `ttm.pages_limit` raise | unlocks models >39 GiB |
| `parallel = 2` + `kv-unified` + `cache-ram` | keeps agent prefix cached across interleaved requests |

Note the second and third interact: the optimal ubatch changed when Mesa was
upgraded. Retune ubatch after any driver change.

## Tested and rejected

Do not spend time on these; all measured zero or negative on this hardware.

| Attempted | Result |
|---|---|
| `GGML_VULKAN_INTEGER_DOT` via newer glslc | 0% - coopmat path dominates |
| `GGML_HIP_ROCWMMA_FATTN=ON` | 0% - does not activate on RDNA3 |
| `--load-mode mlock` / `mmap` variants | 0% - irrelevant under full GPU offload |
| `power_dpm_force_performance_level=high` (host) | 0-1% - auto DPM already ramps fully under load |
| `ctx-checkpoints` / `checkpoint-min-step` tuning | not needed - identical-prefix restore reprocesses ~15 tok |
| Vulkan: add an RDNA3 entry to `gpu_pipeline_configs` | tg flat, pp -2% |
| Vulkan: raise the `mul_mat_id` vector-path threshold | no gain at our draft length (see below) |
| `models-max = 2` to co-resident two models | OOM-killed under load (see below) |
| Qwen3-Next-80B-A3B-Thinking as `deep` | less accurate and slower than gpt-oss-120b |
| Ternary-Bonsai-27B (Q2_0_g128) | will not load - needs the vendor fork, kernels are CUDA/Metal only |

### Dense models do not work here

Three dense models were measured on this hardware, all coherent and all far too
slow, because a dense model reads every parameter per token while the MoE models
read 3-10 experts of 256:

| model | size | speculation | tg |
|---|---|---|---|
| Qwopus3.6-27B-Fusion (dense 27B) | 15.7 GiB | none | **4.6 t/s** |
| Fable-Fusion-711 (dense 27B) | 15.7 GiB | MTP, 0.66 acceptance | 8.3 t/s |
| Defiant (dense 9B) | 8.2 GiB | MTP, 0.78 acceptance | 17.8 t/s |

The two 27Bs share a base and a file size; the only difference is that one can
speculate, and that is worth 1.8x. Against `fast` at 34.6 t/s from a 22 GiB MoE,
none of them is competitive - the 27Bs are 4-7x slower from a *smaller* file.
Treat "dense" as disqualifying on this box unless the weights are sub-2-bit.

### On ternary quants

Ternary looks made for this hardware - 27B-class weights in 6.7 GiB is exactly
the byte-per-parameter reduction a bandwidth-bound iGPU wants, and the published
scores are strong (80.49 across 15 thinking benchmarks, coding 85.96). It does
not work here, for reasons worth recording before the next one comes along.

The file is `Q2_0_g128`, a group-128 layout that is not upstream `Q2_0` despite
the name, so stock llama.cpp fails at load with a tensor offset mismatch
(`output_norm.weight has offset 337715200, expected 357580800`) rather than an
unsupported-type error. The checksum verifies - the file is fine, the format is
simply different. Beyond that, the vendor states the low-bit kernels exist for
CUDA and Metal only, so even on their fork there is no Vulkan path.

Worth re-checking if upstream ever lands ternary Vulkan kernels; the shape of
the win is real, only the plumbing is missing.

### Replacing the deep slot

Qwen3-Next-80B-A3B-Thinking Q5_K_XL looked like the obvious upgrade - same
`qwen3next` arch as `coder`, native thinking, 262K ctx, 52.8 GiB against
gpt-oss's 60.4, and 3B active against 5.1B. Measured, it loses on both axes:

| | gpt-oss-120b | Qwen3-Next-80B-A3B-Thinking |
|---|---|---|
| `reason-eval.sh` | 8/8 | 7/8 |
| reasoning emitted | 15.4k chars | 27.2k chars |
| pp | 242 t/s | 176 t/s |
| tg | 19.6 t/s | 20.5 t/s |
| swap-in | 66 s | 62 s |

It spends nearly twice the reasoning to reach a worse answer, and 27% slower
prefill outweighs 4% faster generation on the long prompts this slot sees.
Fewer active parameters did not translate into speed here: the hybrid GDN
layers prefill poorly, and Q5_K_XL reads more bytes per weight than MXFP4.

### Co-residency

`models-max = 2` does work - `coder` plus `assist` fit, and switching drops
from 14-40 s to under 4 s. It is still not worth it: GTT sits at 59.2 of
60 GiB, prompt processing falls 32% (235 -> 159 t/s), and a 9k-token prompt
OOM-killed the service. Keep `models-max = 1` and pay the swap.

### Code-level attempts (Vulkan backend)

Two source changes were built and measured against this hardware. Neither is
applied; both are recorded so they are not retried blind.

**RDNA3 subgroup size.** `gpu_pipeline_configs` in `ggml-vulkan.cpp` has entries
for RDNA1 and RDNA2 but none for RDNA3, so `get_subgroup_size` returns 0 and the
device falls back to RADV's reported 64 - where RDNA2 would have been pinned to
`RDNA_DEFAULT_SUBGROUP_SIZE` (32). Adding a matching RDNA3 entry does change the
device to wave32 (`warp size: 32` in the banner), but measured tg 18.47 vs 18.53
and pp 222 vs 227. RADV already picks a good wave size per shader.

**MoE vector-path threshold.** `ggml_vk_use_mul_mat_vec_id` selects the matvec
path only when `src2->ne[1] <= 8`; above that it uses the matrix path. The matvec
path loops over tokens, one dispatch each, so its cost is linear in batch size -
`MUL_MAT_ID(q4_K, n_used=8)` measures a flat 88-95 us/token from n=1 to n=32,
and only improves past n=128. A 9-token speculative batch therefore crosses into
the matrix path, which is why `spec-draft-n-max = 8` regressed. Raising the
threshold to 32 does recover that case (19.5 -> 21.3 t/s at n-max 8), but n-max 4
stays faster than either, so the change buys nothing at the draft length we run.

### Watch for silent CPU fallback

If throughput drops several-fold, check the backend before trusting any other
measurement. When Vulkan fails to initialise, llama.cpp does not error - it
falls back to CPU and keeps serving at roughly a sixth of the speed. The tell is
the backend column in `llama-bench` reading `CPU` instead of `Vulkan`:

```sh
llama-bench -m <model> -ngl 99 -p 512 -n 64 | grep -E "Vulkan|CPU"
vulkaninfo --summary | grep -A1 deviceName     # RADV PHOENIX should be listed
awk '{print $1/1073741824" GiB"}' /sys/class/drm/card0/device/mem_info_gtt_used
```

The cause seen here was GTT exhaustion: an orphaned `llama-server` child left in
uninterruptible `D` state kept 38 GiB of GTT and 16 GiB of VRAM pinned, so RADV
could no longer open `/dev/dri/renderD128` (`Cannot allocate memory`). Restarting
the service while requests are in flight on the GPU is what produced the orphan.
`SIGKILL` will not reap a `D`-state task, `pct stop` and `pct reboot` both hang
on it, and an `amdgpu_gpu_recover` MODE2 reset succeeds at the device level
(`device wedged, but recovered through reset`) without freeing the process. Only
a hard power cycle cleared it.

Degradation is progressive, not a cliff: pp on `coder` measured 213, then 200,
then 184 t/s over the hour it took to wedge, and returned to 235 t/s after the
reboot. Do not write off a slow downward drift as run-to-run variance - re-check
the backend. Genuine repeat variance on an idle, healthy box is only a few
percent, so prefer `llama-bench` (which reports stddev) for clean pp/tg numbers,
and make sure nothing else is driving the server while sampling.
| Draft-model speculation (Qwen3.5-0.8B) | 0% - never engages on hybrid arch |
| `spec-type ngram-*` (all variants) | 0 to -4% with varied prompts |
| ROCm/HIP backend | wins pp by 7-11%, loses tg by 11-21%, caps at 39 GiB |

### The probe-server stall on `coder`

Measured 2026-08-01. `probe-server.sh` reliably stalls `coder` on the third or
fourth consecutive sample. Three runs, three stalls:

| run | clean samples | pp / tg | stalled at | recovery |
|---|---|---|---|---|
| first | 5 | 227.7 / 24.77 | sample 6 | self-cleared after ~11 min |
| after clean restart | 3 | 232.0 / 24.77 | sample 4 | none, stopped it after 27 min |
| after clean restart | 3 | 190.5 / 24.5 | sample 4 | none, stopped it after 8 min |

During a stall the GPU is pegged at 92% at the full 2600 MHz state, the model
child sits in `R` state burning about a third of a core, its worker threads are
parked in `futex_do_wait`, and nothing is in `D`. Generation is unaffected
throughout - tg measures 24.3-25.4 on every clean sample - so what degrades is
prefill (232 -> 190 t/s across episodes) and then the decode phase hangs
outright, emitting no timing lines at all.

What it is not, each ruled out by measurement rather than assumed:

| checked | result |
|---|---|
| silent CPU fallback | no - the GPU is saturated, not idle |
| thermal or power throttling | no - 71 C and 44 W, limit is ~95 C |
| memory pressure | no - PSI ~0, 44 GB free, no swap |
| driver wedge | no - `renderD128` opens, a clean stop drains GTT to 0.013 GiB |
| competing load | no - no apt, no unattended-upgrades, nothing else running |

Suspected trigger is the probe's own request shape: the same 2472-token prompt
repeated with `cache_prompt: false` and `ignore_eos: true` against `parallel = 2`
plus `kv-unified` plus speculation. The journal shows `f_sim_best = 1.000` on
every request - a perfect prefix match that is then forced to reprefill cold. A
real agent client caches, so ordinary serving is probably unaffected, but that
is unconfirmed and the isolation has not been run yet.

Consequences for anything that measures this box:

- Keep `probe-server.sh` at **3 samples**. The 600 s per-request timeout means
  one stalled sample costs ten minutes and takes the whole run down with a
  `TimeoutError` traceback.
- Prefer `llama-bench` when speculation is not the subject. It does not exhibit
  this and it reports stddev.
- Do not kill the service to hurry a stall along. Wait for `gpu_busy_percent` to
  fall, then stop. A stop during a stall took the full `TimeoutStopSec` of 120 s
  and needed the SIGKILL escalation, against 1 s when idle. It recovered cleanly
  both times, but that is the unit hardening working, not luck.
- A stop/start restores prefill: 190 -> 219.7 t/s on the next sample.
- **Sample GPU state during the run, not after.** `gpu_busy_percent` and
  `pp_dpm_sclk` read once a task has released show an idle GPU at 800 MHz, which
  says nothing about what happened while it ran. Reading them after the fact is
  what produced a wrong "CPU fallback" call during this investigation; reading
  them mid-stall is what showed the GPU was pegged instead.

### On ROCm

ROCm 7.2 works via `HSA_OVERRIDE_GFX_VERSION=11.0.2` (rocBLAS ships no gfx1103
TensileLibrary, so it must masquerade as gfx1102). It is not recommended:
generation is consistently slower, and KFD advertises only what `ttm.pages_limit`
allowed at driver init, so large models fail or hang. Vulkan sees the full pool.

## Host prerequisites

Kernel cmdline (Proxmox host), then reboot:

```
amd_iommu=on iommu=pt amdgpu.gttsize=61440 amdgpu.no_system_mem_limit=1 \
transparent_hugepage=always ttm.pages_limit=15728640
```

`ttm.pages_limit` is in 4 KiB pages: GiB x 262144. 15728640 = 60 GiB. This is the
binding limit - `amdgpu.gttsize` alone is deprecated and does not raise the TTM
cap. Keep the two aligned or the kernel logs a mismatch warning.

Container config (`/etc/pve/lxc/<id>.conf`):

```
cores: 16
dev0: /dev/dri/renderD128,gid=993
dev1: /dev/dri/card0,gid=44
dev2: /dev/kfd,gid=993
lxc.prlimit.memlock: unlimited
```

`cores` must cover whole SMT pairs. Proxmox picking an arbitrary subset (e.g. 14
of 16) produces an asymmetric cpuset where some physical cores contribute one
thread and others two, which creates stragglers at layer sync points.

## Install

```sh
./build.sh                       # builds Vulkan backend with a modern glslc
cp router.ini /etc/llama/
cp llama-server.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now llama-server
```

`build.sh` fetches a current shaderc. Distro glslc (Ubuntu 24.04 ships 2023.8) is
too old to compile several feature shaders, and CMake silently drops any feature
whose probe fails rather than erroring.

## Updating

**This repo is the single source of truth.** Every change - `router.ini`, the
systemd unit, the scripts - is edited here, committed, and only then copied to
the server. Nothing is edited in place on the box. `/etc/llama/` and
`/etc/systemd/system/` hold deployed copies, never originals, and
`/root/llama.cpp` is a read-only mirror of this repo.

Editing on the server instead costs you the record of why a value is what it is.
Every number in `router.ini` was measured, and the reasoning lives in the commit
that set it; a `sed` on the live file leaves a tuned system nobody can explain
and a repo that lies about what is running.

To check the box has not drifted:

```sh
git -C /root/llama.cpp status --short          # must be empty
diff /root/llama.cpp/deploy/radeon-780m/router.ini /etc/llama/router.ini
diff /root/llama.cpp/deploy/radeon-780m/llama-server.service \
     /etc/systemd/system/llama-server.service
```

Updates are deliberate, not scheduled - nothing pulls automatically. The tuning
in `router.ini` is measured against a specific llama.cpp build and Mesa version,
so an unattended update can silently invalidate it.

**Config only** (edited `router.ini` here, want it live). Safe any time:

```sh
git -C /root/llama.cpp pull --ff-only
cp /root/llama.cpp/deploy/radeon-780m/router.ini /etc/llama/
systemctl restart llama-server        # only when idle - see below
```

**Config plus new llama.cpp** (picking up upstream changes). Rebuild first, and
budget time to re-measure afterwards:

```sh
systemctl stop llama-server
git -C /root/llama.cpp pull --ff-only
cd /root/llama.cpp/deploy/radeon-780m && ./build.sh
cp router.ini /etc/llama/
cp llama-server.service /etc/systemd/system/ && systemctl daemon-reload
systemctl start llama-server
./bench.sh <model>                    # confirm ubatch 2048 is still optimal
./probe-server.sh coder 6             # real serving speed, incl. speculation
```

Three things to know:

- **Restart only when idle.** Tearing down mid-decode can wedge a model child in
  the GPU driver; see "Watch for silent CPU fallback" for why that is expensive.
  Check with `curl -s localhost:8080/slots`.
- **Re-verify after any llama.cpp or Mesa change.** Optimal ubatch moved the last
  time Mesa was upgraded, and the speculation settings are build-specific. A new
  build is a reason to re-run `bench.sh`, not to assume the numbers hold.
- **If the pull refuses**, the working tree has drifted (a stray `chmod` is the
  usual cause). This checkout is a mirror and holds nothing you need - the live
  config lives in `/etc/llama/` - so discard and retry:
  `git -C /root/llama.cpp checkout -- . && git -C /root/llama.cpp pull --ff-only`

## Models

Always verify checksums. Use `fetch-model.sh`, which checks the SHA256 from the
HF API and retries. Parallel downloaders against HF's Xet CDN can produce files
that are the correct length but byte-damaged; a damaged GGUF still loads and
still benchmarks at full speed, it just emits garbage.

| Slot | Model | Why |
|---|---|---|
| `fast` | Ornith-1.0-35B MTP-APEX + mmproj | all-rounder: reasoning, vision and tools in 21.9 GiB |
| `assist` | Qwen3-VL-30B-A3B-Instruct UD-Q4_K_XL + mmproj | only alias with vision; 32 t/s, 256K ctx |
| `coder` | Qwen3-Coder-Next UD-Q4_K_XL + DFlash drafter | SWE-bench Verified 70.6 at 3B active; best agentic quality that fits |

`coder` is arch `qwen3next`: a hybrid of 48 blocks where only every 4th is full
attention (`full_attention_interval = 4`) and the other 36 are Gated Delta Net
linear-attention layers, over 512 experts with 10 used. The GDN op is the reason
speculation pays here beyond the usual: `GATED_DELTA_NET(head_count=32,
head_size=128)` costs 64 us at one token but 3.6 us/token at 64 tokens, because
the 4.2 MB of per-layer recurrent state is read and written once per call
regardless of batch size. Clean `llama-bench` figures: pp512 227 t/s, tg64 18.5 t/s.
Served with the DFlash drafter on a healthy box: pp 235 t/s, tg 25 t/s.
| `deep` | gpt-oss-120b MXFP4 | 117B/5.1B active, native `reasoning_effort` |

Measured on `coder` (80B-A3B, 46 GiB): pp ~210 t/s, tg 18 t/s base, 25 t/s with
the DFlash drafter (`spec-type = draft-dflash`, 88% acceptance at n-max 3-4).
Draft length above 4 regresses even though more tokens are accepted: on MoE,
each verified token routes to different experts, so verify bandwidth grows with
draft length. This is the opposite of dense models - keep MoE drafts short.

ubatch 2048 is optimal for `coder` too (1024 and 4096 both measure ~180 t/s pp
vs 213 at 2048). `cache-ram` is a cap, not an allocation, and GTT weights do
not count against the container cgroup, so `fast`/`coder` carry a higher cap
(24576) than `deep`, whose 59 GiB GTT leaves less physical host RAM.

Both expose a thinking toggle, so one endpoint covers quick edits and deep
analysis:

```jsonc
// fast, no thinking
{"model": "fast", "chat_template_kwargs": {"enable_thinking": false}}
// deep, full reasoning
{"model": "deep", "chat_template_kwargs": {"reasoning_effort": "high"}}
```

Give thinking requests a generous `max_tokens`. Reasoning is emitted before the
answer, so a small budget returns empty content with `finish_reason: length`.
This also makes a working model look broken: at `max_tokens = 200`, `fast` spent
159 tokens reasoning and returned no tool call at all, which reads exactly like
missing tool support. `check-vision-tools.sh` budgets 1200 for that reason.

### Picking a slot

Point Hermes Agent at `fast`: it takes images, which Hermes needs for its
screenshot tooling, and it reasons and calls tools in the same model. `assist`
remains the alternative when prompt processing dominates - it prefills 24%
faster, which tells on the very long contexts an agent accumulates, but it has
no reasoning channel of its own. Verify any new model with:

```sh
./check-vision-tools.sh assist    # tool calling + image input
./probe-server.sh assist 6        # real serving throughput
```

Measured on this hardware, generation with a 2.4k-token prompt:

| alias | pp | tg | vision | tools | reasoning |
|---|---|---|---|---|---|
| `fast` | 317 t/s | 34.6 t/s | yes | yes | yes, 8/8 in 190 s |
| `assist` | 394 t/s | 32 t/s | yes | yes | no |
| `coder` | 235 t/s | 25 t/s | no | yes | no |
| `deep` | 242 t/s | 19.6 t/s | no | yes | yes, 8/8 in 279 s |

`fast` is now the default choice for almost everything: it beats `coder` on
every published SWE-bench variant while generating 38% faster in half the
footprint, and matches `deep` on the reasoning eval in two thirds the time from
a third of the size. `assist` is kept only for its prefill lead, which matters
on the very large contexts an agent client builds up. Note the eval saturates -
both `fast` and `deep` score 8/8 - so it cannot separate them on genuinely hard
analysis, where `deep`'s 117B parameters may still tell.

`models-max = 1` swaps on demand rather than co-residing: gpt-oss alone is 59 GiB
of the 76 GiB pool. Swap cost is ~31 s for gpt-oss, ~14 s for the 35B.

Restart the service only when it is idle. A `systemctl restart` with requests in
flight can leave the model child process wedged in the GPU driver, and a
`vk::DeviceLostError` on the first request afterwards is the early warning: it
means the previous instance did not tear down cleanly. Do not simply retry past
it - check `mem_info_gtt_used` has returned to ~0 with the service stopped,
because a leaked child pins the whole pool and eventually forces CPU fallback
(see "Watch for silent CPU fallback").

## Serving agent clients (Claude Code, OpenCode)

The server exposes both OpenAI (`/v1/chat/completions`) and Anthropic
(`/v1/messages`, `/v1/messages/count_tokens`) APIs. Tool use, streaming and
`cache_control` blocks all work, so Claude Code runs against it directly.

Agent clients interleave one large growing conversation with small background
requests (title generation, summarization). With a single slot those evict the
main prefix and every turn reprocesses the full context. Three settings fix it:

- `parallel = 2` - background requests land on the second slot
- `kv-unified = true` - both slots share the full ctx-size pool instead of splitting it
- `cache-ram = 16384` - displaced prefixes restore from RAM instead of reprocessing

Measured with an 11k-token prompt interleaved with a small request: 9k of 11k
tokens restored from cache. Generation on code: 32 t/s (MTP unaffected by the
second slot). Fresh prompt processing: 313 t/s, so a cold 25k-token agent
system prompt costs ~80 s once, then stays cached.

Claude Code setup (PowerShell; bash equivalent with `export`):

```powershell
$env:ANTHROPIC_BASE_URL       = "http://192.168.254.250:8080"
$env:ANTHROPIC_AUTH_TOKEN     = "local"
$env:ANTHROPIC_MODEL          = "coder"
$env:ANTHROPIC_SMALL_FAST_MODEL = "coder"
claude
```

Keep `ANTHROPIC_SMALL_FAST_MODEL` on the **same alias** as the main model:
with `models-max = 1`, pointing it at a different model forces a 14-31 s model
swap on every background request.

OpenCode (`~/.config/opencode/opencode.json`):

```jsonc
{
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://192.168.254.250:8080/v1" },
      "models": { "fast": {}, "deep": {} }
    }
  }
}
```
