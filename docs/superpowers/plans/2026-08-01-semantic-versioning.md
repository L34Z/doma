# Semantic Versioning & Automated Releases (Cocogitto) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `doma --version` report the exact built release, and let CI derive version, changelog, tag, and binaries from conventional commits with no hand-written version.

**Architecture:** Cocogitto (`cog`) owns bumping/changelog/tagging, driven by the conventional-commit history the project already writes. Git tags are the version state; a pre-bump hook mirrors the number into `version.txt`, which the build compiles into the binary via an Odin `-define`. One CI workflow bumps on push to `main` (cog pushes the tag), then builds the platform binaries from that tag and attaches them to a GitHub Release whose body is the cog changelog.

**Tech Stack:** Odin (nightly), Nix flake dev shell, Cocogitto 7.0.0 (nixpkgs `cocogitto`), GitHub Actions (`cocogitto/cocogitto-action@v4`, `laytan/setup-odin@v2`, `softprops/action-gh-release@v2`).

## Global Constraints

- Version string source of truth: git tags (prefix `v`), mirrored to `version.txt` at repo root by cog's pre-bump hook. Nothing else stores a version number.
- Odin define name is exactly `DOMA_VERSION`; the in-code constant default is exactly `"0.0.0-dev"`.
- `doma --version` output is exactly `doma <VERSION>\n` (e.g. `doma 0.1.0`).
- Local builds inject `<version.txt contents>-dev`; CI release builds inject the plain number (no `-dev`).
- Under `odin test` no define is set, so `VERSION` is the `0.0.0-dev` default — tests must not depend on any tag.
- Commit messages follow `type: summary` (`feat`, `fix`, `docs`, `chore`, `test`, `bench`, `perf`) per GUIDELINES; `feat` → minor, `fix`/`perf` → patch, `!`/`BREAKING CHANGE` → major.
- Every touched module keeps its dated `## Changes` header block updated (one line per change).
- Keep code free of references to any `.claude/` documents.

---

## File Structure

- `src/cli.odin` (modify) — add `VERSION` constant, `version_line` helper, `version` command case, USAGE line.
- `src/version_test.odin` (create) — pins the `--version` output format.
- `version.txt` (create) — hermetic build input; seeded `0.1.0`, thereafter written by cog.
- `cog.toml` (create) — Cocogitto config: tag prefix, pre/post-bump hooks, changelog path, skip-ci.
- `flake.nix` (modify) — add `cocogitto` to the dev shell; `build`/`run` inject `DOMA_VERSION` from `version.txt`.
- `.github/workflows/release.yml` (rewrite) — bump → build matrix → publish, on push to `main`.
- `.github/workflows/check.yml` (create) — `cog check` on pull requests.
- `CHANGELOG.md` — created and owned by Cocogitto on first release; not authored here.

---

### Task 1: `doma --version` command

**Files:**
- Modify: `src/cli.odin`
- Create: `src/version_test.odin`

**Interfaces:**
- Produces: `VERSION :: string` constant (compile-time `#config`); `version_line :: proc() -> string` returning `"doma <VERSION>"` (allocated in `context.temp_allocator`).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test**

Create `src/version_test.odin`:

```odin
package doma

// ## Changes
// - 2026-08-01: Pin `doma version` output format; under `odin test` the
//   DOMA_VERSION define is unset, so VERSION is the "0.0.0-dev" default.

import "core:testing"

@(test)
version_line_is_name_space_version :: proc(t: ^testing.T) {
	testing.expect_value(t, version_line(), "doma 0.0.0-dev")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test src -define:ODIN_TEST_NAMES=doma.version_line_is_name_space_version`
Expected: FAIL to compile — `version_line` is undefined.

- [ ] **Step 3: Add the constant, helper, command case, and USAGE line**

In `src/cli.odin`, add a line to the `## Changes` header:

```odin
// - 2026-08-01: `version`/`-v`/`--version` print the compiled-in build version;
//   VERSION comes from the DOMA_VERSION define (default "0.0.0-dev").
```

Add below the `import "core:fmt"` line:

```odin
// Baked in at build time via `-define:DOMA_VERSION=...`. The default fires only
// for a bare `odin build` with no define — an honest "unknown dev build" marker.
VERSION :: #config(DOMA_VERSION, "0.0.0-dev")

// Split out so the exact output can be asserted without capturing stdout.
version_line :: proc() -> string {
	return fmt.tprintf("doma %s", VERSION)
}
```

Add a case to the `switch args[1]` in `run`, before the `case:` default:

```odin
	case "version", "-v", "--version":
		fmt.println(version_line())
		return 0
```

Add one line to the `USAGE` string, in the `Usage:` block after the `help` line:

