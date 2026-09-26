// Document synchronization: the client-side mirror of the documents the
// server has open. didOpen/didChange/didClose carry full text (a change
// event without a range is a full replacement — valid under every
// TextDocumentSyncKind, so one code path serves Full and Incremental
// servers alike). The mirror maps exactly the open document set (data,
// not a cache: it is bounded by what the callers open — opens are
// refcounted per URI, and an entry dies with the didClose of its last
// opener, so the editor sync's long-lived opens and the one-shot bridge
// opens share one epoch without closing it under each other).
package lsp

import "core:encoding/json"
import "core:strings"
import "core:sync"

import "src:jsonutil"

Doc_State :: struct {
	uri:         string, // owned (client allocator)
	language_id: string, // owned
	text:        string, // owned; the content the server was last told
	version:     i64,
	openers:     int, // shared-open count; the entry dies at zero
}

// doc_open mirrors a file into the server with didOpen. Opens are
// refcounted per URI: the first opener sends didOpen, later openers
// share the entry and keep its text — each close pairs its own open,
// and the didClose reaches the server when the last opener closes.
// Text and ids are copied into the client's allocator — the caller
// keeps its input.
doc_open :: proc(cl: ^Client, uri, language_id, text: string) -> bool {
	sync.mutex_lock(&cl.doc_mu)
	defer sync.mutex_unlock(&cl.doc_mu)
	sync.mutex_lock(&cl.state_mu)
	if st, open := cl.docs[uri]; open {
		st.openers += 1
		sync.mutex_unlock(&cl.state_mu)
		return true
	}
	st := new(Doc_State, cl.allocator)
	st^ = {
		uri          = strings.clone(uri, cl.allocator),
		language_id = strings.clone(language_id, cl.allocator),
		text         = strings.clone(text, cl.allocator),
		version      = 1,
		openers      = 1,
	}
	cl.docs[st.uri] = st
	sync.mutex_unlock(&cl.state_mu)
	// A new open epoch starts clean: a late publication for the closed
	// document can re-land after the previous epoch's close cleared the
	// store (the entry dies at close by design — a fresh epoch restarts
	// versions at 1, and a watermark surviving the close would drop its
	// early publications), and the new epoch's reads must not inherit it.
	// Only the epoch-creating open comes through here; shared opens keep
	// the epoch's live set.
	diagnostics_store_clear(&cl.diagnostics, uri)

	td := jsonutil.json_object(4, context.temp_allocator)
	jsonutil.obj_set(&td, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set(&td, "languageId", jsonutil.json_string(language_id))
	jsonutil.obj_set(&td, "version", jsonutil.json_int(1))
	jsonutil.obj_set(&td, "text", jsonutil.json_string(text))
	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "textDocument", json.Value(json.Object(td)))
	// The mirror change and its notification are ONE serialized step
	// (doc_mu): with the notify outside the lock, a concurrent
	// doc_close could post its didClose first and this didOpen would
	// reach the server as an unpaired open. The send is synchronous (LSP
	// conns carry no outbound writer); a wedged server blocks here only
	// until server_destroy kills the process and the pipe write fails —
	// nothing else orders against doc_mu, so no circular wait exists.
	return client_notify(cl, METHOD_DID_OPEN, json.Value(json.Object(params)))
}

// doc_change_full replaces the mirrored content and tells the server with
// a single full-replacement change event. Version increments come from the
// mirror, so concurrent callers cannot emit a duplicate version.
doc_change_full :: proc(cl: ^Client, uri, text: string) -> bool {
	// Same doc_mu discipline as open/close: the change event reaches
	// the wire in the mirror's order.
	sync.mutex_lock(&cl.doc_mu)
	defer sync.mutex_unlock(&cl.doc_mu)
	sync.mutex_lock(&cl.state_mu)
	st, open := cl.docs[uri]
	if !open {
		sync.mutex_unlock(&cl.state_mu)
		return false
	}
	new_text := strings.clone(text, cl.allocator)
	delete(st.text, cl.allocator)
	st.text = new_text
	st.version += 1
	// Snapshot under the lock: st stays in the map, so a concurrent
	// doc_close could free the state between unlock and the notify below.
	uri_snap := strings.clone(st.uri, context.temp_allocator)
	text_snap := strings.clone(st.text, context.temp_allocator)
	version := st.version
	sync.mutex_unlock(&cl.state_mu)

	td := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&td, "uri", jsonutil.json_string(uri_snap))
	jsonutil.obj_set(&td, "version", jsonutil.json_int(version))
	change := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&change, "text", jsonutil.json_string(text_snap))
	params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&params, "textDocument", json.Value(json.Object(td)))
	jsonutil.obj_set(
		&params,
		"contentChanges",
		jsonutil.json_array({json.Value(json.Object(change))}, context.temp_allocator),
	)
	return client_notify(cl, METHOD_DID_CHANGE, json.Value(json.Object(params)))
}

// doc_close drops one opener and tells the server when the last one
// left: the didClose reaches the wire exactly once per open epoch, so
// shared openers never close the document under each other. The stored
// diagnostics for the URI die with the entry — a server that publishes
// no empty set on didClose would otherwise leave them riding into later
// reads. The notification is built before the state is freed (its
// strings are borrowed).
doc_close :: proc(cl: ^Client, uri: string) -> bool {
	td := jsonutil.json_object(1, context.temp_allocator)

	sync.mutex_lock(&cl.doc_mu)
	defer sync.mutex_unlock(&cl.doc_mu)
	sync.mutex_lock(&cl.state_mu)
	st, open := cl.docs[uri]
	if !open {
		sync.mutex_unlock(&cl.state_mu)
		return false
	}
	st.openers -= 1
	if st.openers > 0 {
		sync.mutex_unlock(&cl.state_mu)
		return true
	}
	jsonutil.obj_set(&td, "uri", jsonutil.json_string(st.uri))
	delete_key(&cl.docs, uri)
	sync.mutex_unlock(&cl.state_mu)

	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "textDocument", json.Value(json.Object(td)))
	sent := client_notify(cl, METHOD_DID_CLOSE, json.Value(json.Object(params)))

	diagnostics_store_clear(&cl.diagnostics, st.uri)
	doc_state_free(cl, st)
	return sent
}

// doc_version reports the mirrored version for a URI, 0 when not open.
doc_version :: proc(cl: ^Client, uri: string) -> i64 {
	sync.mutex_lock(&cl.state_mu)
	st, open := cl.docs[uri]
	version := i64(0)
	if open {
		version = st.version
	}
	sync.mutex_unlock(&cl.state_mu)
	return version
}

doc_state_free :: proc(cl: ^Client, st: ^Doc_State) {
	delete(st.uri, cl.allocator)
	delete(st.language_id, cl.allocator)
	delete(st.text, cl.allocator)
	free(st, cl.allocator)
}

// docs_destroy frees the whole mirror (client teardown; the server
// connection is already gone at that point).
docs_destroy :: proc(cl: ^Client) {
	sync.mutex_lock(&cl.state_mu)
	for _, st in cl.docs {
		doc_state_free(cl, st)
	}
	delete(cl.docs)
	sync.mutex_unlock(&cl.state_mu)
}
