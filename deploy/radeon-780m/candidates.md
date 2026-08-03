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
