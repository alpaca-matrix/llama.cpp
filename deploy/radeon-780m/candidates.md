# Model candidates

Researched 2026-08-01. Candidates 1 and 2 were measured on this box the same
day and **both were rejected**; their numbers and the reasons are in "Measured
and rejected" below. Step-3.5-Flash is the only entry still untested.

Read `README.md` first. Everything in "Tested and rejected" there is out of
scope and must not be re-proposed.

## Read the throughput estimates with a correction factor

Every estimate below starts as a bandwidth ceiling:

```
tg_ceiling = 74 GB/s / (active_params x bytes_per_param)
```

That ceiling is never reached. Checked against the five models now measured on
this hardware:

| model | active | bytes/param | ceiling | measured base tg | ratio |
|---|---|---|---|---|---|
| `fast` (Ornith-1.0-35B-A3B, 21.9 GiB) | 3B | 0.672 | 36.7 | ~22 | 0.60 |
| `deep` (gpt-oss-120b, MXFP4) | 5.1B | 0.542 | 26.8 | 19.6 | 0.73 |
| `coder` (Qwen3-Coder-Next 80B-A3B, 46 GiB) | 3B | 0.617 | 40.0 | 18 | 0.45 |
| Ornith-Agents-A1-3.6 (20.5 GiB, rejected) | 3B | 0.630 | 39.1 | 28.66 | 0.73 |
| MiniMax-M2.1 IQ1_S (43.8 GiB, rejected) | 10B | 0.205 | 36.0 | 19.37 | 0.54 |

So the realistic band is **0.45 to 0.75 of the ceiling**, and the position
within that band tracks routing overhead: `coder` has 512 experts and a hybrid
attention stack and lands at the bottom, `deep` has 128 and lands at the top.
A high expert count pushes a candidate toward 0.45.

**The method works, and it did not help.** Both tested candidates landed inside
their predicted bands - Ornith-3.6 was estimated 20-34 base and measured 28.66,
MiniMax was estimated 16-27 and measured 19.37. Neither was rejected on
throughput. Both were rejected on things this formula cannot see. Budget the
testing time accordingly: the estimate tells you whether a candidate is worth
downloading, never whether it is worth deploying.

### The formula says nothing about depth, and depth is where MiniMax died

`tg_ceiling` describes generation at zero context. It does not model how KV
reads scale as the context fills, and that scaling varies enormously by
attention layout:

| model | full-attention layers | tg d0 -> d32768 |
|---|---|---|
| `fast` | 41 of 41 | 25.3 -> 20.9 (-17%) |
| `coder` | 12 of 48 (hybrid GDN) | 18.5 -> 15.7 (-15%) |
| MiniMax-M2.1 | **62 of 62** | 19.37 -> **6.75 (-65%)** |

Before estimating any candidate for a long-context slot, read `attn_type_list`
(or the equivalent) out of `config.json` and count the full-attention layers.
A model that is all full attention over many layers pays KV bandwidth on every
one of them, and a respectable d0 figure tells you nothing about how it serves
a 32k agent prefix. Fitting in the pool is a separate and easier question - see
MiniMax below, which fit comfortably and was still unusable.

## Priority order

| # | model | replaces | est. real tg | why it is ranked here |
|---|---|---|---|---|
| 3 | Step-3.5-Flash | `coder` | 11-18 with MTP | last untested entry; best benchmarks, worst fit |

Candidates 1 (Ornith-Agents-A1-3.6) and 2 (MiniMax-M2.1) have been measured and
rejected. Step-3.5-Flash keeps its original ranking and its original caveat:
it is expected to land at or below the throughput of the slot it would replace,
and its 69.2 GiB leaves too little room for the 131072 context this lineup runs.
The KV arithmetic below is now a hard gate on it rather than a suggestion.

---

## Measured and rejected

### 1. Ornith-Agents-A1-3.6-35B-A3B - rejected 2026-08-01

