# fast-opt-plan: optimize the `fast` serving path (Ornith-1.0-35B MTP)

Status: PLANNED, not started. Written 2026-08-02 while the box was unreachable;
every stage carries its benchmark recipe so implementation sessions are turnkey.
All file:line references verified against this tree on the date above.

## Context

`fast` (Ornith-1.0-35B, arch QWEN35MOE, 151936 vocab, in-model 1-layer MTP head,
Q6_K/Q5_K/IQ4_XS expert mix) is served with `spec-type = draft-mtp`,
`spec-draft-n-max = 3`, `parallel = 2`, `kv-unified`, KV q8_0, ubatch 2048.
Baseline: pp512 ~333 t/s (llama-bench), tg ~34.6 t/s served, tg bandwidth-bound
at ~74 of 89.6 GB/s theoretical.

Goal: improve serving throughput with code/config changes, each proven by A/B/A
benchmarks on the box.

Rules (see README.md for the reasoning):
- Repo is source of truth: edit here -> commit -> push to fork -> pull on LXC ->
  rebuild -> bench. No commit/push without explicit per-action user approval.
- Do NOT retry rejected items: RDNA3 gpu_pipeline_configs entry, mul_mat_vec_id
  threshold RAISE, MMVQ disable (PR 25666), q8_0 KV dequant hoist (PR 25494),
  ROCm, ngram/draft-model spec, rocwmma, integer dot, models-max 2.
- llama-bench for pp (server pp is unstable +/-17%); probe-server.sh 3 samples
  for tg/acceptance; A/B/A always; confirm backend column = Vulkan; restart only
  when idle; space restarts (DeviceLost history).

## How a `fast` request flows (established by code trace)

HTTP thread: json parse -> (Anthropic->OAI) -> jinja render -> tokenize -> queue.
Main loop `update_slots()`: slot pick by LCP similarity (server-context.cpp:1525),
prompt-cache save/load, `pre_decode` (arm draft -> `common_speculative_draft` ->
build batch), chunked `llama_decode`, then per generation round:

1. 3 serialized MTP draft decodes, each a full 151936-vocab LM-head pass ending in
   a blocking `llama_synchronize` (common/speculative.cpp:1571, sampling.cpp:563)
2. 1 target verify decode (draft+1 rows, all logits)
3. 1 MTP catch-up decode over the verify batch, zero logit rows
   (`common_speculative_process`, speculative.cpp:1402-1518, called from
   server-context.cpp:3638 on every chunk, prefill included)
4. CPU acceptance in `post_decode` (server-context.cpp:3788-3903)

= 5 serialized GPU dispatches per ~30 ms round, 4 through the MTP head.

Master Vulkan finding: ggml-backend.cpp:1569-1576 fully drains the GPU before
copying graph inputs, so CPU graph build/record NEVER overlaps GPU execution;
the fence wait spins with YIELD (ggml-vulkan.cpp:2395-2414), and on a shared-TDP
APU the spinning core competes with the iGPU for power and memory bandwidth.
Sampling, MTP CPU work, fusion probing (~15 pattern probes/node) and descriptor
updates all happen inside this dead GPU time.

## Stage 0 - Bubble measurement (first 30 min of box access; GATES Stage 3)

No source changes. Splits decode time into GPU-busy vs CPU/sync bubble.

- `GGML_VK_PERF_LOGGER=1 GGML_VK_PERF_LOGGER_CONCURRENT=1 llama-bench -m <fast>
  -ngl 99 -fa 1 -ub 2048 -p 0 -n 64 -r 3` -> sum per-op GPU time per graph;
  bubble = wall ms/token - GPU-busy ms/token. Must use _CONCURRENT: the plain
  logger inserts a barrier per node and serializes everything.
- Same with `-p 512 -n 0` for prefill; confirm `topk_moe` and fused `mul_mat_id`
  labels appear (fusion sanity check).
- One server probe sample, then read the `graphs reused` counter (printed via
  server-context.cpp:605) to quantify the ctx_dft graph-rebuild alternation.

Decision rule: bubble >= ~25% of decode wall -> Stage 4 first, Stage 3 is capped
by Amdahl. Bubble <= ~10% -> Stage 3 kernels first. Record the number in
README.md either way.

## Stage 1 - Config-only sweeps (same session; one commit per change)

All flags verified present in this tree. Metrics: probe-server tg + acceptance,
A/B/A, unless noted.

- 1a `spec-draft-p-min = {0.3, 0.5, 0.7}` under `[fast]` (default 0.0 means
  draft truncation never fires today). Skips low-confidence full-vocab LM-head
  draft steps; with acceptance 0.83 the rejections live in steps 2-3.
  Expect 0-8% tg. Abort: tg down or acceptance collapse at all three values.