```
  doma version                               show the build version
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test src -define:ODIN_TEST_NAMES=doma.version_line_is_name_space_version`
Expected: PASS.

- [ ] **Step 5: Verify the command end to end**

Run: `odin build . -out:build/doma -define:DOMA_VERSION=9.9.9 && build/doma --version`
Expected: prints exactly `doma 9.9.9`. Then `build/doma version` and `build/doma -v` print the same.

- [ ] **Step 6: Commit**

```bash
git add src/cli.odin src/version_test.odin
git commit -m "feat: doma --version reports the compiled-in build version"
```

---

### Task 2: `version.txt` + flake injects the version

**Files:**
- Create: `version.txt`
- Modify: `flake.nix`

**Interfaces:**
- Consumes: `VERSION`/`DOMA_VERSION` define from Task 1.
- Produces: `version.txt` at repo root (single line, no `v`, trailing newline); `build`/`run` dev-shell commands that inject `DOMA_VERSION=<version.txt>-dev`; `cocogitto` on the dev-shell PATH.

- [ ] **Step 1: Create `version.txt`**

Write `version.txt` with exactly (one line, trailing newline):

```
0.1.0
```

- [ ] **Step 2: Add `cocogitto` to the dev shell**

In `flake.nix`, in the `packages = with pkgs; [ ... ]` list, add `cocogitto` under `gdb`:

```nix
            gdb
            cocogitto # `cog` — conventional-commit bump, changelog, tag
```

- [ ] **Step 3: Inject the version into `build` and `run`**

Replace the `build` script line:

```nix
            (writeShellScriptBin "build" "exec odin build . -out:build/doma \"$@\"")
```

with:

```nix
            (writeShellScriptBin "build" ''
              exec odin build . -out:build/doma \
                -define:DOMA_VERSION="$(cat version.txt)-dev" "$@"
            '')
```

Replace the `run` script:

```nix
            (writeShellScriptBin "run" ''
              odin build . -out:build/doma || exit
              exec build/doma "$@"
            '')
```

with:

```nix
            (writeShellScriptBin "run" ''
              odin build . -out:build/doma \
                -define:DOMA_VERSION="$(cat version.txt)-dev" || exit
              exec build/doma "$@"
            '')
```

Leave the `test` command unchanged — tests must run with the unset-define default (Global Constraints).

- [ ] **Step 4: Verify the injected version**

Run (from repo root, inside the dev shell): `build && build/doma --version`
Expected: prints exactly `doma 0.1.0-dev`.

- [ ] **Step 5: Verify `cog` is available**

Run: `cog --version`
Expected: prints a cocogitto version (e.g. `cog 7.0.0`).

- [ ] **Step 6: Commit**

```bash
git add version.txt flake.nix
git commit -m "feat: flake pins cocogitto and bakes version.txt into local builds"
```

---

### Task 3: `cog.toml` — bump, changelog, tag, push

**Files:**
- Create: `cog.toml`

**Interfaces:**
- Consumes: `version.txt` (written by the pre-bump hook), `VERSION` wiring from Tasks 1–2.
- Produces: repo-root `cog.toml` defining tag prefix `v`, the `version.txt` pre-bump hook, atomic push post-bump hook, `CHANGELOG.md` path, and `[skip ci]` on bump commits.

- [ ] **Step 1: Create `cog.toml`**

Write `cog.toml`:

```toml
# Cocogitto configuration. `cog bump --auto` computes the next version from the
# conventional commits since the latest `v*` tag, mirrors the number into
# version.txt (so the build is hermetic), writes CHANGELOG.md, commits, tags,
# and pushes the commit and tag together.

tag_prefix = "v"
skip_ci = "[skip ci]" # keep the bump commit from re-triggering CI

pre_bump_hooks = [
    "echo {{version}} > version.txt", # the build reads this; no git at build time
]

post_bump_hooks = [
    "git push --atomic origin main v{{version}}",
]

[changelog]
path = "CHANGELOG.md"
```

- [ ] **Step 2: Verify config parses and commits are clean**

Run: `cog check --from-latest-tag || cog check`
Expected: `No errored commits` (or it names a non-conventional commit — if so, that is a real finding, not a plan bug).

- [ ] **Step 3: Verify the computed bump without releasing**

Run: `cog bump --dry-run --auto`
Expected: prints a single version number to stdout (e.g. `0.1.0`) with no error. This performs no commit, tag, or push.

- [ ] **Step 4: Commit**

```bash
git add cog.toml
git commit -m "feat: cocogitto config for auto bump, changelog, and tag push"
```

---

### Task 4: CI — release workflow + PR commit check

