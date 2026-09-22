// Direct tests for the svc memory file operations (no daemon): the
// write/read/edit/delete/rename lifecycle, pattern enforcement, the
// listing walk, and symlink containment. The daemon-pair contract tests
// for the svc.memory/* face ride the same ops through the handlers.
package tests

import "core:mem"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "src:jsonrpc"
import "src:jsonutil"
import "src:memory"
import "src:platform"
import "src:svc"

Memory_Test_Dirs :: struct {
	project: string,
	home:    string,
	mf:      ^svc.Memory_Files,
}

memory_test_setup :: proc(t: ^testing.T, read_only: []string = nil, ignored: []string = nil) -> ^Memory_Test_Dirs {
	project, perr := os.make_directory_temp("", "aubade-memproj-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp project dir failed")
	}
	home, herr := os.make_directory_temp("", "aubade-memhome-", context.allocator)
	if herr != nil {
		os.remove_all(project)
		delete(project, context.allocator)
		testing.fail_now(t, "temp home dir failed")
	}
	mf := new(svc.Memory_Files, context.allocator)
	svc.memory_files_init(mf, project, home, read_only, ignored, context.allocator)
	box := new(Memory_Test_Dirs, context.allocator)
	box^ = {project = project, home = home, mf = mf}
	return box
}

memory_test_teardown :: proc(box: ^Memory_Test_Dirs) {
	svc.memory_files_destroy(box.mf)
	free(box.mf, context.allocator)
	_ = os.remove_all(box.project)
	_ = os.remove_all(box.home)
	delete(box.project, context.allocator)
	delete(box.home, context.allocator)
	free(box, context.allocator)
}

@(test)
svc_memory_write_read_delete_roundtrip :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Write creates the nested topic directories.
	if err := svc.memory_save(box.mf, "auth/login/logic", "# Logic\nbody\n", a); err != nil {
		testing.expectf(t, false, "save failed: %s", platform.err_message(err))
		return
	}

	content, found, lerr := svc.memory_load(box.mf, "auth/login/logic", a)
	testing.expect(t, lerr == nil)
	testing.expect(t, found)
	testing.expect_value(t, content, "# Logic\nbody\n")

	// The ".md" suffix is implicit.
	suffixed, found2, _ := svc.memory_load(box.mf, "auth/login/logic.md", a)
	testing.expect(t, found2)
	testing.expect_value(t, suffixed, "# Logic\nbody\n")

	// Missing memories read as found=false, never an error.
	_, found3, merr := svc.memory_load(box.mf, "nope/missing", a)
	testing.expect(t, merr == nil)
	testing.expect(t, !found3)

	// Delete reports found, then not-found.
	found4, derr := svc.memory_delete(box.mf, "auth/login/logic", a)
	testing.expect(t, derr == nil)
	testing.expect(t, found4)
	found5, derr2 := svc.memory_delete(box.mf, "auth/login/logic", a)
	testing.expect(t, derr2 == nil)
	testing.expect(t, !found5)
}

@(test)
svc_memory_traversal_and_bare_global_refused :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	if err := svc.memory_save(box.mf, "../escape", "x", a); err == nil {
		testing.expectf(t, false, "traversal must refuse")
		return
	}
	if _, _, err := svc.memory_load(box.mf, "a/../../escape", a); err == nil {
		testing.expectf(t, false, "nested traversal must refuse")
		return
	}
	if _, _, err := svc.memory_load(box.mf, "global", a); err == nil {
		testing.expectf(t, false, "bare global must refuse")
	}
}

