package doma

// ## Changes
// - 2026-08-01: Catalog model (DESIGN successor: named corpuses). A corpus is a named,
//   filtered view of the tree (path + extensions + excludes); the catalog is the set of
//   them, kept in .doma/catalog.ini at the project root. INI is parsed once at a boundary
//   into a flat, name-sorted []Corpus; every later lookup is a linear scan over a handful
//   of small structs (N is single digits), so no hash map lives on any repeated path.

import "core:encoding/ini"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

CATALOG_DIR  :: ".doma"
CATALOG_FILE :: "catalog.ini"
DOMA_SECTION :: "doma" // reserved [doma] settings section (holds `default`)

// INI parser options: `#` comments (git/toml-familiar) instead of the default `;`.
INI_OPTS :: ini.Options{comment = "#", key_lower_case = false}

// A corpus: a named, filtered view of the tree. Cold, tiny, few instances — plain AoS.
Corpus :: struct {
	name:    string,   // section name; the query alias
	path:    string,   // project-root-relative directory
	exts:    []string, // dot-prefixed, lowercased (".odin"); defaults to Markdown
	exclude: []string, // project-root-relative path prefixes to skip
}

// The parsed catalog. `corpuses` is sorted by name for determinism; `default_name` is the
// corpus a bare `doma <query>` targets ("" when none can be resolved).
Catalog :: struct {
	root:         string, // absolute project root (the dir containing .doma/)
	corpuses:     []Corpus,
	default_name: string,
}

// catalog_file_path is <root>/.doma/catalog.ini.
catalog_file_path :: proc(root: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({root, CATALOG_DIR, CATALOG_FILE}, allocator)
	return p
}

// corpus_index_path is <root>/.doma/<name>.idx — where a built corpus index lives.
corpus_index_path :: proc(root, name: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({root, CATALOG_DIR, strings.concatenate({name, ".idx"}, allocator)}, allocator)
	return p
}

// find_project_root walks up from `start` looking for the nearest ancestor that holds
// .doma/catalog.ini, so `doma <query>` works from any subdirectory (like git finds .git).
// Returns ("", false) if none exists up to the filesystem root.
find_project_root :: proc(start: string, allocator := context.allocator) -> (string, bool) {
	dir, err := filepath.abs(start, allocator)
	if err != nil do return "", false
	for {
		if os.exists(catalog_file_path(dir, allocator)) do return dir, true
		parent := filepath.dir(dir)
		if parent == dir do return "", false // reached the filesystem root
		dir = parent
	}
}

// split_csv splits "a, b ,,c" into {"a","b","c"}: comma-separated, trimmed, blanks dropped.
@(private = "file")
split_csv :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in strings.split(s, ",", allocator) {
		p := strings.trim_space(part)
		if len(p) > 0 do append(&out, p)
	}
	return out[:]
}

// load_catalog reads and parses <root>/.doma/catalog.ini. Returns ok=false if the file is
// absent or unparseable. Corpus sections are every section except "" (stray top-level
// keys) and the reserved [doma]. A section without a `path` is malformed and skipped.
load_catalog :: proc(root: string, allocator := context.allocator) -> (Catalog, bool) {
	data, rerr := os.read_entire_file(catalog_file_path(root, allocator), allocator)
	if rerr != nil do return {}, false
	m, merr := ini.load_map_from_string(string(data), allocator, INI_OPTS)
	if merr != nil do return {}, false

	corpuses := make([dynamic]Corpus, allocator)
	declared_default := ""
	for section, pairs in m {
		if section == "" do continue
		if section == DOMA_SECTION {
			if d, ok := pairs["default"]; ok do declared_default = strings.trim_space(d)
			continue
		}
		path, has_path := pairs["path"]
		if !has_path do continue

		// Clone the default: MARKDOWN_EXTS is a constant whose backing array is a stack
		// temporary at the use site, so it must not be stored in the returned Corpus as-is.
		exts := slice.clone(MARKDOWN_EXTS, allocator)
		if ext_val, ok := pairs["ext"]; ok {
			e := parse_exts(ext_val, allocator) // dot-prefix, lowercase, dedupe
			if len(e) > 0 do exts = e
		}
		exclude: []string
		if exc_val, ok := pairs["exclude"]; ok do exclude = split_csv(exc_val, allocator)

		append(&corpuses, Corpus{
			name    = section,
			path    = strings.trim_space(path),
			exts    = exts,
			exclude = exclude,
		})
	}

	// Sort by name: ini.Map iteration order is nondeterministic, output must not be.
	slice.sort_by(corpuses[:], proc(a, b: Corpus) -> bool { return a.name < b.name })

	cat := Catalog{
		root         = root,
		corpuses     = corpuses[:],
		default_name = resolve_default(corpuses[:], declared_default),
	}
	// Postcondition: names are unique-enough and sorted; the default (if any) exists.
	assert(cat.default_name == "" || find_corpus(&cat, cat.default_name) != nil, "resolved default must name a real corpus")
	return cat, true
}

// resolve_default picks the corpus a bare query targets: the declared [doma] default if it
// names a real corpus, else one named "code", else the sole corpus, else "" (ambiguous).
resolve_default :: proc(corpuses: []Corpus, declared: string) -> string {
	if declared != "" {
		for c in corpuses do if c.name == declared do return declared
	}
	for c in corpuses do if c.name == "code" do return "code"
	if len(corpuses) == 1 do return corpuses[0].name
	return ""
}

// find_corpus returns a pointer to the named corpus, or nil. Linear scan: N is tiny.
find_corpus :: proc(cat: ^Catalog, name: string) -> ^Corpus {
	for &c in cat.corpuses do if c.name == name do return &c
	return nil
}
