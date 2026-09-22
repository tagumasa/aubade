// Fold snapshots: the persisted checkpoint that turns manager startup's
// full-stream refold into restore + tail replay. The fold is pure and
// deterministic, so "snapshot at watermark W + replay events with
// uid > W" must equal "fold the whole stream" — the restore path either
// rebuilds the exact state or refuses (any structural surprise falls
// back to the full refold with one anomaly line). Correctness never
// depends on a snapshot WRITE succeeding: a missing or stale snapshot
// only costs the old full-refold cost.

package tracker

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:sort"
import "core:strings"
import "src:jsonutil"
import "src:util"

SNAPSHOT_VERSION :: int(1)

// The kv key under the store's machine-owned registry. Snapshots live
// in the same SQLite file as the events they summarize.
SNAPSHOT_KEY :: "tracker.fold_snapshot"

// A snapshot bigger than this is skipped (the state has outgrown the
// format's intent); the manager stays dirty and the next start falls
// back to the full refold. Far beyond any real project's tracker state.
MAX_SNAPSHOT_BYTES :: 4 * 1024 * 1024

// The daemon's manager re-persists the snapshot every N folded appends
// (plus once after a full refold and once at clean teardown): the write
// is O(state) while the appends it amortizes over are O(1) each.
SNAPSHOT_EVERY :: 64

// snapshot_serialize renders the whole fold state plus the consumed
// watermark (which may sit past state.last_uid: envelope-invalid rows
// order the stream and advance the watermark without applying). The
// returned blob is owned by `a`; strings inside the state are only read
// (json.String holds views), so serialization never mutates the state.
snapshot_serialize :: proc(s: ^Fold_State, last_seen_uid: string, a: mem.Allocator) -> (blob: string, ok: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a)
	defer mem.dynamic_arena_destroy(&arena)
	aa := mem.dynamic_arena_allocator(&arena)

	root := jsonutil.json_object(16, aa)
	jsonutil.obj_set(&root, "version", jsonutil.json_int(i64(SNAPSHOT_VERSION)))
	jsonutil.obj_set(&root, "last_seen_uid", jsonutil.json_string(last_seen_uid))
	jsonutil.obj_set(&root, "last_uid", jsonutil.json_string(s.last_uid))
	jsonutil.obj_set(&root, "inc_count", jsonutil.json_int(i64(s.inc_count)))
	jsonutil.obj_set(&root, "spr_count", jsonutil.json_int(i64(s.spr_count)))
	jsonutil.obj_set(&root, "defer_count", jsonutil.json_int(i64(s.defer_count)))

	incs := make([]json.Value, len(s.incident_order), aa)
	for uid, i in s.incident_order {
		incs[i] = incident_header_to_json(s.incidents[uid], aa)
	}
	jsonutil.obj_set(&root, "incidents", jsonutil.json_array(incs, aa))
	jsonutil.obj_set(&root, "incident_order", jsonutil.json_string_array(s.incident_order[:], aa))

	sprs := make([]json.Value, len(s.sprint_order), aa)
	for id, i in s.sprint_order {
		sprs[i] = sprint_header_to_json(s.sprints[id], aa)
	}
	jsonutil.obj_set(&root, "sprints", jsonutil.json_array(sprs, aa))
	jsonutil.obj_set(&root, "sprint_order", jsonutil.json_string_array(s.sprint_order[:], aa))

	dfs := make([]json.Value, len(s.defer_order), aa)
	for id, i in s.defer_order {
		dfs[i] = defer_record_to_json(s.defers[id], aa)
	}
	jsonutil.obj_set(&root, "defers", jsonutil.json_array(dfs, aa))
	jsonutil.obj_set(&root, "defer_order", jsonutil.json_string_array(s.defer_order[:], aa))

	// Sorted for determinism: the map's iteration order varies run to
	// run, and serialize(restore(blob)) must reproduce blob byte for byte.
	seen := make([]string, len(s.seen_uids), aa)
	i := 0
	for uid, _ in s.seen_uids {
		seen[i] = uid
		i += 1
	}
	sort.quick_sort(seen[:])
	jsonutil.obj_set(&root, "seen_uids", jsonutil.json_string_array(seen, aa))

	// Derived lookup maps go out as plain objects; restore re-borrows
	// the headers they point at.
	aliases := jsonutil.json_object(len(s.aliases), aa)
	for alias, h in s.aliases {
		jsonutil.obj_set(&aliases, alias, jsonutil.json_string(h.uid))
	}
	jsonutil.obj_set(&root, "aliases", json.Value(json.Object(aliases)))
	id_to_uid := jsonutil.json_object(len(s.id_to_uid), aa)
	for id, h in s.id_to_uid {
		jsonutil.obj_set(&id_to_uid, id, jsonutil.json_string(h.uid))
	}
	jsonutil.obj_set(&root, "id_to_uid", json.Value(json.Object(id_to_uid)))

	nodes := jsonutil.json_object(len(s.dag.nodes), aa)
	for id, node in s.dag.nodes {
		nm := jsonutil.json_object(2, aa)
		jsonutil.obj_set(&nm, "edges", jsonutil.json_string_array(node.edges[:], aa))
		jsonutil.obj_set(&nm, "rev", jsonutil.json_string_array(node.rev[:], aa))
		jsonutil.obj_set(&nodes, id, json.Value(json.Object(nm)))
	}
	jsonutil.obj_set(&root, "dag", json.Value(json.Object(nodes)))

	jsonutil.obj_set(&root, "anomalies", jsonutil.json_string_array(s.anomalies[:], aa))

	out := jsonutil.marshal_value(json.Value(json.Object(root)), aa)
	if len(out) > MAX_SNAPSHOT_BYTES {
		return "", false
	}
	return strings.clone(out, a), true
}

