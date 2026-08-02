package doma

// ## Changes
// - 2026-07-29: `doma search` — discovery, BM25, snippets, human/JSON output (DESIGN.md §6).
// - 2026-08-01: Now the ad-hoc, catalog-independent path: build an ephemeral in-memory index
//   of a directory and search it (nothing written). Corpus queries (`doma <corpus> <query>`)
//   go through cmd_query against a prebuilt index. `--in` is gone (use corpus names);
//   `--ext`/`--exclude` scope the ad-hoc walk. render_hits is shared with cmd_query.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

cmd_search :: proc(args: []string) -> int {
	query      := ""
	dir        := "."
	exts       := []string{".md"} // ad-hoc default corpus is Markdown; --ext for code
	exclude:   []string
	topk       := 10
	as_json    := false
	positional := 0
	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--json":
			as_json = true
		case a == "--ext":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma search: --ext needs a comma-separated list")
				return 2
			}
			e := parse_exts(args[i])
			if len(e) == 0 {
				fmt.eprintfln("doma search: no usable extensions in %q", args[i])
				return 2
			}
			exts = e
		case a == "--exclude":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma search: --exclude needs a comma-separated list")
				return 2
			}
			exclude = split_arg_list(args[i])
		case a == "--topk":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma search: --topk needs a number")
				return 2
			}
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				fmt.eprintfln("doma search: bad --topk %q", args[i])
				return 2
			}
			topk = n
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma search: unknown flag %q", a)
			return 2
		case:
			switch positional {
			case 0:
				query = a
			case 1:
				dir = a
			case:
				fmt.eprintln("doma search: too many arguments")
				return 2
			}
			positional += 1
		}
		i += 1
	}
	if query == "" {
		fmt.eprintln("usage: doma search <query> [dir] [--ext list] [--exclude list] [--topk n] [--json]")
		return 2
	}

	dir_abs, aerr := filepath.abs(dir)
	if aerr != nil {
		fmt.eprintfln("doma search: cannot resolve %q", dir)
		return 2
	}
	files, ok := collect_files(dir, Collect_Opts{
		exts          = exts,
		exclude       = exclude,
		use_gitignore = true,
		project_root  = dir_abs,
	})
	if !ok {
		fmt.eprintfln("doma search: cannot read %q", dir)
		return 2
	}
	base := filepath.base(strings.trim_right(dir_abs, "/"))
	idx := build_index_jobs(base, files, 0)
	idx.corpus = base
	loaded := []Loaded{{idx = idx, corpus = base}}

	q_toks := tokenize(transmute([]u8)query)
	q_terms := make([]string, len(q_toks))
	for tk, k in q_toks do q_terms[k] = tk.text

	hits := search(loaded, query, topk)
	if len(hits) == 0 {
		fmt.eprintfln("doma search: no matches for %q", query)
		return 1
	}
	render_hits(hits, dir_abs, q_terms, as_json)
	return 0
}

// split_arg_list splits "a, b ,c" into {"a","b","c"} for --exclude. (parse_exts handles
// the extension-specific normalization; excludes are raw path prefixes.)
@(private = "file")
split_arg_list :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in strings.split(s, ",", allocator) {
		p := strings.trim_space(part)
		if len(p) > 0 do append(&out, p)
	}
	return out[:]
}

// render_hits prints ranked hits (human or JSON). `read_base` is the absolute directory a
// hit's stored relpath joins onto to read source for the snippet. Shared by ad-hoc search
// and corpus query. A file that can't be read is skipped, never a crash.
render_hits :: proc(hits: []Hit, read_base: string, q_terms: []string, as_json: bool) {
	for h, rank in hits {
		c    := h.idx.chunks[h.chunk]
		frec := h.idx.files[c.file]
		path := seg(h.idx, frec.path)
		full, _ := filepath.join({read_base, path})
		src, rerr := os.read_entire_file(full, context.temp_allocator)
		if rerr != nil {
			fmt.eprintfln("doma: cannot read %q — skipping", full)
			continue
		}
		snip  := snippet_of(src, c, q_terms)
		crumb := breadcrumb_of(h.idx, h.chunk, context.temp_allocator) // built for survivors only

		if as_json {
			fmt.println(render_json_line(h, path, crumb, snip, context.temp_allocator))
		} else {
			fmt.printfln("#%d  %.3f  %s", rank + 1, h.score, crumb)
			fmt.println(snip)
		}
	}
}

// render_json_line encodes one search hit as a single JSON object string.
// Single source of truth for the JSON format used by --json output and golden tests.
// Breadcrumb is passed in (built by the caller for survivors only), not read off Hit.
// Field order: score, corpus, path, breadcrumb, start, end, snippet.
render_json_line :: proc(h: Hit, path: string, breadcrumb: string, snip: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	c := h.idx.chunks[h.chunk]
	strings.write_string(&b, `{"score":`)
	strings.write_string(&b, fmt.aprintf("%.3f", h.score, allocator = allocator))
	strings.write_string(&b, `,"corpus":`)
	strings.write_string(&b, jstr(h.corpus, allocator))
	strings.write_string(&b, `,"path":`)
	strings.write_string(&b, jstr(path, allocator))
	strings.write_string(&b, `,"breadcrumb":`)
	strings.write_string(&b, jstr(breadcrumb, allocator))
	strings.write_string(&b, `,"start":`)
	strings.write_string(&b, fmt.aprintf("%d", c.start, allocator = allocator))
	strings.write_string(&b, `,"end":`)
	strings.write_string(&b, fmt.aprintf("%d", c.end, allocator = allocator))
	strings.write_string(&b, `,"snippet":`)
	strings.write_string(&b, jstr(snip, allocator))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// jstr JSON-encodes a string: returns a quoted, escaped JSON string literal.
// Uses json.marshal which calls io.write_quoted_string internally.
@(private = "file")
jstr :: proc(s: string, allocator := context.allocator) -> string {
	data, _ := json.marshal(s, allocator = allocator)
	return string(data)
}