@(test)
svc_memory_pattern_enforcement :: proc(t: ^testing.T) {
	// One directory pair, two views: the pattern-free seeder writes;
	// the enforcing view classifies and refuses.
	box := memory_test_setup(t)
	defer memory_test_teardown(box)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	seed_a := mem.dynamic_arena_allocator(&arena)

	if err := svc.memory_save(box.mf, "pinned/arch", "arch notes", seed_a); err != nil {
		testing.expectf(t, false, "seed pinned failed")
		return
	}
	if err := svc.memory_save(box.mf, "secret/keys", "hidden", seed_a); err != nil {
		testing.expectf(t, false, "seed secret failed")
		return
	}
	if err := svc.memory_save(box.mf, "normal", "plain", seed_a); err != nil {
		testing.expectf(t, false, "seed normal failed")
		return
	}

	// Static literals — no delete (the backing lives in constant data).
	ro := []string{"pinned/.*"}
	ig := []string{"secret/.*"}
	enforcer := new(svc.Memory_Files, context.allocator)
	svc.memory_files_init(enforcer, box.project, box.home, ro, ig, context.allocator)
	defer {
		svc.memory_files_destroy(enforcer)
		free(enforcer, context.allocator)
	}

	// Reads of ignored memories refuse; writes to read-only refuse.
	if _, _, err := svc.memory_load(enforcer, "secret/keys", seed_a); err == nil {
		testing.expectf(t, false, "ignored read must refuse")
		return
	}
	if err := svc.memory_save(enforcer, "pinned/arch", "overwrite", seed_a); err == nil {
		testing.expectf(t, false, "read-only write must refuse")
		return
	}

	// Listing splits read-only into its bucket and drops ignored names.
	list, _ := svc.memory_list(enforcer, "", seed_a)
	defer memory.memories_list_destroy(&list)
	if len(list.memories) != 1 || len(list.read_only_memories) != 1 {
		testing.expectf(
			t, false, "listing buckets: %d writable, %d read-only",
			len(list.memories), len(list.read_only_memories),
		)
		return
	}
	testing.expect_value(t, list.memories[0], "normal")
	testing.expect_value(t, list.read_only_memories[0], "pinned/arch")
}

@(test)
svc_memory_bad_pattern_refuses :: proc(t: ^testing.T) {
	// A typo'd gate pattern must refuse the operation naming the pattern:
	// the pre-fix behavior silently dropped the uncompilable pattern from
	// the compiled set, failing the access gates open for exactly the
	// memories it was meant to protect.
	box := memory_test_setup(t, nil, []string{"secret/.*", "([unclosed"})
	defer memory_test_teardown(box)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Every memory operation through the ignored gate refuses — even for
	// a name the broken pattern never covered — with the pattern named.
	_, _, rerr := svc.memory_load(box.mf, "normal", a)
	if rerr == nil {
		testing.expectf(t, false, "load must refuse on a bad ignored pattern")
		return
	}
	testing.expect(t, platform.err_kind(rerr) == .Invalid, "refusal must be Invalid")
	msg := platform.err_message(rerr, context.temp_allocator)
	testing.expect(t, strings.contains(msg, "([unclosed"), msg)

	// The listing face refuses too: a dropped ignored pattern would leak
	// protected names into the listing.
	if _, lerr := svc.memory_list(box.mf, "", a); lerr == nil {
		testing.expectf(t, false, "list must refuse on a bad ignored pattern")
		return
	}

	// A bad read_only pattern refuses writes and renames the same way.
	robox := memory_test_setup(t, []string{"([unclosed"}, nil)
	defer memory_test_teardown(robox)
	if werr := svc.memory_save(robox.mf, "anything", "x", a); werr == nil {
		testing.expectf(t, false, "save must refuse on a bad read_only pattern")
		return
	}
	if _, _, rnerr := svc.memory_rename(robox.mf, "anything", "else", a); rnerr == nil {
		testing.expectf(t, false, "rename must refuse on a bad read_only pattern")
	}
}

