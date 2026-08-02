package doma

// ## Changes
// - 2026-07-29: Assemble an in-memory Index from source files (DESIGN.md §3, §7).
//   Deterministic: caller pre-sorts files by relpath; terms sorted lexicographically,
//   postings by chunk id. No precomputed scores — raw stats only (DESIGN.md §3).
// - 2026-07-29: Threaded per-file build; merge in fixed file-id order (DESIGN.md §7).
// - 2026-07-29: Unify flatten/merge into a single merge_works; serial + threaded builds
//   feed it a common File_Work representation (single source of truth).

import "base:runtime"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:thread"

Src_File :: struct {
	relpath: string,
	bytes:   []u8,
}

// Binary search the sorted term dictionary; returns index or -1 (DESIGN.md §3.4).
find_term :: proc(idx: ^Index, term: string) -> int {
	lo, hi := 0, len(idx.terms)
	for lo < hi {
		mid := (lo + hi) / 2
		s := seg(idx, idx.terms[mid].text)
		switch {
		case s < term:
			lo = mid + 1
		case s > term:
			hi = mid
		case:
			return mid
		}
	}
	return -1
}

@(private = "file")
Term_Accum :: struct {
	tf: map[u32]u32,
}

// chunk_file routes a source file to the chunker for its kind: the Markdown heading
// chunker for .md/.markdown, otherwise the language-agnostic code chunker. Both emit
// Raw_Chunks (byte ranges + crumbs), so the two kinds coexist in one index with no
// format change — the index never records which chunker produced a chunk.
@(private = "file")
chunk_file :: proc(src: []u8, basename, relpath: string, allocator := context.allocator) -> []Raw_Chunk {
	if is_markdown_path(relpath) do return chunk_markdown(src, basename, relpath, allocator)
	return chunk_code(src, basename, relpath, allocator)
}

// build_index assembles an Index single-threaded: chunk+tokenize each file in fid
// order, then merge via the shared merge_works. Serial and threaded builds share the
// same merge — the single source of truth for interning/sorting/postings.
build_index :: proc(basename: string, files: []Src_File, allocator := context.allocator) -> Index {
	works := make([]File_Work, len(files), allocator)
	for f, fid in files {
		raws := chunk_file(f.bytes, basename, f.relpath, allocator)
		toks := make([][]Token, len(raws), allocator)
		for rc, k in raws {
			toks[k] = tokenize(f.bytes[rc.start:rc.end], allocator)
		}
		works[fid] = File_Work{
			fid    = fid,
			src    = f.bytes,
			rel    = f.relpath,
			hash   = hash.fnv64a(f.bytes),
			chunks = raws,
			toks   = toks,
		}
	}
	return merge_works(basename, works, allocator)
}

// Per-file work: chunk+tokenize output for one file. In the threaded build each entry
// is produced by a worker into its own arena; in the serial build entries use the
// caller's allocator directly (arena zero-valued, never destroyed).
@(private = "file")
File_Work :: struct {
	fid:    int,
	src:    []u8,
	rel:    string,
	hash:   u64,
	chunks: []Raw_Chunk,
	toks:   [][]Token, // per-chunk tokens
	arena:  virtual.Arena, // threaded-build backing store; destroyed after merge
}

// Task context shared (read-only) across all workers.
@(private = "file")
Task_Ctx :: struct {
	works: []File_Work,
	files: []Src_File,
	base:  string,
}

@(private = "file")
worker_proc :: proc(task: thread.Task) {
	c := (^Task_Ctx)(task.data)
	fi := task.user_index
	f := c.files[fi]
	w := &c.works[fi]

	// Each worker has its own growing virtual arena — independent heap-backed
	// memory, no shared mutable state with any other worker (race-free).
	if err := virtual.arena_init_growing(&w.arena); err != nil {
		panic("arena init failed")
	}
	a := virtual.arena_allocator(&w.arena)
	context.allocator = a

	raws := chunk_file(f.bytes, c.base, f.relpath, a)
	toks := make([][]Token, len(raws), a)
	for rc, k in raws {
		toks[k] = tokenize(f.bytes[rc.start:rc.end], a)
	}
	w.fid    = fi
	w.src    = f.bytes
	w.rel    = f.relpath
	w.hash   = hash.fnv64a(f.bytes)
	w.chunks = raws
	w.toks   = toks
}

