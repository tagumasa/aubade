// Shell guard: blocks dangerous commands through regex patterns matched
// against the structurally normalized pipeline (the parser resolves
// quoting, escapes, separators, and substitutions), and optionally enforces
// a fully anchored executable allowlist. Commands the parser cannot
// evaluate deterministically are refused when an allowlist is configured.
// Also carries the sensitive-write-target detection used by shell tooling.
package safety

import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:regex"
import "src:util"

Blocked_Pattern :: struct {
	pattern: string,
	re:      regex.Regex,
	reason:  string,
}

Allowed_Pattern :: struct {
	pattern: string, // anchored spelling as registered
	re:      regex.Regex,
}

Shell_Guard :: struct {
	mu:        sync.Mutex,
	patterns:  [dynamic]Blocked_Pattern,
	allowed:   [dynamic]Allowed_Pattern, // anchored, compiled at registration
	sensitive: [dynamic]regex.Regex,     // write-target patterns, compiled at init
	allocator: mem.Allocator,
}

shellguard_init :: proc(sg: ^Shell_Guard, a := context.allocator) {
	sg.patterns = make([dynamic]Blocked_Pattern, 0, 30, a)
	sg.allowed = make([dynamic]Allowed_Pattern, 0, 4, a)
	sg.sensitive = make([dynamic]regex.Regex, 0, len(SENSITIVE_WRITE_TARGET_PATTERNS), a)
	sg.allocator = a
	shellguard_load_defaults(sg)
}

shellguard_destroy :: proc(sg: ^Shell_Guard) {
	for bp in sg.patterns {
		re := bp.re
		regex.regex_destroy(&re)
		delete(bp.pattern, sg.allocator)
		delete(bp.reason, sg.allocator)
	}
	for ap in sg.allowed {
		re := ap.re
		regex.regex_destroy(&re)
		delete(ap.pattern, sg.allocator)
	}
	for i in 0..<len(sg.sensitive) {
		re := sg.sensitive[i]
		regex.regex_destroy(&re)
	}
	delete(sg.patterns)
	delete(sg.allowed)
	delete(sg.sensitive)
	sg.patterns = nil
	sg.allowed = nil
	sg.sensitive = nil
}

// shellguard_is_blocked reports whether the command should be blocked and
// why ("" when allowed). The pattern loop and the allowlist-size read run
// under the mutex — the rules' PCRE2 match_data serves one thread at a
// time. executable_allowed takes the lock itself, so it runs only after
// this section has released the guard.
shellguard_is_blocked :: proc(sg: ^Shell_Guard, command: string) -> (bool, string) {
	commands, warnings := parse_shell_command(command, context.temp_allocator)
	if len(commands) == 0 {
		return false, ""
	}

	full := normalize_shell_command(command, context.temp_allocator)
	sync.mutex_lock(&sg.mu)
	for _, i in sg.patterns {
		re := sg.patterns[i].re
		if regex.regex_match(&re, full) {
			// The reason string lives until destroy (patterns are never
			// removed), so the view survives the unlock.
			reason := sg.patterns[i].reason
			sync.mutex_unlock(&sg.mu)
			return true, reason
		}
	}
	allowlist_active := len(sg.allowed) > 0
	sync.mutex_unlock(&sg.mu)

	if allowlist_active {
		if len(warnings) > 0 {
			reason := strings.concatenate(
				{"command contains non-deterministic constructs: ", strings.join(warnings[:], "; ", context.temp_allocator) or_else ""},
				context.temp_allocator,
			)
			return true, reason
		}
		for cmd in commands {
			if !shellguard_executable_allowed(sg, cmd.executable) {
				return true, strings.concatenate(
					{"executable \"", cmd.executable, "\" is not in the allowlist"},
					context.temp_allocator,
				)
			}
		}
	}
	return false, ""
}

// shellguard_executable_allowed matches the executable (and its basename)
// against the allowlist's registration-compiled anchored patterns. Takes
// the guard's mutex itself — callers must not already hold it.
shellguard_executable_allowed :: proc(sg: ^Shell_Guard, executable: string) -> bool {
	if executable == "" {
		return false
	}
	sync.mutex_lock(&sg.mu)
	defer sync.mutex_unlock(&sg.mu)
	base := filepath.base(executable)
	for ap in sg.allowed {
		re := ap.re
		if regex.regex_match(&re, executable) || regex.regex_match(&re, base) {
			return true
		}
	}
	return false
}

