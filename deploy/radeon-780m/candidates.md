# Model candidates

Researched 2026-08-02, sweeping specifically for the `deep` slot. Read
`README.md` first — everything in its "Tested and rejected" section is out of
scope and must not be re-proposed unless something material changed (noted
inline where checked).

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
| 1 | Qwen3.5-122B-A10B | `qwen35moe` | 122B/10B | UD-IQ4_XS, 57.7 GiB, 4.06 bpw | 256 (top-8) | 12 of 48 (GDN hybrid, interval 4) | native MTP, confirmed in-tree | **8.5-11.6 t/s w/ MTP** (6.6-8.0 base) | interesting, not yet worth downloading blind |
| 2 | Nemotron 3 Super 120B-A12B | `nemotron_h_moe` | 120B/12B | UD-Q2_K_XL, 50.9 GiB, 3.64 bpw | unclear (Latent MoE, count unpublished) | few (mostly Mamba-2, small number of attn blocks) | native MTP claimed | **~7-12 t/s w/ MTP**, wide error bars | insufficient evidence — watch |
| — | Ling-3.0-flash | (unknown, unreleased) | 124B/5.1B | no GGUF | ? | ? | ? | ? | not released — API only, watch for GGUF |
| — | MiniMax-M2.7 | `minimax-m2` | 229B/10B | UD-Q3-class, ~55-60 GiB | 256 (top-8) | **62 of 62** | DFlash now published | n/a | reject — same 62/62 depth collapse as M2.1, unchanged |
| — | Laguna S 2.1 | `laguna` | 118B/8B | smallest ~49 GiB (4-bit) | ? | ? | official DFlash | n/a | reject — wrong slot (coding-agent, not reasoning) and too tight against pool |
| — | GLM-4.7-Flash | `glm4moe` | 30B-A3B | — | — | — | declared, unconfirmed fixed | n/a | already tested/rejected on this box (`failed to create MTP context`); no material fix found |
| — | Kimi K3 | `kimi-linear` | 2.8T/104B | 1-bit GGUF still 594 GB | 896 (top-16) | ? | native | n/a | reject — exceeds pool by ~8x even at 1-bit; note arch **is now supported** (`LLM_ARCH_KIMI_LINEAR` in this tree), correcting the earlier "no arch" rejection reason — size is now the sole blocker |
| — | gpt-oss-120b (incumbent) | `gpt-oss` | 117B/5.1B | MXFP4, ~60 GiB, 0.542 B/param | 128 (top-4) | 36 of 36 (small KV per layer) | none | 19.6 t/s served | holds |

---

## 1. Qwen3.5-122B-A10B — the one candidate worth a closer look

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

## 2. Nemotron 3 Super 120B-A12B — insufficient evidence, not a real candidate yet

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

## 3. Ling-3.0-flash — still not released

124B total / 5.1B active — notably the same active-param count as gpt-oss.
Ant Group's 2026-07-27 announcement offers a free API through 2026-08-03 (one
day from today) with weights promised to open-source afterward. As of
2026-08-02 there are still no Hugging Face weights, no GitHub repo, no GGUF,
and no license statement — identical status to the 2026-08-01 rejection.
Revisit in the next few days; if the active-param match holds and weights land
in a supportable quant, this is worth a fast look given the near-identical
bandwidth profile to the incumbent.

---

## Rejected at research time, with reasons

| model | reason |
|---|---|
| MiniMax-M2.7 | Same `minimax-m2` arch, config confirms **62 of 62 layers still full attention**, unchanged from M2.1. DFlash drafters are now published for this point release, but the depth-collapse problem that actually killed M2.1 (65% tg drop by d32768) is architectural, not a speculation gap, and is unchanged. Not re-measured. |
| Laguna S 2.1 | Wrong slot — SWE-bench/Terminal-Bench-tuned coding model, no GPQA/ARC-AGI evidence found. Smallest GGUF quants (INT4 ~72 GB, 4-bit GGUF ~75 GB) leave under 4 GiB of the 76 GiB pool once any KV is added — fails the practical-ceiling gate even before the slot mismatch. |
| GLM-4.7-Flash | Already tested and rejected on this box (`failed to create MTP context`, declared-but-missing nextn tensors). Searched for a fix; found only an unrelated Jan-2026 scoring-function bug fix, no confirmation the MTP tensor gap was addressed. Not re-tested. |
| Kimi K3 | Correction to the prior entry: arch **is now supported** in this tree (`LLM_ARCH_KIMI_LINEAR`, confirmed in `src/llama-arch.cpp`), so the earlier "no kimi_k3 arch" rejection reason is stale. Still fails on size alone — even the 1-bit Unsloth dynamic GGUF is ~594 GB, ~8x the pool. |
| Step-3.5-Flash (`step35`, 196B/11B) | Carried forward from the 2026-08-01 shortlist unresolved, where it was ranked for `coder`, not `deep`. Still untested. Its blocking gate is unchanged: IQ2_S is 69.2 GiB against a 76 GiB pool, leaving ~6.8 GiB for KV at 131072, and its estimated 11-18 t/s lands at or below the slot it would replace. Not re-evaluated in this deep-focused sweep — arch `LLM_ARCH_STEP35` is present in this tree. |
| Ling-3.0-flash | Weights not released — see above, unchanged from 2026-08-01 modulo an imminent open-source date. |
| Nemotron 3 Super | See section 2 — not rejected outright, but insufficient independently-verified evidence to shortlist; gated config, uncorroborated benchmark. |
| Hy3 (Tencent, `hy_v3`, 295B/21B) | Exceeds pool. Unchanged from 2026-08-01. |
| DeepSeek-V4-Flash (`deepseek4`, 284B/13B) | Exceeds pool, smallest quant 82.5 GB verified. Unchanged. |
| GLM-4.7 full (355B) | Exceeds pool. Unchanged. |
| GLM-4.5-Air (106B/12B) | Fits, SWE-bench Verified 57.6 below every current slot. Unchanged. |
| Ling-2.6-flash | Hybrid `BailingMoeV2.5` arch needs a vendor fork. Unchanged. |
| Ling-flash-2.0 (`bailingmoe2`, 100B/6.1B) | Arch supported, superseded, no fresh agentic evidence. Unchanged. |
| Qwen3.6-35B-A3B base | Loses to `fast` on SWE-bench and Terminal-Bench 2.0. Unchanged; also the base of the already-rejected Ornith-3.6 merge. |
| Trinity-Large-Preview (398B/13B) | ~119 GB, exceeds pool. Unchanged. |
| ERNIE-4.5-21B-A3B, ERNIE-5.0 | Too small (4.5) / no weights found (5.0). |
| Seed-OSS, dots.llm2 | No successor shipped since 2026-08-01. |

---

## Measured and rejected (the only two candidates ever tested on this box)

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
