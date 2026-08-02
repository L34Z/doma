package doma

// ## Changes
// - 2026-08-01: .gitignore respect by offloading to `git check-ignore`. Git's own matcher
//   (nested .gitignore, negation, **, core.excludesFile) for near-zero code, as a SOFT
//   dependency: if git is missing or the tree is not a repo, filtering is skipped and every
//   path is kept, so doma still runs standalone. Index-time only — the search path never
//   forks git. Batched over argv (one subprocess per GITIGNORE_CHUNK paths).

import "core:os"
import "core:strings"

// Paths per `git check-ignore` invocation: keeps a huge tree well under ARG_MAX while
// forking git only a handful of times.
GITIGNORE_CHUNK :: 1024

// filter_gitignored returns the subset of `paths` (project-root-relative) that git does
// NOT ignore, delegating to `git check-ignore` run with cwd = `root`. It batches paths over
// argv and parses stdout — one ignored path per line. Input order is preserved.
// `core.quotePath=false` keeps non-ASCII paths raw; `--` ends option parsing.
//
// Soft dependency: git absent (exec error) or `root` not a repo (git exits 128) → keep
// every path, no filtering. `git check-ignore` exits 0 when some paths are ignored and 1
// when none are; both are normal and must not be treated as failure.
// Honest limit: a path containing a literal newline can't be round-tripped this way (git
// would quote it); such names are pathological and simply won't be filtered.
filter_gitignored :: proc(root: string, paths: []string, allocator := context.allocator) -> []string {
	if len(paths) == 0 do return paths

	ignored := make(map[string]bool, allocator)
	off := 0
	for off < len(paths) {
		hi := min(off + GITIGNORE_CHUNK, len(paths))

		cmd := make([dynamic]string, allocator)
		append(&cmd, "git", "-c", "core.quotePath=false", "check-ignore", "--")
		append(&cmd, ..paths[off:hi])

		desc := os.Process_Desc{working_dir = root, command = cmd[:]}
		state, stdout, _, err := os.process_exec(desc, allocator)
		if err != nil || state.exit_code >= 128 {
			// git missing or not a repo: abandon filtering entirely, keep everything.
			return paths
		}

		// stdout is the ignored paths, one per line (empty when none in this chunk).
		for line in strings.split_lines(string(stdout), allocator) {
			rec := strings.trim_space(line)
			if len(rec) > 0 do ignored[rec] = true
		}
		off = hi
	}

	if len(ignored) == 0 do return paths
	kept := make([dynamic]string, 0, len(paths), allocator)
	for p in paths do if !ignored[p] do append(&kept, p)
	return kept[:]
}
