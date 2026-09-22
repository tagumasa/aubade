// Safety facade: aggregates the deny list, redactor, env guard, the
// write/read gates, the shell guard, and the URL guard behind one checker
// owned by the session/daemon (no package globals).
package safety

import "core:strings"

import "src:platform"

Safety_Checker :: struct {
	deny_list:    Deny_List,
	redactor:     Redactor,
	env_guard:    Env_Guard,
	write_denied: Write_Denied_Tables,
	shell_guard:  Shell_Guard,
	url_guard:    URL_Guard,
}

// safety_checker_init builds a checker with the default rules. Additional
// blocked/allowed shell-command and URL patterns from the merged config
// lists are consumed by the guards when config wiring lands.
safety_checker_init :: proc(s: ^Safety_Checker, a := context.allocator) {
	denylist_init(&s.deny_list, a)
	redactor_init(&s.redactor, a)
	envguard_init(&s.env_guard, a = a)
	write_denied_init(&s.write_denied, a)
	shellguard_init(&s.shell_guard, a)
	urlguard_init(&s.url_guard, a)
}

safety_checker_destroy :: proc(s: ^Safety_Checker) {
	denylist_destroy(&s.deny_list)
	redactor_destroy(&s.redactor)
	envguard_destroy(&s.env_guard)
	write_denied_destroy(&s.write_denied)
	shellguard_destroy(&s.shell_guard)
	urlguard_destroy(&s.url_guard)
}

// redact_content scrubs sensitive patterns from content. Fails closed
// when a rule cannot complete its pass (see redact).
redact_content :: proc(s: ^Safety_Checker, content: string, a := context.allocator) -> (string, platform.Err) {
	return redact(&s.redactor, content, a)
}

// scrub_environment drops env entries whose names are not allowed (the
// checker's env guard — added prefixes take effect).
scrub_environment :: proc(s: ^Safety_Checker, env: []string, a := context.allocator) -> []string {
	return envguard_scrub(&s.env_guard, env, a)
}

// check_command reports whether the shell guard blocks the command.
check_command :: proc(s: ^Safety_Checker, command: string) -> (bool, string) {
	return shellguard_is_blocked(&s.shell_guard, command)
}

// check_sensitive_path reports whether the command references a
// sensitive write target (the shell guard's init-compiled table).
check_sensitive_path :: proc(s: ^Safety_Checker, command: string) -> (bool, string) {
	return shellguard_detect_sensitive_path(&s.shell_guard, command)
}

// check_url reports whether the URL guard blocks the URL; the message
// carries the full "safety: URL blocked: ..." shape callers relay.
check_url :: proc(s: ^Safety_Checker, url: string) -> (bool, string) {
	blocked, reason := urlguard_is_blocked(&s.url_guard, url)
	if !blocked {
		return false, ""
	}
	msg := "safety: URL blocked: "
	return true, strings.concatenate({msg, reason}, context.temp_allocator)
}

// check_url_for_secrets reports whether the URL embeds credentials or
// tokens (raw or percent-encoded).
check_url_for_secrets :: proc(s: ^Safety_Checker, raw_url: string) -> (bool, string) {
	return urlguard_check_for_secrets(&s.url_guard, raw_url)
}