// snapshot_restore validates the blob against the stream it claims to
// summarize and rebuilds the state. On success the state is replaced
// wholesale and the consumed watermark is returned (a view into the
// parsed blob, alive as long as `scratch`); on ANY failure the state is
// left exactly as passed — still empty and destroyable — and the reason
// (allocated in `scratch`) explains why. The caller folds
// events_read_after(last_seen_uid) on top of the restored state. An
// empty watermark is the one tolerated oddity: it summarizes an empty
// stream, so the caller's empty state already stands and the tail
// replay from "" re-folds everything — the same outcome as no snapshot.
snapshot_restore :: proc(
	s: ^Fold_State,          // an init'd (expected empty) state; untouched on failure
	blob: string,
	stream_max_uid: string,  // events_last_uid(); "" when the table is empty
	has_events: bool,
	scratch: mem.Allocator,
) -> (last_seen_uid: string, ok: bool, reason: string) {
	if !util.json_sanity_ok(transmute([]u8)blob) {
		return "", false, "fold snapshot is not valid JSON"
	}
	parsed, perr := json.parse_string(blob, spec = .JSON, parse_integers = true, allocator = scratch)
	if perr != nil {
		return "", false, "fold snapshot is not valid JSON"
	}
	root, is_obj := jsonutil.as_object(parsed)
	if !is_obj {
		return "", false, "fold snapshot root is not an object"
	}
	ver, ver_ok := snap_field_int(root, "version")
	if !ver_ok || ver != i64(SNAPSHOT_VERSION) {
		return "", false, "fold snapshot version is unsupported"
	}
	lsu, lsu_ok := snap_field_str(root, "last_seen_uid")
	if !lsu_ok {
		return "", false, "fold snapshot is missing its watermark"
	}
	if lsu == "" {
		// An empty watermark summarizes an empty stream: the caller's
		// empty state already IS the restored state, and the tail replay
		// from "" re-folds whatever arrived since — the same outcome as
		// having no snapshot. Restored rather than refused so a stale
		// empty checkpoint never alarms.
		return "", true, ""
	}
	if _, uok := uid_ts_ns(lsu); !uok {
		return "", false, "fold snapshot watermark is not a uid"
	}
	if !has_events {
		// An events table that no longer covers the watermark means the
		// stream was rolled back or replaced: the snapshot summarizes a
		// history that no longer exists.
		return "", false, "event stream is empty under a fold snapshot"
	}
	if strings.compare(lsu, stream_max_uid) > 0 {
		return "", false, "fold snapshot watermark is ahead of the event stream"
	}

	// Build the replacement off to the side: a failed rebuild destroys
	// the scratch state and leaves the caller's empty one in place.
	tmp: Fold_State
	fold_state_init(&tmp, s.allocator)
	if rebuilt, why := restore_state_from(&tmp, root, scratch); !rebuilt {
		restore_abort_destroy(&tmp)
		return "", false, why
	}
	fold_state_destroy(s)
	s^ = tmp
	return lsu, true, ""
}

// restore_abort_destroy frees a refused restore's scratch state. The live
// destroy frees entities by walking the order arrays (map and order are
// bijections there); a refused restore can hold entities the population
// loops never reached, so this walks the maps instead. The order arrays
// hold borrowed ids and are simply dropped.
@(private)
restore_abort_destroy :: proc(t: ^Fold_State) {
	for _, h in t.incidents {
		if h != nil {
			incident_header_destroy(h, t.allocator)
			free(h, t.allocator)
		}
	}
	for _, spr in t.sprints {
		if spr != nil {
			sprint_header_destroy(spr, t.allocator)
			free(spr, t.allocator)
		}
	}
	for _, d in t.defers {
		if d != nil {
			defer_record_destroy(d, t.allocator)
			free(d, t.allocator)
		}
	}
	delete(t.incidents)
	delete(t.incident_order)
	delete(t.sprints)
	delete(t.sprint_order)
	delete(t.defers)
	delete(t.defer_order)
	for uid in t.seen_uids {
		delete(uid, t.allocator)
	}
	delete(t.seen_uids)
	for alias in t.aliases {
		delete(alias, t.allocator)
	}
	delete(t.aliases)
	delete(t.id_to_uid)
	for line in t.anomalies {
		delete(line, t.allocator)
	}
	delete(t.anomalies)
	if t.last_uid != "" {
		delete(t.last_uid, t.allocator)
	}
	dag_destroy(&t.dag)
	t^ = {}
}

