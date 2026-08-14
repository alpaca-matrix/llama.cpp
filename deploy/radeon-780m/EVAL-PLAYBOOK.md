# Evaluating a candidate model on this box

How to decide whether a model should take an alias here, and in what order to
find out. Every rule below exists because skipping it produced a wrong answer at
least once - the citation after each one is the incident, not a footnote.

Read `README.md` for the hardware and serving config, and `candidates.md` for
what has already been tested and rejected. This file is the method.

---

## The short version

```
0. vet on paper          arch, pool fit, tokenizer, MTP head, vision, licence
1. fetch                 fetch-model.sh (SHA256 - the CDN returns damaged files)
2. eval stanza           new [alias] in router.ini, never touch a production one
3. tune the drafter      spec-sweep, REAL prompts, 1 and 2 streams, per model
4. confirm on 8080       the spare port does not reproduce production
5. head-to-head          same session, same conditions, vs the incumbent
6. depth                 only if the alias will actually run deep
7. paired perplexity     per-chunk ordering, not the final estimate
8. quant tier            before concluding anything about the MODEL
9. soak                  before it takes a production alias, on the tier you ship
```

Steps 3-8 are cheap and can kill a candidate. Step 9 is expensive and only
matters for one that survived.

**Step 3 gates step 5.** Do not run an eval tier until the sweep has settled the
draft length, including on models believed to have no drafter - the sweep at
n-max 0 is also how you get the 1- and 2-stream throughput baseline, and this
repo's own capability claims have been wrong.

---

## 0. Vet on paper first

Costs nothing and rejects most candidates.

| check | how | reject if |
|---|---|---|
| arch supported | `grep LLM_ARCH src/llama-arch.cpp` | not in this tree |
| pool fit | file size + KV at target ctx vs 76 GiB | over, at `models-max 1` |
| dense or MoE | expert tensors in `gguf_dump.py --no-tensors` | **dense** - four rejections here, ~4-8 t/s |
| tokenizer | `tokenizer.ggml.model` + token count | differs from the incumbent, if you want cross-model perplexity |
| MTP head | `blk.N` beyond `block_count - 1` | absent means no speculation, ~30% off tg |
| vision | mmproj published? | absent, if the target alias serves screenshots |
| full-attention layers | `full_attention_interval` in upstream config.json | all layers full-attn - see MiniMax-M2.1, -65% by d32768 |

**Throughput estimate.** `tg_ceiling = bandwidth / (active_params x bytes_per_param)`,
using **60.5 GB/s for a GDN hybrid** and 70 GB/s otherwise. Realised fraction
lands 0.45-0.75. This sets a ceiling, never a forecast: TD's Q6 tier was
predicted at -25.7% against Q4 from the weight ratio and measured -14.1%,
because KV and activations do not scale with the tier.

---

## 1. Fetch

```sh
./fetch-model.sh <repo> <remote-file> [out-file]
```

Always. HF's Xet CDN returns files of the correct length with damaged bytes; a
damaged GGUF loads, reports correct tensor shapes, benchmarks at full speed and
emits gibberish. `fetch-model.sh` verifies SHA256 against the API.

Some repos serve presigned URLs scoped to a byte range, so aria2's parallel
connections get a 403. It retries down to one connection and recovers - a 403 in
the log is not a failed download. Check for the `VERIFIED` line and compare the
size against the API before believing either outcome.

---

## 2. Give it an eval stanza, never a production alias

Copy the incumbent's stanza, change the model path, set
`load-on-startup = false`. Name it `<thing>-eval`. Config changes go through the
repo - edit, commit, push, `git pull --ff-only` on the box, `cp` into
`/etc/llama/`, restart. Never `sed` the live file.

**Restart only when idle, and wait for `model loaded` + `listening` in the
journal before sending any request.** A request during the load window makes the
router kill a child mid-GPU-allocation, and the teardown deadlocks in
uninterruptible D state holding the whole pool. That needed a hard power cycle
on 2026-08-07.

