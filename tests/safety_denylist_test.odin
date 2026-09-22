// Tests for src/safety denylist + redact + facade.
package tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "src:platform"
import "src:safety"
import "src:util"

@(test)
denylist_blocks_sensitive_paths :: proc(t: ^testing.T) {
	d: safety.Deny_List
	safety.denylist_init(&d, context.allocator)
	defer safety.denylist_destroy(&d)

	testing.expect(t, safety.is_denied(&d, "/project/.env"))
	testing.expect(t, safety.is_denied(&d, "/project/.env.local"))
	testing.expect(t, safety.is_denied(&d, "/deep/nested/dir/server.pem"))
	testing.expect(t, safety.is_denied(&d, "/home/u/.ssh/id_rsa"))
	testing.expect(t, safety.is_denied(&d, "/x/my-credentials.json"))
	testing.expect(t, safety.is_denied(&d, "/x/.aws/credentials"))
	testing.expect(t, safety.is_denied(&d, "/x/.gnupg/anything"))

	testing.expect(t, !safety.is_denied(&d, "/project/src/main.go"))
	testing.expect(t, !safety.is_denied(&d, "/project/README.md"))
	testing.expect(t, !safety.is_denied(&d, "/project/Makefile"))

	// Credential-container shapes still deny: hidden dotfiles,
	// extensionless files, and the data extensions.
	testing.expect(t, safety.is_denied(&d, "/x/.token"))
	testing.expect(t, safety.is_denied(&d, "/x/.token_github"))
	testing.expect(t, safety.is_denied(&d, "/x/token"))
	testing.expect(t, safety.is_denied(&d, "/x/tokens"))
	testing.expect(t, safety.is_denied(&d, "/x/token.txt"))
	testing.expect(t, safety.is_denied(&d, "/x/tokens.json"))
	testing.expect(t, safety.is_denied(&d, "/x/client_secrets.json"))
	testing.expect(t, safety.is_denied(&d, "/x/db_credentials.yaml"))
	testing.expect(t, safety.is_denied(&d, "/x/credentials"))
	testing.expect(t, safety.is_denied(&d, "/x/.credentials_gcp"))

	// Source files whose names merely contain the words are not deny
	// material — an unsuffixed name-loose pattern once made these
	// invisible to the index and every read tool.
	testing.expect(t, !safety.is_denied(&d, "/project/src/tokenizer.odin"))
	testing.expect(t, !safety.is_denied(&d, "/project/src/token.odin"))
	testing.expect(t, !safety.is_denied(&d, "/project/bench/tokenize_par.odin"))
	testing.expect(t, !safety.is_denied(&d, "/project/secrets.go"))
	testing.expect(t, !safety.is_denied(&d, "/project/credentials_store.go"))
	testing.expect(t, !safety.is_denied(&d, "/project/token.rs"))

	// Percent-encoded paths decode before matching.
	testing.expect(t, safety.is_denied(&d, "/project/%2Eenv"))
}

@(test)
denylist_custom_pattern :: proc(t: ^testing.T) {
	d: safety.Deny_List
	safety.denylist_init(&d, context.allocator)
	defer safety.denylist_destroy(&d)

	err := safety.denylist_add_pattern(&d, "**/internal_only/**")
	testing.expect(t, err == nil)
	testing.expect(t, safety.is_denied(&d, "/repo/internal_only/x.go"))

	// Duplicates are ignored.
	_ = safety.denylist_add_pattern(&d, "**/internal_only/**")
}

