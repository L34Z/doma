package doma

// ## Changes
// - 2026-08-01: Corpus query — the ergonomic front door. `doma <corpus> <query>` (and the
//   default `doma <query>`) mmap the corpus's prebuilt .doma/<corpus>.idx, run the freshness
//   gate against the corpus directory, and search. mmap keeps a cold search paging in only
//   the term dict + touched postings, not the whole blob (perf record, commit 5abaead).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// cmd_query searches one catalogued corpus. `args` is everything after the corpus token
// (or the whole tail for a default query): positional words join into the query, plus the
// search flags. Refuses (exit 2) on a missing or stale index; 1 on no hits; 0 on hits.
cmd_query :: proc(root: string, cat: ^Catalog, corpus_name: string, args: []string) -> int {
	corpus := find_corpus(cat, corpus_name)
	assert(corpus != nil, "cmd_query called with a corpus the catalog does not contain")

	// Parse the tail: positionals form the query; flags tune output/freshness.
	qb := strings.builder_make(context.allocator)
	topk := 10
	as_json := false
	verify := false
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--json":
			as_json = true
		case a == "--verify":
			verify = true
		case a == "--topk":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma: --topk needs a number")
				return 2
			}
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				fmt.eprintfln("doma: bad --topk %q", args[i])
				return 2
			}
			topk = n
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma: unknown flag %q", a)
			return 2
		case:
			if strings.builder_len(qb) > 0 do strings.write_byte(&qb, ' ')
			strings.write_string(&qb, a)
		}
		i += 1
	}
	query := strings.to_string(qb)
	if query == "" {
		fmt.eprintfln("usage: doma %s <query> [--topk n] [--json] [--verify]", corpus_name)
		return 2
	}

	// mmap the prebuilt index (demand-paged); fall back to a plain read if it can't be mapped.
	idx_path := corpus_index_path(root, corpus.name)
	idx_c := strings.clone_to_cstring(idx_path, context.allocator)
	data, mok := mmap_file(idx_c)
	if !mok {
		if d, rerr := os.read_entire_file(idx_path, context.allocator); rerr == nil {
			data, mok = d, true
		}
	}
	if !mok {
		fmt.eprintfln("doma: corpus %q is not indexed — run `doma index`", corpus.name)
		return 2
	}
	idx, rok := read_index(data)
	if !rok {
		fmt.eprintfln("doma: corpus %q has an unreadable index — run `doma index`", corpus.name)
		return 2
	}

	// Freshness gate against the corpus directory; the index file's own mtime is the baseline.
	corpus_dir, _ := filepath.join({root, corpus.path})
	reason := verify_index(&idx, corpus_dir, file_mtime(idx_c), verify, context.allocator)
	if reason != "" {
		fmt.eprintfln("doma: corpus %q is stale (%s) — re-run `doma index`", corpus.name, reason)
		return 2
	}

	idx.corpus = corpus.name
	loaded := []Loaded{{idx = idx, corpus = corpus.name}}

	q_toks := tokenize(transmute([]u8)query)
	q_terms := make([]string, len(q_toks))
	for tk, k in q_toks do q_terms[k] = tk.text

	hits := search(loaded, query, topk)
	if len(hits) == 0 {
		fmt.eprintfln("doma: no matches for %q in corpus %q", query, corpus.name)
		return 1
	}
	render_hits(hits, corpus_dir, q_terms, as_json)
	return 0
}