@(test)
svc_memory_global_scope :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	if err := svc.memory_save(box.mf, "global/java/style", "style guide", a); err != nil {
		testing.expectf(t, false, "global save failed")
		return
	}
	got, found, _ := svc.memory_load(box.mf, "global/java/style", a)
	testing.expect(t, found)
	testing.expect_value(t, got, "style guide")

	// The empty topic lists both roots; the global topic filters to it.
	all, _ := svc.memory_list(box.mf, "", a)
	defer memory.memories_list_destroy(&all)
	has_global := false
	for n in all.memories {
		if n == "global/java/style" {
			has_global = true
		}
	}
	testing.expect(t, has_global, "empty topic must list global memories")

	just_global, _ := svc.memory_list(box.mf, "global", a)
	defer memory.memories_list_destroy(&just_global)
	if len(just_global.memories) != 1 {
		testing.expectf(t, false, "global topic: %d memories", len(just_global.memories))
		return
	}
	testing.expect_value(t, just_global.memories[0], "global/java/style")

	sub, _ := svc.memory_list(box.mf, "global/java", a)
	defer memory.memories_list_destroy(&sub)
	if len(sub.memories) != 1 {
		testing.expectf(t, false, "global subtopic: %d memories", len(sub.memories))
		return
	}
	testing.expect_value(t, sub.memories[0], "global/java/style")

	// Project topics do not see global memories.
	proj, _ := svc.memory_list(box.mf, "java", a)
	defer memory.memories_list_destroy(&proj)
	testing.expect_value(t, len(proj.memories), 0)
}

@(test)
svc_memory_topic_rejects_path_shapes :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The topic joins onto the memories root; dot-dot and empty segments
	// must be refused instead of walking out of the root.
	bad_topics := []string{"..", "../..", "a/../b", "a//b", "global/..", "trail/"}
	for topic in bad_topics {
		if _, err := svc.memory_list(box.mf, topic, a); err == nil {
			testing.expectf(t, false, "topic %q must be refused", topic)
			return
		}
	}
}

@(test)
svc_memory_rename_and_reference_propagation :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	_ = svc.memory_save(box.mf, "b", "the b memory", a)
	_ = svc.memory_save(box.mf, "reader", "see mem:b and mem:b; also mem:bb", a)

	found, propagated, rerr := svc.memory_rename(box.mf, "b", "c", a)
	testing.expect(t, rerr == nil)
	testing.expect(t, found)
	testing.expect_value(t, propagated, 1)

	updated, ok, _ := svc.memory_load(box.mf, "reader", a)
	testing.expect(t, ok)
	testing.expect_value(t, updated, "see mem:c and mem:c; also mem:bb")

	// The old name is gone; renames onto an existing name refuse.
	_, gone, _ := svc.memory_load(box.mf, "b", a)
	testing.expect(t, !gone)
	_, _, dup_err := svc.memory_rename(box.mf, "c", "reader", a)
	testing.expect(t, dup_err != nil, "rename onto existing must refuse")

	_, _, missing_err := svc.memory_rename(box.mf, "never", "x", a)
	testing.expect(t, missing_err != nil, "rename of missing memory must refuse")
}

@(test)
svc_memory_edit_modes :: proc(t: ^testing.T) {
	box := memory_test_setup(t)
	defer memory_test_teardown(box)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	_ = svc.memory_save(box.mf, "notes", "alpha beta gamma", a)

	// Literal replace of one occurrence.
	if err := svc.memory_edit(box.mf, "notes", "beta", "BETA", .Literal, false, a); err != nil {
		testing.expectf(t, false, "literal edit failed")
		return
	}
	got, _, _ := svc.memory_load(box.mf, "notes", a)
	testing.expect_value(t, got, "alpha BETA gamma")

	// Multiple occurrences refuse without the flag.
	if err := svc.memory_edit(box.mf, "notes", "a", "x", .Literal, false, a); err == nil {
		testing.expectf(t, false, "ambiguous literal edit must refuse")
		return
	}

	// Regex with a backreference.
	if err := svc.memory_edit(
		box.mf, "notes", "(alpha) (BETA)", "$!2 $!1", .Regex, false, a,
	); err != nil {
		testing.expectf(t, false, "regex edit failed")
		return
	}
	got2, _, _ := svc.memory_load(box.mf, "notes", a)
	testing.expect_value(t, got2, "BETA alpha gamma")

	// Editing a missing memory refuses.
	if err := svc.memory_edit(box.mf, "gone", "x", "y", .Literal, false, a); err == nil {
		testing.expectf(t, false, "edit of missing memory must refuse")
	}
}

