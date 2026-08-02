package doma

// ## Changes
// - 2026-07-29: Tests for .doma-index serialize/deserialize (round-trip identity + bad magic).

import "core:slice"
import "core:testing"

@(test)
index_format_roundtrips_and_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# Alpha\nzebra alpha zebra\n")},
		{relpath = "b.md", bytes = transmute([]u8)string("# Beta\nalpha beta\n")},
	}
	idx := build_index("proj", files)
	b1 := write_index(&idx)
	// Determinism: writing the same index twice yields identical bytes.
	b2 := write_index(&idx)
	testing.expect(t, slice.equal(b1, b2), "serialize is deterministic")

	back, ok := read_index(b1)
	testing.expect(t, ok, "read ok")
	testing.expect_value(t, back.total_chunks, idx.total_chunks)
	testing.expect_value(t, back.total_tokens, idx.total_tokens)
	testing.expect_value(t, len(back.terms), len(idx.terms))
	// Term lookup still works after reload.
	ti := find_term(&back, "alpha")
	testing.expect(t, ti >= 0, "alpha present after reload")
	testing.expect_value(t, back.terms[ti].post_len, u32(2))
	// Re-serializing the reloaded index reproduces the exact bytes (round-trip identity).
	b3 := write_index(&back)
	testing.expect(t, slice.equal(b1, b3), "round-trip is byte-identical")
}

@(test)
index_format_rejects_bad_magic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	_, ok := read_index(transmute([]u8)string("XXXX...."))
	testing.expect(t, !ok, "bad magic rejected")
}

@(test)
index_format_rejects_truncated_buffer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := []Src_File{
		{relpath = "a.md", bytes = transmute([]u8)string("# Alpha\nzebra alpha zebra\n")},
	}
	idx := build_index("proj", files)
	full := write_index(&idx)

	// A truncated prefix must be rejected, not read past the end.
	_, ok := read_index(full[:len(full) / 2])
	testing.expect(t, !ok, "truncated buffer rejected")

	// Magic + header scalars + a bogus File count of 1_000_000 with no file data.
	// Must fail immediately at the can_read check, never allocating millions of elems.
	bogus := make([dynamic]u8)
	append(&bogus, ..transmute([]u8)string(MAGIC))
	for _ in 0 ..< 3 {append(&bogus, 0, 0, 0, 0)} // format_ver, tok_ver, total_chunks (u32s)
	append(&bogus, 0, 0, 0, 0, 0, 0, 0, 0) // total_tokens (u64)
	// n_files = 1_000_000 (LE), then nothing.
	append(&bogus, 0x40, 0x42, 0x0F, 0x00)
	_, ok2 := read_index(bogus[:])
	testing.expect(t, !ok2, "bogus huge count rejected")
}