DARE-TIES merge on Qwen3.6-35B-A3B, tested as a replacement for `fast`.
Files kept at `/root/models/ornith36-agents-a1-*`.

**It won every throughput comparison.** `llama-bench`, both models measured in
the same session, Vulkan backend confirmed on every run:

| metric | incumbent `fast` | Ornith-3.6 | delta |
|---|---|---|---|
| pp512 | 333.60 +/- 1.28 | 361.21 +/- 1.47 | +8.3% |
| tg128 | 25.36 +/- 0.01 | 28.66 +/- 0.02 | +13.0% |
| pp512 @d32768 | 166.12 +/- 1.84 | 170.80 +/- 1.77 | +2.8% |
| tg64 @d32768 | 20.85 +/- 0.11 | 23.08 +/- 0.15 | +10.7% |

Served with MTP (`probe-server.sh`, 3 samples): 344.2 pp / 36.03 tg at
acceptance 0.823-0.855, against the incumbent's 309.0 / 34.60 at 0.815-0.826.

Discount part of that. The incumbent is a Q6_K/Q5_K/IQ4_XS mix at 21.9 GiB and
the candidate is Q4_K_M at 20.5 GiB, so it reads about 6% fewer bytes per token
before any architectural merit is counted.

**It was rejected on reasoning.** `reason-eval.sh`, same 8 problems, same
session, temperature 0, 8000 max_tokens:

| | score | wall time | reasoning emitted |
|---|---|---|---|
| incumbent `fast` | **8/8** | 186 s | 19,592 chars |
| Ornith-3.6 | **6/8** | 570 s | 70,493 chars |

It failed `deadlock` and `list-mutation` by exhausting the full token budget
without ever concluding - roughly 30,000 characters of reasoning each, ending
in `finish_reason: length`. The incumbent answers both in 93 s combined. Tool
calling and vision both passed, so the merge damage landed on reasoning
termination rather than output formatting.

Runaway reasoning in an agent loop costs far more than 4% served generation
buys. The risk flagged at research time - an unbenchmarked DARE-TIES merge
degrading behaviour that throughput cannot detect - was real, it simply
manifested as non-termination instead of malformed tool calls.

**Check whether an MTP sidecar is actually a model before wiring it.** The repo
ships `mtp-sidecar.gguf` alongside the weights, which looks like it needs
`spec-draft-model`. It does not, and it cannot be used that way: the sidecar
holds 20 tensors with no `token_embd.weight`, so `llama_model_load_from_file`
rejects it outright. The **main** GGUF already contains the complete block-40
MTP layer, byte-identical types - the sidecar is a redundant duplicate. Correct
wiring was identical to the incumbent: `spec-type = draft-mtp` and no
draft-model line, which takes the built-in hybrid path (`creating MTP draft
context against the target model`) and speculates correctly.

This is a third failure shape, distinct from the two in `README.md`: not the
`probe-server.sh` stall and not DeviceLost-on-load, but a packaging mismatch
that costs a debugging session if assumed rather than checked. Inspect the
sidecar's tensor list first. If the main file already carries the nextn block,
ignore the sidecar entirely.

### 2. MiniMax-M2.1 IQ1_S - rejected 2026-08-01

229B total / 10B active, arch `minimax-m2` (`LLM_ARCH_MINIMAX_M2`, confirmed at
`src/llama-arch.cpp:129`; the 2.1 point release does report `model_type:
minimax_m2`). Tested as a replacement for `coder`, and potentially `deep` as
well. File kept at `/root/models/minimax-m21-iq1s.gguf`.

**It fit, which was the only prediction that held.** Loaded cleanly at
`ctx-size 131072`: GTT 46.05 GiB + VRAM 15.58 GiB = 61.63 GiB of the 76 GiB
pool, 14.4 GiB spare, ~31.5 s to load.

**Rejected twice over, on independent grounds.**