@(test)
write_denied_gates :: proc(t: ^testing.T) {
	w: safety.Write_Denied_Tables
	safety.write_denied_init(&w, context.allocator)
	defer safety.write_denied_destroy(&w)

	testing.expect(t, safety.is_write_denied(&w, "/etc/passwd"))
	testing.expect(t, safety.is_write_denied(&w, "/etc/ssh/sshd_config"))

	home, found := os.lookup_env_alloc("HOME", context.temp_allocator)
	if found && home != "" {
		ssh_config := strings.concatenate({home, "/.ssh/config"}, context.temp_allocator)
		testing.expect(t, safety.is_write_denied(&w, ssh_config))
		authorized := strings.concatenate({home, "/.ssh/authorized_keys"}, context.temp_allocator)
		testing.expect(t, safety.is_write_denied(&w, authorized))
		bashrc := strings.concatenate({home, "/.bashrc"}, context.temp_allocator)
		testing.expect(t, safety.is_write_denied(&w, bashrc))
		inside_ssh := strings.concatenate({home, "/.ssh/some/new/key"}, context.temp_allocator)
		testing.expect(t, safety.is_write_denied(&w, inside_ssh))
		normal := strings.concatenate({home, "/projects/main.go"}, context.temp_allocator)
		testing.expect(t, !safety.is_write_denied(&w, normal))
	}

	// Env expansion that empties a segment fails closed.
	testing.expect(t, safety.is_write_denied(&w, "a/$UNSET_VAR_ENTIRELY/b"))
}

@(test)
write_denied_dir_prefix_rule :: proc(t: ^testing.T) {
	// The daemon-level location rule: the resolved managed state directory
	// denies its whole tree, whatever the folder template named it.
	w: safety.Write_Denied_Tables
	safety.write_denied_init(&w, context.allocator)
	defer safety.write_denied_destroy(&w)

	safety.write_denied_add_dir_prefix(&w, "/proj/.state")
	testing.expect(t, safety.is_write_denied(&w, "/proj/.state"))
	testing.expect(t, safety.is_write_denied(&w, "/proj/.state/aubade.db"))
	testing.expect(t, safety.is_write_denied(&w, "/proj/.state/memories/note.md"))
	// Neighbor spellings that share the prefix but not the segment stay
	// writable, and ordinary project paths are untouched.
	testing.expect(t, !safety.is_write_denied(&w, "/proj/.state-other/x"))
	testing.expect(t, !safety.is_write_denied(&w, "/proj/src/main.go"))
	// An empty directory drops the rule instead of degrading into a
	// deny-everything prefix.
	safety.write_denied_add_dir_prefix(&w, "")
	testing.expect(t, !safety.is_write_denied(&w, "/unrelated/file"))
}

@(test)
read_ask_heuristics :: proc(t: ^testing.T) {
	testing.expect(t, safety.is_read_ask("/project/.env"))
	testing.expect(t, safety.is_read_ask("/project/creds.pem"))
	testing.expect(t, safety.is_read_ask("/project/service-account-prod.json"))
	testing.expect(t, safety.is_read_ask("/home/u/.ssh/known_hosts"))
	testing.expect(t, safety.is_read_ask("/home/u/.aws/something"))
	testing.expect(t, !safety.is_read_ask("/project/src/main.go"))
	testing.expect(t, !safety.is_read_ask("/project/notes.txt"))
}

@(test)
sensitive_system_paths :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// /etc, /boot, /var/run are Linux-only paths; skip on Windows.
		return
	}
	testing.expect(t, safety.is_sensitive_system_path("/etc/passwd"))
	testing.expect(t, safety.is_sensitive_system_path("/etc/nginx/nginx.conf"))
	testing.expect(t, safety.is_sensitive_system_path("/boot/vmlinuz"))
	testing.expect(t, safety.is_sensitive_system_path("/var/run/docker.sock"))
	testing.expect(t, !safety.is_sensitive_system_path("/home/u/project/main.go"))
	testing.expect(t, !safety.is_sensitive_system_path("/tmp/x"))
}

