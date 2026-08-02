# ADR-0001: Stat-gated freshness on the search path

- Status: accepted
- Date: 2026-07-29

## Context

`doma search` verifies each loaded index against disk before scoring, so a stale index
never serves wrong results (DESIGN §4). The original check read and FNV-hashed *every*
source file on *every* query. On a 13k-file / 86 MB corpus that is ~0.22 s per search,
while BM25 scoring itself is ~52 µs (README benchmarks). The read path, not ranking, was ~99.5%
of query wall time — and it grows with corpus size, directly contradicting the §9
"search under a millisecond" target.

## Decision

Verify in two tiers:

1. **Freshness gate** — one `stat` per indexed file. A file is *suspect* if its size
   differs from the stored byte length, or its mtime is newer than the `.doma-index`
   file's own mtime. No suspects ⇒ fresh, zero reads.
2. **Content verification** — only suspect files are read and hashed. Hash remains the
   final arbiter of stale-vs-fresh.

Freshness is split into a pure `freshness(recs, file_states, index_mtime)` verdict
(unit-testable with hand-built states, no filesystem) and a thin I/O shell that stats,
calls it, and hashes the suspects. `--verify` skips the gate and hashes everything.

## Alternatives considered

- **Keep hashing every file.** Correct but cannot meet §9 at scale; rejected.
- **Store per-file mtime in `File_Rec`.** Simplest gate, but mtime varies across machines
  and checkouts, so identical sources would produce different index bytes — breaks §8
  byte-determinism and every golden test. Rejected in favour of comparing against the
  index file's own mtime, which stores nothing new.
- **Mark suspect files stale immediately.** Blunter and faster to write, but a harmless
  `touch` would force a full reindex. Rejected: hashing only the suspects keeps the hash
  as arbiter at bounded cost.

## Consequences

- Query wall time drops from O(corpus bytes) to O(files) `stat` calls in the common case.
- No index format change; index bytes stay deterministic (§8).
- **Accepted limit:** an edit preserving both byte length and mtime is invisible to the
  gate until the next `doma index`. `.doma-index` is a derived cache (§8) and `--verify`
  forces a full check, so the exposure is bounded and escapable.
