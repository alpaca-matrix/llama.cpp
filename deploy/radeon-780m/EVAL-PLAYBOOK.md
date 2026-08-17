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
| arch supported | `strings build-vk2/bin/libllama.so \| grep -x <arch>` | not in the **serving** library, not merely absent from the tree |
| pool fit | file size + KV at target ctx vs 76 GiB | over, at `models-max 1` |
| dense or MoE | expert tensors in `gguf-header.py` | **dense** - four rejections here, ~4-8 t/s |
| tokenizer | `tokenizer.ggml.model` + token count | differs from the incumbent, if you want cross-model perplexity |
| MTP head | `blk.N` beyond `block_count - 1` | absent means no speculation, ~30% off tg |
| vision | mmproj published? | absent, if the target alias serves screenshots |
| full-attention layers | `full_attention_interval` in upstream config.json | all layers full-attn - see MiniMax-M2.1, -65% by d32768 |

**Answer all of the above from the GGUF header, without downloading weights.**
The KV block and tensor table sit at the front of the file, so a range request
for the first 50 MB carries arch, block count, expert count, context length,
tokenizer and vocab size, the chat template, and every tensor name:

```sh
curl -sL -r 0-52428800 -o /tmp/head.gguf \
  "https://huggingface.co/<repo>/resolve/main/<file>.gguf"
./gguf-header.py     /tmp/head.gguf   # all KV + every tensor name/shape/type
./bytes-per-token.py /tmp/head.gguf   # active bytes/token and the tg ceiling
```

**Do not reach for `gguf_dump.py` here - it cannot read a prefix at all.**
`GGUFReader` builds numpy views over the tensor data during construction, so
every truncated file dies with `cannot reshape array of size N into shape (...)`
before printing a single field. That is why this section used to fall back to
`strings`, which answers the MTP-head question and nothing else.

`gguf-header.py` parses the KV block and tensor-info table directly and stops at
the data section, so it works on a prefix and on a whole file alike. It prints
the full KV (truncating only the token/score/merge arrays to their lengths), the
`blk.N` index range, and the unique tensor-name patterns with shape and quant
type - which is where "does this have an MTP head" and "is this dense" get
answered in one read. `bytes-per-token.py` then computes the throughput estimate
from that same table, weighting `*_exps` tensors by
`expert_used_count / expert_count` and counting everything else in full, so the
prediction comes from real shapes and real quant types rather than from a file
size and an assumed active fraction.

50 MB answers the questions that decide whether to spend 30 GB. Used
2026-08-15 on three candidates: it found two of them had their MTP head dropped
in conversion, which set the whole session's expectations before a byte of
weights was fetched. Used again 2026-08-17 on three more, where it settled two
dense rejections and, on the one that passed, established from the header alone
that the drafter was a separate `gemma4-assistant` model rather than an in-file
head. Do this before every fetch.

**Check the chat template too, while the header is open.** It costs one grep and
it decides how the model's reasoning and tool calls will be parsed. On 2026-08-17
the two gemma4 candidates were confirmed to hit llama.cpp's native `peg-gemma4`
parser (detection is the `'<|tool_call>call:'` literal in `common/chat.cpp`) and
the CURRENT template variant rather than the compatibility-workaround path, and
that their reasoning arrives on `<|channel>thought` .. `<channel|>` rather than
in a `<think>` tag - so `reasoning-format` was not going to do what the other
stanzas use it for.

**And confirm the arch against the SERVING library, not the source tree.** The
tree and `build-vk2` can differ by weeks. `strings build-vk2/bin/libllama.so |
grep -x <arch>` answers it in one command; the source having the arch proves only
that a rebuild would.

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
> `block_count - 1` in `gguf-header.py`, and check the repo listing for an
> mmproj, before believing any capability claim in this repo's own docs.
>
> **The head may not be in the file at all.** Gemma 4 publishes it as a separate
> model of arch `gemma4-assistant` (`nextn.pre_projection` /
> `nextn.post_projection`, `nextn_predict_layers` 4), wired with
> `spec-draft-model` the way an external drafter is. So "no block beyond
> `block_count - 1`" means "no head in THIS file", not "no MTP" - check the repo
> listing for an `mtp-*` file before concluding a model cannot speculate. Note
> also that this shape shares the target's KV (`is_mem_shared` in
> `common/speculative.cpp`), so it costs no draft KV and the `n_max` clamp to
> `nextn_predict_layers` does not apply to it.

