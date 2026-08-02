package doma

// ## Changes
// - 2026-07-29: Discover indexes to depth 3 + verify staleness loudly (DESIGN.md §4).
// - 2026-07-29: Freshness gate uses a lean stat(2) for just size+mtime instead of
//   os.stat — os.stat readlinks /proc/self/fd to build a fullpath we never read, ~2
//   extra syscalls per file that dominated cold search on large corpora (DESIGN.md §4).
// - 2026-07-29: mmap the index instead of reading it whole, and reuse one path buffer
//   across the stat gate — a cold search over a 55MB / 13k-file index no longer faults
//   the whole file in or allocates per file (DESIGN.md §4, §7).
// - 2026-07-29: parallelise the tier-1 stat walk across the thread pool. Once the earlier
//   allocation was gone the ~13k stat syscalls became the whole cold-search cost; they are
//   independent and write disjoint slots, so fanning them over the cores cut the walk ~9ms
//   → ~2ms and put a ranking search under grep's raw scan. Serial below 2048 files; output
//   is thread-count-invariant, verdicts consumed in file-id order (DESIGN.md §4, §7).

import "base:runtime"
import "core:c"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

DISCOVER_DEPTH :: 3

// stat_size_mtime returns just the two fields the freshness gate compares — file size
// and modification time (unix ns) — via one stat(2) on a caller-supplied cstring. It
// skips os.stat, whose File_Info carries a symlink-resolved `fullpath` (an extra readlink
// + allocation per call) that this gate never uses. present=false means the file is gone.
@(private = "file")
stat_size_mtime :: proc(path: cstring) -> (present: bool, size: u64, mtime_ns: i64) {
	when ODIN_OS == .Windows {
		// Windows has no core:sys/posix stat. Fall back to os.stat, which allocates a
		// File_Info whose fullpath this gate discards — the readlink+alloc the lean posix
		// path was written to avoid. That cost is fine here: the perf-tuned path targets
		// Linux/macOS, and no measured Windows large-corpus workload justifies a native
		// GetFileAttributesEx backend yet. Temp allocator: the CLI is short-lived.
		fi, err := os.stat(string(path), context.temp_allocator)
		if err != nil do return
		return true, u64(fi.size), time.time_to_unix_nano(fi.modification_time)
	} else {
		st: posix.stat_t
		if posix.stat(path, &st) != .OK do return
		return true, u64(st.st_size), i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec)
	}
}

// file_mtime returns a file's modification time (unix ns), or 0 if it is absent. Used as
// the freshness baseline for a corpus index (its own mtime vs the files it indexes).
file_mtime :: proc(path: cstring) -> i64 {
	if present, _, mtime := stat_size_mtime(path); present do return mtime
	return 0
}

// mmap_file maps a whole file read-only and returns its bytes. The mapping is never
// unmapped: it lives for the process, exactly like the command arena, so an Index cast
// over it stays valid (DESIGN.md §7). Being demand-paged is the point — a search faults
// in only the index pages it touches (term dict, a few postings), not the whole blob.
// ok=false means absent or unmappable; the caller falls back to a plain read.
mmap_file :: proc(path: cstring) -> ([]u8, bool) {
	when ODIN_OS == .Windows {
		// No mmap here: return unmappable so the caller falls back to a plain read
		// (cmd_query.odin). A CreateFileMapping/MapViewOfFile backend waits on a measured
		// Windows workload — until then the read path is correct and simpler.
		return nil, false
	} else {
		fd := posix.open(path, {})
		if fd < 0 do return nil, false
		defer posix.close(fd)
		st: posix.stat_t
		if posix.fstat(fd, &st) != .OK do return nil, false
		size := int(st.st_size)
		if size <= 0 do return nil, false
		p := posix.mmap(nil, c.size_t(size), {.READ}, {.PRIVATE}, fd, 0)
		if p == posix.MAP_FAILED do return nil, false
		return (cast([^]u8)p)[:size], true
	}
}

// Cheap per-file stat data: no source bytes read. Gathered by the I/O shell and
// handed to the pure freshness verdict (ADR-0001).
File_State :: struct {
	present: bool,
	size:    u64,
	mtime:   i64, // modification time, unix nanoseconds
}

// Fresh: serve as-is. Suspect: cheap gate flagged it; hash to confirm.
// Stale: definitively out of date (currently: missing file).
Freshness :: enum {
	Fresh,
	Suspect,
	Stale,
}

// freshness_of is the two-tier gate's pure core (ADR-0001): given one file record,
// its current stat, and the index file's own mtime, decide without reading bytes.
// A missing file is stale; a size change or an mtime newer than the index is suspect
// (the caller hashes suspects to confirm); everything else is fresh.
freshness_of :: proc(rec: File_Rec, st: File_State, index_mtime: i64) -> Freshness {
	if !st.present do return .Stale
	if st.size != rec.length do return .Suspect
	if st.mtime > index_mtime do return .Suspect
	return .Fresh
}

// Loaded pairs an index with the corpus name it belongs to; search() ranks across a slice
// of these (one per corpus queried).
Loaded :: struct {
	idx:    Index,
	corpus: string,
}

// WALK_PARALLEL_MIN is the file count below which the stat walk stays serial: the
// thread-pool spawn only pays off once there are enough files to amortise it, and small
// corpora (tests, synthetic fixtures) keep the simplest, allocation-free path.
WALK_PARALLEL_MIN :: 2048