// build_index_jobs builds an Index using up to `jobs` worker threads.
// When jobs <= 1 it delegates to build_index (same output).
// When jobs == 0 it uses the hardware thread count (or 4 if unavailable).
// Output bytes are independent of jobs value and worker completion order:
// workers only chunk/tokenize their own file; all merging happens single-threaded
// in fixed file-id order (DESIGN.md §7).
build_index_jobs :: proc(basename: string, files: []Src_File, jobs: int, allocator := context.allocator) -> Index {
	effective := jobs
	if effective == 0 {
		n := os.get_processor_core_count()
		effective = n if n > 0 else 4
	}
	if effective <= 1 {
		return build_index(basename, files, allocator)
	}

	works := make([]File_Work, len(files), allocator)
	tctx := Task_Ctx{works = works, files = files, base = basename}

	// Pool uses the heap allocator (thread-safe malloc/free on Linux).
	// Each worker uses its own virtual.Arena — no shared mutable state.
	heap := runtime.heap_allocator()
	pool: thread.Pool
	thread.pool_init(&pool, heap, effective)
	defer thread.pool_destroy(&pool)

	for fi in 0 ..< len(files) {
		thread.pool_add_task(&pool, heap, worker_proc, &tctx, fi)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	// Merge single-threaded in fixed fid order (structural determinism, DESIGN.md §7).
	idx := merge_works(basename, works, allocator)

	// Free per-worker arenas now that merge is complete.
	for &w in works {
		virtual.arena_destroy(&w.arena)
	}

	return idx
}

// merge_works merges pre-computed per-file work into an Index using the same
// ordering rules as build_index: fid order for files/chunks, lexicographic for terms,
// chunk-id order for postings.
@(private = "file")
merge_works :: proc(basename: string, works: []File_Work, allocator := context.allocator) -> Index {
	b: Blob_Builder
	file_recs  := make([dynamic]File_Rec, allocator)
	chunk_recs := make([dynamic]Chunk_Rec, allocator)
	crumbs     := make([dynamic]Ref, allocator)
	terms      := make(map[string]^Term_Accum, allocator)
	total_tokens := u64(0)

	for w in works {
		append(&file_recs, File_Rec{
			path   = blob_intern(&b, w.rel),
			length = u64(len(w.src)),
			hash   = w.hash,
		})
		for rc, k in w.chunks {
			cid       := u32(len(chunk_recs))
			crumb_off := u32(len(crumbs))
			for c in rc.crumbs {
				append(&crumbs, blob_intern(&b, c))
			}
			toks := w.toks[k]
			total_tokens += u64(len(toks))
			append(&chunk_recs, Chunk_Rec{
				file      = u32(w.fid),
				start     = u32(rc.start),
				end       = u32(rc.end),
				crumb_off = crumb_off,
				crumb_len = u32(len(rc.crumbs)),
				tok_len   = u32(len(toks)),
			})
			for tok in toks {
				acc := terms[tok.text]
				if acc == nil {
					acc = new(Term_Accum, allocator)
					acc.tf = make(map[u32]u32, allocator)
					terms[tok.text] = acc
				}
				acc.tf[cid] += 1
			}
		}
	}

	// Flatten terms sorted lexicographically; postings sorted by chunk id.
	keys := make([dynamic]string, allocator)
	for k in terms {
		append(&keys, k)
	}
	slice.sort(keys[:])

	term_recs := make([dynamic]Term_Rec, allocator)
	postings  := make([dynamic]Posting, allocator)
	for k in keys {
		acc  := terms[k]
		cids := make([dynamic]u32, allocator)
		for cid in acc.tf {
			append(&cids, cid)
		}
		slice.sort(cids[:])
		off := u32(len(postings))
		for cid in cids {
			append(&postings, Posting{chunk = cid, tf = acc.tf[cid]})
		}
		append(&term_recs, Term_Rec{
			text     = blob_intern(&b, k),
			post_off = off,
			post_len = u32(len(cids)),
		})
	}

	return Index{
		format_ver   = FORMAT_VERSION,
		tok_ver      = TOKENIZER_VERSION,
		files        = file_recs[:],
		chunks       = chunk_recs[:],
		crumbs       = crumbs[:],
		terms        = term_recs[:],
		postings     = postings[:],
		total_chunks = u32(len(chunk_recs)),
		total_tokens = total_tokens,
		blob         = blob_finish(&b),
	}
}