@(test)
filepath_match_go_parity :: proc(t: ^testing.T) {
	testing.expect(t, safety.filepath_match("*.go", "main.go"))
	testing.expect(t, !safety.filepath_match("*.go", "main.go.txt"))
	testing.expect(t, safety.filepath_match("a?c", "abc"))
	testing.expect(t, !safety.filepath_match("a?c", "abbc"))
	testing.expect(t, safety.filepath_match("[a-z][0-9].txt", "a1.txt"))
	testing.expect(t, !safety.filepath_match("[a-z][0-9].txt", "A1.txt"))
	testing.expect(t, safety.filepath_match("[^a].txt", "b.txt"))
	testing.expect(t, !safety.filepath_match("[^a].txt", "a.txt"))
	testing.expect(t, safety.filepath_match("a*b*c", "abc"))
	testing.expect(t, safety.filepath_match("a*b*c", "aXbYc"))
}

@(test)
redact_scrubs_secrets :: proc(t: ^testing.T) {
	r: safety.Redactor
	safety.redactor_init(&r, context.temp_allocator)
	defer safety.redactor_destroy(&r)

	// Vendor prefixes.
	out, err := safety.redact(&r, "key is sk-abcdefghij1234 here", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, "sk-abcdefghij1234"))
	testing.expect(t, strings.contains(out, "[REDACTED]"))

	// Bearer token keeps the prefix.
	out, err = safety.redact(&r, "Authorization: Bearer eyJhbGciOi", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, "Authorization: Bearer [REDACTED]"))

	// Private key blocks.
	out, err = safety.redact(&r, "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, "[REDACTED PRIVATE KEY]"))

	// Env-style secrets keep the name.
	out, err = safety.redact(&r, "MY_API_KEY=supersecret123", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, "MY_API_KEY="))
	testing.expect(t, !strings.contains(out, "supersecret123"))

	// Quoted multi-word secret values redact whole: the value class spans
	// whitespace inside the quotes (the old class stopped at \s and
	// redacted only the first word, leaking the tail).
	out, err = safety.redact(&r, `SECRET="my secret tail"`, context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, `SECRET="[REDACTED]"`), out)
	testing.expect(t, !strings.contains(out, "secret tail"), out)

	out, err = safety.redact(&r, `PASSWORD="don't leak this"`, context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, "leak this"), out)

	out, err = safety.redact(&r, "TOKEN='abc def'", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, "TOKEN='[REDACTED]'"), out)

	// An unterminated quoted value still redacts to end of line.
	out, err = safety.redact(&r, `API_KEY="abc def`, context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, "abc def"), out)

	// JSON secrets keep the key.
	out, err = safety.redact(&r, `{"api_key": "abc123def456"}`, context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, `"api_key": "[REDACTED]"`))

	// DB connection strings.
	out, err = safety.redact(&r, "postgres://user:secretpw@host:5432/db", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, strings.contains(out, "postgres://user:[REDACTED]@host:5432/db"))

	// URL userinfo and sensitive query params.
	out, err = safety.redact(&r, "https://user:pass@example.com/path?token=abc&x=1", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, ":pass@"))
	testing.expect(t, !strings.contains(out, "token=abc"))

	// Plain text passes through.
	out, err = safety.redact(&r, "just some normal text with no secrets", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect_value(t, out, "just some normal text with no secrets")
}

@(test)
safety_facade_composition :: proc(t: ^testing.T) {
	s: safety.Safety_Checker
	safety.safety_checker_init(&s, context.allocator)
	defer safety.safety_checker_destroy(&s)

	testing.expect(t, safety.is_denied(&s.deny_list, "/x/.env"))
	testing.expect(t, !safety.is_denied(&s.deny_list, "/x/main.go"))
	out, rerr := safety.redact_content(&s, "token is ghp_abcdefghij1234", context.temp_allocator)
	testing.expectf(t, rerr == nil, "redact_content: %v", rerr)
	testing.expect(t, !strings.contains(out, "ghp_abcdefghij1234"))
	env := safety.scrub_environment(&s, {"PATH=/usr/bin", "HOME=/root"}, context.temp_allocator)
	testing.expect_value(t, len(env), 2)
}

