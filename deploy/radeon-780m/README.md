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
| `parallel = 3` + `kv-unified` + `cache-ram` | keeps agent prefix cached across interleaved requests; third slot added 2026-08-11 for a second independent client |
| `spec-draft-p-min = 0.3` on `fast` | +2% generation; acceptance 0.82 -> 0.85-0.87 (see fast-opt-plan notes below) |
| `spec-draft-type-k/v = q8_0` on `fast` | 0% speed, halves the MTP draft KV; kept for the memory |

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
| ~~Vulkan: raise the `mul_mat_id` vector-path threshold~~ | **REOPENED 2026-08-11** - rejected while the batch size was ours to choose, which stops being true at `parallel = 3`. Now a runtime knob, `GGML_VK_MUL_MAT_VEC_ID_MAX_COLS`; value still to be measured. See "MoE vector-path threshold" |
| `models-max = 2` to co-resident two models | OOM-killed under load (see below) |
| Qwen3-Next-80B-A3B-Thinking as `deep` | less accurate and slower than gpt-oss-120b |
| Ternary-Bonsai-27B (Q2_0_g128) | will not load - needs the vendor fork, kernels are CUDA/Metal only |
| Ornith-Agents-A1-3.6-35B-A3B as `fast` | faster on every axis (+13% tg) but reason-eval 6/8 vs 8/8 in 3x the time - runs the token budget out without concluding |
| MiniMax-M2.1 IQ1_S as `coder`/`deep` | fits at 131072, but tg collapses 65% by d32768 (62 of 62 full-attention layers) and reasoning does not converge at 1.64 bits/weight |
| Disabling MMVQ (upstream PR 25666) | 0 to -5% - bracketed with `GGML_VK_DISABLE_MMVQ` (see below) |
| Hoisting q8_0 KV dequant in coopmat1 FA (upstream PR 25494) | no headroom - q8_0 KV already matches f16 at depth (see below) |
| `spec-draft-p-min` 0.5 (and 0.2) | 0.5 over-truncates (accept 0.86-0.89 but mean len drops, tg back to baseline); 0.2 barely fires; 0.3 is the peak |
| `GGML_VK_MAX_NODES_PER_SUBMIT = 25` | llama-bench tg +0.9%, but SERVED tg -1% - bench gains on submit granularity do not transfer to the MTP round shape |
| `cache-idle-slots = false` | deferred, not rejected: single-stream served pp measured stable (325-327 t/s) on 2026-08-02, so the 264-311 variance it targets was not reproducible; revisit if agent-shaped pp instability recurs |
| Vulkan: `DMMV_WG_SIZE_LARGE` on the `_id` matvec for AMD | tg -1.9% (24.69 vs 25.16) - the NVIDIA/Intel spread-the-work heuristic does not fit 12 CUs |
| Vulkan: FA scalar path for the 2-4-row verify batches | flat at 2.6k ctx (35.09 vs 35.07 served); untested at depth |
| Vulkan: LOWER the `mul_mat_id` vector-path threshold to 1 | tg -27% (25.79 vs 35.07 served) - expert-count prepass + matrix tiles swamp the union-read saving at tiny n; with the earlier raise-to-32 rejection this brackets the default 8 as correct on this box |
| ~~Gated (Laguna) DFlash speculation on `laguna-eval`~~ | **REVERSED 2026-08-07** - the drafter was being run at its shipped BF16, which costs ~35 ms of a ~156 ms round on this bandwidth-bound box and ate the whole margin. Quantized to Q4_K_M it is +19.4%, not +0.9%. See "A BF16 drafter cannot pay for itself" below |

### Stage 0 of fast-opt-plan: where decode time goes (2026-08-02)

Measured with `GGML_VK_PERF_LOGGER_CONCURRENT` on `fast`, build b303f73:

- Decode (tg64): GPU-busy median 34.9 ms/token vs ~39.4 ms unlogged wall ->
  the CPU/sync bubble is ~11% of decode wall. The box is GPU-bound; per-kernel
  wins are worth pursuing, and overlap work caps out around that 11%.
- Prefill (pp512): GPU-busy ~= wall (~1% bubble). Prefill is pure GPU.
- Fusion sanity: `TOPK_MOE_EARLY_SOFTMAX_NORM`, `RMS_NORM_MUL`, `MULTI_ADD`
  all present in the served graph. `GATED_DELTA_NET` confirms the hybrid arch.
- `graphs reused` counter: ~72 per 256-token request ~= one per speculative
  round, i.e. only the target verify graph reuses; the MTP draft context
  rebuilds its graph on all 4 of its decodes per round (shape alternation).

Stages 2-3 (2026-08-02, tested via a temporary build-vk3 router on :8081):
the per-round n_vocab sampler clone is now guarded out in the tree (measured
flat on tg as predicted - it sat inside the 11% CPU bubble - but verified
acceptance-identical to five decimals, kept as an upstreamable cleanup along
with a dangling-pointer fix in common_sampler_clone). All three Vulkan
kernel-selection experiments measured zero or negative and were reverted;
per-entry results in the table above.

### The MTP catch-up decode cannot absorb draft step 0

Stage 4 of fast-opt-plan, built and measured 2026-08-02, then reverted.

Per round, `draft-mtp` runs four decodes on the draft context: `n_max`
drafting steps plus a catch-up decode (`common_speculative_process`) that
replays the verify batch with the target's hidden states. The catch-up runs
*before* acceptance is known, so it also re-evaluates the rejected tail. The
idea was to move it after acceptance, decode only the accepted prefix, and
append one logits row for the token the target just sampled - making the same
decode produce draft step 0 and removing one decode plus one synchronize per
round.

It works, and it is slower. Measured on `fast`:

| condition | tg | acceptance | mean draft len |
|---|---|---|---|
| baseline | 35.07 | 0.85 | 3.51 |
| catch-up after acceptance, no step-0 merge | 34.68 | 0.85 | 3.51 |
| full merge | **26.41** | **0.57** | 2.55 |

Step 0's *token* comes out correct - it matched the baseline token on every
sampled round, with probabilities agreeing to about 1%. Its *hidden state*
does not: 1.120066 against -2.698365 on the same input pair. That hidden
state is the input embedding for steps 1 and 2, so those drafts are computed
from a corrupted `h` and get rejected, which is the whole regression.

The reason is a KV invariant that is easy to miss. After drafting, the server
removes the speculated region from the draft context (`ckpt.pos_max + 1`), and
nothing refills it until the next catch-up call. So the legacy step-0 decode
deliberately runs with a *hole* where the accepted tokens' KV would be. The
merged version fills that region in first, because it must decode the accepted
rows to place the step-0 row after them. Same token, same position, same input
embedding - different attention context, therefore a different hidden state.
That hole is what `[TAG_SPEC_AVOID_DRAFT_REEVAL]`'s "always re-evaluate for
simplicity" is holding in place.

Worth knowing before attempting this again: moving the catch-up after
acceptance is itself sound and costs nothing (row two of the table, within
noise of baseline), so the acceptance-aware plumbing is reusable. What does
not work is deriving step 0 from a decode that has already materialised the
accepted KV. Any future attempt has to reproduce the legacy attention context
exactly, and must be gated on a token-for-token acceptance match rather than
on throughput - the token stream alone looks correct here while the drafts
behind it are not.

