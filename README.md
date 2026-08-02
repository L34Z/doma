# doma

> [!NOTE]
> This project was made for my personal use and enjoyment. AI was used.

**doma** (DOcument MAtcher) is a small and fast single binary that runs
[BM25](https://en.wikipedia.org/wiki/Okapi_BM25) search over your code and docs.
doma chunks Markdown at the heading level and source files at top-level
definitions. Either way a query returns ranked passages with a breadcrumb trail
and a snippet, so it lands you on the right section or function rather than the
right file.

You organise a project into named **corpuses**. A corpus is a filtered view of
the tree: a path, some extensions, and some exclusions. You query one by name:
`doma docs "auth flow"`, `doma code "bounded heap"`, or just `doma "<query>"` for
the default. Definitions live in a small committed `.doma/catalog.ini`.

No models, no server, no network. It reads local files and writes one index file
per corpus. The only optional dependency is `git`, used to honour `.gitignore`
when indexing; without it, doma still runs and just skips that filtering.

Written in [Odin](https://odin-lang.org/).

It pairs well with [doyo](https://github.com/L34Z/doyo), which yoinks a
project's docs into a local Markdown tree for doma to index.

## Download

Grab a prebuilt binary for Linux, macOS, or Windows from the
[Releases](https://github.com/L34Z/doma/releases) tab. Each release is built
natively on its own platform. To build from source instead, read on.

## Install

The dev environment is a pinned Nix flake. Enter it with:

```
nix develop     # or `direnv allow` if you use direnv
```

That gives you the Odin compiler, the `ols` language server, `gdb`, and three
convenience commands run from the repo root: `build` (compile to `build/doma`),
`test` (run the suite), and `run` (build, then run the binary with your
arguments). doma needs nothing at runtime except an optional `git` (see
Dependencies); the binary reads and writes files and does nothing else.

## Build

Inside the dev shell:

```
build                       # odin build . -out:build/doma
run search <query> <dir>    # build, then run
```

Or call the compiler directly:

```
odin build . -out:build/doma
build/doma init
build/doma index
build/doma <corpus> <query>
```

This builds on Linux, macOS, and Windows. Odin links only for the host OS, so
each platform's binary is built on that platform (see
`.github/workflows/release.yml`, which does exactly this for every release).

## Usage

Set up a project once with `doma init`, build the indexes with `doma index`, then
query a corpus by name. The index is a cache that a query checks against disk and
never trusts blindly.

```
doma init [dir]
  Detects your languages and a docs/ dir, writes a starter .doma/catalog.ini,
  and adds /.doma/*.idx to .gitignore. Edit the catalog, then index.

doma index [corpus] [--jobs n] [--no-gitignore] [--force]
  Builds every corpus (or just the named one) into .doma/<corpus>.idx.

doma <corpus> <query> [flags]     search a catalogued corpus
doma <query> [flags]              search the default corpus
  --topk <n>      how many results to return (default 10)
  --json          one JSON object per line instead of the human format
  --verify        hash every indexed file instead of the cheap freshness gate

doma catalog [add <name> <path> [--ext list] [--exclude list]]
  List corpuses, or append a new one to the catalog.

doma search <query> [dir] [--ext list] [--exclude list] [--topk n] [--json]
  Ad-hoc, catalog-free: builds an in-memory index of a path and searches it.
```

A `.doma/catalog.ini` looks like this. Each `[section]` is a corpus:

```ini
[doma]
default = code

[code]
path = .
ext = odin
exclude = docs

[docs]
path = docs
```

Examples:

```
doma init                          # writes .doma/catalog.ini
doma index                         # builds every corpus
doma code "bounded min heap"       # query the code corpus
doma "camelCase splitting" --json  # query the default corpus
doma catalog add nakama docs/vendor/nakama
doma search "quick look" ./notes --ext md   # one-off, no catalog
```

The first token resolves by precedence: a reserved verb (`init`, `index`,
`search`, `catalog`, `bench`, `help`) wins, else a corpus name, else the whole
line is a query against the default corpus. So a corpus can't share a name with a
verb. Results print as `rank, score, breadcrumb` followed by the matching snippet.
A stale corpus reports the changed file and asks you to re-run `doma index`.

## Use with an AI agent

Build or download the binary, drop it in your project, run `doma init` and
`doma index` once, and point your coding agent at it. Tell the agent something
like:

> Run ./doma docs "<question>" to find the relevant docs, or ./doma code
> "<symbol or idea>" to find where something lives, before you answer.

doma returns the ranked passages and their breadcrumbs, so the agent reads the
right few sections of real documentation or source instead of guessing at an API
from memory, and it does so in a few milliseconds with no server to keep running.

## How it works

doma splits into two pure functions, each testable byte-for-byte:

1. `source bytes -> index bytes` (`doma index`)
2. `(index bytes, query) -> results` (`doma search`)

**Indexing.** For each corpus, doma walks its `path` for the configured
extensions. It skips dotted directories and `node_modules/`, `vendor/`,
`thirdparty/`, applies the corpus's `exclude` prefixes, and drops anything
`.gitignore`d when `git` is present. Markdown (`.md`, `.markdown`) is split at ATX
heading boundaries (`#` to `######`), so a chunk runs to the next heading of
equal-or-higher level; fenced code blocks are tracked so a `#` inside a fence
never opens a chunk. Every other file is split at top-level definitions: a line
that begins in column 0 with real content (not a comment or a lone closing
delimiter) opens a chunk that runs to the next such line. That is a
language-agnostic heuristic, not a parser. Every chunk carries a breadcrumb
(`<corpus> > <path> > <heading or signature> > ...`). Text is tokenized by
lowercasing and splitting on non-alphanumeric bytes, on camelCase boundaries, and
on underscores, with no stemming and no stopwords.

**The index.** doma writes one binary index per corpus at `.doma/<corpus>.idx`: a
header, a file table, a chunk table, a sorted term dictionary, postings, corpus
stats, and a deduped string blob. It holds raw statistics only, no precomputed
scores. The tables are packed little-endian struct arrays, so the search reader
casts them in place out of an mmap rather than parsing field by field. Index load
costs almost nothing, and a cold search faults in only the pages it touches. (On
Windows, which lacks the POSIX mmap, doma reads the index whole instead — same
results, but the whole index is loaded up front rather than demand-paged.)

**Searching.** A corpus query mmaps that one corpus's index and ranks with BM25
(`k1 = 1.2`, `b = 0.75`). It keeps the top *k* through a bounded min-heap and
builds a breadcrumb only for the survivors. The snippet is read live from the
source file at the stored byte range (the index stores no content): the
highest-density ~200-byte window, the one covering the most distinct query terms.

**Freshness.** Before searching, doma verifies the corpus index against disk in
two tiers so a query never re-reads the whole corpus. A cheap `stat` per file
flags anything whose size changed or whose mtime is newer than the index. Only
flagged files are read and hashed; a matching hash clears them, while a mismatch
or a missing file marks the corpus stale and asks you to re-run `doma index`. A
bare `touch` never forces a reindex. `--verify` skips the gate and hashes
everything.

## Determinism

The transform is deterministic: the same source bytes always produce the same
index bytes, and the same index and query always produce the same ranked output.
Every table in the index is sorted, ties break on a total order
`(corpus, file id, chunk start)`, and the threaded index build merges workers in
fixed file-id order, so output is byte-identical regardless of `--jobs` or how the
OS scheduled the threads. There is no wall clock and no unseeded randomness
anywhere in the logic. The one honest limit: an edit that preserves both a file's
byte length and its mtime is invisible to the freshness gate until the next
`doma index`.

## Scope

In scope for v1:

- Named corpuses defined in `.doma/catalog.ini` (`init`, `index`, `catalog`).
- Markdown heading chunking and language-agnostic code chunking, BM25 ranking.
- `.gitignore` respect (via `git check-ignore`) and per-corpus excludes.
- Ad-hoc `doma search` over any path with no catalog.
- Two-tier freshness checking so a stale index is caught, not silently trusted.

Out of scope until a design decision promotes it:

- Stemming, stopwords, phrase and boolean queries, fuzzy matching.
- Language-aware (parser or tree-sitter) code chunking.
- A global, cross-project corpus registry.
- Incremental reindexing and watch mode.
- MCP or any server mode.
- Embeddings or models of any kind.

## Testing and benchmarks

The pure transform is the unit-tested layer. A seeded in-repo generator emits the
synthetic fixture tree, and golden tests assert the exact index and result bytes,
so a change that moves a golden value updates it in the same commit.

```
odin test src
```

The benchmark runs the same transform over a generated 1000-file tree and reports
throughput, with no disk or network variance. Pass a directory to benchmark a
real corpus instead.

```
odin build . -out:build/doma && build/doma bench
```

On the reference tree it builds the index in about 50 ms and searches in about
11 µs per query, with index load too fast to measure (the tables are cast in
place, not parsed). On a real 52.6 MB index over 13,299 Markdown files, a warm
search lands at about 4 ms, faster than `grep -r` over the same tree (~46 ms)
while ranking by relevance rather than just matching. Real corpora are smoke data
only, never committed to the suite.

## Dependencies

One, and it is optional: `git`, invoked as `git check-ignore` to honour
`.gitignore` while indexing. If `git` is missing or the tree isn't a repo, doma
skips that filtering and runs unchanged, so the binary is still self-contained for
search. Everything else is hand-rolled and owned: the index format, the chunkers,
the tokenizer, and the BM25 scorer, with no bundled C libraries and no network
calls. It requires a little-endian host (every current target, x86-64 and ARM64,
qualifies), which is checked at compile time.

## Contributing

I made doma for myself and don't plan to put much ongoing work into it. If you
send a thoughtful pull request I'll read it and merge what fits. Bug reports and
small fixes are welcome too. Open an issue or a PR and I'll get to it when I can.
No templates, no formal process.