@(test)
svc_memory_symlink_escape_refused :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires privileges the test
		// runner may not have; the containment logic is POSIX-tested.
		return
	} else {
		box := memory_test_setup(t)
		defer memory_test_teardown(box)

		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, context.allocator)
		defer mem.dynamic_arena_destroy(&arena)
		a := mem.dynamic_arena_allocator(&arena)

		outside, _ := os.join_path({box.home, "outside.txt"}, context.temp_allocator)
		secret := "secret"
		_ = os.write_entire_file_from_bytes(outside, transmute([]u8)secret)
		mem_root, _ := os.join_path(
			{box.project, ".aubade", "memories"}, context.temp_allocator,
		)
		evil, _ := os.join_path({mem_root, "evil.md"}, context.temp_allocator)
		if lerr := os.symlink(outside, evil); lerr != nil {
			// No symlink support in this environment: nothing to assert.
			return
		}

		if _, _, err := svc.memory_load(box.mf, "evil", a); err == nil {
			testing.expectf(t, false, "symlink escape must refuse")
			return
		}
		if err := svc.memory_save(box.mf, "evil", "overwrite", a); err == nil {
			testing.expectf(t, false, "symlink write must refuse")
		}
	}
}

// The project root may itself be reached through an intermediate
// symlink; containment must resolve the memories root canonically and
// still refuse escapes. A root self-walk with itself as the prefix used
// to truncate at the first hop (macOS /var -> /private/var hits this on
// every temp tree) and read every sibling path as contained.
@(test)
svc_memory_symlinked_root_escape_refused :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires privileges the test
		// runner may not have.
		return
	} else {
		base, terr := os.make_directory_temp("", "aubade-memlink-", context.allocator)
		if terr != nil {
			testing.fail_now(t, "temp dir failed")
		}
		defer {
			_ = os.remove_all(base)
			delete(base, context.allocator)
		}

		real, _ := os.join_path({base, "real"}, context.allocator)
		home, _ := os.join_path({base, "home"}, context.allocator)
		defer {
			delete(real, context.allocator)
			delete(home, context.allocator)
		}
		if merr := os.make_directory_all(real, {.Read_User, .Write_User, .Execute_User}); merr != nil {
			testing.expect(t, false, "real dir failed")
			return
		}
		if merr := os.make_directory_all(home, {.Read_User, .Write_User, .Execute_User}); merr != nil {
			testing.expect(t, false, "home dir failed")
			return
		}
		link, _ := os.join_path({base, "link"}, context.allocator)
		defer delete(link, context.allocator)
		if lerr := os.symlink(real, link); lerr != nil {
			// No symlink support in this environment: nothing to assert.
			return
		}

		outside, _ := os.join_path({real, "outside.txt"}, context.temp_allocator)
		secret := "secret"
		_ = os.write_entire_file_from_bytes(outside, transmute([]u8)secret)

		mf := new(svc.Memory_Files, context.allocator)
		defer {
			svc.memory_files_destroy(mf)
			free(mf, context.allocator)
		}
		svc.memory_files_init(mf, link, home, nil, nil, context.allocator)

		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, context.allocator)
		defer mem.dynamic_arena_destroy(&arena)
		a := mem.dynamic_arena_allocator(&arena)

		evil, _ := os.join_path({mf.project_dir, "evil.md"}, context.temp_allocator)
		if lerr := os.symlink(outside, evil); lerr != nil {
			return
		}
		if _, _, err := svc.memory_load(mf, "evil", a); err == nil {
			testing.expectf(t, false, "escape through a symlinked root must refuse")
			return
		}
		if err := svc.memory_save(mf, "evil", "overwrite", a); err == nil {
			testing.expectf(t, false, "escape write through a symlinked root must refuse")
		}
	}
}