// A rule that blows its regex budget must refuse the output — a truncated
// pass would hand back partially redacted text.
@(test)
redact_fails_closed_on_budget_exhaustion :: proc(t: ^testing.T) {
	r: safety.Redactor
	safety.redactor_init(&r, context.temp_allocator)
	defer safety.redactor_destroy(&r)

	err := safety.redactor_add_pattern(&r, `(a+)+$`)
	testing.expect(t, err == nil)

	pathological := make([dynamic]u8, 0, 4096, context.temp_allocator)
	for _ in 0..<4000 {
		append(&pathological, 'a')
	}
	append(&pathological, 'b')
	subject := string(pathological[:])
	pathological = nil

	out, rerr := safety.redact(&r, subject, context.temp_allocator)
	testing.expectf(t, rerr != nil, "budget-exhausting rule must fail closed")
	testing.expect(t, strings.contains(platform.err_message(rerr, context.temp_allocator), "redaction incomplete"))
	testing.expect_value(t, out, "")
}

@(test)
sensitive_system_path_predicate :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// /etc, /boot, /var/run are Linux-only paths; skip on Windows.
		return
	}
	testing.expect(t, safety.is_sensitive_system_path("/etc/passwd"))
	testing.expect(t, safety.is_sensitive_system_path("/boot/vmlinuz"))
	testing.expect(t, safety.is_sensitive_system_path("/usr/lib/systemd/systemd"))
	testing.expect(t, safety.is_sensitive_system_path("/var/run/docker.sock"))
	testing.expect(t, !safety.is_sensitive_system_path("/home/u/project/main.go"))
	testing.expect(t, !safety.is_sensitive_system_path("/project/README.md"))
}

@(test)
urlguard_user_patterns_block_and_skip_invalid :: proc(t: ^testing.T) {
	s: safety.Safety_Checker
	safety.safety_checker_init(&s, context.allocator)
	defer safety.safety_checker_destroy(&s)

	ok, _ := safety.urlguard_add_blocked_pattern(&s.url_guard, `(?i)^https://evil\.example\.com`, "test deny")
	testing.expect(t, ok)
	// An invalid regex is reported and skipped, not fatal to the guard.
	bad, _ := safety.urlguard_add_blocked_pattern(&s.url_guard, `([unclosed`, "broken")
	testing.expect(t, !bad)

	blocked, _ := safety.check_url(&s, "https://evil.example.com/x")
	testing.expect(t, blocked)
	passed, _ := safety.check_url(&s, "https://good.example.org/x")
	testing.expect(t, !passed)
}

@(test)
util_limit_length :: proc(t: ^testing.T) {
	testing.expect_value(t, util.limit_length("short", 100, nil), "short")
	testing.expect_value(t, util.limit_length("short", 0, nil), "short")

	long := "x"
	for _ in 0..<300 {
		long = strings.concatenate({long, "x"}, context.temp_allocator)
	}
	// The reference returns the plain too-long message when no shortened
	// version fits — even when the message itself exceeds the cap.
	out := util.limit_length(long, 50, nil, context.temp_allocator)
	testing.expect(t, strings.contains(out, "The answer is too long"))
	testing.expect(t, !strings.contains(out, "xxxxxxxxxxxxxxxx"))

	// Candidates are tried in order after the too-long notice; the
	// first that fits wins.
	shortened := []string{"SHORT SUMMARY"}
	out2 := util.limit_length(long, 200, shortened, context.temp_allocator)
	testing.expect(t, strings.contains(out2, "SHORT SUMMARY"))
	testing.expect(t, len(out2) <= 200)

	// The cap counts characters, not bytes: 9 CJK characters are 27
	// bytes and must fit a 10-character cap (a byte count would cut them
	// at a third).
	cjk := "日本語テキストです"
	testing.expect_value(t, util.limit_length(cjk, 10, nil), cjk)
	out3 := util.limit_length(cjk, 5, nil, context.temp_allocator)
	testing.expect(t, strings.contains(out3, "too long"))
}


