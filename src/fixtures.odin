package doma

// ## Changes
// - 2026-07-29: Seeded fixture generator — fixtures are code, never downloaded
//   (DESIGN.md §9). Deterministic splitmix64, no OS randomness.

import "core:fmt"
import "core:strings"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rng_pick :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

@(private = "file")
VOCAB := []string{
	"alpha", "beta", "gamma", "delta", "needle", "target", "vector", "matrix",
	"buffer", "cache", "index", "search", "token", "chunk", "score", "query",
}

// Generate n_files deterministic markdown files with headings, prose, and a fenced block.
gen_fixture_tree :: proc(seed: u64, n_files: int, allocator := context.allocator) -> []Src_File {
	r := Rng{state = seed}
	out := make([]Src_File, n_files, allocator)
	for i in 0 ..< n_files {
		b := strings.builder_make(allocator)
		fmt.sbprintf(&b, "# Doc %d\n\n", i)
		sections := 1 + rng_pick(&r, 3)
		for s in 0 ..< sections {
			fmt.sbprintf(&b, "## Section %d %s\n\n", s, VOCAB[rng_pick(&r, len(VOCAB))])
			words := 8 + rng_pick(&r, 24)
			for w in 0 ..< words {
				strings.write_string(&b, VOCAB[rng_pick(&r, len(VOCAB))])
				strings.write_byte(&b, ' ' if w % 12 != 11 else '\n')
			}
			strings.write_string(&b, "\n\n```\n# not a heading\ncode line\n```\n\n")
		}
		out[i] = Src_File{
			relpath = fmt.aprintf("doc_%04d.md", i, allocator = allocator),
			bytes   = transmute([]u8)strings.to_string(b),
		}
	}
	return out
}
