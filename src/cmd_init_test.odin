package doma

// ## Changes
// - 2026-08-01: `doma init` writes a usable catalog (detected code + docs) and gitignores
//   the built indexes; re-running without --force refuses.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
cmd_init_writes_usable_catalog :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_init"})
	defer os.remove_all(root)
	os.make_directory(root)

	// A code file and a docs/ dir so init detects both.
	src_path, _ := filepath.join({root, "main.odin"})
	_ = os.write_entire_file(src_path, transmute([]u8)string("package p\n"))
	docs_dir, _ := filepath.join({root, "docs"})
	os.make_directory(docs_dir)
	doc_path, _ := filepath.join({docs_dir, "guide.md"})
	_ = os.write_entire_file(doc_path, transmute([]u8)string("# Guide\n"))

	testing.expect_value(t, cmd_init([]string{"doma", "init", root}), 0)

	cat, ok := load_catalog(root)
	testing.expect(t, ok, "catalog loads after init")
	testing.expect_value(t, cat.default_name, "code")

	code := find_corpus(&cat, "code")
	testing.expect(t, code != nil, "code corpus present")
	testing.expect(t, slice_contains(code.exts, ".odin"), "detected .odin")
	testing.expect(t, find_corpus(&cat, "docs") != nil, "docs corpus present")

	// Built indexes are gitignored; catalog.ini is not.
	gi, _ := filepath.join({root, ".gitignore"})
	gi_data, _ := os.read_entire_file(gi, context.temp_allocator)
	testing.expect(t, strings.contains(string(gi_data), GITIGNORE_LINE), "index glob gitignored")

	// Re-init without --force refuses.
	testing.expect_value(t, cmd_init([]string{"doma", "init", root}), 2)
	// With --force it succeeds.
	testing.expect_value(t, cmd_init([]string{"doma", "init", root, "--force"}), 0)
}

@(private = "file")
slice_contains :: proc(xs: []string, want: string) -> bool {
	for x in xs do if x == want do return true
	return false
}