// Every hardcoded rule must compile and load: a pattern regression that
// silently dropped a rule would leave its secret class unredacted (the
// loader logs, this count turns it into a CI failure).
@(test)
redactor_default_rules_all_load :: proc(t: ^testing.T) {
	r: safety.Redactor
	safety.redactor_init(&r, context.temp_allocator)
	defer safety.redactor_destroy(&r)

	testing.expect_value(t, len(r.rules), 9)
}

@(test)
redact_query_params :: proc(t: ^testing.T) {
	r: safety.Redactor
	safety.redactor_init(&r, context.temp_allocator)
	defer safety.redactor_destroy(&r)

	// x-amz-signature defeats the env-secret rule via its hyphens — only
	// the url_query_params rule catches it.
	out, err := safety.redact(&r, "https://example.com/p?x-amz-signature=deadbeef9876&ok=1", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, "deadbeef9876"), out)
	testing.expect(t, strings.contains(out, "x-amz-signature=[REDACTED]"), out)
	testing.expect(t, strings.contains(out, "ok=1"), out)
	testing.expect(t, strings.contains(out, "https://example.com/p?"), out)

	// Fragment survives; a percent-encoded key decodes before matching.
	out, err = safety.redact(&r, "http://h.io/x?api%5Fkey=z9z9z9z9z9#frag", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect(t, !strings.contains(out, "z9z9z9z9z9"), out)
	testing.expect(t, strings.contains(out, "#frag"), out)

	// Non-sensitive queries pass through untouched.
	out, err = safety.redact(&r, "https://example.com/s?q=hello+world&page=2", context.temp_allocator)
	testing.expectf(t, err == nil, "redact: %v", err)
	testing.expect_value(t, out, "https://example.com/s?q=hello+world&page=2")
}

@(test)
write_denied_case_variants_follow_fs :: proc(t: ^testing.T) {
	w: safety.Write_Denied_Tables
	safety.write_denied_init(&w, context.allocator)
	defer safety.write_denied_destroy(&w)

	// The comparison helpers carry the filesystem's case sensitivity for
	// the write gate's exact/prefix tables: a case-varied spelling of a
	// denied path must not bypass the gate on macOS/Windows, while on
	// case-sensitive systems distinct spellings are distinct files.
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		testing.expect(t, safety.deny_path_eq("/Users/Foo/.ssh/id_rsa", "/users/foo/.ssh/id_rsa"))
		testing.expect(t, safety.deny_path_prefix("/Users/Foo/.SSH/config", "/users/foo/.ssh/"))
		testing.expect(t, safety.is_write_denied(&w, "/ETC/PASSWD"))
	} else {
		testing.expect(t, !safety.deny_path_eq("/a/B", "/a/b"))
		testing.expect(t, safety.deny_path_eq("/a/B", "/a/B"))
		testing.expect(t, !safety.deny_path_prefix("/a/B/x", "/a/b/"))
		testing.expect(t, !safety.is_write_denied(&w, "/ETC/PASSWD"))
	}
}