First, it is slower than both incumbents before depth is considered, and then
it collapses:

| | `coder` | `deep` | MiniMax-M2.1 |
|---|---|---|---|
| pp served | 235 | 242 | 105.3 |
| tg served | 25 | 19.6 | 16.73 |
| pp512 (`llama-bench`) | 228.91 | - | 80.42 +/- 0.45 |
| tg128 @d0 | 18.58 | - | 19.37 +/- 0.02 |
| tg128 @d32768 | 15.74 | - | **6.75 +/- 0.00** |

62 of 62 layers are full attention, so there is no equivalent of `coder`'s GDN
discount and KV bandwidth scales with depth across every layer. A 65% drop by
32k makes it unusable well inside its own context window, on a slot whose whole
purpose is long agent prefixes. No speculation is available to offset it -
z-lab publishes DFlash drafters for M2.5 and M2.7 but not for 2.1.

Second, reasoning does not converge at 1.64 bits/weight. Two of two attempted
`reason-eval.sh` questions - including the trivial bat-and-ball - consumed the
entire 8000-token budget without producing an answer, roughly 8.5 minutes of
GPU each. The run was stopped at 2 of 8 once the pattern reproduced, so this is
a labelled partial: **0/2 attempted, 6/8 not run**.

**What did not fail is worth recording.** The predicted 1-bit failure mode was
subtly malformed tool calls and broken diffs. That did not happen. Coherence
passed, tool calling passed (`get_weather({"city":"Manila"})`), and a realistic
`edit_file` request produced valid JSON with an exactly-matching `old_str` and a
correct fix. When this model finishes, its structured output is fine. The
problem is that it frequently does not finish.

**There is no better quant to retreat to.** IQ1_S is the only one that fits:
IQ2_S is 59.0 GiB, which plus ~16.5 GiB of q8_0 KV at 131072 exceeds the pool.
Note also that `IQ1_M` at "49.0 GiB" in the original research was GB, not GiB -
the real figure is 45.7 GiB, and it does not change the conclusion.

---

## 3. Step-3.5-Flash - replaces `coder` (untested)

- Arch `step35`, confirmed in `src/llama-arch.cpp`. 196B total, 11B active, 288
  routed experts (top-8) plus 1 shared, native MTP-3 head.
- Repo `AesSedai/Step-3.5-Flash-GGUF`, `IQ2_S` 69.2 GiB - a MoE-aware quant
  holding attention and router tensors higher while squeezing FFN experts.
  `bartowski/stepfun-ai_Step-3.5-Flash-GGUF` also exists; check it for an
  equivalent-size imatrix quant before committing to the less-established one.
- 0.353 bytes/param (2.82 bits/weight, much less extreme than MiniMax). Ceiling
  19 t/s. With 288 experts the ratio should sit near the bottom of the band, so
  ~9-14 base, and MTP-3 at the +30% that MoE verify cost realistically allows
  here gives **11-18 t/s**.
- SWE-bench Verified 74.4, SWE-bench Multilingual 67.4 (arXiv 2602.10604) -
  beats `coder` on both axes, and its MTP is native where `coder` needs an
  external DFlash drafter.

**Risk:** two, and together they are close to disqualifying. Throughput lands at
or below the 25 t/s incumbent it would replace. And 69.2 GiB against a 76 GiB
ceiling leaves roughly 6.8 GiB for KV and overhead, which will not support the
131072 context the current lineup runs - a hard problem for an agent workload
that lives on long prefixes.

**Before downloading 69 GiB:** count the full-attention layers and compute the
q8_0 KV footprint at 131072. MiniMax cost ~132 KiB/token at 62 full-attention
layers; Step-3.5-Flash has more layers still, and only 6.8 GiB to spend. If the
arithmetic forces context below ~32k, stop there and do not download it. This
gate is now backed by measurement rather than caution: MiniMax passed the
easier version of this test (it fit) and still failed in service.