// ---------------------------------------------------------------------------
// Serialize helpers (all views; the tree lives on the caller's arena)

@(private)
event_refs_to_json :: proc(refs: [dynamic]Event_Ref, a: mem.Allocator) -> json.Value {
	items := make([]json.Value, len(refs), a)
	for ref, i in refs {
		rm := jsonutil.json_object(3, a)
		jsonutil.obj_set(&rm, "uid", jsonutil.json_string(ref.uid))
		jsonutil.obj_set(&rm, "kind", jsonutil.json_string(event_kind_string(ref.kind)))
		jsonutil.obj_set(&rm, "ts_ms", jsonutil.json_int(ref.ts_ms))
		items[i] = json.Value(json.Object(rm))
	}
	return jsonutil.json_array(items, a)
}

@(private)
event_refs_from_json :: proc(t: ^Fold_State, arr: []json.Value, what: string, scratch: mem.Allocator) -> ([dynamic]Event_Ref, string) {
	out := make([dynamic]Event_Ref, 0, len(arr), t.allocator)
	// The returned dynamic attaches to a header only when the caller
	// accepts it; the state's destroy never sees this build otherwise. A
	// mid-array failure must release the uid clones already taken.
	completed := false
	defer if !completed {
		for ref in out {
			if ref.uid != "" {
				delete(ref.uid, t.allocator)
			}
		}
		delete(out)
	}
	for el in arr {
		o, is_obj := jsonutil.as_object(el)
		if !is_obj {
			return nil, fmt.aprintf("fold snapshot %s event ref is not an object", what, allocator = scratch)
		}
		ref: Event_Ref
		uid, uid_ok := snap_field_str(o, "uid")
		if !uid_ok {
			return nil, fmt.aprintf("fold snapshot %s event ref uid is not a string", what, allocator = scratch)
		}
		ref.uid = strings.clone(uid, t.allocator)
		kind_str, k_ok := snap_field_str(o, "kind")
		if !k_ok {
			return nil, fmt.aprintf("fold snapshot %s event ref kind is not a string", what, allocator = scratch)
		}
		kind, known := event_kind_from_string(kind_str)
		if !known {
			return nil, fmt.aprintf("fold snapshot %s event ref kind is unknown", what, allocator = scratch)
		}
		ref.kind = kind
		ts, ts_ok := snap_field_int(o, "ts_ms")
		if !ts_ok {
			return nil, fmt.aprintf("fold snapshot %s event ref ts_ms is not an integer", what, allocator = scratch)
		}
		ref.ts_ms = ts
		append(&out, ref)
	}
	completed = true
	return out, ""
}

@(private)
incident_header_to_json :: proc(h: ^Incident_Header, a: mem.Allocator) -> json.Value {
	m := jsonutil.json_object(25, a)
	jsonutil.obj_set(&m, "uid", jsonutil.json_string(h.uid))
	jsonutil.obj_set(&m, "id", jsonutil.json_string(h.id))
	jsonutil.obj_set(&m, "title", jsonutil.json_string(h.title))
	jsonutil.obj_set(&m, "status", jsonutil.json_string(h.status))
	jsonutil.obj_set(&m, "priority", jsonutil.json_string(h.priority))
	jsonutil.obj_set(&m, "labels", jsonutil.json_string_array(h.labels, a))
	jsonutil.obj_set(&m, "sprint", jsonutil.json_string(h.sprint))
	jsonutil.obj_set(&m, "blocked_by", jsonutil.json_string_array(h.blocked_by, a))
	jsonutil.obj_set(&m, "assignee", jsonutil.json_string(h.assignee))
	jsonutil.obj_set(&m, "aliases", jsonutil.json_string_array(h.aliases, a))
	jsonutil.obj_set(&m, "created_by", jsonutil.json_string(h.created_by))
	jsonutil.obj_set(&m, "verdict", jsonutil.json_string(h.verdict))
	jsonutil.obj_set(&m, "fp_pattern", jsonutil.json_string(h.fp_pattern))
	jsonutil.obj_set(&m, "created_ms", jsonutil.json_int(h.created_ms))
	jsonutil.obj_set(&m, "updated_ms", jsonutil.json_int(h.updated_ms))
	jsonutil.obj_set(&m, "verified_ms", jsonutil.json_int(h.verified_ms))
	jsonutil.obj_set(&m, "resolved_ms", jsonutil.json_int(h.resolved_ms))
	jsonutil.obj_set(&m, "resolution", jsonutil.json_string(h.resolution))
	jsonutil.obj_set(&m, "deleted", jsonutil.json_bool(h.is_deleted))
	jsonutil.obj_set(&m, "duplicate_of", jsonutil.json_string(h.duplicate_of))
	jsonutil.obj_set(&m, "anomaly", jsonutil.json_bool(h.is_anomaly))
	jsonutil.obj_set(&m, "anomaly_detail", jsonutil.json_string_array(h.anomaly_detail[:], a))
	ls := jsonutil.json_object(3, a)
	jsonutil.obj_set(&ls, "kind", jsonutil.json_string(event_kind_string(h.last_status.kind)))
	jsonutil.obj_set(&ls, "ts_ms", jsonutil.json_int(h.last_status.ts_ms))
	jsonutil.obj_set(&ls, "origin", jsonutil.json_string(h.last_status.origin))
	jsonutil.obj_set(&m, "last_status", json.Value(json.Object(ls)))
	jsonutil.obj_set(&m, "note_count", jsonutil.json_int(i64(h.note_count)))
	jsonutil.obj_set(&m, "events", event_refs_to_json(h.events, a))
	return json.Value(json.Object(m))
}