**Files:**
- Rewrite: `.github/workflows/release.yml`
- Create: `.github/workflows/check.yml`

**Interfaces:**
- Consumes: `cog.toml` (Task 3), `version.txt` + `DOMA_VERSION` (Tasks 1–2). Relies on the action output `steps.<id>.outputs.version` being the prefixed tag (e.g. `v0.1.0`) or empty when nothing is releasable.
- Produces: on push to `main`, a bumped tag/commit (pushed by cog's post-bump hook), three platform binaries, and a GitHub Release whose body is the cog changelog.

- [ ] **Step 1: Rewrite `.github/workflows/release.yml`**

Replace the whole file with:

```yaml
name: release

# On every push to main, let Cocogitto decide whether the commits warrant a
# release. If they do, it bumps version.txt + CHANGELOG.md, commits, tags, and
# pushes (via cog.toml post-bump hook). We then build the native binaries from
# that tag — Odin can't cross-compile the linker step, so each target builds on
# its own runner — and attach them to a GitHub Release with the cog changelog.
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.cog.outputs.version }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # cocogitto needs the full history

      - id: cog
        # Non-releasable pushes (docs/chore/etc.) make `cog bump` exit non-zero;
        # treat that as "no release" rather than a failed workflow.
        continue-on-error: true
        uses: cocogitto/cocogitto-action@v4
        with:
          command: bump
          args: --auto
          git-user: doma-bot
          git-user-email: doma@sendz.net

  build:
    needs: release
    if: needs.release.outputs.version != ''
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            out: doma-linux-amd64
          - os: macos-14
            out: doma-macos-arm64
          - os: windows-latest
            out: doma-windows-amd64.exe
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ needs.release.outputs.version }} # the tag cog just pushed

      - name: Install Odin
        uses: laytan/setup-odin@v2
        with:
          release: nightly

      - name: Build
        shell: bash
        run: odin build . -out:${{ matrix.out }} -o:speed -define:DOMA_VERSION=$(cat version.txt)

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.out }}
          path: ${{ matrix.out }}

  publish:
    needs: [release, build]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - id: changelog
        uses: cocogitto/cocogitto-action@v4
        with:
          command: changelog
          args: --at ${{ needs.release.outputs.version }}

      - uses: actions/download-artifact@v4
        with:
          path: dist
          merge-multiple: true

      - name: Publish release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ needs.release.outputs.version }}
          body: ${{ steps.changelog.outputs.stdout }}
          files: dist/*
```

- [ ] **Step 2: Create `.github/workflows/check.yml`**

```yaml
name: check

# Fail a pull request early if any of its commits break the conventional-commit
# convention that the release pipeline depends on.
on:
  pull_request:

jobs:
  cog_check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: ${{ github.event.pull_request.head.sha }} # PR HEAD, not the merge commit

      - uses: cocogitto/cocogitto-action@v4
        with:
          command: check
```

- [ ] **Step 3: Validate the workflow YAML**

Run: `actionlint .github/workflows/release.yml .github/workflows/check.yml` if `actionlint` is available; otherwise `python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/release.yml .github/workflows/check.yml`.
Expected: no errors.

- [ ] **Step 4: Note the one operational prerequisite**

The `release` job pushes the bump commit and tag to `main` using the default `GITHUB_TOKEN`. If `main` has branch protection, add an exception so `doma-bot`/`github-actions` can push, or the release job will fail at the push hook. Record this in the PR description; no code change here.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/check.yml
git commit -m "ci: cocogitto-driven release on main and commit check on PRs"
```

---

## Self-Review

**Spec coverage:**
- Binary reports its version → Task 1 (`VERSION`, `version` command, test).
- Single source of truth / hermetic build input → Task 2 (`version.txt`) + Task 3 (pre-bump hook writes it).
- Cocogitto in the flake → Task 2 (dev-shell package).
- Auto bump + changelog + tag → Task 3 (`cog.toml`) + Task 4 (`release` job).
- Binaries attached with cocogitto changelog → Task 4 (`build` + `publish` jobs).
- Commit-convention enforcement → Task 4 (`check.yml`).
- Bootstrapping → `version.txt` seeded `0.1.0` (Task 2); first push to `main` auto-bumps.
- Out-of-scope items (pre-release channels, target triple in output, cocogitto-bot) → intentionally not implemented.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code and config block is literal.

**Type consistency:** `version_line` (defined Task 1) is the only cross-task symbol and is used only in its own test. `DOMA_VERSION`/`VERSION`/`version.txt`/`v{{version}}`/`needs.release.outputs.version` names are consistent across Tasks 1–4. The action output is treated as the prefixed tag (`v0.1.0`) throughout — matching `git describe` in the action's `cog.sh`.