### A BF16 drafter cannot pay for itself (2026-08-07)

Gated DFlash support for Laguna was implemented, measured, and rejected on
`laguna-eval` earlier the same day at +0.9%. That rejection was wrong. The
drafter had been left at the BF16 poolside ships, and **the drafter's own
weights are read in full on every draft round, exactly like the target's**. At
2.08 GiB that is ~35 ms of a ~156 ms round - the entire speculation margin.

Re-measured with nothing changed but the drafter's quantization (ctx 32768,
`parallel 1`, 4 coding prompts, 300 tokens each, box idle, production stopped):

| drafter | file | tg @ n-max 2 | vs baseline | acceptance |
|---|---|---|---|---|
| BF16 (as shipped) | 2.08 GiB | 14.22 | +0.5% | 0.601 |
| Q8_0 | 1.10 GiB | 15.57 | +10.0% | 0.591 |
| Q3_K_M | 0.50 GiB | 16.04 | +13.4% | 0.588 |
| IQ4_XS | 0.55 GiB | 16.05 | +13.4% | 0.591 |
| **Q4_K_M** | **0.60 GiB** | **16.89** | **+19.4%** | **0.617** |

Baseline is 14.15 t/s with no drafter. **Acceptance is flat at 0.59-0.62 across
every quantization** - a 4-bit drafter drafts as well as a 16-bit one - so the
whole spread is bytes read, not draft quality. Q3_K_M being no better than
Q4_K_M despite being smaller marks the floor.

The draft length barely matters once the drafter is cheap. Q4_K_M at n-max 1 /
2 / 3 measures 15.90 / 16.89 / 15.69, and n-max 4 with p-min 0.6 measures
16.60; that whole band is inside the noise of a 4-prompt median (individual
prompts ranged 14.03-18.54). Take n-max 2, p-min 0 and do not over-tune it.

What survives from the earlier analysis is the **cost model**, which is still
correct and still the reason to keep drafts short here: round cost is flat in
acceptance and set by verify width, because each extra token in the batch
routes to its own 10-of-256 experts. Break-even needs `1 + n_max*acceptance >
cost_ratio`, which lands near acceptance 0.5 at n-max 2. Laguna's drafter sits
just above that, which is why the BF16 overhead was enough to hide the win
entirely.

Two corrections to what was recorded with it:

- **Poolside does not recommend `--spec-draft-n-max 15`.** Their model card
  recommends **7** speculative tokens for vLLM and describes 15 as the *clamp*
  (trained `block_size` 16, minus the anchor token). The earlier note read a
  ceiling as advice. 15 is still the worst setting measured here.
- The **n-max 8 and 15 cliffs** are real and unchanged: 9- and 16-token verify
  batches fall off the `mul_mat_vec_id` path onto the matrix path, the same
  `<= 8` threshold as the two rejected attempts to move it.

A **DSpark confidence head** would still help (adaptive per-position truncation
instead of a global p-min), and no DSpark drafter exists for Laguna. But it is
no longer the thing standing between this model and a working drafter.

**Generalisation worth keeping: never load a drafter at F16/BF16 on this box.**
This applies to DFlash, EAGLE3 and plain draft models alike. Vendors ship
drafters unquantized because on a compute-rich dGPU the extra weight traffic is
free; here it is the whole budget. `llama-quantize --allow-requantize <drafter>
<out> Q4_K_M 8` takes about two seconds.

### Published quant mixes are not optimised for a bandwidth-bound box (2026-08-07)

Generation speed here is arithmetic: **bytes read per token, divided by ~70
GB/s**. Laguna-S-2.1 UD-IQ3_S reads 4.93 GB/token and serves at 70.7 ms/token =
69.8 GB/s effective, so its decode path is already near optimal and the only
lever left is reading fewer bytes.

Computing that budget from the GGUF exposes a badly allocated mix. `attn_q` +
`attn_output` at Q6_K are **41.6% of per-token traffic - more than all 256
experts combined** - because they are read in full every token while any one
expert is read 10 times in 256. Unsloth's UD mixes protect attention and crush
experts to IQ2_S, which is right for quality per byte *stored* and wrong here.

Requantizing just those two tensors to IQ4_XS (`pin-tensor-types.py` +
`llama-quantize --tensor-type-file`, everything else byte-copied):

| variant | retargeted to IQ4_XS | size | tg | pp4096 | PPL (80 chunks, held-out code) |
|---|---|---|---|---|---|
| base UD-IQ3_S | — | 45.10 GiB | 13.77 | 147.5 | 2.3658 +/- 0.0339 |
| Q5_K control | attn_q, attn_output | 44.78 GiB | 14.16 | — | 2.3674 +/- 0.0341 |
| V2 | attn_q, attn_output | 44.42 GiB | 16.08 | 151.0 | 2.3660 +/- 0.0339 |
| **V3** | **+ attn_k, attn_v, shexp** | **44.21 GiB** | **16.95** | **153.3** | **2.3657 +/- 0.0337** |

**+23.1% tg and +3.9% pp at unchanged perplexity** (V3 lands 0.0001 *below*
stock, i.e. noise). The Q6_K attention was pure overprovisioning - quality is
already set by the IQ2_S experts. `output.weight` and `token_embd` were left at
Q6_K; lm_head is where 4 bits is known to bite and they are only 0.24
GiB/token. This is specific to a mix this lopsided - do not assume it carries
to a model whose experts are already at 4 bits or better.

Two things to carry forward:

- **Prefer IQ4_XS to Q5_K on this backend.** Q5_K saves 328 MiB and should have
  been +7.5%; it measured +2.8%, because its 5-bit unpack is split across two
  planes and is slower per byte than the Q6_K it replaced. The bytes-per-token
  model predicts bandwidth, not dequant cost - confirm with llama-bench.
- **This win and the drafter win are substitutes, not complements** - and on
  the full V3 requant the drafter turns into a net loss. See below.

### Requantizing the target un-does a feature-conditioned drafter (2026-08-07)

Served tg through `spec-sweep.sh`, same four prompts throughout:

| config | tg | acceptance |
|---|---|---|
| stock, no drafter | 14.15 | — |
| V2, no drafter | 16.00 | — |
| **V3, no drafter** | **16.75** | — |
| stock + Q4_K_M drafter, n-max 2 | 16.89 | 0.617 |
| V2 + drafter, n-max 2 | 17.00 | 0.611 |
| V3 + drafter, n-max 2 | 16.05 | **0.544** |
| V3 + drafter, n-max 1 | 16.68 | 0.688 |

Two effects push the same way, both predicted by the round cost model:

1. **A faster base raises break-even acceptance.** The requant cuts a round's
   *fixed* bytes but not the per-verify-token expert bytes, so `T1` falls while
   the marginal verify cost does not. Break-even at n-max 2 moved from ~0.45 on
   stock to ~0.556 on V3; at n-max 1 it is ~0.670.
2. **Requantizing the target degrades draft acceptance**: 0.617 -> 0.611 (V2)
   -> 0.544 (V3). This is mechanistic. DFlash conditions on the *target's
   internal hidden states* at layers 1/10/19/29/38/47, and V3 is the first
   variant to requantize `attn_k`/`attn_v`, which changes the KV cache and so
   those states pervasively - where V2 only touched `attn_q`/`attn_output`. The
   drafter was trained against a full-precision target and is now off
   distribution.

