# Model candidates

Researched 2026-08-02, sweeping specifically for the `deep` slot. Read
`README.md` first — everything in its "Tested and rejected" section is out of
scope and must not be re-proposed unless something material changed (noted
inline where checked).

> **On "exceeds pool" rejections:** as of 2026-08-15 that phrase is ambiguous.
> See "Colibri" at the end of this file — for four architectures there is now
> an engine that streams experts from disk, so the binding limit becomes the
> 931.5 GB drive rather than the 76 GiB pool. Say which gate you mean.

**Headline: nothing found beats gpt-oss-120b for `deep`.** The one candidate
worth further attention, Qwen3.5-122B-A10B-MTP, has a genuinely better score on
an unsaturated benchmark and a native MTP head this tree already wires for its
exact layout, but costs 40-55% of served throughput and carries a directly
relevant family precedent for reasoning verbosity. It is worth a cheap header
check before a 57.7 GiB download, not worth downloading blind.

## Read the throughput estimate with a correction factor

```
tg_ceiling = 74 GB/s / (active_params x bytes_per_param)
```

Never reached. Across five models measured on this hardware the realized
fraction lands **0.45 to 0.75** of ceiling, and position in that band tracks
routing overhead:

| model | active | bytes/param | ceiling | measured base tg | ratio |
|---|---|---|---|---|---|
| `fast` (Ornith-1.0-35B-A3B) | 3B | 0.672 | 36.7 | ~22 | 0.60 |
| `deep` (gpt-oss-120b, MXFP4) | 5.1B | 0.542 | 26.8 | 19.6 | **0.73** |
| `coder` (Qwen3-Coder-Next 80B-A3B) | 3B | 0.617 | 40.0 | 18 | **0.45** |
| Ornith-Agents-A1-3.6 (rejected) | 3B | 0.630 | 39.1 | 28.66 | 0.73 |
| MiniMax-M2.1 IQ1_S (rejected) | 10B | 0.205 | 36.0 | 19.37 | 0.54 |

128 experts (gpt-oss) sits at the top; 512 experts plus a hybrid attention
stack (`coder`) sits at the bottom. High expert count + hybrid attention both
push a candidate toward 0.45. The method works and is not sufficient — both
2026-08-01 candidates landed inside their predicted bands and were both still
rejected, on quality grounds the formula cannot see.

### Depth scaling — check before recommending

`tg_ceiling` says nothing about how KV reads scale as context fills:

| model | full-attention layers | tg d0 -> d32768 |
|---|---|---|
| `fast` | 41 of 41 | 25.3 -> 20.9 (-17%) |
| `coder` | 12 of 48 (hybrid GDN) | 18.5 -> 15.7 (-15%) |
| MiniMax-M2.1 | 62 of 62 | 19.37 -> 6.75 (-65%) |

Read the attention-layer pattern out of `config.json`, count full-attention
layers, and compute the q8_0 KV footprint at 131072 before anything else.
Fitting in the pool is the easier, separate question — MiniMax fit comfortably
and was still unusable.

## The `deep` slot's bar, as of 2026-08-02

Incumbent gpt-oss-120b MXFP4, 117B/5.1B active, ~60 GiB, pp 242 t/s, tg
19.6 t/s, native `reasoning_effort`. On `reason-eval-hard.sh` (the tier built
specifically because `reason-eval.sh` saturates both `fast` and `deep` at
8/8): **10/10 in 208 s, 8,558 chars of reasoning**, against `fast` at 8/10 in
999 s, 95,650 chars. `deep` reached a complete set of answers five times
faster while generating at 60% of `fast`'s token rate — an 11x reasoning-length
difference swamped a 1.7x speed difference. `reasoning_effort: high` buys
nothing on this tier: identical 10/10 for 2.6x the reasoning and 48% more wall
time.

**The bar for any replacement: 10/10, under ~210 s, under ~10k chars of
reasoning.** The tier saturates gpt-oss, so it justifies the slot but cannot
rank a claimed improvement above it — a harder discriminator (SWE-bench Pro,
ARC-AGI-2, GPQA Diamond, Terminal-Bench 2.0) has to be the argument for
anything claiming to beat it, not another 10/10.

---

## Priority order

| # | model | arch | total/active | quant+size+bpw | experts | full-attn layers | MTP/drafter | est. tg range | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Ling-3.0-flash | `bailingmoe3` | 124B/5.1B | IQ3_XXS, 47.7 GiB, 3.30 bpw | 512 (top-8) + 1 shared | **7 of 42** (35 KDA linear + 7 MLA) | native MTP, bundled in every GGUF | **~21-27 t/s w/ MTP** (16-20 base) | strongest `deep` candidate found - but **arch is in no shipping llama.cpp**; do not download yet. **Re-checked 2026-08-11:** tool calling now fixed, but the Vulkan freezes are on Strix Halo (this box's GPU family) and are the binding blocker - see the 2026-08-11 section at the end |
| 2 | Qwen3.5-122B-A10B | `qwen35moe` | 122B/10B | UD-IQ4_XS, 57.7 GiB, 4.06 bpw | 256 (top-8) | 12 of 48 (GDN hybrid, interval 4) | native MTP, confirmed in-tree | **8.5-11.6 t/s w/ MTP** (6.6-8.0 base) | interesting, not yet worth downloading blind |
| 3 | Nemotron 3 Super 120B-A12B | `nemotron_h_moe` | 120B/12B | UD-Q2_K_XL, 50.9 GiB, 3.64 bpw | unclear (Latent MoE, count unpublished) | few (mostly Mamba-2, small number of attn blocks) | native MTP claimed | **~7-12 t/s w/ MTP**, wide error bars | insufficient evidence — watch |
| — | MiniMax-M2.7 | `minimax-m2` | 229B/10B | UD-Q3-class, ~55-60 GiB | 256 (top-8) | **62 of 62** | DFlash now published | n/a | reject — same 62/62 depth collapse as M2.1, unchanged |
| — | Laguna S 2.1 | `laguna` | 118B/8B | smallest ~49 GiB (4-bit) | ? | ? | official DFlash | n/a | reject — wrong slot (coding-agent, not reasoning) and too tight against pool |
| — | GLM-4.7-Flash | `glm4moe` | 30B-A3B | — | — | — | declared, unconfirmed fixed | n/a | already tested/rejected on this box (`failed to create MTP context`); no material fix found |
| — | Kimi K3 | `kimi-linear` | 2.8T/104B | 1-bit GGUF still 594 GB | 896 (top-16) | ? | native | n/a | reject — exceeds pool by ~8x even at 1-bit; note arch **is now supported** (`LLM_ARCH_KIMI_LINEAR` in this tree), correcting the earlier "no arch" rejection reason — size is now the sole blocker |
| — | gpt-oss-120b (incumbent) | `gpt-oss` | 117B/5.1B | MXFP4, ~60 GiB, 0.542 B/param | 128 (top-4) | 36 of 36 (small KV per layer) | none | 19.6 t/s served | holds |

---

## 1. Ling-3.0-flash - released, and the strongest `deep` candidate so far

Released under MIT since this file last recorded it as "still not released", so
that verdict is retired. Target slot is `deep`, not `fast`: 5.1B active is the
same count gpt-oss-120b carries, and the predicted throughput lands on top of
the incumbent's.

**Everything in this section is research and arithmetic. Nothing here is
measured on this box** - the arch does not load here yet, see the blockers.

### What it is, from `config.json`

`model_type: bailing_hybrid`, GGUF arch tag `bailingmoe3`.

| field | value |
|---|---|
| total / active | 124B / 5.1B |
| layers | 42 - **35 KDA + 7 gated MLA**, 5:1 alternating |
| experts | **512 routed top-8** + 1 shared, `moe_intermediate_size` 768 |
| hidden / vocab | 2560 / 157,184 |
| attention | Kimi Delta Attention (linear) + MLA, `kv_lora_rank` 512 |
| context | `max_position_embeddings` 262144, `rope_scaling: null` - native, no YaRN |
| MTP | `num_nextn_predict_layers: 1`, bundled in every GGUF |
| license | MIT |

### Which tier fits the 76 GiB pool

Publisher sizes are GB (10^9), converted to GiB against the pool.

| tier | GB | GiB | bpw | verdict |
|---|---|---|---|---|
| UD-Q2_K_XL | 43.4 | 40.4 | 2.80 | below this repo's 3-bpw floor |
| **IQ3_XXS** | **51.2** | **47.7** | **3.30** | **the pick** - same bpw as Laguna's IQ3_S |
| Q3_K_M | 62.6 | 58.3 | 4.04 | fits, ~10 GiB margin |
| MXFP4_MOE | 69.8 | 65.0 | 4.50 | too tight |
| Q4_K_S and up | 73.9+ | 68.8+ | - | exceeds |

IQ3_XXS at 47.7 GiB is **smaller than `deep` is today** (59.0 GiB).

### Predicted 16-20 t/s base, ~21-27 with MTP

Two independent methods agree, which is why this is a range and not a point.

Decomposing active params from `config.json`: ~1.89B routed experts (8/512 of
~120B), ~2.79B non-expert of which **KDA projections alone are ~1.93B**, and
~0.40B `token_embd`. That sums to 5.08B against the published 5.1B, which is
what makes the decomposition trustworthy enough to build on. At IQ3_XXS with
non-expert tensors protected at Q6_K/Q8_0 - which is what the publishers say
they do - that is **3.0-3.7 GB/token**, and at the 60.5 GB/s hybrid-attention
correction factor, **16-20 t/s**.

The `tg_ceiling` formula at the top of this file lands in the same place: 5.1B
x 0.4125 B/param = 2.10 GB, ceiling 35.2 t/s, x the 0.45 realized band (512
experts plus hybrid attention is exactly the worst band, the one `coder` sits
in) = 15.9 t/s.

Against `deep`'s measured 19.6 t/s that is a wash, and well below `fast` (35.1)
or `kat-eval` (29.2).

### Three properties that make it worth tracking

**1. The best depth profile of anything evaluated here.** Only 7 of 42 layers
carry a KV cache at all, and those 7 are MLA (`kv_lora_rank` 512 + 64 rope =
576 per token per layer). The full 262144 context at q8_0 is about **1.1 GB**
of KV; the 35 KDA layers carry fixed-size recurrent state, ~73 MB per sequence.
The MiniMax-M2.1 failure mode that killed it here (-65% tg by d32768) is
structurally impossible on this layer pattern.

**2. The `pin-tensor-types.py` lever applies, harder than it did to Laguna.**
About 60% of non-embedding per-token bytes are non-expert, and the publishers
explicitly keep "KDA projections at higher precision". Retargeting those ~1.93B
params Q8_0 -> IQ4_XS is roughly a 27% cut in bytes per token, predicting
**~+38% tg** - the same play that took Laguna 13.77 -> 16.95. Note the caveat
recorded there: it worked because the mix was lopsided. This one looks lopsided
in the same direction, but that is a prediction, not a result.

**3. It clears `deep`'s harder-discriminator bar on published numbers.**

| benchmark | Ling-3.0-flash | best incumbent |
|---|---|---|
| GPQA-D | 85.0 | - |
| SWE-bench Pro | 56.6 | `fast` 50.4 |
| SWE-bench Multilingual | 72.4 | `fast` 69.3 |
| LiveCodeBench v5 | 82.8 | - |
| AIME 2026 | 93.2 | - |
| SWE-bench Verified | **not published** | `fast` 75.6 |

Per the `deep` bar above, another 10/10 on `reason-eval-hard.sh` cannot rank a
replacement - a harder discriminator has to be the argument. GPQA-D 85.0 and
SWE-bench Pro 56.6 are that argument.

### ...and four blockers, in severity order

**1. The arch does not exist in any shipping llama.cpp.** This tree has
`LLM_ARCH_BAILINGMOE` and `LLM_ARCH_BAILINGMOE2`, not `bailingmoe3`. Neither
does upstream master - a code search of `ggml-org/llama.cpp` returns zero hits.
Support is PR #26608 (`ggml-org/llama.cpp`), **OPEN** as of 2026-08-09: created
2026-08-05, 850 additions across 17 files, awaiting 2 of 3 code-owner
approvals, CPU-only for graph construction. Both GGUF publishers require a
non-upstream build - AtomicChat a "TurboQuant" build, bloomer010 the
`aetherbird/llama.cpp` fork. AtomicChat's card claims bailingmoe3 "is in
upstream llama.cpp"; **that claim is false**, and it is the kind of card
assertion this file has been burned by before.

**2. Tool calling is broken in the PR.** Multi-argument function calls fail:
the first argument's value swallows the remaining arguments as a literal
string. For this box that is disqualifying on its own, independent of every
other number here.

**3. Reported Vulkan freezes, and "MTP cannot be disabled without crashes."**
The hard op is *not* missing - this tree already ships Vulkan gated-delta-net
kernels with explicit KDA variants (`ggml/src/ggml-vulkan/ggml-vulkan.cpp`,
`gated_delta_net_f32_d128_kda`), which is why `kimi-linear.cpp` works. But an
untested arch on an unmerged PR with open Vulkan freeze reports is precisely
the shape that has cost this box two hard power cycles of pve2.

**4. The tier that fits is the hardest possible quant case.** 3.30 bpw with 512
experts of 5.9M params each. Laguna's IQ3_S was accepted only as an eval slot,
and only because its mix was lopsided enough to fix.

### One open question the config cannot settle

`mtp_loss_scaling_factor: 0`. If that means the MTP head carried no loss term
in final training, acceptance may be poor and the entire speculation upside
evaporates. The record here is split: KAT's *grafted* donor head accepted 0.76,
while GLM-4.7-Flash's declared-but-missing nextn tensors failed outright.
**Measure acceptance first** - that single number decides whether this is a
16 t/s model or a 27 t/s one, and it is cheap to get.

### Verdict

Do not download yet. Two things have to close first: PR #26608 merging, and the
multi-argument tool-calling bug. That PR is four days old and moving, not
stalled - re-check in 2-4 weeks.

When it clears, the path is `IQ3_XXS` into a `ling-eval` slot with
`load-on-startup = false`, verified standalone on port 8081 before it touches
`router.ini`, with MTP acceptance as the first measurement taken.

> **Re-checked 2026-08-11 - verdict holds, but the reasons moved.** The
> tool-calling blocker is fixed; the Vulkan one turned out to be reported on
> AMD Strix Halo, the nearest hardware sibling to this box, and is now the
> binding blocker rather than a generic risk. Every GGUF published before
> 2026-08-07 is also missing the SwiGLU clamp metadata. See "Ling-3.0-flash
> re-check, and Muse Glimmer - research 2026-08-11" at the end of this file
> before acting on anything in this section.

---

## 2. Qwen3.5-122B-A10B — the one candidate worth a closer look

Repo: `unsloth/Qwen3.5-122B-A10B-MTP-GGUF` (dedicated MTP-carrying repo,
distinct from the plain `unsloth/Qwen3.5-122B-A10B-GGUF`). Arch
`Qwen3_5MoeForConditionalGeneration` -> GGUF `qwen35moe`, confirmed present in
`src/llama-arch.cpp` (`LLM_ARCH_QWEN35MOE`).

**Architecture, verified from `config.json`:** 48 layers, hidden 3072, hybrid
attention with a repeating cycle of 3 GDN (linear) layers to 1 full-attention
layer (`full_attention_interval = 4` -> 12 of 48 full-attention), 32 query
heads / 2 KV heads / head_dim 256, 256 experts top-8 plus a shared expert,
262K native context. This is architecturally the same GDN-hybrid family as
`coder` (qwen3next), just with fewer experts (256 vs 512) and no shared-family
issues expected on the Vulkan backend.

**MTP wiring is already coded for this exact case**, not just declared. In
`src/llama-model.cpp:2147`:

```cpp
// The MTP head is dense-attention only on hybrid Qwen3.5/3.6, so use a plain
// attention KV cache for the MTP context instead of the hybrid wrapper.
const bool mtp_on_hybrid_qwen35 =
    params.ctx_type == LLAMA_CONTEXT_TYPE_MTP &&
    (arch == LLM_ARCH_QWEN35 || arch == LLM_ARCH_QWEN35MOE);
```

This is a real, arch-specific fix in-tree, which meaningfully de-risks the
"MTP declared but missing/broken" failure mode that killed GLM-4.7-Flash. The
generic `nextn.*` tensor names (`blk.%d.nextn.eh_proj`, `.enorm`, `.hnorm`,
etc.) are the same mechanism `fast` already uses successfully. **Still
unverified: whether the specific quants below actually carry the nextn tensor
block** — inspect the GGUF tensor list before downloading, the same check that
caught GLM-4.7-Flash's gap.

**Quant / size, verified via HF tree API (`unsloth/Qwen3.5-122B-A10B-MTP-GGUF/tree/main`):**

| quant | bytes | GiB | bpw |
|---|---|---|---|
| MXFP4_MOE | 76,230,560,800 | 71.0 | ~4.7 (native 4-bit) |
| UD-IQ4_XS | 61,927,783,424 | **57.7** | 4.06 |
| UD-Q3_K_XL | 58,379,402,272 | 54.4 | 3.83 |
| UD-Q3_K_M | 58,194,652,192 | 54.2 | 3.82 |
| UD-IQ3_S | 52,026,297,344 | 48.4 | 3.41 |
| UD-Q2_K_XL | 42,849,544,896 | 39.9 | 2.81 |
| UD-IQ2_M / IQ2_XXS | ~40.4 / 40.3 | ~37.5-37.6 | ~2.6 |
| UD-IQ1_M | 38,671,895,232 | 36.0 | ~2.5 |
| UD-Q4_K_S | 73,428,565,092 | 68.4 | 4.81 |
| UD-Q4_K_M | 78,260,403,200 | 72.9 | 5.13 |

**KV at 131072, q8_0, computed from the confirmed layer pattern:** 12
full-attention layers x 2 (K+V) x 2 KV-heads x 256 head_dim x ~1.06 bytes/elem
(q8_0 + block scale) ~= 12.7 KiB/token x 131072 tokens ~= **~1.6-2.0 GiB**.
This mirrors `coder`'s measured ~800 MiB at d65536 (same interval-4 GDN hybrid
family), so the estimate is corroborated by an existing measurement, not
invented from scratch.

**Pool arithmetic for the recommended quant (UD-IQ4_XS):** 57.7 GiB weights +
~2 GiB KV = **~59.7 GiB of 76**, leaving ~16.3 GiB spare — comfortably inside
the practical ~60 GiB ceiling for a `deep`-slot model, with real margin because
the hybrid layout keeps KV nearly free. MXFP4_MOE (71.0 GiB) and both Q4_K
variants (68.4/72.9 GiB) fail this arithmetic outright — MXFP4_MOE leaves
~3 GiB after KV, no headroom for load overhead; the Q4_K pair essentially fills
or exceeds the pool. IQ3_S (48.4 GiB, 3.41 bpw) is the leaner fallback if
IQ4_XS's quality turns out not to matter; anything below that (Q2_K_XL and the
IQ2/IQ1 tier, 2.5-2.8 bpw) crosses below the ~3 bpw floor for a reasoning slot
and should not be considered given the MiniMax-M2.1 precedent (1.64 bpw fit
fine, never terminated).

