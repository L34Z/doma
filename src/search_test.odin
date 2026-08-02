package doma

// ## Changes
// - 2026-07-29: Tests for BM25 search (DESIGN.md §5).

import "core:testing"

@(test)
search_ranks_and_breaks_ties :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# Alpha\nzebra zebra needle\n")},
		{relpath = "b.md", bytes = transmute([]u8)string("# Beta\nneedle\n")},
		{relpath = "c.md", bytes = transmute([]u8)string("# Gamma\nunrelated words only\n")},
	}
	idx := build_index("proj", files)
	idx.corpus = "."
	loaded := []Loaded{{idx = idx, corpus = "."}}

	hits := search(loaded, "needle", 10)
	testing.expect_value(t, len(hits), 2) // gamma has no "needle"
	// Both contain "needle" once; shorter chunk (Beta) scores higher via BM25 length norm.
	testing.expect(t, hits[0].score >= hits[1].score, "sorted by score desc")
	testing.expect(t, breadcrumb_of(hits[0].idx, hits[0].chunk) != "", "breadcrumb builds from a hit")

	// A query term absent from every index contributes nothing (no crash, no hits added).
	none := search(loaded, "absentterm", 10)
	testing.expect_value(t, len(none), 0)
}

// Bounded top-k: only the k highest-scoring chunks survive, in score order.
@(test)
search_bounds_topk :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Longer chunks score lower under BM25 length norm, so "needle" repeated across
	// files of growing length gives three distinct, decreasing scores.
	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# A\nneedle\n")},
		{relpath = "b.md", bytes = transmute([]u8)string("# B\nneedle pad pad\n")},
		{relpath = "c.md", bytes = transmute([]u8)string("# C\nneedle pad pad pad pad\n")},
	}
	idx := build_index("proj", files)
	idx.corpus = "."
	loaded := []Loaded{{idx = idx, corpus = "."}}

	hits := search(loaded, "needle", 2)
	testing.expect_value(t, len(hits), 2) // three candidates, k=2 kept
	testing.expect(t, hits[0].score > hits[1].score, "kept the two highest, in order")

	all := search(loaded, "needle", 10)
	testing.expect(t, hits[1].score >= all[2].score, "the dropped hit ranks no higher than the kept")
}

// Exact-score ties break by the cheap key (corpus, file id, chunk start), deterministically.
@(test)
search_tie_break_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Identical chunk bodies -> identical BM25 scores -> a pure tie.
	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# A\nneedle\n")},
		{relpath = "b.md", bytes = transmute([]u8)string("# B\nneedle\n")},
	}
	idx := build_index("proj", files)
	idx.corpus = "."
	loaded := []Loaded{{idx = idx, corpus = "."}}

	h1 := search(loaded, "needle", 10)
	h2 := search(loaded, "needle", 10)
	testing.expect_value(t, len(h1), 2)
	testing.expect(t, h1[0].score == h1[1].score, "constructed a score tie")
	// Same input, same order every run; tie ordered by ascending file id.
	testing.expect(t, h1[0].chunk == h2[0].chunk && h1[1].chunk == h2[1].chunk, "stable across runs")
	c0 := h1[0].idx.chunks[h1[0].chunk]; c1 := h1[1].idx.chunks[h1[1].chunk]
	testing.expect(t, c0.file < c1.file, "tie broken by ascending file id")
}
