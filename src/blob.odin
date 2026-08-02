package doma

// ## Changes
// - 2026-07-29: Deduped string-blob arena (DESIGN.md §3.7).
// - 2026-07-29: Key the dedup map by the caller's string, not by a slice of `buf`.
//   `buf` is a [dynamic]u8: it reallocates as it grows and, on the heap allocator, the
//   old block is freed — so a key that pointed into it dangled, crashing later lookups
//   (SEGV in string compare) on any corpus large enough to force a realloc.

// Builds the string blob. Interning a string returns a stable (offset,len) ref and
// stores each distinct string exactly once, so a repeated heading/dir costs nothing.
//
// Contract: an interned string's bytes must stay valid for the builder's lifetime — the
// dedup map keys reference caller memory. The sole caller (merge_works) interns strings
// held in per-file work arenas that outlive the merge, so this holds. Keying by a slice
// of `buf` instead would NOT hold: `buf` moves when it grows.
Blob_Builder :: struct {
	buf:  [dynamic]u8,
	seen: map[string]Ref,
}

blob_intern :: proc(b: ^Blob_Builder, s: string) -> Ref {
	if r, ok := b.seen[s]; ok {
		return r
	}
	r := Ref{off = u32(len(b.buf)), len = u32(len(s))}
	append(&b.buf, ..transmute([]u8)s)
	b.seen[s] = r // key by caller memory (stable); see the contract on Blob_Builder
	return r
}

blob_finish :: proc(b: ^Blob_Builder) -> []u8 {
	return b.buf[:]
}
