package doma

// ## Changes
// - 2026-07-29: Tokenizer — identical at index and query time (DESIGN.md §2).

import "base:runtime"

TOKEN_MAX :: 64 // normalized tokens truncated at 64 bytes (honest limit, DESIGN §8)

Token :: struct {
	text:  string,
	start: int,
	end:   int,
}

@(private = "file") is_ascii_alnum :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
@(private = "file") is_word_byte :: proc(c: u8) -> bool {
	// Word chars: ASCII alnum OR any non-ASCII byte (passes through, DESIGN §2).
	return is_ascii_alnum(c) || c >= 0x80
}
@(private = "file") is_lower :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' }
@(private = "file") is_upper :: proc(c: u8) -> bool { return c >= 'A' && c <= 'Z' }

// Emit one normalized sub-token for source range [s,e): lowercase ASCII, truncate to 64.
@(private = "file") push :: proc(out: ^[dynamic]Token, src: []u8, s, e: int, alloc: runtime.Allocator) {
	if e <= s do return
	n := e - s
	cap_n := min(n, TOKEN_MAX)
	buf := make([]u8, cap_n, alloc)
	for i in 0 ..< cap_n {
		c := src[s + i]
		buf[i] = c + 32 if is_upper(c) else c // ASCII-only fold
	}
	append(out, Token{text = string(buf), start = s, end = e})
}

tokenize :: proc(src: []u8, allocator := context.allocator) -> []Token {
	out := make([dynamic]Token, allocator)
	i := 0
	for i < len(src) {
		if !is_word_byte(src[i]) { i += 1; continue }
		ws := i
		// Extend the word run over word bytes, splitting at lower->UPPER boundaries.
		i += 1
		sub := ws
		for i < len(src) && is_word_byte(src[i]) {
			if is_lower(src[i - 1]) && is_upper(src[i]) {
				push(&out, src, sub, i, allocator)
				sub = i
			}
			i += 1
		}
		push(&out, src, sub, i, allocator)
	}
	return out[:]
}