// Without a home directory the write gate must fail closed: the
// home-relative secrets stay denied by their spelling (suffix rules), not
// silently writable. HOME/USERPROFILE are saved, cleared, and restored.
@(test)
write_denied_without_home_falls_back_to_suffixes :: proc(t: ^testing.T) {
	saved_home, had_home := os.lookup_env_alloc("HOME", context.temp_allocator)
	if had_home {
		defer delete(saved_home, context.temp_allocator)
	}
	saved_prof, had_prof := os.lookup_env_alloc("USERPROFILE", context.temp_allocator)
	if had_prof {
		defer delete(saved_prof, context.temp_allocator)
	}
	os.unset_env("HOME")
	os.unset_env("USERPROFILE")
	defer {
		if had_home {
			os.set_env("HOME", saved_home)
		}
		if had_prof {
			os.set_env("USERPROFILE", saved_prof)
		}
	}

	w: safety.Write_Denied_Tables
	safety.write_denied_init(&w, context.allocator)
	defer safety.write_denied_destroy(&w)

	// System paths keep their exact/prefix rules.
	testing.expect(t, safety.is_write_denied(&w, "/etc/passwd"))
	testing.expect(t, safety.is_write_denied(&w, "/etc/ssh/sshd_config"))

	// Home-relative secrets stay denied under any directory.
	testing.expect(t, safety.is_write_denied(&w, "/root/.ssh/authorized_keys"))
	testing.expect(t, safety.is_write_denied(&w, "/home/whoever/.ssh/id_rsa"))
	testing.expect(t, safety.is_write_denied(&w, "/srv/app/.aws/credentials"))
	testing.expect(t, safety.is_write_denied(&w, "/var/tmp/.bashrc"))
	testing.expect(t, safety.is_write_denied(&w, "/x/.config/gh/hosts.yml"))
	testing.expect(t, safety.is_write_denied(&w, "/x/.aubade/auth.yml"))

	// Ordinary project paths stay writable.
	testing.expect(t, !safety.is_write_denied(&w, "/project/src/main.go"))
	testing.expect(t, !safety.is_write_denied(&w, "/project/README.md"))
}

// Two threads hammer every guard read path on one shared checker, the way
// the daemon's web pool does through d.web_safety. A missing or nested
// lock in the read sites deadlocks here (suite timeout) or corrupts the
// shared PCRE2 match_data; a green run is the contract the mutexes hold.
Guard_Hammer_Box :: struct {
	s:      ^safety.Safety_Checker,
	rounds: int,
	failed: bool,
}

guard_hammer_entry :: proc(data: rawptr) {
	box := cast(^Guard_Hammer_Box)data
	for _ in 0..<box.rounds {
		if blocked, _ := safety.check_command(box.s, "rm -rf /"); !blocked {
			box.failed = true
			return
		}
		if blocked, _ := safety.check_command(box.s, "git status"); blocked {
			box.failed = true
			return
		}
		if blocked, _ := safety.check_url(box.s, "https://pastebin.com/x"); !blocked {
			box.failed = true
			return
		}
		if found, _ := safety.check_url_for_secrets(box.s, "https://x.io/?k=sk-abcdefghij12"); !found {
			box.failed = true
			return
		}
		out, rerr := safety.redact_content(box.s, "token ghp_abcdefghij1234 and text", context.temp_allocator)
		leaked := rerr != nil || strings.contains(out, "ghp_abcdefghij1234")
		delete(out, context.temp_allocator)
		if leaked {
			box.failed = true
			return
		}
	}
}

@(test)
shared_guards_survive_concurrent_checks :: proc(t: ^testing.T) {
	s: safety.Safety_Checker
	safety.safety_checker_init(&s, context.allocator)
	defer safety.safety_checker_destroy(&s)

	box := new(Guard_Hammer_Box, context.allocator)
	box^ = {s = &s, rounds = 200}
	defer free(box, context.allocator)

	t1 := thread.create_and_start_with_data(box, guard_hammer_entry, self_cleanup = false, name = "guard-hammer-1")
	t2 := thread.create_and_start_with_data(box, guard_hammer_entry, self_cleanup = false, name = "guard-hammer-2")
	thread.join(t1)
	thread.join(t2)
	free(t1, context.allocator)
	free(t2, context.allocator)
	testing.expect(t, !box.failed, "a guard answered wrongly under contention")
}

