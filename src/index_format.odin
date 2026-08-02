package doma

// ## Changes
// - 2026-07-29: .doma-index serialize/deserialize, fixed little-endian (DESIGN.md §3).
// - 2026-07-29: read path casts tables in place instead of decoding field-by-field —
//   the on-disk layout IS the packed little-endian struct array, so a search borrows
//   its index with bounds checks, not ~half a million integer decodes (DESIGN.md §7).

import "core:encoding/endian"
import "core:mem"

// The read path reinterprets on-disk bytes directly as record arrays; that is only
// bit-correct on a little-endian host (the same assumption DESIGN §3 already makes for
// the format). Fail loud at compile time on the imaginary big-endian target rather than
// silently mis-decoding — no "technically" (DESIGN.md §7).
#assert(ODIN_ENDIAN == .Little)

MAGIC :: "DOMA"

@(private = "file")
Writer :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
w_u32 :: proc(w: ^Writer, v: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
w_u64 :: proc(w: ^Writer, v: u64) {
	b: [8]u8
	endian.put_u64(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
w_ref :: proc(w: ^Writer, r: Ref) {
	w_u32(w, r.off)
	w_u32(w, r.len)
}

write_index :: proc(idx: ^Index, allocator := context.allocator) -> []u8 {
	w := Writer{buf = make([dynamic]u8, allocator)}
	append(&w.buf, ..transmute([]u8)string(MAGIC))
	w_u32(&w, idx.format_ver)
	w_u32(&w, idx.tok_ver)
	w_u32(&w, idx.total_chunks)
	w_u64(&w, idx.total_tokens)

	w_u32(&w, u32(len(idx.files)))
	for f in idx.files {
		w_ref(&w, f.path)
		w_u64(&w, f.length)
		w_u64(&w, f.hash)
	}

	w_u32(&w, u32(len(idx.chunks)))
	for c in idx.chunks {
		w_u32(&w, c.file)
		w_u32(&w, c.start)
		w_u32(&w, c.end)
		w_u32(&w, c.crumb_off)
		w_u32(&w, c.crumb_len)
		w_u32(&w, c.tok_len)
	}

	w_u32(&w, u32(len(idx.crumbs)))
	for r in idx.crumbs {
		w_ref(&w, r)
	}

	w_u32(&w, u32(len(idx.terms)))
	for tr in idx.terms {
		w_ref(&w, tr.text)
		w_u32(&w, tr.post_off)
		w_u32(&w, tr.post_len)
	}

	w_u32(&w, u32(len(idx.postings)))
	for p in idx.postings {
		w_u32(&w, p.chunk)
		w_u32(&w, p.tf)
	}

	w_u32(&w, u32(len(idx.blob)))
	append(&w.buf, ..idx.blob)
	return w.buf[:]
}

@(private = "file")
Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

@(private = "file")
r_u32 :: proc(r: ^Reader) -> u32 {
	if r.pos + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_u32(r.data[r.pos:r.pos + 4], .Little)
	r.pos += 4
	return v
}

@(private = "file")
r_u64 :: proc(r: ^Reader) -> u64 {
	if r.pos + 8 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_u64(r.data[r.pos:r.pos + 8], .Little)
	r.pos += 8
	return v
}

// Validate the declared byte size of a section against the remaining buffer BEFORE
// trusting it, so a malformed count can never make us read past the end.
@(private = "file")
can_read :: proc(r: ^Reader, nbytes: int) -> bool {
	return r.ok && nbytes >= 0 && r.pos + nbytes <= len(r.data)
}

// r_table reinterprets the next `count` records as a `[]T` that borrows the source
// buffer — no per-field decode, no allocation, no copy. can_read bounds-checks the
// declared size first, so a bogus count is rejected before it can read out of range;
// records are packed with no padding, so count*size_of(T) is exactly the section's
// byte length. `count` is widened from a u32, so count*size_of(T) fits a 64-bit int.
@(private = "file")
r_table :: proc(r: ^Reader, $T: typeid, count: int) -> []T {
	n := count * size_of(T)
	if !can_read(r, n) {
		r.ok = false
		return nil
	}
	out := mem.slice_data_cast([]T, r.data[r.pos:r.pos + n])
	r.pos += n
	return out
}

// read_index borrows `data`: the returned Index's tables and blob are slices into it,
// so `data` must outlive the Index. Every caller reads the file into the command arena
// (freed whole at exit, DESIGN.md §7), so the borrow holds for the whole command.
read_index :: proc(data: []u8, allocator := context.allocator) -> (Index, bool) {
	if len(data) < 4 || string(data[:4]) != MAGIC {
		return {}, false
	}
	r := Reader{data = data, pos = 4, ok = true}
	idx: Index
	idx.format_ver = r_u32(&r)
	idx.tok_ver = r_u32(&r)
	idx.total_chunks = r_u32(&r)
	idx.total_tokens = r_u64(&r)
	if !r.ok do return {}, false

	// Tables are cast straight out of the buffer — the on-disk bytes are the packed
	// little-endian record arrays, so this is where the old field-by-field decode used
	// to burn ~30 ms on a large index (README benchmarks). r_table bounds-checks each count.
	files    := r_table(&r, File_Rec, int(r_u32(&r)))
	chunks   := r_table(&r, Chunk_Rec, int(r_u32(&r)))
	crumbs   := r_table(&r, Ref, int(r_u32(&r)))
	terms    := r_table(&r, Term_Rec, int(r_u32(&r)))
	postings := r_table(&r, Posting, int(r_u32(&r)))

	bl := int(r_u32(&r))
	if !can_read(&r, bl) do return {}, false
	blob := data[r.pos:r.pos + bl] // slice, not copy — borrows `data` (see proc doc)
	r.pos += bl
	if !r.ok do return {}, false

	idx.files = files
	idx.chunks = chunks
	idx.crumbs = crumbs
	idx.terms = terms
	idx.postings = postings
	idx.blob = blob
	return idx, true
}