---

## 3. Tune the drafter, per model, on real prompts

> **This step GATES step 5. Never run the eval tiers before the sweep.** Every
> tier result is read against throughput - wall time, turns per second, whether
> a thinking model finishes inside its budget - so a candidate scored at the
> wrong draft length is being judged on a config it would never ship with. TD's
> recorded n-max 4 was 19% down on aggregate against no speculation at all; any
> eval taken at that setting was measuring the mistake, not the model.

> **Run the sweep even when the model "has no drafter", and verify that claim
> from the GGUF rather than inheriting it.** At worst it costs one pass at
> n-max 0 and hands you the 1- and 2-stream baseline you need anyway. At best it
> catches a wrong assumption: `coder` was documented here as text-only for
> eleven days and its GGUF repo ships an mmproj the whole time, so "no MTP head"
> from the same source deserves the same scepticism. Check for a block beyond
> `block_count - 1` in `gguf_dump.py --no-tensors`, and check the repo listing
> for an mmproj, before believing any capability claim in this repo's own docs.

Vendor defaults and other models' values do not transfer. Three vendors have
now shipped a wrong `n-max` for this hardware, and the same model at a different
quant does not necessarily want the same value.

```sh
PROMPT_FILE=/root/llama.cpp/src/llama-context.cpp \
GGML_VK_MUL_MAT_VEC_ID_MAX_COLS=12 PARALLEL=3 CONC=<1|2> \
SPEC_TYPE=draft-mtp ./spec-sweep.sh <model.gguf> <n_max> '' <p_min>
```

Sweep `n_max` in 0,1,2,3,4 at **both** CONC=1 and CONC=2, then `p_min` at the
winning `n_max`.

- **`PROMPT_FILE` is mandatory.** The built-in prompts return acceptance 0.61
  where a real source file returns 0.85, and they called `n-max 1` a 21% winner
  when it is not.
- **Sweep at the concurrency you serve.** This box is tuned for two clients.
  n-max 3 was the single-stream peak for `fast` and cost 8.8% at two streams;
  TD's recorded n-max 4 was, at two streams, **worse than not speculating at
  all**.
- **Aggregate is the honest metric, not per-stream tg.** Speculation taxes
  prefill to subsidise generation - MTP's catch-up decode runs over every
  prefill ubatch - so per-stream tg flatters it on any workload with real
  prefill. On one config the two cancelled exactly: n-max 0 and n-max 1 both
  landed at 62.3 s wall.
- **Repeat one cell** to establish the noise floor before believing a delta.
  Here it is 1-2%; a 24% "win" was once read out of a run whose own quoted range
  was 20% wide.
- **MoE draft lengths stay short.** Each verified token routes to its own
  experts, so verify cost grows with draft length. Every alias here peaks at
  n-max 2.

**Column limit.** The Vulkan matvec path applies only up to
`GGML_VK_MUL_MAT_VEC_ID_MAX_COLS` (12 in the unit) columns, and the batch is
`n_active_slots x (1 + n_max)`. At `parallel = 3`, n-max 2 is 9 columns and
fits; n-max 4 is 15 and does not. Re-derive this whenever either changes -
measured worth +9.4% aggregate at three streams.

---

## 4. Confirm on 8080 before believing anything

The spare port runs ctx 32768 without `cache-ram` and **does not reproduce
production**. It called an n-max change a tie where the router showed -4.6%. It
also, in the other direction, made a model look fine at a task the router showed
it failing.

Sweep on 8081, deploy the winner to the eval stanza, re-measure on 8080.

---

## 5. Head-to-head, same session, same conditions

This is the rule that governs everything else.

> **Temperature 0 is not a determinism guarantee.** Slot count and cache state
> change the batch geometry, which changes `MUL_MAT_ID` shapes, which changes
> floating-point reduction order, which flips near-tied tokens. `fast` produced
> byte-identical runs three times in a clean loop and truncated on the same
> request when it ran third in a script.