- 1b `spec-draft-type-k = q8_0`, `spec-draft-type-v = q8_0` under `[fast]`
  (exact key names from arg.cpp:3920/3933; the MTP draft KV is silently F16
  today while the target runs q8_0). Halves the 1-layer MTP KV. Expect 0-2% tg
  plus GTT savings; accept if not negative; abort if acceptance drops >1 point.
- 1c `cache-idle-slots = false` in `[*]` - targets the idle-slot KV dump/erase
  around every request (server-context.cpp:2398-2414, armed by kv-unified +
  parallel 2), the suspected source of the 264-311 t/s server-pp variance.
  Criterion is SPREAD, not mean: 6 identical requests per condition, compare
  min/max. Before accepting, re-verify the agent prefix-cache behavior
  (the 9k-of-11k restore test in README.md) still holds - this flag exists to
  protect cached prefixes.
- 1d `GGML_VK_MAX_NODES_PER_SUBMIT = {25, 1000000}` (default 100; ~15-18
  vkQueueSubmit per decode graph today). llama-bench env inline, pp512 + tg64,
  A/B/A. A winner lands as an `Environment=` line in llama-server.service.

## Stage 2 - Trivial patches (one commit each)

- 2a Sampler-clone guard, tools/server/server-context.cpp:3801. Today every
  verify round clones the sampler (~1.8 MB candidate vector) and discards it
  unless the checkpoint-restore path at :3838 runs. The clone MUST stay
  pre-sampling (`use_ckpt_tgt` at :3811 depends on n_rollback, known only
  post-sampling), so guard with the conservative pre-sampling predicate already
  used at :3002-3004:
  `may_restore = ctx_tgt_seq_rm_type == FULL || (RS && n_draft > llama_n_rs_seq(ctx_tgt))`
  and clone only if may_restore. Covers every case where :3838 restores. On
  `fast` (RS type, n_draft 3 == n_rs_seq) the clone disappears from every round.
  Expect 0-2% tg (this CPU work sits in dead GPU time; record honestly either
  way; acceptance criterion is no-regression).
- 2b Dangling-pointer fix in common_sampler_clone (common/sampling.cpp:497-507):
  the copied `cur_p.data` still points into the source sampler's `cur`; rebase it
  onto the copy. Separate commit (independently upstreamable correctness fix);
  no benchmark needed.

## Stage 3 - Vulkan kernel-selection A/Bs (gated by Stage 0)

Implement all three as getenv-gated toggles in ONE build (the bracket method
proven on MMVQ); A/B/A each independently from the same binary; hard-code
winners / record rejections; remove dead toggles in a cleanup commit. Keep
build-vk2 intact as the A binary.

- 3a DMMV_WG_SIZE_LARGE for AMD on the `_id` path. ggml-vulkan.cpp:7720 gates
  4-subgroup dmmv workgroups to NVIDIA/Intel; AMD always runs one-subgroup
  workgroups. Distinct from the rejected wave32 experiment (subgroups per
  workgroup, not subgroup width). Both WG variants are compiled for all vendors
  (pipeline loop :4993, :5087+), so no missing-pipeline risk. Note Q6_K takes
  the stricter `m < 4096 && k >= 1024` branch (:7724-7727) - check actual expert
  tensor m before predicting coverage. Measure: llama-bench tg64 + perf-logger
  MUL_MAT_ID per-op delta; probe-server confirm. Expect 0-5% tg.
- 3b FA scalar for small n: ggml-vulkan.cpp:3657, `n_rows == 1` -> `n_rows <= 4`.
  The 2-4-row verify batches currently run coopmat1 on a 16x64 tile (mostly
  padding). Shmem validity is re-checked downstream (:10387). llama-bench cannot
  produce 4-row decodes - measure served tg + perf-logger FA op time from a
  served run; re-run pp512 to confirm prefill FA untouched. Expect 0-3% tg.
- 3c mul_mat_vec_id threshold LOWER: ggml-vulkan.cpp:10371, `<= 8` -> `<= 1`,
  forcing n=2-4 verify batches onto the expert-major matrix path (reads the
  union of experts once vs one-dispatch-per-token re-reads, loop at :10340;
  NUM_COLS is hardwired 1 for every mul_mat_vec_id pipeline, :5087). This is the
  INVERSE of the rejected raise-to-32. Cost side: count_experts prepass +
  quantize_y at tiny n - may lose; the one-line A/B settles it.
  Expect -3..+5% tg; abort immediately if pp512 moves (it should not).

## Stage 4 - process()/draft-step-0 merge (structural; biggest single candidate)

Collapses 4 MTP dispatches/round to 3: removes one decode+synchronize round-trip
per round and decodes n_accepted+2 rows instead of n_draft+1 through the MTP
layer; resolves [TAG_SPEC_AVOID_DRAFT_REEVAL] (server-context.cpp:3635) and
eliminates the verify_h copies (~32 MiB per 2048-token prefill chunk).