> **Confirm "no MTP head" positively, not by absence.** Point spec-sweep at the
> file with `SPEC_TYPE=draft-mtp` and a non-zero n-max: if there is no head the
> server refuses and dies during load, which is a positive result rather than an
> inference from a tensor scan that might have missed something. Costs one
> failed load. Used on both non-speculating candidates 2026-08-15.
>
> **A dropped MTP head is a real failure mode of third-party conversions.** Two
> of the three candidates that day came from upstream models that HAVE a native
> MTP head and shipped GGUFs without it - in one case the very head SC117 grafts
> onto Ornith to make `fast` speculate. It silently costs ~27% of generation and
> neither repo card mentions it.

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
- **A sweep cell that never returns is a result, not a broken run.** An
  EXTERNAL drafter can hard-wedge a slot: generation freezes mid-request,
  `/slots` still reports `is_processing` with `n_decoded` frozen, the GPU sits
  at 90% emitting nothing until the client's 900 s timeout. It is not the
  amdgpu watchdog - check `journalctl -k` and it is clean - and it clears when
  the client gives up. Qwen3-Coder-Next did this in 7 of 21 speculated cells on
  2026-08-17, with both DFlash and Eagle3, and it reproduced on ordinary router
  traffic with EOS enabled, so it is not the harness's `ignore_eos`. Give each
  cell its own `LOG` path or the post-mortem is overwritten by the next one,
  and count the hangs - a config that wedges is disqualified whatever it
  measures.

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
once - it should match to four decimals. Verified 2026-08-15: `fast` re-measured
2.0183 +/- 0.02510 and `balanced` 2.0079, matching their recorded figures across
eleven days, a `parallel` change and a rebuilt binary, and the `balanced` vs
`fast` pairing re-derived independently as the same 51/61 with one flip.

> **Perplexity can INVERT capability, not merely fail to predict it.** On
> 2026-08-15 the candidate with the best perplexity ever measured on this box -
> 2.0069, lower than `fast` at 61 of 61 paired chunks, the strongest form this
> test has - scored **5/10 with 5 truncations** on `reason-eval-hard`, the worst
> result ever recorded here. It was also the fastest model ever measured here.
> A candidate that arrives with a perplexity argument and no `reason-eval-hard`
> number has said nothing at all. Never let step 7 promote anything; it is a
> tie-breaker and a tier check, never evidence of capability.

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
- **Do not trust the scripts' "server is busy" guard.** `/slots` answers HTTP
  400 in router mode and `probe-server.sh` pipes the check through `grep -c`,
  so the 400 becomes a count of 0 and it reports "not busy" no matter what the
  server is doing. That guard has been inoperative for as long as this box has
  run in router mode (found 2026-08-15). Confirm idleness yourself.
- **Do not wait on `pgrep -f <pattern>`** when the waiter's own command line can
  contain the pattern - it matches itself and waits forever. Cost 20 minutes on
  2026-08-15, and a stale process from an earlier session was found spinning on
  the identical bug. Wait on a marker file or a completion line in a log.
  `pkill -f` over SSH is the same bug with teeth: the remote `bash -c` line
  contains the pattern, so it kills the session instead of the target and
  orphans whatever the target had spawned. Kill by PID. Found again 2026-08-17,
  which left a sweep cell running with no parent.
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
| QCN | 0.62% | **fixed** termination (2 stalled tasks, both coding tiers 5/6 -> 6/6) **and broke** tool discipline (0 -> 2 read-before-edit, 0 -> 3 edit misses) | irrelevant, loses at both tiers |

**Perplexity gain does not predict capability gain.** TD's 0.82% fixed a task
failure; `coder`'s 0.76% - almost the same magnitude, solid at 61/61 - changed
nothing at all. And KAT's *smallest* PPL gain came with the *largest* behaviour
change, in the wrong direction.

**That "consistent effect" is now withdrawn.** Through four models the rule read
"a higher tier repairs marginal tool-discipline failures" - TD's multi-image
comparison, KAT's read-before-edit violation and edit miss. QCN broke it in both
directions at once on 2026-08-17: the higher tier repaired **termination** (two
tasks that stalled out at Q4-class now pass in 4 and 13 turns) while *creating*
tool-discipline failures that were not there (0 -> 2 read-before-edit, 0 -> 3
edit misses). What survives is weaker and vaguer: a higher tier moves whatever
was marginal, and the direction is not predictable.

**The failure's shape does not tell you whether the tier is responsible.** This
is the expensive lesson of 2026-08-17. QCN's IQ4_XS failures were read, at the
time, as pointing away from quantization - discipline was perfect, so the lever
that had always worked on discipline looked irrelevant. That inference was
wrong; both failures were the tier. Do not reason from signature to cause.

So: measure the tier, do not infer it - not from perplexity, not from another
model, not from the same model's other tiers, not from the shape of the failure.
And **re-run `reason-eval-hard` after any requant**, because termination
behaviour moved on KAT where its perplexity barely did.