At 0.544 against a 0.556 break-even the drafter lands the wrong side and costs
4%; at n-max 1 it is a wash.

**Carry forward: a feature-conditioned drafter (DFlash, EAGLE3) is coupled to
the target's quantization in a way a vocabulary-only drafter is not.
Re-measure acceptance after any change to the target file.**

The top three configs (17.00 / 16.89 / 16.75) are inside the noise of a
4-prompt median, so this is not a claim that V3-alone is fastest. It is a claim
that they tie and V3-alone is the better engineering: no drafter in the pool,
0.9 GiB smaller, best prefill of the three, and no prompt-dependent variance -
the four prompts returned 16.76/16.75/16.74/16.74 against 15.96-19.37 for
V2+drafter.

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

**...which stops being true at `parallel = 3` (2026-08-11).** That rejection
assumed the column count was ours to choose. It is not, once more than one slot
generates at a time: `server-context.cpp` puts every generating slot's sampled
token and its entire draft into one shared batch, so the columns `MUL_MAT_ID`
sees are `n_active_slots x (1 + n_draft)`, and no draft-length setting can hold
that under 8 while three slots are busy. At `parallel = 3` the aliases sit at 12
(`fast`), 9 (`kat-eval`) and 15 (`nerkyor-eval`) - all on the matrix path, all
the time, which is the same cliff that cost n-max 8 its 9%.

So the threshold is now a runtime knob rather than a constant, following the
`GGML_VK_MAX_NODES_PER_SUBMIT` pattern:

```sh
GGML_VK_MUL_MAT_VEC_ID_MAX_COLS=<n>     # default 8, upstream behaviour
```

An env var rather than an edit because the right value has to be swept and each
rebuild on this box costs a restart, which is the operation with the incident
history.

**Measured 2026-08-11, and it is worth ~2-3%, not 9%.** `12` is deployed in the
systemd unit. Two independent harnesses agree, and the effect is much smaller
than the n-max 8 data point suggested:

| harness | conc | cols 8 | cols 12 | cols 16 |
|---|---|---|---|---|
| spec-sweep (short prompts) | 3 | 29.96 / 29.77 | 30.82 | 30.81 |
| conc-probe (2641-tok source file) | 3 | 15.17 | 16.48 | - |

Three things that measurement establishes beyond the headline number:

- **`12` and `16` are identical** (30.82 / 30.81). That is the mechanism
  confirming itself: three slots at n-max 3 produce exactly 12 columns, so no
  value above 12 is reachable and nothing above it can matter.
- **Most of the apparent conc-3 gain is session drift, not the knob.** The
  conc-probe pair looks like +8.6%, but the conc-1 control - 4 columns, where
  the knob CANNOT apply - moved +6.2% across the same two sessions. Subtracting
  the control leaves ~2.4%, which matches spec-sweep's +2.9% on much tighter
  variance (0.6% between repeats). Always run conc 1 as a control here.
- **It is moot below three streams.** One and two streams are 4 and 8 columns,
  both already under the default 8.

Do not raise it past 12 on this lineup, and re-derive it from
`n_slots x (1 + n_max)` if either changes.

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

### The load window after a restart is as dangerous as one mid-decode (2026-08-07)

"Restart only when idle" is necessary but **not sufficient**, and the gap cost a
hard power cycle. The box was idle and the restart itself was clean; the orphan
came from a request sent ~45 s later, while the startup model was still loading.

With `models-max = 1`, a request for any other alias makes the router evict the
current one. If that one is still loading, it is force-killed mid-allocation:

```
srv  ensure_model: model name=coder is not loaded, loading...
srv    unload_lru: models_max limit reached, removing LRU name=fast
srv        unload: model name=fast is still loading, force-killing
srv    operator(): force-killing model instance name=fast after 10 seconds timeout
```

That child went uninterruptible `D` in `drm_suballoc_new`, holding 15.6 GiB of
GTT and **100% of VRAM**. It is a teardown deadlock: the dying process has to
allocate in order to free, and there is nothing left to allocate from. Host
kernel trace, repeating every 122 s:

```
INFO: task llama-server:645181 blocked for more than 614 seconds.
  amdgpu_ib_get -> amdgpu_job_alloc_with_ib -> amdgpu_vm_sdma_prepare
  -> amdgpu_vm_bo_update -> amdgpu_vm_handle_moved -> amdgpu_cs_ioctl
```

**Distinguish this from the ErrorDeviceLost class.** There is no hung job here,
so no ring timeout fires and `amdgpu.lockup_timeout` is irrelevant - dmesg shows
zero reset or recover events. `amdgpu_gpu_recover` cannot help for the same
reason, and `SIGKILL` cannot reap a `D`-state task. Only a hard power cycle
cleared it, same as the 2026-07-31 orphan.

The rule that actually covers both cases:

> After any `systemctl restart llama-server`, send nothing until the journal
> shows `srv llama_server: model loaded` followed by `listening on`.

```sh
journalctl -u llama-server -f | grep -m1 'llama_server: model loaded'
```

Swapping aliases is safe once a model is **fully** loaded - the eviction path is
only destructive against a child that is still loading. Verified clean
immediately afterwards across three swaps (`fast` 33.65 t/s with MTP acceptance
35/41, `coder` 26.6, `laguna-eval` 13.38).

Note `/slots` is not a sufficient idle check on its own: during startup load it
answers for the router, not the child, so it can look quiet while a load is in
flight. `/health` returning `ok` likewise does not mean loading has finished.

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

### MMVQ and upstream PR 25666

