package doma

// ## Changes
// - 2026-07-29: Split main() out to the root package main; src exposes run only.
// - 2026-07-29: Subcommand skeleton (index/search), exit codes per DESIGN.md §8.
// - 2026-08-01: `help`/`-h`/`--help` and no-args both print USAGE (help to stdout,
//   exit 0; no-args to stderr, exit 2). One USAGE string is the single source.
// - 2026-08-01: Catalog dispatch. First token resolves by precedence: reserved verb →
//   catalog corpus name (`doma nakama <query>`) → default corpus (`doma <query>`).

import "core:fmt"

// Reserved subcommands. A corpus may not share a name with one of these, so first-token
// dispatch is unambiguous; `doma init`/`catalog add` reject shadowing names.
RESERVED_VERBS :: []string{"init", "index", "search", "catalog", "bench", "help"}

is_reserved_verb :: proc(s: string) -> bool {
	for v in RESERVED_VERBS do if s == v do return true
	return false
}

USAGE :: `doma — BM25 search over your code and docs, organised as named corpuses.

Usage:
  doma init [dir]                            write a starter .doma/catalog.ini
  doma <corpus> <query> [flags]              search a catalogued corpus
  doma <query> [flags]                       search the default corpus
  doma index [corpus] [flags]                build the corpus index(es)
  doma catalog [add <name> <path> ...]       list corpuses, or add one
  doma search <query> [dir] [flags]          ad-hoc search of a path (no catalog)
  doma bench [dir] [--files n]               run the benchmark
  doma help                                  show this message

index flags:
  --jobs <n>       build threads (default: hardware threads)
  --no-gitignore   do not consult git check-ignore while walking
  --force          accepted, no-op (the index is a derived cache, always rebuilt)

search / query flags:
  --topk <n>   number of results (default 10)
  --json       one JSON object per line instead of the human format
  --verify     hash every indexed file instead of the cheap freshness gate

catalog add flags:
  --ext <list>       comma-separated extensions (default: md)
  --exclude <list>   comma-separated project-relative path prefixes to skip

ad-hoc search flags: --ext, --exclude, plus the search flags above.

Exit codes: 0 results, 1 no results, 2 error.
`

// run returns the process exit code. Called from the root main so tests can call it too.
run :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.eprint(USAGE)
		return 2
	}

	// 1. Verbs that do not need an existing catalog.
	switch args[1] {
	case "init":
		return cmd_init(args)
	case "search":
		return cmd_search(args)
	case "bench":
		return cmd_bench(args)
	case "help", "-h", "--help":
		fmt.print(USAGE)
		return 0
	}

	// Everything else — index, catalog, a corpus name, or a default query — needs a catalog.
	// Resolve the project root and load it once, here.
	root, has_root := find_project_root(".")
	if !has_root {
		switch args[1] {
		case "index", "catalog":
			fmt.eprintfln("doma %s: no catalog found — run `doma init` first", args[1])
		case:
			fmt.eprintfln("doma: unknown command %q, and no catalog here — run `doma init` or use `doma search`", args[1])
		}
		return 2
	}
	cat, ok := load_catalog(root)
	if !ok {
		fmt.eprintfln("doma: cannot read %q", catalog_file_path(root))
		return 2
	}

	// 2. Remaining reserved verbs, now with root + catalog in hand.
	switch args[1] {
	case "index":
		return cmd_index(root, &cat, args)
	case "catalog":
		return cmd_catalog(root, &cat, args)
	}

	// 3 & 4. A corpus name, else the start of a default query.
	if find_corpus(&cat, args[1]) != nil {
		return cmd_query(root, &cat, args[1], args[2:]) // doma <corpus> <query...>
	}
	if cat.default_name == "" {
		fmt.eprintfln("doma: %q is not a corpus and no default is set — name a corpus or set [doma] default", args[1])
		return 2
	}
	return cmd_query(root, &cat, cat.default_name, args[1:]) // doma <query...> against default
}