// shellguard_add_blocked_pattern registers a blocked-command regex.
shellguard_add_blocked_pattern :: proc(sg: ^Shell_Guard, pattern: string, reason: string) -> platform.Err {
	// The guard owns the compiled regex for its lifetime: it rides the
	// guard's allocator, never the ambient temp.
	re, err := regex.compile_regex(pattern, sg.allocator)
	if err != nil {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"invalid blocked-command pattern: ", pattern}, context.temp_allocator),
		}
	}
	sync.mutex_lock(&sg.mu)
	defer sync.mutex_unlock(&sg.mu)
	for bp in sg.patterns {
		if bp.pattern == pattern {
			r := re
			regex.regex_destroy(&r)
			return nil
		}
	}
	append(&sg.patterns, Blocked_Pattern{
		pattern = strings.clone(pattern, sg.allocator),
		re      = re,
		reason  = strings.clone(reason, sg.allocator),
	})
	return nil
}

// shellguard_add_allowed registers an allowlist pattern, anchored and
// compiled once on the guard's allocator; with any pattern present, only
// matching executables run. Anchoring happens here, not at match time:
// the anchored spelling is the one that runs, so it is the one validated
// and stored.
shellguard_add_allowed :: proc(sg: ^Shell_Guard, pattern: string) -> platform.Err {
	anchored := pattern
	if !strings.has_prefix(anchored, "^") {
		anchored = strings.concatenate({"^", anchored}, context.temp_allocator)
	}
	if !strings.has_suffix(anchored, "$") {
		anchored = strings.concatenate({anchored, "$"}, context.temp_allocator)
	}
	// The guard owns the compiled regex for its lifetime: it rides the
	// guard's allocator, never the ambient temp.
	re, err := regex.compile_regex(anchored, sg.allocator)
	if err != nil {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"invalid allowed-command pattern: ", pattern}, context.temp_allocator),
		}
	}
	sync.mutex_lock(&sg.mu)
	defer sync.mutex_unlock(&sg.mu)
	for ap in sg.allowed {
		if ap.pattern == anchored {
			r := re
			regex.regex_destroy(&r)
			return nil
		}
	}
	append(&sg.allowed, Allowed_Pattern{
		pattern = strings.clone(anchored, sg.allocator),
		re      = re,
	})
	return nil
}

// Guard_Default is one row of a default guard table: the pattern and the
// reason it would report live in the same declaration, so the two sides
// cannot drift apart under edit. Shared by the shell and URL guards.
Guard_Default :: struct {
	pattern: string,
	reason:  string,
}