@(private)
sprint_header_to_json :: proc(h: ^Sprint_Header, a: mem.Allocator) -> json.Value {
	m := jsonutil.json_object(9, a)
	jsonutil.obj_set(&m, "id", jsonutil.json_string(h.id))
	jsonutil.obj_set(&m, "name", jsonutil.json_string(h.name))
	jsonutil.obj_set(&m, "status", jsonutil.json_string(sprint_status_string(h.status)))
	jsonutil.obj_set(&m, "started_ms", jsonutil.json_int(h.started_ms))
	jsonutil.obj_set(&m, "closed_ms", jsonutil.json_int(h.closed_ms))
	jsonutil.obj_set(&m, "follows", jsonutil.json_string(h.follows))
	jsonutil.obj_set(&m, "must", jsonutil.json_string_array(h.must, a))
	verifs := make([]json.Value, len(h.verifications), a)
	for i in 0..<len(h.verifications) {
		v := &h.verifications[i]
		vm := jsonutil.json_object(6, a)
		jsonutil.obj_set(&vm, "task", jsonutil.json_string(v.task))
		jsonutil.obj_set(&vm, "definition", jsonutil.json_string(v.definition))
		jsonutil.obj_set(&vm, "outcome", jsonutil.json_string(v.outcome))
		jsonutil.obj_set(&vm, "output", jsonutil.json_string(v.output))
		jsonutil.obj_set(&vm, "session", jsonutil.json_string(v.session))
		jsonutil.obj_set(&vm, "ts_ms", jsonutil.json_int(v.ts_ms))
		verifs[i] = json.Value(json.Object(vm))
	}
	jsonutil.obj_set(&m, "verifications", jsonutil.json_array(verifs, a))
	jsonutil.obj_set(&m, "events", event_refs_to_json(h.events, a))
	return json.Value(json.Object(m))
}

@(private)
defer_record_to_json :: proc(d: ^Defer_Record, a: mem.Allocator) -> json.Value {
	m := jsonutil.json_object(9, a)
	jsonutil.obj_set(&m, "id", jsonutil.json_string(d.id))
	jsonutil.obj_set(&m, "sprint", jsonutil.json_string(d.sprint))
	jsonutil.obj_set(&m, "kind", jsonutil.json_string(d.kind))
	jsonutil.obj_set(&m, "body_md", jsonutil.json_string(d.body_md))
	jsonutil.obj_set(&m, "task", jsonutil.json_string(d.task))
	jsonutil.obj_set(&m, "ref", jsonutil.json_string(d.ref))
	jsonutil.obj_set(&m, "ts_ms", jsonutil.json_int(d.ts_ms))
	jsonutil.obj_set(&m, "resolved_ms", jsonutil.json_int(d.resolved_ms))
	jsonutil.obj_set(&m, "resolved_by", jsonutil.json_string(d.resolved_by))
	return json.Value(json.Object(m))
}

// ---------------------------------------------------------------------------
// Restore helpers (every kept string is copy-in cloned onto the state's
// allocator; borrowed map keys reuse the owning header's string)

@(private)
// order_consistent checks that a snapshot section's order array and the
// restored entry map agree, and rebuilds the live order slice. Map/order
// consistency is load-bearing: the live destroy frees entries by walking
// the order, so a map entry missing from the order would leak, an order
// entry missing from the map would dangle, and a repeated order entry
// would free the same entry twice. The order slice borrows each entry's
// own key field (key_of), never the JSON spelling. Returns "" on
// success.
order_consistent :: proc(
	order:   []json.Value,
	entries: map[string]$V,
	out:     ^[dynamic]string,
	key_of:  proc(v: V) -> string,
	noun:    string,
	an_noun: string,
	a := context.allocator,
) -> string {
	if len(order) != len(entries) {
		return strings.concatenate({"fold snapshot ", noun, " order disagrees with the ", noun, " set"}, a)
	}
	seen := make(map[string]bool, len(order), a)
	for el in order {
		key, is_str := snap_value_str(el)
		if !is_str {
			return strings.concatenate({"fold snapshot ", noun, " order entry is not a string"}, a)
		}
		if key in seen {
			return strings.concatenate({"fold snapshot ", noun, " order repeats ", an_noun}, a)
		}
		seen[key] = true
		v, known := entries[key]
		if !known {
			return strings.concatenate({"fold snapshot ", noun, " order entry is missing from the ", noun, " set"}, a)
		}
		append(out, key_of(v))
	}
	return ""
}