@(private = "file")
Walk_Ctx :: struct {
	idx:         ^Index,
	prefix:      string, // "<corpus_abs>/" — every path is prefix + relpath
	index_mtime: i64,
	full_hash:   bool,
	verdicts:    []Freshness,
	block:       int, // files per task; task t covers [t*block, (t+1)*block)
}

// walk_range computes freshness for files [lo,hi) into ctx.verdicts. Pure per-file work
// over the read-only index; it writes only its own disjoint slots, so concurrent tasks
// never race and need no lock. The path is built in a stack buffer — no allocation.
@(private = "file")
walk_range :: proc(c: ^Walk_Ctx, lo, hi: int) {
	buf: [4096]u8 // "<prefix><relpath>\0"; relpaths from a markdown tree fit comfortably
	pl := copy(buf[:], c.prefix)
	for i in lo ..< hi {
		f := c.idx.files[i]
		rel := seg(c.idx, f.path)
		if pl + len(rel) + 1 > len(buf) { // pathological length — mark suspect, the hash resolves it
			c.verdicts[i] = .Suspect
			continue
		}
		copy(buf[pl:], rel)
		buf[pl + len(rel)] = 0
		st: File_State
		if present, size, mtime := stat_size_mtime(cstring(&buf[0])); present {
			st = File_State{present = true, size = size, mtime = mtime}
		}
		verdict := freshness_of(f, st, c.index_mtime)
		if c.full_hash && st.present do verdict = .Suspect // --verify: hash everything present
		c.verdicts[i] = verdict
	}
}

@(private = "file")
walk_worker :: proc(task: thread.Task) {
	c := (^Walk_Ctx)(task.data)
	lo := task.user_index * c.block
	hi := min(lo + c.block, len(c.idx.files))
	walk_range(c, lo, hi)
}

// stat_walk fills `verdicts` (one per indexed file) with each file's freshness. Serial
// below WALK_PARALLEL_MIN; above it, split into one contiguous block per hardware thread
// and stat them concurrently — the syscall walk is the bulk of a cold search on a large
// corpus, so this is where parallelism pays. Output is independent of the thread count:
// every file's verdict is computed the same way and stored by file id (DESIGN.md §7).
@(private = "file")
stat_walk :: proc(idx: ^Index, prefix: string, index_mtime: i64, full_hash: bool, verdicts: []Freshness) {
	ctx := Walk_Ctx{idx = idx, prefix = prefix, index_mtime = index_mtime, full_hash = full_hash, verdicts = verdicts}
	n := len(idx.files)

	jobs := 0
	if n >= WALK_PARALLEL_MIN do jobs = os.get_processor_core_count()
	if jobs <= 1 {
		walk_range(&ctx, 0, n)
		return
	}

	ctx.block = (n + jobs - 1) / jobs
	ntasks := (n + ctx.block - 1) / ctx.block

	// Heap allocator: thread-safe on Linux, and the pool needs one for its own bookkeeping.
	// Workers allocate nothing, so no per-worker arena (unlike the index build, DESIGN.md §7).
	heap := runtime.heap_allocator()
	pool: thread.Pool
	thread.pool_init(&pool, heap, jobs)
	defer thread.pool_destroy(&pool)
	for t in 0 ..< ntasks {
		thread.pool_add_task(&pool, heap, walk_worker, &ctx, t)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)
}

// verify_index checks every file in the index against disk in two tiers (ADR-0001).
// Tier 1 is a cheap stat gate (freshness_of); only files it flags *suspect* fall to
// tier 2, which reads and hashes them — the arbiter. index_mtime is the .doma-index
// file's own modification time (unix ns). full_hash forces every present file through
// the hash arbiter, skipping the gate (the `--verify` path).
// Returns "" if fresh, else a human-readable reason naming the offending file.
// Never panics on missing files — a vanished file becomes a stale reason.
verify_index :: proc(idx: ^Index, corpus_abs: string, index_mtime: i64, full_hash: bool, a: runtime.Allocator) -> string {
	if idx.format_ver != FORMAT_VERSION do return "format version mismatch"
	if idx.tok_ver != TOKENIZER_VERSION do return "tokenizer version mismatch"

	// Tier 1: stat gate — one stat per indexed file, the honest floor of a cold search on
	// a large corpus (~13k syscalls) and its dominant cost. Each file's verdict is
	// independent and lands in its own slot, so stat_walk fans the syscalls across the
	// thread pool above a size threshold. Verdicts are then consumed in file-id order, so a
	// missing file names the same path no matter how the stats were scheduled (DESIGN.md §4).
	verdicts := make([]Freshness, len(idx.files), a)
	prefix := strings.concatenate({strings.trim_right(corpus_abs, "/"), "/"}, a)
	stat_walk(idx, prefix, index_mtime, full_hash, verdicts)

	suspects := make([dynamic]int, a)
	for verdict, i in verdicts {
		switch verdict {
		case .Stale:   return strings.concatenate({"missing file: ", seg(idx, idx.files[i].path)}, a)
		case .Suspect: append(&suspects, i)
		case .Fresh:   // gate cleared it; no read
		}
	}

	// Tier 2: the arbiter — read and hash only suspect files. Content decides.
	for i in suspects {
		f := idx.files[i]
		rel := seg(idx, f.path)
		full, _ := filepath.join({corpus_abs, rel}, a)
		bytes, rerr := os.read_entire_file(full, a)
		if rerr != nil do return strings.concatenate({"missing file: ", rel}, a)
		if u64(len(bytes)) != f.length do return strings.concatenate({"changed length: ", rel}, a)
		if hash.fnv64a(bytes) != f.hash do return strings.concatenate({"changed content: ", rel}, a)
	}
	return ""
}
