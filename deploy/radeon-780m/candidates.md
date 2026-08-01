# Model candidates

Researched 2026-08-01. Nothing here has been measured on this box. This is a
queue of things worth testing, ordered by expected value per hour of testing,
not by model quality.

Read `README.md` first. Everything in "Tested and rejected" there is out of
scope and must not be re-proposed.

## Read the throughput estimates with a correction factor

Every estimate below starts as a bandwidth ceiling:

```
tg_ceiling = 74 GB/s / (active_params x bytes_per_param)
```

That ceiling is never reached. Checked against the three models actually
measured on this hardware:

| model | active | bytes/param | ceiling | measured base tg | ratio |
|---|---|---|---|---|---|
| `fast` (Ornith-1.0-35B-A3B, 21.9 GiB) | 3B | 0.672 | 36.7 | ~22 | 0.60 |
| `deep` (gpt-oss-120b, MXFP4) | 5.1B | 0.542 | 26.8 | 19.6 | 0.73 |
| `coder` (Qwen3-Coder-Next 80B-A3B, 46 GiB) | 3B | 0.617 | 40.0 | 18 | 0.45 |

So the realistic band is **0.45 to 0.75 of the ceiling**, and the position
within that band tracks routing overhead: `coder` has 512 experts and a hybrid
attention stack and lands at the bottom, `deep` has 128 and lands at the top.
A high expert count pushes a candidate toward 0.45.

Apply this before getting excited about any number below. A candidate whose
ceiling is 36 t/s is a 16-27 t/s model in practice, which is `coder` territory,
not a breakthrough.

## Priority order

| # | model | replaces | est. real tg | why it is ranked here |
|---|---|---|---|---|
| 1 | Ornith-Agents-A1-3.6-35B-A3B | `fast` | 20-34 base, higher with MTP | cheapest test that could move the slot that matters most |
| 2 | MiniMax-M2.1 | `coder`, maybe `deep` | 16-27 | only candidate that could retire two slots; severe quant risk |
| 3 | Step-3.5-Flash | `coder` | 11-18 with MTP | best benchmarks, worst fit; likely slower than the incumbent |

This ordering differs from the researcher's, which put MiniMax first and Ornith
last. The reason is the correction factor above plus test cost: Ornith-3.6 is a
20.5 GiB download that swaps into an existing alias with no config change, so
it can be accepted or rejected in one session, while the other two are 47 and
69 GiB downloads whose realistic throughput lands at or below what they replace.

---

## 1. Ornith-Agents-A1-3.6-35B-A3B - replaces `fast`

DARE-TIES merge on top of Qwen3.6-35B-A3B, the generation after the Qwen3.5
base that the current Ornith-1.0 is built on.

- Arch `qwen35moe`, mainline, with hybrid-MTP handling already in
  `src/llama-model.cpp` (~lines 2147-2242). Same arch as the incumbent, so this
  is a file swap, not a config exercise.
- Repo `tepirale/Ornith-Agents-A1-3.6-35B-A3B-MTP-GGUF`. `Q4_K_M` 20.5 GiB
  (`Q6_K` 27.4 GiB also available). Ships `mmproj-F32.gguf` for vision and a
  real MTP sidecar grafted post-quantization (Q8_0 weights / BF16 router / F32
  norms).
- 35B total, 3B active. Ceiling 45 t/s at Q4_K_M density; at `fast`'s measured
  0.60 ratio that is ~27 t/s base, and MTP speculation has been worth +35-45%
  here, so mid-30s to low-40s is the plausible landing zone against `fast`'s
  current 34.6.
- Speculation: genuine MTP tensor set, not the declared-but-missing kind that
  killed GLM-4.7-Flash. Start at `spec-draft-n-max = 3`, which is the measured
  peak for the incumbent.

**Risk:** no published benchmarks at all. The model card says so outright - no
SWE-bench, no Terminal-Bench, no tool-calling numbers. DARE-TIES merges
frequently degrade the instruction-following and tool-call formatting that an
agentic client depends on, and throughput cannot detect that.

**Why it is still first:** the risk is entirely quality, and quality is exactly
what `check-vision-tools.sh` and `reason-eval.sh` answer in a single pass on an
already-configured alias. Cheapest possible disconfirmation of the highest-value
slot. If it fails, it fails in an hour and costs 20 GiB.

## 2. MiniMax-M2.1 - replaces `coder`, possibly `deep` as well

- Arch `minimax-m2`, present as `LLM_ARCH_MINIMAX_M2` in `src/llama-arch.cpp`.
  Confirm `config.json` `model_type` on the 2.1 point release before
  downloading; point releases usually keep the parent arch string but this is
  unverified.
- Repo `bartowski/MiniMaxAI_MiniMax-M2.1-GGUF`, file
  `MiniMaxAI_MiniMax-M2.1-IQ1_S.gguf`, 47,009,105,696 bytes confirmed via the HF
  tree API. `IQ1_M` at 49.0 GiB gives a small safety margin.
- 229B total, 10B active, 0.205 bytes/param (1.64 bits/weight). Ceiling 36 t/s;
  expert count is unknown, so the realistic band is the full 16-27 t/s.
- `IQ1_S`/`IQ1_M` have real Vulkan kernels in this tree (`dequant_funcs.glsl`,
  `mul_mat_vecq.comp`, `mul_mm.comp`). This is not the Ternary-Bonsai situation.
- SWE-bench Verified 74.0 (self-reported, 4-run average, mixed scaffolds), above
  `coder`'s 70.6 and below `fast`'s 75.6.
- Speculation: none confirmed. z-lab publishes DFlash drafters for M2.5 and M2.7
  but not M2.1. Assume no draft path; the estimate above already does.

**Risk, and it is the whole question:** 1.64 bits/weight is far more aggressive
than anything currently deployed, and 229B is small for a model expected to
survive 1-bit-class quantization gracefully - the models that do this well are
usually 500B+. The published 74.0 was certainly not measured on this quant. The
specific failure to expect is not gibberish but subtly broken tool calls and
malformed diffs, which throughput testing cannot see.

**Payoff if it holds:** it is the only candidate that could plausibly collapse
`coder` and `deep` into one slot, which is worth more than a throughput win.

## 3. Step-3.5-Flash - replaces `coder`

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

**Before downloading 69 GiB:** compute the q8_0 KV footprint at a realistic
context and confirm it fits. If it forces context below ~32k, stop there.

---

## Rejected, with reasons

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