incident_uid_of :: proc(h: ^Incident_Header) -> string {
	return h.uid
}

sprint_id_of :: proc(h: ^Sprint_Header) -> string {
	return h.id
}

defer_id_of :: proc(r: ^Defer_Record) -> string {
	return r.id
}

restore_state_from :: proc(t: ^Fold_State, root: map[string]json.Value, scratch: mem.Allocator) -> (ok: bool, reason: string) {
	lu, lu_ok := snap_field_str(root, "last_uid")
	if !lu_ok {
		return false, "fold snapshot is missing last_uid"
	}
	if lu != "" {
		t.last_uid = strings.clone(lu, t.allocator)
	}
	if n, n_ok := snap_field_int(root, "inc_count"); !n_ok {
		return false, "fold snapshot is missing inc_count"
	} else {
		t.inc_count = int(n)
	}
	if n, n_ok := snap_field_int(root, "spr_count"); !n_ok {
		return false, "fold snapshot is missing spr_count"
	} else {
		t.spr_count = int(n)
	}
	if n, n_ok := snap_field_int(root, "defer_count"); !n_ok {
		return false, "fold snapshot is missing defer_count"
	} else {
		t.defer_count = int(n)
	}

	incs, bad, why := snap_array(root, "incidents", scratch)
	if bad {
		return false, why
	}
	inc_order, inc_bad, inc_why := snap_array(root, "incident_order", scratch)
	if inc_bad {
		return false, inc_why
	}
	// The writer emits the section array and its order as the same set:
	// a length mismatch means a duplicated or dropped entity, and refusing
	// here keeps the restore from silently keeping the last duplicate.
	if len(incs) != len(inc_order) {
		return false, "fold snapshot incidents disagree with the incident order"
	}
	for el in incs {
		o, is_obj := jsonutil.as_object(el)
		if !is_obj {
			return false, "fold snapshot incident is not an object"
		}
		if w := restore_incident(t, o, scratch); w != "" {
			return false, w
		}
	}
	if w := order_consistent(inc_order, t.incidents, &t.incident_order, incident_uid_of, "incident", "an incident", scratch); w != "" {
		return false, w
	}

	sprs, sprs_bad, sprs_why := snap_array(root, "sprints", scratch)
	if sprs_bad {
		return false, sprs_why
	}
	spr_order, spr_order_bad, spr_order_why := snap_array(root, "sprint_order", scratch)
	if spr_order_bad {
		return false, spr_order_why
	}
	if len(sprs) != len(spr_order) {
		return false, "fold snapshot sprints disagree with the sprint order"
	}
	for el in sprs {
		o, is_obj := jsonutil.as_object(el)
		if !is_obj {
			return false, "fold snapshot sprint is not an object"
		}
		if w := restore_sprint(t, o, scratch); w != "" {
			return false, w
		}
	}
	if w := order_consistent(spr_order, t.sprints, &t.sprint_order, sprint_id_of, "sprint", "a sprint", scratch); w != "" {
		return false, w
	}

	dfs, dfs_bad, dfs_why := snap_array(root, "defers", scratch)
	if dfs_bad {
		return false, dfs_why
	}
	defer_order, defer_order_bad, defer_order_why := snap_array(root, "defer_order", scratch)
	if defer_order_bad {
		return false, defer_order_why
	}
	if len(dfs) != len(defer_order) {
		return false, "fold snapshot defers disagree with the defer order"
	}
	for el in dfs {
		o, is_obj := jsonutil.as_object(el)
		if !is_obj {
			return false, "fold snapshot defer is not an object"
		}
		if w := restore_defer(t, o, scratch); w != "" {
			return false, w
		}
	}
	if w := order_consistent(defer_order, t.defers, &t.defer_order, defer_id_of, "defer", "a defer", scratch); w != "" {
		return false, w
	}

	seen_uid_arr, seen_bad, seen_why := snap_array(root, "seen_uids", scratch)
	if seen_bad {
		return false, seen_why
	}
	for el in seen_uid_arr {
		uid, is_str := snap_value_str(el)
		if !is_str {
			return false, "fold snapshot seen uid is not a string"
		}
		t.seen_uids[strings.clone(uid, t.allocator)] = true
	}

	aliases, aliases_ok := jsonutil.as_object(snap_member(root, "aliases"))
	if !aliases_ok {
		return false, "fold snapshot aliases is not an object"
	}
	for alias, v in aliases {
		uid, is_str := snap_value_str(v)
		if !is_str {
			return false, "fold snapshot alias target is not a string"
		}
		h, known := t.incidents[uid]
		if !known {
			return false, "fold snapshot alias points outside the incident set"
		}
		t.aliases[strings.clone(alias, t.allocator)] = h
	}

	ids, ids_ok := jsonutil.as_object(snap_member(root, "id_to_uid"))
	if !ids_ok {
		return false, "fold snapshot id_to_uid is not an object"
	}
	for id, v in ids {
		uid, is_str := snap_value_str(v)
		if !is_str {
			return false, "fold snapshot id map value is not a string"
		}
		h, known := t.incidents[uid]
		if !known || h.id != id {
			return false, "fold snapshot id map disagrees with the incident set"
		}
		// The key is borrowed from the owning header, like the fold's own
		// inserts (fold_state_destroy does not free these keys).
		t.id_to_uid[h.id] = h
	}

	nodes, nodes_ok := jsonutil.as_object(snap_member(root, "dag"))
	if !nodes_ok {
		return false, "fold snapshot dag is not an object"
	}
	for id, v in nodes {
		no, no_ok := jsonutil.as_object(v)
		if !no_ok {
			return false, "fold snapshot dag node is not an object"
		}
		edges, edges_bad, edges_why := snap_array(no, "edges", scratch)
		if edges_bad {
			return false, edges_why
		}
		revs, revs_bad, revs_why := snap_array(no, "rev", scratch)
		if revs_bad {
			return false, revs_why
		}
		n := new(DAG_Node, t.allocator)
		n.edges = make([dynamic]string, 0, len(edges), t.allocator)
		n.rev = make([dynamic]string, 0, len(revs), t.allocator)
		// Loop-body scope: the defer fires each iteration, freeing the
		// node and its clones unless the insert completed them.
		stored := false
		defer if !stored {
			free_dag_node(n, t.allocator)
		}
		for el in edges {
			s, is_str := snap_value_str(el)
			if !is_str {
				return false, "fold snapshot dag edge is not a string"
			}
			append(&n.edges, strings.clone(s, t.allocator))
		}
		for el in revs {
			s, is_str := snap_value_str(el)
			if !is_str {
				return false, "fold snapshot dag rev is not a string"
			}
			append(&n.rev, strings.clone(s, t.allocator))
		}
		t.dag.nodes[strings.clone(id, t.allocator)] = n
		stored = true
	}
	// Every edge endpoint must have a node: the live DAG creates nodes on
	// demand, and dag_destroy frees nodes only through this map.
	for _, node in t.dag.nodes {
		for to in node.edges {
			if _, known := t.dag.nodes[to]; !known {
				return false, "fold snapshot dag edge points at a missing node"
			}
		}
		for from in node.rev {
			if _, known := t.dag.nodes[from]; !known {
				return false, "fold snapshot dag rev points at a missing node"
			}
		}
	}

	lines, lines_bad, lines_why := snap_array(root, "anomalies", scratch)
	if lines_bad {
		return false, lines_why
	}
	for el in lines {
		line, is_str := snap_value_str(el)
		if !is_str {
			return false, "fold snapshot anomaly line is not a string"
		}
		append(&t.anomalies, strings.clone(line, t.allocator))
	}
	return true, ""
}

