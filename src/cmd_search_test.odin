package doma

// ## Changes
// - 2026-07-29: End-to-end tests for `doma search` — exit codes (DESIGN.md §6, §8).
// - 2026-08-01: `doma search` is now ad-hoc: it builds an ephemeral in-memory index of the
//   directory and searches it, so no prior `doma index` is needed.

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
cmd_search_end_to_end_exit_codes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "get temp dir")
	root, _ := filepath.join({tmp_dir, "doma_search_e2e"})
	os.make_directory(root)
	defer os.remove_all(root)

	md_path, _ := filepath.join({root, "a.md"})
	_ = os.write_entire_file(md_path, transmute([]u8)string("# Alpha\nthe needle is here\n"))

	// Has results -> exit 0 (index built in-memory from the dir).
	testing.expect_value(t, cmd_search([]string{"doma", "search", "needle", root}), 0)
	// Zero results -> exit 1.
	testing.expect_value(t, cmd_search([]string{"doma", "search", "absentxyz", root}), 1)
	// Missing query -> exit 2.
	testing.expect_value(t, cmd_search([]string{"doma", "search"}), 2)
}
