package doma

// ## Changes
// - 2026-07-29: Tests for cmd_index command.
// - 2026-08-01: parse_exts normalization plus catalog-driven index tests. cmd_index now
//   takes (root, cat, args); tests construct a Catalog pointing at a temp tree.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

@(test)
parse_exts_normalizes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Dots optional, case-folded, whitespace trimmed, blanks and lone dots dropped, deduped.
	got := parse_exts("go, .RS ,py,,go,.,md")
	testing.expect(t, slice.equal(got, []string{".go", ".rs", ".py", ".md"}), "unexpected normalization")

	testing.expect_value(t, len(parse_exts("")), 0)
	testing.expect_value(t, len(parse_exts(" , , ")), 0)
}

// read_corpus_index loads the index cmd_index wrote for a corpus.
@(private = "file")
read_corpus_index :: proc(t: ^testing.T, root, name: string) -> (Index, bool) {
	data, rerr := os.read_entire_file(corpus_index_path(root, name), context.temp_allocator)
	if rerr != nil {
		return {}, false
	}
	return read_index(data)
}

@(test)
cmd_index_builds_code_corpus :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "get temp dir")
	root, _ := filepath.join({tmp_dir, "doma_idx_code"})
	defer os.remove_all(root)
	os.make_directory(root)
	src_path, _ := filepath.join({root, "sample.odin"})
	_ = os.write_entire_file(src_path, transmute([]u8)string("package p\n\nwidget :: proc() {\n\treturn\n}\n"))
	// A .md sibling must be ignored when the corpus is odin-only.
	md_path, _ := filepath.join({root, "readme.md"})
	_ = os.write_entire_file(md_path, transmute([]u8)string("# Doc\nprose\n"))

	cat := Catalog{
		root         = root,
		corpuses     = []Corpus{{name = "code", path = ".", exts = {".odin"}}},
		default_name = "code",
	}
	testing.expect_value(t, cmd_index(root, &cat, []string{"doma", "index"}), 0)

	idx, ok := read_corpus_index(t, root, "code")
	testing.expect(t, ok, "code.idx parses")
	testing.expect(t, find_term(&idx, "widget") >= 0, "code identifier indexed")
	testing.expect(t, find_term(&idx, "prose") < 0, "markdown file excluded by ext")
}

@(test)
cmd_index_unknown_corpus_is_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cat := Catalog{
		root         = "/tmp/doma_nonexistent",
		corpuses     = []Corpus{{name = "code", path = ".", exts = {".odin"}}},
		default_name = "code",
	}
	testing.expect_value(t, cmd_index("/tmp/doma_nonexistent", &cat, []string{"doma", "index", "ghost"}), 2)
}
