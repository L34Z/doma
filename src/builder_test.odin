package doma

// ## Changes
// - 2026-07-29: Tests for build_index and find_term (DESIGN.md §3).

import "core:testing"
import "core:slice"

@(test)
build_index_is_sorted_and_counted :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# Alpha\nzebra alpha zebra\n")},
		{relpath = "b.md", bytes = transmute([]u8)string("# Beta\nalpha beta\n")},
	}
	idx := build_index("proj", files)
	testing.expect_value(t, len(idx.files), 2)
	testing.expect_value(t, idx.total_chunks, u32(len(idx.chunks)))
	testing.expect(t, idx.total_chunks == 2, "one chunk per file heading")
	// a.md chunk tokenizes to {alpha, zebra, alpha, zebra} = 4; b.md to {beta, alpha, beta} = 3.
	testing.expect_value(t, idx.total_tokens, u64(7))

	// Terms sorted lexicographically.
	for i in 1 ..< len(idx.terms) {
		a := seg(&idx, idx.terms[i - 1].text)
		b := seg(&idx, idx.terms[i].text)
		testing.expect(t, a < b, "terms must be strictly sorted & deduped")
	}
	// "alpha" appears in both chunks -> 2 postings, sorted by chunk id.
	ti := find_term(&idx, "alpha")
	testing.expect(t, ti >= 0, "alpha present")
	tr := idx.terms[ti]
	testing.expect_value(t, tr.post_len, u32(2))
	p := idx.postings[tr.post_off:tr.post_off + tr.post_len]
	testing.expect(t, p[0].chunk < p[1].chunk, "postings sorted by chunk id")
	// "zebra" has tf 2 in chunk a.
	zi := find_term(&idx, "zebra")
	zr := idx.terms[zi]
	testing.expect_value(t, idx.postings[zr.post_off].tf, u32(2))
}
