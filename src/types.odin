package doma

// ## Changes
// - 2026-07-29: Initial flat data model (DESIGN.md §1).

// A segment in the string blob: byte offset + length. All references are indices.
Ref :: struct {
	off: u32,
	len: u32,
}

// One indexed source file. Path is a blob ref; hash is FNV-1a 64 of the source bytes.
File_Rec :: struct {
	path:   Ref,
	length: u64,
	hash:   u64,
}

// One heading-level chunk. Byte range [start,end) is in the owning file's source.
// crumb_off/crumb_len slice into Index.crumbs (a flat list of blob refs).
Chunk_Rec :: struct {
	file:      u32,
	start:     u32,
	end:       u32,
	crumb_off: u32,
	crumb_len: u32,
	tok_len:   u32,
}

// One term. text is a blob ref; postings are Index.postings[post_off:post_off+post_len].
Term_Rec :: struct {
	text:     Ref,
	post_off: u32,
	post_len: u32,
}

// One (chunk, term-frequency) pair. Postings for a term are sorted by chunk id.
Posting :: struct {
	chunk: u32,
	tf:    u32,
}

FORMAT_VERSION :: u32(1)
TOKENIZER_VERSION :: u32(1)

// An index in memory. Loaded from or written to <dir>/.doma-index. Deduped string
// blob holds paths and breadcrumb segments; nothing stores source content (DESIGN.md §3).
Index :: struct {
	format_ver:   u32,
	tok_ver:      u32,
	files:        []File_Rec,
	chunks:       []Chunk_Rec,
	crumbs:       []Ref,
	terms:        []Term_Rec, // sorted lexicographically by text
	postings:     []Posting,
	total_chunks: u32,
	total_tokens: u64,
	blob:         []u8,
	corpus:       string, // dir holding the index, relative to search start (set at load)
}

// Resolve a blob ref to its bytes.
seg :: proc(idx: ^Index, r: Ref) -> string {
	return string(idx.blob[r.off:r.off + r.len])
}
