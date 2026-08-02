# Semantic versioning & automated releases (via Cocogitto)

## Goal

`doma --version` reports the exact release it was built from, and public
releases (bump, changelog, tag, binaries) happen with no hand-written version
or tag — Cocogitto derives everything from the conventional-commit history the
project already writes.

## Tool

[Cocogitto](https://github.com/cocogitto/cocogitto) (`cog`), pinned in the
flake dev shell (nixpkgs `cocogitto` 7.0.0). It owns bumping, changelog, and
commit-convention checking; we write no release logic of our own. This replaces
the earlier release-please design.

**Behavioral note:** unlike a release-PR bot, `cog bump --auto` releases
*directly on push to `main`* — it computes the next version from commits since
the last tag, writes the changelog, commits, and tags in one step. There is no
"Release vX.Y.Z" PR to gate the release. That is Cocogitto's model, accepted by
choosing it.

## Source of truth

Git tags are Cocogitto's version state; `cog bump --auto` reads the latest
`vX.Y.Z` tag and the commits since it. A pre-bump hook mirrors the new number
into `version.txt` at the repo root so the *build* has a hermetic file to read
without invoking git:

```
0.1.0
```

`cog.toml`:

```toml
tag_prefix = "v"
pre_bump_hooks = ["echo {{version}} > version.txt"]

[changelog]
path = "CHANGELOG.md"
```

The bump commit therefore contains both the changelog entry and the updated
`version.txt`, and carries tag `vX.Y.Z`. Nothing else stores a version, so
nothing drifts.

## Binary injection

`cli.odin` reads the version from a build-time define:

```odin
VERSION :: #config(DOMA_VERSION, "0.0.0-dev")
```

- **Local (nix `build`/`run`):** inject `$(cat version.txt)-dev`, e.g.
  `0.1.0-dev` — honestly marks a working-tree build as newer than the tagged
  release of the same number. No git call; build stays hermetic.
- **CI release build:** inject the tag with `v` stripped
  (`${GITHUB_REF_NAME#v}`) so the binary's version equals the release exactly.
- Bare `odin build` with no define falls back to `0.0.0-dev`.

## CLI surface

`run()` gains a case:

```odin
case "version", "-v", "--version":
    fmt.printfln("doma %s", VERSION)
    return 0
```

USAGE gets one line: `doma version   show the version`. Output is exactly
`doma 0.1.0\n`. Deterministic — a compiled-in constant, no wall clock, no git.

## CI workflows

1. **`.github/workflows/release.yml`** (existing) grows a release job that runs
   before the binary build, on push to `main`:

   ```yaml
   on:
     push:
       branches: [main]

   jobs:
     release:
       runs-on: ubuntu-latest
       permissions: { contents: write }
       outputs:
         version: ${{ steps.cog.outputs.version }}
       steps:
         - uses: actions/checkout@v4
           with: { fetch-depth: 0 }        # cog needs full history
         - id: cog
           uses: oknozor/cocogitto-action@v3
           with:
             release: true                 # runs `cog bump --auto`
             check: true                   # `cog check` gates on bad commits
             git-user: 'doma-bot'
             git-user-email: 'doma@sendz.net'
   ```

   When commits since the last tag warrant a release, this pushes the bump
   commit and tag `vX.Y.Z` and creates the GitHub Release with the changelog.
   When they don't (only `docs:`/`chore:`/etc.), it no-ops.

2. The existing **binary matrix build** stays, but is gated on a release having
   happened and injects the version:
   - Trigger the build job `needs: release` and `if: steps…outputs.version` (or
     keep the separate `push: tags: v*` trigger — the bot's tag push fires it).
   - Build step adds `-define:DOMA_VERSION=${GITHUB_REF_NAME#v}` beside
     `-o:speed`.
   - Drop `generate_release_notes: true`; Cocogitto wrote the notes.
     softprops/action-gh-release uploads the three binaries to the existing
     release for the tag.

   Chosen wiring (tag-triggered build) keeps the two concerns in separate
   workflow files and avoids passing job outputs across them; the release
   workflow only bumps, the tag-triggered `release.yml` only builds+uploads.

## Bootstrapping

The repo has no tags yet. First release: either let the first push to `main`
auto-bump to `0.1.0`, or seed it once with `cog bump --version 0.1.0` locally
and push the tag. `version.txt` is seeded with `0.1.0` so local builds report a
sensible number before the first CI release.

## Testing

A golden test asserts `run` prints the compiled-in version. Under `odin test`
no define is set, so it pins `doma 0.0.0-dev\n`, proving the wiring without
depending on any tag.

## Out of scope

- Pre-release / build-metadata channels (`cog bump --pre`). Available if a
  release train needs them; not wired now.
- Compiler/target triple in `--version` output. Plain number chosen.
- `cocogitto-bot` GitHub App PR status checks. Nice-to-have; not required.

## Files touched

- `cog.toml` — new; Cocogitto config (tag prefix, pre-bump hook, changelog).
- `version.txt` — new; hermetic build input, written by the pre-bump hook.
- `flake.nix` — add `cocogitto` to the dev shell; `build`/`run` inject
  `DOMA_VERSION` from `version.txt`.
- `.github/workflows/release.yml` — add the Cocogitto release job; inject the
  define; drop generated notes.
- `.github/workflows/check.yml` — optional: `cog check` on PRs (or fold into an
  existing CI workflow) so bad commit messages fail early.
- `src/cli.odin` — `VERSION` const, `version` case, USAGE line.
- `src/*_test.odin` — pin `--version` output.
- `CHANGELOG.md` — created and owned by Cocogitto on first release.