@(private)
restore_incident :: proc(t: ^Fold_State, o: map[string]json.Value, scratch: mem.Allocator) -> string {
	h := new(Incident_Header, t.allocator)
	// The state owns h only once it lands in t.incidents; every early
	// return below would otherwise leak the partially built header (the
	// destroy helpers are partial-safe: they skip "" fields and nil
	// dynamics).
	inserted := false
	defer if !inserted {
		incident_header_destroy(h, t.allocator)
		free(h, t.allocator)
	}
	if w := snap_clone_str(&h.uid, t, o, "uid", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.id, t, o, "id", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.title, t, o, "title", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.status, t, o, "status", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.priority, t, o, "priority", scratch); w != "" {
		return w
	}
	if w := snap_str_slice_field(&h.labels, t, o, "labels", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.sprint, t, o, "sprint", scratch); w != "" {
		return w
	}
	if w := snap_str_slice_field(&h.blocked_by, t, o, "blocked_by", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.assignee, t, o, "assignee", scratch); w != "" {
		return w
	}
	if w := snap_str_slice_field(&h.aliases, t, o, "aliases", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.created_by, t, o, "created_by", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.verdict, t, o, "verdict", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.fp_pattern, t, o, "fp_pattern", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&h.created_ms, o, "created_ms", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&h.updated_ms, o, "updated_ms", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&h.verified_ms, o, "verified_ms", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&h.resolved_ms, o, "resolved_ms", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.resolution, t, o, "resolution", scratch); w != "" {
		return w
	}
	if w := snap_bool_field(&h.is_deleted, o, "deleted", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.duplicate_of, t, o, "duplicate_of", scratch); w != "" {
		return w
	}
	if w := snap_bool_field(&h.is_anomaly, o, "anomaly", scratch); w != "" {
		return w
	}
	if w := snap_dyn_str_field(&h.anomaly_detail, t, o, "anomaly_detail", scratch); w != "" {
		return w
	}
	ls, known := o["last_status"]
	if !known {
		return "fold snapshot incident is missing last_status"
	}
	lso, is_obj := jsonutil.as_object(ls)
	if !is_obj {
		return "fold snapshot incident last_status is not an object"
	}
	kind_str, k_ok := snap_field_str(lso, "kind")
	if !k_ok {
		return "fold snapshot incident last_status kind is not a string"
	}
	kind, kind_known := event_kind_from_string(kind_str)
	if !kind_known {
		return "fold snapshot incident last_status kind is unknown"
	}
	h.last_status.kind = kind
	if w := snap_i64_field(&h.last_status.ts_ms, lso, "ts_ms", scratch); w != "" {
		return w
	}
	origin, o_ok := snap_field_str(lso, "origin")
	if !o_ok {
		return "fold snapshot incident last_status origin is not a string"
	}
	if origin != "" {
		h.last_status.origin = strings.clone(origin, t.allocator)
	}
	if w := snap_int_field(&h.note_count, o, "note_count", scratch); w != "" {
		return w
	}
	refs, refs_bad, why := snap_array(o, "events", scratch)
	if refs_bad {
		return why
	}
	events, w := event_refs_from_json(t, refs, "incident", scratch)
	if w != "" {
		return w
	}
	h.events = events
	t.incidents[h.uid] = h
	inserted = true
	return ""
}

