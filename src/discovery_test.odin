package doma

// ## Changes
// - 2026-07-29: Tests for discover + verify_index staleness detection.
// - 2026-08-01: Discovery is gone (corpus queries load one known index). These now test the
//   freshness gate directly. index_mtime = 0 forces every present file through the hash
//   arbiter (its mtime is always "newer"), exercising the suspect -> hash path (ADR-0001).

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
verify_index_detects_changed_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "get temp dir")
	root, _ := filepath.join({tmp_dir, "doma_verify_changed"})
	os.make_directory(root)
	defer os.remove_all(root)

	a_md, _ := filepath.join({root, "a.md"})
	_ = os.write_entire_file(a_md, transmute([]u8)string("# Alpha\nbody\n"))
	idx, ok := build_index_from_dir(root)
	testing.expect(t, ok, "build index from dir")

	// Unchanged content is fresh even under full hashing.
	testing.expect_value(t, verify_index(&idx, root, 0, false, context.temp_allocator), "")

	// Mutate a source file -> length/content changes -> a non-empty stale reason.
	_ = os.write_entire_file(a_md, transmute([]u8)string("# Alpha\nCHANGED body now longer\n"))
	reason := verify_index(&idx, root, 0, false, context.temp_allocator)
	testing.expect(t, reason != "", "a changed file must produce a stale reason")
}

// A file rewritten with identical bytes (a bare `touch`: newer mtime, same content) must
// stay fresh — the gate flags it suspect, the hash arbiter clears it (ADR-0001).
@(test)
verify_index_touch_stays_fresh :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_verify_touch"})
	os.make_directory(root)
	defer os.remove_all(root)

	a_md, _ := filepath.join({root, "a.md"})
	body := "# Alpha\nbody\n"
	_ = os.write_entire_file(a_md, transmute([]u8)string(body))
	idx, ok := build_index_from_dir(root)
	testing.expect(t, ok, "build index from dir")

	// Rewrite the exact same bytes -> suspect by mtime, cleared by the hash -> fresh.
	_ = os.write_entire_file(a_md, transmute([]u8)string(body))
	testing.expect_value(t, verify_index(&idx, root, 0, false, context.temp_allocator), "")
}

@(test)
verify_index_missing_file_is_stale :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_verify_missing"})
	os.make_directory(root)
	defer os.remove_all(root)

	a_md, _ := filepath.join({root, "a.md"})
	_ = os.write_entire_file(a_md, transmute([]u8)string("# Alpha\nbody\n"))
	idx, ok := build_index_from_dir(root)
	testing.expect(t, ok, "build index from dir")

	os.remove(a_md)
	reason := verify_index(&idx, root, 0, false, context.temp_allocator)
	testing.expect(t, reason != "", "a missing file must produce a stale reason")
}
