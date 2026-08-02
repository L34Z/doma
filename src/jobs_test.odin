package doma

// ## Changes
// - 2026-07-29: Determinism invariant — write_index output is byte-identical for any --jobs value.

import "core:slice"
import "core:testing"

@(test)
jobs_invariant_same_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := gen_fixture_tree(99, 40)
	slice.sort_by(files, proc(a, b: Src_File) -> bool { return a.relpath < b.relpath })

	idx1 := build_index_jobs("fx", files, 1)
	idx4 := build_index_jobs("fx", files, 4)
	idx8 := build_index_jobs("fx", files, 8)
	b1 := write_index(&idx1)
	b4 := write_index(&idx4)
	b8 := write_index(&idx8)

	testing.expect(t, slice.equal(b1, b4), "--jobs 1 vs 4 identical bytes")
	testing.expect(t, slice.equal(b1, b8), "--jobs 1 vs 8 identical bytes")

	// And identical to the single-threaded reference build.
	ref := build_index("fx", files)
	bref := write_index(&ref)
	testing.expect(t, slice.equal(b1, bref), "threaded matches single-threaded reference")
}
