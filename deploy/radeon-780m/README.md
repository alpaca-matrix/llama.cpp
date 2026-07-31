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
| Draft-model speculation (Qwen3.5-0.8B) | 0% - never engages on hybrid arch |
| `spec-type ngram-*` (all variants) | 0 to -4% with varied prompts |
| ROCm/HIP backend | wins pp by 7-11%, loses tg by 11-21%, caps at 39 GiB |

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

## Models

Always verify checksums. Use `fetch-model.sh`, which checks the SHA256 from the
HF API and retries. Parallel downloaders against HF's Xet CDN can produce files
that are the correct length but byte-damaged; a damaged GGUF still loads and
still benchmarks at full speed, it just emits garbage.

| Slot | Model | Why |
|---|---|---|
| `fast` | Qwen3.6-35B-A3B-MTP UD-Q4_K_XL | MTP head enables +35-45% speculation |
| `deep` | gpt-oss-120b MXFP4 | 117B/5.1B active, native `reasoning_effort` |

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

`models-max = 1` swaps on demand rather than co-residing: gpt-oss alone is 59 GiB
of the 76 GiB pool. Swap cost is ~31 s for gpt-oss, ~14 s for the 35B.

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
$env:ANTHROPIC_MODEL          = "fast"
$env:ANTHROPIC_SMALL_FAST_MODEL = "fast"
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
