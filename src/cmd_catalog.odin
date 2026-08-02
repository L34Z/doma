package doma

// ## Changes
// - 2026-08-01: `doma catalog` (list) and `doma catalog add <name> <path>` (append). Add
//   writes a new [section] textually so existing comments and formatting survive.

import "core:fmt"
import "core:os"
import "core:strings"

// cmd_catalog lists corpuses or adds one. `root`/`cat` are supplied by cli.run.
cmd_catalog :: proc(root: string, cat: ^Catalog, args: []string) -> int {
	if len(args) <= 2 {
		return catalog_list(cat)
	}
	switch args[2] {
	case "add":
		return catalog_add(root, cat, args[3:])
	case:
		fmt.eprintfln("doma catalog: unknown subcommand %q (try: add)", args[2])
		return 2
	}
}

@(private = "file")
catalog_list :: proc(cat: ^Catalog) -> int {
	if len(cat.corpuses) == 0 {
		fmt.eprintln("doma: catalog has no corpuses")
		return 1
	}
	for c in cat.corpuses {
		mark := ""
		if c.name == cat.default_name do mark = "  (default)"
		fmt.printfln("%s%s", c.name, mark)
		fmt.printfln("  path:    %s", c.path)
		fmt.printfln("  ext:     %s", strings.join(bare_exts(c.exts), ", "))
		if len(c.exclude) > 0 do fmt.printfln("  exclude: %s", strings.join(c.exclude, ", "))
	}
	return 0
}

// bare_exts strips the leading dot from each extension for display: ".odin" -> "odin".
@(private = "file")
bare_exts :: proc(exts: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(exts), allocator)
	for e, i in exts do out[i] = strings.trim_prefix(e, ".")
	return out
}

// catalog_add appends a new [name] section to catalog.ini. `args` is everything after
// `add`: <name> <path> [--ext list] [--exclude list]. Refuses names that duplicate an
// existing corpus, shadow a reserved verb, or collide with the reserved [doma] section.
@(private = "file")
catalog_add :: proc(root: string, cat: ^Catalog, args: []string) -> int {
	name := ""
	path := ""
	ext := ""
	exclude := ""
	positional := 0
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--ext":
			i += 1
			if i >= len(args) { fmt.eprintln("doma catalog add: --ext needs a list"); return 2 }
			ext = args[i]
		case a == "--exclude":
			i += 1
			if i >= len(args) { fmt.eprintln("doma catalog add: --exclude needs a list"); return 2 }
			exclude = args[i]
		case len(a) > 0 && a[0] == '-':
			fmt.eprintfln("doma catalog add: unknown flag %q", a)
			return 2
		case:
			switch positional {
			case 0: name = a
			case 1: path = a
			case:   fmt.eprintln("doma catalog add: expected <name> <path>"); return 2
			}
			positional += 1
		}
		i += 1
	}
	if name == "" || path == "" {
		fmt.eprintln("usage: doma catalog add <name> <path> [--ext list] [--exclude list]")
		return 2
	}
	if name == DOMA_SECTION || is_reserved_verb(name) {
		fmt.eprintfln("doma catalog add: %q is reserved and cannot be a corpus name", name)
		return 2
	}
	if find_corpus(cat, name) != nil {
		fmt.eprintfln("doma catalog add: corpus %q already exists", name)
		return 2
	}

	// Append textually so comments/formatting in the existing file are preserved.
	b := strings.builder_make(context.allocator)
	existing, _ := os.read_entire_file(catalog_file_path(root), context.allocator)
	strings.write_string(&b, string(existing))
	if len(existing) > 0 && existing[len(existing) - 1] != '\n' do strings.write_byte(&b, '\n')
	fmt.sbprintf(&b, "\n[%s]\npath = %s\n", name, path)
	if ext != "" do fmt.sbprintf(&b, "ext = %s\n", ext)
	if exclude != "" do fmt.sbprintf(&b, "exclude = %s\n", exclude)

	if werr := os.write_entire_file(catalog_file_path(root), transmute([]u8)strings.to_string(b)); werr != nil {
		fmt.eprintfln("doma catalog add: cannot write %q", catalog_file_path(root))
		return 2
	}
	fmt.eprintfln("doma: added corpus %q — run `doma index %s`", name, name)
	return 0
}