Consequences:

- Compare candidate against incumbent **measured in the same session**.
- **Never** cite a historical number taken under a different `parallel`, ctx or
  build. `fast`'s code-eval-hard went 163 s -> 255 s across the `parallel` 2->3
  change with no model change at all.
- Re-measure the incumbent every time. It is cheap and it is the control.

Run, through the router:

```sh
./probe-server.sh <alias> 3          # 1-stream pp/tg
python3 conc-probe <alias> 2         # 2-stream per-stream + aggregate
./reason-eval-hard.sh <alias>        # THE discriminator once easy tiers saturate
./code-eval-hard.sh <alias>          # regression check + effort tiebreak
./code-eval-claude.sh <alias>        # the client you actually run
./check-vision-agentic.sh <alias>    # only if the alias serves images
```

**What each tier is worth.** `code-eval.sh` and `code-eval-hard.sh` saturate -
everything scores 4/4 and 6/6 - so they catch regressions and rank effort, not
quality. `reason-eval-hard.sh` is the discriminator: it separates 8/10 from
10/10 and exposes non-termination. `code-eval-claude.sh` is the one that matches
your client, and it disagrees with the others - KAT is the best model on
`code-eval-hard` (20 turns) and the worst on `code-eval-claude` (45 turns, and
the only model to violate read-before-edit).

**Read turns, reasoning volume and truncations, not just the score.** Session
latency is turns x per-turn time. A model that scores 8/10 in 103 s and 7.4k
chars is more useful than one scoring 8/10 in 987 s and 93.6k chars with two
truncations.

**Non-termination is disqualifying.** Burning the budget without concluding has
rejected four candidates here. Report it as TRUNC, never as FAIL - and give
thinking models room, because a budget that is too small produces empty content
that reads exactly like missing capability. 1200 tokens scored a working model
as broken; 4000 is the floor for anything with a thinking channel.

---

## 6. Depth, if the alias will run deep

Grow one context with `cache_prompt: true` so each step prefills only the delta,
and read cumulative depth, not `prompt_n` (which is the delta).

Facts established 2026-08-14, to 234k tokens on two models:

- **GTT does not grow with depth.** KV is preallocated at `ctx-size` on load, so
  the load-time footprint is the worst case and a long conversation cannot creep
  the pool.
- **tg at depth tracks draft acceptance, which is content-dependent, not
  depth-dependent.** It wandered 0.72-0.95 with no trend. Single-point tg
  comparisons at depth are noise; compare the whole curve or retention.
- Prefill at depth is a property of the attention shape - two models with the
  same GDN-hybrid layout matched to three significant figures at every depth.

---

## 7. Paired perplexity - the final estimate proves nothing

```sh
llama-perplexity --model <m> -f /root/ppl-holdout-ornith.txt \
  -c 512 --chunks 80 --n-gpu-layers 99 --flash-attn on --threads 8
```

The differences that matter here are smaller than the error bars, so the final
estimate alone cannot establish a sign. **Keep the full output** and count
paired per-chunk ordering over chunks 20-80:

| result | reading |
|---|---|
| lower at 61 of 61, no flips | solid |
| lower at ~51 of 61, ordering reverses | **a wash** - do not claim a winner |

That distinction reversed a conclusion on 2026-08-14: TD-Q6 "beating" Ornith was
51 of 61 with flips, i.e. nothing, while TD-Q4 losing to Ornith was 61 of 61.

**Perplexity is bit-reproducible here** (unlike generation), so an incumbent's
run can be reused across sessions rather than repeated. Verify by re-running it
once - it should match to four decimals.

**Cross-model requires an identical tokenizer**; check `tokenizer.ggml.model`
and the token count. And note the corpus is public source, so contamination is
possible and unquantified - within-model tier comparisons are clean, cross-model
ordering is suggestive.

---

## 8. Test the quant tier before blaming the model

