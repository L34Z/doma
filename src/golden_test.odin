package doma

// ## Changes
// - 2026-07-29: Byte-for-byte golden tests for source→index and (index,query)→result
//   plus JSON round-trip coverage and in-code determinism assertion (DESIGN.md §9).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

// Assert `got` equals committed testdata/<name>; if the file is absent, write it and
// fail with a note so the reviewer commits the golden intentionally (DESIGN.md §9).
@(private = "file")
assert_golden :: proc(t: ^testing.T, name: string, got: []u8) {
	path := fmt.tprintf("testdata/%s", name)
	want, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		os.make_directory("testdata")
		_ = os.write_entire_file(path, got)
		testing.expectf(
			t,
			false,
			"golden %q was missing — wrote it; review & commit, then re-run",
			path,
		)
		return
	}
	testing.expectf(
		t,
		slice.equal(got, want),
		"golden %q mismatch (update in-commit with reasoning if intended)",
		path,
	)
}

@(test)
golden_source_to_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := gen_fixture_tree(1234, 12)
	slice.sort_by(files, proc(a, b: Src_File) -> bool {return a.relpath < b.relpath})
	idx := build_index("fixture", files)
	got := write_index(&idx)

	// In-code determinism: build twice, assert identical bytes.
	idx2 := build_index("fixture", files)
	got2 := write_index(&idx2)
	testing.expectf(t, slice.equal(got, got2), "write_index output must be deterministic (two builds differ)")

	assert_golden(t, "fixture.doma-index", got)
}

@(test)
golden_index_query_to_result :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := gen_fixture_tree(1234, 12)
	slice.sort_by(files, proc(a, b: Src_File) -> bool {return a.relpath < b.relpath})
	idx := build_index("fixture", files)
	idx.corpus = "."
	loaded := []Loaded{{idx = idx, corpus = "."}}
	hits := search(loaded, "needle target", 5)

	b: [dynamic]u8
	q_terms := []string{"needle", "target"}
	for h, rank in hits {
		c := h.idx.chunks[h.chunk]
		snip := snippet_of(files[c.file].bytes, c, q_terms)
		crumb := breadcrumb_of(h.idx, h.chunk)
		line := fmt.tprintf("#%d %.3f %s | %s\n", rank + 1, h.score, crumb, snip)
		append(&b, ..transmute([]u8)line)
	}
	assert_golden(t, "fixture.result", b[:])
}

// JSON round-trip: build a Hit, render one JSON line via render_json_line, parse it back,
// and assert all fields round-trip exactly.
@(test)
json_result_roundtrip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files := gen_fixture_tree(1234, 12)
	slice.sort_by(files, proc(a, b: Src_File) -> bool {return a.relpath < b.relpath})
	idx := build_index("fixture", files)
	idx.corpus = "fixture"
	loaded := []Loaded{{idx = idx, corpus = "fixture"}}
	hits := search(loaded, "needle target", 1)
	if len(hits) == 0 {
		testing.fail_now(t, "no hits for JSON round-trip test")
	}

	h := hits[0]
	c := h.idx.chunks[h.chunk]
	snip := snippet_of(files[c.file].bytes, c, []string{"needle", "target"})
	frec := h.idx.files[c.file]
	path := seg(h.idx, frec.path)
	crumb := breadcrumb_of(h.idx, h.chunk)

	line := render_json_line(h, path, crumb, snip)

	// Parse it back.
	Parsed :: struct {
		score:      f64,
		corpus:     string,
		path:       string,
		breadcrumb: string,
		start:      u32,
		end:        u32,
		snippet:    string,
	}
	p: Parsed
	err := json.unmarshal(transmute([]u8)line, &p)
	testing.expectf(t, err == nil, "json.unmarshal error: %v", err)

	// Score: 3 decimal places means tolerance of 0.0005.
	score_diff := h.score - p.score
	if score_diff < 0 do score_diff = -score_diff
	testing.expectf(t, score_diff < 0.001, "score round-trip: got %.6f want %.6f", p.score, h.score)
	testing.expect_value(t, p.corpus, h.corpus)
	testing.expect_value(t, p.path, path)
	testing.expect_value(t, p.breadcrumb, crumb)
	testing.expect_value(t, p.start, c.start)
	testing.expect_value(t, p.end, c.end)
	testing.expect_value(t, p.snippet, snip)
}

