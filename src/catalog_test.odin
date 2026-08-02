package doma

// ## Changes
// - 2026-08-01: Catalog parsing/resolution tests — INI -> sorted []Corpus, default
//   resolution, ext/exclude parsing, and the markdown-ext fallback.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

// write_catalog creates <root>/.doma/catalog.ini with `body`.
@(private = "file")
write_catalog :: proc(root, body: string) {
	doma_dir, _ := filepath.join({root, CATALOG_DIR})
	os.make_directory(root)
	os.make_directory(doma_dir)
	_ = os.write_entire_file(catalog_file_path(root), transmute([]u8)body)
}

@(test)
load_catalog_parses_sorts_resolves :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_cat_parse"})
	defer os.remove_all(root)
	write_catalog(root,
		"[doma]\ndefault = docs\n\n" +
		"[code]\npath = .\next = odin, go\nexclude = docs, vendor\n\n" +
		"[docs]\npath = docs\n")

	cat, ok := load_catalog(root)
	testing.expect(t, ok, "catalog loads")
	// Sorted by name: code, docs.
	testing.expect_value(t, len(cat.corpuses), 2)
	testing.expect_value(t, cat.corpuses[0].name, "code")
	testing.expect_value(t, cat.corpuses[1].name, "docs")
	// Declared default honoured.
	testing.expect_value(t, cat.default_name, "docs")

	code := find_corpus(&cat, "code")
	testing.expect(t, code != nil, "code corpus exists")
	testing.expect_value(t, code.path, ".")
	testing.expect(t, slice.equal(code.exts, []string{".odin", ".go"}), "code exts")
	testing.expect(t, slice.equal(code.exclude, []string{"docs", "vendor"}), "code exclude")

	// A corpus without `ext` defaults to Markdown.
	docs := find_corpus(&cat, "docs")
	testing.expect(t, docs != nil, "docs corpus exists")
	testing.expect(t, slice.equal(docs.exts, MARKDOWN_EXTS), "docs defaults to markdown exts")

	testing.expect(t, find_corpus(&cat, "ghost") == nil, "unknown corpus is nil")
}

@(test)
resolve_default_falls_back_to_code :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_cat_default"})
	defer os.remove_all(root)
	// No [doma] default declared; a corpus named "code" wins.
	write_catalog(root, "[docs]\npath = docs\n\n[code]\npath = .\next = rs\n")

	cat, ok := load_catalog(root)
	testing.expect(t, ok, "catalog loads")
	testing.expect_value(t, cat.default_name, "code")
}

@(test)
resolve_default_single_corpus :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_cat_single"})
	defer os.remove_all(root)
	// No default, no "code": the lone corpus becomes the default.
	write_catalog(root, "[notes]\npath = notes\n")

	cat, ok := load_catalog(root)
	testing.expect(t, ok, "catalog loads")
	testing.expect_value(t, cat.default_name, "notes")
}
