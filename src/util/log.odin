// Leveled stderr diagnostics for the long-running processes (the MCP
// child, the daemon, and their worker threads). This logger is the one
// sanctioned module-level mutable state outside App/Daemon: every
// background thread (reader pumps, stderr pumps, heartbeats) needs it and
// threading a handle through each foundation package would outweigh the
// rule. It is initialized once at process startup, before those threads
// spawn; the level is only ever touched through the mutex.
//
// One-shot CLI results and usage errors keep printing directly — they are
// output, not diagnostics, and must appear regardless of any level.
package util

import "core:fmt"
import "core:strings"
import "core:sync"

Log_Level :: enum {
	Debug,
	Info,
	Warning,
	Error,
}

Log_State :: struct {
	mu:    sync.Mutex,
	level: Log_Level,
}

state: Log_State = {level = .Warning}

log_init :: proc(level: Log_Level) {
	log_set_level(level)
}

log_set_level :: proc(level: Log_Level) {
	sync.mutex_lock(&state.mu)
	state.level = level
	sync.mutex_unlock(&state.mu)
}

log_level :: proc() -> Log_Level {
	sync.mutex_lock(&state.mu)
	l := state.level
	sync.mutex_unlock(&state.mu)
	return l
}

log_enabled :: proc(level: Log_Level) -> bool {
	return level >= log_level()
}

// log_parse_level accepts the four CLI/config spellings, case-insensitive
// (the config loader stores lowercase; the flag keeps the user's casing).
// log_level_string renders the level's canonical lowercase name and is the
// single declaration of the vocabulary: the parser walks it, and messages
// that enumerate the levels build on log_levels_quoted.
log_level_string :: proc(l: Log_Level) -> string {
	switch l {
	case .Debug:   return "debug"
	case .Info:    return "info"
	case .Warning: return "warning"
	case .Error:   return "error"
	}
	return "warning"
}

log_parse_level :: proc(s: string) -> (Log_Level, bool) {
	lower := strings.to_lower(s, context.temp_allocator)
	for l in Log_Level {
		if log_level_string(l) == lower {
			return l, true
		}
	}
	return .Warning, false
}

// log_levels_quoted renders the accepted spellings comma-joined and
// double-quoted ("debug", "info", ...) for messages that enumerate them.
log_levels_quoted :: proc(a := context.allocator) -> string {
	return wire_names(Log_Level, log_level_string, ", ", "\"", a)
}

// log_write emits one line as "aubade <level>: <msg>". The pieces go
// through fmt's value printing, never a format string: '{' inside a
// message would otherwise be parsed as a parameter brace.
log_write :: proc(level: Log_Level, msg: string) {
	if !log_enabled(level) {
		return
	}
	sync.mutex_lock(&state.mu)
	fmt.eprint("aubade ")
	fmt.eprint(log_level_string(level))
	fmt.eprint(": ")
	fmt.eprintln(msg)
	sync.mutex_unlock(&state.mu)
}

log_debug :: proc(msg: string) {
	log_write(.Debug, msg)
}

log_info :: proc(msg: string) {
	log_write(.Info, msg)
}

log_warning :: proc(msg: string) {
	log_write(.Warning, msg)
}

log_error :: proc(msg: string) {
	log_write(.Error, msg)
}