Measured 2026-08-01. PR 25666 ("vulkan: do not enable MMVQ for speculative-decode
steps on AMD") narrows `ggml_vk_should_use_mmvq`: it raises the `n > 1`
early-return to `n > 8` so speculative-verify batches fall through to the
per-vendor heuristics, and on AMD it requires `k >= 4096` rather than 2048 for
k-quants. Reported at +12.9% tg and +11pp acceptance on gfx1151 Strix Halo, the
closest RDNA3/UMA analog to this box. It applies cleanly to this tree.

It was bracketed rather than built, using `GGML_VK_DISABLE_MMVQ=1`, which forces
`should_use_mmvq` false for all n and k - a strict superset of what the PR does.
Nothing moved:

| model | A1 baseline | B: MMVQ off | A2 repeat |
|---|---|---|---|
| `fast` pp512 / tg128 | 333.17 +/- 2.66 / 25.35 | 331.69 +/- 2.61 / 25.37 | 333.30 +/- 2.15 / 25.35 |
| `assist` pp512 / tg128 | 424.36 +/- 2.88 / 36.03 | 424.80 +/- 2.90 / 35.92 | 424.51 +/- 3.62 / 36.02 |

`llama-bench`, backend column confirmed `Vulkan`. A1 and A2 agree to under 0.1%,
so the comparison is trustworthy and B sits inside stddev on both models. On the
server, `assist` (no speculation) was flat across A/B/A, and `fast`'s tg and
draft acceptance were unchanged - acceptance matched to five decimals between the
two A rounds.

A cancelling-effects reading was checked and ruled out: if disabling MMVQ helped
small batches but hurt large-n prefill, the two could mask each other. Prefill
was flat in every condition, so that is not happening. Since the superset
measures zero, the PR's narrower version cannot do better.

Two things worth keeping from this:

- **`fast` is not a Q4_K model.** Its expert tensors are a per-layer mix of Q6_K
  (230 tensors), Q5_K (30) and IQ4_XS (60), and `ggml_vk_should_use_mmvq` already
  excludes Q6_K from MMVQ on AMD unconditionally ("only a win on Intel"). Most of
  `fast`'s weight was never MMVQ-eligible, so it is a diluted test of anything
  MMVQ-related. `assist` is genuinely Q4_K-dominant and is the cleaner probe.
`coder` was tested separately, because unlike the other two it is genuinely in
the band the patch targets. Its GGUF is 57.2% Q4_K by weight (28.39 GB, the
`ffn_gate_exps` and `ffn_up_exps` tensors) and **every one of those tensors has
k = 2048**, exactly inside the [2048, 4096) window the AMD threshold change
covers. The remaining 35% is Q5_K `ffn_down_exps` at k = 512, already ineligible
either way. So for `coder` the patch would flip MMVQ off across most of the
generation phase, not just the speculative-verify window. The codepath is live
on this box: RADV reports `integerDotProduct4x8BitPackedSignedAccelerated`, and
the deployed `libggml-vulkan.so` contains the q8_1 MMVQ pipelines.

Measuring it was mostly defeated by the non-determinism recorded below - two of
three prompts diverged as much between two baseline rounds as between baseline
and treatment. One prompt was fully stable (identical 19-token output and 14/20
acceptance in every run), and there the comparison is clean:

| condition | tg |
|---|---|
| A1 baseline | 20.51 |
| B, MMVQ off | **19.57** |
| A2 baseline | 20.70 |
| A2 repeat | 20.79 |
| baseline x5 | 20.74 - 20.82 |

B sits below every baseline observation, about 5% down. That is a single B
sample and not conclusive on its own, but it points the same way as the
maintainer's counter-benchmark on the sibling PR 24966, which measured dense
k-quant regressions from the same idea. Taken with the flat results on `fast`
and `assist`, the evidence across the lineup runs from zero to slightly
negative. Do not apply PR 25666.

### q8_0 KV dequant and upstream PR 25494

Measured 2026-08-01, binary `b303f73` (build 205, `build-vk2`). PR 25494
("vulkan: dequant q8_0 KV once in coopmat1") dequantizes and transposes q8_0 K/V
once into an f16 scratch buffer instead of repeating that work per workgroup
inside the coopmat1 flash-attention shader. Upstream reports pp512 going
200 -> 282 t/s at d32768 and 99 -> 166 t/s at d65536 on qwen3moe 30B-A3B, and it
was independently reproduced by a Vulkan maintainer on an RTX 5090.

Every gating condition is met here, checked at runtime rather than from
`vulkaninfo`: RADV does advertise `VK_NV_cooperative_matrix2`, but the device
fails seven of the required feature flags, so llama.cpp's own `matrix_cores`
string reads `KHR_coopmat` in every run. q8_0 KV is the deployed default and
`-ctk q8_0 -ctv q8_0` is accepted rather than silently substituted. The patch
was still rejected, and it was rejected without building it.

**The method: bound the win with an f16 control.** After the patch, the FA
shader reads an f16 scratch buffer exactly as the native f16 path does, plus a
one-time dequant. So f16 throughput is the patch's ceiling - it can approach
f16 and never exceed it. Measuring f16 against q8_0 on the unpatched build
therefore bounds the maximum possible gain without writing any code.

`fast`, `llama-bench`, `-ngl 99 -fa 1 -ub 2048 -p 512 -n 64 -r 3`, backend
column confirmed `Vulkan`, two separate invocations so K and V always match
(comma-separated lists to `-ctk`/`-ctv` can generate cross combinations):

| condition | pp512 | tg64 |
|---|---|---|
| q8_0 @ d32768 | 166.92 +/- 1.81 | 20.87 +/- 0.10 |
| f16 @ d32768 | 168.47 +/- 1.76 | 20.60 +/- 0.07 |
| q8_0 @ d65536 | 110.99 +/- 0.10 | 17.89 +/- 0.06 |
| f16 @ d65536 | 112.18 +/- 4.55 | 17.44 +/- 0.01 |

The d32768 pair replicates an earlier session's 167.49 / 167.01 to within
stddev, so the control is reproducible across sessions, not a one-off.

**pp is the metric that decides this**, because the patch is gated to
`neq1 >= 64` and never engages during single-token decode. At d65536, where the
PR claims its largest win, f16 leads by a nominal 1.1% with a stddev of 4.55
that swamps the gap. q8_0 is already at its own ceiling at both depths. There is
nothing for the patch to recover. Do not apply PR 25494.

The tg column is not evidence about this patch and must not be read as such, but
it explains why the upstream result inverts here: q8_0 beats f16 by 2.6% at
d65536, outside noise on both stddevs. q8_0 KV reads half the bytes, and at
74 GB/s that saving outweighs the dequant cost. The reference machine has
bandwidth to spare and is dequant-compute bound, which is the opposite balance.

**Keep the f16-control method.** It settled a patch in one bench run instead of
a port, a build and an A/B. It generalizes: any change whose mechanism is
"convert quantized KV into f16 and then proceed normally" is ceilinged by the
f16 path, so measure that ceiling first. Combined with the `GGML_VK_DISABLE_MMVQ`
bracket used on PR 25666, two upstream candidates have now been settled without
porting either.

Full depth sweep from the same build, for reference when judging future FA work:

| model | KV | d0 | d8192 | d32768 | d65536 |
|---|---|---|---|---|---|
| `fast` pp512 | q8_0 | 343.80 | 265.99 | 167.49 | 111.30 |
| `fast` tg64 | q8_0 | 25.31 | 24.12 | 20.93 | 17.86 |
| `coder` pp512 | q8_0 | 228.91 | 190.54 | 126.27 | 87.11 |
| `coder` tg64 | q8_0 | 18.58 | 17.67 | 15.74 | 13.68 |

Note `coder` peaked at 32.94 GiB GTT even at d65536. qwen3next runs full
attention on only 12 of 48 layers, the rest being GDN with context-independent
recurrent state, so its q8_0 KV at that depth costs roughly 800 MiB rather than
several GiB. Do not generalize that headroom to conventional-attention models.

### Greedy decode is not reproducible on `coder`

Measured 2026-08-01, and it invalidates a test that would otherwise look sound.

At `temperature: 0, top_k: 1` with an identical cached prompt, `coder` does not
generate the same tokens run to run. Two baseline rounds of the same config
diverged in completion length and draft acceptance by as much as a baseline-vs-
treatment comparison did, and the divergence reproduced within a single server
process with no restart in between. The cause is floating-point reduction order
in batched, parallel-slot Vulkan execution: an occasional argmax flips, and the
whole trailing trajectory follows it somewhere else, changing EOS timing and the
acceptance denominator with it.

This is alias-specific. `fast` under MTP was reproducible in the same session -
its acceptance matched to five decimals between rounds - so do not assume either
behaviour without checking the alias you are actually measuring.

Consequences:

- **A token-for-token determinism check is not a valid non-regression test on
  `coder`.** It will report differences that have nothing to do with the change
  under test. It remains valid on `fast`.
- Long generations make it worse, because a trajectory needs room to diverge.
  Keep `n_predict` short when comparing acceptance, or pin the token count with
  `ignore_eos` so at least the denominator is fixed.
- Prefer prompts whose output is short and stable for any A/B. Finding one is
  worth the effort; the stable short prompt above was the only usable comparison
  out of three.

### A second failure mode: DeviceLost on spec-model load

Seen once, 2026-08-01, and distinct from the `probe-server.sh` stall above. It is
also distinct from the ring-timeout `ErrorDeviceLost` below, which is the common
one: this fails at *load* with an allocation error and an idle GPU, that one
fails mid-request at depth with a `ring comp_* timeout` in the host kernel log.

During the DFlash draft model's load-time sanity decode, the server logged
`radv/amdgpu: Not enough memory for command submission` followed by
`vk::DeviceLostError`, and left the router waiting on a zombie child. The tell
that separates it from the stall: **the GPU was idle at 0%, not pegged at 92%**,
with no `D`-state process and clean memory (GTT 0.013 GiB, VRAM 0.068 GiB). So
it is an allocation failure at submission time, not a runaway kernel.

It followed four service restarts inside about ten minutes, so rapid restart
cycling stressing the RADV allocator is the suspected trigger, unconfirmed.
Recovery was the documented sequence and it worked: idle check, `systemctl stop`
(which again took the full `TimeoutStopSec` and needed the SIGKILL escalation,
logging `Result: timeout`), GTT and VRAM drained fully, `systemctl reset-failed`,
then a restart that succeeded first try. If you are restarting repeatedly while
testing, space the restarts out.

### ErrorDeviceLost at depth is the compute-ring watchdog (2026-08-05)

Root-caused and fixed 2026-08-05. **This supersedes the earlier attribution to
the MTP draft KV cache**, which is wrong - see "correcting the record" below.
The comments in `router.ini` and the incident writeup in `candidates.md` still
carry the old explanation.

Symptom, seen from the LXC:

```
radv/amdgpu: The CS has been cancelled because the context is lost. This context is innocent.
E srv  update_slots: decode() failed: vk::Queue::submit: ErrorDeviceLost
```

The `innocent` is a red herring - it only reflects that amdgpu took the
per-queue reset path rather than a device-wide one, not that some other process
was to blame. The real evidence is on the Proxmox host, and it names us:

```
amdgpu 0000:c4:00.0: ring comp_1.2.0 timeout, signaled seq=11104763, emitted seq=11104765
amdgpu 0000:c4:00.0:  Process llama-server pid 752878
amdgpu 0000:c4:00.0: Starting comp_1.2.0 ring reset ... Ring comp_1.2.0 reset succeeded
amdgpu 0000:c4:00.0: [drm] device wedged, but recovered through reset
```

**Check `journalctl -k` on the host (`192.168.254.222`), not just the LXC.** Ten
ring timeouts fired between Aug 03 and Aug 05; only seven of them appear in
`journalctl -u llama-server`, because a crashed model child does not always get
to log. `emitted = signaled + 2` in every one is just `sched_hw_submission = 2`
(the ring depth), not a clue - it means the ring was full and the head job never
signalled.

Cause: **a single Vulkan compute submission ran past amdgpu's 2000 ms default
lockup timeout.** Two independent lines of evidence for the 2 s figure:

- `modinfo amdgpu | grep lockup_timeout` on this kernel (7.0.14-8-pve) reads
  `default: 2000`, and `/sys/module/amdgpu/parameters/lockup_timeout` was empty,
  so the default was in force. Note this differs from mainline, which uses 10 s
  for graphics and 60 s for compute - do not assume the mainline value.
- The Aug 04 22:51 event: the previous ubatch's fence signalled at 22:50:50 and
  the ring timed out at 22:51:15, so the failing job's entire lifetime was under
  25 s. A 60 s compute timeout is arithmetically impossible.

And the work per submission is genuinely that large. At ~106k context a
2048-token ubatch takes ~27 s wall clock (82 -> 77 t/s in the log) and
flash-attention over the full KV dominates it, so one `FLASH_ATTN_EXT` node runs
in the high hundreds of ms. The Vulkan backend cannot cut that: it caps a
submission at `2 GFLOP x shader_core_count` for weak AMD parts (24 GFLOP at 12
CUs) but then doubles that cap three times, and in any case **a single node
cannot be split across submissions**. With ring depth 2 a job's watchdog starts
while its predecessor is still running, so two consecutive FA dispatches share
one 2 s budget.

Everything fits: the failures are depth-dependent (`n_tokens` at failure was
67160, 106011, 115537, 127774), prefill-heavy, recoverable by a queue reset
rather than a device reset, and completely model-independent.

**Correcting the record.** The earlier writeup blamed Thinking-Distill's MTP
draft KV running at `f16` instead of `q8_0`, and that model lost the `fast`
alias twice and had its weights deleted over it. It is exonerated:

- Aug 03 21:05 and 22:08 hit **`coder`** (`nerkyor-dsv4pro-q4.gguf`), which has
  no MTP head, no drafter and no speculation of any kind. Both predate the
  Thinking-Distill swap entirely.
- Three more fired Aug 05 01:30 to 02:08, after `nerkyor-eval` was killed.

The `spec-draft-type-k/v = q8_0` setting is still worth keeping for the memory
it saves (see the table above), but it was never the fix for this.

**Fix 1 (host, primary):** `amdgpu.lockup_timeout=10000,60000,10000,10000` on
the kernel cmdline. See "Host prerequisites". Applied 2026-08-05.

**Fix 2 (config, held in reserve):** if it recurs even at 60 s, bound the
worst-case dispatch directly - `ctx-size` back to 131072, or `ubatch-size` 2048
-> 1024 on the deep aliases. FA dispatch time scales linearly with ubatch. Both
cost measured pp, which is why neither was applied first.

**Fix 3 (code, applied):** the loss used to be unsurvivable *and* silent.
Nothing in the Vulkan backend recreates a lost `VkDevice`, and
`server-context.cpp` catches the exception and reports a request error, so the
instance kept serving a dead device until an uncaught throw from a path with no
`vk::SystemError` catch finally killed it. On Aug 04 that took **26 minutes**:

```
12:35:26  decode() failed: vk::Queue::submit: ErrorDeviceLost
13:01:37  terminate called after throwing an instance of 'vk::DeviceLostError'
13:01:44  (router respawns the child)
```

`ggml_vk_queue_submit()` in `ggml/src/ggml-vulkan/ggml-vulkan.cpp` now converts
`vk::DeviceLostError` into a `GGML_ABORT` at the point of failure, matching how
the file already handles other unrecoverable Vulkan errors. Every submit in the
backend routes through `vk_queue_handle::submit`, so the two overrides are the
only call sites needed. The child now dies in seconds with an attributable
message and the router respawns it, instead of wedging. Upstreamable as-is.

**What to watch.** `journalctl -k` on the host for `ring comp_* timeout`. A
`Fence fallback timer expired on ring comp_*` line is a near-miss (a missed
interrupt the fallback timer caught) and is worth noting but is not a hang - one
appeared Aug 05 05:14.

### Prompt processing through the server is not a stable measurement

Measured 2026-08-01, and it invalidates a whole class of comparison.

On `fast`, server-measured pp swung 264.7 -> 253.8 -> 310.9 t/s across an A/B/A
in which A and B differed only by an environment variable that measured zero
everywhere else. That is a 17% spread between two identical conditions. In the
same session `llama-bench` on the same model measured 333.17 then 333.30 t/s,
+/- 2.6.

Stable under `llama-bench` and unstable through the server means the variance
lives in llama-server's prefill path - slot selection, LCP cache reuse, ubatch
scheduling - and not in the GPU, the driver, or memory bandwidth. An earlier
`coder` reading of 182-188 t/s against a 220-235 baseline has the same signature
and is most likely the same effect rather than hardware degradation.

Consequences:

- **Use `llama-bench` for any pp comparison.** It reports stddev and it is
  reproducible. `probe-server.sh` pp is not.
- **`probe-server.sh` remains correct for tg and draft acceptance**, which were
  stable and reproducible across every round here.
- Measure A/B/A, never A/B. A single A/B here would have reported a 4% pp
  regression from B that the second A shows was drift.
- A single low sample is not a regression. One `fast` sample dropped to
  acceptance 0.644 and tg 28.97 in one round and did not reproduce in either A
  round or in the other two B samples. Repeat before believing it.

### On ROCm

ROCm 7.2 works via `HSA_OVERRIDE_GFX_VERSION=11.0.2` (rocBLAS ships no gfx1103
TensileLibrary, so it must masquerade as gfx1102). It is not recommended:
generation is consistently slower, and KFD advertises only what `ttm.pages_limit`
allowed at driver init, so large models fail or hang. Vulkan sees the full pool.

## Host prerequisites

Kernel cmdline (Proxmox host), then reboot:

```
amd_iommu=on iommu=pt amdgpu.gttsize=61440 amdgpu.no_system_mem_limit=1 \
transparent_hugepage=always ttm.pages_limit=15728640 \
amdgpu.lockup_timeout=10000,60000,10000,10000
```

`ttm.pages_limit` is in 4 KiB pages: GiB x 262144. 15728640 = 60 GiB. This is the
binding limit - `amdgpu.gttsize` alone is deprecated and does not raise the TTM
cap. Keep the two aligned or the kernel logs a mismatch warning.

`amdgpu.lockup_timeout` is `GFX,Compute,SDMA,Video` in ms. This module's default
is 2000 ms for all four, which is a graphics frame deadline and is far too short
for the multi-hundred-ms compute dispatches this workload submits at depth - it
was the cause of the recurring `ErrorDeviceLost` documented below. Compute goes
to 60 s; the box is headless, so nothing depends on a short watchdog. Verify it
took after reboot with `cat /sys/module/amdgpu/parameters/lockup_timeout`, which
reads back **empty** when the default is in force.

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
systemctl restart llama-server        # only when idle, then wait for the load - see below
journalctl -u llama-server -f | grep -m1 'llama_server: model loaded'
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
journalctl -u llama-server -f | grep -m1 'llama_server: model loaded'   # wait, do not skip
./bench.sh <model>                    # confirm ubatch 2048 is still optimal
./probe-server.sh coder 6             # real serving speed, incl. speculation
```

Three things to know:

- **Restart only when idle, then wait for the load to finish.** Tearing down
  mid-decode can wedge a model child in the GPU driver, and so can a request
  that arrives while the startup model is still loading - `models-max = 1`
  force-kills a still-loading child to make room. Both wedges cost a hard power
  cycle. Check idle with `curl -s localhost:8080/slots`, then wait for
  `journalctl -u llama-server -f | grep -m1 'llama_server: model loaded'` before
  sending anything. See "The load window after a restart is as dangerous as one
  mid-decode" and "Watch for silent CPU fallback".
- **Re-verify after any llama.cpp or Mesa change.** Optimal ubatch moved the last
  time Mesa was upgraded, and the speculation settings are build-specific. A new
  build is a reason to re-run `bench.sh`, not to assume the numbers hold.
- **If the pull refuses**, the working tree has drifted (a stray `chmod` is the
  usual cause). This checkout is a mirror and holds nothing you need - the live
  config lives in `/etc/llama/` - so discard and retry:
  `git -C /root/llama.cpp checkout -- . && git -C /root/llama.cpp pull --ff-only`

## Models

**Evaluating a new candidate: follow `EVAL-PLAYBOOK.md`.** It is the order of
operations for deciding whether a model should take an alias here, and every
rule in it exists because skipping that rule produced a wrong answer at least
once. The short version: vet on paper, fetch with checksums, give it an eval
stanza and never a production alias, tune the drafter per model on real prompts
at the concurrency you serve, confirm on 8080 because the spare port lies,
compare against the incumbent **in the same session** because temperature 0 is
not determinism here, establish perplexity signs by paired per-chunk ordering
rather than the final estimate, test the quant tier before blaming the model,
and soak only what you intend to ship.

Always verify checksums. Use `fetch-model.sh`, which checks the SHA256 from the
HF API and retries. Parallel downloaders against HF's Xet CDN can produce files
that are the correct length but byte-damaged; a damaged GGUF still loads and
still benchmarks at full speed, it just emits garbage.

`ctx-size` was raised 131072 -> 262144 2026-08-04 for `fast`/`coder`/`assist`/
`nerkyor-eval`, matching each GGUF's own `context_length` metadata
(`gguf_dump.py --no-tensors`, all four report 262144 natively - none of this
was YaRN-extrapolated beyond what the model declares). `deep` stays at 131072:
that is gpt-oss-120b's own GGUF-declared ceiling, already YaRN-extended from a
4096 base per its `rope.scaling.*` metadata, so there is no larger native
context to move to. Each raised alias was verified loadable standalone at the
new ctx-size on a spare port before this went into `router.ini` - `fast`
(with its MTP draft context, the most memory-hungry case) measured ~30.5 GiB
GTT+VRAM alone, `assist` (full attention, no speculation) ~33 GiB, both
comfortably inside the 76 GiB pool with `models-max = 1`. None of this has
been exercised past 131072 in the eval scripts yet - depth-sensitive settings
(draft acceptance, `p-min`) were tuned at shallower depths and may want
revisiting if this box starts serving conversations that actually reach into
the new range.

**Lineup cut to three on 2026-08-14.** `coder` and `assist` were removed and
their weights deleted, gpt-oss-120b lost `deep` to Laguna, and every eval slot
was retired. What survives:

| Slot | Model | Why |
|---|---|---|
| **`balanced`** | Thinking-Distill Q6_K + mmproj, 27.2 GiB | **THE DEFAULT**, the only load-on-startup alias. 10/10 with zero truncations on `reason-eval-hard` in 207 s, against `fast`'s 8/10 with two truncations in 987 s. Vision, and answers the two-image compare item 3/3 in 188 deterministic tokens where `fast` truncates it |
| `fast` | Ornith-1.0-35B MTP-APEX + mmproj, 21.9 GiB | kept for raw speed: 33.96 tg / 347.8 pp against `balanced`'s 30.66 / 296.4. Weakest hard reasoner of the three |
| `deep` | Laguna-S-2.1 attn-IQ4_XS v3, 44.22 GiB | long-horizon autonomous coding. Text-only, no speculation (DFlash measures +0.9% for 2.2 GiB), lower quant tier than the others - weigh results accordingly |

Deleted with the cut, and worth knowing what was given up: **`coder`** measured
best of anything on this box on 2026-08-14 once its published mmproj was loaded
- 10/10 reasoning AND 4/4 vision at 24.8 GiB, beating `fast` on both quality
axes while 6 GiB lighter. **gpt-oss-120b** held `deep` at 10/10 on the hard
tier. Both are recoverable by re-download; the measurements are in
`candidates.md`.

**`coder-eval` was restored 2026-08-14 by request and removed again 2026-08-16
by request** - the Q4-imatrix weights plus the repo's own
`mmproj-Qwen3.6-35B-A3B-Q8_0.gguf`, that is, the config `coder-vision-eval`
measured rather than the text-only one production `coder` actually shipped. It
was an eval slot for two days, never `load-on-startup`, never promoted. Q5 was
not restored either, having bought 0.76% perplexity and no measurable
capability. What it cost against the survivors is throughput: 25.71 tg
unspeculated, ~24% under `fast` and ~16% under `balanced`, which is why it lost
the cut in the first place. Re-downloadable; promoting it would need the full
playbook against today's `balanced` in the same session, plus the soak it has
never had.


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
./check-vision-tools.sh assist    # tool calling + image input, smoke test
./check-vision-agentic.sh assist  # vision at agent depth - read/locate/compare/act
./probe-server.sh assist 6        # real serving throughput
```

`check-vision-tools.sh` proves the mmproj is wired and nothing more. Run
`check-vision-agentic.sh` before trusting vision on any alias that will serve
screenshots: it reads rendered text out of a UI image, compares two screenshots,
and requires a tool call carrying a value read from pixels. The two-image
`compare` item is the one that discriminates - measured 2026-08-14, `fast`
passes it 3/3 and Thinking-Distill 0/3, a gap the colour-swatch smoke test
cannot see. It runs over `/v1/messages` by default because that is the path
Claude Code and Hermes use, with `TRANSPORT=oai` as a control.

The agentic-coding ladder is `code-eval.sh` -> `code-eval-hard.sh` ->
`code-eval-claude.sh`. The last replaced `code-eval-opencode.sh` on 2026-08-14,
when opencode stopped being a client here; it uses Claude Code's tool surface
and enforces read-before-edit and the `cat -n` line-number convention, neither
of which any other tier tests. The opencode tier is kept but superseded, since
its numbers are quoted throughout `candidates.md`.

Measured on this hardware, generation with a 2.4k-token prompt:

| alias | pp | tg | vision | tools | reasoning |
|---|---|---|---|---|---|
| `balanced` | 296 t/s | 30.66 t/s | yes | yes | **yes - 10/10, 0 truncations, 207 s, 20.4k chars** |
| `fast` | 348 t/s | 33.96 t/s | yes | yes | yes, but **8/10 with 2 truncations**, 987 s, 93.6k chars |
| `deep` | see candidates.md | 13.38 t/s | no | yes | not measured on the hard tier at this tier |
| ~~`coder-eval`~~ | 312 t/s | 25.71 t/s | yes (mmproj) | yes | **yes - 10/10, 0 truncations, 254/276 s** |

The `coder-eval` row is kept struck through rather than deleted: the alias was
removed and its weights deleted 2026-08-16, but that column is the calibration
a future candidate gets scored against - 10/10 hard reasoning at 24.8 GiB
resident is still the best quality-per-byte measured on this box.

**A note kept because the lesson outlives the alias: `coder` was listed here as
`reasoning: no` and as text-only, and both were wrong.** It carries `reasoning-format = deepseek`, emits ~20k chars of reasoning
per pass, and scores 10/10 with zero truncations on `reason-eval-hard` - twice.
It is the strongest hard-reasoning alias on this box that is not `deep`, it is
the lightest at 24.0 GiB resident, and the error stood for eleven days while
this repo searched for a model that could beat `fast` on exactly that axis. Send
hard reasoning here, not to `fast`, unless the work needs vision. `fast`/`assist`
numbers re-measured the same day; the older 317/34.6 and 235/25 figures predate
`parallel` 2 -> 3.

A temporary `td-q6-eval` slot holds nerkyor
Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill at **Q6_K**. **Adjudicated 2026-08-14:
`fast` keeps the alias, and the Q4_K_M tier was removed.**

The Q4 tier served here as `nerkyor-eval` and lost outright. Re-measured through
the production router at a corrected draft length (n-max 4 -> 2; 4 was worse than
not speculating at all at two streams), its recorded throughput lead of 13-18%
was really 1.7%, it was **worse than `fast` on perplexity** at 61 of 61 paired
chunks, and it was unreliable on multi-image vision - 0/3 where `fast` scores
3/3, twice non-terminating at 28-32k chars. Weights deleted; alias removed.

Q6_K fixes the vision problem (3/3, 188 byte-identical tokens, better than
`fast`'s 237) and keeps the hard-reasoning win (10/10 in 207 s against `fast`'s
8/10 in 987 s with two truncations). It costs ~10% of served generation
(30.66 vs 33.96 t/s), ~15% of prefill, and 5.3 GiB of pool. On perplexity it and
`fast` are **indistinguishable** - 51 of 61 paired chunks with the ordering
reversing, which is a wash by this repo's own standard - so the case for it rests
entirely on task results, not on underlying model quality.

That trade is not taken. Not load-on-startup, not wired to any client; select it
with `"model": "td-q6-eval"`. It still owes a soak on this tier. Full writeup,
including the determinism caveat that governs how any of these numbers may be
compared, is in `candidates.md` under "Re-adjudicating Thinking-Distill for
`fast`".

A second temporary slot, `kat-eval` (Kwaipilot/KAT-Coder-V2.5-Dev, MTP-grafted
UD-Q4_K_XL), holds a `coder` candidate: 332.9 t/s / 29.24 t/s served, 4/4, 6/6
and 7/8 across the three coding tiers with zero edit misses. Its turn counts
(14 / 20 / 32) are the lowest any model has recorded here, which matters more
than the tied scores - session latency is turns x per-turn time. Text-only, so
it cannot replace an alias that needs vision. Same handling as above: not
load-on-startup, selectable with `"model": "kat-eval"`.

`fast` is the default choice for almost everything: it beats `coder` on every
published SWE-bench variant while generating 38% faster in half the footprint,
and it ties `deep` 8/8 on `reason-eval.sh`. `assist` is kept only for its
prefill lead, which matters on the very large contexts an agent client builds
up.

That 8/8 tie is an artifact of the eval, not a real equivalence - see the next
section, which was written to break it and does.

### The hard tier separates `fast` from `deep` (2026-08-02)

`reason-eval.sh` saturates: `fast` and `deep` both score 8/8, so it cannot
justify keeping a 117B model that costs 60 GiB and a 31 s swap, and it cannot
score a candidate claiming to beat it. `reason-eval-hard.sh` is ten problems
picked so a strong 35B is expected to miss several - derivations the common
pattern gets wrong (a recurrence outside the master theorem, the x86-TSO
store-buffer litmus test, the Lamport-clock converse) plus named subtleties at
the obscure end. Same harness, temperature 0, `max_tokens` 8000, all three
passes back to back on an idle box:

| | `fast` | `deep` (default effort) | `deep` (effort=high) |
|---|---|---|---|
| score | 8/10, **2 truncated** | **10/10, 0 truncated** | **10/10, 0 truncated** |
| wall time, all 10 | 999 s | **208 s** | 307 s |
| reasoning emitted | 95,650 ch | **8,558 ch** | 22,234 ch |
| generation | 33 t/s | ~19.6 t/s | ~19.6 t/s |

**`deep` is five times faster to a complete set of answers while generating at
60% of the token rate**, because it emits 11x less reasoning. Token economy
dominates raw throughput on this slot by a margin large enough that no
bandwidth-side tuning could close it.

Both of `fast`'s losses are truncation, not a wrong answer, and one of them is
damning on its own: it spent 29,786 chars failing to name reservoir sampling,
which `deep` answers in 4.7 s and 240 chars. That is a runaway, not a hard
question. RETRY-PENDING

**`reasoning_effort: high` buys nothing here**: identical 10/10 for 2.6x the
reasoning and 48% more wall time. Leave `deep` at the template default for
problems of this shape. Whether high effort earns its cost on open-ended design
work is untested.

Two consequences worth carrying forward:

- **`deep` is not redundant against `fast`.** The lineup note that `coder` and
  `deep` are arguably redundant holds only against the saturated eval. On
  problems that discriminate, `deep` is both more accurate and faster to an
  answer.
- **`fast` shows the same failure mode that rejected Ornith-3.6 and
  MiniMax-M2.1** - exhausting the budget without concluding - just on harder
  problems than tier 1 contains. Apply that rejection criterion to candidates
  knowing the incumbent is not immune to it.

The tier saturates `deep` at 10/10, so it justifies the slot but cannot rank
two `deep`-class candidates against each other. A shortlist for this slot needs
harder items again. The bar for any replacement: 10/10, under ~210 s, under
~10k chars of reasoning.

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

- `parallel = 3` - background requests land on a second slot; the third is for a
  second independent client (see below)
- `kv-unified = true` - all slots share the full ctx-size pool instead of splitting it
- `cache-ram = 16384` - displaced prefixes restore from RAM instead of reprocessing

### Two clients at once (2026-08-11)

`parallel = 3` is what lets a second consumer - Hermes Agent, say - work against
the model a claude-local session already has resident. Two constraints decide
whether that is fast or pathological:

**Both clients must name the SAME alias.** `--models-max 1` means one model is
resident; naming a second alias evicts the first, per turn, forever. `assist` is
described elsewhere in this file as the Hermes slot, and that is only true when
nothing else is running - `fast` carries vision too, so point Hermes at whatever
alias the session holds rather than at `assist`. Evicting a model that is still
loading is what produced the 2026-08-09 retry storm and, in a worse variant, the
D-state deadlock that needed a hard power cycle.

**The ctx pool is shared, not per-slot.** `kv-unified` means the sum of all live
conversations has to fit inside `ctx-size`, so two agents can hold ~130k each at
262144, not 262144 each. The tell that you have crossed it is slot displacement
and full reprefills in `journalctl -u llama-server`; `cache-ram` softens that but
does not remove it.

Also worth knowing: claude-local alone will not use the extra slots. It pins
`tool_concurrency` and `max_concurrent_subagents` to 1 and sets
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, so it holds one request in flight. The
third slot is for the second client, not for making a single session faster.

**Concurrency here SHARES throughput, it does not add any (measured
2026-08-11).** This is the result to set expectations by. Production-shaped
requests, `fast` at its deployed config, aggregate tokens over wall clock:

| streams | aggregate t/s | per-stream tg |
|---|---|---|
| 1 | 15.37 | 30.09 |
| 2 | 15.40 | 15.03 |
| 3 | 15.17 | 9.60 |

Aggregate is flat to within noise while per-stream falls as almost exactly
`1/n`. The box is bandwidth-saturated by a single stream, so a second client
does not get free capacity - it takes half of the first client's. That is still
the right trade for the case this was built for, because the alternative is a
second client queueing behind a whole agent turn, but it is fair-sharing rather
than added capacity, and `parallel = 3` buys nothing at all for one client.

Cross-check on single-stream production before and after the change:
347.2 pp / 35.13 tg -> 347.5 pp / 35.22 tg. The extra slots cost nothing when
idle; they cost ~1.6 GiB of recurrent state (13.2 -> 14.9 GiB GTT).

**The optimal draft length is regime-dependent, and `n-max 3` is the
single-stream answer, not the concurrent one.** Same harness, `fast`, per-stream
tg:

| streams | n-max 3 | n-max 1 |
|---|---|---|
| 1 | 31.82 | 30.56 |
| 2 | 15.03 | 18.17 |
| 3 | 10.86 | 12.92 |

That table is on synthetic prompts and it is wrong - see the warning below.
**Re-measured with real prompts through the production router, `n-max 2` is the
answer for two clients and it is deployed (2026-08-11):**

| n-max | 1 stream tg | 2 streams tg | 2 streams aggregate |
|---|---|---|---|
| 2 | 33.97 | 18.55-19.23 | 17.64-17.70 |
| 3 | 35.59 | 17.68 | 16.49 |

A trade, not a free win: -4.6% at one stream for +8.8% at two, break-even
around 35% of wall clock spent at two streams. `p-min 0.3` was re-swept at the
new draft length and is still the peak (0 -> 18.47, 0.3 -> 18.67, 0.5 -> 17.10,
0.75 -> 17.53 on the spare port); 0.75 buys acceptance 0.949 nobody needed.

**Two harness traps, both of which produced a wrong answer here.** The first
cost nothing because it was caught; assume the next one will not be.

1. *Synthetic prompts invert the verdict.* `spec-sweep.sh`'s built-in prompts
   return acceptance 0.61 where a real source file returns 0.85. On them
   `n-max 1` looked like a flat +25% win at three streams and +21% at two. With
   `PROMPT_FILE` set, `n-max 1` is not even the peak - `n-max 2` is. Acceptance
   0.857 at one stream is the tell that the harness is reproducing production,
   since that matches the 0.85-0.87 this alias has always documented.
2. *The spare port does not reproduce single-stream production.* At ctx 32768
   without `cache-ram`, `n-max 2` and `3` measured 34.05 vs 33.88 - a tie. On
   the real router at ctx 262144 they are 33.97 vs 35.59, a 4.6% regression the
   sweep could not see. Sweep on the spare port, then **confirm the winner on
   8080 before deploying it.**

**Do not tune draft length on `spec-sweep.sh`'s built-in prompts.** They are
short and synthetic and return acceptance 0.61 where a real 2641-token source
file returns 0.85. On those prompts `n-max 1` looked like a flat +25% win at
conc 3; at production acceptance the same comparison is +19% concurrent and -4%
single-stream. Draft-length economics are dominated by acceptance, so measure
with `probe-server.sh`-shaped input before changing `spec-draft-n-max`.

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