SHELLGUARD_DEFAULTS :: []Guard_Default{
	// rm against / or ~ with recursive+force flags: fused (-rf/-fr) or
	// split (-r … -f in either order), with any other flags around them.
	{pattern = `\brm\s+(?:-\w+\s+)*(?:-\w*r\w*\s+(?:-\w+\s+)*-\w*f\w*|-\w*f\w*\s+(?:-\w+\s+)*-\w*r\w*|-\w*rf\w*|-\w*fr\w*)\s+/`, reason = "recursive delete from root directory"},
	{pattern = `\bmkfs\b`,                                                                                    reason = "filesystem formatting command"},
	{pattern = `\bdd\s+.*\bif=`,                                                                              reason = "raw disk read with dd"},
	{pattern = `\bdd\s+.*\bof=/dev/`,                                                                         reason = "raw disk write with dd"},
	{pattern = `>\s*/dev/sd`,                                                                                 reason = "redirect output to block device (SCSI)"},
	{pattern = `\bcurl\b.*\|\s*\b(?:sh|bash|zsh|ksh|ash|dash|fish|pwsh|powershell|iex)\b`,                    reason = "download and execute via curl (pipe to shell)"},
	{pattern = `\bwget\b.*\|\s*\b(?:sh|bash|zsh|ksh|ash|dash|fish|pwsh|powershell|iex)\b`,                    reason = "download and execute via wget (pipe to shell)"},
	{pattern = `\bchmod\b(?:\s+-[\w]*)*\s+(?:0*777|[ugo=]+rwx|[ugo]*\+rwx)\s+/`,                              reason = "world-writable permissions on absolute path"},
	{pattern = `:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:`,                                              reason = "fork bomb"},
	{pattern = `>\s*/etc/`,                                                                                   reason = "redirect output to system configuration"},
	{pattern = `\brm\s+(?:-\w+\s+)*(?:-\w*r\w*\s+(?:-\w+\s+)*-\w*f\w*|-\w*f\w*\s+(?:-\w+\s+)*-\w*r\w*|-\w*rf\w*|-\w*fr\w*)\s+~`, reason = "recursive delete from home directory"},
	{pattern = `\bfind\s+/(?:\s|$)`,                                                                          reason = "filesystem-wide find from root directory"},
	{pattern = `\bfind\s+(?:~|\$HOME|\$\{HOME\}|(?i:%USERPROFILE%))\s(?:[^\n]*\s)?-delete\b`,                 reason = "find -delete from home directory"},
	{pattern = `\bfind\s+(?:~|\$HOME|\$\{HOME\}|(?i:%USERPROFILE%))\s(?:[^\n]*\s)?-exec\s+(?:[^\n]*\s)?rm\b`, reason = "find -exec rm from home directory"},
	{pattern = `\bfind\s+(?:~|\$HOME|\$\{HOME\}|(?i:%USERPROFILE%))\s[^\n]*\|\s*[^\n]*\bxargs\s+(?:-\S+\s+)*rm\b`, reason = "find from home directory piped into xargs rm"},
	{pattern = `\bblkdiscard\b`,                                                                              reason = "block device discard command"},
	{pattern = `\bwipefs\b.*\s-a\b`,                                                                          reason = "filesystem signature wipe via wipefs"},
	{pattern = `\bshred\b.*\s/dev/`,                                                                          reason = "shred on raw disk device"},
	{pattern = `>\s*/dev/vd`,                                                                                 reason = "redirect output to block device (virtio)"},
	{pattern = `>\s*/dev/xvd`,                                                                                reason = "redirect output to block device (Xen)"},
	{pattern = `>\s*/dev/mmcblk`,                                                                             reason = "redirect output to block device (MMC)"},
	{pattern = `>\s*/dev/mapper`,                                                                             reason = "redirect output to device-mapper target"},
	{pattern = `>\s*/dev/hd`,                                                                                 reason = "redirect output to block device (IDE)"},
	{pattern = `>\s*/dev/nvme`,                                                                               reason = "redirect output to block device (NVMe)"},
	// cmd.exe, PowerShell, and Windows paths are all case-insensitive —
	// the whole Windows-family block matches case-insensitively or it
	// fails open on DEL /S /Q spellings.
	{pattern = `(?i)\bdel\s+(?:/[sq]\s+)+[A-Za-z]:[\\/]?`,                                                    reason = "recursive delete from Windows drive root"},
	{pattern = `(?i)\brmdir\s+(?:/[sq]\s+)+[A-Za-z]:[\\/]?`,                                                  reason = "recursive rmdir from Windows drive root"},
	{pattern = `(?i)\bformat\s+[A-Za-z]:`,                                                                    reason = "Windows disk format command"},
	{pattern = `(?i)\bRemove-Item\s+(?:-[A-Za-z]+\s+)*-Recurse\s+-Force\s+[A-Za-z]:[\\/]?`,                   reason = "PowerShell recursive force delete from drive root"},
	{pattern = `(?i)>\s*[A-Za-z]:[\\/]Windows[\\/]System32`,                                                  reason = "redirect output to Windows system directory"},
	{pattern = `(?i)>\s*[A-Za-z]:[\\/]Windows[\\/]System32[\\/]config`,                                        reason = "redirect output to Windows registry hives"},
}

// compile_default_pattern compiles one default guard pattern and appends
// it to `out`. A default that fails to compile is a build regression: log
// it under `label` and keep going — the default-pattern-count tests in the
// suite fail before such a change can ship. `owns_strings` clones the
// pattern and reason into `a` for tables whose destroy deletes them; the
// urlguard host table borrows its constant-backed strings and passes false.
compile_default_pattern :: proc(
	out:            ^[dynamic]Blocked_Pattern,
	pattern:        string,
	reason:         string,
	label:          string,
	owns_strings:   bool,
	a:              mem.Allocator,
) {
	re, err := regex.compile_regex(pattern, a)
	if err != nil {
		util.log_warning(strings.concatenate({
			label,
			" failed to compile and is INACTIVE: ",
			platform.err_message(err, context.temp_allocator),
		}, context.temp_allocator))
		return
	}
	if owns_strings {
		append(out, Blocked_Pattern{
			pattern = strings.clone(pattern, a),
			re      = re,
			reason  = strings.clone(reason, a),
		})
	} else {
		append(out, Blocked_Pattern{
			pattern = pattern,
			re      = re,
			reason  = reason,
		})
	}
}

