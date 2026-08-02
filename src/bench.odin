package doma

// ## Changes
// - 2026-07-29: Actionable methodology — warmup, min+median over RUNS timed
//   repetitions, per-query temp-allocator reset (search allocations no longer
//   accumulate and drift), a diverse seeded query set drawn from the corpus
//   vocabulary, and throughput in MB/s, files/s, queries/s.
// - 2026-07-29: Take an optional <dir> (real corpus) and --files n cap.
// - 2026-07-29: Write the report to ./bench/results.txt beside printing it to stdout.
// - 2026-07-29: Hermetic benchmark over a generated tree (DESIGN.md §9). time is
//   used only to measure, never in logic — determinism is preserved.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// Synthetic default when no <dir> is given — keeps a hermetic reference corpus.
BENCH_SYNTH_FILES :: 1000
// Timed repetitions. We report the min (least perturbed by scheduler noise — the
// closest thing to the machine's true speed) and the median (typical run).
BENCH_RUNS :: 5
// Distinct queries per run. Enough to average out per-query variance and to touch
// many different postings lists rather than one cache-hot term.
BENCH_QUERIES :: 100

cmd_bench :: proc(args: []string) -> int {
	dir := ""
	limit := 0 // 0 = no cap (all files)
	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--files":
			i += 1
			if i >= len(args) {
				fmt.eprintln("doma bench: --files needs a number")
				return 2
			}
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				fmt.eprintfln("doma bench: bad --files %q", args[i])
				return 2
			}
			limit = n
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma bench: unknown flag %q", a)
			return 2
		case:
			if dir != "" {
				fmt.eprintln("doma bench: expected one <dir>")
				return 2
			}
			dir = a
		}
		i += 1
	}

	// Gather the corpus: real markdown under <dir>, else the synthetic tree.
	files: []Src_File
	base := "bench"
	synthetic := dir == ""
	if synthetic {
		n := limit if limit > 0 else BENCH_SYNTH_FILES
		files = gen_fixture_tree(2026, n)
		slice.sort_by(files, proc(a, b: Src_File) -> bool { return a.relpath < b.relpath })
	} else {
		ok: bool
		files, ok = collect_markdown(dir)
		if !ok {
			fmt.eprintfln("doma bench: cannot read %q", dir)
			return 2
		}
		if len(files) == 0 {
			fmt.eprintfln("doma bench: no .md files under %q", dir)
			return 2
		}
		if abs, e := filepath.abs(dir); e == nil {
			base = filepath.base(strings.trim_right(abs, "/"))
		}
	}
	// Cap to the requested count; default (no --files) is all files.
	if limit > 0 && limit < len(files) {
		files = files[:limit]
	}
	N := len(files)
	input_bytes := 0
	for f in files do input_bytes += len(f.bytes)

	// The index used for searching lives for the whole run (default allocator).
	idx := build_index_jobs(base, files, 4)
	bytes := write_index(&idx)
	loaded := []Loaded{{idx = idx, corpus = "."}}

	// --- indexing: rebuild BENCH_RUNS times into the temp arena (freed between
	// runs so nothing accumulates), report the fastest and the median. ---
	build_ms := make([]f64, BENCH_RUNS)
	for r in 0 ..< BENCH_RUNS {
		t := time.now()
		_ = build_index_jobs(base, files, 4, context.temp_allocator)
		build_ms[r] = time.duration_milliseconds(time.since(t))
		free_all(context.temp_allocator)
	}
	build_min := fmin(build_ms)
	slice.sort(build_ms)
	build_med := build_ms[len(build_ms) / 2]

	// --- index load: deserialize the written bytes cold, BENCH_RUNS times (temp arena
	// freed between runs). This is the per-invocation cost every real `doma search` pays
	// before it can rank a thing — the number that was invisible while search reused one
	// loaded index. Casting in place (DESIGN.md §7) is why it now reads as sub-ms. ---
	load_ms := make([]f64, BENCH_RUNS)
	for r in 0 ..< BENCH_RUNS {
		t := time.now()
		_, _ = read_index(bytes, context.temp_allocator)
		load_ms[r] = time.duration_milliseconds(time.since(t))
		free_all(context.temp_allocator)
	}
	load_min := fmin(load_ms)
	slice.sort(load_ms)
	load_med := load_ms[len(load_ms) / 2]

	// --- search: warmup once, then BENCH_RUNS timed passes over the query set.
	// The temp arena is reset after every query, so each measurement is the true
	// cost of one search including its own allocation, with no cross-query drift. ---
	queries := build_query_set(&idx)
	search_us := make([]f64, BENCH_RUNS)
	hits_total := 0
	if len(queries) > 0 {
		for q in queries do _ = search(loaded, q, 10, context.temp_allocator)
		free_all(context.temp_allocator)
		for r in 0 ..< BENCH_RUNS {
			t := time.now()
			for q in queries {
				h := search(loaded, q, 10, context.temp_allocator)
				if r == 0 do hits_total += len(h)
				free_all(context.temp_allocator)
			}
			search_us[r] = time.duration_microseconds(time.since(t)) / f64(len(queries))
		}
	}
	search_min := fmin(search_us)
	slice.sort(search_us)
	search_med := search_us[len(search_us) / 2]

	mb := f64(input_bytes) / (1024 * 1024)
	b := strings.builder_make()
	if synthetic {
		fmt.sbprintfln(&b, "doma benchmark — synthetic (%d files)", N)
	} else {
		fmt.sbprintfln(&b, "doma benchmark — %q (%d files)", dir, N)
	}
	fmt.sbprintfln(&b, "  corpus      : %.2f MB source, %d chunks, %d terms", mb, idx.total_chunks, len(idx.terms))
	if build_min > 0 {
		fmt.sbprintfln(&b, "  index build : %.1f ms min (%.1f median)  →  %.1f MB/s, %.0f files/s",
			build_min, build_med, mb / (build_min / 1000), f64(N) / (build_min / 1000))
	} else {
		fmt.sbprintfln(&b, "  index build : %.2f ms min (%.2f median)  (too fast to rate)", build_min, build_med)
	}
	ratio := f64(len(bytes)) / f64(max(input_bytes, 1)) * 100
	fmt.sbprintfln(&b, "  index size  : %d bytes (%.0f%% of source)", len(bytes), ratio)
	// Below ~10 µs the MB/s figure is scheduler noise, not throughput — say so instead
	// of printing a fantasy rate. A cast-in-place load is genuinely this cheap.
	if load_min >= 0.01 {
		fmt.sbprintfln(&b, "  index load  : %.3f ms min (%.3f median)  →  %.0f MB/s",
			load_min, load_med, (f64(len(bytes)) / (1024 * 1024)) / (load_min / 1000))
	} else {
		fmt.sbprintfln(&b, "  index load  : %.3f ms min (%.3f median)  (cast in place — too fast to rate)", load_min, load_med)
	}
	if len(queries) > 0 && search_min > 0 {
		fmt.sbprintfln(&b, "  search      : %.1f µs/query min (%.1f median)  →  %.0f queries/s",
			search_min, search_med, 1e6 / search_min)
		fmt.sbprintfln(&b, "                %d queries × %d runs, %.1f hits/query", len(queries), BENCH_RUNS, f64(hits_total) / f64(len(queries)))
	} else {
		fmt.sbprintfln(&b, "  search      : n/a (no indexable terms)")
	}
	report := strings.to_string(b)

	fmt.print(report)

	// Persist the report beside stdout, in a bench/ folder relative to the
	// working directory. It's a regenerable artifact, not user data, so
	// overwriting the previous run is expected — but a failed write is loud.
	os.make_directory("bench")
	out := "bench/results.txt"
	if err := os.write_entire_file(out, report); err != nil {
		fmt.eprintfln("doma: could not write %s (%v)", out, err)
		return 1
	}
	return 0
}

// fmin returns the smallest element (min of measured times = the run least
// disturbed by the OS). Assumes non-empty.
fmin :: proc(xs: []f64) -> f64 {
	m := xs[0]
	for v in xs do m = min(m, v)
	return m
}

// build_query_set draws BENCH_QUERIES realistic queries from the corpus. Terms are
// sampled uniformly from the vocabulary — so most picks are the many rare terms
// and a few are common, the shape of real search traffic — and grouped 1–3 per
// query. Seeded, so the set is identical every run (deterministic, comparable).
build_query_set :: proc(idx: ^Index, allocator := context.allocator) -> []string {
	n := len(idx.terms)
	if n == 0 do return nil
	terms := make([]string, n, allocator)
	for t, k in idx.terms do terms[k] = seg(idx, t.text)

	r := Rng{state = 2026}
	q := make([]string, BENCH_QUERIES, allocator)
	for qi in 0 ..< BENCH_QUERIES {
		k := 1 + rng_pick(&r, 3)
		parts := make([]string, k, allocator)
		for j in 0 ..< k do parts[j] = terms[rng_pick(&r, n)]
		q[qi] = strings.join(parts, " ", allocator)
	}
	return q
}