Two facts that shaped the design (do not re-litigate):
- The catch-up decode requests ZERO logit rows (speculative.cpp:1441), so it
  never runs the LM head - the win is a dispatch + sync, NOT an LM-head stream
  (the 3 draft LM-head passes remain).
- Draft step 0's input token is the freshly sampled target token, which is not
  in the verify batch - the merged decode must APPEND a row, which forces
  acceptance-first ordering.

Design (gated on `!chain_heads && !is_mem_shared`, the qwen35moe single-head
path; other impls keep legacy `process()`):

1. New API `common_speculative_process_batch(spec, batch_view, updates)` in
   common/speculative.{h,cpp}; per-seq update = {state PREFILL|ACCEPTED|RESTORED,
   n_accepted, id_next, pos_next}. Legacy `common_speculative_process` remains.
2. Server: delete the `common_speculative_process` call from `decode()` (:3638);
   call `process_batch` at the END of `post_decode()` (after the :3877 seq_rm) -
   still inside the chunk loop, so the target h_nextn buffers remain valid,
   prefill chunks included. States: prompt chunks -> PREFILL; generation rounds
   -> ACCEPTED (id_next = slot.sampled, pos_next = prompt.tokens.pos_next());
   the ckpt-restore early-return path (:3817-3841) -> RESTORED.
3. impl_draft_mtp::process_batch: PREFILL rows exactly as today's process().
   ACCEPTED seqs: decode rows 0..n_accepted (embd = shifted target h, row 0 from
   pending_h, as :1444-1465) plus ONE appended row (id_next, pos_next,
   logits=true, embd = target h at the accepted boundary). One llama_decode for
   all seqs. Then per ACCEPTED seq: sample step-0 from the appended row
   (common_sampler_reset + common_sampler_sample), stash h0 =
   llama_get_embeddings_nextn_ith of that row and step0_tok, set has_step0.
   RESTORED: legacy semantics, has_step0 false.
4. draft() (:1520): if has_step0, skip the first decode - apply the p-min gate
   to the stored candidate, push it, seed the loop at i=1 with
   (step0_tok, n_past+1, h0). Else legacy path (graceful degradation).
5. KV bookkeeping: accept one redundant row per round (the step-0 cell is wiped
   by the :2996 seq_rm next round and re-decoded as row 0 of the next merged
   call). Do NOT touch the seq_rm invariants - that is where this change would
   get dangerous.
6. Fold in the verify_h elimination: accept()'s single-row read moves inside
   process_batch; PREFILL updates pending_h from the last row directly.

Multi-slot (parallel 2) works naturally: the update vector is per-seq and the
merged decode batches both slots, including mixed generate+prefill chunks.
Graph shapes: 3 ctx_dft graphs/round; steps 1-2 reuse; the merged graph varies
with n_accepted, so the shape alternation is only partially resolved.

Expect 3-8% tg (bounded by Stage 0's bubble/5 - each sync round-trip is about a
fifth of the bubble). Correctness gate: `fast` under MTP is deterministic on
this box (acceptance matched to five decimals between rounds) - acceptance and
the token stream must match baseline EXACTLY on the stable prompt; any drift
means the h/position bookkeeping is wrong: abort, do not tune around it.
pp512 must be exactly flat.

## Sequencing, sessions, approval, recording

- Order: Stage 0 -> 1 (session 1, no builds) -> 2+3 (session 2, one build
  containing 2a + 2b + the three env-gated toggles) -> 4 (session 3, own build,
  baseline includes whatever 1-3 landed). Land Stage 1 first: p-min changes the
  round shape Stage 4 is measured against.
- Rollback: one commit per change; git revert + re-pull/rebuild per README flow.
- Approval: prepare each diff, ask before every commit and push (AGENTS.md).
- Recording: every result, accepted or rejected, goes into README.md
  ("What actually mattered" / "Tested and rejected") in the same commit that
  lands or reverts the change.

## Final acceptance for the whole effort

- llama-bench pp512/tg64 at d0 and d32768 vs the README depth-sweep baseline.
- probe-server.sh fast 3: served tg + acceptance vs 34.6 t/s / 0.83 baseline.
- One real Claude Code session against the box (claude-local.ps1 fast) to
  confirm tools, streaming and prefix-cache restore are unchanged.

## Critical files

- tools/server/server-context.cpp (:3801 clone guard; :3638 process move;
  :3788-3903 acceptance plumbing; :2398-2414 cache-idle-slots behavior)
- common/speculative.cpp (:1249-1693 impl_draft_mtp; new process_batch;
  draft() step-0 skip)
- common/sampling.cpp (:497-507 clone fix)
- ggml/src/ggml-vulkan/ggml-vulkan.cpp (:7719-7733 dmmv _id WG; :3657 FA
  scalar; :10371 matvec_id threshold)
- deploy/radeon-780m/router.ini (Stage 1 keys) + README.md (results record) +
  llama-server.service (if 1d wins)
