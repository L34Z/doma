package doma

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// ## Changes
// - 2026-07-29: Markdown heading chunker tests (Task 4).
//   Tests chunk_markdown for ATX headings, setext headings, fence detection,
//   and proper breadcrumb nesting per heading levels.
// - 2026-07-29: Added chunk_sibling_headings_keep_parent_contiguous to guard against
//   sibling same-level headings splitting the parent chunk's range (regression test).
// - 2026-08-01: Code chunker tests (chunk_code): top-level definition boundaries,
//   full-file coverage/contiguity, comments & closing braces not opening, whole-file
//   fallback, UTF-8-safe signature truncation, and is_markdown_path dispatch.

// expect_contiguous asserts chunks tile [0, total) with no gaps or overlaps: the first
// starts at 0, each begins where the previous ended, and the last ends at total.
@(private = "file")
expect_contiguous :: proc(t: ^testing.T, cs: []Raw_Chunk, total: int) {
	testing.expect(t, len(cs) > 0, "expected at least one chunk")
	testing.expect_value(t, cs[0].start, 0)
	for i in 1 ..< len(cs) do testing.expect_value(t, cs[i].start, cs[i - 1].end)
	testing.expect_value(t, cs[len(cs) - 1].end, total)
}

@(test)
chunk_code_splits_top_level :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("package doma\n\nimport \"core:fmt\"\n\nfoo :: proc() {\n\tx := 1\n}\n\nbar :: proc() {\n\ty := 2\n}\n")
	cs := chunk_code(src, "pkg", "a.odin")

	// Openers: package, import, foo, bar. Indented bodies and lone `}` do not open.
	testing.expect_value(t, len(cs), 4)
	expect_contiguous(t, cs, len(src))

	testing.expect_value(t, cs[0].crumbs[len(cs[0].crumbs) - 1], "package doma")
	testing.expect_value(t, cs[1].crumbs[len(cs[1].crumbs) - 1], "import \"core:fmt\"")
	// Trailing " {" is stripped from the signature label.
	testing.expect_value(t, cs[2].crumbs[len(cs[2].crumbs) - 1], "foo :: proc()")
	testing.expect_value(t, cs[3].crumbs[len(cs[3].crumbs) - 1], "bar :: proc()")
	// Definition crumbs carry [basename, relpath, signature].
	testing.expect_value(t, len(cs[2].crumbs), 3)
	testing.expect_value(t, cs[2].crumbs[0], "pkg")
	testing.expect_value(t, cs[2].crumbs[1], "a.odin")
}

@(test)
chunk_code_comments_and_braces_do_not_open :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// A leading comment can't open, so it becomes the preamble; the def opens after it.
	src := transmute([]u8)string("// header comment\nfoo :: proc() {\n}\n")
	cs := chunk_code(src, "p", "f.odin")

	testing.expect_value(t, len(cs), 2)
	expect_contiguous(t, cs, len(src))
	testing.expect_value(t, len(cs[0].crumbs), 2) // preamble: just [basename, relpath]
	testing.expect_value(t, cs[1].crumbs[len(cs[1].crumbs) - 1], "foo :: proc()")
}

@(test)
chunk_code_whole_file_when_no_opener :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Everything indented: no column-0 opener, so the whole file is one chunk.
	src := transmute([]u8)string("\tindented only\n  more indented\n")
	cs := chunk_code(src, "p", "f.odin")

	testing.expect_value(t, len(cs), 1)
	expect_contiguous(t, cs, len(src))
	testing.expect_value(t, len(cs[0].crumbs), 2)
}

@(test)
chunk_code_signature_truncates_on_rune_boundary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// 79 ASCII bytes then a 2-byte rune straddling the 80-byte cap: the cut must land
	// before the rune, never inside it, so the crumb stays valid UTF-8.
	line := strings.concatenate({strings.repeat("a", 79), "é :: 1\n"})
	cs := chunk_code(transmute([]u8)line, "p", "f.odin")

	testing.expect_value(t, len(cs), 1)
	sig := cs[0].crumbs[len(cs[0].crumbs) - 1]
	testing.expect(t, len(sig) <= CODE_CRUMB_MAX, "signature must respect the byte cap")
	testing.expect(t, utf8.valid_string(sig), "truncated signature must be valid UTF-8")
}

@(test)
markdown_path_routes_to_chunker :: proc(t: ^testing.T) {
	testing.expect(t, is_markdown_path("a.md"), ".md is markdown")
	testing.expect(t, is_markdown_path("dir/b.markdown"), ".markdown is markdown")
	testing.expect(t, !is_markdown_path("c.odin"), ".odin is not markdown")
	testing.expect(t, !is_markdown_path("Makefile"), "no extension is not markdown")
}

