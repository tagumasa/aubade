// Tests for the wired L1 payload tier: the TS read path serves L1 ahead
// of the hot L2 tree and the parse, a hash change misses and re-truths the
// index, the LSP outline path answers from L1 with the server refusing,
// and both producers (per-file TS, crawl, LSP) write decodable payloads.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:editor"
import "src:jsonrpc"
import "src:lsp"
import "src:platform"
import "src:store"
import "src:symbol"
import "src:svc"

@(test)
l1_ts_hit_serves_before_l2_and_parse :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	content := "package alpha\n\ntype Greeter struct{}\n\nfunc Add(a, b int) int { return a + b }\n"
	ts_write_file(t, f, "alpha.go", content)

	// First call: the real parse fills L0, L1, and the hot L2 tree.
	roots, err := svc.ts_source_file_symbols(f.src, "alpha.go")
	testing.expectf(t, err == nil, "first read: %v", err)
	testing.expect(t, len(roots) > 0)
	symbol.symbol_forest_destroy(roots, context.allocator)

	// Inject a payload no parse of this file could produce, under the
	// file's real content hash.
	zzz := symbol.symbol_new(context.allocator)
	zzz.name = strings.clone("ZZZ_INJECTED", context.allocator)
	zzz.kind = .Function
	inj := make([dynamic]^symbol.Symbol, 0, 1, context.allocator)
	append(&inj, zzz)
	payload := symbol.encode_symbol_payload(inj[:], context.allocator)
	names := []store.Symbol_Name_Row{{name = "ZZZ_INJECTED", kind = "Function", line = 0, parent = ""}}
	hash := editor.content_hash_hex(content, context.temp_allocator)
	werr := store.write_symbol_index(f.db, "alpha.go", hash, "go", names, payload, platform.clock_now(f.clock))
	testing.expectf(t, werr == nil, "inject write: %v", werr)
	delete(payload, context.allocator)
	delete(inj)
	symbol.symbol_node_free(zzz, context.allocator)

	// The L2 entry from the first call is hot — only an L1 probe that
	// comes FIRST can return the injected name.
	roots2, err2 := svc.ts_source_file_symbols(f.src, "alpha.go")
	testing.expectf(t, err2 == nil, "second read: %v", err2)
	testing.expectf(t, len(roots2) == 1 && roots2[0].name == "ZZZ_INJECTED", "expected the injected payload, got %d roots", len(roots2))
	symbol.symbol_forest_destroy(roots2, context.allocator)

	// Editing the file changes the hash: the read misses, re-parses, and
	// the index carries the true outline again.
	content2 := strings.concatenate({content, "\nfunc Extra() {}\n"}, context.allocator)
	defer delete(content2)
	ts_write_file(t, f, "alpha.go", content2)
	roots3, err3 := svc.ts_source_file_symbols(f.src, "alpha.go")
	testing.expectf(t, err3 == nil, "third read: %v", err3)
	injected_gone := true
	for i in 0..<len(roots3) {
		if roots3[i].name == "ZZZ_INJECTED" {
			injected_gone = false
		}
	}
	testing.expect(t, injected_gone, "stale payload survived a content change")
	testing.expect(t, len(roots3) >= 2, "re-parse lost symbols")
	symbol.symbol_forest_destroy(roots3, context.allocator)

	hash2 := editor.content_hash_hex(content2, context.temp_allocator)
	got, lang, found, perr := store.symbol_cache_payload(f.db, "alpha.go", hash2, platform.clock_now(f.clock), context.allocator)
	testing.expectf(t, perr == nil, "payload read: %v", perr)
	testing.expect(t, found, "re-parse did not rewrite the payload")
	testing.expectf(t, lang == "go", "language %q", lang)
	decoded, dok := symbol.decode_symbol_payload(got, f.dir, "alpha.go", context.allocator)
	testing.expect(t, dok, "rewritten payload failed to decode")
	if dok {
		testing.expect(t, len(decoded) > 0 && decoded[0].name != "ZZZ_INJECTED", "rewritten payload still injected")
		symbol.symbol_forest_destroy(decoded, context.allocator)
	}
	delete(got)
	delete(lang)
}