**The most expensive lesson of 2026-08-14.** A candidate failed multi-image
comparison, produced 28-32k chars without concluding, and twice claimed it could
only see one image. That reads as a perception failure. It was not: at one tier
up the same model answered in 188 byte-identical tokens.

**Quantization sets the margin, not the outcome.** A marginal task consumes what
the quantization left, and tips into non-termination. Q4 was costing that model
0.82% perplexity - 3.2x the *entire* headroom `fast` has from its own BF16.

So: before concluding anything about a model's capability, check whether one
tier up fixes it. And when comparing tiers, **measure both under identical
conditions** - comparing a new tier's standalone numbers against the old tier's
router numbers is not a comparison.

Rule of thumb: if a model is within ~0.3% of its own BF16, quantization is not a
lever (that was `fast`, and requantizing it failed). If it is ~0.8% away, the
tier is doing real damage and is worth testing.

---

## 9. Soak, before a production alias only

Standalone evals passed a model that then fell over under real agentic traffic
in 2026-08-04. What the suite cannot see: sustained real-client traffic shape at
depth over tens of minutes.

Requirements: longer than 30 minutes, crossing >67k and >100k accumulated
tokens, on the **tier you intend to ship** - a soak of a tier you are not
deploying proves nothing. Watch `journalctl -u llama-server` in the LXC **and
`journalctl -k` on the host** (192.168.254.222).

**Use `journalctl -k`, never `dmesg`.** The ring buffer wraps, and one `dmesg`
reading that showed "zero prior timeouts" is what made a platform-wide amdgpu
fault look model-specific, cost a model its alias twice, and got its weights
deleted.

Distinguish the signatures:

| line | meaning |
|---|---|
| `ring comp_X timeout` + `ring reset` + `device wedged` | the real hang. Depth-triggered. Watchdog fix is `amdgpu.lockup_timeout=10000,60000,10000,10000` |
| `Fence fallback timer expired` | benign. Late or lost fence interrupt, caught by the fallback poll. No reset, no failed request |

---

## Operational safety

- **Kill the client before the server.** Stopping llama-server with requests in
  flight strands a child in uninterruptible D state holding GTT and VRAM; SIGKILL
  cannot reap it and only a hard power cycle clears it. Stop the client, wait for
  `/slots` to show zero processing, then stop the server.
- **Check the backend column says Vulkan**, not CPU. Silent CPU fallback costs
  6x and looks like a bad model.
- **After any run**: no stray spare-port servers, no D-state processes, GTT back
  to the production baseline, repo and `/etc/llama` identical, production alias
  resident.
- Do not run two GPU workloads at once. A stray recursive `grep` over the model
  directory cost 11% on one measurement.

---

## Results, 2026-08-14

All through the production router, same session. `fast` is the incumbent
(Ornith-1.0-35B MTP-APEX). TD is nerkyor Qwen3.6-35B-A3B-DSV4Pro-Thinking-Distill.
KAT is Kwaipilot KAT-Coder-V2.5-Dev, text-only.

| | **`fast`** (Ornith) | **`coder` Q4 +mmproj** | **`coder` Q5** | **TD-Q6_K** |
|---|---|---|---|---|
| role | production all-rounder | production coding | eval | eval |
| resident (GTT+VRAM) | 30.7 GiB | **24.8 GiB** | 33.2 GiB | 36.0 GiB |
| speculation | MTP n-max 2, p-min 0.3 | **none** (verified) | none | MTP n-max 2 |
| tg, 1 stream | **33.96** | 25.71 | 21.57 | 30.66 |
| pp, 1 stream | **347.8** | 312.3 | 289.9 | 296.4 |
| perplexity | 2.0183 | 2.0177 | **2.0024** | 2.0079 |
| **reason-eval-hard** | 8/10, **2 trunc**, 987 s, 93.6k | **10/10, 0 trunc**, 254/276 s | **10/10, 0 trunc**, 312/319 s | **10/10, 0 trunc**, 207 s |
| code-eval-hard | 6/6, 255 s, 29 turns | 6/6, 250 s, 31 turns | 6/6, 270 s, 31 turns | 6/6, 228 s, 31 turns |
| code-eval-claude | 6/6, 128 s, 41 turns | 6/6, 147 s, 31 turns | 6/6, 143 s, **28 turns** | 6/6, **115 s**, 33 turns |
| vision tier | 3/4 (compare TRUNC) | **4/4** | **4/4** | **4/4** |
| vision compare x3 | 3/3 @ 237 tok | **3/3 @ 233 tok** | 4/4 single | **3/3 @ 188 tok** |