---

## Rejected at research time, with reasons

| model | reason |
|---|---|
| Hy3 (Tencent, `hy_v3`, 295B/21B) | Exceeds pool. Smallest confirmed GGUF 143.9 GB; next tier 116.7 GB. Vendor's own "1-bit" target is a 128 GB device. |
| DeepSeek-V4-Flash (`deepseek4`, 284B/13B) | Exceeds pool. Smallest quant (unsloth `UD-IQ1_S`) 82.5 GB, verified via HF tree API. Strong agentic scores, no quant fits. |
| GLM-4.7 full (355B) | Exceeds pool. 2-bit dynamic GGUF 134-135 GB. |
| GLM-4.7-Flash | Already tested and rejected on this box: MTP tensors declared but missing, `failed to create MTP context`. |
| Kimi K3 (2.8T) | No `kimi_k3` arch in llama.cpp, and ~594 GB native. Fails both filters. |
| GLM-4.5-Air (106B/12B) | Fits, but SWE-bench Verified 57.6 is below every current slot. |
| Ling-2.6-flash | Hybrid `BailingMoeV2.5` linear-attention arch needs a vendor fork. |
| Ling-flash-2.0 (`bailingmoe2`, 100B/6.1B) | Arch supported but no agentic benchmark evidence found; superseded. |
| Ling-3.0-flash (124B/5.1B) | Weights not released, API-only. Revisit when GGUF ships. |
| Qwen3.6-35B-A3B base | Loses to `fast`: SWE-bench 73.4 vs 75.6, Terminal-Bench 2.0 51.5 vs 64.2. |
| Laguna-XS.2 (Poolside, 33B/3B) | Loses to `coder`: SWE-bench 68.2 vs 70.6, no speculation edge. Arch IS supported - an lmstudio bug report claiming otherwise is stale, `LLM_ARCH_LAGUNA` is in this tree. |
| Trinity-Large-Preview (398B/13B) | ~119 GB at 2.4 bits/weight, exceeds pool. Only general benchmarks published, no agentic evidence. |
| ERNIE-4.5-21B-A3B | Too small to beat any current slot, no fresh evidence. |
| Seed-OSS, dots.llm2 | No successor shipped; only Seed-OSS 36B exists and it is dense. |

## Why there is no new-slot candidate

The brief asked for three models justifying a new slot. There are none, and the
reason is structural rather than a gap in the search.

Every model found with a genuinely different capability profile turned out to
have the same shape as an existing slot, making it a replacement rather than an
addition. Nothing vision-capable beat `assist` or `fast` on any axis. No
long-context specialist meaningfully exceeded the current 131072 window
(MiniMax-M2.1's native ~204,800 is not a large enough jump to earn a slot).

This is the more useful answer anyway. With `models-max = 1` a new slot buys no
concurrency - it costs disk plus a 14-31 s swap - while `coder` and `deep` are
already arguably redundant against `fast`. The lineup's problem is that it has
too many slots, not too few.

## What the two rejections say about the shortlist as a whole

Both tested candidates were quality failures that throughput testing would have
scored as wins, and both failed the same way: they did not stop generating.
Ornith-3.6 exhausted its budget on 2 of 8 reasoning problems, MiniMax on 2 of 2.
The incumbents do not do this.

Two consequences for the next candidate:

- **Run `reason-eval.sh` before any throughput tuning.** It costs one pass and
  it is what rejected both. A `spec-draft-n-max` sweep on a model that cannot
  terminate is wasted time; the sweep planned for Ornith-3.6 was skipped for
  exactly this reason.
- **Treat non-termination as the expected failure of an aggressively quantized
  or merged model**, ahead of gibberish or malformed tool calls. Neither
  rejected model produced either of those. Both produced well-formed output
  that never arrived at an answer, which is invisible to a coherence check and
  to every timing metric.
