package doma

// ## Changes
// - 2026-07-29: `doma index` — atomic temp-file+rename write.
// - 2026-07-29: Wire --jobs to build_index_jobs (threaded per-file build).
// - 2026-08-01: Catalog-driven. `doma index [corpus]` builds every corpus (or one named)
//   from .doma/catalog.ini into .doma/<corpus>.idx, honouring per-corpus excludes and
//   .gitignore. The corpus name is the first breadcrumb crumb.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// cmd_index builds corpus indexes. `root` is the resolved project root and `cat` its
// parsed catalog (both supplied by cli.run, which owns root resolution).
cmd_index :: proc(root: string, cat: ^Catalog, args: []string) -> int {
	only := "" // build just this corpus when set
	jobs := 0
	use_gitignore := true
	positional := 0
	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--force": // derived cache; rebuild always allowed. Accepted, no-op.
		case a == "--no-gitignore":
			use_gitignore = false
		case a == "--jobs":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma index: --jobs needs a number")
				return 2
			}
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				fmt.eprintfln("doma index: bad --jobs %q", args[i])
				return 2
			}
			jobs = n
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma index: unknown flag %q", a)
			return 2
		case:
			if positional > 0 {
				fmt.eprintln("doma index: expected at most one <corpus>")
				return 2
			}
			only = a
			positional += 1
		}
		i += 1
	}

	// Select which corpuses to build: one named, or all (already name-sorted).
	targets := make([dynamic]Corpus, context.allocator)
	if only != "" {
		c := find_corpus(cat, only)
		if c == nil {
			fmt.eprintfln("doma index: no corpus named %q in the catalog", only)
			return 2
		}
		append(&targets, c^)
	} else {
		append(&targets, ..cat.corpuses)
	}
	if len(targets) == 0 {
		fmt.eprintln("doma index: catalog has no corpuses")
		return 2
	}

	for corpus in targets {
		if code := build_corpus(root, corpus, jobs, use_gitignore); code != 0 do return code
	}
	return 0
}

// build_corpus collects, indexes, and atomically writes one corpus's index to
// .doma/<name>.idx. The corpus name is the index basename (first breadcrumb crumb).
@(private = "file")
build_corpus :: proc(root: string, corpus: Corpus, jobs: int, use_gitignore: bool) -> int {
	corpus_dir, _ := filepath.join({root, corpus.path})
	files, ok := collect_files(corpus_dir, Collect_Opts{
		exts          = corpus.exts,
		exclude       = corpus.exclude,
		use_gitignore = use_gitignore,
		project_root  = root,
	})
	if !ok {
		fmt.eprintfln("doma index: cannot read corpus %q at %q", corpus.name, corpus_dir)
		return 2
	}

	idx := build_index_jobs(corpus.name, files, jobs)
	bytes := write_index(&idx)

	// The index lives beside catalog.ini in .doma/; make sure the dir exists (it normally
	// does, since catalog.ini is in it) before the atomic temp+rename.
	doma_dir, _ := filepath.join({root, CATALOG_DIR})
	os.make_directory(doma_dir)

	final := corpus_index_path(root, corpus.name)
	tmp := fmt.tprintf("%s.tmp", final)
	if werr := os.write_entire_file(tmp, bytes); werr != nil {
		fmt.eprintfln("doma index: cannot write %q", tmp)
		return 2
	}
	if rerr := os.rename(tmp, final); rerr != nil {
		fmt.eprintfln("doma index: cannot rename into %q", final)
		return 2
	}
	fmt.eprintfln("doma: indexed %q — %d chunks from %d files", corpus.name, idx.total_chunks, len(files))
	return 0
}

// parse_exts turns a `--ext` argument like "go, .rs,PY" into a normalized, deduped set
// of dot-prefixed lowercase extensions: {".go", ".rs", ".py"}. Blank entries are
// dropped. Order follows first appearance so the result is deterministic.
parse_exts :: proc(arg: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in strings.split(arg, ",", allocator) {
		e := strings.to_lower(strings.trim_space(part), allocator)
		if len(e) == 0 do continue
		if e[0] != '.' do e = strings.concatenate({".", e}, allocator)
		if e == "." do continue // a lone dot has no extension to match
		seen := false
		for existing in out do if existing == e { seen = true; break }
		if !seen do append(&out, e)
	}
	return out[:]
}