Perplexity pairs, per-chunk over 20-80:

| pair | lower at | reading |
|---|---|---|
| coder-Q5 vs coder-Q4 | 61/61 | solid |
| coder-Q5 vs TD-Q6 | 61/61 | solid |
| TD-Q6 vs coder-Q4 | 61/61 | solid |
| coder-Q5 vs `fast` | 57/61, one tiny flip | probable, not solid |
| coder-Q4 vs `fast` | 10/61, flips | **wash** |
| TD-Q6 vs `fast` | 51/61, flips | **wash** |

**Lineup cut to three on 2026-08-14**: `fast`, `balanced` (Thinking-Distill
Q6_K, the default) and `deep` (Laguna). Removed and deleted: TD-Q4_K_M, both
KAT tiers, `coder` and its Q5 tier, `assist`, gpt-oss-120b. The table above is
kept in full because it is the calibration a future candidate is scored
against, and two of those models are the strongest results on it - `coder`
matched `balanced` on reasoning at 24.8 GiB and beat `fast` on vision, and
gpt-oss held `deep` at 10/10. Both are re-downloadable.

**`coder` Q4 +mmproj was re-downloaded the same day as `coder-eval`**, an eval
slot rather than an alias. Its column above is what it measured then, under a
lineup that no longer exists - promoting it means running this playbook against
today's `balanced` in one session, not citing that column. Its Q5 tier stays
deleted; that experiment has an answer.

Standing conclusions:

- **`balanced` is the default** on the tier this repo built to discriminate:
  10/10 with zero truncations against `fast`'s 8/10 with two, in a fifth of the
  wall clock, plus vision that does not truncate on the two-image item.
- **`fast` is kept for speed only** - +11% tg and +17% pp - and is the weakest
  hard reasoner of the three.
- **Perplexity did not decide anything here.** `balanced` and `fast` are a wash
  on it (51/61 with flips) and 10/10 against 8/10 on the tier that matters.
- **This repo's own capability claims have been wrong twice** - `coder` as
  text-only and as `reasoning: no`. Verify against the GGUF and the repo
  listing, not the docs.

### The quant-tier lesson, across four models

The same experiment - Q4 against one tier up - has now produced four different
answers. **Two were surprises against the prior. None could have been inferred.**

| model | PPL gain | capability effect | verdict |
|---|---|---|---|
| TD | 0.82% | **fixed** multi-image vision, 0/3 -> 3/3 deterministic | ship the higher tier |
| KAT | 0.20% | **broke** termination, 0 -> 3 truncations over two runs | keep Q4 |
| `coder` | 0.76% | **nothing** - same score, truncations, turns and vision | keep Q4 |

**Perplexity gain does not predict capability gain.** TD's 0.82% fixed a task
failure; `coder`'s 0.76% - almost the same magnitude, solid at 61/61 - changed
nothing at all. And KAT's *smallest* PPL gain came with the *largest* behaviour
change, in the wrong direction.

The one effect that has been consistent: **a higher tier repairs marginal
tool-discipline failures.** It fixed TD's multi-image comparison and KAT's
read-before-edit violation and edit miss. Where nothing was marginal, as on
`coder`, it did nothing.

So: measure the tier, do not infer it - not from perplexity, not from another
model, not from the same model's other tiers. And **re-run `reason-eval-hard`
after any requant**, because termination behaviour moved on KAT where its
perplexity barely did.

