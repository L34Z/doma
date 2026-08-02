package doma

// ## Changes
// - 2026-07-29: Directory walk + skip rules; build an index from a dir (DESIGN.md §2, §7).
// - 2026-07-29: Resolve dir to absolute path in collect_markdown so filepath.rel works correctly for relative dir args (e.g. "."); check rel error; derive basename from absolute path.
// - 2026-08-01: Generalise the walk to an arbitrary extension set (collect_files); the
//   codebase itself becomes indexable via `doma index <dir> --ext go,rs,…`. Markdown
//   stays the default; is_markdown_path picks the chunker per file at build time.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

SKIP_DIRS :: []string{"node_modules", "vendor", "thirdparty"}

// Extensions routed to the Markdown chunker; everything else goes to the code chunker.
MARKDOWN_EXTS :: []string{".md", ".markdown"}

skip_dir :: proc(name: string) -> bool {
	if len(name) > 0 && name[0] == '.' do return true // dotted dirs (DESIGN.md §2)
	for s in SKIP_DIRS do if name == s do return true
	return false
}

// has_ext reports whether `name` ends in one of `exts` (each written with its dot, e.g.
// ".md"). Callers pass lowercased extensions; the name is matched case-sensitively, so
// pass whatever the platform convention is.
@(private = "file")
has_ext :: proc(name: string, exts: []string) -> bool {
	for e in exts do if strings.has_suffix(name, e) do return true
	return false
}

// is_markdown_path decides which chunker a file gets: Markdown by extension, else code.
is_markdown_path :: proc(relpath: string) -> bool {
	return has_ext(relpath, MARKDOWN_EXTS)
}

// Collect_Opts configures collect_files. `exts` are dot-prefixed extensions to match.
// `exclude` are project-root-relative path prefixes to skip. `use_gitignore` runs the
// candidates through `git check-ignore`. `project_root` (absolute) is the base for exclude
// matching and the git cwd; when "" it defaults to the corpus dir itself (ad-hoc use).
Collect_Opts :: struct {
	exts:          []string,
	exclude:       []string,
	use_gitignore: bool,
	project_root:  string,
}

// A file found by the path-gathering pass, before its bytes are read. `corpus_rel` is
// relative to the corpus dir (what the index stores); `proj_rel` is relative to the
// project root (what exclude and gitignore match against).
@(private = "file")
Candidate :: struct {
	abs:        string,
	corpus_rel: string,
	proj_rel:   string,
}

// collect_files gathers the source files of a corpus in three passes so ignored files are
// never read: (1) walk `dir` collecting matching paths, pruning dot-dirs/SKIP_DIRS and
// `exclude` prefixes; (2) drop gitignored paths via filter_gitignored; (3) read the
// survivors' bytes. Output is relpath-sorted (relative to `dir`) for determinism.
collect_files :: proc(dir: string, opts: Collect_Opts, allocator := context.allocator) -> ([]Src_File, bool) {
	// Resolve to absolute so filepath.rel is well-defined even for a relative dir like ".".
	dir_abs, abs_err := filepath.abs(dir, allocator)
	if abs_err != nil do return nil, false
	root_abs := opts.project_root
	if root_abs == "" do root_abs = dir_abs

	// Pass 1: gather candidate paths, no content reads.
	cands := make([dynamic]Candidate, allocator)
	if !gather_paths(root_abs, dir_abs, dir_abs, opts.exts, opts.exclude, &cands, allocator) {
		return nil, false
	}

	// Pass 2: drop gitignored candidates (project-relative paths, git cwd = project root).
	if opts.use_gitignore && len(cands) > 0 {
		proj := make([]string, len(cands), allocator)
		for c, i in cands do proj[i] = c.proj_rel
		kept := filter_gitignored(root_abs, proj, allocator)
		if len(kept) != len(cands) {
			keep := make(map[string]bool, allocator)
			for k in kept do keep[k] = true
			filtered := make([dynamic]Candidate, allocator)
			for c in cands do if keep[c.proj_rel] do append(&filtered, c)
			cands = filtered
		}
	}

	// Pass 3: read the survivors' bytes.
	out := make([dynamic]Src_File, allocator)
	for c in cands {
		bytes, rerr := os.read_entire_file(c.abs, allocator)
		if rerr != nil do return nil, false
		append(&out, Src_File{relpath = c.corpus_rel, bytes = bytes})
	}
	slice.sort_by(out[:], proc(a, b: Src_File) -> bool { return a.relpath < b.relpath })
	return out[:], true
}

// collect_markdown gathers *.md under dir — the default corpus. Thin wrapper over
// collect_files kept for the callers and tests that only ever want Markdown (no excludes,
// no gitignore — behaviour identical to before the corpus work).
collect_markdown :: proc(dir: string, allocator := context.allocator) -> ([]Src_File, bool) {
	return collect_files(dir, Collect_Opts{exts = {".md"}}, allocator)
}

// is_excluded reports whether `rel` (a project-relative path) is at or under any exclude
// prefix. Matching is on path boundaries: "docs" excludes "docs" and "docs/x", not "docsy".
@(private = "file")
is_excluded :: proc(rel: string, exclude: []string) -> bool {
	for ex in exclude {
		e := strings.trim_right(ex, "/")
		if len(e) == 0 do continue
		if rel == e do return true
		if len(rel) > len(e) && rel[len(e)] == '/' && strings.has_prefix(rel, e) do return true
	}
	return false
}

@(private = "file")
gather_paths :: proc(root_abs, dir_start, dir: string, exts, exclude: []string, out: ^[dynamic]Candidate, a: runtime.Allocator) -> bool {
	f, err := os.open(dir)
	if err != nil do return false
	defer os.close(f)
	infos, rerr := os.read_dir(f, -1, a)
	if rerr != nil do return false
	// Sort entries so recursion order is deterministic regardless of FS order.
	slice.sort_by(infos, proc(x, y: os.File_Info) -> bool { return x.name < y.name })
	for info in infos {
		proj_rel, prerr := filepath.rel(root_abs, info.fullpath, a)
		if prerr != .None do return false
		if is_excluded(proj_rel, exclude) do continue
		if info.type == .Directory {
			if skip_dir(info.name) do continue
			if !gather_paths(root_abs, dir_start, info.fullpath, exts, exclude, out, a) do return false
		} else if has_ext(info.name, exts) {
			corpus_rel, crerr := filepath.rel(dir_start, info.fullpath, a)
			if crerr != .None do return false
			append(out, Candidate{
				abs        = strings.clone(info.fullpath, a),
				corpus_rel = corpus_rel,
				proj_rel   = proj_rel,
			})
		}
	}
	return true
}

build_index_from_dir :: proc(dir: string, allocator := context.allocator) -> (Index, bool) {
	// Resolve to absolute so basename is the real directory name, not "." or "..".
	dir_abs, abs_err := filepath.abs(dir, allocator)
	if abs_err != nil do return {}, false
	files, ok := collect_markdown(dir, allocator)
	if !ok do return {}, false
	// Linux-only per project target: trailing separator is "/" (DESIGN.md).
	base := filepath.base(strings.trim_right(dir_abs, "/"))
	return build_index(base, files, allocator), true
}
