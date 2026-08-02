package doma

// ## Changes
// - 2026-08-01: filter_gitignored tests. Guarded: skipped when git is unavailable, since the
//   feature is a soft dependency. check-ignore matches path strings, so no files are created.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

@(private = "file")
git_available :: proc() -> bool {
	_, _, _, err := os.process_exec(os.Process_Desc{command = []string{"git", "--version"}}, context.temp_allocator)
	return err == nil
}

@(private = "file")
run_git :: proc(cwd: string, args: ..string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git")
	append(&cmd, ..args)
	_, _, _, _ = os.process_exec(os.Process_Desc{working_dir = cwd, command = cmd[:]}, context.temp_allocator)
}

@(test)
gitignore_filters_in_repo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	if !git_available() do return // soft dependency: skip when git is absent

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_gi_repo"})
	defer os.remove_all(root)
	os.make_directory(root)
	run_git(root, "init", "-q")
	gi, _ := filepath.join({root, ".gitignore"})
	_ = os.write_entire_file(gi, transmute([]u8)string("ignored/\n*.log\n"))

	// check-ignore matches path strings; the files need not exist. Order is preserved.
	kept := filter_gitignored(root, []string{"keep.txt", "ignored/skip.txt", "debug.log"})
	testing.expect(t, slice.equal(kept, []string{"keep.txt"}), "only the non-ignored path survives")
}

@(test)
gitignore_keeps_all_when_not_a_repo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	root, _ := filepath.join({tmp_dir, "doma_gi_norepo"})
	defer os.remove_all(root)
	os.make_directory(root)

	// Not a git repo (and git may be absent): fall back to keeping every path.
	paths := []string{"a.txt", "b.txt"}
	kept := filter_gitignored(root, paths)
	testing.expect(t, slice.equal(kept, paths), "non-repo (or no git) keeps all paths")
}