@(test)
l1_lsp_hit_answers_with_the_server_refusing :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-l1w-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	db_dir, dderr := os.make_directory_temp("", "aubade-l1wdb-", context.allocator)
	testing.expectf(t, dderr == nil, "temp db dir failed")
	defer {
		_ = os.remove_all(dir)
		delete(dir)
		_ = os.remove_all(db_dir)
		delete(db_dir)
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "db open failed")
	defer store.db_close(db)

	content := "package mod\n\ntype Client struct {\n\tID int\n}\n"
	lsp_write_file(dir, "src/mod.go", content)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_go_document_symbols)

	port := Fake_LSP_Port{client = p.client, language_id = "go", normalize = lsp_split_receiver}
	src := new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(src, dir, db, clock, nil, fake_lsp_port, &port, nil, context.allocator)
	defer {
		svc.lsp_source_destroy(src)
		free(src, context.allocator)
	}

	// Real round trip: the producer writes a decodable L1 payload.
	roots, err := svc.lsp_source_file_symbols(src, "src/mod.go", context.allocator)
	testing.expectf(t, err == nil, "first read: %s", platform.err_message(err))
	testing.expect(t, len(roots) == 1)
	symbol.symbol_forest_destroy(roots, context.allocator)

	hash := editor.content_hash_hex(content, context.temp_allocator)
	payload, lang, found, perr := store.symbol_cache_payload(db, "src/mod.go", hash, platform.clock_now(clock), context.allocator)
	testing.expectf(t, perr == nil, "payload read: %v", perr)
	testing.expect(t, found, "LSP producer wrote no payload")
	testing.expectf(t, lang == "go", "language %q", lang)
	delete(payload)
	delete(lang)

	// With the port refusing, only an L1 hit can answer — no server
	// start, no documentSymbol round trip.
	port.fail = true
	roots2, err2 := svc.lsp_source_file_symbols(src, "src/mod.go", context.allocator)
	testing.expectf(t, err2 == nil, "cached read: %s", platform.err_message(err2))
	testing.expectf(t, len(roots2) == 1 && roots2[0].name == "Client", "L1 did not serve with the port refusing")
	if len(roots2) == 1 {
		// The children are asserted unconditionally-then-guarded: a
		// regression that drops them must fail the count, not skip the
		// checks vacuously.
		testing.expectf(t, len(roots2[0].children) == 2, "Client children: %d", len(roots2[0].children))
		if len(roots2[0].children) == 2 {
			testing.expectf(t, roots2[0].children[0].name == "ID", "child 0 %s", roots2[0].children[0].name)
			testing.expectf(t, roots2[0].children[1].name == "Call", "child 1 %s", roots2[0].children[1].name)
		}
	}
	symbol.symbol_forest_destroy(roots2, context.allocator)

	// Sanity: with no payload cached the refusing port yields empty roots
	// (the lenient contract), proving the previous answer came from L1.
	lsp_write_file(dir, "src/other.go", "package mod\n")
	roots3, err3 := svc.lsp_source_file_symbols(src, "src/other.go", context.allocator)
	testing.expectf(t, err3 == nil, "uncached read: %s", platform.err_message(err3))
	testing.expect(t, len(roots3) == 0, "refusing port produced symbols")
	symbol.symbol_forest_destroy(roots3, context.allocator)
}

@(test)
l1_crawl_writes_payloads :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	content := "package alpha\n\ntype Greeter struct{}\n"
	ts_write_file(t, f, "alpha.go", content)

	stats: svc.Crawl_Stats
	cerr := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, cerr == nil, "crawl: %v", cerr)
	testing.expect(t, stats.files_indexed == 1)

	hash := editor.content_hash_hex(content, context.temp_allocator)
	payload, lang, found, perr := store.symbol_cache_payload(f.db, "alpha.go", hash, platform.clock_now(f.clock), context.allocator)
	testing.expectf(t, perr == nil, "payload read: %v", perr)
	testing.expect(t, found, "crawl wrote no payload")
	testing.expectf(t, lang == "go", "language %q", lang)
	decoded, dok := symbol.decode_symbol_payload(payload, f.dir, "alpha.go", context.allocator)
	testing.expect(t, dok, "crawl payload failed to decode")
	if dok {
		testing.expectf(t, len(decoded) == 1 && decoded[0].name == "Greeter", "decoded crawl payload")
		symbol.symbol_forest_destroy(decoded, context.allocator)
	}
	delete(payload)
	delete(lang)
}