@(private)
restore_sprint :: proc(t: ^Fold_State, o: map[string]json.Value, scratch: mem.Allocator) -> string {
	h := new(Sprint_Header, t.allocator)
	// Same partial-ownership contract as restore_incident: the state owns
	// the header only after the final insert.
	inserted := false
	defer if !inserted {
		sprint_header_destroy(h, t.allocator)
		free(h, t.allocator)
	}
	if w := snap_clone_str(&h.id, t, o, "id", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.name, t, o, "name", scratch); w != "" {
		return w
	}
	status_str, s_ok := snap_field_str(o, "status")
	if !s_ok {
		return "fold snapshot sprint status is not a string"
	}
	status, known := sprint_status_from_string(status_str)
	if !known {
		return "fold snapshot sprint status is unknown"
	}
	h.status = status
	if w := snap_i64_field(&h.started_ms, o, "started_ms", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&h.closed_ms, o, "closed_ms", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&h.follows, t, o, "follows", scratch); w != "" {
		return w
	}
	if w := snap_str_slice_field(&h.must, t, o, "must", scratch); w != "" {
		return w
	}
	verifs, verifs_bad, why := snap_array(o, "verifications", scratch)
	if verifs_bad {
		return why
	}
	h.verifications = make([dynamic]Task_Verif, 0, len(verifs), t.allocator)
	for el in verifs {
		vm, is_obj := jsonutil.as_object(el)
		if !is_obj {
			return "fold snapshot sprint verification is not an object"
		}
		v: Task_Verif
		// Loop-body scope: the defer fires each iteration, freeing the
		// clones this round took unless the append completed them.
		appended := false
		defer if !appended {
			free_partial_verif(&v, t.allocator)
		}
		if w := snap_clone_str(&v.task, t, vm, "task", scratch); w != "" {
			return w
		}
		if w := snap_clone_str(&v.definition, t, vm, "definition", scratch); w != "" {
			return w
		}
		if w := snap_clone_str(&v.outcome, t, vm, "outcome", scratch); w != "" {
			return w
		}
		if w := snap_clone_str(&v.output, t, vm, "output", scratch); w != "" {
			return w
		}
		if w := snap_clone_str(&v.session, t, vm, "session", scratch); w != "" {
			return w
		}
		if w := snap_i64_field(&v.ts_ms, vm, "ts_ms", scratch); w != "" {
			return w
		}
		append(&h.verifications, v)
		appended = true
	}
	refs, refs_bad, refs_why := snap_array(o, "events", scratch)
	if refs_bad {
		return refs_why
	}
	events, w := event_refs_from_json(t, refs, "sprint", scratch)
	if w != "" {
		return w
	}
	h.events = events
	t.sprints[h.id] = h
	inserted = true
	return ""
}

// free_partial_verif releases the string clones a Task_Verif restore took
// before bailing mid-way; only ever called on a zero-valued struct whose
// non-empty fields are that restore's own clones.
@(private)
free_partial_verif :: proc(v: ^Task_Verif, a: mem.Allocator) {
	if v.task != "" { delete(v.task, a) }
	if v.definition != "" { delete(v.definition, a) }
	if v.outcome != "" { delete(v.outcome, a) }
	if v.output != "" { delete(v.output, a) }
	if v.session != "" { delete(v.session, a) }
}