@(test)
deny_case_variants_follow_fs :: proc(t: ^testing.T) {
	d: safety.Deny_List
	safety.denylist_init(&d, context.allocator)
	defer safety.denylist_destroy(&d)

	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		// Case-insensitive platforms wrap the globs with (?i): a
		// case-variant spelling of a deny glob still denies.
		testing.expect(t, safety.is_denied(&d, "/project/.ENV"), "ci deny upper .ENV")
		testing.expect(t, safety.is_denied(&d, "/project/SERVER.PEM"), "ci deny upper .PEM")
	} else {
		// Linux compiles the globs case-sensitively (reference
		// behavior): exact spellings deny, variants do not.
		testing.expect(t, safety.is_denied(&d, "/project/.env"), "exact deny")
		testing.expect(t, !safety.is_denied(&d, "/project/.ENV"), "case-sensitive on Linux")
	}
}

@(test)
stored_safety_regexes_survive_a_scratch_reset :: proc(t: ^testing.T) {
	// The deny list and the redactor own their compiled patterns for the
	// checker's whole lifetime, and the session's dispatch loop frees its
	// thread temp after every frame while the checker lives on: the
	// compiles must ride the owner's allocator and keep working after the
	// scratch dies. A temp-backed pattern reads freed memory once the
	// reset lands — this probe scribbles over the reset region to make
	// that failure visible instead of latent.
	d: safety.Deny_List
	safety.denylist_init(&d, context.allocator)
	defer safety.denylist_destroy(&d)

	r: safety.Redactor
	safety.redactor_init(&r, context.allocator)
	defer safety.redactor_destroy(&r)

	mem.free_all(context.temp_allocator)
	noise := make([]u8, 1 << 20, context.temp_allocator)
	for i in 0..<len(noise) {
		noise[i] = 0xAA
	}

	testing.expect(t, safety.is_denied(&d, "/project/.env"), "deny patterns match after the scratch reset")
	out, rerr := safety.redact(&r, "Authorization: Bearer abc123")
	testing.expect(t, rerr == nil, "redaction runs after the scratch reset")
	testing.expect(t, !strings.contains(out, "abc123"), "bearer rule still redacts")
	// redact's return rides the caller's allocator — the test owns it.
	delete(out, context.allocator)

	delete(noise, context.temp_allocator)
}

