// Tests for src/safety/shellcmd.odin. Pure parser; no I/O, no fixtures.
package tests

import "core:strings"
import "core:testing"
import "src:safety"

@(test)
simple_command :: proc(t: ^testing.T) {
	cmds, warns := safety.parse_shell_command("ls -la /tmp", context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) > 0 {
		testing.expect_value(t, cmds[0].executable, "ls")
		testing.expect_value(t, len(cmds[0].args), 2)
	}
	testing.expect_value(t, len(warns), 0)
}

@(test)
empty_input :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("", context.temp_allocator)
	testing.expect_value(t, len(cmds), 0)
}

@(test)
whitespace_only :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("   \t   ", context.temp_allocator)
	testing.expect_value(t, len(cmds), 0)
}

@(test)
single_quoted :: proc(t: ^testing.T) {
	// Single quotes contain spaces and metacharacters literally.
	cmds, warns := safety.parse_shell_command(`echo 'hello world'`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) > 0 {
		testing.expect_value(t, cmds[0].executable, "echo")
		testing.expect_value(t, len(cmds[0].args), 1)
	}
	testing.expect_value(t, len(warns), 0)
}

@(test)
double_quoted :: proc(t: ^testing.T) {
	cmds, warns := safety.parse_shell_command(`echo "hello world"`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	testing.expect_value(t, len(warns), 0)
}

@(test)
unbalanced_single_quote_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command(`echo 'unterminated`, context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "unbalanced single quote") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
unbalanced_double_quote_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command(`echo "unterminated`, context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "unbalanced double quote") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
command_substitution_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("echo $(whoami)", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "command substitution") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
backtick_substitution_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("echo `whoami`", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "backtick") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
variable_expansion_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("echo $HOME", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "variable expansion") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
brace_expansion_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("echo {a,b,c}", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "brace expansion") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
subshell_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("(echo foo)", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "subshell") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
separator_split :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("ls; grep foo; wc -l", context.temp_allocator)
	testing.expect_value(t, len(cmds), 3)
	if len(cmds) == 3 {
		testing.expect_value(t, cmds[0].executable, "ls")
		testing.expect_value(t, len(cmds[0].args), 0)
		testing.expect_value(t, cmds[1].executable, "grep")
		testing.expect_value(t, len(cmds[1].args), 1)
		if len(cmds[1].args) == 1 {
			testing.expect_value(t, cmds[1].args[0], "foo")
		}
		testing.expect_value(t, cmds[2].executable, "wc")
		testing.expect_value(t, len(cmds[2].args), 1)
		if len(cmds[2].args) == 1 {
			testing.expect_value(t, cmds[2].args[0], "-l")
		}
	}
}

@(test)
and_separator :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("ls && echo ok", context.temp_allocator)
	testing.expect_value(t, len(cmds), 2)
	if len(cmds) == 2 {
		testing.expect_value(t, cmds[1].executable, "echo")
		testing.expect_value(t, len(cmds[1].args), 1)
	}
}

@(test)
or_separator :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("ls || echo fail", context.temp_allocator)
	testing.expect_value(t, len(cmds), 2)
	if len(cmds) == 2 {
		testing.expect_value(t, cmds[1].executable, "echo")
		testing.expect_value(t, len(cmds[1].args), 1)
	}
}

@(test)
pipe_separator :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("ls | grep foo", context.temp_allocator)
	testing.expect_value(t, len(cmds), 2)
	if len(cmds) == 2 {
		testing.expect_value(t, cmds[1].executable, "grep")
		testing.expect_value(t, len(cmds[1].args), 1)
	}
}

@(test)
redirect_skipped_from_exec :: proc(t: ^testing.T) {
	// "ls > /tmp/out" — the redirect target should not be in args.
	cmds, _ := safety.parse_shell_command("ls > /tmp/out", context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) > 0 {
		testing.expect_value(t, cmds[0].executable, "ls")
		testing.expect_value(t, len(cmds[0].args), 0)
	}
}