shellguard_load_defaults :: proc(sg: ^Shell_Guard) {
	for d in SHELLGUARD_DEFAULTS {
		compile_default_pattern(&sg.patterns, d.pattern, d.reason, "shellguard: default blocked pattern", true, sg.allocator)
	}
	for p in SENSITIVE_WRITE_TARGET_PATTERNS {
		// Same contract as the blocked defaults: a default that fails to
		// compile is a build regression, logged here and turned into a CI
		// failure by the sensitive-table count test.
		re, err := regex.compile_regex(p, sg.allocator)
		if err != nil {
			util.log_warning(strings.concatenate({
				"shellguard: sensitive write-target pattern failed to compile and is INACTIVE: ",
				platform.err_message(err, context.temp_allocator),
			}, context.temp_allocator))
			continue
		}
		append(&sg.sensitive, re)
	}
}

// --- sensitive write-target detection -------------------------------------------

SENSITIVE_WRITE_TARGET_PATTERNS :: []string{
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE)[\\/]\.ssh(?:[\\/]|$)`,
	`(?:^|[/\\=\s])\.env(?:[.\s]|$)`,
	`[\\/](?:etc|boot)[\\/]\S+`,
	`[\\/]dev[\\/](?:sd|nvme|hd|vd|xvd|mmcblk|mapper)`,
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE)[\\/]\.aws(?:[\\/]|$)`,
	`(?:~|\$HOME|\$\{HOME\}|%APPDATA%|\$env:APPDATA|%LOCALAPPDATA%|\$env:LOCALAPPDATA)[\\/](?:\.config[\\/])?gcloud(?:[\\/]|$)`,
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE)[\\/]\.kube(?:[\\/]|$)`,
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE|%APPDATA%|\$env:APPDATA)[\\/]\.gnupg(?:[\\/]|$)`,
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE)[\\/]\.netrc(?:[\\/]|$)`,
	`(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE)[\\/]\.docker(?:[\\/]|$)`,
	`(?:%APPDATA%|\$env:APPDATA|%LOCALAPPDATA%|\$env:LOCALAPPDATA)[\\/]Microsoft[\\/]Protect[\\/]\S+`,
	`(?:%USERPROFILE%|\$env:USERPROFILE)[\\/]AppData[\\/]Roaming[\\/]Microsoft[\\/]Credentials[\\/]\S*`,
	`[\\/]Windows[\\/]System32[\\/]config[\\/]\S+`,
}

is_exclude_like_flag :: proc(flag: string) -> bool {
	switch flag {
	case "--exclude", "--exclude-from", "--include", "--exclude-from-standard":
		return true
	case:
		return false
	}
}

// shellguard_detect_sensitive_path scans the structurally parsed command
// for references to sensitive paths, skipping filter-flag arguments. The
// table is compiled once at init and matched under the mutex — the rules'
// PCRE2 match_data serves one thread at a time.
shellguard_detect_sensitive_path :: proc(sg: ^Shell_Guard, cmd: string) -> (bool, string) {
	commands, _ := parse_shell_command(cmd, context.temp_allocator)
	sync.mutex_lock(&sg.mu)
	defer sync.mutex_unlock(&sg.mu)
	for sub in commands {
		skip_next := false
		for tok in sub.tokens {
			if skip_next {
				skip_next = false
				continue
			}
			if tok.kind != .Word {
				continue
			}
			if is_exclude_like_flag(tok.value) {
				skip_next = true
				continue
			}
			if idx := strings.index(tok.value, "="); idx > 0 {
				if is_exclude_like_flag(tok.value[:idx]) {
					continue
				}
			}
			for i in 0..<len(sg.sensitive) {
				re := sg.sensitive[i]
				if regex.regex_match(&re, tok.value) {
					return true, strings.concatenate(
						{"command targets sensitive path: ", tok.value},
						context.temp_allocator,
					)
				}
			}
		}
	}
	return false, ""
}
