package doma

// ## Changes
// - 2026-08-01: `doma init` — write a starter .doma/catalog.ini (detect code languages and
//   a docs/ dir) and make sure /.doma/*.idx is gitignored. The catalog is committed; the
//   built indexes are a derived cache.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Programming-language extensions doma will offer as a `[code]` corpus at init time, in a
// fixed order so the generated catalog is deterministic. Config/data formats are omitted on
// purpose — `doma init` is a starting point the user edits, not an exhaustive scan.
@(private = "file")
CODE_EXTS :: []string{
	".odin", ".go", ".rs", ".zig", ".nim", ".c", ".h", ".cc", ".cpp", ".hpp",
	".cxx", ".hh", ".m", ".mm", ".py", ".rb", ".js", ".jsx", ".ts", ".tsx",
	".java", ".kt", ".swift", ".cs", ".php", ".lua", ".sh", ".ml", ".hs",
	".ex", ".exs", ".clj", ".scala", ".sql",
}

GITIGNORE_LINE :: "/.doma/*.idx"

cmd_init :: proc(args: []string) -> int {
	dir := "."
	force := false
	positional := 0
	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--force":
			force = true
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma init: unknown flag %q", a)
			return 2
		case:
			if positional > 0 {
				fmt.eprintln("doma init: expected at most one <dir>")
				return 2
			}
			dir = a
			positional += 1
		}
		i += 1
	}

	root, aerr := filepath.abs(dir)
	if aerr != nil {
		fmt.eprintfln("doma init: cannot resolve %q", dir)
		return 2
	}

	cat_path := catalog_file_path(root)
	if os.exists(cat_path) && !force {
		fmt.eprintfln("doma init: %q already exists (use --force to overwrite)", cat_path)
		return 2
	}

	code_exts := detect_code_exts(root)
	docs_path, _ := filepath.join({root, "docs"})
	has_docs := os.is_dir(docs_path)
	content := render_catalog(code_exts, has_docs)

	doma_dir, _ := filepath.join({root, CATALOG_DIR})
	if !os.exists(doma_dir) {
		if merr := os.make_directory(doma_dir); merr != nil {
			fmt.eprintfln("doma init: cannot create %q", doma_dir)
			return 2
		}
	}
	if werr := os.write_entire_file(cat_path, transmute([]u8)content); werr != nil {
		fmt.eprintfln("doma init: cannot write %q", cat_path)
		return 2
	}
	ensure_gitignore(root)

	fmt.eprintfln("doma: wrote %q — edit it, then run `doma index`", cat_path)
	return 0
}

// render_catalog builds the starter catalog text. `[code]` always exists (falling back to
// Markdown when no code is detected, so a docs-only tree still answers `doma <query>`);
// `[docs]` is added only when a docs/ directory is present.
@(private = "file")
render_catalog :: proc(code_exts: []string, has_docs: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# doma catalog — each [section] names a corpus: a filtered view of the tree.\n")
	strings.write_string(&b, "# path is project-root-relative; ext is a comma list (default: md);\n")
	strings.write_string(&b, "# exclude is a comma list of path prefixes. Query with `doma <name> <query>`.\n\n")
	strings.write_string(&b, "[doma]\ndefault = code\n\n")

	strings.write_string(&b, "[code]\npath = .\n")
	if len(code_exts) > 0 {
		// Strip the leading dot for a readable `ext = odin, go` line.
		bare := make([]string, len(code_exts), allocator)
		for e, k in code_exts do bare[k] = strings.trim_prefix(e, ".")
		fmt.sbprintf(&b, "ext = %s\n", strings.join(bare, ", ", allocator))
	} else {
		strings.write_string(&b, "ext = md\n")
	}
	if has_docs do strings.write_string(&b, "exclude = docs\n")

	if has_docs {
		strings.write_string(&b, "\n[docs]\npath = docs\n")
	}
	return strings.to_string(b)
}

// detect_code_exts returns the CODE_EXTS present anywhere under root, in allowlist order
// (deterministic). Dot-dirs and SKIP_DIRS are pruned so vendored/hidden trees don't count.
@(private = "file")
detect_code_exts :: proc(root: string, allocator := context.allocator) -> []string {
	present := make(map[string]bool, allocator)
	scan_exts(root, &present, allocator)
	out := make([dynamic]string, allocator)
	for e in CODE_EXTS do if present[e] do append(&out, e)
	return out[:]
}

@(private = "file")
scan_exts :: proc(dir: string, present: ^map[string]bool, a: runtime.Allocator) {
	f, err := os.open(dir)
	if err != nil do return
	defer os.close(f)
	infos, rerr := os.read_dir(f, -1, a)
	if rerr != nil do return
	for info in infos {
		if info.type == .Directory {
			if skip_dir(info.name) do continue
			scan_exts(info.fullpath, present, a)
		} else {
			ext := strings.to_lower(filepath.ext(info.name), a)
			if len(ext) > 0 do present[ext] = true
		}
	}
}

// ensure_gitignore appends GITIGNORE_LINE to <root>/.gitignore unless it is already there,
// so built indexes stay out of version control while catalog.ini stays in it.
@(private = "file")
ensure_gitignore :: proc(root: string) {
	gi_path, _ := filepath.join({root, ".gitignore"})
	existing, _ := os.read_entire_file(gi_path, context.allocator)
	for line in strings.split_lines(string(existing), context.allocator) {
		if strings.trim_space(line) == GITIGNORE_LINE do return // already ignored
	}
	b := strings.builder_make(context.allocator)
	strings.write_string(&b, string(existing))
	if len(existing) > 0 && existing[len(existing) - 1] != '\n' do strings.write_byte(&b, '\n')
	strings.write_string(&b, GITIGNORE_LINE)
	strings.write_byte(&b, '\n')
	_ = os.write_entire_file(gi_path, transmute([]u8)strings.to_string(b))
}