**Why it might beat the incumbent:** GPQA Diamond 85.5-86.6% (two independent
third-party sources, not yet corroborated against Qwen's own release post)
against gpt-oss-120b's own-reported 80.9% at high effort — exactly the kind of
unsaturated benchmark to weight here, since `reason-eval-hard.sh` is saturated
at 10/10 for gpt-oss and cannot itself discriminate a further improvement.
Terminal-Bench 2.0 41.6-49.4% is not directly comparable to anything published
for gpt-oss-120b. SWE-bench Verified 72.0-72.4 is below `fast`'s 75.6 and not a
`deep`-slot argument either way.

**Why it might not:** three independent problems, not one.

1. **Throughput.** active_params(10B) x bytes/param(0.508 for IQ4_XS) = 5.08
   GB/token read; ceiling = 74/5.08 = **14.6 t/s**. Realized fraction: 256
   experts plus a hybrid GDN attention stack is architecturally the same shape
   that put `coder` at the bottom of the band (0.45), just with half the
   expert count, so estimate **0.45-0.55** -> base **6.6-8.0 t/s**. Applying
   the measured MTP range (+30-45%) gives **8.5-11.6 t/s served** — roughly
   45-60% of gpt-oss's measured 19.6 t/s, a real and large regression before
   any quality argument is weighed against it.
2. **No evidence on reasoning-token cost.** Nothing published quantifies
   thinking-token length for this model against gpt-oss. The one weak signal
   found — an Intelligence-Index note that it "generated 96M output tokens,
   somewhat higher than average" across its benchmark suite — points the wrong
   direction, toward verbosity, not economy.
3. **A directly relevant negative precedent already exists in this repo.**
   `README.md`'s "Replacing the deep slot" section measured
   Qwen3-Next-80B-A3B-Thinking — same lab, same hybrid-GDN reasoning lineage —
   against gpt-oss and it lost on both axes that matter here: 27.2k chars of
   reasoning against gpt-oss's 15.4k for a worse score, and 27% slower prefill
   outweighing 4% faster generation. Qwen3.5-122B-A10B is a newer, larger point
   release of the same family pattern (hybrid GDN + MoE + thinking), which
   raises rather than lowers the prior that it repeats the verbosity problem.

**Risk, stated plainly:** the expected failure mode is non-termination on hard
reasoning items, and a 3.41-4.06 bpw UD quant of a 122B model is close enough
to the ~3 bpw floor to take that seriously, especially with zero published
evidence either way on thinking-token cost. Combined with a 40-55% throughput
deficit, this is not a "download and swap it in" candidate. It is the
best-supported candidate this sweep found and the one to check next if a
download is to be spent: **pull the tensor listing only first** (`gguf-py`
header read, no full download needed) to confirm the nextn block is actually
present in UD-IQ4_XS before committing 57.7 GiB, given GLM-4.7-Flash's exact
failure mode was a declared-but-absent MTP block.

## 3. Nemotron 3 Super 120B-A12B — insufficient evidence, not a real candidate yet

`unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF`, arch `nemotron_h_moe`
(confirmed present in `src/llama-arch.cpp`, `LLM_ARCH_NEMOTRON_H_MOE`). Hybrid
Mamba-2 / Latent-MoE / attention, 120B total / 12B active, native MTP claimed
by NVIDIA's release post, native 1M context.

Genuinely interesting shape — mostly-Mamba2 layers with attention "interleaved
at key depths" should give excellent depth scaling, similar in spirit to
`coder`'s cheap KV — but three things stop it here:

- **The official config is gated** (401 on the raw `config.json`), so the exact
  attention-layer count, per-layer head config, and true expert count could not
  be verified independently; the blog's "repeating groups" language is too
  vague to compute a KV-at-131072 figure with any confidence.
- **No corroborated benchmark on GPQA Diamond, ARC-AGI-2, SWE-bench Pro, or
  Terminal-Bench 2.0** — the only number found is a self-reported "PinchBench
  85.6%," an NVIDIA-only benchmark with no independent citation, which should
  be treated as marketing until corroborated.
- Active params (12B) is even higher than Qwen3.5's 10B, and the quants that
  fit the pool (UD-Q2_K_XL 50.9 GiB / 3.64 bpw, or the unlabeled "other IQ"
  tier at 49.0 GiB / ~3.5 bpw) sit at or below the same 3 bpw floor concern,
  with less margin than Qwen3.5's IQ4_XS.

Watch this one; do not act on it without the config and at least one
independent benchmark number.

---

## Rejected at research time, with reasons

| model | reason |
|---|---|
| MiniMax-M2.7 | Same `minimax-m2` arch, config confirms **62 of 62 layers still full attention**, unchanged from M2.1. DFlash drafters are now published for this point release, but the depth-collapse problem that actually killed M2.1 (65% tg drop by d32768) is architectural, not a speculation gap, and is unchanged. Not re-measured. |
| Laguna S 2.1 | Wrong slot — SWE-bench/Terminal-Bench-tuned coding model, no GPQA/ARC-AGI evidence found. Smallest GGUF quants (INT4 ~72 GB, 4-bit GGUF ~75 GB) leave under 4 GiB of the 76 GiB pool once any KV is added — fails the practical-ceiling gate even before the slot mismatch. |
| GLM-4.7-Flash | Already tested and rejected on this box (`failed to create MTP context`, declared-but-missing nextn tensors). Searched for a fix; found only an unrelated Jan-2026 scoring-function bug fix, no confirmation the MTP tensor gap was addressed. Not re-tested. |
| Kimi K3 | Correction to the prior entry: arch **is now supported** in this tree (`LLM_ARCH_KIMI_LINEAR`, confirmed in `src/llama-arch.cpp`), so the earlier "no kimi_k3 arch" rejection reason is stale. Still fails on size alone — even the 1-bit Unsloth dynamic GGUF is ~594 GB, ~8x the pool. **2026-08-15:** Colibri runs it at 1.6 TB streamed from disk, so "exceeds pool" is the wrong gate now — it exceeds the 931.5 GB *drive*. Still rejected, different reason; see "Colibri" at the end of this file |
| Step-3.5-Flash (`step35`, 196B/11B) | Carried forward from the 2026-08-01 shortlist unresolved, where it was ranked for `coder`, not `deep`. Still untested. Its blocking gate is unchanged: IQ2_S is 69.2 GiB against a 76 GiB pool, leaving ~6.8 GiB for KV at 131072, and its estimated 11-18 t/s lands at or below the slot it would replace. Not re-evaluated in this deep-focused sweep — arch `LLM_ARCH_STEP35` is present in this tree. |
| Ling-3.0-flash | **No longer rejected - see section 1.** Weights released under MIT; it is now the top-ranked `deep` candidate, blocked on arch support rather than on merit. |
| Nemotron 3 Super | See section 3 — not rejected outright, but insufficient independently-verified evidence to shortlist; gated config, uncorroborated benchmark. |
| Hy3 (Tencent, `hy_v3`, 295B/21B) | Exceeds pool. Unchanged from 2026-08-01. **2026-08-15:** a `UnderstandLing/Hy3-colibri-int4` container exists on HF, but `hy_v3` is not among Colibri's architecture files — verify before believing it. See "Colibri" at the end of this file |
| DeepSeek-V4-Flash (`deepseek4`, 284B/13B) | Exceeds pool, smallest quant 82.5 GB verified. **2026-08-15: this rejection reason is retired.** Colibri implements `deepseek_v4.c` and its fp4 container is 167 GB, which fits the 337 GB free on this box today — at an estimated 1-2 t/s. The gate is now throughput and harness compatibility, not size. See "Colibri" at the end of this file |
| GLM-4.7 full (355B) | Exceeds pool. Unchanged — and Colibri does not help, it implements GLM-**5.2**, not this. |
| GLM-4.5-Air (106B/12B) | Fits, SWE-bench Verified 57.6 below every current slot. Unchanged. |
| Ling-2.6-flash | Hybrid `BailingMoeV2.5` arch needs a vendor fork. Unchanged. |
| Ling-flash-2.0 (`bailingmoe2`, 100B/6.1B) | Arch supported, superseded, no fresh agentic evidence. Unchanged. |
| Qwen3.6-35B-A3B base | Loses to `fast` on SWE-bench and Terminal-Bench 2.0. Unchanged; also the base of the already-rejected Ornith-3.6 merge. |
| Trinity-Large-Preview (398B/13B) | ~119 GB, exceeds pool. Unchanged. |
| ERNIE-4.5-21B-A3B, ERNIE-5.0 | Too small (4.5) / no weights found (5.0). |
| Seed-OSS, dots.llm2 | No successor shipped since 2026-08-01. |

---

## Measured on this box

Registry of every model actually downloaded and run through the eval scripts
on this hardware — check here before re-downloading or re-testing anything.
Desk-rejected models (architecture ruled out from `config.json` alone, never
downloaded) are in the tables above/below instead; this table is only for
models that cost GPU time and disk space to evaluate. Full write-up for each
row is linked in the "Detail" column.

| Model / repo | Tested for | Date | Verdict | Why | Disk |
|---|---|---|---|---|---|
| `SC117/Ornith-1.0-35B-MTP-APEX-GGUF` | `fast` | 2026-07-31 | **deployed** | all-rounder: SWE-bench Verified 75.6, native MTP head, vision+tools+reasoning 8/8 | on disk (`ornith35-mtp-q.gguf` + mmproj) |
| Ornith-Agents-A1-3.6-35B-A3B (DARE-TIES merge) | `fast` | 2026-08-01 | **rejected** | wins every throughput axis (+13% tg) but reason-eval 6/8, exhausts token budget without concluding on 2/8 | deleted 2026-08-03, see below |
| MiniMax-M2.1 IQ1_S | `coder`/`deep` | 2026-08-01 | **rejected** | fits the pool but tg collapses 65% by d32768 (62/62 full-attention layers) and reasoning does not converge at 1.64 bpw | deleted 2026-08-03, see below |
| `unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF` (UD-Q4_K_XL) | `assist` | 2026-07-31 | **deployed** | only vision-capable alias besides `fast`; 394 t/s prefill lead | on disk + mmproj |
| `gpt-oss-120b` MXFP4 (publisher unverified) | `deep` | 2026-07-31 | **deployed** | 10/10 on `reason-eval-hard.sh` in 208s vs `fast`'s 8/10 in 999s; native `reasoning_effort` | on disk |
| `unsloth/Qwen3-Coder-Next-GGUF` (UD-Q4_K_XL) + DFlash drafter | `coder` | 2026-07-31 | **retired 2026-08-03** | beaten on every axis by nerkyor DSV4Pro (pp 229 vs 326, tg 18.6 vs 26.4 base); also started repeatably hitting DeviceLost on load | deleted 2026-08-03 |
| Qwen3.6-35B-A3B vanilla (official quant) | `fast`/`deep` | downloaded 2026-07-31, desk-rejected | **rejected** | same hybrid-GDN shape as `coder` (10/40 full-attention) — no reason to expect better prefill than the fine-tunes already covering this base | deleted 2026-08-03 |
| `nerkyor/Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-GGUF` (Q4, 19.06 GiB) | `coder` -> `coder-eval` | 2026-08-03 | **held `coder` until 2026-08-14, now an eval slot** | beats Coder-Next on every axis, ties `fast` on saturating evals, and once its mmproj was loaded it was the best model measured here that day; lost the alias to the three-alias cut on throughput, not merit | deleted 2026-08-14, re-downloaded the same day as `EVAL-coder-Q4.gguf` + `EVAL-coder-mmproj-Q8_0.gguf` |
| `nerkyor/Qwen3.6-35B-A3B-APEX-MTP-GGUF` ("I-Balanced", 24.27 GiB) | `fast` (MTP comparison) | 2026-08-04 | **rejected** | class-leading throughput once retuned to n-max=3 (35.6 t/s served, beats `fast`) but hard-reasoning 6/10 with 4 truncations — same non-termination failure that sank Ornith-3.6 and MiniMax-M2.1 | deleted 2026-08-04 |
| `nerkyor/Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill` (Q4_K_M, 20.22 GiB + mmproj) | `fast` -> `nerkyor-eval` | 2026-08-04, re-verdicted 2026-08-07 | **eval slot, exonerated** | won every standalone eval; lost `fast` twice on 2026-08-04 to two `ErrorDeviceLost` GPU hangs that were **wrongly attributed to it** - the real cause was amdgpu's 2000 ms compute-ring watchdog, which also hit `coder` (no speculation at all) the day before. Weights were deleted 2026-08-05 on that bad diagnosis and redownloaded 2026-08-07; `nerkyor-eval` slot restored. Owes a real-traffic soak with the watchdog fix in place before it can retake `fast`. See "Root cause, corrected" below | on disk (`nerkyor-Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill-Q4_K_M.gguf` + `-mmproj-F16.gguf`) |
| `nerkyor/Qwen3.6-27B-DSV4Pro-GLM52-SFT-GPT55-RL-Coding-GGUF` (Q4-LynnStyle, dense) | `coder` | 2026-08-04 | **rejected** | confirmed dense (`qwen35`, zero expert tensors) — 4.1 t/s base, 8.5 t/s even with its own MTP draft sidecar; reproduces this repo's established dense-model rejection a third time | deleted 2026-08-04 |
| `mudler/Qwen3.5-35B-A3B-APEX-GGUF` (I-Quality, 21.25 GiB + mmproj) | `fast` | 2026-08-15 | **rejected** | the base model `fast` is a post-train OF, same recipe/tier/geometry - **2/6 on `code-eval-hard`**, a tier everything else saturates, by quitting after 2 turns with tests still red; also worse perplexity at 61/61 and -27% tg from the dropped MTP head | on disk (`EVAL-apex-q35-IQuality.gguf` + mmproj) |
| `nerkyor/Qwen3.6-35B-A3B-APEX-MTP-GGUF` ("I-Balanced", 24.27 GiB) - **re-test** | `fast` | 2026-08-15 | **rejected again** | reproduces the 2026-08-04 verdict almost exactly: 5/10 with 5 truncations and 143,308 chars against 6/10, 4 truncations and 143,125 chars then. Fastest model ever measured here (35.14 tg) and the **best perplexity ever measured here** (2.0069, beats `fast` at 61/61) - and it still cannot finish a hard reasoning item | on disk (`EVAL-apexmtp-q36-IBalanced.gguf`) |
| `zTrojan/Qwen3.5-122B-A10B-REAP30-APEX-GGUF` (Mini, 30.76 GiB) | `balanced` / `deep` | 2026-08-15 | **rejected** | 30% expert-pruned, 180 of 256 left. Loses to `deep` on every axis: 6/10 with 4 truncations against 8/10 with none, 2929 s against 546 s, 13.06 tg against 15.55, and worst perplexity measured here (2.1699, +7.5%). Bottom tier - I-Compact untested by decision | on disk (`EVAL-reap30-mini.gguf`) |

### Ornith-Agents-A1-3.6-35B-A3B — rejected 2026-08-01, tested for `fast`

DARE-TIES merge on Qwen3.6-35B-A3B. **Won every throughput comparison** —
served tg 36.03 vs incumbent's 34.60, pp +8.3%, tg +13.0% base — and was
**rejected on reasoning**: `reason-eval.sh` scored 6/8 against the incumbent's
8/8, exhausting the full 8000-token budget on 2 of 8 problems (~30,000 chars
each, `finish_reason: length`) without ever concluding. The incumbent answers
both in 93 s combined. Tool calling and vision both passed — the merge damage
landed specifically on reasoning termination.

Also: the repo ships an `mtp-sidecar.gguf` that looks like a drafter but is
not — it holds 20 tensors with no `token_embd.weight` and cannot load as a
model. The **main** GGUF already carries the complete nextn block; correct
wiring is identical to the incumbent (`spec-type = draft-mtp`, no
`draft-model` line). Check any sidecar's tensor list before assuming it needs
wiring as a separate drafter.

### MiniMax-M2.1 IQ1_S — rejected 2026-08-01, tested for `coder`/`deep`

229B/10B active, `minimax-m2` arch. **Fit the pool** (61.63 GiB of 76 at
131072 ctx) — the only prediction that held. **Rejected twice over:**

1. 62 of 62 layers full attention, no GDN discount available. tg collapsed 65%
   by d32768 (19.37 -> 6.75), unusable well inside its own context window on a
   slot whose purpose is long prefixes. No speculation available for this point
   release (DFlash exists for M2.5/M2.7, not 2.1).
2. Reasoning does not converge at 1.64 bits/weight: 2 of 2 attempted
   `reason-eval.sh` questions — including the trivial bat-and-ball — consumed
   the entire 8000-token budget without an answer (~8.5 min GPU each). Run
   stopped at 2/8 once the pattern reproduced (0/2 attempted, 6/8 not run).

What did **not** fail: coherence, tool calling (`get_weather` call correct),
and a realistic `edit_file` request produced valid JSON with an
exactly-matching `old_str`. When this model finishes, its structured output is
fine — the problem is that it frequently does not finish. No better quant
exists to retreat to: IQ2_S is 59.0 GiB, which plus q8_0 KV at 131072 exceeds
the pool.

### What both rejections say about the next candidate

Both were quality failures throughput testing would have scored as wins, and
both failed the identical way: **they did not stop generating.** Treat
non-termination as the expected failure mode of an aggressively quantized or
merged model, ahead of incoherence or malformed tool calls — neither rejected
model produced either of those. Run `reason-eval.sh` and `reason-eval-hard.sh`
before any throughput tuning; a `spec-draft-n-max` sweep on a model that cannot
terminate is wasted time, which is exactly what rejected these two before it
was wasted. The incumbents are not immune either — `fast` truncates on 2 of the
10 hard items. The bar is the incumbent for that slot, not perfection.

### nerkyor Qwen3.6-35B-A3B-DSV4Pro RL-Agent Q4 — measured 2026-08-03, not rejected

`nerkyor/Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-GGUF`, Q4 tier, 19.06
GiB. A community fine-tune of Qwen3.6-35B-A3B whose repo name stacks enough
unverifiable claims (a Qwen version that does not exist, two closed-model
distillation claims, an RL-agent suffix) that it was expected to be a mislabeled
reupload. **It is not.** The repo is real (12,356 downloads, four consistent
quant tiers at 13.30 / 19.06 / 27.60 / 34.37 GiB plus an optional vision
projector, cross-verified against `manifest.json` and `SHA256SUMS`), and the
weights are a genuine 256-expert top-8, 40-block, GDN-hybrid MoE — confirmed by
parsing the raw GGUF binary header, not by trusting the HF summary.

**Verdict: beats `coder` on every measured axis, sits behind `fast` on
generation speed, ties it everywhere else.** Same build (`3d08405`, build 268),
idle box, Vulkan confirmed, `bench-guard.sh` clean (35-81°C, 4-51 W).

| condition | pp d0/4k/16k | tg d0/16k/32k | served pp/tg | code-eval | reason-eval |
|---|---|---|---|---|---|
| **nerkyor Q4** | 325.97 / 316.95 / 296.16 | 26.41 / 24.05 / 21.96 | 319.7 / 26.14 | **4/4**, 104 s, 19 turns, 0/0, 3,597c | **8/8**, 107 s, 9,611c |
| `fast` (re-measured same session) | 332.60 / 263.18 / 285.52 | 25.33 / 23.06 / 21.15 (base) | 317 / **34.6** (MTP) | 4/4, 93 s, 19 turns, 0/0, 4,342c | 8/8, 190 s |
| `coder` (baseline table) | 228.9 (d0) | 18.6 (d0) | 235 / 25 (DFlash) | 2/4, 162 s, 36 turns, STALL | n/a |

On base throughput it is a dead heat with `fast` (within a few percent in both
directions, ordinary run-to-run variance) and roughly +40% on `coder` for both
pp and tg. Its **non-speculative** served tg of 26.14 edges out `coder`'s
**speculative** served tg of 25 — with no drafter at all.

**Where it loses, and why the gap cannot be closed:** `fast`'s in-model MTP head
puts it at 34.6 t/s served, a 32% generation lead. This candidate's model card
explicitly states no MTP sidecar exists ("Do not add `--model-draft`"), so there
is no speculation path to recover it.

**What the passing scores do and do not prove.** Both `code-eval.sh` and
`reason-eval.sh` saturate at the incumbent's score, so 4/4 and 8/8 here
demonstrate *not worse*, not *better* — the same limitation recorded above for
the easy tiers generally. `code-eval-hard.sh` was written on 2026-08-03
specifically to close this gap for the coder slot, the way `reason-eval-hard.sh`
closed it for `deep`.

**One anomaly, recorded because it was a legitimate reason to distrust the
file.** The GGUF's `general.architecture` reads `qwen3next`, while both official
conversions of the same base model (`ggml-org/Qwen3.6-35B-A3B-GGUF`,
`unsloth/Qwen3.6-35B-A3B-GGUF`) tag it `qwen35moe` — and this file's own
metadata carries a reference byte-size field matching the `ggml-org` qwen35moe
repo exactly, confirming same base model with a mismatched arch tag.
`llama-model.cpp` documents genuinely different QKV/SSM broadcast conventions
between those two paths, so this was not a nitpick. It was tested rather than
rejected on that basis: `check-output.sh`, `code-eval.sh` and `reason-eval.sh`
all pass cleanly, and throughput tracks the `qwen35moe` (`fast`) shape rather
than `coder`'s slower `qwen3next` shape — so it behaves correctly despite the
label. **Residual risk is not fully closed**: testing reached 32768 depth only,
and vision and long-running serving were not exercised.

**Superseded — it took the `coder` alias on 2026-08-03.** The recommendation
below was written before the hard tiers ran; see "Hard-tier results" immediately
after this section for what changed and why the swap was made.

~~Standing recommendation: do not wire it into `router.ini` on this evidence.~~
It is not a case for replacing `fast` — parity on the saturating evals, 32%
behind on generation, no speculation available. It *is* a stronger `coder`-slot
candidate than anything the 2026-08-03 sweeps found: smaller (19 vs 46 GiB),
faster on every measured axis, and it passes the agentic-coding eval where
`coder` stalls.

The Q4 file is on the box at `/root/models/nerkyor-dsv4pro-q4.gguf` (20.47 GB,
SHA256-verified; 201 GiB free).

### Hard-tier results — measured 2026-08-03, and the `coder` swap

All three hard tiers, both models, same session and build. `fast` ran through
the router; the candidate ran standalone on port 8081 at `c=32768` with the
router stopped so it had the pool to itself.

| eval | `fast` | candidate |
|---|---|---|
| `reason-eval-hard.sh` | 9/10, 1 trunc, 776 s, 72,108c | 9/10, 1 trunc, **540 s, 28,007c** |
| `code-eval-hard.sh` | 6/6, **163 s**, 27 turns | 6/6, 244 s, 31 turns |
| `code-eval-opencode.sh` | 6/7, **200 s**, 43 turns, 3.7K read | 6/7, 275 s, 42 turns, 3.8K read |

**No tier separated the two models on score.** They tie on all three, and on the
opencode tier they fail the *same* item. Three things follow, in order of how
much they matter.

**1. The candidate wins decisively on reasoning economy.** Same score and same
truncation count on the hard reasoning tier, reached 30% faster while emitting
**2.6x less reasoning** — despite having no MTP head and generating at ~26 t/s
against `fast`'s 34.6. This repo has weighted that axis above raw t/s since the
`deep` sweep ("a model that thinks in half the tokens is worth more than one
that generates 20% faster"); this is the first local measurement where a
candidate wins on it. The matching truncation count is also direct evidence
against the non-termination mode that rejected Ornith-3.6 and MiniMax-M2.1 —
the open question from the throughput run above, now answered.

**2. `code-eval-hard.sh` is saturated and failed at its job.** It was written to
rank a candidate above `fast`; two models scored 6/6 on the first attempt. It
remains a regression check — a harder workload than the easy tier (27 turns and
163 s against 19 and 93 s) without being a harder discriminator. Its dup-block
item, built specifically to force edit misses, produced **0 for both models**:
each qualified its `old_str` with surrounding context on the first try. The
opencode-critical metric is still untested on this box.

**3. `code-eval-opencode.sh` was the only tier to produce a failure**, and both
models failed identically on `agents-md` — correct fix, every assertion passing,
a bare exception instead of the `ConfigError` that AGENTS.md mandates, at 5-6
turns and ~0.5K read. That is not enough reading to have opened AGENTS.md at
all.

That prompted an A/B, since opencode injects AGENTS.md *contents* into the
system prompt while the item only said the file existed. `agents-inject` is
byte-identical apart from the injection:

| model | `agents-md` (must discover) | `agents-inject` (handed over) |
|---|---|---|
| `fast` | VIOLATE, 6 turns, 0.6K | **PASS**, 5 turns, 0.5K |
| candidate | VIOLATE, 5 turns, 0.4K | **PASS**, 4 turns, 0.5K |

Unambiguous and identical for both: **neither model goes looking for project
conventions, and both follow them once handed over.** The failure is discovery,
not compliance — and since opencode does the handing over, real exposure in the
client is low. Read alone, the un-injected item would have overstated the
problem. Both items are kept: `agents-inject` is the opencode-faithful score,
`agents-md` is the control that makes it interpretable.

What the opencode tier established that tiers 1-2 structurally could not:
`stale-edit` passed for both with 1 harness-induced miss and 0 real misses, so
both re-read a file that changed under them and adapted rather than blindly
retrying — the opencode-critical behaviour, now measured rather than assumed.
`needle` passed on ~0.4K of reads against ~5.3K to brute-read the 32-file
project, so both grep rather than reading everything.

**One correction to the record.** `fast` on `reason-eval-hard.sh` scored 9/10 in
776 s on 72,108 chars this session, against the 8/10 / 999 s / 95,650 chars
recorded in the `deep` section above. Same build. The recorded figure is a
single sample and this tier is noisier than the 10/10-vs-8/10 framing implies;
treat single-sample hard-tier numbers as indicative, not settled.

**Decision: the candidate took the `coder` alias on 2026-08-03.** The case is
not that it beats `fast` — it does not, and it is 32% behind on generation with
no speculation path. The case is that it beats what `coder` was: pp 326 vs 229,
tg 26.4 vs 18.6 base, served 26.14 (no speculation) vs 25 (with DFlash),
`code-eval` 4/4 in 104 s against 2/4 in 162 s with a stall, and 19 GiB against
46. Qwen3-Coder-Next had also stopped loading entirely (repeatable DeviceLost),
so the alias was unusable as it stood. Retired weights were deleted from disk
2026-08-04 once nothing referenced them.

**Still open, and worth closing before trusting the slot broadly:** it has only
been exercised to 32768 context here while `router.ini` sets 131072; the
`qwen3next`/`qwen35moe` arch-tag mismatch is understood but not fully closed
out; and it carries no vision, where the retired model carried none either but
`fast` and `assist` both do.

### Three more nerkyor variants — measured 2026-08-04, following up on the DSV4Pro RL-Agent result

Same publisher, same base model family, same box, same build (`3d08405`,
build 268). Box idle and clean before every run; `bench-guard.sh` reported no
throttling on any of the three (33-81 °C, 4-56 W); backend confirmed `Vulkan`
on every `llama-bench` table below.

#### nerkyor/Qwen3.6-35B-A3B-APEX-MTP-GGUF — rejected 2026-08-04, tested for `fast`

`Qwen3.6-35B-A3B-APEX-MTP-I-Balanced.gguf`, 24.27 GiB, SHA256-verified. Only
one quant tier exists in this repo — an adaptive-precision mix (131 Q8_0 /
217 Q6_K / 93 Q5_K tensors, no Q4 at all). `general.architecture` reads
`qwen35moe`, matching the known-good shape — no mislabeling this time.
`general.name` is just `"Safetensors"`, uninformative. MTP is real, confirmed
via raw tensor dump (`blk.40.nextn.eh_proj/enorm/hnorm/shared_head_norm`
present) rather than trusted from the card. No mmproj shipped — no vision.

The vendor's own recommended `--spec-draft-n-max 4` (tuned on a DGX Spark
GB10, a different GPU) is poor on this box — acceptance collapses to
0.49-0.58. Retuned to n-max=3 (`fast`'s own tuned value), acceptance jumps to
0.90-0.96 and served tg reaches a **35.6 t/s median — beating `fast`'s 34.6**:

| condition | pp d0/4k/16k | tg d0/16k/32k | served pp/tg | acceptance |
|---|---|---|---|---|
| `bench.sh` (no spec) | 325.45 / 349.81 / 272.59 | 24.99 / 22.45 / 20.70 | — | — |
| served, vendor's n-max=4 | — | — | — | 0.49-0.58, len 2.97-3.31 |
| served, n-max=3 (retuned here) | — | — | 289-300 / **35.59 median** | 0.90-0.96, len 3.7-3.86 |

Evals (standalone :8081, c=32768, n-max=3):

| eval | result |
|---|---|
| `check-output.sh` | OK, coherent |
| `reason-eval.sh` | 8/8, 143 s, 15,720c |
| `reason-eval-hard.sh` | **6/10, 4 truncated**, 1463 s, 143,125c reasoning |
| `code-eval.sh` | 4/4, 118 s, 21 turns |
| `code-eval-hard.sh` | 6/6, 193 s, 30 turns |
| `code-eval-opencode.sh` | 7/8, 200 s, 40 turns (fails `agents-md`, same as every model tested) |

**Verdict: reject.** The hard-reasoning result is disqualifying — 4 of 10
items exhaust the token budget without concluding, and total reasoning volume
(143k chars) is roughly double `fast`'s own worst recorded session. This is
the same non-termination failure mode that rejected Ornith-3.6 and
MiniMax-M2.1. Class-leading throughput cannot offset it, and it has no vision
to fall back to a different slot. The n-max=3 retuning finding (vendor default
is wrong for this hardware) is worth keeping regardless of the reject.

#### nerkyor/Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill — measured 2026-08-04, not rejected, tested for `fast`

`gguf/Qwen3.6-35B-A3B-DSV4Pro-Distill-MTP-Q4_K_M-imatrix.gguf`, 20.22 GiB,
SHA256-verified. Proper multi-tier release (Q4_K_M/Q5_K_M/Q6_K/Q8_0/F16) plus
an F16 mmproj (~0.84 GiB, not downloaded/tested here). `general.architecture`
reads `qwen35moe`, matching the known-good shape. `general.name` is
`"Distill 35b Bf16 Vllmfix"`. MTP confirmed real via the same raw tensor
check as the others; standard Q4_K/Q6_K histogram, no adaptive-precision
oddity.

**Best base throughput of any candidate measured on this box, including the
current `coder` incumbent:**

| condition | pp d0/4k/16k | tg d0/16k/32k | served pp/tg | acceptance |
|---|---|---|---|---|
| `bench.sh` (no spec) | **375.24 / 347.30 / 323.09** | **28.74 / 25.85 / 23.18** | — | — |
| served, n-max=3 (vendor default here, same as `fast`'s tuned value) | — | — | 343.1 median / 32.75 median (32.73-40.39) | 0.69-0.93, len 3.07-3.79 |

Evals (standalone :8081, c=32768, n-max=3), against `fast`:

| eval | result | vs `fast` |
|---|---|---|
| `check-output.sh` | OK, coherent | — |
| `reason-eval.sh` | 8/8, **114 s**, 13,223c | faster (`fast` ~190 s) |
| `reason-eval-hard.sh` | **10/10, 0 truncated**, 154 s, 15,749c | **decisively beats** `fast`'s 8-9/10 (72-95k chars reasoning) |
| `code-eval.sh` | 4/4, **88 s**, 18 turns | faster (`fast` 93 s) |
| `code-eval-hard.sh` | 6/6, 235 s, 33 turns | ties (`fast` 163 s/27 turns, slightly faster) |
| `code-eval-opencode.sh` | 7/8, 225 s, 47 turns | ties (same `agents-md` failure as every model tested) |

No greedy-decode looping was observed despite the model card's explicit
warning that this thinking model wants `temperature=0.6`, not greedy — worth
noting since this harness runs everything at `temperature=0`.

**Verdict: the strongest `fast`-slot candidate found in this repo's search
history.** Wins base throughput, wins hard reasoning outright (10/10
zero-truncation vs 8-9/10 with truncations, in far fewer reasoning tokens),
wins easy-tier speed, ties everything else — while being smaller (20.22 vs
21.9 GiB) and carrying vision like `fast` does. **Not wired in yet.**
Recommend a focused follow-up before any slot decision: exercise vision
(`check-vision-tools.sh`), tune `spec-draft-n-max`/`p-min` the way `fast` was
tuned (only the vendor default was tried here), and re-verify at the full
131072 `ctx-size` (only tested to 32768 here, same open caveat as `coder`).

#### Follow-up — measured 2026-08-04: vision, its own spec-tuning peak, full-ctx verify

**1. Vision + tools, standalone with mmproj-F16 loaded alongside the MTP
head.** `gguf/Qwen3.6-35B-A3B-DSV4Pro-Distill-mmproj-F16.gguf`, 0.84 GiB,
SHA256-verified, loads cleanly with `spec-type = draft-mtp` — no conflict.
Tool call (`get_weather`) and vision (four-quadrant color ID) both **PASS**.
This candidate genuinely covers the same capability surface as `fast`
(reasoning + vision + tools in one model), not a `coder`-shaped
faster-but-narrower tradeoff. Caveat: this is a smoke test, not the depth of
vision exercise `fast` has accumulated (Hermes Agent screenshot tooling) — if
vision is load-bearing in practice, worth a closer look before cutover.

**2. Its own spec-tuning peak is n-max=4, not n-max=3 inherited from `fast`.**
The first pass above used `fast`'s tuned value as an untested assumption.
Swept n-max 2/3/4/6 x p-min 0.0/0.2/0.3/0.5 (standalone :8081, c=32768,
`probe-server.sh`, 3 samples each):

| n-max | p-min | served tg median (range) | acceptance | mean draft len |
|---|---|---|---|---|
| 2 | 0.0 | 35.16 (34.77-36.45) | 0.79-0.86 | 2.58-2.70 |
| 3 | 0.0 | 32.75 (32.73-40.39, noisy) | 0.69-0.93 | 2.97-3.79 |
| **4** | **0.0** | **40.75 / 38.93 across two runs** (40.45-40.89 / 38.51-40.26) | **0.83-0.90** | 4.31-4.55 |
| 4 | 0.2 | 39.48 (39.16-40.39) | 0.86-0.89 | 4.36-4.47 |
| 4 | 0.3 | 33.13 (23.24-43.21, unstable) | 0.42-0.96 | 2.45-4.81 |
| 4 | 0.5 | 40.79 (36.49-43.48) | 0.90-0.99 | 3.76-4.92 |
| 6 | 0.0 | 40.06 (27.03-40.71, noisy — same n-max=6 regression shape `fast` shows) | 0.52-0.87 | 4.11-6.22 |

Reproduced across two separate n-max=4 runs (40.75, 38.93), both well above
n-max=3's 32.75. Unlike `fast`, `p-min` gives no reliable win here and 0.3
actively destabilizes it — leave `p-min` at default. Net effect: ~20-25% more
served tg than the number in the initial writeup above, now a solid,
reproducible win over `fast`'s own served 34.6 t/s.

**3. Full-context re-verify (c=131072, n-max=4).** Loads cleanly at the
ctx-size `router.ini` actually uses. GTT usage 8.44 GiB — comfortably inside
the pool. Depth sweep (`llama-bench`, `bench-guard.sh` clean, 41-75°C, no
throttling):

| | d0 | d8192 | d32768 | d65536 |
|---|---|---|---|---|
| pp512 | 368.18 ± 2.38 | 289.79 ± 3.97 | 175.08 ± 1.94 | 114.49 ± 0.45 |
| tg64 | 28.73 ± 0.01 | 27.15 ± 0.09 | 23.14 ± 0.15 | 19.54 ± 0.07 |

No depth collapse: retains 68% of tg64 at d65536, in the same healthy
hybrid-GDN band as `fast` (70.5% retained) and `coder` (73.6% retained) — not
close to MiniMax-M2.1's -65% collapse by d32768 alone.

**Final recommendation: swap `fast` to this model.** Weighed the same way
the `coder` swap was actually decided — not on score parity, but on the
combination: it beats `fast` on base+served throughput (tuned: ~39-41 t/s vs
`fast`'s 34.6), and wins hard reasoning decisively (10/10 zero-truncation in
154s/15,749c vs `fast`'s 8-9/10 with truncations burning 72-95k chars) — the
axis this repo weighs most heavily because it's the one built specifically to
discriminate once the easy tiers saturate. Vision and tools tie (both work).
`fast` edges ahead only on two small margins: code-eval-hard wall time
(163s/27 turns vs 235s/33 turns, same 6/6 score) and depth-decay percentage
(70.5% vs 68% retained at d65536) — neither large enough to offset a
10-vs-8-out-of-10 hard-reasoning result. Smaller footprint too (20.22 vs 21.9
GiB).

**`router.ini` change applied 2026-08-04 09:48, reverted the same day at ~13:00**
after the incident below:
```
model             = /root/models/nerkyor-thinking-distill-q4.gguf
mmproj            = /root/models/nerkyor-thinking-distill-mmproj-F16.gguf
spec-type         = draft-mtp
spec-draft-n-max  = 4
; spec-draft-p-min left at default — no benefit found, unlike fast's 0.3
ctx-size          = 131072
```

#### GPU hang incident — 2026-08-04, `fast` reverted to Ornith after ~3 hours live

The swap above went live at 09:51:30 (service restart after the commit). Real
usage was via OpenCode against the deployed alias, not the eval scripts.
Two crashes followed, both the same signature and both self-healing at the
kernel level:

```
radv/amdgpu: The CS has been cancelled because the context is lost. This context is innocent.
E srv  update_slots: decode() failed: vk::Queue::submit: ErrorDeviceLost
```

Host dmesg, same two moments:
```
amdgpu 0000:c4:00.0: ring comp_1.1.0 timeout, signaled seq=..., emitted seq=...
amdgpu 0000:c4:00.0: Starting comp_1.1.0 ring reset
amdgpu 0000:c4:00.0: reset compute queue (1:1:0)
amdgpu 0000:c4:00.0: Ring comp_1.1.0 reset succeeded
amdgpu 0000:c4:00.0: [drm] device wedged, but recovered through reset
```

| time | in-flight request | outcome |
|---|---|---|
| 12:28:02 | ~2,048 tokens into prompt processing (small request, on an instance already running cleanly for ~30 min) | request failed, ring reset, service auto-reloaded the model |
| 12:35:26 | 67,160 tokens into prompt processing (large request, on the freshly reloaded instance) | request failed, ring reset, service stayed up |

Ruled out rather than assumed:

| checked | result |
|---|---|
| context-length trigger | no — crashed at both ~2k and 67k tokens. **WRONG, see "Root cause, corrected" below** - the ~2k figure is tokens *into prompt processing of one request*, on a slot that had been warm for ~30 min and already held a large KV. It is not the context depth, which is what actually matters. Depth was never ruled out; it is the trigger |
| D-state / stuck process (the known GTT-exhaustion failure mode) | no — `ps aux` clean both times |
| silent CPU fallback | no — `/v1/models` showed `fast` still `loaded`, GTT/VRAM at normal levels (10.6/17 GiB) afterward |
| thermal/pre-existing driver flakiness | no — host dmesg shows **zero** `amdgpu` ring timeouts across the ~44 h of uptime before this swap; two in the first 3 h after it. **WRONG, see "Root cause, corrected" below** - `dmesg` reads the kernel ring buffer, which had wrapped. `journalctl -k` on the host shows two timeouts on 2026-08-03 (21:05, 22:08) hitting `coder`, before this swap existed. This single bad observation is what made the incident look model-specific. **Use `journalctl -k`, never `dmesg`, for anything older than the last few hours** |
| load-time/teardown race (the previously documented `DeviceLost` mode) | no — that mode shows the GPU idle at 0% with a clean allocator failure; both of these hit mid-decode with the GPU actively computing |

This is a fourth, previously undocumented `DeviceLost` signature on this box
(see the other two in "Watch for silent CPU fallback" and "A second failure
mode: DeviceLost on spec-model load" above) — a genuine `amdgpu` compute-ring
hang under active load, not an allocator or teardown issue. It self-heals at
the ring level (no D-state stranding, no CPU fallback this time) but kills
whatever request was in flight, which is a real problem for an agentic client
that can't tell the difference between "the model refused" and "the GPU ate
the request."

Root cause not confirmed at the time. The standalone evals (including the
full-ctx depth sweep above) never exercised opencode's actual traffic shape,
so the trigger could be something opencode does specifically, or something
about this model's own MTP draft head under sustained real-world load that
`llama-bench`/`probe-server.sh` don't reproduce. Ornith held the `fast` alias
for days across this repo's entire measurement history with no such hang, so
**reverted `fast` to Ornith** (`router.ini`, `opencode.json`) as the immediate
fix; Thinking-Distill's weights were kept on disk for further isolation.

##### Root cause and fix — same day, 2026-08-04 - SUPERSEDED, THIS DIAGNOSIS IS WRONG

> Kept as a record of what was believed at the time and of how the reasoning
> failed. The actual cause is in "Root cause, corrected" below. The
> `spec-draft-type-k/v = q8_0` setting this section introduced is worth keeping
> for the memory it saves, but it did not fix anything.

Reading `common/speculative.cpp`'s MTP implementation
(`common_speculative_impl_draft_mtp::process()`, around line 1402) shows the
draft context is not idle outside generation: on every prefill ubatch it runs
its own full `llama_decode()` catch-up over that batch, to keep the draft
model's KV cache in lockstep with the target's. That decode's bandwidth cost
is set by `--spec-draft-type-k/v`, which defaults to **F16**
(`common/common.h:340-341`) unless overridden - and since the draft context's
KV holds the whole accumulated conversation, that cost scales with total
context, not just the current request.

Ornith's `[fast]` stanza has always set `spec-draft-type-k/v = q8_0`
explicitly (halves that bandwidth - see the FAST comment block above). The
first Thinking-Distill deploy did not: the entry earlier in this table notes
it was "deliberately omitted here rather than carried over untested." Combined
with `n-max=4` (one more draft round per verify cycle than Ornith's 3), the
deployed config was running roughly double the draft-KV bandwidth of Ornith's
proven-stable config, scaling with the accumulated context - consistent with
both incidents (one on a session already ~30 min / a few thousand tokens
warm, one at 67k accumulated tokens).

**Fix applied:** added `spec-draft-type-k = q8_0` / `spec-draft-type-v = q8_0`
to the `[fast]` stanza, keeping `n-max=4` (no evidence pointed at `n-max`
itself, and dropping it would give up most of the throughput win for no
established reason).

**Verification, standalone port 8081, production `fast`/Ornith untouched
throughout:** ~20 minutes of active request traffic (two phases, 15:15-15:29
and 15:29-15:36) against the fixed config, crossing both incident depths -
small ~2k-token requests on an already-warm instance, and single-conversation
depth past 67k (reaching 102k tokens) - with concurrent two-slot bursts
throughout (`parallel=2`, matching production). Draft acceptance stayed
healthy, 0.73-0.98 typically (one 0.38 outlier under two-slot contention, not
a correctness signal). Zero `ErrorDeviceLost` in the server log; zero
`amdgpu` ring-timeout/reset lines in a continuous host `dmesg -T -w` capture
for the full window (`192.168.254.222`). GPU sampled live during requests at
97-99% busy, full clock, no throttling, no D-state. Cleanup verified: GTT/VRAM
returned to the exact pre-test production-only baseline (11.30 GiB / 15.85
GiB), no stray processes, no repo or systemd files touched.

**Confidence level - good but not proven-safe.** Twenty minutes of active
traffic crossing the critical depths twice is meaningfully reassuring, but
the two real incidents happened at ~30 and ~37 minutes into two *separate*
live sessions over a 3-hour organic-traffic window - longer cumulative
exposure and a bursty real-agent traffic shape this soak did not fully match.
**Redeployed to production 2026-08-04** on that basis; the plan is to watch
`journalctl -u llama-server` and host `dmesg` closely for the same signature
under real opencode traffic rather than run a longer synthetic soak first. If
it recurs, revert to Ornith again (`ornith35-mtp-q.gguf`, kept on disk as the
rollback target) and treat `n-max` as the next variable to isolate.

##### Second revert, same day: `fast` back to Ornith, Thinking-Distill moved to a temporary eval slot

The redeploy above went live on ~20 minutes of standalone soak, short of the
~30 minute mark where the first incident hit - "good but not proven-safe" by
its own assessment. Rather than let that redeploy accumulate its remaining
confidence under production traffic, **`fast` was reverted to Ornith a second
time** (`router.ini`, `opencode.json`, `README.md`) before any further
incident occurred. This is a risk-posture decision, not a new data point: no
additional crash was observed on the q8_0-fixed config in its brief second
production window.

Thinking-Distill's weights move to a new **`nerkyor-eval`** stanza in
`router.ini` - same q8_0-fixed config as the redeploy above (`n-max=4`,
`spec-draft-type-k/v=q8_0`), `load-on-startup=false`, not referenced by
`opencode.json` or any client. It shares port 8080 with production (`models-max
= 1` swaps it in on demand via `"model": "nerkyor-eval"`), so it is available
for further eval-script isolation without a separate standalone router
process, but is not a soak-test in itself - no eval traffic against it holds
the same evidentiary weight as time live under real opencode usage. Promote it
back to `fast` only after that gap is closed, not on standalone eval wins
alone.

##### Root cause, corrected - 2026-08-05/07

Both reverts above were wrong, and so was the retirement that followed them on
2026-08-05 (weights deleted, ~22 GiB). The hangs had nothing to do with this
model, its MTP head, or its draft KV type.

**Actual cause: amdgpu's compute-ring watchdog.** This kernel (7.0.14-8-pve)
defaults `amdgpu.lockup_timeout` to 2000 ms on all four rings - a graphics
frame deadline. At depth this workload submits flash-attention dispatches that
run in the high hundreds of ms, and with `sched_hw_submission = 2` a job's
watchdog starts while its predecessor is still executing, so two consecutive FA
dispatches share one 2 s budget. The full derivation, including the two
independent ways the 2 s figure was confirmed, is in `README.md` under
"ErrorDeviceLost at depth is the compute-ring watchdog".

**Fixed** on the host cmdline with
`amdgpu.lockup_timeout=10000,60000,10000,10000` (compute to 60 s), applied
2026-08-05. Result: **zero ring timeouts in the 2 days 3 hours since**, against
ten in the three days before, on the same workload. Plus a Vulkan-backend
change (`ggml_vk_queue_submit`) that aborts on device loss instead of serving a
dead device for 26 minutes.

**Why this model was wrongly convicted.** Two observational errors, both in the
"Ruled out rather than assumed" table above:

- The claim that the host had **zero** ring timeouts in the 44 h before the
  swap came from `dmesg`, whose ring buffer had wrapped. `journalctl -k` shows
  two on 2026-08-03 hitting `coder` - which has no MTP head, no drafter, and no
  speculation of any kind. That one bad reading is what made a
  platform-wide fault look model-specific.
- "Crashed at both ~2k and 67k tokens" treated tokens-into-a-request as
  context depth. Every incident was in fact deep: `n_tokens` 67160, 106011,
  115537, 127774.

Once depth is the variable, the F16-draft-KV story stops explaining anything:
`coder` has no draft context at all.

**Method lesson, and it is the expensive one here.** A plausible mechanism was
found for a fault whose *scope* had never been established, and a model was
convicted on it twice and then deleted. The mechanism was real code doing real
work - MTP's catch-up decode does scale with accumulated context - it just was
not what was failing. Before attributing a fault to the thing that changed,
establish whether the fault predates the change; on this box that means
`journalctl -k` on the **host** (`192.168.254.222`), not `dmesg`, and not the
LXC journal alone - three of the ten timeouts never reached the LXC at all,
because a crashed model child does not always get to log.

**Status 2026-08-07:** weights redownloaded, `nerkyor-eval` slot restored, and
the candidate is back to being judged on the evals it won. What it still owes
before taking `fast` is unchanged and is now the *only* thing outstanding: a
real-traffic soak longer than the ~20 min it got, crossing >67k and >100k
accumulated tokens, with the watchdog fix in place.

#### nerkyor/Qwen3.6-27B-DSV4Pro-GLM52-SFT-GPT55-RL-Coding-GGUF — rejected 2026-08-04, tested for `coder`

`Q4_LynnStyle/...-Q4-LynnStyle.gguf`, 18.23 GiB, plus a
`Q4-imatrix-MTP-draft.gguf` sidecar, 2.28 GiB — both SHA256-verified against
the repo's own `SHA256SUMS`/`manifest.json`. **Confirmed dense via the raw
GGUF header: zero expert tensors anywhere.** `general.architecture` reads
`qwen35` (dense), matching the HF `dense` tag and the model card's own
"LynnStyle Dense" framing exactly — nothing mislabeled here, unlike the
current `coder`. The MTP draft is an unusual separate sidecar (the model's
own extracted nextn layer plus a full embed/output copy) loaded via
`--model-draft`, not embedded like the other three nerkyor releases.

| condition | pp d0/4k/16k | tg d0/16k/32k | served pp/tg | acceptance |
|---|---|---|---|---|
| `bench.sh` (no spec) | 99.36 / 86.95 / 75.63 | **4.12 / 3.87 / 3.69** | — | — |
| served, vendor's own MTP draft, n-max=2 | — | — | 81.2 median / **8.49 median** | 0.82-0.84, len 2.65-2.68 |

This reproduces this repo's own dense-27B precedent (Qwopus3.6-27B-Fusion 4.6
t/s base; Fable-Fusion-711 8.3 t/s with MTP, 0.66 acceptance) almost exactly —
confirming it a third time. Evals run (standalone :8081, c=32768):
`check-output.sh` OK/coherent, `reason-eval.sh` 8/8 in 174 s (4,884c),
`code-eval.sh` 4/4 in 224 s / 19 turns — same score as `fast`/`coder` but
2.2-2.4x slower wall time purely from throughput. `reason-eval-hard.sh`,
`code-eval-hard.sh` and `code-eval-opencode.sh` were deliberately skipped: the
throughput result alone is already dispositive per this repo's established
rule that dense models don't work here, and three more multi-turn tiers at
~8.5 t/s would have cost roughly an hour for a result that can't change the
verdict.

**Verdict: reject, confirmed on architecture and on two independent
throughput measurements.** Decent quoted quality (vendor's own 92% MMLU / 82%
Coding100, and this box's own 4/4 and 8/8 passes) cannot compensate for a
3-6x throughput deficit against the `coder` slot it targets by name.

---

# Coder slot for opencode — sweep of 2026-08-03

Researched 2026-08-03 against a specific complaint: **`coder`
(Qwen3-Coder-Next 80B-A3B) is too slow for opencode, and opencode's `init` step
alone is the visible symptom.** That step scans the repo, concatenates many
files into one very large prompt, and emits a single long AGENTS.md-style
generation — so it is dominated by **prefill at large context** and
**generation at depth**, not by tg at d0. This is a different ranking axis from
the 2026-08-02 `deep` sweep above, which stays as written.

**Headline: no new model needs to be downloaded. The fix is already in the
lineup and is measured, not estimated — `fast` beats `coder` on both axes at
every depth in this repo's own sweep.** The one new-model candidate worth a
narrow look, Qwen3-Coder-30B-A3B-Instruct, is architecturally well-matched to
the problem but carries a ~19-point SWE-bench regression against the incumbent,
which is a bad trade for a slot used on every turn rather than just at init.

## The measured comparison that settles it

From `README.md`'s depth sweep (same build, `llama-bench`, Vulkan confirmed):

| model | KV | d0 | d8192 | d32768 | d65536 |
|---|---|---|---|---|---|
| `fast` pp512 | q8_0 | 343.80 | 265.99 | 167.49 | **111.30** |
| `coder` pp512 | q8_0 | 228.91 | 190.54 | 126.27 | **87.11** |
| `fast` tg64 | q8_0 | 25.31 | 24.12 | 20.93 | **17.86** |
| `coder` tg64 | q8_0 | 18.58 | 17.67 | 15.74 | **13.68** |

`fast` leads prefill by 28-50% and generation by 27-31% across the entire depth
range an opencode init traverses. It also wins the quality axis outright —
SWE-bench Verified 75.6 vs 70.6, Terminal-Bench 2.0 64.2 with no published
`coder` equivalent — and exposes `enable_thinking: false`, which strips
reasoning overhead from a tool loop where that cost is paid once per turn
across dozens of turns.

This is not a new finding so much as an unread one: `README.md` already notes
`assist` "prefills 24% faster, which tells on the very long contexts an agent
accumulates." The same logic applies to `fast` over `coder`, with a larger
margin and no vision tax.

**Recommended first action, costing nothing: point opencode at `fast` and
re-time the init step.** If that fixes the complaint, this sweep is closed and
no download is spent. Only if a dedicated code-only slot is still wanted for
reasons outside throughput — smaller footprint, no mmproj, faster swap-in —
does the candidate below become relevant.

## Priority order

| # | model | arch | total/active | quant+size+bpw | experts | full-attn layers | MTP/drafter | throughput | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `fast` (already deployed) | `qwen35moe` family | 35B/3B | Ornith-1.0-35B MTP-APEX, 21.9 GiB | 256 (top-8) | 10 of 40 (GDN, interval 4) + MTP head — **corrected 2026-08-11, was "41 of 41"** | in-model MTP, wired | pp 343.8 -> 111.3, tg 25.3 -> 17.9 (**measured**) | **re-route here first — no download** |
| 2 | Qwen3-Coder-30B-A3B-Instruct | `qwen3moe` | 30.5B/3.3B | UD-Q4_K_XL, 16.45 GiB, 4.63 bpw | 128 (top-8) | 48 of 48 | DFlash exists, **no GGUF** | est. pp d0 350-425; tg d0 21-27, d65536 11-18 | narrow test only, if a dedicated slot is still wanted |
| — | Qwen3.6-35B-A3B (vanilla) | `qwen35moe` | 35B/3B | — | 256 (top-8) | 10 of 40 (GDN, interval 4) | — | n/a | reject — same hybrid shape as `coder`, no reason to expect better prefill |
| — | GLM-4.5-Air | `glm4moe` | 106B/12B | — | — | — | — | ceiling ~12 t/s | reject — 12B active fails the ceiling check on the exact axis being fixed |
| — | MiniMax-M2.x | `minimax-m2` | 229B/10B | — | 256 (top-8) | 62 of 62 | DFlash (M2.5/2.7) | n/a | reject — measured 65% depth collapse, unchanged |
| — | `coder` (incumbent) | `qwen3next` | 80B/3B | UD-Q4_K_XL, ~46 GiB | 512 (top-10) | 12 of 48 (GDN hybrid) | DFlash, wired | pp 228.9 -> 87.1, tg 18.6 -> 13.7 | the thing being complained about |

## Why `coder` prefills slowly — the shape to avoid

The `deep` sweep already recorded that `coder` realizes only **0.45** of its tg
ceiling, the bottom of the measured band, and attributed it to 512 experts plus
a hybrid GDN stack. Prefill points the same direction for a related reason:
prompt processing is compute- and routing-bound rather than purely
bandwidth-bound, so a top-10-of-512 router runs far more expert-dispatch work
per token than a top-8-of-128 one, and the GDN layers do not batch across a
long prompt the way full attention does. `coder` peaks at 32.94 GiB GTT even at
d65536 — it is not memory-starved, it is routing-bound.

**The heuristic for this slot: fewer experts and a lower top-k beat a larger
total parameter count.** That is the opposite of the `deep` slot's preference
and is why the two slots should not share a shortlist.

## 1. Qwen3-Coder-30B-A3B-Instruct — the only new candidate worth a look

Repo `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`. Arch
`Qwen3MoeForCausalLM` -> GGUF `qwen3moe`, **confirmed present in this tree** at
`src/llama-arch.cpp:37` (`LLM_ARCH_QWEN3MOE`) — the same converter path `fast`
and `assist` already use, not a new arch.

**Config, verified from `config.json`:** 48 layers, hidden 2048, 32 query heads
/ 4 KV heads / head_dim 128, standard GQA with no sliding window and no
hybrid/linear-attention fields, 128 experts top-8, 262K native context. **All
48 layers are full attention** — no GDN discount, unlike `coder`'s 12 of 48.

**Sizes, verified via HF tree API:**

| quant | bytes | GiB | bpw |
|---|---|---|---|
| UD-Q3_K_XL | 13,806,312,608 | 12.86 | 3.62 |
| **UD-Q4_K_XL** | 17,665,334,432 | **16.45** | 4.63 |
| UD-Q5_K_XL | 21,740,305,568 | 20.25 | 5.70 |
| UD-Q6_K_XL | 26,340,328,608 | 24.54 | 6.91 |
| Q8_0 | 32,483,935,392 | 30.26 | 8.52 |

**KV at 131072, q8_0:** 48 layers x 2 (K+V) x 4 KV-heads x 128 head_dim x
~1.06 bytes/elem ~= 6.4 GiB. Higher than `coder`'s hybrid-discounted KV, but
cheap in absolute terms thanks to the 8:1 GQA ratio.

**Pool arithmetic:** 16.45 GiB weights + 6.4 GiB KV = **22.85 GiB of 76**.
Size is not the constraint here — there is room to take UD-Q6_K_XL (30.9 GiB
total) or even Q8_0 (36.7 GiB) if quality per bit matters more than swap time.
That is a genuinely different position from every candidate in the `deep`
sweep, all of which were pinned against the ceiling.

**Why the prefill claim is credible rather than invented:**
`Qwen3-VL-30B-A3B-Instruct` — deployed here as `assist` — has an **identical
text backbone** (48 layers, 128 experts top-8, 32Q/4KV, head_dim 128, confirmed
from its own `config.json`). `assist` measures **pp512 424.4 t/s / tg128 36.0**
on this box in `llama-bench`, against `coder`'s 228.9 / 18.6. That is a
same-hardware, same-shape data point, not an extrapolation from the formula.

**Throughput estimate:** active 3.3B x 0.579 bytes/param = 1.91 GB/token ->
ceiling 74/1.91 = **38.7 t/s**. 128 experts and no hybrid routing argue for the
top of the 0.45-0.75 band, so base tg **21-27 t/s**. But full attention on 100%
of layers means KV reads grow faster with depth than the incumbent's, so
**d65536 tg is a real unknown, plausibly 11-18 t/s** — it could land either
side of `coder`'s measured 13.68. Prefill is the stronger case: even applying
`fast`'s own 68% cumulative pp decay, a 350-425 t/s d0 baseline still reaches
~120-150 t/s at d65536, comfortably above `coder`'s 87.1.

**Thinking mode:** none. The model card states it "supports only non-thinking
mode and does not generate thinking blocks" — nothing to disable, and no
per-turn reasoning tax in the tool loop.

**Speculation:** `z-lab/Qwen3-Coder-30B-A3B-DFlash` exists (473.9 MB, BF16
safetensors) claiming 2.6-3.5x with acceptance 6.4-8.1. `draft-dflash` is
already wired and proven here, and `convert_hf_to_gguf.py` has a generic
`--target-model-dir` path — but **no pre-made GGUF for this drafter was
found**, so it needs manual conversion. Unlike the incumbent's, this is not
download-and-go.

**Tool calling:** BFCL-v2 76.63%, documented function-call format for agentic
clients (Qwen Code, CLINE). No opencode-specific evidence found either way.

**Why it might not work — the honest case against.** SWE-bench Verified is
**51.6-51.9, roughly 19 points below `coder`'s 70.6 and 24 below `fast`'s
75.6**; Terminal-Bench 23.8 against `fast`'s 64.2. This is the older, smaller
model that Qwen3-Coder-Next supersedes, so the gap is expected rather than
anomalous. The slot serves the whole session, not just init — swapping here
trades coding quality on every turn to fix one step, and option 1 fixes that
same step with no quality cost at all. Also unverified: no depth sweep exists
for this model or for `assist`, so the tg-at-depth figures above rest on the
architectural analogy plus the formula, and no non-termination testing exists
on this box.

## Rejected at research time, with reasons

| model | reason |
|---|---|
| Qwen3.6-35B-A3B (vanilla) | `config.json` confirms hybrid GDN, `full_attention_interval = 4`, 10 of 40 full-attention — architecturally the same shape as `coder`, so no reason to expect better prefill. SWE-bench 73.4 is single-source and only marginally above 70.6. Already passed over in the `deep` sweep for losing to `fast`. |
| GLM-4.5-Air (106B/12B) | 12B active gives a ~12 t/s ceiling before any realized-fraction discount — worse than the incumbent on the axis being fixed. Already noted above as below every current slot on SWE-bench (57.6). |
| MiniMax-M2.x (M2.1/2.5/2.7) | 62 of 62 full-attention layers, measured 65% tg collapse by d32768 on this box. Newer DFlash drafters do not touch the architectural cause. Unchanged. |
| GLM-4.7-Flash | Already tested and rejected here (`failed to create MTP context`). No material change found; not re-tested. |
| Nemotron 3 Super, Kimi K3, Trinity-Large, Hy3, DeepSeek-V4-Flash, GLM-4.7 full | Carried forward unchanged from 2026-08-02 — all fail on pool size or missing/gated evidence, none for reasons specific to the `deep` slot. |

## What was verified vs. inferred

**Verified:** `LLM_ARCH_QWEN3MOE` and `LLM_ARCH_QWEN3NEXT` present in
`src/llama-arch.cpp`; all GGUF byte sizes via the HF tree API; both
`config.json` layer/expert/head configurations; every `fast`/`coder`/`assist`
throughput number quoted from `README.md`.

**Inferred, not measured:** the tg-and-pp-at-depth estimates for
Qwen3-Coder-30B-A3B-Instruct (rest on the `assist` backbone analogy plus the
ceiling formula); the routing-bound explanation for `coder`'s slow prefill.

**Not found at all:** any depth sweep for `assist` or the candidate;
opencode-specific tool-calling or init-step evidence for any model here; any
confirmation that a converted DFlash drafter reproduces its claimed speedup on
this Vulkan path.

---

# Beating `fast` at agentic coding — sweep of 2026-08-03 (second pass)

Researched 2026-08-03, same day as the sweep above but against a **different and
harder brief**: find a model that is genuinely *better at agentic coding than
`fast`*, accepting some speed loss to get it. The sweep above asked which
existing alias handles opencode's prefill-bound init best and answered `fast`.
This one asks what beats `fast` outright.

**The bar:** SWE-bench Verified **75.6**, Terminal-Bench 2.0 **64.2** (also
SWE-bench Multilingual 50.4, Lite 69.3). Measured here: pp512 343.8 -> 111.3,
tg64 25.3 -> 17.9.

**Speed floor applied:** `coder`'s measured throughput — pp512 228.9 (d0) /
87.1 (d65536), tg64 18.6 / 13.7. Rationale: `coder` was already rejected *for
being too slow*, so anything slower than it is not a candidate no matter how it
scores. Target band was within 25-40% of `fast`.

## Metric correction — SWE-bench is the wrong lead criterion here

This sweep was first written ranking on SWE-bench Verified, with
Terminal-Bench 2.0 as a tiebreaker. **That weighting is wrong for an opencode
slot and has been corrected below.** Recording why, because the error is easy
to repeat:

1. **SWE-bench scores are scaffold-dependent and the scaffold is not
   opencode.** Published figures come from Agentless (a fixed
   localize-then-patch pipeline with no real agency), OpenHands, mini-SWE-agent
   or vendor-custom harnesses, usually unlabelled. Nemotron's 60.47 is
   explicitly "(OpenHands)"; most others do not say. A model tuned for a
   pipelined harness can score well without being good in a free-form tool
   loop. Cross-model comparison at +/-3 points is close to meaningless.
2. **It cannot see the thing that started this investigation.** SWE-bench does
   not score latency or token economy at all. A model emitting 30k reasoning
   chars before each tool call scores identically to one emitting 500 — but in
   an interactive client one is unusable. The original complaint was "init
   takes too long."
3. **It does not test edit-format compliance.** opencode depends on well-formed
   tool calls and exactly-matching search/replace edits. SWE-bench harnesses
   frequently retry or constrain the format, so malformed-call rates never
   surface.
4. **Short-horizon and Python-only.** Mostly small localized bug fixes across
   12 Python repos; opencode sessions accumulate long multi-turn contexts.
5. **This repo already has the counterexample.** Both models ever rejected on
   this box failed by *not terminating*, and the note above says it plainly:
   "quality failures throughput testing would have scored as wins." No
   published benchmark predicted either.

**Better published proxies, in order for this slot:** Terminal-Bench 2.0 (real
terminal, real agent harness — closest to opencode), Aider polyglot (scores
diff/edit-format compliance directly, multi-language), tau2-bench / BFCL for
tool-call reliability. **Best signal of all is local** — see `code-eval.sh`,
written for exactly this gap.

### First local measurement (`code-eval.sh`, 2026-08-03)

| alias | score | wall | turns | edit misses | botched calls | reasoning |
|---|---|---|---|---|---|---|
| `fast` | **4/4** | 93 s | 19 | 0 | 0 | 4,342 ch |
| `coder` | 2/4 | 162 s | 36 | 0 | 0 | 0 ch |

`coder` took 1.9x the turns and 1.7x the wall time for half the score, and
**stalled outright** on the task requiring a new function — 24 turns, budget
exhausted, the same non-termination signature that rejected Ornith-3.6 and
MiniMax-M2.1. Its fourth task never scored because the alias failed to load
(see below). This is the first evidence on this box that `fast` is the better
agentic coder that was not borrowed from a vendor's benchmark table, and it
agrees with the throughput argument in the sweep above.

**But the tier saturates on `fast` at 4/4**, exactly as `reason-eval.sh`
saturates at 8/8. It justifies the incumbent and will catch a regression; it
**cannot rank a candidate claiming to beat `fast`**. A model scoring 4/4 has
only failed to be worse. Ranking above the incumbent needs a harder tier, the
way `reason-eval-hard.sh` was built for the `deep` slot — that tier does not
exist yet and is the obvious next piece of work if this search continues.

**Separately, `coder` currently fails to load on the box.** Repeatable
`radv/amdgpu: Not enough memory for command submission` escalating to
`vk::DeviceLostError` during load, with system RAM nearly free (41 GB) and the
router alive. An infrastructure fault, not a model property, but it means the
`coder` alias is unusable as things stand.

**What the re-ranking changes:** not the headline. Nothing here was rejected
*because of its score* — the binding gates were dense-architecture and pool
size (128 GiB, 390 GiB, 82 GiB against 76), both metric-independent. What it
changes is the near-miss ordering, corrected in the two sections below.

| | SWE-V | TB 2.0 |
|---|---|---|
| `fast` (the bar) | 75.6 | **64.2** |
| Qwen3.6-27B | 77.2 | **59.3** |
| Step-3.5-Flash | 74.4 | **51.0** |
| Nemotron 3 Super | 60.5 | **31.0** |

`fast` scores unusually high on Terminal-Bench relative to its SWE-bench, so
weighting the more relevant metric makes it *stronger* against the field, not
weaker.

## Headline: nothing clears the bar

Every open-weight model found that credibly beats 75.6 and/or 64.2 falls into
exactly one of two buckets:

1. **Dense** — disqualifying on this box per `README.md`'s own rule ("Treat
   'dense' as disqualifying on this box unless the weights are sub-2-bit"),
   backed by three measured dense models at 4.6-17.8 t/s.
2. **Frontier-scale MoE (200B-1T total)** — smallest usable GGUF is 1.7-5.1x
   the 76 GiB pool, verified by byte count, even at the lowest bit-width that
   still clears the ~3 bpw floor.

Every mid-size MoE that *does* fit the pool and clear the speed floor scores
**below** 75.6/64.2. There is no candidate to hand to a benchmark run.

**The "exceeds speed budget, flagged anyway" table is empty** — and that is
itself the finding. Nothing reached the state of "clears quality, fits pool at
>=3 bpw, supported arch" and *then* failed on speed. Everything failed
architecture or pool size first, which are harder and earlier gates. The speed
budget was never the binding constraint.

## The one model that clears a bar — and why it still loses

**Qwen3.6-27B**, SWE-bench Verified **77.2** (clears 75.6). It is the only
model found that beats `fast` on a quality axis while being small enough to
even discuss. It loses anyway, on three independent grounds:

- **Terminal-Bench 2.0 59.3 — below `fast`'s 64.2.** It clears one of the two
  bars, not both.
- **It is dense.** 64 layers with a 3:1 GDN-to-full-attention hybrid, but the
  hybrid pattern cuts KV cost, not weight-read cost — every parameter is read
  every token.
- **Throughput is measured, not estimated.** `tg_ceiling = 74 / (27e9 x 0.570)
  = 4.81 t/s`, and this repo has already measured two same-size dense 27Bs:
  Qwopus3.6-27B-Fusion at **4.6 t/s** (4% off the formula) and Fable-Fusion-711
  with MTP at **8.3 t/s**. So `unsloth/Qwen3.6-27B-MTP-GGUF` lands at roughly
  **7-9 t/s** — about a third of `fast`, and well under `coder`'s already-
  rejected floor.

**Under the corrected metric weighting its case collapses entirely.** The 77.2
SWE-bench figure was the *only* argument for considering a dense model at all,
and SWE-bench is the metric this slot should weight least. On Terminal-Bench
2.0 — the closest published proxy for opencode — it scores **59.3 against
`fast`'s 64.2**, so on the metric that matters it is not a near-miss, it is
simply worse. Combined with dense architecture and 7-9 t/s, there is no
remaining reason to spend a download.

This was previously written as "the one model to benchmark if the speed floor
is wrong." **That is withdrawn.** The speed floor was never what was actually
blocking it. If a dense 27B is to be tried anyway for reasons outside these
numbers, the entry is `unsloth/Qwen3.6-27B-MTP-GGUF` UD-IQ4_XS (15.4 GiB,
4.56 bpw, arch `qwen35`, `LLM_ARCH_QWEN35` confirmed at
`src/llama-arch.cpp:41`) — but run `code-eval.sh` against `fast` first and see
whether there is a gap worth closing at all.

## Priority order — all rejects

| model | arch | total/active | quant + size + bpw | experts | full-attn layers | MTP/drafter | est. tg | verdict |
|---|---|---|---|---|---|---|---|---|
| Qwen3.6-27B | `qwen35` (confirmed) | 27B **dense** | UD-IQ4_XS, 15.4 GiB, 4.56 bpw | n/a | 64/64 (3:1 GDN hybrid, dense) | MTP repo exists | **4.8 base, 7-9 MTP** | **TB 59.3 < 64.2** — worse on the metric that counts; dense; below floor. SWE 77.2 is the least relevant number here |
| Step-3.5 / 3.7-Flash | `step35` (confirmed) | 196-198B/11B | IQ2_S ~69.2 GiB | many, 3:1 SWA hybrid | 1 of 4 | none found | ~11-18 | **TB 51.0 < 64.2, a 13.2-point gap.** Right shape, wrong scores — quant also under floor |
| Qwen3.5-122B-A10B | `qwen35moe` (confirmed) | 122B/10B | UD-IQ4_XS, 57.7 GiB, 4.06 bpw | 256 top-8 | 12/48 | native MTP, in-tree | 6.6-11.6 | SWE 72.0-72.4, TB 41.6-49.4 — both short |
| Nemotron 3 Super | `nemotron_h_moe` (confirmed) | 120B/12B | UD-Q2_K_XL, 50.9 GiB, 3.64 bpw | unclear | mostly Mamba-2 | claimed | ~7-12 | SWE 60.5, TB 31.0 — **now resolved from "watch" to no** |
| MiniMax-M3 | `minimax-m3` (confirmed) | 428B/22-23B | UD-IQ1_M, **128.41 GiB verified** | 128 top-4 + shared | 3 dense + MSA sparse | none | n/a | SWE **80.5** clears bar — 69% over pool at its *smallest* quant, already sub-3 bpw |
| Kimi K2.6 / K2.7 Code | deepseek-v3-style | 1.03T/32B | UD-Q2_K_XL, **390.37 GiB verified** | 384 top-8 | — | none | n/a | SWE **80.2** clears bar — 5.1x the pool |
| DeepSeek-V4-Flash | `deepseek4` (confirmed) | 284B/13B | ~82.5 GiB min | — | — | — | n/a | SWE **80.6** clears bar — exceeds pool |
| GLM-4.7 / 4.6 | `glm4moe` | 355B/32B | far over pool | — | — | — | n/a | SWE 73.8 / 68.0 — short *and* over pool |
| Devstral 2 / Small 2 | dense (Mistral) | 123B / 24B dense | ~70+ / ~15 GiB | n/a | dense | none | low | dense; SWE 72.2 / 68.0 short anyway |
| Kimi-Dev-72B | dense | 72B dense | ~40+ GiB | n/a | dense | none | ~2-4 | dense; SWE 60.4 |
| Qwen3-Coder-480B-A35B | `qwen3moe` | 480B/35B | Q2_K 175 GB | 160 top-8 | 48/48 | none | n/a | superseded by Coder-Next; SWE 50-60; over pool |
| Seed-Coder-8B | dense | 8B dense | small | n/a | dense | none | fine | SWE ~19-56, far below bar |

## The near-miss, re-ranked — it is not as near as first written

**Step-3.5-Flash / Step-3.7-Flash** (`step35`, confirmed in-tree) was first
recorded here as the "softest reject" on the strength of **SWE-bench Verified
74.4**, only 1.2 points short. **That framing was an artifact of ranking on the
wrong metric.** On Terminal-Bench 2.0 it scores **51.0 against `fast`'s 64.2 —
a 13.2-point gap, not 1.2.** Weighted properly it is a wide miss, not a
close-run thing, and it should not be described as nearly qualifying.

It still fits the "large-total, low-active, hybrid-attention" shape this box
likes (196-198B/11B, 3:1 sliding-window-to-full ratio, 1 full-attention layer
of every 4), and its blocking gate is unchanged from the 2026-08-02 note above:
IQ2_S at 69.2 GiB leaves ~6.8 GiB for KV against a 76 GiB pool, and 2 bpw sits
under the quant floor. Worth watching for the architecture, but a future point
release would need to move Terminal-Bench a long way, not just nudge SWE-bench
past 75.6.

## What would change the answer

- A **Step-3.x point release** crossing 75.6 with a >=3 bpw quant under 60 GiB.
- **Ling-3.0-flash** finally releasing weights (124B/5.1B — the active-param
  count this box wants). Still no HF weights as of 2026-08-03, one day past the
  announced open-source date.
- **Any 200B-class MoE shipping a >=3 bpw quant under 60 GiB.** MiniMax-M3,
  Kimi K2.6 and DeepSeek-V4-Flash all clear the quality bar comfortably (80.5 /
  80.2 / 80.6 SWE-bench) and are blocked purely on size. This is the most
  likely source of a future win — the quality already exists, only the
  quantization does not. Caveat per the metric correction above: no
  Terminal-Bench 2.0 figure was found for any of the three, so their lead on
  the metric this slot should weight is **unmeasured, not established**.
- **`code-eval.sh` finding a real gap.** The whole premise is that `fast` is
  good enough at agentic coding. That has never been measured locally — only
  inferred from published scores of questionable relevance. Run it against
  `fast` and `coder` first; if `fast` scores well, this slot needs nothing and
  the search can stop.

**Withdrawn:** the earlier bullet "deciding the speed floor is wrong, which
promotes Qwen3.6-27B-MTP to a benchmark candidate." The speed floor was never
what blocked it — Terminal-Bench 59.3 against `fast`'s 64.2 does.

## Rejected at research time, with reasons

| model | reason |
|---|---|
| Qwen3.6-27B | Fails TB 59.3 < 64.2 — worse than `fast` on the metric this slot should weight; its SWE 77.2 is the least relevant number available. Also dense (disqualifying per `README.md`) and 7-9 t/s with MTP, anchored to two measured same-size dense 27Bs on this box rather than the formula alone. Three independent rejections. |
| Step-3.5 / 3.7-Flash | TB 51.0 < 64.2 — a 13.2-point gap. SWE 74.4 < 75.6 as well. Previously called the "softest reject" on the SWE gap alone; that was a metric artifact and is corrected. |
| Qwen3.5-122B-A10B | Re-examined under the relaxed speed budget per brief: verdict unchanged. 72.0-72.4 < 75.6. The relaxed budget does not help a model that fails on quality. |
| Nemotron 3 Super 120B-A12B | Prior sweep flagged "insufficient evidence — watch." **Now resolved:** NVIDIA's own arxiv paper reports SWE-bench Verified (OpenHands) 60.47 and Terminal-Bench Core 2.0 31.00. Clear no, from the technical report rather than marketing. |
| MiniMax-M3 | SWE 80.5 clears the bar. Smallest GGUF verified via HF tree API: `unsloth/MiniMax-M3-GGUF` UD-IQ1_M, 128,411,281,152 bytes = 128.41 GiB — 69% over pool, and already ~2.4 bpw, under the floor. No smaller option to retreat to. |
| Kimi K2.6 / K2.7 Code | SWE 80.2 clears the bar. Smallest practical GGUF verified: `unsloth/Kimi-K2.6-GGUF` UD-Q2_K_XL, 390,370,707,888 bytes = 390.37 GiB (~3.03 bpw, at the floor not above it) — 5.1x the pool. |
| DeepSeek-V4-Flash | SWE 80.6 clears the bar; exceeds pool at 82.5 GiB minimum. Unchanged. |
| GLM-4.7 / GLM-4.6 | SWE 73.8 / 68.0, both short; 355B total also exceeds pool regardless. |
| GLM-4.5-Air | SWE 57.6. Unchanged. |
| GLM-4.7-Flash | Already tested and rejected here (`failed to create MTP context`). No fix found. |
| Devstral 2 (123B), Devstral Small 2 (24B) | Dense. SWE 72.2 / 68.0 short anyway. |
| Kimi-Dev-72B | Dense. SWE 60.4. |
| Seed-Coder-8B | SWE ~19-56, superseded lineage. |
| Qwen3-Coder-480B-A35B | SWE 50-60 (superseded by Coder-Next); 175 GB at Q2_K, 2.3x pool. |
| MiniMax-M2.x (2.1/2.5/2.7) | 62/62 full attention, measured 65% depth collapse here. Self-reported SWE figures conflict (56-78) and do not address the architectural cause. |
| Ling-3.0-flash | Still unreleased — no HF weights, no GGUF, as of 2026-08-03. |
| Qwen3.6-35B-A3B (vanilla) | SWE 73.4 single-source, short; superseded by `fast`. |

## What was verified vs. inferred

**Verified:** `LLM_ARCH_QWEN35` (`llama-arch.cpp:41`), `LLM_ARCH_DEEPSEEK4`
(:80), `LLM_ARCH_MINIMAX_M3` (:130), `LLM_ARCH_STEP35` (:140),
`LLM_ARCH_QWEN35MOE` and `LLM_ARCH_NEMOTRON_H_MOE` all present in this tree.
MiniMax-M3's smallest GGUF (128,411,281,152 bytes) and Kimi-K2.6's
(390,370,707,888 bytes) via the HF tree API. The dense-27B throughput anchors
(4.6 base / 8.3 MTP) quoted directly from `README.md:147-148`, not re-derived.
The dense-disqualifying rule at `README.md:154`.

**Inferred, not measured:** every throughput figure in the table other than
Qwen3.6-27B rests on the ceiling formula plus the 0.45-0.75 band, none
re-measured here. Kimi K2.6/K2.7's DeepSeek-V3-compatible arch claim was not
confirmed against actual GGUF metadata — moot given the size rejection.

**Not found at all:** independent (non-vendor) corroboration of GLM-4.7's 73.8;
any Terminal-Bench 2.0 figure for MiniMax-M3, Kimi K2.6, or DeepSeek-V4-Flash;
any depth-scaling data for MiniMax-M3's MSA mechanism.

---

# ModelScope sweep for `assist` and `coder` — 2026-08-03 (third pass)

Researched 2026-08-03 against a different **source** rather than a different
brief: sweep Alibaba's ModelScope hub for anything the HF-centric sweeps above
would have missed. ModelScope carries Chinese-lab releases (Qwen, GLM,
Ling/Bailing, MiniMax, StepFun, InternLM, Skywork, Moonshot, Baichuan, Yi)
sometimes earlier than HF, sometimes exclusively, occasionally with first-party
GGUFs. Gates carried forward unchanged from the sweeps above.

**Headline: nothing on ModelScope beats `assist` or `coder`.** Nothing reached
the state of "clears quality, fits pool at >=3 bpw, supported arch" — every
candidate failed an architecture or packaging gate first, so no per-candidate
deep-dive section follows. The nearest thing, InternVL3.5-30B-A3B, is
architecturally *identical* to `assist`'s text backbone, so there is no
arithmetic case to make even before touching benchmarks.

**Read this sweep's sourcing caveat before trusting a size.** Both
`modelscope.ai` and `modelscope.cn` are JS-rendered SPAs that `WebFetch` cannot
execute, and the file-tree API paths tried all 404'd. **No byte size in this
section was read from ModelScope itself** — sizes come from HF mirrors of the
same releases. That is the usual corroboration path for these repos and no
candidate here got far enough to need a size, but a future ModelScope sweep
that reaches the pool-arithmetic stage will need a different fetch method
(rendered browser or the official SDK), not `WebFetch`.

On the URL the sweep was asked about: `modelscope.ai` serves the same
repo/model-card content as `modelscope.cn` under an English-first URL, and
third-party coverage describes it as the same Alibaba/DAMO MaaS platform. **No
redirect was observed** — the fetch tool never reported one, which is weak
evidence against a redirect rather than proof of one. Treat the two as the same
catalog.

## Priority order — all rejects

| model | arch | total/active | quant+size+bpw | experts | full-attn layers | MTP/drafter | est. tg | verdict |
|---|---|---|---|---|---|---|---|---|
| GLM-4.6V (full) | `glm4v`-projected MoE | 106B/12B | not sized (rejected before quant search) | 128 | full attn, no hybrid | none found | **~6-9 (est., formula only)** | reject — 12B active fails the ceiling check against a slot already running 36 t/s on 3B active |
| GLM-4.6V-Flash | dense VLM | 9B **dense** | Q4_K_M ~5-6 GiB (HF mirror) | n/a | dense | none | dense-rule | reject — dense, well over the sub-4B routine exception |
| InternVL3.5-30B-A3B | Qwen3MoE backbone + InternViT | 30.5B/3.3B | **no GGUF found** | 128 top-8 | 48 of 48 | none found | ~parity with `assist` (est., from arch identity) | reject — identical active/expert config to the incumbent, so no throughput case exists either way; benchmark parity only; no GGUF+mmproj packaging |
| Ming-flash-omni-2.0 | `bailingmoe2` + omni towers | 100B/6.1B | no GGUF/mmproj found | — | full attn, 32 layers | tensors present, **not wired** | n/a | reject — no vision/audio tower support in this tree; text-backbone MTP is inert here |
| Ling-flash-2.0 / Ling-mini-2.0 | `bailingmoe2` | 100B/6.1B, 16B/1B | GGUFs exist | 1:32 activation | **all layers full attention** | tensors present, not wired | unmeasured | unchanged reject — superseded, no fresh agentic evidence; full attention everywhere raises the MiniMax-M2.1 depth concern |
| Skywork-R1V3-38B | dense (InternViT-6B + R1-Distill-Qwen-32B) | 38B **dense** | GGUF exists | n/a | dense | none | dense-rule | reject — dense, far over the sub-4B exception |
| MiniMax-M2.5 / M2.7 coder variants | `minimax-m2` | 229B/10B | large | 256 top-8 | **62 of 62** | DFlash published | n/a | unchanged reject — measured 65% depth collapse on M2.1 is architectural; no TB 2.0 figure found for any point release |
| Qwen3.6-Coder / 3.7-Coder / 3.6-VL / 3.7-VL | — | — | — | — | — | — | — | **do not exist** as of 2026-08-03 — searched specifically |

## One correction to the record, and it is not a new candidate

`bailingmoe2` (Ling-flash-2.0 / Ling-mini-2.0) is **natively implemented** in
this tree, not merely enum-registered: `src/models/bailingmoe2.cpp` builds
standard multi-head attention with RoPE + QK-norm on every layer and a standard
`build_moe_ffn` MoE with a shared expert — no exotic ops, no vendor fork needed.
This confirms rather than changes the 2026-08-02 entry ("Arch supported,
superseded, no fresh agentic evidence").

Two details worth keeping:

- **Its NextN/MTP tensors are loaded but explicitly not wired into the graph**
  (stated in a comment in that file). So a Ling GGUF advertising MTP would get
  no speculation benefit here — the same declared-but-unusable shape that killed
  GLM-4.7-Flash, differing only in that it fails silently rather than erroring.
- **Ling-flash-2.0 is full attention on every layer**, correcting a possible
  conflation with the `BailingMoeV2.5` hybrid in Ling-2.6-flash. That puts it in
  the MiniMax-M2.1 depth-collapse category, not the cheap-KV category.

Ling-2.6-flash still needs a vendor fork (`BailingMoeV2.5` is a distinct hybrid
variant from the plain `bailingmoe2` now in-tree) — unchanged.

## Rejected at research time, with reasons

| model | reason |
|---|---|
| GLM-4.6V (106B/12B) | 12B active fails the ceiling check for a vision slot already served at 36 t/s on 3.3B active — same failure mode as GLM-4.5-Air's rejection for `coder`. |
| GLM-4.6V-Flash (9B) | Dense, over the sub-4B exception. Also carried a **Vulkan-specific mmproj incoherence bug** (ggml-org/llama.cpp #18164, `--no-mmproj-offload` workaround, fixed in PR #18180). Moot given the dense rejection, but recorded because it is exactly the class of Vulkan-specific breakage this box has to watch for in any vision candidate. |
| InternVL3.5-30B-A3B | Same Qwen3-30B-A3B text backbone as `assist` (48 layers, 128 experts top-8, 3.3B active) — no throughput advantage is architecturally possible. MVBench 72.1 vs 71.6 is parity, not an upgrade. No GGUF or mmproj packaging found at all. `tools/mtmd/internvl.cpp` does exist, so the vision tower family is supported generically — untested against this model's specific config. |
| Ming-flash-omni-2.0 | Same `bailingmoe2` base as Ling-flash-2.0; its vision/audio/image-gen towers have no mmproj support found in this tree. |
| Ling-flash-2.0 / Ling-mini-2.0 | Unchanged from 2026-08-02 — see the correction above. |
| Ling-2.6-flash | Still needs a vendor fork (`BailingMoeV2.5`). Unchanged. |
| Skywork-R1V3-38B | Dense. Over the sub-4B exception. |
| MiniMax-M2.5 / M2.7 | 62 of 62 full attention; newer DFlash drafters do not touch the architectural cause of the measured collapse. Unchanged. |
| Qwen3.6-Coder / 3.7-Coder / 3.6-VL / 3.7-VL | None exist. Qwen3.7 shipped as closed `Plus`/`Max` plus `Qwen3.6-35B-A3B` / `Qwen3.6-27B`, both already covered and rejected above. No coder- or vision-specific MoE point release. |
| Skywork-VL, Baichuan-VL, Yi-VL | No 2026 MoE releases found. Yi-VL-34B-GGUF is a stale 2024 dense model; Skywork's vision line (R1V3) is dense. |

## What was verified vs. inferred

**Verified:** `LLM_ARCH_BAILINGMOE2` registered at `src/llama-arch.cpp:107`
**and** fully implemented in `src/models/bailingmoe2.cpp` — read directly, not
inferred from the enum — including the comment stating NextN/MTP tensors are
loaded but unused. `tools/mtmd/internvl.cpp` present, confirming generic
InternVL vision-tower support. The GLM-4.6V-Flash Vulkan mmproj bug and its fix
(#18164 / PR #18180) via direct GitHub fetch.

**Inferred, not measured:** InternVL3.5-30B-A3B's throughput parity with
`assist` (architectural identity of the text backbone, no benchmark run);
GLM-4.6V's ~6-9 t/s (ceiling formula only, no measured anchor for this model on
this box).

**Not found at all:** any GGUF for InternVL3.5-30B-A3B; any working
GGUF+mmproj pairing for Ming-flash-omni-2.0's non-text modalities; a
Terminal-Bench 2.0 or Aider-polyglot figure for any MiniMax-M2.x point release,
for GLM-4.6V, or for Ling-flash-2.0 / Ling-2.6-flash; **any file-tree byte size
from ModelScope itself**, for the SPA reason given above.

# Gated DFlash for Laguna — implemented and measured 2026-08-07

Not a model candidate: a code change, plus the measurement that decides whether
to use it. Follows up the `laguna-eval` note in `router.ini` that recorded the
drafter as unloadable.

## The drafter now loads, and the earlier arithmetic was exactly right

`poolside/Laguna-S-2.1-GGUF/laguna-s-2.1-DFlash-BF16.gguf` failed with
`wrong number of tensors; expected 76, got 69`. The guess on record was that
the 7 unclaimed tensors were 6 `blk.N.attn_gate.weight` plus
`enc.aux_norm.weight`. Dumped the file on the box: correct, both in identity
and in shape — `attn_gate` is `[3072, 72]`, i.e. per-head (n_head 72), and
`enc.aux_norm` is `[3072, 6]`, one norm vector per captured target layer.

Support exists upstream only as poolside's own fork (`poolsideai/llama.cpp`,
branch `laguna`, commit `9c899a68` "Full laguna support"). Upstream llama.cpp
merged the Laguna *target* arch (PR #25165, #26233) but not the drafter-side
contract. Ported from that commit.

## Three differences the tensor count did not show

Loading the two extra tensor kinds is the visible part. The rest would have
loaded silently and drafted badly:

1. **Context K/V through the input layernorm.** Generic DFlash projects the
   fused target features raw into the draft KV cache; Laguna drafters project
   them from the `attn_norm` output, matching their query path.
2. **Causal noise block.** Generic DFlash sets `llama_set_causal_attn(false)`.
   Laguna drafters are trained causal, keyed off `dflash.decoder_arch`.
3. **`target_layers` ends at the layer count.** The GGUF asks for layers
   `[2, 11, 20, 30, 39, 48]` from a 48-layer target. Index 48 is not a layer —
   it means the pre-final-norm residual, captured through the nextn path. The
   EAGLE3 implementation in this tree already handled exactly this; the DFlash
   one did not.

Also needed on the **target** side, and missing from upstream's merged
`laguna.cpp`: `res->t_layer_inp[il]` capture per layer, and `res->t_h_nextn`
before the final norm. Without these the target aborts at
`llama-graph.cpp:1247` on the first request. The output-row gather in the last
layer is deferred only when unmasked nextn extraction is actually on, so the
unspeculated path keeps its narrowing and is unchanged.

Poolside's fork also carries a Metal-specific f16 overflow workaround in
`build_moe_ffn` and a non-finite sanitize on the target features, both for
Laguna's massive activations (|x| ~ 1e6 at attention-sink tokens). The sanitize
is ported (cheap, and it is the guard that proves the point); the `build_moe_ffn`
rewrite is **not** — it is a Metal problem and it costs a sum-of-squares pass
on every expert column. **On Vulkan the guard never fires**, checked across
every measured run: no non-finite features on this backend.

## Measured — and it buys nothing here

> **SUPERSEDED the same day.** Every number in this section was measured with
> the drafter at the BF16 poolside ships. The drafter's weights are read in
> full on every draft round, so 2.08 GiB of BF16 was costing ~35 ms of a
> ~156 ms round and hiding the entire win. Quantized to Q4_K_M the same
> drafter measures **+19.4%**, not +0.9%. See "The drafter's own quantization
> was the whole story" at the end of this section. The cost model below is
> still correct and still worth reading - it is the reason drafts have to stay
> short here - only the verdict changed.

IQ3_S, ctx 32768, `parallel 1`, q8_0 KV and q8_0 draft KV, 4 realistic coding
prompts, 1200 generated tokens per config, box idle, production stopped.

| config | tg t/s | acceptance |
|---|---|---|
| baseline, no drafter | **14.18** | — |
| n-max 2, p-min 0 | 14.31 | 0.62 |
| n-max 4, p-min 0.6 | 14.30 | 0.75 |
| n-max 4, p-min 0.8 | 13.77 | 0.91 |
| n-max 3, p-min 0 | 12.98 | 0.48 |
| n-max 4, p-min 0 | 12.13 | 0.42 |
| n-max 6, p-min 0 | 9.01 | 0.30 |
| n-max 8, p-min 0 | 3.65 | 0.20 |
| n-max 15, p-min 0 | 2.90 | 0.11 |

+0.9% at the peak, which is noise, for 2.2 GiB of the pool. **Left off.**

## Why — the cost model, which generalises past this model

Cost per round is flat in acceptance and set by the verify width. Measured from
the n-max 4 runs: a 5-token verify round costs ~233 ms against ~73 ms for one
unspeculated decode. That is 3.2x the cost for 5 tokens, where a dense
bandwidth-bound model would pay close to 1x — each extra token in the verify
batch routes to its own 10-of-256 experts, and the union of expert weights read
is what this box is bandwidth-bound on.

Break-even therefore needs `1 + n*acc > cost_ratio`: at n-max 4, acceptance
above ~0.55; at n-max 2, above ~0.62. The drafter only clears that with p-min
high enough that it stops drafting most of the time — at p-min 0.6 it drafts
900 tokens where p-min 0 drafts 1784, and the win from the higher acceptance is
cancelled by the rounds it declines to draft at all.

This is the same MoE effect already recorded for `coder` ("keep MoE drafts at
3-4"), measured here with the round cost isolated rather than inferred.

Two side notes worth keeping:

- **The n-max 8 and 15 collapses are the Vulkan `mul_mat_id` threshold**, not
  acceptance. 5- and 7-token batches use the `mul_mat_vec_id` path; 9 and 16
  fall to the matrix path. Consistent with the `<= 8` threshold finding already
  in the README, and the reason n-max 8 is far worse than its acceptance alone
  predicts.
- ~~**Poolside's own docs recommend `--spec-draft-n-max 15`.**~~ **Misread.**
  Their model card recommends **7** speculative tokens for vLLM and gives 15
  as the *clamp* — the trained `block_size` of 16 minus the anchor token. 15
  is still the worst setting measured here, but it was never advice.

## The drafter's own quantization was the whole story

Re-measured with the identical harness, changing only the drafter file:

| drafter | file | tg @ n-max 2 | vs baseline | acceptance |
|---|---|---|---|---|
| BF16 (as shipped) | 2.08 GiB | 14.22 | +0.5% | 0.601 |
| Q8_0 | 1.10 GiB | 15.57 | +10.0% | 0.591 |
| Q3_K_M | 0.50 GiB | 16.04 | +13.4% | 0.588 |
| IQ4_XS | 0.55 GiB | 16.05 | +13.4% | 0.591 |
| **Q4_K_M** | **0.60 GiB** | **16.89** | **+19.4%** | **0.617** |

Baseline 14.15 t/s, `deploy/radeon-780m/spec-sweep.sh`. The BF16 row reproduces
the +0.9% of the original table, which is what confirms the two runs are
comparable and that nothing else changed.

**Acceptance is flat at 0.59-0.62 across every quantization.** The drafter
drafts exactly as well at 4 bits as at 16, so the entire spread is bytes read
per round, not draft quality. Q3_K_M being no better than Q4_K_M despite being
120 MiB smaller marks the floor — below Q4 the acceptance loss starts to cost
more than the bytes save.

Draft length stops mattering much once drafting is cheap: Q4_K_M at n-max
1/2/3 measures 15.90 / 16.89 / 15.69 and n-max 4 with p-min 0.6 measures 16.60.
That band is inside the noise of a 4-prompt median — individual prompts ranged
14.03-18.54, straddling the ~0.5 break-even acceptance the cost model predicts.
Take n-max 2, p-min 0; do not over-tune it on four prompts.

Quantizing also removes the other objection: the drafter costs 0.60 GiB of the
pool instead of 2.2 GiB.

## What would change the answer further

A drafter carrying a **DSpark confidence head** — this tree already implements
DSpark, and a learned per-position accept probability truncates adaptively
instead of by a fixed global p-min, which is exactly the knob the cost model
says is missing. Poolside ships DFlash only for Laguna, no DSpark variant as of
2026-08-07. It is no longer what stands between this model and a working
drafter, only what would push it past +19%.

# Rebalancing the quant byte budget on Laguna — 2026-08-07

Not a model candidate: a rewrite of an existing GGUF's quantization mix, and
the measurement that justifies it. Follows the DFlash work above.

## Generation speed here is arithmetic on bytes per token

Laguna-S-2.1 UD-IQ3_S reads **4.93 GB per token** and serves at 70.7 ms per
token = **69.8 GB/s effective**, against the ~74 GB/s this box achieves at
best. llama-bench and llama-server agreed to within 1%. There is no efficiency
bug in the decode path - it is bandwidth-bound and already near optimal, so the
only way to make it faster is to read fewer bytes.

Bytes per token = every non-expert tensor in full (`token_embd` excepted, it is
a gather) plus `n_expert_used / n_expert` of the routed experts:

| what | GiB/token | share |
|---|---|---|
| `attn_q` + `attn_output` (Q6_K) | 1.916 | **41.6%** |
| routed experts, 10/256 (IQ2_S + IQ4_XS) | 1.637 | 35.6% |
| shared experts, attn_k/v, output, router | 1.042 | 22.8% |

**Two tensors cost more per token than all 256 experts combined**, because they
are read in full every token while any given expert is read 10 times in 256.
Unsloth's UD mixes protect attention and crush the experts to IQ2_S - correct
for quality per byte *stored*, wrong for this box, which needs quality per byte
*read*. Laguna makes it extreme: 72 heads x 128 head_dim on a 3072 hidden is a
3x expansion, so `attn_q` and `attn_output` are enormous.

## Doing it without round-tripping the experts

`llama-quantize` has no "change these and copy the rest" mode, and
re-quantizing an imatrix-built IQ2_S expert through f32 would throw away the
quality the imatrix bought. But it skips a tensor whose target type equals its
current type, so `deploy/radeon-780m/pin-tensor-types.py` emits a
`--tensor-type-file` pinning all 527 quantized tensors to what they already
are, overriding only the 96 attention ones. Everything else is a byte copy.

One llama.cpp change was needed: `llama-quant.cpp` demanded an imatrix for any
tensor whose *target* type is IQ2_S-class, without checking whether the tensor
was actually being requantized - so pinning 92 IQ2_S experts to IQ2_S aborted
the run. Fixed to require an imatrix only when `target_type != tensor->type`.
An imatrix was built anyway (100 chunks, code corpus) since it improves the
attention requant; expert coverage came out at 98.8-99.6%, which does not
matter here because no expert is touched.

## Measured

| variant | attention | size | tg | vs base | PPL (80 chunks, held-out code) |
|---|---|---|---|---|---|
| base UD-IQ3_S | Q6_K | 45.10 GiB | 13.77 | — | 2.3658 +/- 0.0339 |
| V1 | Q5_K | 44.78 GiB | 14.16 | +2.8% | 2.3674 +/- 0.0341 |
| **V2** | **IQ4_XS** | **44.42 GiB** | **16.08** | **+16.8%** | **2.3660 +/- 0.0339** |

Both passed `check-output.sh` first. **Perplexity is unchanged** - IQ4_XS
attention costs 0.008%, which is nothing, because model quality here is already
set by the IQ2_S experts and the Q6_K attention was pure overprovisioning.
Prefill improves slightly too: pp4096 147.5 -> 151.0, pp512 106.3 -> 111.3.

**Q5_K is the trap.** It saves 328 MiB and should have been +7.5%; it measured
+2.8%. Its 5-bit unpack is split across two planes and is slower per byte on
this Vulkan backend than the Q6_K it replaced, so most of the byte saving went
back into dequant. IQ4_XS is a flat 4-bit codebook lookup, is already the type
used for `ffn_down_exps` in these files, saves twice as much, and hit its
prediction. **The bytes-per-token model predicts bandwidth, not dequant cost -
always confirm with llama-bench.**

## The two wins overlap - do not add them up

| config | tg | vs base |
|---|---|---|
| base, no drafter | 14.15 | — |
| base + Q4_K_M drafter, n-max 2 | 16.89 | +19.4% |
| V2, no drafter | 16.00 | +13.1% |
| **V2 + Q4_K_M drafter, n-max 2** | **17.00** | **+20.1%** |

+13% and +19% compose to +20%, not +35%. The requant cuts the *fixed* bytes of
a round; the drafter's marginal cost is the *per-verify-token* expert bytes,
which the requant does not touch. Worse, cutting the fixed cost lowers `T1` and
so raises the acceptance needed to break even - from ~0.45 to ~0.51 at n-max 2,
against a measured 0.611. Both are still worth having (V2 is 0.68 GiB smaller
and free in quality; the drafter is the bigger single win), but the combination
is where the ceiling is, and on these four prompts V2+drafter is not separable
from drafter alone.

## V3: extending IQ4_XS to the rest of the per-token reads

Same treatment applied to `attn_k`, `attn_v` and the three shared-expert
tensors as well, 333 tensors retargeted in total. `output.weight` and
`token_embd` stay Q6_K - lm_head is the one place 4 bits is known to bite, and
they are only 0.24 GiB/token between them.

| variant | retargeted | size | tg | pp512 | pp4096 | PPL |
|---|---|---|---|---|---|---|
| base UD-IQ3_S | — | 45.10 GiB | 13.77 | 106.3 | 147.5 | 2.3658 +/- 0.0339 |
| V2 (q, output) | 96 | 44.42 GiB | 16.08 | 111.3 | 151.0 | 2.3660 +/- 0.0339 |
| **V3 (+ k, v, shexp)** | **333** | **44.21 GiB** | **16.95** | **111.8** | **153.3** | **2.3657 +/- 0.0337** |

**+23.1% tg and +3.9% pp over stock, at a perplexity that is 0.0001 *below*
the original** - i.e. unchanged, the difference is noise. Predicted 17.06 t/s
from the byte budget, measured 16.95. IQ4_XS keeps hitting its prediction where
Q5_K did not.

The honest reading is that Unsloth's UD mix carries roughly 0.9 GiB per token
of attention and shared-expert precision that buys nothing measurable on this
model, because quality is already pinned by the IQ2_S routed experts. That is
specific to a mix this lopsided - do not assume it generalises to a model whose
experts are at 4 bits or better.

`token_embd` and `output.weight` at IQ4_XS would remove another ~0.08
GiB/token, ~+2%. Not attempted: lm_head is the sensitive one and the return no
longer justifies the risk.

## ...and then the drafter lost to the requant

Both optimisations measured together, served through `spec-sweep.sh` on the
same four prompts:

| config | tg | acceptance |
|---|---|---|
| stock, no drafter | 14.15 | — |
| V2, no drafter | 16.00 | — |
| **V3, no drafter** | **16.75** | — |
| stock + Q4_K_M drafter, n-max 2 | 16.89 | 0.617 |
| V2 + drafter, n-max 2 | 17.00 | 0.611 |
| V3 + drafter, n-max 2 | 16.05 | **0.544** |
| V3 + drafter, n-max 1 | 16.68 | 0.688 |

On V3 the drafter is a net loss at n-max 2 and a wash at n-max 1. Two effects,
both predicted by the round cost model:

1. **A faster base raises break-even acceptance.** The requant cuts a round's
   fixed bytes but not the per-verify-token expert bytes, so `T1` falls while
   marginal verify cost does not. Break-even at n-max 2: ~0.45 stock, ~0.556 on
   V3. At n-max 1: ~0.670, against a measured 0.688 - hence the wash.
2. **Requantizing the target degrades draft acceptance**: 0.617 -> 0.611 (V2)
   -> 0.544 (V3). Mechanistic, not noise. DFlash conditions on the target's
   *internal hidden states* at layers 1/10/19/29/38/47. V3 is the first variant
   to requantize `attn_k`/`attn_v`, which changes the KV cache and therefore
   those states pervasively; V2 only touched `attn_q`/`attn_output`, which is
   why V2 held acceptance and V3 did not. The drafter was trained against a
   full-precision target and is now off distribution.

**This is the transferable result: a feature-conditioned drafter (DFlash,
EAGLE3) is coupled to the target's quantization in a way a vocabulary-only
drafter is not.** Changing the target file invalidates the drafter's measured
acceptance. Re-measure; never carry an acceptance figure across a requant.

## What was deployed and why

`laguna-eval` runs V3 with no drafter. The top three configs (17.00 / 16.89 /
16.75) sit inside the noise of a 4-prompt median, so this is not a claim that
V3-alone is the fastest - it is a claim that they tie, and V3-alone wins on
everything else: no drafter in the pool, 0.9 GiB smaller, the best prefill of
the three, and no prompt-dependent variance. Unspeculated V3 returned
16.76/16.75/16.74/16.74 across the four prompts; V2+drafter ranged 15.96-19.37
depending on how predictable the continuation was. For an interactive coding
backend the flat one is worth more than a median 1.5% higher.

The Q4_K_M drafter stays on disk. It is worth +19.4% against the stock file,
and it is the thing to re-test if a DSpark-headed Laguna drafter ever ships.

---

# KAT-Coder-V2.5-Dev - measured 2026-08-07, `kat-eval`

Kwaipilot/KAT-Coder-V2.5-Dev, 35B total / 3B active, Apache-2.0. Post-trained
on Qwen/Qwen3.6-35B-A3B, the same base `coder` and `nerkyor-eval` already
serve, so no part of the architecture is new to this box: arch `qwen35moe`, 256
routed experts top-8 plus 1 shared, 40 blocks, `full_attention_interval 4` (10
full-attention layers, 30 Gated Delta Net), context_length 262144. Published
SWE-bench Verified 69.40 / Multilingual 63.00 - level with `coder`'s
70.6/62.8, which is to say the published numbers are not the reason to look.

Served file is `gbuzhf/KAT-Coder-V2.5-Dev-MTP-GGUF`, tier `MTP-UD-Q4_K_XL`
(21.27 GiB), SHA256-verified through `fetch-model.sh`.

**The open weights are text-only.** Kwaipilot stripped the vision tower from
the release while leaving a `vision_config` in `config.json`; there is no
mmproj and none can be built. `check-vision-tools.sh` reports `vision FAIL -
HTTP 500`, which is correct behaviour, not a deployment fault.

## The MTP head is grafted, and it works anyway

KAT ships `mtp_num_hidden_layers: 0` - no draft head. The GGUF above grafts
Qwen3.6-35B-A3B's *original* MTP head onto KAT's trunk. Measured here it
accepts 0.76, against 0.85-0.87 for `fast`'s own co-trained head - a real gap
but nowhere near enough to stop it paying.

Worth recording because it cuts against the Laguna result directly above: the
publisher fine-tuned this head on KAT's own rollouts twice, at 80 and 450
steps, and **both fine-tunes made acceptance worse** (0.73 -> 0.45/0.46
agentic, their measurement). A donor head from the base model beat both
adaptations of it. The DFlash lesson - that a feature-conditioned drafter is
coupled to its target - says acceptance must be re-measured after any change to
the target; it does not say a co-trained head is always available, and when one
is not, an unmodified donor head from the base model is a better bet than a
hand-adapted one.

## Sweep - `spec-sweep.sh`, 4 prompts, median of each

| config | tg t/s | acceptance |
|---|---|---|
| baseline, no speculation | 22.03 | - |
| n-max 2, p-min 0 | **29.28** | 0.764 |
| n-max 2, p-min 0.3 | 29.05 | 0.773 |
| n-max 2, p-min 0.3, + `ngram-mod` | 29.24 | 0.773 |
| n-max 3, p-min 0 | 26.63 | 0.607 |
| n-max 4, p-min 0.3 | 25.41 | 0.576 |
| n-max 1, p-min 0.75 *(publisher's pick)* | 26.16 | 0.948 |
| n-max 2, p-min 0.75 | 27.96 | 0.935 |

+33% for the head. n-max 2 is the peak, the same MoE draft-length ceiling every
other alias here hits and for the same reason: each verified token routes to
its own experts, so verify cost grows with draft length.

Two results are worth carrying forward.

**The publisher's recommended flags are 11% slower here.** They ship
`--spec-draft-n-max 1 --spec-draft-p-min 0.75 --spec-type draft-mtp,ngram-mod`,
found by coordinate ascent over 79 live configs - real work, honestly reported,
and wrong for this box. It was tuned on an RTX 3070 Ti Laptop 8 GB with 35 of
40 MoE layers on CPU, where (their words) MTP alone is a net loss and
`ngram-mod` has to carry the win. Here MTP alone is +33%. **Third time vendor
speculation guidance has failed to transfer** - poolside's n-max 15 for Laguna,
Qwen's defaults for `fast`, now this. Re-sweep every time; the failure is not
that vendors are careless, it is that the optimum is a property of the memory
system, not of the model.

**`ngram-mod` never fired.** Paired with `draft-mtp` it returned acceptance
byte-identical to `draft-mtp` alone, 714/924, and tg inside the noise. There
was nothing left for it to cover.

`p-min 0.75` is the clearest illustration of the trap: 0.935 acceptance, and
4.5% slower than p-min 0.3 at 0.773. Acceptance is not the objective.

## Evals - through the router, alias `kat-eval`

| eval | `kat-eval` | best incumbent |
|---|---|---|
| `probe-server.sh` | pp 332.9 t/s, tg 29.24 t/s | `coder` pp 326, tg 26.14 |
| `check-vision-tools.sh` | tools PASS, vision FAIL (text-only) | - |
| `code-eval.sh` | 4/4, 78 s, **14 turns**, 2.1K think | `coder` 4/4, 104 s |
| `code-eval-hard.sh` | 6/6, 180 s, **20 turns** | `fast` 6/6, 163 s, 27 turns |
| `code-eval-opencode.sh` | 7/8, 213 s, **32 turns**, 4.9K read | `nerkyor-eval` 7/8, 225 s, 47 turns |

Zero edit misses and zero botched tool calls across all 18 items. The single
failure is `agents-md`, which **every model tested on this box has failed**.

The scores tie; the turn counts do not. 14/20/32 are the lowest recorded here
against 27-47 for the incumbents - 26% fewer turns than `fast` on the hard tier
and 32% fewer than `nerkyor-eval` on the opencode tier. Session latency is
turns x per-turn time, so on the metric that started this whole search ("init
takes too long") this is the strongest result any candidate has produced.
Reasoning economy is healthy too: 2.1K/6.0K/4.3K chars, against the 143K that
disqualified Darwin-36B.

Tool calling works through KAT's `<tool_call><function=name><parameter=x>` XML
template - a different shape from the JSON-in-`<tool_call>` every other alias
here uses. llama.cpp's PEG auto-parser (`common/chat-peg-parser.cpp`, the
`function_opener` marker) handles it and emits a correct OpenAI tool call.

## Tier choice, and the requant this file is asking for

`MTP-UD-IQ4_XS` (16.95 GiB) was measured alongside: 31.69 t/s speculated
against 29.05 (+9%), pp4096 419 vs 350 (+20%). It was **not** deployed -
Q4_K_XL keeps routed experts at Q4_K/Q5_K/Q6_K where IQ4_XS drops them to
IQ3_S/IQ4_XS, this slot exists to judge coding quality, and unlike Laguna there
is no memory pressure forcing the lower tier.

Both tiers are badly allocated for a bandwidth-bound box, and worse than Laguna
was. Per-token traffic on the deployed file:

| tensor | GB/token | share | type |
|---|---|---|---|
| routed experts | 0.6136 | 22.3% | Q4_K/Q5_K/Q6_K |
| `output` | 0.5403 | 19.6% | Q8_0 |
| `attn_qkv` | 0.5348 | 19.4% | Q8_0 |
| `attn_gate` | 0.2674 | 9.7% | Q8_0 |
| `ssm_out` | 0.2674 | 9.7% | Q8_0 |
| `attn_q` | 0.1783 | 6.5% | Q8_0 |
| `attn_output` | 0.0891 | 3.2% | Q8_0 |
| shared experts (3) | 0.1338 | 4.8% | Q8_0 |
| | **2.751 total** | | |

**All 256 routed experts together are 22.3% of the traffic; the Q8_0 non-expert
tensors are 68%.** Unsloth's Dynamic mixes protect exactly the tensors read in
full on every single token, which is right for quality-per-byte-stored and
wrong for tokens-per-second - the same finding as Laguna, on a file whose
experts are three tiers higher.

The bytes-per-token model predicts 25.4 t/s against 22.02 measured, and 28.1
against 24.21 for IQ4_XS: a consistent 0.865 correction, i.e. ~60.5 GB/s
effective rather than the ~70 GB/s dense-attention models reach. The GDN layers
carry recurrent-state traffic the model does not count. **Use 60.5 GB/s for
hybrid-attention arithmetic on this box, 70 for the rest.**

Retargeting the Q8_0 non-expert tensors to IQ4_XS via `pin-tensor-types.py`
predicts 2.751 -> ~1.88 GB/token, or ~32 t/s unspeculated - above even the
stock IQ4_XS file, while keeping the experts at the higher tier. NOT ATTEMPTED,
and two things must be settled first:

1. **Perplexity.** Laguna's equivalent requant was free (2.3657 vs 2.3658)
   *because* its experts were already pinned at IQ2_S, so the Q6_K attention
   was buying nothing. That argument does not hold here - these experts are at
   4-6 bits, so the Q8_0 attention may be doing real work. This needs the
   held-out perplexity run Laguna got, not an assumption.
2. **Draft acceptance.** The MTP head conditions on the target's hidden states.
   Requantizing `attn_k`/`attn_v` moved Laguna's DFlash acceptance 0.617 ->
   0.544 and turned a win into a loss. Expect the same coupling here and
   re-sweep after; never carry 0.773 across.

The requant and the head may well be substitutes, exactly as they were for
Laguna. Measure, do not add them up.

## What was deployed

`kat-eval`, UD-Q4_K_XL, `draft-mtp` at n-max 2 / p-min 0.3,
`spec-draft-type-k/v = q8_0`, ctx 262144, not load-on-startup, listed in
`opencode.json` but not the default there. Verified loadable standalone at
262144 first: 17.15 GiB VRAM + 13.63 GiB GTT = 30.78 GiB, well inside the
76 GiB pool.

p-min 0 and 0.3 tie (29.28 vs 29.05, inside noise). 0.3 is deployed on the same
reasoning `fast` carries it - verify cost grows with depth, so declining to
draft on low-confidence steps should be worth more at 100k tokens than in a
300-token sweep. That is a judgement call, not a measurement.

Before this could take `coder`: everything above was measured at ctx 32768
while the slot is configured for 262144, and none of it is a real agentic
session. The `nerkyor-eval` history is the precedent - a candidate that passed
every standalone eval hung the GPU twice under real opencode traffic. Soak it
across the depths that mattered there (>67k and >100k accumulated tokens)
before promoting it.

---

# Requantizing Ornith - measured 2026-08-11, a closed avenue

Not a model candidate: the Laguna byte-budget rewrite above, applied to `fast`.
Three results, one a correction to this file and one contradicting what the
Laguna section established.

Triggered by asking whether a higher-quality Ornith variant exists. Off the
shelf, no. The deployed file is byte-exact with SC117's **I-Quality** tier
(23,514,742,112 bytes), the top of the four APEX mixes - the local filename says
`Q6_K` but it is an adaptive mix, not a uniform Q6_K. The official
`deepreinforce-ai` and `unsloth` ladders go higher (Q8_0, UD-Q8_K_XL) but carry
**no MTP head**; SC117 grafts one in from Qwen3.5-35B-A3B, so those tiers trade
the 25.3 -> 34.6 speculation win for a fidelity gain that turns out not to
exist. The rest of the Ornith 1.0 family is 9B dense, 31B dense and 397B MoE:
too small, dense (three prior rejections on this box), and past the pool.

That left building one. SC117 also ships `Ornith-1.0-35B-MTP-BF16.gguf`
(71,066,994,112 bytes, MTP head included) - the only route to a higher-precision
Ornith, since requantizing upward from the deployed file recovers nothing.

## Correction: `fast` is a GDN hybrid, not 41 of 41 full-attention

Confirmed from the GGUF's own tensors. 30 of the 41 blocks carry `ssm_*`
(`ssm_out`, `ssm_conv1d`, `ssm_a`, `ssm_dt.bias`, `ssm_norm`) and a fused
`attn_qkv`; only blocks 3, 7, 11 ... 39, plus block 40 (the MTP head), carry
separate `attn_q`/`attn_k`/`attn_v`. That is **10 of 40 at interval 4 plus the
head**, with `qwen35moe.ssm.state_size = 128`.

Two consequences. The bytes-per-token arithmetic for `fast` takes the **60.5
GB/s hybrid constant, not 70**: 2.339 GB/token predicts 25.9 t/s against 25.3
measured, where 70 GB/s would have predicted 29.9. And the desk-rejection of
Qwen3.6-35B-A3B vanilla for being "the same hybrid shape as `coder`, no reason
to expect better prefill" rests on a distinction that does not exist - `fast`
has that exact shape and prefills at pp4096 334.

## The incumbent is 0.26% from its own BF16 weights

`llama-perplexity`, 80 chunks, `-c 512`, held-out code corpus (text past byte
offset 12000 in 151 files, disjoint from the imatrix corpus):

| model | disk | PPL | vs BF16 |
|---|---|---|---|
| BF16 source | 66.20 GiB | 2.0131 +/- 0.02495 | - |
| **APEX I-Quality (deployed)** | 21.89 GiB | **2.0183** +/- 0.02510 | **+0.26%** |
| row-3 build (below) | 26.95 GiB | 2.0215 +/- 0.02509 | +0.42% |

The deltas sit inside the individual error bars, but these are paired runs over
identical chunks and the ordering never flips once converged: across chunks
20-80 the incumbent reads worse than BF16 at 61 of 61 points, and row 3 worse
than the incumbent at 61 of 61. Cumulative values are autocorrelated, so that is
one persistent signal rather than 61 trials - the *sign* is solid, the magnitude
is 0.005. A p-value is not recoverable from 4-decimal logs, since reconstructing
per-chunk NLL amplifies rounding by a factor of n.

**This bounds every future requant of this model.** The whole distance from the
deployed file to its own unquantized weights is 0.26%; no mix can buy more than
that. Quantization is not a quality lever on `fast` - a real upgrade has to be
different weights.

## IQ4_XS on GDN projections returns a quarter of its prediction

The Laguna play, applied here as "row 3": experts raised from the APEX mix
(4.25/5.5/6.5625, 5.14 bpw avg) to uniform Q6_K, paid for by dropping the 90
GDN-block projections (`attn_qkv`, `attn_gate`, `ssm_out` - 0.825 GB/token at
Q6_K) to IQ4_XS. Built from BF16 with a 443-tensor `--tensor-type-file` and a
fresh BF16-derived imatrix (200 chunks, code corpus, expert coverage 99.61%).
Passed `check-output.sh`. 2.227 GB/token against 2.339 predicts **+7.5%**.

Both benched back to back on build `8eef506`, `bench.sh` defaults:

| test | incumbent 21.89 GiB | row 3 26.95 GiB | delta |
|---|---|---|---|
| pp512 | 299.49 +/- 9.92 | 319.09 +/- 0.89 | +6.5%, but the incumbent's error bar is 9.92 |
| pp4096 | 334.08 +/- 0.20 | 330.33 +/- 0.41 | -1.1% |
| pp16384 | 295.57 +/- 0.65 | 267.29 +/- 0.69 | **-9.6%** |
| tg128 | 25.36 +/- 0.01 | 25.86 +/- 0.22 | **+2.0%** |
| tg128 @ d16384 | 23.12 +/- 0.02 | 23.54 +/- 0.01 | +1.8% |
| tg128 @ d32768 | 21.12 +/- 0.06 | 21.60 +/- 0.06 | +2.3% |

**+2.0% of a predicted +7.5%, and 9.6% of prefill at depth given away.** The
Laguna section concluded IQ4_XS "hit its prediction" while Q5_K was the trap.
That holds for ordinary attention tensors and does **not** transfer to a GDN
hybrid's `attn_qkv`/`attn_gate`/`ssm_out`. The dequant-cost caveat recorded
there is the right frame, but IQ4_XS is not automatically on its safe side - the
tensor's role matters, not only its type.

## Verdict: reject row 3, and stop requantizing this model

Worse perplexity than the incumbent, 9.6% less prefill at depth, +5.06 GiB, for
+2.0% generation. The MTP `n-max`/`p-min` sweep and the reason/code/vision evals
were not run: speculation cannot recover a fidelity regression, and the
candidate had already lost on two axes.

Both files deleted 2026-08-11, 94 GB reclaimed. Kept:
`/root/models/ornith-row3.imatrix.gguf` (184 MiB, BF16-derived, 200 chunks) so
the 41-minute server outage it cost need not be repeated, plus
`/root/emit-ornith-row3-types.py` and `/root/ornith-row3-types.txt`.
`router.ini` was never modified and `fast` served the incumbent throughout,
except during the imatrix window.

One mechanical note for any future build from an unquantized source:
`pin-tensor-types.py` does **not** work from BF16. It pins each tensor to the
type it already has and skips anything not already Q/IQ, so from a BF16 file it
emits an empty map. The quantizable name set has to come from an existing quant
of the same model - which is what `emit-ornith-row3-types.py` does, taking the
names from the APEX file and assigning targets by rule.

---

# Ling-3.0-flash re-check, and Muse Glimmer - research 2026-08-11

**Nothing in this section is measured on this box.** Both entries are research
and arithmetic against published metadata. Neither model has been downloaded.

## Ling-3.0-flash - two blockers closed, one is worse than recorded

Re-check of section 1 at the top of this file, triggered at the 2-4 week mark it
set for itself.

| blocker, as written 2026-08-02 | status 2026-08-11 |
|---|---|
| 1. arch in no shipping llama.cpp | **unchanged** - PR #26608 still OPEN, awaiting 2 of 3 code-owner approvals (JohannesGaessler, CISC, ggerganov). Not in upstream master, not in this tree. |
| 2. multi-argument tool calling broken | **closed** - `common: fix Bailing V3 tool argument parsing`, 2026-08-07, landed with regression tests |
| 3. Vulkan freezes, MTP cannot be disabled | **worse** - see below. No commit addresses either. |
| 4. IQ3_XXS is the hardest quant case | unchanged |

The PR is moving, not stalled: 2026-08-05 speculative decoding, 08-06 SwiGLU
clamp, 08-07 the tool-call fix, 08-09 metadata writer, 08-11 a master merge plus
Q-LoRA support for Ling-3.0-tiny and a "small mtp change".

### Blocker 3 is more specific than this file recorded, and points at us

The Vulkan freeze reports are on **AMD Strix Halo** - gfx1151, RDNA 3.5, the
same radv/amdgpu path this box runs on gfx1103. Section 1 filed this as generic
"untested arch on an unmerged PR" risk. It is not generic. It is the nearest
hardware sibling to this box, and it is the configuration that hangs.

Compounding it: "MTP cannot be disabled without crashes" is still unaddressed,
so speculation cannot be turned off to separate a Vulkan hang from an MTP bug.
That is the first diagnostic step this box would take, and it is unavailable.
The precedent for why that matters is the 2026-08-04 `ErrorDeviceLost`
incident - two reverts and a weight deletion on a wrong diagnosis, settled only
by finding a case (`coder`) that had no speculation at all to rule it out.

### New: every GGUF published before 2026-08-07 is wrong

All Ling-3.0-flash GGUFs were re-uploaded 2026-08-07 to carry Ling 3.0's trained
per-layer SwiGLU clamp metadata. Anything pulled earlier needs a re-download or
`add-ling3-clamp-metadata.py`. Check the file date before spending 47.7 GiB, and
before attributing any quality result to the quant tier.

### Verdict unchanged: do not download

Half of the download-blocking condition set on 2026-08-02 is now met. Hold on
the other half. Re-check in 2-4 weeks (early September 2026) for **the merge and
a Vulkan fix**, not the merge alone - blocker 3 has become the binding one.

## Muse Glimmer 30B - it would load, and it is dense

Meta, Apache-2.0, released with day-0 llama.cpp support: PR #26841 is **merged
upstream**. GGUF arch tag `muse-glimmer`, `model_type: muse_glimmer`. It is
**not in this tree** - this fork has not pulled that master commit - so the cost
of support is a rebase on upstream, not a cherry-pick of an unmerged branch.
That is the one axis on which it is far ahead of Ling.

### It is dense, and that settles the slot question

`config.json` carries no expert fields of any kind: 2B frozen ViT plus a **28B
dense** text decoder, 52 layers, hidden 6656, 32 heads / 2 KV heads,
`sliding_window` 2048, `max_position_embeddings` 131072, vocab 202048.

Dense means the whole file is read every token. There is no active-parameter
discount, and no `pin-tensor-types.py` lever either, because there are no expert
tensors sitting idle to leave alone - every byte is hot on every token.

Meta's own GGUF is 16.8 GB:

```
ceiling = 74 GB/s / 16.8 GB = 4.4 t/s
```

Calibrated against this box's one *measured* dense datapoint - the nerkyor
Qwen3.6-27B dense Q4 at 4.1 t/s base, which realized ~0.85 of its own ceiling
because dense carries no routing overhead - that predicts **3.7-4.0 t/s base**.

For speculation, use Meta's Apple Silicon figure and not its RTX 5090 figure:
the card claims ~3x on a 5090 but **1.5-1.8x on Apple Silicon**, and Apple
Silicon is unified-memory and bandwidth-bound, which is this box's regime. That
predicts **~6-7 t/s served**, against `deep` 19.6, `laguna-eval` 16.75, `coder`
26.1, `kat-eval` 29.1 and `fast` 34.6. It would be the slowest thing here by
roughly 3x. This is the fourth dense rejection on this box.

### Everything else about it is right, which is why it is recorded rather than desk-rejected

Official artifacts (`meta-models/Muse-Glimmer-30B-GGUF`):

| file | size | note |
|---|---|---|
| `muse-glimmer-30B-kquant-17gb.gguf` | 16.8 GB | primary |
| `muse-glimmer-30B-kquant-dynamic.gguf` | 19.7 GB | higher-quality variant |
| `mmproj-kquant.gguf` | 1.4 GB | vision |
| `dflash-kquant.gguf` | 1.6 GB | DFlash drafter, **already quantized** |

The drafter shipping pre-quantized matters here specifically: the Laguna section
above established that a BF16 drafter eats the entire speculation win, because a
drafter's weights are read in full on every draft round exactly like the
target's. At 1.6 GB against a 16.8 GB target that tax is ~10%, the healthy end
of that finding rather than the trap.

Published benchmarks - these do clear the `deep` bar's "harder discriminator"
requirement, which is why throughput has to be the reason for the reject:

| benchmark | Muse Glimmer | best incumbent |
|---|---|---|
| SWE-bench Verified | 76.0 | `fast` 75.6 |
| SWE-bench Pro | 51.2 | `fast` 50.4 |
| GPQA Diamond | 83.5 | gpt-oss-120b 80.9 |
| Terminal-Bench 2.1 | 51.7 | - |
| AIME 2026 | 94.7 | - |
| MMMU Pro | 74 | - |

Depth profile is excellent: three sliding-window (2048) layers to one full
attention, so only **13 of 52** layers carry a growing KV, with GQA at 32:2. At
q8_0 and 131072 that is roughly 1.5 GiB, the 39 windowed layers capping out
around 70 MB in total. Weights plus mmproj plus drafter plus KV is about 21 GiB
of the 76 GiB pool. The MiniMax-M2.1 depth collapse is structurally impossible
on this layer pattern.

### Open items, if it is ever tested anyway

- Meta's announcement says context 32768, while `config.json` says
  `max_position_embeddings` 131072 and both GGUF cards say "131072+".
  Unresolved - read it from the GGUF with `gguf_dump.py` before configuring a
  slot, do not trust any of the three.
- Nothing published on reasoning-token economy, the axis that has rejected four
  candidates on this box.
- The 2-bit tiers that would speed it up (10.7-12.4 GB) fall below this repo's
  3-bpw floor.
- `--jinja` is mandatory per Meta, and do not stop on `<|eom|>`.

### Verdict: reject on throughput, but it is the cheapest experiment this file has ever proposed

Rejected for any production slot. ~6-7 t/s is 3x slower than the slowest alias,
and dense offers no lever to recover it - not quantization, not tensor pinning,
and speculation is already priced in above.

One caveat against that reject, recorded because it is unusual. It is the
cheapest candidate this file has evaluated: ~21 GiB total, arch already
upstream, official pre-quantized drafter and mmproj, Apache-2.0, no fork build,
no unmerged PR. And it is the first dense candidate whose published quality
would justify a slot if speed were not the issue. If a download is ever spent on
it, the point is to replace a fourth *extrapolation* of the dense penalty with a
measurement. Expect ~6 t/s, and do not wire it into `router.ini` on the
benchmarks above.

---

# Re-adjudicating Thinking-Distill for `fast` - measured 2026-08-14

The `nerkyor-eval` slot has held Thinking-Distill since 2026-08-07 with one
outstanding obligation and a standing recommendation to swap `fast` to it.
Everything that recommendation rested on was re-measured. Most of it does not
survive, the central quality claim does, and a capability nobody had tested
turns out to decide the question.

**Verdict: `fast` keeps the alias, and the deployed Q4_K_M is the reason.** Not
on the margins the original writeup kept for it - both of those are gone - but
on multi-image vision, which was never tested and which is the reason this slot
carries an mmproj at all. The correction below matters: Thinking-Distill is not
incapable of it, its Q4_K_M tier is unreliable at it, and Q6_K is not. So the
open question is no longer "is this model good enough for `fast`" but "is Q6_K
affordable here", which is a throughput and pool question with a measurable
answer.

## What the record claimed, and what it measures at today

| claim | recorded | measured 2026-08-14 |
|---|---|---|
| served throughput | ~39-41 t/s vs `fast`'s 34.6 (+13-18%) | 34.55 vs 33.96 (**+1.7%**) |
| its own tuned draft length | n-max 4, "its own measured peak" | **n-max 2**; 4 is the worst speculated setting at two streams |
| hard reasoning | 10/10 vs 8-9/10 | **holds** - 10/10 in 150 s vs 8/10 in 987 s |
| code-eval-hard | `fast` ahead, 163 s / 27 turns vs 235 s / 33 | **reversed** - TD 187 s / 32 turns vs `fast` 255 s / 29 |
| depth decay | `fast` better, 70.5% vs 68% retained | **level** - 30.2% vs 30.1% retained at 234k |
| vision | "smoke test... worth a closer look before cutover" | **decisive, and against TD** |

## The draft length was wrong, and wrong in the expensive direction

Re-swept with real prompts (`spec-sweep` `PROMPT_FILE`) at one and two streams.
The full table lives in `router.ini`'s `[nerkyor-eval]` comment. Short version:

| n-max | 1 stream tg | 2 streams tg | 2 str aggregate | acceptance (2 str) |
|---|---|---|---|---|
| 0 (none) | 28.05 | 18.50 | 19.25 | - |
| 2 | 36.49 | 20.86 | **19.99** | 0.847 |
| 3 | 36.72 | 19.59 | 18.93 | 0.709 |
| 4 (was deployed) | 36.86 | 18.03 | 15.59 | 0.730 |

At one stream 2/3/4 tie inside a 1% spread against a repeat variance of 1-2%,
measured by running the same cell twice. The original sweep read a 24% win for
4 over 3 out of a run whose own quoted range was 32.73-40.39. At two streams the
deployed n-max 4 was **below not speculating at all** - 18.03 against 18.50 -
and 19% down on aggregate.

Two mechanisms worth keeping. Speculation taxes prefill to subsidise
generation, because MTP's catch-up decode runs over every prefill ubatch; on one
config the two cancelled to the resolution of the log, with n-max 0 and n-max 1
both landing at exactly 62.3 s wall (generation 1.7 s faster, prefill 1.7 s
slower). And per-stream tg systematically flatters speculation on any workload
with real prefill in it, which agentic traffic is - **aggregate is the honest
number**.

TD and `fast` landing on the same draft length is what the shared 256-expert
top-8 verify economics predict. Both return acceptance 0.709 at n-max 3, to
three decimals.

## The column limit is settled by that, and is worth more than recorded

Three slots at n-max 2 is 9 columns, inside the unit's
`GGML_VK_MUL_MAT_VEC_ID_MAX_COLS=12`. At n-max 4 it needed 15, which the README
forbids covering. Measured at conc 3, cols 8 vs 12, with conc-1 controls flat to
0.05%: **+9.4% aggregate, +19.4% per-stream** - against the ~2-3% recorded for
`fast` on synthetic prompts.

## Depth: 262144 is real, and the retention claim was noise

First time anything on this box has been run past 131072. Both aliases taken to
~233,600 tokens (89% of the configured ceiling) by growing one context with
`cache_prompt` so each step prefills only the delta.

| cumulative depth | `fast` pp | TD pp | `fast` tg | TD tg |
|---|---|---|---|---|
| ~39k | 224.0 | 220.1 | 26.00 | 24.37 |
| ~75k | 122.4 | 121.8 | 18.96 | 21.35 |
| ~114k | 84.0 | 83.7 | 17.66 | 18.87 |
| ~154k | 63.2 | 63.2 | 14.42 | 15.84 |
| ~193k | 50.6 | 50.6 | 12.14 | 13.46 |
| ~234k | 42.2 | 42.3 | 10.27 | 10.41 |

Prefill is identical at every depth - 63.2 vs 63.2, 50.6 vs 50.6 - as the shared
GDN-hybrid shape predicts. tg differences track draft acceptance, which is
**content-dependent, not depth-dependent** (it wandered 0.72-0.95 in both models
with no trend), so single-point tg comparisons at depth are noise. Retention to
234k is 30.2% (`fast`) against 30.1% (TD): the recorded 70.5-vs-68% advantage is
not there.

Two operational facts fall out. **GTT does not grow with depth** - it is
preallocated at `ctx-size` on load and stayed pinned at 14.7 GiB (`fast`) and
13.2 GiB (TD) across every depth - so the load-time footprint is the worst case
and a long conversation cannot creep the pool. And TD runs 1.5 GiB leaner.

## Vision is where it is decided, and it needed a harness that did not exist

`check-vision-tools.sh` names colours in a four-quadrant square. That was the
entire vision evidence behind the swap recommendation, which said so and
deferred the question. `check-vision-agentic.sh`, added today, puts four items
in front of the model over `/v1/messages`: read a field value out of rendered
pixels, locate the highlighted button, compare two screenshots differing in one
field, and read a value then call a tool with it.

`read`, `locate` and `act` pass on both models. TD reads `8080` off the pixels
and calls `apply_port` with it - vision and tool use in one turn, which no
existing test covered.

`compare` does not. Controlled three-trial loop, identical request:

| | `fast` | TD |
|---|---|---|
| correct | **3/3** | **0/3** |
| output tokens | 237, 237, 237 | 8000 (trunc), 8000 (trunc), 2035 |
| thinking | 708c, byte-identical x3 | 28,518c / 31,786c / 7,638c |
| failure mode | - | 2 non-terminations, 1 "only one screenshot is provided" |

Across all attempts today under varying conditions TD answered correctly about
twice in eight tries; in the clean loop, never. And 28.5k/31.8k chars without
concluding is **the non-termination signature that rejected
Ornith-Agents-A1-3.6, MiniMax-M2.1 and nerkyor's own APEX-MTP variant** - TD was
legitimately cleared of it on the reasoning tier, 10/10 in 16k chars total, and
exhibits it here.

### Corrected same day: it is the quant tier, not the model

The paragraph above originally read this as a perception failure, citing two
responses that stated only one screenshot was provided. **That attribution was
wrong**, and the correction is the whole reason the Q6_K download was worth
spending. Q6_K and Q4_K_M measured back to back, both standalone on 8081 under
identical settings so the comparison is internally consistent:

| | correct | output tokens per trial | deterministic |
|---|---|---|---|
| **Q6_K** | **3/3** | 188, 188, 188 | yes, byte-identical |
| Q4_K_M | 3/3 | 1842, 1875, 2768 | no, drifts upward |
| Q4_K_M, repeated later at the SAME settings | **0/2** | 3008 (wrong), 8000 (trunc) | no |
| Q4_K_M through the router | **0/3** | 8000, 8000, 2035 | no |
| `fast` through the router | 3/3 | 237, 237, 237 | yes |

TD can do this task. **Quantization sets the margin, not the outcome.** Q6_K
solves it in 188 tokens with enormous headroom and repeats byte-identically.
Q4_K_M solves it only barely - 1.8k to 3k tokens, wandering between runs - and
that thin margin tips into non-termination roughly half the time. The "only one
screenshot" responses are a model reasoning past its budget, not one that cannot
see the second image.

An intermediate hypothesis, that production conditions (`parallel 3`,
`ctx 262144`) were responsible, was tested and **rejected**: the identical
standalone configuration scored 3/3 once and 0/2 an hour later. A
condition-isolation sweep was started and abandoned once the baseline arm
reproduced the failure, because Q4's intrinsic variance on this item is larger
than any effect that sweep could resolve at two trials per condition. Do not
retry that experiment without many more trials per cell.

Method note, and it is the same one this file keeps relearning: the first
reading pattern-matched a single contrast (router fails, standalone passes) onto
a mechanism, exactly as the 2026-08-04 incident matched draft-KV bandwidth onto
a fault whose scope had never been established. The control that caught it was
running BOTH tiers standalone rather than comparing new Q6 numbers against
Q4 numbers taken through a different harness.

`fast` remains correct, cheap and deterministic on this item. So is TD at Q6_K,
in fewer tokens than `fast` needs.

## A note on determinism, because two results depend on it

Temperature 0 is not a determinism guarantee across batch geometry. `fast`
produced byte-identical 708-char runs three times in a clean back-to-back loop,
and truncated on the same request when it ran third in a script behind two other
requests. Changing what precedes a request changes slot and cache state, which
changes `MUL_MAT_ID` shapes, which changes floating-point reduction order, which
can flip a near-tied token. The same mechanism explains `fast`'s code-eval-hard
divergence from its 2026-08-03 baseline (255 s / 29 turns against 163 s / 27),
which predates `parallel` 2 -> 3.

**Consequence for method: compare models measured in the same session under the
same conditions, and do not compare either against a historical number taken
under a different slot count.** Today's `fast`-vs-TD comparisons are sound;
`fast` against its own August 3 code-eval-hard number is not. `reason-eval-hard`
reproduced to within 1% for both models, so this is item-specific sensitivity
rather than general drift.

## What is not in doubt

Both aliases are clean on Claude Code's plumbing over `/v1/messages`: streaming
with `tool_use` blocks, `cache_control` accepted, and prefix restore reading
10,256 of 12,304 tokens from cache, where the residue is exactly one `ubatch`.
Identical on both. A `TRANSPORT=oai` control on the new Claude tier returns the
same scores and turn counts either way, so the Anthropic path costs nothing and
any future tool-calling fault belongs to the model, not the translation layer.

The box was clean across roughly five hours of heavy load including two runs to
234k tokens: **zero ring timeouts, zero resets, zero device-wedged events** on
the host. One `Fence fallback timer expired on ring comp_1.2.1` appeared, under
`fast` and not TD - a late or lost fence interrupt caught by the driver's
fallback poll, with no reset and no failed request. It is not the incident
signature and should not be read as one.

## What Q6_K costs, and what it buys - measured 2026-08-14

The vision correction above turned the question from "is this model good enough
for `fast`" into "is Q6_K affordable". Both halves are now measured.

### Cost, on the same harness and prompts as the n-max sweep

| | Q4_K_M | Q6_K | delta |
|---|---|---|---|
| tg, 1 stream | 36.49 | 31.36 | **-14.1%** |
| pp, 1 stream | 358.9 | 279.2 | -22.2% |
| aggregate, 1 stream | 19.63 | 16.10 | -18.0% |
| tg, 2 streams | 20.86 | 17.18 | -17.6% |
| aggregate, 2 streams | 19.99 | 15.27 | -23.6% |
| on disk | 20.22 GiB | 27.2 GiB | +7.0 GiB |

The bytes-per-token model predicts -25.7% on tg from the weight ratio alone;
actual is -14.1%, because KV and activations do not scale with the tier. The
arithmetic sets a ceiling here, not a forecast - same as everywhere else on this
box.

Against the incumbent, which is what the slot decision needs. Standalone reads
about 5.6% high versus production on this model (Q4 measured 36.49 standalone
against 34.55 through the router), so Q6_K lands near **29.7 t/s served against
`fast`'s 33.96 - roughly 12% slower**, and 5.3 GiB heavier than Ornith's 21.9.

### What it buys: better weights than `fast` has access to

`llama-perplexity`, 80 chunks, `-c 512`, `/root/ppl-holdout-ornith.txt` - the
same corpus and method as the Ornith requant work. Both models are `qwen35moe`
with the `gpt2` tokenizer and an identical 248,320-token vocab (checked, not
assumed), so the numbers share a denominator.

| model / tier | PPL |
|---|---|
| **TD Q6_K** | **2.0079 +/- 0.02453** |
| Ornith BF16 (unquantized source) | 2.0131 +/- 0.02495 |
| Ornith APEX I-Quality (deployed `fast`) | 2.0183 +/- 0.02510 |
| **TD Q4_K_M (deployed `nerkyor-eval`)** | **2.0245 +/- 0.02489** |

The within-model delta is the clean one: **Q4 -> Q6 is worth 0.82%**. For scale,
this file established that Ornith's entire distance from its own BF16 weights is
0.26%, so **TD's quantization gap is 3.2x Ornith's total quantization
headroom**. Q4_K_M is doing real damage to this model where APEX's adaptive mix
costs Ornith almost nothing.

Two consequences, one solid and one that did NOT survive checking:

- **TD as deployed is worse than `fast` on perplexity** (2.0245 against 2.0183).
  Nobody had measured this; the record had TD winning on quality throughout.
  Solid - see the paired analysis below.
- **TD at Q6_K is NOT established as better than Ornith.** An earlier version of
  this section claimed it was better "at any tier, including its unquantized
  weights", on the strength of 2.0079 against Ornith's BF16 2.0131. The paired
  per-chunk analysis does not support that, and the claim is withdrawn.

### Paired per-chunk analysis - the step that settles the sign

All three runs re-taken 2026-08-14 with per-chunk output retained, because the
final estimates sit inside the individual error bars and only the paired
ordering can establish a sign. All three reproduced their earlier final
estimates EXACTLY, to four decimals and the same error bar - perplexity is
bit-reproducible here, unlike generation, which makes the pairing trustworthy.

Counting cumulative chunks 20-80, the way the Ornith requant work did it:

| pair | lower at | mean gap | flips? |
|---|---|---|---|
| TD-Q6 vs TD-Q4 | **61 of 61** | +0.0166 | no, min +0.0132 |
| Ornith vs TD-Q4 | **61 of 61** | +0.0124 | no, min +0.0057 |
| TD-Q6 vs Ornith | 51 of 61 | +0.0042 | **yes, min -0.0101** |

The first two are solid by this file's own standard: the ordering never flips
once converged. **The third is not.** TD-Q6 reads lower on average but the sign
reverses on 10 of 61 chunks and the mean gap is a third of the other two. On
this corpus **TD-Q6 and Ornith are a wash**, and any claim that one is the
better model needs a different instrument than perplexity.

What survives is the within-model result (Q4 -> Q6 is real and large) and the
deployed-tier result (TD-Q4 is genuinely worse than `fast`). What does not
survive is the cross-model ordering at Q6, which was the more exciting claim and
the wrong one. The lesson is the same one this file keeps paying for: a
difference inside the error bars is not a finding until the paired ordering is
checked, and checking it here took one re-run.

It also explains the vision result mechanically. Two-image comparison is a
marginal task for this model, and Q4 spends the margin on quantization damage:
188 deterministic tokens at Q6 against 1,800-8,000 wandering ones at Q4.

Cross-model PPL caveat, stated because it limits the second bullet: the corpus
was built to be held out from *Ornith's imatrix*, not from either model's
training data, and it is llama.cpp source, which is public. Contamination is
possible and unquantified for both. The within-model Q4-vs-Q6 comparison is
unaffected; the cross-model ordering is suggestive rather than settled, and the
deltas sit inside the individual error bars.

### The trade, priced

TD-Q6 for `fast` costs ~12% of served generation and 5.3 GiB of pool, and buys
better perplexity than `fast` can reach at any quantization, 10/10 hard
reasoning against 8/10 at 6.6x the speed, vision parity (188 tokens against
`fast`'s 237, both deterministic), and 20% fewer turns on the Claude Code tool
surface.

That is a real trade with a real price, not the free upgrade the 2026-08-04
writeup described. It is not taken today. What it needs first is the soak, run
against Q6_K rather than Q4 - a soak of the tier that is not being deployed
proves nothing - plus a `check-vision-agentic` and `reason-eval-hard` pass on
Q6 through the router rather than standalone.

## Final tally, Q6_K through the router - and the Q4 tier removed

Everything below was taken through the production router on 2026-08-14, because
`fast`'s numbers were, and the determinism finding above forbids mixing
harnesses. Q6_K carried the same spec config the Q4 tier did, so the tier was
the only variable.

| axis | `fast` (Ornith) | TD-Q4_K_M | TD-Q6_K |
|---|---|---|---|
| tg, 1 stream | **33.96** | 34.55 | 30.66 |
| pp, 1 stream | **347.8** | 337.9 | 296.4 |
| GTT + VRAM | **30.7 GiB** | 29.1 GiB | 36.0 GiB |
| perplexity | 2.0183 | 2.0245 | 2.0079 |
| reason-eval-hard | 8/10, 987 s, **2 trunc**, 93.6k chars | 10/10, 150 s, 16.6k | **10/10, 207 s, 0 trunc, 20.4k** |
| code-eval-claude | 6/6, 128 s, 41 turns | 6/6, 104 s, 35 turns | **6/6, 115 s, 33 turns** |
| vision, 4-item tier | 3/4 (compare TRUNC) | 3/4 | **4/4** |
| vision, compare x3 | 3/3 @ 237 tok | **0/3** | 3/3 @ **188 tok** |
| determinism on compare | byte-identical | none | byte-identical across TWO harnesses |

Q6_K reproduced its standalone compare result byte-for-byte through the router -
188 tokens, 560 chars, three times here and three times standalone. Q4 flipped
between conditions constantly. That is the margin difference made visible: Q6 has
so much headroom on this item that batch geometry cannot perturb it.

### What the Q4 tier cost, and why it is gone

`nerkyor-eval` was removed from `router.ini` and its 20.22 GiB deleted on
2026-08-14. It was not merely the weaker tier - it was **worse than the alias it
was competing with**, on the one instrument that is bit-reproducible here:

    Ornith vs TD-Q4    Ornith lower at 61 of 61 paired chunks   mean +0.0124

The mmproj is kept: `td-q6-eval` shares it.

### The trade at Q6, priced

Give up ~10% of served generation, ~15% of prefill and 5.3 GiB. Get 10/10
against 8/10 on the tier built to discriminate, with `fast` truncating twice and
burning 93.6k chars against 20.4k; 20% fewer turns on the Claude Code surface;
and multi-image vision at 188 tokens against `fast`'s 237.

**Perplexity does not contribute to that case.** TD-Q6 and Ornith are a wash -
51 of 61 with the ordering reversing. The argument is task results only.

Not deployed. What it owes: a soak on Q6_K, not on a tier that no longer exists.

## Where this leaves Thinking-Distill

It is the better model on nearly everything this box measures, and the gap on
hard reasoning is large and reproducible: 10/10 against 8/10, 6.6x faster, 5.6x
less reasoning, zero truncations against two. It needs 20% fewer turns on the
Claude Code tool surface, where the retired opencode tier had said the opposite
(47 turns against 32). It is 1.5 GiB leaner and marginally faster.

At **Q4_K_M** it cannot reliably compare two images, and `fast` holds this alias
because Hermes sends screenshots. At **Q6_K** it can, deterministically, in
fewer tokens than `fast` needs. Neither tier is deployed to `fast` on the
strength of that alone - the tier costs 7 GiB and this box is bandwidth-bound,
so the throughput and pool numbers decide it.

Two live options, in the order they should be measured:

1. **TD Q6_K for `fast`.** Clears the vision bar that Q4 failed and keeps every
   other advantage. Costs 27.2 GiB against Ornith's 21.9 and TD-Q4's 20.2, and
   generation here is bytes-per-token, so expect a double-digit tg loss against
   TD-Q4 that has to be weighed against `fast`'s 33.96. Pool fit is not in
   doubt at `models-max 1`; throughput is the question.
2. **TD for `coder`, which is text-only** and where the vision result does not
   apply at either tier. TD-Q4 serves at 34.55 t/s against `coder`'s 26.14 -
   `coder` has no MTP head, no drafter and no speculation at all - and adds
   10/10 hard reasoning. This is the cheaper win and needs no new download.

The soak this candidate has owed since 2026-08-04 was deliberately **not** run.
It answers whether TD is stable enough for `fast` under real traffic, which was
moot while the vision result stood against it. If either option above is taken
up, the soak becomes load-bearing again and should be run against the tier that
is actually being deployed - a Q4 soak says nothing about Q6.

---

# KAT-Coder Q4_K_XL vs Q6_K - measured 2026-08-14

Repeating on KAT the tier comparison that overturned the Thinking-Distill
verdict the same day. **The result is the opposite, and that is the finding.**

**Verdict: keep Q4_K_XL, reject Q6_K.** It costs 9.3% of generation and 6.6 GiB,
buys 0.20% of perplexity, and introduces the non-termination failure mode this
repo treats as disqualifying.

Both tiers measured through the production router in one session. The
2026-08-07 kat-eval numbers were NOT cited - they predate `parallel` 2 -> 3 and
used the retired opencode tier - so Q4 was re-taken here.

## Throughput

| | Q4_K_XL | Q6_K |
|---|---|---|
| on disk | 21.29 GiB | 27.95 GiB |
| GTT + VRAM | 28.9 GiB | 35.5 GiB |
| tg, 1 stream | **29.01** | 26.32 (-9.3%) |
| pp, 1 stream | 292.0 | 289.6 (-0.8%) |

Prefill barely moves, where TD's Q6 cost 14.8%. That is the byte budget showing
through: KAT's UD mix already spends 68% of per-token bytes on Q8_0 non-expert
tensors, so Q4 -> Q6 mostly touches the 22.3% that is routed experts, and
experts dominate generation far more than prefill.

## The higher tier is WORSE, reproducibly

`reason-eval-hard`, two runs each:

| | run 1 | run 2 |
|---|---|---|
| **Q4_K_XL** | 8/10, **0 trunc**, 103 s, 7,354c | 8/10, **0 trunc**, 129 s, 8,805c |
| **Q6_K** | 8/10, **1 trunc**, 394 s, 46,360c | 7/10, **2 trunc**, 689 s, 77,851c |

Three truncations across two Q6 runs against zero across two Q4 runs, reasoning
volume 6-9x higher, and the score dropping to 7/10. Q4's spread (103-129 s,
7.4-8.8k chars) is nowhere near large enough to explain it. At Q6 this model is
about as bad on this tier as `fast` is (7/10, 2 trunc, 689 s against `fast`'s
8/10, 2 trunc, 987 s).

**The most defensible reading: KAT's celebrated reasoning economy at Q4 is
substantially a quantization artifact, and the artifact was helping.** Coarser
logits terminate the chain early; at Q6 the model's actual behaviour on hard
reasoning emerges and it does not know when to stop.

The other two tiers do not show the same direction, which is why this needed
repeating rather than asserting:

| tier | Q4 -> Q6 |
|---|---|
| reason-eval-hard | much worse (7.4k -> 46-78k chars, 0 -> 3 truncations) |
| code-eval-hard | worse (5,915c -> 8,948c, same 20 turns, 175 s -> 250 s) |
| code-eval-claude | **better** (45 -> 39 turns, and it fixes 1 rbe + 1 edit miss) |

That last row matters and matches TD: **the higher tier repairs marginal
tool-discipline failures.** Q4 is the only model measured today to violate
read-before-edit or miss an edit on the Claude Code surface; Q6 does neither.
So the tier helps where the task is marginal and hurts where the task invites
unbounded reasoning.

## Perplexity - and the answer to the open byte-budget question

`llama-perplexity`, 80 chunks, `-c 512`, same corpus, paired per-chunk ordering
over chunks 20-80:

| model | PPL | vs |
|---|---|---|
| TD-Q6_K | 2.0079 | - |
| **`fast`** | **2.0183** | - |
| TD-Q4_K_M | 2.0245 | - |
| KAT-Q6_K | 2.0443 | - |
| KAT-Q4_K_XL | 2.0484 | - |

| pair | lower at | mean gap | verdict |
|---|---|---|---|
| KAT-Q6 vs KAT-Q4 | 61/61 | +0.0060 | solid, and small |
| `fast` vs KAT-Q4 | 61/61 | +0.0278 | solid |
| `fast` vs KAT-Q6 | 61/61 | +0.0217 | solid |
| TD-Q6 vs KAT-Q6 | 61/61 | +0.0259 | solid |

**This answers the question the 2026-08-07 section asked and never got.** That
section recorded that KAT's UD mix spends 68% of per-token bytes on Q8_0
non-expert tensors and only 22.3% on all 256 routed experts, called the budget
badly allocated, and asked for a held-out perplexity run before retargeting the
experts to IQ4_XS. The run says the mix is **not** starving the experts:
doubling their precision buys 0.20%, comparable to Ornith's entire 0.26%
distance from its own BF16. This model is quantization-insensitive in this band.

Which makes the IQ4_XS retarget the lever worth pulling, exactly as that section
guessed - if the experts are insensitive going up, the 68% spent on Q8_0
non-expert tensors is where the bytes are wasted, and the predicted ~32 t/s
unspeculated is worth measuring. **Do not simply requantize the experts
downward without re-running reason-eval-hard**: this section has just
established that this model's termination behaviour is quantization-sensitive
even where its perplexity is not.

## Also worth recording: perplexity is not a capability proxy

KAT is the **best** model measured today on `code-eval-hard` turn economy (20
turns at both tiers, against 29-32 for everything else) and the **worst** on
perplexity, on a code corpus, as a model post-trained for coding. Post-training
for agentic behaviour evidently trades against next-token fit. Rank on the tier
that matches the job, not on PPL.

## Where this leaves KAT

`kat-eval` stays at Q4_K_XL. Q6_K is rejected on the numbers above.

What has still never been measured is KAT against **`coder`**, the alias it
would actually take - it is text-only and `coder` is the text-only coding slot.
Every comparison so far has been against `fast`. The 2026-08-07 record has KAT
ahead of `coder` (332.9/29.24 against 326/26.14, and `coder` carries no
speculation at all), but that record predates `parallel` 2 -> 3 and cannot be
cited under the determinism rule. That head-to-head needs no download and is
the next thing worth running.

---

# `coder` measured, and the record was wrong about it - 2026-08-14

`coder` had never been run through this session's battery. It is a production
alias whose last numbers date from 2026-08-03, predating `parallel` 2 -> 3, so
under the determinism rule they could not be carried into any comparison. It
was measured only because KAT was deleted and the summary table had a hole in
it.

**It scores 10/10 on `reason-eval-hard` with zero truncations, twice.** The
README's capability table lists this alias as `reasoning: no`.

## The correction

| run | result |
|---|---|
| 1 | 10/10 correct, 0 truncated, 254 s, 20,345 chars |
| 2 | 10/10 correct, 0 truncated, 276 s, 22,355 chars |

That ties TD-Q6_K, the challenger this repo spent the day evaluating for the
`fast` slot, whose entire case rested on 10/10 against `fast`'s 8/10. TD-Q6
produced 10/10, 0 truncated, 207 s, 20,376 chars - within 31 characters of
`coder`'s first run.

`coder` carries `reasoning-format = deepseek` in `router.ini` and emits ~20k
chars of reasoning per pass. The "no reasoning channel" line in the README is
simply wrong, and it has been wrong while this repo searched for a model that
could beat `fast` on exactly this axis. **The box already had one, deployed,
for eleven days.**

## Full numbers, same session as everything else

| | value |
|---|---|
| GTT + VRAM | **24.0 GiB** - the lightest alias measured |
| tg, 1 stream | 25.71 (range 25.67-25.71) |
| pp, 1 stream | 312.3 |
| perplexity | 2.0177 +/- 0.02463 |
| reason-eval-hard | **10/10, 0 trunc**, 254/276 s, 20.3/22.4k |
| code-eval-hard | 6/6, 250 s, 31 turns, 9,494c |
| code-eval-claude | 6/6, 147 s, **31 turns**, 0 rbe, 0 lnum, 0 edmiss |
| vision | none - no mmproj |
| speculation | **none** - no MTP head, no drafter, card says do not pass --model-draft |

Its tg range is the tightest measured today, 25.67-25.71, because without a
drafter there is no acceptance variance. Every speculating alias shows a wider
band.

Paired perplexity, chunks 20-80:

| pair | lower at | verdict |
|---|---|---|
| `coder` vs `fast` | 10/61, flips | **a wash** |
| TD-Q6 vs `coder` | 61/61, no flips, mean +0.0099 | solid |

So TD-Q6 is genuinely ahead of `coder` on raw fit, while `coder` and `fast` are
indistinguishable - the same pattern TD-Q6 and `fast` showed.

## What this does to the TD-Q6 case

TD-Q6's argument for taking `fast` was that it is the only model here that
solves the two hard-reasoning items `fast` cannot finish. That is no longer
true. `coder` solves them too, at **24.0 GiB against TD-Q6's 36.0**, with no
download, no soak owed and no new risk.

What TD-Q6 still has that `coder` does not:

- **vision** - `coder` has no mmproj and cannot take an image at all
- **speed** - 30.66 tg against 25.71, and 33 turns against 31 on the Claude
  tier, so comparable session latency despite the throughput gap

So the honest framing of the remaining choice is narrower than it was this
morning. TD-Q6 is worth 5.3 GiB over `fast` **only** if a single alias must do
hard reasoning AND vision AND tools at once. If the reasoning work can be
routed to a text-only alias, the box already covers it.

The catch is `--models-max 1`: routing between `fast` and `coder` costs a
15-30 s model swap per switch, and two clients naming different aliases evict
each other every turn. That is the real argument for one strong all-rounder,
and it is a serving-topology argument rather than a model-quality one.

## What to do about it

1. **Fix the README capability table.** `coder` reasons, and well.
2. **Route hard reasoning to `coder` today.** It is deployed, it is the lightest
   alias here, and it is 10/10 on the tier built to discriminate. `deep` remains
   for work that needs 117B.
3. Re-run this battery on any alias whose documented capabilities have never
   been measured. `coder` was mischaracterised for eleven days and the error was
   found by accident, while filling a hole in a table.

---

# `coder` Q5, and `coder` has vision - measured 2026-08-14

Two results from one run. The tier question was the one asked; the vision
result is the one that matters.

**Verdict: keep Q4. Add the mmproj to it.**

## `coder` has vision, and always did

The GGUF repo publishes `mmproj-Qwen3.6-35B-A3B-Q8_0.gguf`, 0.57 GiB. The
deployed stanza has never loaded it and this alias has been documented as
text-only since it took the alias on 2026-08-03. Loaded against the **deployed
Q4 weights, unchanged**:

| item | result |
|---|---|
| read (field value off rendered pixels) | PASS |
| locate (which button is highlighted) | PASS |
| compare (two screenshots, one changed field) | PASS |
| act (read a value, call a tool with it) | PASS |
| compare, 3-trial reliability | **3/3** - 235/233/233 tokens, 678/684/684 chars |

**4/4, and stable.** For context on that `compare` item: `fast` scores 3/4 on
this tier because compare TRUNCATES at a 4000-token budget, and TD-Q4 scored
0/3 on the reliability loop. `coder` passes it deterministically in ~233
tokens, which is better than `fast` manages at all.

Cost: 24.8 GiB resident with the mmproj against 24.0 without. **0.8 GiB for
vision, on the lightest alias here.**

This retires the last argument for TD-Q6_K. After `coder` measured 10/10 on
reason-eval-hard, the only thing left for TD was that one alias should do hard
reasoning AND vision AND tools together. `coder` does all three, at 24.8 GiB
against TD-Q6's 36.0, already deployed.

## The Q5 tier: real perplexity, zero capability

The ladder is Q3_16G / Q4 / Q5 / Q8_0 - there is no Q6. Q5-imatrix is 27.60 GiB
against Q4's 19.06.

| | Q4 (+mmproj) | Q5 | delta |
|---|---|---|---|
| resident | **24.8 GiB** | 33.2 GiB | +8.4 |
| tg | **25.71** | 21.57 | **-16.1%** |
| pp | **312.3** | 289.9 | -7.2% |
| perplexity | 2.0177 | **2.0024** | **-0.76%, 61/61 solid** |
| reason-eval-hard | 10/10, 0 trunc, 254/276 s | 10/10, 0 trunc, 312/319 s | **neutral** |
| code-eval-hard | 6/6, 250 s, 31 turns | 6/6, 270 s, 31 turns | **neutral** |
| code-eval-claude | 6/6, 147 s, 31 turns | 6/6, 143 s, **28 turns** | slightly better |
| vision tier | 4/4 | 4/4 | **neutral** |

The reasoning result is the clean one. Q4's mean wall scaled by the throughput
ratio predicts 316 s for Q5; Q5 measured 312 s and 319 s. **Every second of the
difference is throughput. The model behaves identically.**

**This is the important finding, and it is a negative one: a real, solid 0.76%
perplexity gain bought no capability whatsoever.** Same score on every tier,
same truncation count, same turn count on two of three coding tiers, same
vision result. Compare TD, where 0.82% - almost the same magnitude - fixed a
multi-image failure outright. Perplexity gain does not predict capability gain,
and this is now measured rather than argued.

Q5's one win is 28 turns against 31 on the Claude Code tier, the best turn count
of any model measured. It finished that tier in 143 s against Q4's 147 s despite
being 16% slower per token, because three fewer turns more than paid for it.
That is not worth 8.4 GiB and 16% of generation everywhere else.

## Where this leaves the tier experiment, across four models

The same experiment has now produced four different answers:

| model | Q4 -> higher tier PPL | capability effect |
|---|---|---|
| TD | 0.82% | **fixed** multi-image vision, 0/3 -> 3/3 |
| KAT | 0.20% | **broke** termination, 0 -> 3 truncations |
| `coder` | 0.76% | **nothing** |

Two of these were surprises against the prior. **Do not infer the tier effect
from perplexity, from another model, or from the same model's other tiers -
measure it.** And note the shared thread that does hold: on TD and KAT the
higher tier repaired marginal tool-discipline failures, which is the one effect
that has been consistent.

## Perplexity ordering, all pairs

| model | PPL | |
|---|---|---|
| **`coder` Q5** | **2.0024** | best measured |
| TD-Q6_K | 2.0079 | |
| `coder` Q4 | 2.0177 | |
| `fast` | 2.0183 | |
| TD-Q4_K_M | 2.0245 | deleted |
| KAT-Q6_K | 2.0443 | deleted |
| KAT-Q4_K_XL | 2.0484 | deleted |

| pair | lower at | verdict |
|---|---|---|
| coder-Q5 vs coder-Q4 | 61/61 | solid |
| coder-Q5 vs TD-Q6 | 61/61 | solid |
| TD-Q6 vs `coder` Q4 | 61/61 | solid |
| coder-Q5 vs `fast` | 57/61, one -0.0014 flip | probable, short of solid |
| `coder` Q4 vs `fast` | 10/61, flips | wash |
| TD-Q6 vs `fast` | 51/61, flips | wash |

## Also confirmed: `coder` really has no MTP head

Checked rather than inherited, because the same docs got vision wrong. The
tensor scan tops out at `blk.39` against `block_count = 40` - no head - and the
server refuses to start with `--spec-type draft-mtp`:

    llama_init_from_model: context type MTP requested but model doesn't contain MTP layers
    common_speculative_init_result: failed to create MTP context
    llama_server: exiting due to model loading error

So one claim was wrong and the other right, which is the point of checking. The
failure mode is safe - llama.cpp exits rather than silently serving
unspeculated - and `coder`'s ~25 t/s ceiling against `fast`'s ~34 is structural,
not a tuning miss.

---

# `coder` restored as `coder-eval` - 2026-08-14, hours after it was deleted

Restored by request, at Q4-imatrix plus the mmproj. Recorded here because a
delete-and-redownload inside one day looks like indecision unless the reason is
written down: it was never rejected on measurement. The three-alias cut was a
lineup-size decision, and this model's own section above ("`coder` has vision,
and always did") is the strongest result in this file.

## What was restored, exactly

| | file | size |
|---|---|---|
| weights | `Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-LynnStyle-Q4-imatrix.gguf` -> `EVAL-coder-Q4.gguf` | 19.06 GiB |
| mmproj | `mmproj-Qwen3.6-35B-A3B-Q8_0.gguf` -> `EVAL-coder-mmproj-Q8_0.gguf` | 0.57 GiB |

Both SHA256-verified by `fetch-model.sh` against the HF API.

**This is `coder-vision-eval`'s config, not `coder`'s.** Production `coder`
never loaded an mmproj - the stanza had none for the eleven days it held the
alias, on the assumption that the repo published none. It does, and the
capability was only measured on the day the alias was cut. The Q4 weights are
byte-identical to what shipped; the mmproj is the whole difference.

**Q5 is deliberately not restored.** It is settled: 0.76% perplexity, solid at
61 of 61 paired chunks, and zero capability change - same 10/10, same zero
truncations, same turn counts, same vision result - for +8.5 GiB. Restoring it
would be re-running an experiment that already has an answer.

## What it is worth, and what it costs

Carried forward from the same-session measurements above, and **not to be cited
as a live comparison** - nothing on this box compares across sessions:

| | `coder` Q4 +mmproj | `balanced` | `fast` |
|---|---|---|---|
| resident | **24.8 GiB** | 36.0 | 30.7 |
| reason-eval-hard | 10/10, 0 trunc, 254/276 s | 10/10, 0 trunc, 207 s | 8/10, 2 trunc, 987 s |
| vision compare | 3/3 @ 233 tok | 3/3 @ 188 tok | TRUNC |
| tg / pp, 1 stream | 25.71 / 312.3 | 30.66 / 296.4 | **33.96 / 347.8** |
| speculation | none (verified: no MTP head) | MTP n-max 2 | MTP n-max 2, p-min 0.3 |

So it ties the default on the tier built to discriminate, at 11.2 GiB less
pool, and pays ~16% of generation for it. That trade is the open question the
slot exists to settle; it is not settled by the table above.

## What it would take to promote it

It is an eval slot. `load-on-startup = false`, not in `opencode.json`, selected
by name only. Giving it a production alias means EVAL-PLAYBOOK.md end to end
against **today's** `balanced` in one session - steps 3 through 5 at minimum,
since the numbers above were taken under a lineup that no longer exists - plus
step 9, the soak, which this model has never had at any tier.

Two things already established that the re-run does not need to redo: it has no
MTP head (checked in the tensor scan, and the server refuses `--spec-type
draft-mtp` outright), so there is no draft length to sweep beyond the n-max 0
baseline; and the tier question is answered.

---

# Three candidates, 2026-08-15 - the session where perplexity inverted

Two candidates tested against `fast` and one against `balanced`, by request.
All three rejected. Everything below is same-session through the production
router, `bench-guard.sh` reporting "no throttling, result is trustworthy" on
every throughput run, build `05dad3b`, `parallel = 3`.

The models, and what step 0 established before any weights were downloaded:

| | `apexq-eval` | `apexmtp-eval` | `reap30-eval` |
|---|---|---|---|
| repo | `mudler/Qwen3.5-35B-A3B-APEX` | `nerkyor/Qwen3.6-35B-A3B-APEX-MTP` | `zTrojan/Qwen3.5-122B-A10B-REAP30-APEX` |
| tier / size | I-Quality, 21.25 GiB | I-Balanced, 24.27 GiB | Mini, 30.76 GiB |
| arch | `qwen35moe`, 40 blk, 256 exp top-8 | `qwen35moe`, 40 blk | `qwen35moe`, 48 blk, **180 exp** top-8 |
| MTP head | **dropped in conversion** | present | **dropped in conversion** |
| vision | mmproj published | none | none |
| vocab | 248320 gpt2 | 248320 gpt2 | 248320 gpt2 |

**Step 0 was done by range-fetching 50 MB of each GGUF header**, not by
downloading the weights. `curl -r 0-52428800` on the resolve URL carries the
full KV block and tensor table, which answers arch, block count, expert count,
context length, tokenizer, chat template and MTP presence. That is the cheapest
step in this playbook and it decided the shape of the whole session; it belongs
in step 0 permanently.

All three carry the **same 248320-token gpt2 vocab as `fast`**, which is why
cross-model perplexity below is legitimate rather than merely suggestive. That
is rare here, and it was verified from each GGUF KV rather than assumed.

## Results

| | **`fast`** | **`apexq-eval`** | **`balanced`** | **`deep`** | **`reap30-eval`** | **`apexmtp-eval`** |
|---|---|---|---|---|---|---|
| role | control | candidate | control | control | candidate | candidate |
| tg 1 stream | 33.46 | 24.56 | 30.57 | 15.55 | 13.06 | **35.14** |
| pp 1 stream | **320.2** | 247.2 | 286.0 | 138.9 | 129.9 | 251.9 |
| tg 2 stream, aggregate | **17.49** | 13.79 | 14.40 | 8.23 | 6.86 | 16.22 |
| draft acceptance | 0.808 | none | 0.861 | none | none | 0.795 |
| **reason-eval-hard** | 8/10, 1 TRUNC, 880 s, 79.5k | 8/10, **2 TRUNC**, 1119 s, 87.2k | **10/10, 0 TRUNC**, 212 s, 20.7k | 8/10, **0 TRUNC**, 546 s, 26.6k | **6/10, 4 TRUNC**, 2929 s, 111.6k | **5/10, 5 TRUNC**, 1483 s, 143.3k |
| code-eval-hard | 6/6, 192 s, 29 t | **2/6**, 131 s, 18 t | 6/6, 271 s, 33 t | 5/6, 948 s, 56 t | 6/6, 389 s, 33 t | not run |
| code-eval-claude | 6/6, 115 s, 39 t | 6/6, 162 s, 31 t, **1 RBE** | 6/6, 114 s, 33 t | 6/6, 215 s, 34 t | 6/6, 306 s, 35 t | not run |
| vision tier | 3/4 (compare TRUNC) | 3/4 (compare TRUNC) | **4/4** | n/a | n/a | n/a |
| perplexity | 2.0183 | 2.0405 | 2.0079 | not comparable | 2.1699 | **2.0069** |

Paired per-chunk ordering over chunks 20-80, the reading that decides sign:

| pair | lower at | reading |
|---|---|---|
| `apexmtp` vs `fast` | 61/61 | **solid** - apexmtp better |
| `apexmtp` vs `balanced` | 41/61, 6 flips | wash |
| `balanced` vs `fast` | 51/61, 1 flip | wash |
| `fast` vs `apexq` | 61/61 | **solid** - fast better |
| `balanced` vs `reap30` | 61/61 | **solid** - balanced better |
| `fast` vs `reap30` | 61/61 | **solid** - fast better |

`deep` is excluded from perplexity deliberately: arch `laguna`, different
tokenizer, so a number for it would not be comparable rather than merely noisy.

## The result that matters: perplexity inverted

**`apexmtp-eval` has the best perplexity ever measured on this box** - 2.0069,
lower than `fast` at 61 of 61 paired chunks with no flips, the strongest form
this repo's own test has - **and it is the worst hard reasoner ever measured
here**, 5/10 with 5 truncations and 143k chars of reasoning that never reach a
conclusion. It is also the fastest model ever measured here, 35.14 tg against
`fast`'s 33.46.

EVAL-PLAYBOOK step 8 already said perplexity gain does not predict capability
gain. This is stronger than that. Perplexity did not fail to predict capability
here, it **inverted** it: a solid 61/61 win on the metric alongside the worst
result on the tier that decides. Any future candidate that arrives with a
perplexity argument and no `reason-eval-hard` number has said nothing.

## Two validations of the method, both free

**Perplexity is bit-reproducible, confirmed.** `fast` re-measured 2.0183 +/-
0.02510 and `balanced` 2.0079, matching their recorded figures to four decimals
across eleven days, a `parallel` change and a rebuilt binary. The `balanced` vs
`fast` pairing also re-derived independently as 51/61 with one flip, the exact
historical reading. Incumbent perplexity runs really can be reused across
sessions; this is the verification the playbook asks for.

**The non-termination reject reproduces to 0.13%.** `apexmtp-eval` was rejected
on 2026-08-04 at 6/10, 4 truncations, 143,125 chars of reasoning. Re-tested
today under a different `parallel`, a different binary, and a draft length
re-derived from scratch: 5/10, 5 truncations, **143,308 chars**. Failure to
terminate is a stable property of the model, not a bad day, and it survives
every serving change this box has made. Re-testing a non-termination reject is
close to worthless, which is the argument for spot-checking one tier rather
than running nine steps, as was done here.

## `apexq-eval`: the post-train is doing the agentic work

The closest thing to a controlled experiment this box has run. `fast` is
Ornith-1.0-35B, a post-train **of this exact base model**, quantised with the
same APEX recipe at the same tier, within 0.64 GiB of the same size, same 40
blocks, same 256 experts top-8, same GDN interval 4, same vocab. What differs
is the post-train, plus the MTP head mudler's conversion dropped.

It scored **2/6 on `code-eval-hard`**, a tier that saturates at 6/6 for
everything else ever run here, including a 30%-pruned model at 13 t/s. The
failure detail is the finding:

| task | `apexq-eval` | `fast` |
|---|---|---|
| dup-block | FAIL, 4 turns, 1374c | PASS, 5 turns, 699c |
| two-bugs | FAIL, **2 turns**, 474c | PASS, 5 turns, 727c |
| hidden-call | FAIL, **2 turns**, 489c | PASS, 5 turns, 1833c |
| shared-state | FAIL, **2 turns**, 577c | PASS, 5 turns, 602c |

Every failure is the same shape: it stops after two turns having left the tests
red, with a few hundred characters of reasoning. It is not hitting a capability
ceiling, it never looks. Zero edit misses and zero botched calls, so the tool
surface works fine. On `code-eval-claude`, whose harness structure pushes more
turns, the same model scores 6/6 in 31 turns.

So the weights are not the problem: 1.10% of perplexity separates it from
`fast`, and it passes a client-shaped tier under a harness that makes it
iterate. **What the post-train supplies is the disposition to keep going until
the tests pass**, and without it a competent base model is not an agentic
coder. It also means `code-eval-hard` and `code-eval-claude` disagree by design,
and that disagreement is informative rather than noise.

Secondary: the dropped MTP head costs 27% of generation against `fast`. Its
unspeculated 24.64 t/s sits within 2% of `apexmtp-eval`'s unspeculated 24.17,
so the entire gap to `fast` is the head, not the weights.

## `reap30-eval`: pruning does not buy a `deep` slot

Scored against `deep`, the alias its throughput could plausibly displace, and
it loses on every axis at once: 6/10 with 4 truncations against 8/10 with none,
2929 s against 546 s (49 minutes on ten items), 13.06 tg against 15.55, 6.86
aggregate against 8.23, and the worst perplexity measured on this box, 2.1699,
worse than `balanced` at 61 of 61 chunks. It is text-only where `balanced`
carries vision, and it is the slowest thing ever measured here at two streams.

The unpruned Qwen3.5-122B-A10B was already desk-rejected on published scores
(SWE-bench Verified 72.0-72.4 against Ornith's 75.6). Removing 30% of its
experts does not raise that ceiling.

**Caveat, recorded honestly: Mini is the bottom of the APEX ladder and the
I-Compact tier (38.34 GiB) was NOT tested.** Step 8 says a bottom-tier failure
is a tier result until a higher tier says otherwise, and this failure mode - 4
truncations - is exactly what one tier up repaired on Thinking-Distill. That
test was declined by decision, on the grounds that Compact is larger and would
land near 10 t/s against `deep`'s 15.55, so it can only win on quality while
losing further on speed. The verdict is therefore **rejected at this tier**,
and a reader who wants the model question rather than the tier question still
has that run to do.

## Fallout for the harness

- **`conc-probe` did not exist.** EVAL-PLAYBOOK step 5 has cited
  `python3 conc-probe <alias> 2` since it was written, and README quotes its
  output in the `parallel` 2 -> 3 tables, but it lived only as an inline script
  in a session and was lost. Rewritten as `conc-probe.py`. Every stream gets
  its own moving window of the source file rather than sharing one prompt,
  because the shared-prompt shape is what is suspected of the 2026-08-01
  `coder` stall.
- **`/slots` answers HTTP 400 in router mode.** `probe-server.sh` pipes that
  check through `grep -c`, so the 400 becomes a count of 0 and it reports "not
  busy" unconditionally. **That idle guard has been inoperative for as long as
  this box has run in router mode**, and every run relying on it was unguarded.
  `conc-probe.py` reports the failure instead of trusting it. `probe-server.sh`
  was deliberately left alone rather than changed underneath measurements
  already taken in the same session.
- **`bench-guard.sh` exits non-zero on success.** It ran correctly and reported
  "no throttling, result is trustworthy" every time, but returns 1, so any
  driver checking its exit status records a false failure.
- **`pgrep -f` self-matching cost 20 minutes.** A download queue waiting on
  `pgrep -f EVAL-reap30-mini` matched the `bash -c` wrapper whose own command
  line contained that string, so it waited on itself. A stale process from an
  earlier session was found spinning on the identical bug. Wait on a marker
  file, not on a pattern that can match the waiter.

## Box health

Zero ring timeouts, zero `device wedged`, zero `Fence fallback timer expired`
on the host across roughly seven hours of continuous GPU load, including one
49-minute reasoning run. The `amdgpu.lockup_timeout=10000,60000,10000,10000`
cmdline fix from 2026-08-05 is holding under the heaviest sustained load this
box has taken since it was applied. Clean throughout: no D-state processes, no
stray spare-port servers, GTT back to 0.013 GiB on every stop and to the 20.04
GiB `balanced` baseline at the end.

## Disk

**Deleted 2026-08-15 by user decision, 77.11 GiB (82.8 GB) reclaimed**, and the
three stanzas came out of `router.ini` with them - a tombstone at the end of
that file points back here so nobody re-adds them. Disk went 45% -> 29% used,
337 GB free.

    EVAL-apex-q35-IQuality.gguf         21.25 GiB
    EVAL-apex-q35-mmproj-F16.gguf        0.84 GiB
    EVAL-apexmtp-q36-IBalanced.gguf     24.27 GiB
    EVAL-reap30-mini.gguf               30.76 GiB

All four are re-downloadable through `fetch-model.sh` if a reason ever appears;
for `apexmtp` specifically there is no such reason, since its rejection has now
reproduced twice to within 0.13% on the same failure.

---

# Colibri - a different engine, research 2026-08-15

Not a model and not a llama.cpp fork. `JustVugg/colibri` (Apache-2.0, ~24.7k
stars, pure C, one `.c` per model architecture over shared headers) is a
separate inference engine that **streams MoE experts from NVMe** instead of
requiring the weights to fit in memory. It claims frontier-scale models -
GLM-5.2 744B, Inkling 975B, Kimi K3 2.8T - on consumer hardware.

**The claim is true. It is also not usable here as a backend.** Nothing below
is measured on this box; it is a desk evaluation against four numbers, three of
which were checked on the box and one of which was not.

## Why it matters to this file at all

Because it retires **"exceeds pool"** as a rejection reason, which is the reason
this file has used to desk-reject more models than any other. Every row in the
"Rejected at research time" table that says *exceeds pool* is re-openable for
the four architectures Colibri implements - and re-closable on disk capacity
instead, which is a different and mostly harder gate on this box.

That is the whole value. It is a research finding about the rejection table,
not a deployment path.

## What it does

| mechanism | detail |
|---|---|
| tiering | NVMe / RAM / VRAM are placement tiers for one weight set, not a fit requirement |
| resident | dense only - attention, embeddings, shared experts, MTP head (~9.9 GB int4 for GLM-5.2) |
| streamed | 19,456 routed experts, ~372 GB, per-layer LRU + a **learned pinned hot-store** |
| prefetch | `PILOT` lookahead thread; routing is **71.6% predictable one layer ahead** |
| I/O shape | batched expert unions - one `pread` per unique expert across all batch positions, adjacent matrix storage |
| options | `O_DIRECT` (+34% decode on some drives), dual-SSD striping (two copies = 2x read bandwidth), CUDA / Metal / **Vulkan** tiers (AMD via Mesa/RADV explicitly supported) |
| persistence | `.coli_usage` carries routing statistics across sessions |

Its stated contract is worth repeating because it is the opposite of the usual
consumer-inference claim: *"no SLA on speed, and a hard guarantee on
semantics"* - running short of memory makes it slow, it never silently
re-quantizes or changes router semantics.

## Published throughput, and the shape of the trade

| hardware | GLM-5.2 decode |
|---|---|
| 6x RTX 5090, full expert residency | 5.8-6.8 t/s |
| 128 GB CPU-only, warm cache | ~1.8 t/s |
| single RTX 5070 Ti | 1.07 t/s |
| 25 GB dev box, cold | 0.05-0.1 t/s |

It converts a bandwidth-bound problem into an **I/O-bound** problem. That is a
win only when the disk is close to DRAM. On this box the disk is roughly **25x
slower** than the 59.4 GB/s that sets every generation number in the README.

## Four numbers on this box that decide it

Checked 2026-08-15 on the LXC and on pve2, not estimated - except the last row,
which is a datasheet-and-experience guess and is the one worth measuring.

| | |
|---|---|
| LXC rootfs | 496 GB, **337 GB free** |
| pve2 thin pool | 832 GB total, 480 GB used, **352 GB unallocated** |
| physical disk | **one** Kingston SNV3S1000G, 931.5 GB, DRAM-less Gen4 |
| LXC memory limit | **78 GB, not 96** - 48 GB was page cache at the time of the check |
| DRAM read | 59.4 GB/s CPU-side, ~74 GB/s GPU-side |
| NVMe random read | **unmeasured**, assumed 2-3 GB/s at the expert block size |

The 78 GB figure is the one that is easy to get wrong: `router.ini` arithmetic
in this repo is done against the 76 GiB GPU-addressable pool, but Colibri's
budget is the **container memory limit**, which is a different and smaller
number than the host's 96 GB.

### What fits

| model | Colibri container | fits 337 GB free? |
|---|---|---|
| **DeepSeek-V4-Flash** 284B/13B fp4 | **167 GB** | **yes, comfortably** |
| GLM-5.2 744B/40B int4 | ~372-380 GB | **no** - and growing the LXC disk does not rescue it, the thin pool has only 352 GB unallocated. Needs the remaining models deleted *and* discard actually returning blocks to the pool. Marginal at best |
| Inkling 975B/41B int4 | 469 GB | no, not on a 931.5 GB drive already carrying 480 GB of thin volumes |
| Kimi K3 2.8T MXFP4 | 1.6 TB | no - the rejection reason shrinks from "8x the pool" to "1.7x the disk", and stays a rejection |

### Predicted throughput, DeepSeek-V4-Flash

Roughly 10B of the 13B active is routed expert weight; at fp4 plus scales that
is **~5.6 GB read per token**. 78 GB container minus ~12 GB dense leaves ~60 GB
of cache against ~150 GB of experts - 65-80% hit rate if the hot-store works as
advertised. So **~1.2-2.0 GB/token off NVMe**, at an assumed 2-3 GB/s random
read, giving **~1-2 t/s**. Colibri's own datapoint for this model is "0.6-2+
t/s, storage-dependent," which lands in the same place from the other
direction.

`deep` measures 15.5-19.6 t/s. A 20k-token agentic session at 1.5 t/s is
**3.7 hours of generation alone**, before prefill.

## Three places the tuning INVERTS on this hardware

This is the part that does not transfer from the project's own guidance, and
the reason this section exists rather than a link.

**1. Colibri's three tiers are two tiers on a 780M.** "VRAM" and "RAM" are the
same DDR5-5600. Placing an expert in the VRAM tier reads exactly as many bytes
from exactly the same DRAM - it buys **zero** capacity, and the 16 GiB VRAM
carveout is 16 GiB the expert cache cannot use. For a Colibri run the carveout
should be **shrunk to minimum**, which is the direct opposite of the
`ttm.pages_limit` / carveout tuning the whole README is built on.

**2. CPU-only probably beats the Vulkan tier.** At 1-2 t/s, I/O is >90% of wall
clock, so the 12 CU RDNA3 advantage over 8 Zen 4 cores (74 vs 59.4 GB/s) is
rounding error against a 2-3 GB/s disk - while the GPU tier costs 16 GiB of the
expert cache. Every conclusion in this repo about GPU-vs-CPU is derived from a
bandwidth-bound regime and does not survive the bottleneck moving to storage.

**3. The memory lever is the cgroup limit, not the pool.** Page cache counts
against the container's memory limit, so expert hit rate scales with
`pct set 250 -memory`, not with GTT. Swap must stay at 0 - swapping a streamed
expert would be pathological.

## Levers, ranked by expected effect here

| lever | why |
|---|---|
| **a second NVMe** (`COLI_MODEL_MIRROR` + `COLI_DISK_WEIGHTS`) | two copies = 2x read bandwidth = ~2x t/s in a disk-bound regime. Largest available lever and the cheapest. Check the chassis for a free M.2 slot |
| `PIN_GB=<n>` + `DIRECT=1` | explicit pinned pool plus `O_DIRECT` avoids double-buffering in page cache (+34% reported on some drives). Under a cgroup limit an explicit allocation is far more predictable than page cache subject to reclaim. A/B against the page-cache path |
| `coli tune` | writes a machine-specific profile; the sanctioned starting point before hand-tuning |
| `--topp 0.85` | reads fewer expert bytes per token at no quality cost - a direct win specifically on disk-bound machines |
| `PILOT=1`, `PIPE=1` | on by default; the lookahead prefetch is what overlaps I/O with compute. Do not disable |
| warm `.coli_usage` first | cold and warm runs differ by ~20x, not 20%. The determinism rule recorded for this box applies with far more force here |
| bind-mount a raw partition | LVM-thin adds a metadata indirection on every random read and complicates discard |
| watch NVMe temperature | sustained 100%-duty reads throttle a DRAM-less M.2 in a mini PC. `bench-guard.sh` watches the GPU and does **not** watch this |

**Step 0, before downloading anything:** `fio` random read at Colibri's expert
record size (~1-3 MB), QD 8-32, from inside the LXC. That single number
predicts t/s within a factor. Under ~1.5 GB/s, stop there. This is the storage
analogue of the 50 MB GGUF header range-fetch that caught two of three
candidates on 2026-08-15 - cheap evidence before an expensive download.

## Operational constraints, before anyone tries it

- **Container format, not GGUF.** Nothing in this repo touches it - not
  `fetch-model.sh`, not `router.ini`, not one eval script. Pre-converted
  containers exist on HF (`jlnsrk/GLM-5.2-colibri-int4`,
  `mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp`,
  `nbeerbower/Inkling-colibri-int4`), so the ~750 GB safetensors download and
  the conversion step are avoidable.
- **`coli serve` is OpenAI-compatible only.** No Anthropic `/v1/messages`, and
  tool-calling support is undocumented. Claude Code is the benchmark client for
  this deployment; this does not serve it.
- **Exclusive use.** It cannot co-reside with a resident `llama-server` model in
  a 78 GB container. Stop the service and confirm it drained - the D-state
  teardown deadlock recorded in the README is the failure mode to avoid here.
- **Not a general engine.** One hand-written `.c` per architecture:
  `deepseek_v4.c`, `kimi_k3.c`, `inkling.c`, `olmoe.c`, plus GLM-5.2. Qwen3 MoE,
  Kimi K2 and MiniMax are roadmap only. **No Qwen path exists**, which rules out
  every model family currently deployed on this box.

## Candidates it unlocks, and their standing

**DeepSeek-V4-Flash** - 284B/13B, 167 GB, the only one that physically fits.
Desk-rejected in the table above as *"exceeds pool, smallest quant 82.5 GB
verified"*; that reason is retired, disk is not the gate. Re-post-trained
2026-07-31 with large agentic gains - SWE-bench Verified 79.0 (V4-Pro 80.6),
Terminal-Bench 2.1 61.8 -> 82.7, DSBench-FullStack 37.0 -> 68.7. **All agent
scores are vendor figures from DeepSeek's own unreleased harness with no
independent re-run**, which is exactly the class of claim this file has been
burned by before. 13B active is also the highest active count ever considered
here, and the realized-fraction table puts high active count plus MLA in the
bad band. Est. 1-2 t/s.

**Inkling** - 975B/41B, Apache-2.0, the best candidate on merit and it does not
fit. SWE-bench Verified **77.6**, above `fast` at 75.6. Multimodal (text /
image / audio / video pretrained, MMMU-Pro 73.5), 1M context, controllable
thinking effort, 66 layers, 256 routed + 2 shared experts, 6 routed active.
469 GB rules it out on this drive. This is the model that would justify a 2 TB
NVMe if this road were ever taken.

**GLM-5.2** - 744B/40B, MIT, the flagship Colibri target. SWE-bench Pro
**62.1** (GPT-5.5 58.6), Terminal-Bench 2.1 81.0, FrontierSWE 74.4. This is the
first candidate ever to clear the `deep` slot's stated bar of *a harder
discriminator, not another 10/10* against everything measured here. Carries a
native MTP head that Colibri drives at **2.2-2.8 tokens/forward** - the one
place this repo's MTP experience transfers directly, including the failure
mode: the **MTP head must be int8**, int4 collapses acceptance to 0-4%, which
is the same "quantize the drafter wrong and the whole speculation win
evaporates" result recorded for the Laguna DFlash drafter. Blocked on disk.

**Hy3** (Tencent, 295B/21B) - `UnderstandLing/Hy3-colibri-int4` exists on HF,
which is interesting because the table above rejects Hy3 for exceeding the
pool. But `hy_v3` is **not among the architecture files** in `colibri/c`.
Verify arch support before trusting that repo; a container on HF is not
evidence the engine can load it.

## Verdict

**Do not deploy. Do not download yet.** The defensible experiment, if one is
ever wanted, is DeepSeek-V4-Flash as an **oracle rather than a backend** - 167
GB fits today, and one hard question answered in twenty minutes by a 284B model
is a capability this box does not otherwise have. Gate it on the `fio` number
above; if random read comes back under ~1.5 GB/s the experiment is not worth
the 167 GB.

The finding worth carrying forward is narrower than the engine: **on this box
"exceeds pool" and "exceeds disk" are now different gates, and the second one
is set by a single 931.5 GB drive that is already 57.6% allocated.** Any future
size-based rejection should say which of the two it means.

### Sources

- `github.com/JustVugg/colibri` - README, `docs/quickstart.md`, `c/` tree
- `wavect.io/blog/colibri-glm-5-2-consumer-hardware/` - the critical read
- HF: `jlnsrk/GLM-5.2-colibri-int4`, `mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp`,
  `nbeerbower/Inkling-colibri-int4`, `UnderstandLing/Hy3-colibri-int4`,
  `deepseek-ai/DeepSeek-V4-Flash`
- Inkling architecture/benchmark notes: `sebastianraschka.com/blog/2026/inkling-architecture-benchmark-notes.html`
- GLM-5.2 scores: `emergent.sh/learn/glm-5-2-benchmark`, `morphllm.com/swe-bench-pro`

---

# Phase 0 - Nemotron 3.5 Lightning 30B-A3B and Qwen3-Coder-Next - 2026-08-16

Step 0 of `EVAL-PLAYBOOK.md` for two candidates, both bartowski imatrix repos:

- `bartowski/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF`
- `bartowski/Qwen_Qwen3-Coder-Next-GGUF`

**Nothing was downloaded.** Every number below comes from 20-50 MB range
requests against the GGUF headers, which carry the whole KV block and the full
tensor table. Note that `gguf_dump.py` cannot read a truncated file - it
reshapes tensor *data* and dies with a `ValueError` - so the headers were parsed
with a standalone reader kept at `/root/phase0/ggufhead.py` and
`/root/phase0/ggufbytes.py` on the box. Worth keeping; the playbook's `strings`
recipe answers "is there an MTP head" but not "what does a token cost".

## The two answers

| | **Nemotron 3.5 Lightning 30B-A3B** | **Qwen3-Coder-Next** |
|---|---|---|
| verdict | **do not fetch bartowski's** - will not load | **fetch-eligible** |
| arch | `nemotron_h_moe` | `qwen3next` |
| arch in tree | yes, and inside the box's `build-vk2` lineage | yes, and it held `coder` until 2026-08-03 |
| blocks | 53 = 23 SSM + 6 attn + 23 MoE-FFN + **1 MTP** | 48 = 36 GDN + 12 full attn |
| MoE | 128 experts, top-6, 1 shared (ffn 1856 / shexp 3712) | 512 experts, top-10, 1 shared (ffn 512) |
| native ctx | 1048576 | 262144 |
| tokenizer | `pixtral` pre, 131072 tokens | `qwen2` pre, 151936 tokens |
| MTP head | present in the file, **unusable in this tree** | absent |
| vision | none published, card says "Input support: text" | none published |
| licence | OpenMDW 1.1 (`license: other`) | Apache-2.0 |

## Why bartowski's Nemotron will not load here

The 53rd block is the MTP layer, and this tree does not know that. Read the
per-layer arrays out of the header:

```
layer 51: head_count_kv=0  n_ff=1856   -> MoE-FFN
layer 52: head_count_kv=2  n_ff=1856   -> the only layer with BOTH
```

`nemotron_h_moe` reuses `llama_model_nemotron_h::load_arch_tensors`
(`src/models/nemotron-h.cpp:33`), which classifies each layer by those two
arrays: recurrent if both are zero, attention if `n_ff == 0`, else MoE. Layer 52
has a non-zero `n_ff`, so it takes the **MoE branch** and never creates
`attn_q/k/v/output`. And `load_arch_hparams` never reads
`LLM_KV_NEXTN_PREDICT_LAYERS` at all - only 17 archs do, and this is not one of
them - so `hparams.n_layer_nextn` stays 0 and the four `blk.52.nextn.*` tensors
are never created either.

Eight tensors in the file, nothing claiming them, and
`llama_model_loader::done_getting_tensors` (`src/llama-model-loader.cpp:1315`)
throws `wrong number of tensors; expected 417, got 409` unless called with
`partial`. `qwen35moe.cpp:43` has exactly the `mtp_only` escape hatch that would
be needed; `nemotron-h.cpp` has none. The arch's whole graph file,
`src/models/nemotron-h-moe.cpp`, is six lines - there is no nextn graph to run
even if the tensors loaded.

Two corroborating details: the type table maps `case 52: LLM_TYPE_31B_A3_5B`,
i.e. this tree was written against the 52-block conversion; and bartowski built
these with upstream **b10362**, far newer than this fork's base, with a README
that says plainly "add `--spec-type draft-mtp`". Upstream has the support and
this fork does not.

**Unsloth's tiers are the same shape** - `UD-Q4_K_XL` is also 53 blocks with
`nextn_predict_layers = 1`, so it fails identically, and its per-token budget is
worse (2533 MiB against bartowski's 2234 at Q4_K_M).

### There is a loadable Nemotron, and it is the slow one

`ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` publishes a **52-block
trunk with no MTP layer** (`block_count = 52`, `nextn_predict_layers` absent),
matching what this tree expects, plus the MTP head as a separate sibling file.
That trunk should load. The sibling will not - a lone `blk.52` needs the same
`mtp_only` path nemotron-h lacks - so it would serve unspeculated, and ggml-org
publishes only two tiers, Q4_0 (17.59 GiB) and Q8_0 (31.28 GiB).

## Bytes per token, and what it predicts

Method is the bytes-per-token model: every non-expert weight in full plus
`n_expert_used / n_expert` of the routed experts, `token_embd` excluded as a
gather, at **60.5 GB/s** because both candidates are hybrids. That constant was
fitted on measured hybrids, so the prediction is directly comparable to a
measured *unspeculated* tg, not a ceiling to discount.

| file | size GiB | MiB/token | predicted tg | notes |
|---|---|---|---|---|
| Nemotron bartowski IQ4_XS | 17.62 | 1752 | **32.9** | does not load |
| Nemotron bartowski Q4_K_M | 23.72 | 2234 | 25.8 | does not load |
| Nemotron bartowski Q6_K | 31.94 | 2908 | 19.8 | does not load |
| **Nemotron ggml-org Q4_0** | 17.59 | 2282 | **25.3** | loads, no speculation |
| Nemotron unsloth UD-Q4_K_XL | 23.75 | 2533 | 22.8 | does not load |
| **Qwen3-Coder-Next IQ4_XS** | 39.91 | 2054 | **28.1** | lead tier |
| **Qwen3-Coder-Next Q4_K_M** | 45.38 | 2286 | **25.2** | the step-8 tier up |
| `fast` Ornith Q6_K (control) | 21.89 | 1833 | 31.5 | measures 33.96 with MTP n-max 2 |
| `balanced` TD Q6_K (control) | 27.19 | 1974 | 29.2 | measures 30.66 with MTP n-max 2 |

The two controls are the calibration: both land within ~5% of their measured
served figures, which is what makes the candidate rows worth quoting.

Sanity check against a model that actually ran here: the retired unsloth
Qwen3-Coder-Next UD-Q4_K_XL measured **26.14 tg unspeculated**, which back-solves
to 2205 MiB/token - between bartowski's IQ4_XS and Q4_K_M, exactly where a UD
mix of that size should sit.

### Nemotron's quant ladder is mostly fiction

`ffn_down_exps` has a row length of 1856 and `ffn_up_exps` 2688. Neither is a
multiple of 256, so K- and I-quants cannot be applied to the tensors that are
87% of the file, and `llama-quantize` falls back to legacy types. The evidence
is in the ladder itself - **eight nominal tiers from IQ2_XXS to Q4_0 all land
between 17.54 and 17.78 GiB**, a 1.4% spread - and in the type histogram of the
Q5_K_M file, where only 18 of 417 tensors are actually K-quants against 83 Q8_0,
63 Q5_1 and 9 Q4_0.

Consequences if the loader question is ever solved: the floor is ~17.6 GiB and
1752 MiB/token no matter what is asked for, everything below IQ4_XS is wasted
download, and **step 8 has almost no room to run** - the tier ladder this box
uses to repair marginal failures barely exists for this model.

### Nemotron's KV is remarkably cheap, for whatever that is worth

Only 6 of the 52 trunk layers are attention, at `head_count_kv = 2` and
`key_length = 128`, so q8_0 KV costs ~0.80 GiB at 262144 and ~3.2 GiB at the
full 1048576. The other 46 layers are Mamba2 recurrent or MoE-FFN, and recurrent
state is per-slot and constant. A 1M-context alias is arithmetically affordable
here for the first time. It is the generation speed that is not.

## Qwen3-Coder-Next - the parts that are actually new

This is the same base that held `coder` from 2026-07-31 to 2026-08-03, at
unsloth's UD-Q4_K_XL. What differs is the quanter (bartowski imatrix, calibrated
on 818 chunks) and the tier ladder, which reaches down to IQ4_XS at 39.91 GiB -
**5.5 GiB lighter than Q4_K_M and 6.4 GiB lighter than the UD file that served
here** - and IQ4_XS is the type this box has repeatedly measured as both smaller
and faster than Q5_K on Vulkan.

Pool fit at ctx 262144, `models-max 1`: 12 full-attention layers at
`n_embd_k_gqa = 512` cost ~3.2 GiB of q8_0 KV, recurrent state for 36 GDN layers
across 3 slots is ~0.25 GiB, so IQ4_XS lands near 45 GiB resident and Q4_K_M near
51 GiB. Both fit the 76 GiB pool with room; `deep` at 44.22 GiB is the precedent.
Note the previous `coder` never ran at 262144 - the ctx bump landed 2026-08-04,
the day after this model lost the alias - so that is unverified, not inherited.

**Speculation.** No `nextn` tensors anywhere in the table, and `qwen3next` has no
nextn code path in this tree either, so "no MTP head" is consistent from both
sides - still confirm it positively at step 3 with `SPEC_TYPE=draft-mtp` and a
non-zero n-max, per the playbook. Three notes on drafters:

- `z-lab/Qwen3-Coder-Next-DFlash` - what `coder` ran, GGUF mirrors at
  `transmutator/...-DFlash-GGUF` and `AtomicChat/...-DFlash-GGUF`
- `thoughtworks/Qwen3-Coder-Next-Eagle3` with a GGUF at
  `jdluzen/Qwen3-Coder-Next-Eagle3-GGUF` - **never tested on this box**, and
  `draft-eagle3` is in this tree's spec-type map
- fetch either one quantized, never at BF16 - a BF16 drafter eats the whole
  speculation win

## Cross-model perplexity is unavailable for both candidates

`fast` and `balanced` share a tokenizer - `qwen35` pre, 248320 tokens, identical
SHA over the token list - which is why their paired-chunk comparisons are legal.
Both candidates differ: Qwen3-Coder-Next is `qwen2` pre at 151936, Nemotron is
`pixtral` pre at 131072. Step 7 can therefore only be run **within** a candidate,
tier against tier. Neither can be pitted against an incumbent on perplexity at
all, which raises the weight on `reason-eval-hard` - and after 2026-08-15 that is
no loss.

## Verdict

**Nemotron 3.5 Lightning: do not fetch.** Not rejected on merit - it has never
been measured. It is blocked, and the block is in this repo, not in the model.
Three ways forward, none of them free:

1. Port `nemotron_h_moe` nextn support from upstream b10362 - read
   `LLM_KV_NEXTN_PREDICT_LAYERS`, exclude the MTP layers from the trunk loop, add
   the `mtp_only` sibling path and the nextn graph. That is a new pattern in an
   arch file, so `AGENTS.md` says ask before writing it.
2. Serve ggml-org's 52-block Q4_0 trunk unspeculated at ~25 t/s. That is below
   `fast` (33.96) and `balanced` (30.66) on the only axis this model was
   shortlisted for, so it needs a capability argument to be worth 17.6 GiB.
3. Wait for the fork to sync upstream, which settles it for free.

**Qwen3-Coder-Next: fetch-eligible, IQ4_XS first.** It clears every paper gate -
arch proven on this box, MoE, fits the pool, permissive licence, a real drafter
available. What it does not clear is the reason it lost the alias in the first
place: at ~28 t/s predicted it is slower than both incumbents, and the last time
this box measured it, it was 26.14 against `fast`'s 33.96. Fetch it if the
question is "can a purpose-built 80B coder beat a 35B generalist at agentic
coding", which `reason-eval-hard` and `code-eval-claude` can answer. Do not fetch
it expecting speed.

## One correction to the record

The tombstone added to `router.ini` on 2026-08-16 describes the removed
`coder-eval` as "Qwen3-Coder-Next 80B-A3B UD-Q4_K_XL (19.06 GiB) + its Q8_0
mmproj (0.57 GiB)". The size, the mmproj and the alias history all belong to
`nerkyor/Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-GGUF`, which is what that
stanza's own header block says it was. Qwen3-Coder-Next is a different model that
held `coder` earlier and is listed correctly under "Retired" at the top of the
same file. Only the name in the tombstone is wrong.

## What was verified vs. inferred

**Verified from the GGUF headers**: every architecture number in the tables,
per-layer type arrays, tensor names and types, tokenizer identity and token-list
SHA, file sizes from the HF tree API, and the byte budgets.

**Verified from this tree**: that `nemotron_h_moe` and `qwen3next` are both in
`llama-arch.cpp` and both inside `8eef5068f`'s ancestry, so the box's serving
binary has them; that `nemotron-h.cpp` reads no nextn key and creates no nextn
tensors; that `done_getting_tensors` throws on an under-count; that
`draft-eagle3` and `draft-dflash` are in the spec-type map.

**Inferred, not verified**: that the load actually fails with that message - the
reasoning is a code read, not a failed load, because confirming it costs a 17.6
GiB download. That ggml-org's 52-block trunk loads and runs correctly. Every
predicted tg figure. That neither model has a published mmproj anywhere beyond
the repos checked.

### Sources

- HF API `models/`, `models/*/tree/main?recursive=true`, `commits/main` for both
  repos plus `ggml-org/`, `unsloth/` and the drafter repos
- Range-fetched headers: bartowski Q4_K_M / Q5_K_M / Q6_K / IQ4_XS and
  `mtp-...-Q8_0`, ggml-org Q4_0, unsloth UD-Q4_K_XL, bartowski Qwen3-Coder-Next
  Q4_K_M / IQ4_XS
- `src/models/nemotron-h.cpp`, `src/models/nemotron-h-moe.cpp`,
  `src/models/qwen35moe.cpp`, `src/llama-model.cpp`, `src/llama-model-loader.cpp`,
  `common/speculative.cpp`

---

# qcn-eval deployed, and both drafters work - 2026-08-16

Steps 1 and 2 of the playbook for the candidate phase 0 cleared, plus a drafter
load test that is not a step-3 sweep. No sweep was run; draft length is still
untuned.

## What is on the box

| file | size | sha256 |
|---|---|---|
| `EVAL-Qwen3-Coder-Next-IQ4_XS.gguf` | 39.91 GiB | VERIFIED against the HF API |
| `EVAL-QCN-DFlash-q8_0.gguf` | 486 MiB | VERIFIED |
| `EVAL-QCN-Eagle3-Q8_0.gguf` | 153 MiB | VERIFIED |

Three stanzas in `router.ini`, all `load-on-startup = false`, all pointing at the
same 39.91 GiB weights: `qcn-eval` unspeculated, `qcn-dflash-eval` and
`qcn-eagle3-eval` differing only in the speculation block.

Resident at ctx 262144: **16.3 GiB VRAM + 29.6 GiB GTT = 45.6 GiB**, against
`deep`'s 44.22, inside the 76 GiB pool. Cold load 29 s, warm swap ~11 s. The
262144 context is new ground for this model - the previous `coder` never ran
past 131072, because the ctx bump landed 2026-08-04, the day after it lost the
alias - and it loads without complaint.

## The byte model over-predicted, by 21%

`probe-server.sh qcn-eval 3`, through the production router:

| | measured | predicted from 2054 MiB/token at 60.5 GB/s |
|---|---|---|
| pp, 1 stream | 231.1 t/s (229.6-231.2) | - |
| tg, 1 stream | **22.06 t/s** (21.99-22.07) | 28.1 t/s |

The three samples span 0.4%, so the measurement is solid and the prediction is
what is wrong. This is the first time the bytes-per-token model has missed by
more than a few percent on this box, and the shape of the miss points at a known
caveat rather than a new one: **bytes saved only turn into speed if the dequant
kernel keeps up.** Every case where the model hit its number - Laguna IQ4_XS at
+16.8% predicted +17.4% - retargeted tensors that are **read in full every
token**. Here IQ4_XS sits on the **routed experts**, which go through Vulkan's
`MUL_MAT_ID` path, a different kernel with a different per-byte cost.

Working conclusion, to be tested rather than believed: the byte model is
calibrated for full-read tensors and unproven for expert tensors. The clean way
to settle it is Q4_K_M of this same model measured beside this file - 2286
MiB/token against 2054, so the byte model says Q4_K_M should be 11% SLOWER, and
if it comes back faster the expert-dequant explanation is confirmed and the
whole IQ4_XS-everywhere heuristic needs narrowing.

**Do not compare 22.06 against the retired unsloth UD-Q4_K_XL's 26.14.** That
figure was taken at `parallel = 2` on an older build. This repo has already been
burned by exactly that: `fast`'s code-eval-hard went 163 s to 255 s across the
`parallel` 2 -> 3 change with no model change at all. A legal comparison needs
both files measured in one session.

## Both drafters load and draft, and they are not close

One 160-token code completion each, same prompt, through the router, against
`qcn-eval` unspeculated on the identical prompt:

| drafter | tg | acceptance | mean draft len | verdict |
|---|---|---|---|---|
| none | 22.29 t/s | - | - | baseline |
| **DFlash q8_0** | **36.56 t/s** | **0.984** (126/128) | 4.0 | works, sweep it |
| Eagle3 Q8_0 | 23.06 t/s | 0.724 (118/163) | ~3 | works, buys ~3% |

The prompt is short deterministic boilerplate, which is why DFlash accepts 98%.
**These are not workload numbers** - they answer "does it engage", nothing more.
What they do establish is the shape of the decision: at the same n-max 4, the
acceptance gap is everything. 0.72 barely pays for a 5-token verify batch on a
512-expert top-10 MoE, which is precisely the cost structure that made DFlash
worthless on Laguna at acceptance 0.55. The likely reason for the gap is size -
DFlash is a 0.5B block-diffusion drafter, the Eagle3 head is 145M.

Both load cleanly. DFlash reports `block_size=16, mask_token_id=151669,
n_extract=5`. Eagle3 emits `special_eos_id is not in special_eog_ids - the
tokenizer config may be incorrect`, which nothing else on this box emits, and
its own `context_length` is 4096 - two things to resolve before spending a sweep
on it.

## What is still owed

Everything from step 3 on. Draft length is unswept and `spec-draft-n-max = 4` is
a probe value inherited from July - every alias here that speculates peaked at
2, and three vendors have now shipped a wrong n-max for this hardware. No eval
tier has been run, so there is no capability claim of any kind about this model
at this tier yet, and no same-session control against `fast` or `balanced`.

---

# Qwen3-Coder-Next at IQ4_XS: swept, evaluated, rejected - 2026-08-17

The full playbook against `qcn-eval`, steps 3 through 5, in one session. Step 3
answered the drafter question the 2026-08-16 probes left open and then answered a
larger one nobody asked: **speculation on this model wedges slots.** Step 5 then
lost both coding tiers to `balanced`.

Verdict: **reject.** Not for the reason it was fetched to test - it is a
competent reasoner - but because it is slower than the incumbent on every
throughput axis and needs three times the turns to do the same agentic work.

## Step 3 - the sweep, and DFlash beats Eagle3 without winning anything

`spec-sweep.sh` on port 8081, `PROMPT_FILE=/root/llama.cpp/src/llama-context.cpp`,
`PARALLEL=3`, `GGML_VK_MUL_MAT_VEC_ID_MAX_COLS=12`, `NPREDICT=300`, ctx 32768.
Aggregate is the honest metric; per-stream tg is shown because it is what
flatters speculation.

**One stream:**

| config | tg | pp | acceptance | aggregate | vs none |
|---|---|---|---|---|---|
| none | 22.39 | 222.8 | - | 12.54 | - |
| dflash n1 | 21.46 | 236.6 | 1.000 (596/596) | 12.51 | -0.2% |
| dflash n2 | **HANG** 959 s | | | | |
| dflash n3 | 24.37 | 230.1 | 0.805 (844/1049) | 13.17 | +5.0% |
| dflash n4 | **HANG** 935 s | | | | |
| dflash n3 p0.3 | **HANG** 932 s | | | | |
| dflash n3 p0.5 | **HANG** 958 s | | | | |
| **dflash n3 p0.75** | **26.68** | 218.0 | **0.987** (667/676) | **13.48** | **+5.7%** |
| eagle3 n1 | 18.20 | 231.6 | 1.000 (596/596) | 11.27 | -10.1% |
| eagle3 n2 | **HANG** 999 s | | | | |
| eagle3 n3 | 16.29 | 212.7 | 0.574 (755/1316) | 10.01 | -20.2% |
| eagle3 n4 | **HANG** 947 s | | | | |

**Two streams - the concurrency this box is tuned for:**

| config | per-stream tg | pp | acceptance | aggregate | vs none |
|---|---|---|---|---|---|
| **none** | 14.06 | 113.5 | - | **14.18** | - |
| dflash n1 | 12.36 | 110.0 | 1.000 (596/596) | 12.70 | -10.4% |
| dflash n2 | 11.90 | 110.3 | 0.889 (764/859) | 12.74 | -10.2% |
| dflash n2 p0.3 | 11.43 | 108.9 | 0.913 (738/808) | 12.28 | -13.4% |
| dflash n2 p0.5 | 12.62 | 107.3 | 0.975 (655/672) | 12.73 | -10.2% |
| dflash n3 | 12.05 | 112.1 | 0.765 (831/1086) | 12.14 | -14.4% |
| dflash n4 | **HANG** 966 s | | | | |
| eagle3 n1 | 9.74 | 110.6 | 1.000 (596/596) | 11.22 | -20.9% |
| eagle3 n2 | 7.84 | 103.3 | 0.669 (683/1021) | 9.30 | -34.4% |
| eagle3 n3 | 7.14 | 106.6 | 0.483 (706/1461) | 9.05 | -36.2% |

Eagle3 n4 at two streams was not run: the head had already lost by 20-36% at
every completed setting and the cell was odds-on to spend 15 minutes hanging.

**Noise floor, three cells repeated:**

| cell | run 1 | run 2 | delta |
|---|---|---|---|
| conc2 none, aggregate | 14.18 | 14.04 | -1.0% |
| conc1 dflash n3, aggregate | 13.17 | 13.18 | +0.1% |
| conc1 none, aggregate | 12.54 | 12.95 | +3.3% |

1-3%, matching the recorded floor. Note that `conc1 dflash n3` came back
**bit-identical on acceptance** - 844/1049 twice, tg 24.37 against 24.38 - while
the unspeculated baseline moved 3.3% on prefill. So the +5.0% read off run 1 is
really about +3.4% against the two-run baseline mean, and only p-min 0.75 puts
DFlash clearly outside the floor at one stream.

**The drafter question is settled: DFlash, by a wide margin, and it does not
matter.** At the same n-max 3 it accepts 0.805 against Eagle3's 0.574, and the
gap widens with draft length (0.987 against 0.483 at the extremes). Eagle3 is a
net loss at every single setting measured, at both concurrencies - it never once
beat not speculating. That is consistent with the 2026-08-16 size argument: a
145M head against a 0.5B block-diffusion drafter.

But DFlash's own case does not survive the two-stream column. Its best
configuration there is 12.74 against 14.11 unspeculated (mean of the two
baseline runs), and **p-min cannot rescue it** - pushing acceptance to 0.975
still lands at 12.73, because p-min buys acceptance by declining to draft, which
converges on the unspeculated case minus the drafter's overhead. Against +5.7%
at one stream, the trade is the mirror image of `fast`'s and it points the other
way. **Ship nothing**, which is how `qcn-eval` was already configured.

## Speculation wedges slots on this model, and it is not the harness

Seven of the 21 speculated cells hung. Every one has the same signature:

- the first prompt of the cell always completes normally, at full speed and good
  acceptance - the hung `n3 p0.3` cell did 300 tokens at 29.68 t/s, acceptance
  0.923, mean draft len 3.71, before it died;
- the **second** prompt wedges mid-generation, at `n_decoded` between 149 and
  232 of 300;
- the GPU sits at 90% busy with no token emitted for the full 15 minutes to the
  client timeout, and `/slots` shows `is_processing: true` with `n_decoded`
  frozen - polled three times over 90 s, it does not advance by one;
- `journalctl -k` is **clean** - no `ring comp_X timeout`, no `device wedged`, no
  fence-fallback line, across the whole session. This is not the amdgpu
  compute-ring watchdog that 2026-08-05 diagnosed;
- it always recovers once the client gives up. The server reaps, GTT returns, no
  D-state process, no power cycle.

It happens on both drafters, at n-max 2, 3 and 4, at both concurrencies, and at
p-min 0, 0.3 and 0.5. It never happened in the nine unspeculated cells.

**It is not an artifact of `ignore_eos`.** The obvious objection is that
`spec-sweep.sh` forces 300 tokens with `ignore_eos: true`, which can drive
degenerate repetition the drafter then rides. So the same five prompts were sent
through the **production router** as ordinary chat requests - EOS allowed,
`max_tokens 600`, no forced length - once against `qcn-dflash-eval` at its n-max
4, once against `qcn-eval`:

| request | `qcn-dflash-eval` | `qcn-eval` (no spec) |
|---|---|---|
| 1 - explain 9 KB of source | 600 tok, 76.8 s | 600 tok, 50.7 s |
| 2 - rolling-median class | 600 tok, 24.8 s | 600 tok, 27.3 s |
| 3 - review 8 KB of source | 600 tok, 47.7 s | 600 tok, 34.9 s |
| 4 - Rust semver parser | **WEDGE, 300 s timeout** | 600 tok, 27.1 s |
| 5 - summarise control flow | 208 tok, 44.5 s | 236 tok, 21.2 s |

Request 4 carries no source file at all - it is a plain "write a Rust semver
range parser" prompt - and it wedged with the drafter on and finished in 27 s
with it off. **The wedge follows speculation into ordinary traffic.**

What this does NOT establish: whether the bug is in `common/speculative.cpp`, in
the `dflash`/`eagle3` implementations, or in the Vulkan `MUL_MAT_ID` path they
drive; and whether it reaches other models. `fast` and `balanced` both speculate
via MTP and neither has ever shown this. The distinguishing feature of these two
is an **external drafter model**, which nothing else here currently runs. That is
the hypothesis to test if the question is ever worth reopening; the alias itself
does not need it answered, because the throughput case for speculation here was
already zero.

## Steps 4 and 5 - through the router, same session, against `balanced`

Sweep first, then tiers - step 3 gates step 5, and the sweep said no
speculation, so `qcn-eval` was measured as configured. `balanced` re-measured in
the same session as the control.

| | **`qcn-eval`** (QCN IQ4_XS) | **`balanced`** (TD Q6_K) |
|---|---|---|
| resident | 45.6 GiB | 27.2 GiB |
| speculation | none (swept, rejected) | MTP n-max 2 |
| pp, 1 stream | 243.2 (241.8-243.4) | **273.3** (270.6-273.8) |
| tg, 1 stream | 22.29 (22.29-22.32) | **30.75** (30.75-30.78) |
| per-stream tg, 2 streams | 14.09 | **17.75** |
| aggregate, 2 streams | 13.49 | **15.24** |
| draft acceptance, 2 streams | n/a | 0.861 |
| **reason-eval-hard** | 9/10, 0 trunc, **41 s**, **0c** | **10/10**, 0 trunc, 206 s, 20.5k |
| **code-eval-hard** | 5/6, 238 s, **67 turns** | **6/6**, 195 s, **31 turns** |
| **code-eval-claude** | 5/6, 240 s, **108 turns** | **6/6**, **113 s**, **33 turns** |
| tool discipline | 0 rbe, 0 line-num, 0 edit miss, 0 botch | same, all zero |

`qcn-eval`'s 1-stream numbers reproduce 2026-08-16 closely (231.1/22.06 then,
243.2/22.29 now), so the box has not drifted and the comparison is clean.

**The reasoning tier is where it looks good, and the reason is that it does not
think.** 9 of 10 correct with **zero chars of reasoning**, most items answered in
1.0-1.2 s, the whole tier in 41 s against `balanced`'s 206. Its single miss,
`house-order`, is the one item where it did spend time - 30.3 s - and it landed
on the anti-pattern. That is a real and useful property: on this box, hard
reasoning has always cost 200-990 s of thinking, and this is the first model to
get 9/10 without a thinking channel at all. If the workload were single-shot
questions, that would be an argument.

**The coding tiers are where it loses, and they are the tiers that matter.**
`code-eval-hard` saturates - six previous models all scored 6/6 - and this is
the second candidate ever to break that, by **stalling out on `dup-block` after
32 turns and 81 s**. On `code-eval-claude`, the tier that matches the real
client, it needs **108 turns against `balanced`'s 33**, and `dup-line` failed by
exhausting the 40-turn limit. It is not blundering: read-before-edit, line-number
discipline, edit misses and botched calls are all zero, better than KAT ever
managed. It grinds - 10, 13, 13, 14 and 18 turns on tasks `balanced` closes in
4, 4, 4, 6 and 11.

**And it does not end episodes the way the harness expects.** Three of the six
tasks - `blind-fix`, `numbered`, `stale-edit` - stopped with `no-tool-call`,
i.e. the model finished the work correctly (all three PASS) and then replied in
prose instead of calling `Submit`. `balanced` printed no stop line at all, which
means all six of its episodes ended on `submitted`. `no-tool-call` is the
episode's terminal state, not a wasted mid-episode turn - an earlier draft of
this section said the latter and it was wrong. What it indicates is a
tool-protocol mismatch rather than a capability failure: this is a Qwen coder
model with a native XML tool-call convention being driven over the `anthropic`
transport. That is a competing explanation for part of the turn count and it was
NOT tested here.

Session latency is turns x per-turn time, and this candidate is worse on both
factors at once: 3.3x the turns at 0.72x the generation speed.

## Is this the quant tier? Step 8 was NOT run - here is what is known

Asked directly after the session, and it deserves a recorded answer rather than
a shrug. **Step 8 is the one step of the playbook this session skipped**, so the
honest answer is that it is untested. What the evidence does and does not
support:

**Against the quantization explanation.** The one effect a higher tier has
produced consistently across four models is repairing **marginal tool-discipline
failures** - TD's multi-image comparison, KAT's read-before-edit violation and
edit miss. This candidate's tool discipline was already perfect: zero
read-before-edit, zero line-number errors, zero edit misses, zero botched calls,
across both coding tiers. There is nothing marginal in the place where this
lever has ever worked. `coder` is the precedent: 0.76% of perplexity, solid at
61/61, and it changed nothing at all because nothing was marginal.

**For it, and it is not nothing.** The failures are non-termination-shaped -
`dup-block` stalling after 32 turns, `dup-line` exhausting the 40-turn limit -
and step 8's central lesson is precisely that a marginal task consumes what the
quantization left and tips into non-termination. That is TD's signature.

**Unquantifiable here, unusually.** The normal check is how far the tier sits
from the model's own BF16 - under ~0.3% and the tier is not a lever, ~0.8% and
it is doing real damage. That number does not exist for this model and cannot be
borrowed: the tokenizer is qwen2/151936 against the incumbents' qwen35/248320,
so no cross-model perplexity pairing exists. Within-model tier pairing IS clean,
but it requires the second tier to exist on disk.

**The throughput half of the verdict might genuinely be the tier, in the
direction nobody expects.** IQ4_XS measured 22.29 t/s against 28.1 predicted -
the byte model's worst miss on this box - and the standing hypothesis is that
IQ4_XS is slow per byte specifically on ROUTED EXPERTS through `MUL_MAT_ID`.
If that is right, **Q4_K_M could come back FASTER despite carrying 11% more
bytes per token** (2286 MiB against 2054). So "test the tier up" is not the
usual trade of speed for quality here; it is a live question in both directions,
and it settles a box-wide quant heuristic either way.

**What it would have to achieve to change the verdict.** Close a 3.3x turn gap
and a 27% generation deficit against `balanced`. No tier bump on record here has
moved any metric by 3x. And the `no-tool-call` finding above offers a competing
explanation for a chunk of the turn count that a higher tier would not obviously
fix.

**One thing quantization definitely does not explain: the wedge.** Both arms of
that comparison ran the same IQ4_XS weights - speculation on hung, speculation
off did not - so it is the speculation path, not the tier.

## Where this leaves the model, and the open questions it does not close

**Reject `qcn-eval`.** Rejected on measurement, at this tier, against today's
lineup, in one session with the control re-measured - which is a stronger
rejection than the 2026-08-03 one it inherited.

Kept, because deleting them is the user's call and the two drafters together are
639 MiB: the three stanzas and all three files. The `qcn-dflash-eval` and
`qcn-eagle3-eval` stanzas are marked DO NOT SHIP in `router.ini` - they wedge
slots, and a stanza that looks tuned is exactly how a future session ships one.

Still open, and none of it is blocked on this rejection:

- **The Q4_K_M tier question from 2026-08-16 is untouched.** The byte model
  predicted 28.1 t/s and this file measures 22.3, and the proposed test - Q4_K_M
  of the same model, which the byte model says should be 11% slower - would
  settle whether IQ4_XS on routed experts is the cause. That is a claim about
  **this box's quant heuristic**, not about this model, so it survives the
  rejection intact and is still worth a fetch.
- **Whether the wedge reaches other external-drafter setups**, per above.
- Perplexity was not run. It could not have decided anything - the tokenizer is
  qwen2/151936 against the incumbents' qwen35/248320, so no cross-model pairing
  exists, and step 7 never promotes anything anyway.
- No vision tier: no mmproj is published for this model.
- No soak: soaks are for candidates taking a production alias.

## What was verified vs. inferred

**Measured this session**: every number in every table above, all through
`spec-sweep.sh` on 8081 or the production router on 8080, on one build with one
`router.ini`, with the incumbent re-measured as the control and three sweep cells
repeated for the noise floor.

**Verified by observation**: the wedge signature - frozen `n_decoded` polled
three times over 90 s, GPU at 90%, clean `journalctl -k` for the whole session,
clean recovery on client timeout. And that it reproduces on ordinary router
traffic with EOS enabled.

**Inferred, not verified**: that the external drafter is what distinguishes the
wedging configurations from `fast` and `balanced`'s MTP - that is a hypothesis
from what the two hanging setups have in common, not a code read or a bisect. No
attempt was made to locate the bug in the source.

**Not attempted**: Eagle3 n4 at two streams, perplexity, vision, soak, depth.
