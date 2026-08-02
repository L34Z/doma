package doma

// ## Changes
// - 2026-07-29: Highest-density ~200-byte snippet window (DESIGN.md §6).
//   Windowing is an approximation (honest limit, DESIGN.md §8).

import "core:strings"

SNIPPET_BYTES :: 200

// Score a candidate window [ws,we) by (distinct query terms, total hits). Deterministic.
@(private = "file")
window_score :: proc(toks: []Token, query: map[string]bool, ws, we: int) -> (distinct_n, total: int) {
	seen := make(map[string]bool, context.temp_allocator)
	for tok in toks {
		if tok.start < ws || tok.end > we do continue
		if query[tok.text] {
			total += 1
			if !seen[tok.text] {
				seen[tok.text] = true
				distinct_n += 1
			}
		}
	}
	return
}

snippet_of :: proc(src: []u8, chunk: Chunk_Rec, query_terms: []string, allocator := context.allocator) -> string {
	lo := int(chunk.start)
	hi := int(chunk.end)
	region := src[lo:hi]
	toks := tokenize(region, context.temp_allocator) // offsets relative to region
	qset := make(map[string]bool, context.temp_allocator)
	for q in query_terms do qset[q] = true

	// Candidate window starts: each query-term hit position. Fall back to region start.
	best_start := 0
	best_distinct := -1
	best_total := -1
	tried_any := false
	for anchor in toks {
		if !qset[anchor.text] do continue
		ws := anchor.start
		we := min(len(region), ws + SNIPPET_BYTES)
		d, tot := window_score(toks, qset, ws, we)
		tried_any = true
		// Total order: distinct desc, total desc, start asc — fully deterministic.
		if d > best_distinct || (d == best_distinct && tot > best_total) || (d == best_distinct && tot == best_total && ws < best_start) {
			best_distinct = d
			best_total = tot
			best_start = ws
		}
	}
	if !tried_any {
		best_start = 0 // no query hit in chunk: show the head
	}
	we := min(len(region), best_start + SNIPPET_BYTES)

	raw := string(region[best_start:we])
	collapsed := collapse_ws(raw, allocator)
	lead := best_start > 0
	trail := we < len(region)
	b := strings.builder_make(allocator)
	if lead do strings.write_string(&b, "…")
	strings.write_string(&b, collapsed)
	if trail do strings.write_string(&b, "…")
	return strings.to_string(b)
}

// Collapse runs of ASCII whitespace to a single space; trim ends.
@(private = "file")
collapse_ws :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	prev_space := true // trims leading space
	for i in 0 ..< len(s) {
		c := s[i]
		is_sp := c == ' ' || c == '\t' || c == '\n' || c == '\r'
		if is_sp {
			if !prev_space do strings.write_byte(&b, ' ')
			prev_space = true
		} else {
			strings.write_byte(&b, c)
			prev_space = false
		}
	}
	out := strings.to_string(b)
	return strings.trim_right(out, " ")
}
