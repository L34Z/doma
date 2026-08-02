package doma

// ## Changes
// - 2026-07-29: Tests for directory walk + skip rules (DESIGN.md §2, §7).
// - 2026-07-29: Regression test for relative-dir arg producing non-empty relpaths.

import "core:testing"
import "core:os"
import "core:path/filepath"

@(test)
collect_applies_skip_rules_and_sorts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "get temp dir")

	j :: proc(elems: ..string) -> string {
		s, _ := filepath.join(elems)
		return s
	}

	root := j(tmp_dir, "doma_walk_test_6")
	// best-effort cleanup before and after
	os.remove_all(root)
	defer os.remove_all(root)

	mkdir :: proc(t: ^testing.T, path: string) {
		err := os.make_directory(path)
		testing.expect(t, err == nil, "fixture mkdir")
	}
	write :: proc(t: ^testing.T, path, body: string) {
		werr := os.write_entire_file(path, transmute([]u8)body)
		testing.expect(t, werr == nil, "fixture write")
	}
	mkdir(t, root)
	mkdir(t, j(root, "sub"))
	mkdir(t, j(root, "node_modules"))
	mkdir(t, j(root, ".git"))
	write(t, j(root, "b.md"), "# B\n")
	write(t, j(root, "a.md"), "# A\n")
	write(t, j(root, "sub", "c.md"), "# C\n")
	write(t, j(root, "node_modules", "x.md"), "# X\n")
	write(t, j(root, ".git", "y.md"), "# Y\n")
	write(t, j(root, "readme.txt"), "nope\n")

	files, ok := collect_markdown(root, context.temp_allocator)
	testing.expect(t, ok, "dir readable")
	// Skips node_modules and dotted dirs and non-md; sorts by relpath.
	got := make([]string, len(files))
	for file, i in files do got[i] = file.relpath
	want := []string{"a.md", "b.md", j("sub", "c.md")}
	if !testing.expect_value(t, len(got), len(want)) do return
	for i in 0 ..< len(want) do testing.expect_value(t, got[i], want[i])
}

@(test)
collect_markdown_relative_dir_has_nonempty_relpaths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "get temp dir")

	j :: proc(elems: ..string) -> string {
		s, _ := filepath.join(elems)
		return s
	}

	root := j(tmp_dir, "doma_walk_rel_test_1")
	os.remove_all(root)
	defer os.remove_all(root)

	mkdir :: proc(t: ^testing.T, path: string) {
		err := os.make_directory(path)
		testing.expect(t, err == nil, "fixture mkdir")
	}
	write :: proc(t: ^testing.T, path, body: string) {
		werr := os.write_entire_file(path, transmute([]u8)body)
		testing.expect(t, werr == nil, "fixture write")
	}
	mkdir(t, root)
	mkdir(t, j(root, "sub"))
	write(t, j(root, "a.md"), "# A\n")
	write(t, j(root, "sub", "b.md"), "# B\n")

	// Save and restore cwd so other tests are unaffected.
	saved_cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	testing.expect(t, cwd_err == nil, "get cwd")
	defer os.set_working_directory(saved_cwd)
	chdir_err := os.set_working_directory(root)
	testing.expect(t, chdir_err == nil, "chdir to temp root")

	// Call with relative dir "." — the bug caused empty relpaths.
	files, ok := collect_markdown(".", context.temp_allocator)
	testing.expect(t, ok, "collect_markdown should succeed with '.'")
	if !testing.expect_value(t, len(files), 2) do return
	for f in files {
		testing.expect(t, f.relpath != "", "relpath must not be empty")
	}
	want := []string{"a.md", j("sub", "b.md")}
	got := make([]string, len(files))
	for f, i in files do got[i] = f.relpath
	for i in 0 ..< len(want) do testing.expect_value(t, got[i], want[i])
}