@(test)
comment_stops_parsing :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command("ls # this is a comment", context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
}

@(test)
backslash_escape :: proc(t: ^testing.T) {
	// `\ ` inside an unquoted word escapes the space on POSIX — a single
	// token. On Windows the backslash stays literal (an unquoted
	// `C:\Windows` must not lose its separators), so the word splits.
	cmds, _ := safety.parse_shell_command(`foo\ bar baz`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) > 0 {
		when ODIN_OS == .Windows {
			testing.expect_value(t, cmds[0].executable, `foo\`)
		} else {
			testing.expect_value(t, cmds[0].executable, "foo bar")
		}
	}
}

@(test)
caret_escape_windows :: proc(t: ^testing.T) {
	// cmd.exe strips an unquoted caret and takes the next byte literally:
	// `de^l` runs `del`. Windows builds model that so the resolved value —
	// the string block patterns match — carries the executed spelling; on
	// POSIX the caret is a plain byte and `de^l` is simply a different
	// (unexecutable) command name.
	got := safety.normalize_shell_command(`de^l /q x`, context.temp_allocator)
	when ODIN_OS == .Windows {
		testing.expect_value(t, got, "del /q x")
	} else {
		testing.expect_value(t, got, `de^l /q x`)
	}
}

@(test)
caret_escape_word_edges :: proc(t: ^testing.T) {
	// A leading caret escapes the first byte (`^del` runs `del`); a
	// trailing one is dropped (`x^` runs `x`).
	got := safety.normalize_shell_command(`^del x^ y`, context.temp_allocator)
	when ODIN_OS == .Windows {
		testing.expect_value(t, got, "del x y")
	} else {
		testing.expect_value(t, got, `^del x^ y`)
	}
}

@(test)
caret_in_double_quotes_literal :: proc(t: ^testing.T) {
	// cmd keeps carets literal inside double quotes — the same resolved
	// value POSIX sh produces, where ^ is a plain byte everywhere.
	got := safety.normalize_shell_command(`echo "a^b"`, context.temp_allocator)
	testing.expect_value(t, got, `echo a^b`)
}

@(test)
caret_escaped_quote_not_an_opener :: proc(t: ^testing.T) {
	// `^"` is a literal quote byte for cmd, never an opener: the word
	// survives whole instead of swallowing the rest of the line into an
	// unbalanced quote. POSIX treats the caret as plain and opens the
	// quote, which then never closes.
	cmds, warns := safety.parse_shell_command(`echo c^"d e`, context.temp_allocator)
	when ODIN_OS == .Windows {
		testing.expect_value(t, len(cmds), 1)
		if len(cmds) == 1 {
			testing.expect_value(t, len(cmds[0].args), 2)
			if len(cmds[0].args) == 2 {
				testing.expect_value(t, cmds[0].args[0], `c"d`)
				testing.expect_value(t, cmds[0].args[1], "e")
			}
		}
		testing.expect_value(t, len(warns), 0)
	} else {
		testing.expect_value(t, len(cmds), 1)
		testing.expect_value(t, len(warns), 1) // unbalanced double quote
	}
}

@(test)
windows_variable_warns :: proc(t: ^testing.T) {
	_, warns := safety.parse_shell_command("echo %FOO%", context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "Windows variable expansion") {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
normalize_basic :: proc(t: ^testing.T) {
	got := safety.normalize_shell_command(`echo 'hello  world'`, context.temp_allocator)
	testing.expect(t, strings.contains(got, "hello"))
}

@(test)
normalize_quoted_preserved :: proc(t: ^testing.T) {
	// Normalize keeps every resolved token in order, including the executable.
	got := safety.normalize_shell_command(`echo foo bar`, context.temp_allocator)
	testing.expect_value(t, got, "echo foo bar")
}

@(test)
normalize_append_redirects_single_token :: proc(t: ^testing.T) {
	// The fd-append operators must survive tokenization whole: a
	// first-prefix-wins scan that fires "2>" before "2>>" splits them into
	// two redirects, and the guard's command patterns then match a
	// normalized form the shell would never execute.
	got := safety.normalize_shell_command(`log 2>> f.err 1>> f.out`, context.temp_allocator)
	testing.expect_value(t, got, "log 2>> f.err 1>> f.out")
}

@(test)
normalize_double_quoted_with_var :: proc(t: ^testing.T) {
	// Variable inside double-quotes is parsed and stripped of the expanded
	// section. The warning is observable through parse_shell_command.
	got := safety.normalize_shell_command(`echo "$HOME"`, context.temp_allocator)
	_ = got
	cmds, warns := safety.parse_shell_command(`echo "$HOME"`, context.temp_allocator)
	found := false
	for w in warns {
		if strings.contains(w, "variable expansion") {
			found = true
		}
	}
	testing.expect(t, found)
	_ = cmds
}

@(test)
variable_expansion_keeps_following_text :: proc(t: ^testing.T) {
	// The expansion helper advances p.pos itself; the caller must not add n
	// again (the old double-advance silently ate the bytes after $VAR).
	cmds, _ := safety.parse_shell_command(`echo "$HOME/x" y`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) == 1 {
		testing.expect_value(t, cmds[0].executable, "echo")
		testing.expect_value(t, len(cmds[0].args), 2)
		if len(cmds[0].args) == 2 {
			testing.expect_value(t, cmds[0].args[0], "$HOME/x")
			testing.expect_value(t, cmds[0].args[1], "y")
		}
	}
}

@(test)
variable_expansion_brace_form_keeps_tail :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command(`echo ${HOME}/x y`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) == 1 {
		testing.expect_value(t, len(cmds[0].args), 2)
		if len(cmds[0].args) == 2 {
			testing.expect(t, cmds[0].args[0] == "${HOME}/x")
			testing.expect_value(t, cmds[0].args[1], "y")
		}
	}
}

@(test)
variable_expansion_midword_and_lone_dollar :: proc(t: ^testing.T) {
	cmds, _ := safety.parse_shell_command(`pre$VAR post`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) == 1 {
		testing.expect_value(t, cmds[0].executable, "pre$VAR")
		testing.expect_value(t, len(cmds[0].args), 1)
		if len(cmds[0].args) == 1 {
			testing.expect_value(t, cmds[0].args[0], "post")
		}
	}

	// A lone '$' consumes exactly one byte; the next word survives.
	cmds, _ = safety.parse_shell_command(`echo 5$ x`, context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) == 1 {
		testing.expect_value(t, len(cmds[0].args), 2)
		if len(cmds[0].args) == 2 {
			testing.expect_value(t, cmds[0].args[0], "5$")
			testing.expect_value(t, cmds[0].args[1], "x")
		}
	}
}

@(test)
normalize_keeps_variable_text :: proc(t: ^testing.T) {
	got := safety.normalize_shell_command(`echo "$HOME/x" y`, context.temp_allocator)
	testing.expect_value(t, got, `echo $HOME/x y`)
}

@(test)
stray_closer_terminates :: proc(t: ^testing.T) {
	// A stray ')' at a word start is a boundary parse_word cannot consume;
	// the tokenizer must skip it and finish instead of looping forever.
	cmds, _ := safety.parse_shell_command("echo hi)", context.temp_allocator)
	testing.expect_value(t, len(cmds), 1)
	if len(cmds) > 0 {
		testing.expect_value(t, cmds[0].executable, "echo")
		testing.expect_value(t, len(cmds[0].args), 1)
	}

	cmds2, _ := safety.parse_shell_command("foo ) bar", context.temp_allocator)
	testing.expect_value(t, len(cmds2), 1)
	if len(cmds2) > 0 {
		testing.expect_value(t, cmds2[0].executable, "foo")
		testing.expect_value(t, len(cmds2[0].args), 1)
		testing.expect_value(t, cmds2[0].args[0], "bar")
	}
}
