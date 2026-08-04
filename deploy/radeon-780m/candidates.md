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
| `nerkyor/Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-GGUF` (Q4, 19.06 GiB) | `coder` | 2026-08-03 | **deployed** | beats Coder-Next on every axis, ties `fast` on saturating evals; see "Hard-tier results" below | on disk (`nerkyor-dsv4pro-q4.gguf`) |
| `nerkyor/Qwen3.6-35B-A3B-APEX-MTP-GGUF` ("I-Balanced", 24.27 GiB) | `fast` (MTP comparison) | 2026-08-04 | **rejected** | class-leading throughput once retuned to n-max=3 (35.6 t/s served, beats `fast`) but hard-reasoning 6/10 with 4 truncations — same non-termination failure that sank Ornith-3.6 and MiniMax-M2.1 | deleted 2026-08-04 |
| `nerkyor/Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill` (Q4_K_M, 20.22 GiB + mmproj) | `fast` | 2026-08-04 | **recommended — swap `fast`** | beats `fast` on base+served throughput (tuned n-max=4: ~39-41 t/s vs 34.6), wins hard-reasoning decisively (10/10 zero-trunc vs 8-9/10), vision+tools confirmed, no depth collapse to d65536, smaller than `fast`. Not yet wired into `router.ini` — awaiting user go-ahead | on disk (`nerkyor-thinking-distill-q4.gguf` + `-mmproj-F16.gguf`) |
| `nerkyor/Qwen3.6-27B-DSV4Pro-GLM52-SFT-GPT55-RL-Coding-GGUF` (Q4-LynnStyle, dense) | `coder` | 2026-08-04 | **rejected** | confirmed dense (`qwen35`, zero expert tensors) — 4.1 t/s base, 8.5 t/s even with its own MTP draft sidecar; reproduces this repo's established dense-model rejection a third time | deleted 2026-08-04 |

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

**Proposed `router.ini` change, not yet applied:**
```
model             = /root/models/nerkyor-thinking-distill-q4.gguf
mmproj            = /root/models/nerkyor-thinking-distill-mmproj-F16.gguf
spec-type         = draft-mtp
spec-draft-n-max  = 4
; spec-draft-p-min left at default — no benefit found, unlike fast's 0.3
ctx-size          = 131072
```

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
| 1 | `fast` (already deployed) | `qwen35moe` family | 35B/3B | Ornith-1.0-35B MTP-APEX, 21.9 GiB | 256 (top-8) | 41 of 41 | in-model MTP, wired | pp 343.8 -> 111.3, tg 25.3 -> 17.9 (**measured**) | **re-route here first — no download** |
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
