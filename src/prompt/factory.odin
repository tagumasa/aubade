// The template factory: built-in templates by name, shadowed by user
// files under $AUBADE_HOME/prompt_templates/<name>.tmpl (plain text —
// the libyaml containers are gone).
package prompt

import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:util"

PROMPT_TEMPLATES_DIR :: "prompt_templates"

// Size cap for user template files — the same budget config files get. A
// runaway file falls back to the embedded default instead of loading.
MAX_TEMPLATE_BYTES :: 1024 * 1024

// Built-in template bodies, one row per name — the lookup walks the
// table instead of an if-chain, and adding a template is adding a row.
BUILTIN_TEMPLATES :: []struct{name: string, body: string}{
	{name = "system_prompt",             body = SYSTEM_PROMPT_TEMPLATE},
	{name = "cc_system_prompt_override", body = CC_SYSTEM_PROMPT_OVERRIDE},
	{name = "onboarding_prompt",         body = ONBOARDING_PROMPT_TEMPLATE},
}

// template_builtin returns the embedded template body for a name.
template_builtin :: proc(name: string) -> (string, bool) {
	for t in BUILTIN_TEMPLATES {
		if t.name == name {
			return t.body, true
		}
	}
	return "", false
}

// template_by_name resolves a template: a user file wins over the
// embedded default. A missing, non-regular, oversized, or unreadable user
// file falls back to the embedded default. The body is allocated from `a`.
template_by_name :: proc(home, name: string, a := context.allocator) -> (string, bool) {
	parts := []string{home, PROMPT_TEMPLATES_DIR, strings.concatenate({name, ".tmpl"}, context.temp_allocator)}
	path, _ := filepath.join(parts, a)
	delete(parts[len(parts) - 1], context.temp_allocator)
	defer delete(path, a)
	if util.read_gate(path, MAX_TEMPLATE_BYTES) == .Ok {
		if data, err := os.read_entire_file_from_path(path, a); err == nil {
			return string(data), true
		}
	}
	body, ok := template_builtin(name)
	if !ok {
		return "", false
	}
	return strings.clone(body, a), true
}

// template_list_names lists every available template name: the built-ins
// plus the user directory's .tmpl files (sorted, deduplicated, user names
// first-class — a user file with a built-in name shadows it in place).
template_list_names :: proc(home: string, a := context.allocator) -> []string {
	out: [dynamic]string = make([dynamic]string, 0, 8, a)
	defer delete(out)
	seen := make(map[string]bool, 8, a)
	defer delete(seen)

	dir_parts := []string{home, PROMPT_TEMPLATES_DIR}
	dir, _ := filepath.join(dir_parts, context.temp_allocator)
	entries, derr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if derr == nil {
		for e in entries {
			if strings.has_suffix(e.name, ".tmpl") && len(e.name) > 5 {
				name := strings.clone(e.name[:len(e.name) - 5], a)
				if !seen[name] {
					seen[name] = true
					append(&out, name)
				}
			}
		}
		os.file_info_slice_delete(entries, context.temp_allocator)
	}
	for t in BUILTIN_TEMPLATES {
		if !seen[t.name] {
			seen[t.name] = true
			append(&out, strings.clone(t.name, a))
		}
	}
	// Insertion sort (the listing is tiny).
	for i := 1; i < len(out); i += 1 {
		key := out[i]
		j := i - 1
		for j >= 0 && out[j] > key {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = key
	}
	// Copy into an exact-size owned slice before the deferred delete frees
	// the dynamic's backing (a returned view would dangle).
	owned := make([]string, len(out), a)
	copy(owned, out[:])
	return owned
}