@(private)
restore_defer :: proc(t: ^Fold_State, o: map[string]json.Value, scratch: mem.Allocator) -> string {
	d := new(Defer_Record, t.allocator)
	// Same partial-ownership contract as restore_incident.
	inserted := false
	defer if !inserted {
		defer_record_destroy(d, t.allocator)
		free(d, t.allocator)
	}
	if w := snap_clone_str(&d.id, t, o, "id", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.sprint, t, o, "sprint", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.kind, t, o, "kind", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.body_md, t, o, "body_md", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.task, t, o, "task", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.ref, t, o, "ref", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&d.ts_ms, o, "ts_ms", scratch); w != "" {
		return w
	}
	if w := snap_i64_field(&d.resolved_ms, o, "resolved_ms", scratch); w != "" {
		return w
	}
	if w := snap_clone_str(&d.resolved_by, t, o, "resolved_by", scratch); w != "" {
		return w
	}
	t.defers[d.id] = d
	inserted = true
	return ""
}

// ---------------------------------------------------------------------------
// Field accessors: strict-typed reads that return "" on success and a
// reason (in `scratch`) on any structural surprise.

@(private)
snap_member :: proc(o: map[string]json.Value, key: string) -> json.Value {
	if v, ok := o[key]; ok {
		return v
	}
	return json.Value(nil)
}

@(private)
snap_array :: proc(o: map[string]json.Value, key: string, scratch: mem.Allocator) -> (arr: []json.Value, bad: bool, reason: string) {
	v, ok := o[key]
	if !ok {
		return nil, true, fmt.aprintf("fold snapshot is missing %s", key, allocator = scratch)
	}
	val, is_arr := jsonutil.as_array(v)
	if !is_arr {
		return nil, true, fmt.aprintf("fold snapshot %s is not an array", key, allocator = scratch)
	}
	// An empty array parses to a nil slice; it is a legal value, not a
	// failure — the caller distinguishes via `bad`.
	return val, false, ""
}

@(private)
snap_value_str :: proc(v: json.Value) -> (string, bool) {
	#partial switch x in v {
	case json.String:
		return string(x), true
	case:
	}
	return "", false
}

@(private)
snap_field_str :: proc(o: map[string]json.Value, key: string) -> (string, bool) {
	v, ok := o[key]
	if !ok {
		return "", false
	}
	return snap_value_str(v)
}

@(private)
snap_field_int :: proc(o: map[string]json.Value, key: string) -> (i64, bool) {
	v, ok := o[key]
	if !ok {
		return 0, false
	}
	#partial switch x in v {
	case json.Integer:
		return x, true
	case:
	}
	return 0, false
}

@(private)
snap_clone_str :: proc(dst: ^string, t: ^Fold_State, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	s, ok := snap_field_str(o, key)
	if !ok {
		return fmt.aprintf("fold snapshot field %s is not a string", key, allocator = scratch)
	}
	if s != "" {
		dst^ = strings.clone(s, t.allocator)
	}
	return ""
}

@(private)
snap_i64_field :: proc(dst: ^i64, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	n, ok := snap_field_int(o, key)
	if !ok {
		return fmt.aprintf("fold snapshot field %s is not an integer", key, allocator = scratch)
	}
	dst^ = n
	return ""
}

@(private)
snap_int_field :: proc(dst: ^int, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	n, ok := snap_field_int(o, key)
	if !ok {
		return fmt.aprintf("fold snapshot field %s is not an integer", key, allocator = scratch)
	}
	dst^ = int(n)
	return ""
}

@(private)
snap_bool_field :: proc(dst: ^bool, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	v, ok := o[key]
	if !ok {
		return fmt.aprintf("fold snapshot field %s is not a boolean", key, allocator = scratch)
	}
	#partial switch x in v {
	case json.Boolean:
		dst^ = x
		return ""
	case:
	}
	return fmt.aprintf("fold snapshot field %s is not a boolean", key, allocator = scratch)
}

// snap_str_slice_field restores a []string field; an empty array leaves
// the nil slice in place (serialize renders nil as [] either way).
@(private)
snap_str_slice_field :: proc(dst: ^[]string, t: ^Fold_State, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	arr, bad, why := snap_array(o, key, scratch)
	if bad {
		return why
	}
	if len(arr) == 0 {
		return ""
	}
	out := make([]string, len(arr), t.allocator)
	for el, i in arr {
		s, is_str := snap_value_str(el)
		if !is_str {
			// The error leaves the field untouched — free the slice and
			// the element clones made so far instead of leaking them.
			for j in 0..<i {
				delete(out[j], t.allocator)
			}
			delete(out, t.allocator)
			return fmt.aprintf("fold snapshot %s entry is not a string", key, allocator = scratch)
		}
		out[i] = strings.clone(s, t.allocator)
	}
	dst^ = out
	return ""
}

@(private)
snap_dyn_str_field :: proc(dst: ^[dynamic]string, t: ^Fold_State, o: map[string]json.Value, key: string, scratch: mem.Allocator) -> string {
	arr, bad, why := snap_array(o, key, scratch)
	if bad {
		return why
	}
	if len(arr) == 0 {
		return ""
	}
	dst^ = make([dynamic]string, 0, len(arr), t.allocator)
	for el in arr {
		s, is_str := snap_value_str(el)
		if !is_str {
			return fmt.aprintf("fold snapshot %s entry is not a string", key, allocator = scratch)
		}
		append(dst, strings.clone(s, t.allocator))
	}
	return ""
}