@(test)
chunk_preamble_and_headings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("intro text\n# Title\nbody\n## Sub\nmore\n# Two\nend\n")
	cs := chunk_markdown(src, "guide", "doc.md")
	// preamble, h1 Title (spans through its Sub per equal-or-higher rule), h2 Sub, h1 Two
	testing.expect_value(t, len(cs), 4)
	// preamble: empty heading trail -> just [basename, relpath]
	testing.expect_value(t, len(cs[0].crumbs), 2)
	testing.expect_value(t, cs[0].crumbs[0], "guide")
	testing.expect_value(t, cs[0].crumbs[1], "doc.md")
	// h1 chunk breadcrumb ends in "Title"
	testing.expect_value(t, cs[1].crumbs[len(cs[1].crumbs) - 1], "Title")
	// h2 "Sub" nests under Title: [guide, doc.md, Title, Sub]
	testing.expect_value(t, len(cs[3-1].crumbs), 4)
	testing.expect_value(t, cs[2].crumbs[3], "Sub")
	// h1 "Title" runs until next equal-or-higher heading "# Two"
	title_start := cs[1].start
	two_start := cs[3].start
	testing.expect(t, cs[1].end == two_start, "h1 chunk ends at next h1")
	testing.expect(t, title_start < cs[2].start, "h2 starts after h1 heading line")
}

@(test)
chunk_ignores_headings_in_fences :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("# Real\n```\n# not a heading\n```\ntail\n")
	cs := chunk_markdown(src, "g", "f.md")
	testing.expect_value(t, len(cs), 1) // only "# Real"
	testing.expect_value(t, cs[0].crumbs[len(cs[0].crumbs) - 1], "Real")
}

@(test)
chunk_sibling_headings_keep_parent_contiguous :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// # H1\n## A\n## B\n# H2\n
	// Byte map: H1=0, ## A=5, ## B=10, # H2=15, EOF=20
	src := transmute([]u8)string("# H1\n## A\n## B\n# H2\n")
	cs := chunk_markdown(src, "g", "f.md")
	// Order must be document order: H1, A, B, H2
	testing.expect_value(t, len(cs), 4)

	// cs[0] = H1: single contiguous chunk reaching H2's start.
	testing.expect_value(t, cs[0].crumbs[len(cs[0].crumbs) - 1], "H1")
	testing.expect_value(t, len(cs[0].crumbs), 3)
	testing.expect_value(t, cs[0].start, 0)
	testing.expect_value(t, cs[0].end, 15) // == H2.start

	// cs[1] = A (h2 under H1)
	testing.expect_value(t, len(cs[1].crumbs), 4)
	testing.expect_value(t, cs[1].crumbs[3], "A")
	testing.expect_value(t, cs[1].start, 5)
	testing.expect_value(t, cs[1].end, 10) // == B.start

	// cs[2] = B (h2 under H1), distinct from A
	testing.expect_value(t, len(cs[2].crumbs), 4)
	testing.expect_value(t, cs[2].crumbs[3], "B")
	testing.expect_value(t, cs[2].start, 10)
	testing.expect_value(t, cs[2].end, 15) // == H2.start

	// cs[3] = H2
	testing.expect_value(t, cs[3].crumbs[len(cs[3].crumbs) - 1], "H2")
	testing.expect_value(t, len(cs[3].crumbs), 3)
	testing.expect_value(t, cs[3].start, 15)
	testing.expect_value(t, cs[3].end, 20) // EOF

	// H1 must be a SINGLE chunk: only one chunk has "H1" as last crumb.
	h1_count := 0
	for i := 0; i < len(cs); i += 1 {
		if cs[i].crumbs[len(cs[i].crumbs) - 1] == "H1" do h1_count += 1
	}
	testing.expect_value(t, h1_count, 1)
}

@(test)
chunk_setext_maps_to_h1_h2 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("Title\n=====\nbody\nSub\n---\nmore\n")
	cs := chunk_markdown(src, "g", "f.md")
	testing.expect_value(t, len(cs), 2)
	testing.expect_value(t, cs[0].crumbs[len(cs[0].crumbs) - 1], "Title") // setext h1
	testing.expect_value(t, len(cs[1].crumbs), 4)                        // Sub nests under Title
	testing.expect_value(t, cs[1].crumbs[3], "Sub")
}