@(test)
svc_memory_face_contract :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// write -> read roundtrip through the face.
	w := svc.client_memory_write(pair.conn, "auth/login", "# logic\n", alloc, deadline)
	testing.expect_value(t, w.call_err, jsonrpc.Call_Err.None)
	r := svc.client_memory_read(pair.conn, "auth/login", alloc, deadline)
	testing.expect_value(t, r.call_err, jsonrpc.Call_Err.None)
	content, ok := json_str_field(r.result, "content")
	testing.expect(t, ok)
	testing.expect_value(t, content, "# logic\n")
	found, _ := json_bool_field(r.result, "found")
	testing.expect(t, found)

	// A missing memory answers found=false, never an error.
	m := svc.client_memory_read(pair.conn, "nope", alloc, deadline)
	testing.expect_value(t, m.call_err, jsonrpc.Call_Err.None)
	mfound, _ := json_bool_field(m.result, "found")
	testing.expect(t, !mfound)

	// The listing sees the memory.
	l := svc.client_memory_list(pair.conn, "", alloc, deadline)
	testing.expect_value(t, l.call_err, jsonrpc.Call_Err.None)
	seen := false
	if mems, ok2 := jsonutil.obj_get(l.result, "memories"); ok2 {
		for i in 0..<json_array_len(mems) {
			if s, ok3 := json_array_str_at(mems, i); ok3 && s == "auth/login" {
				seen = true
			}
		}
	}
	testing.expect(t, seen, "list must contain auth/login")

	// Rename rewrites mem: references in other memories.
	w2 := svc.client_memory_write(pair.conn, "reader", "see mem:auth/login here", alloc, deadline)
	testing.expect_value(t, w2.call_err, jsonrpc.Call_Err.None)
	rn := svc.client_memory_rename(pair.conn, "auth/login", "auth/logic", alloc, deadline)
	testing.expect_value(t, rn.call_err, jsonrpc.Call_Err.None)
	propagated, pok := json_int_field(rn.result, "propagated")
	testing.expect(t, pok)
	testing.expect_value(t, propagated, 1)
	r2 := svc.client_memory_read(pair.conn, "reader", alloc, deadline)
	updated, _ := json_str_field(r2.result, "content")
	testing.expect_value(t, updated, "see mem:auth/logic here")

	// Literal replace through the face.
	rep := svc.client_memory_replace(
		pair.conn, "reader", "see", "saw", "literal", false, alloc, deadline,
	)
	testing.expect_value(t, rep.call_err, jsonrpc.Call_Err.None)
	r3 := svc.client_memory_read(pair.conn, "reader", alloc, deadline)
	replaced, _ := json_str_field(r3.result, "content")
	testing.expect_value(t, replaced, "saw mem:auth/logic here")

	// Delete reports found, then not-found.
	del := svc.client_memory_delete(pair.conn, "reader", alloc, deadline)
	testing.expect_value(t, del.call_err, jsonrpc.Call_Err.None)
	dfound, _ := json_bool_field(del.result, "found")
	testing.expect(t, dfound)
	del2 := svc.client_memory_delete(pair.conn, "reader", alloc, deadline)
	testing.expect_value(t, del2.call_err, jsonrpc.Call_Err.None)
	dfound2, _ := json_bool_field(del2.result, "found")
	testing.expect(t, !dfound2)

	// Traversal refuses with the typed invalid-params code.
	esc := svc.client_memory_write(pair.conn, "../escape", "x", alloc, deadline)
	testing.expect_value(t, esc.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, esc.err_code, jsonrpc.Err_Code.Invalid_Params)
}

json_array_str_at :: proc(v: json.Value, i: int) -> (string, bool) {
	#partial switch x in json_array_at(v, i) {
	case json.String:
		return string(x), true
	case:
	}
	return "", false
}