@(test)
deny_walk_composes_resolution_like_is_denied :: proc(t: ^testing.T) {
	// A real tree reached through a symlinked root: every composed
	// deny-walk decision must equal the full "/"-anchored resolution's,
	// and a symlinked root's children compose from the resolved spelling.
	dir, terr := os.make_directory_temp("", "aubade-denywalk-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}

	real := strings.concatenate({dir, "/real"}, context.allocator)
	defer delete(real, context.allocator)
	link := strings.concatenate({dir, "/link"}, context.allocator)
	defer delete(link, context.allocator)
	subdirs := []string{"/src", "/.ssh", "/docs"}
	for p in subdirs {
		full := strings.concatenate({real, p}, context.allocator)
		_ = os.make_directory_all(full, os.Permissions{.Read_User, .Write_User, .Execute_User})
		delete(full, context.allocator)
	}
	ssh_key := strings.concatenate({real, "/.ssh/id_rsa"}, context.allocator)
	_ = os.write_entire_file_from_string(ssh_key, "x")
	delete(ssh_key, context.allocator)
	main_go := strings.concatenate({real, "/src/main.go"}, context.allocator)
	_ = os.write_entire_file_from_string(main_go, "package main")
	delete(main_go, context.allocator)
	pct := strings.concatenate({real, "/src/a%2Fb.go"}, context.allocator)
	_ = os.write_entire_file_from_string(pct, "package pct")
	delete(pct, context.allocator)
	if lerr := os.symlink(real, link); lerr != nil {
		// No symlink support in this environment (Windows runners lack
		// the privilege): nothing to assert — fail_now here would also
		// skip the defers above and report leaks.
		return
	}

	d: safety.Deny_List
	safety.denylist_init(&d, context.allocator)
	defer safety.denylist_destroy(&d)

	dw: safety.Deny_Walk
	safety.deny_walk_init(&dw, link, context.temp_allocator)
	testing.expect(t, dw.resolved_ok, "root resolution must reach .Resolved")
	// `real` is spelled through the temp dir, which macOS resolves
	// (/var -> /private/var): the walk's root must equal the CANONICAL
	// spelling, not the input one.
	expected_root, _ := safety.pathguard_resolve_symlinks(real, "", context.temp_allocator)
	testing.expect(t, dw.resolved == expected_root, "composed root must be the resolved spelling")

	// Directory entries: parity with the full resolution, and the child
	// state carries the resolved spelling one level deeper.
	src_abs := strings.concatenate({link, "/src"}, context.temp_allocator)
	src_child: safety.Deny_Walk
	fast := safety.deny_walk_entry(&dw, &d, src_abs, "src", &src_child)
	full := safety.is_denied(&d, src_abs)
	testing.expectf(t, fast == full, "src dir: fast %v vs full %v", fast, full)
	testing.expect(t, !fast, "src is not denied")

	// Regular entries under it: the deny decisions agree, the key file is
	// denied through the resolved spelling both ways.
	main_abs := strings.concatenate({src_abs, "/main.go"}, context.temp_allocator)
	fast = safety.deny_walk_entry(&src_child, &d, main_abs, "main.go", nil)
	full = safety.is_denied(&d, main_abs)
	testing.expectf(t, fast == full, "main.go: fast %v vs full %v", fast, full)
	testing.expect(t, !fast)

	ssh_abs := strings.concatenate({link, "/.ssh"}, context.temp_allocator)
	ssh_child: safety.Deny_Walk
	fast = safety.deny_walk_entry(&dw, &d, ssh_abs, ".ssh", &ssh_child)
	full = safety.is_denied(&d, ssh_abs)
	testing.expectf(t, fast == full, ".ssh dir: fast %v vs full %v", fast, full)
	key_abs := strings.concatenate({ssh_abs, "/id_rsa"}, context.temp_allocator)
	fast = safety.deny_walk_entry(&ssh_child, &d, key_abs, "id_rsa", nil)
	full = safety.is_denied(&d, key_abs)
	testing.expectf(t, fast == full, "id_rsa: fast %v vs full %v", fast, full)
	testing.expect(t, fast, "id_rsa must stay denied through the composed path")

	// A '%' in the name forces the fallback, and the child state of a
	// percent-named directory inherits resolved_ok=false so the whole
	// subtree keeps resolving fully.
	pct_abs := strings.concatenate({src_abs, "/a%2Fb.go"}, context.temp_allocator)
	fast = safety.deny_walk_entry(&src_child, &d, pct_abs, "a%2Fb.go", nil)
	full = safety.is_denied(&d, pct_abs)
	testing.expectf(t, fast == full, "percent name: fast %v vs full %v", fast, full)
	pct_dir := strings.concatenate({link, "/x%2Fy"}, context.temp_allocator)
	pct_child: safety.Deny_Walk
	_ = safety.deny_walk_entry(&dw, &d, pct_dir, "x%2Fy", &pct_child)
	testing.expect(t, !pct_child.resolved_ok, "percent-named dir must not compose")

	// An unresolvable root leaves the fast path off: every entry then
	// resolves fully, exactly like is_denied.
	bad: safety.Deny_Walk
	safety.deny_walk_init(&bad, strings.concatenate({dir, "/no-such-root"}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, !bad.resolved_ok)
	ghost := strings.concatenate({dir, "/no-such-root/src"}, context.temp_allocator)
	fast = safety.deny_walk_entry(&bad, &d, ghost, "src", nil)
	full = safety.is_denied(&d, ghost)
	testing.expectf(t, fast == full, "unresolved root: fast %v vs full %v", fast, full)
}
