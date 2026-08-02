package doma

// ## Changes
// - 2026-07-29: Test for deduped string-blob arena (DESIGN.md §3.7).

import "core:fmt"
import "core:testing"

// Interning many distinct strings forces the blob's byte buffer to reallocate and move;
// on the heap allocator the old block is actually freed. The dedup map keys must survive
// that move: re-interning an early string must still return its original ref. A key that
// aliased the growing buffer dangles here — crashing on the compare or silently failing
// to dedup. Strings are pre-materialised and outlive the builder, matching how the real
// caller (merge_works) interns worker-arena strings that persist through the merge.
@(test)
blob_dedup_survives_buffer_growth :: proc(t: ^testing.T) {
	b: Blob_Builder
	defer {
		delete(b.buf)
		delete(b.seen)
	}

	N :: 20000
	strs := make([]string, N)
	refs := make([]Ref, N)
	defer {
		for s in strs do delete(s)
		delete(strs)
		delete(refs)
	}
	for i in 0 ..< N do strs[i] = fmt.aprintf("blob-key-%d-with-padding", i)

	for i in 0 ..< N do refs[i] = blob_intern(&b, strs[i])
	// Re-intern every earlier string; each must map back to its original ref.
	for i in 0 ..< N {
		got := blob_intern(&b, strs[i])
		testing.expect_value(t, got, refs[i])
	}
}

@(test)
blob_dedups_and_resolves :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	b: Blob_Builder
	r1 := blob_intern(&b, "guide")
	r2 := blob_intern(&b, "doc.md")
	r3 := blob_intern(&b, "guide") // duplicate
	testing.expect_value(t, r1, r3)          // same ref, stored once
	testing.expect(t, r1.off != r2.off, "distinct strings get distinct offsets")
	blob := blob_finish(&b)
	idx := Index{blob = blob}
	testing.expect_value(t, seg(&idx, r1), "guide")
	testing.expect_value(t, seg(&idx, r2), "doc.md")
	// "guide" (5) + "doc.md" (6) with no duplicate copy = 11 bytes
	testing.expect_value(t, len(blob), 11)
}