---

## Results, 2026-08-17 - Qwen3-Coder-Next at two tiers

All through the production router, one session, `balanced` re-measured as the
control in each half. QCN is Qwen/Qwen3-Coder-Next 80B-A3B (arch `qwen3next`,
512 experts top-10, 12 of 48 layers full attention), at bartowski's IQ4_XS-imatrix
and Q6_K. **Both tiers rejected; all QCN weights deleted 2026-08-17.** The table
is kept because it is the calibration for the next 80B-class coder candidate,
and because it is this repo's only two-tier comparison of one model measured
end-to-end in a single session.

| | **QCN IQ4_XS** | **QCN Q6_K** | **`balanced`** (control) |
|---|---|---|---|
| role | eval | eval | production default |
| resident (GTT+VRAM) | 45.6 GiB | 66.9 GiB | **27.2 GiB** |
| speculation | **none** (swept, see below) | none | MTP n-max 2 |
| tg, 1 stream | 22.29 | 17.94 | **30.87** |
| pp, 1 stream | 243.2 | 163.5 | **293.2** |
| per-stream tg, 2 streams | 14.09 | 11.50 | **17.75** |
| aggregate, 2 streams | 13.49 | 10.00 | **15.24** |
| perplexity | 2.0231 +/- 0.03066 | **2.0105** +/- 0.03045 | 2.0079 (not re-run) |
| **reason-eval-hard** | 9/10, 0 trunc, **41 s**, **0c** | 9/10, 0 trunc, 57 s, **0c** | **10/10**, 0 trunc, 206 s, 20.5k |
| code-eval-hard | **5/6**, 238 s, 67 turns | 6/6, 229 s, 43 turns | 6/6, 199 s, **31 turns** |
| code-eval-claude | **5/6**, 240 s, 108 turns | 6/6, 272 s, 87 turns | 6/6, **115 s**, **33 turns** |
| read-before-edit / edit misses | 0 / 0 | **2 / 3** | 0 / 0 |
| vision | no mmproj published | no mmproj published | 4/4 |

Perplexity pair, per-chunk over 20-80. Only the within-model pair exists: QCN's
tokenizer is qwen2/151936 against the incumbents' qwen35/248320, so **no
cross-model pairing was available for this candidate at all**.

| pair | lower at | reading |
|---|---|---|
| QCN-Q6_K vs QCN-IQ4_XS | **61/61, zero flips** | solid, 0.623% |

**Drafter sweep** (step 3, `spec-sweep.sh`, real prompts, both concurrencies).
QCN has no MTP head, so this was the first candidate here to sweep two EXTERNAL
drafters - z-lab's DFlash 0.5B and thoughtworks' Eagle3 145M, aggregate t/s:

| | 1 stream | 2 streams |
|---|---|---|
| none | 12.54 / 12.95 | **14.18 / 14.04** |
| DFlash, best | **13.48** (n3 p0.75, +5.7%) | 12.74 (n2, -10.2%) |
| Eagle3, best | 11.27 (n1, -10.1%) | 11.22 (n1, -20.9%) |

DFlash beat Eagle3 on every axis - acceptance 0.805 against 0.574 at the same
n-max 3 - and still lost to shipping nothing at the concurrency this box serves.
**Both drafters also wedged slots**, 7 of 21 speculated cells; see the wedge
bullet under step 3.

Conclusions this session added:

- **A non-thinking model can score 9/10 on `reason-eval-hard`.** QCN answered
  most items in 1.0-1.4 s with **zero chars of reasoning**, the whole tier in
  41 s against `balanced`'s 206. It is the first model here to get near the top
  of that tier without a thinking channel, and it never truncated. It still lost
  the tier 9/10 to 10/10, failing the same item at both tiers on the same
  anti-pattern - so that miss is the model, not the tier.
- **`code-eval-hard` is no longer saturated.** Six models scored 6/6 before
  this; QCN at IQ4_XS scored 5/6 by stalling out on `dup-block` after 32 turns.
  The tier repaired it. The bench still discriminates.
- **Turns are the axis that killed it**, not the score. At Q6_K it reaches 6/6
  on both coding tiers - what `balanced` already has - needing 2.6x the turns at
  2.4x the wall clock and 2.5x the pool.
- **The byte model is calibrated for K-quants, not for IQ4_XS on routed
  experts.** Same weights, same `MUL_MAT_ID` path, two quant types: Q6_K
  predicted 18.3 t/s and measured 17.94 (-2%), where IQ4_XS predicted 28.1 and
  measured 22.29 (**-21%**). Narrow the "IQ4_XS is smaller AND faster"
  heuristic, not the bytes-per-token model.
