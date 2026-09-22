// Startup index warm-up. The crawl is the only project-wide population path
// for the symbol name index, and nothing on the daemon side ever ran it: the
// CLI verbs (project index/doctor) were the sole entry points, so a fresh
// store answered every symbol_find with an empty result until each file was
// touched by symbol_list. The thread runs the whole-project crawl once per
// store generation (kv marker), re-warms an index the TTL sweep emptied, and
// never blocks startup — readiness and RPC service run on their own threads,
// and the crawl itself is bounded (file/depth caps, per-entry cancellation
// on the root token). Like the sweeper, it shares the db handle safely:
// transaction spans serialize through the store's transaction mutex.
package daemon

import "core:fmt"
import "core:strings"
import "src:platform"
import "src:store"
import "src:svc"
import "src:util"

INDEX_WARM_KEY :: "index.crawled"

index_warm_thread_entry :: proc(data: rawptr) {
	index_warm_run(cast(^Daemon)data)
}

// index_warm_run is the one-shot warm-up step, directly callable from tests.
// Returns whether a crawl attempt ran.
index_warm_run :: proc(d: ^Daemon) -> (crawled: bool) {
	if !index_warm_needed(d) {
		return false
	}
	index_warm_crawl(d)
	return true
}

// index_warm_needed reports whether the warm-up crawl should run: never
// crawled in this store (marker absent — a partially touched index still
// counts, symbol_list only fills the files it read), or fully swept empty
// since the last crawl (row count zero — the TTL sweep can expire every row
// of a long-lived store).
index_warm_needed :: proc(d: ^Daemon) -> bool {
	if d.db == nil || d.ts == nil {
		return false
	}
	_, found, gerr := store.kv_get(d.db, INDEX_WARM_KEY, context.temp_allocator)
	if gerr != nil {
		util.log_warning("index warm-up: store kv read failed; skipping")
		return false
	}
	if found {
		count, cerr := store.symbol_cache_count(d.db)
		if cerr != nil {
			util.log_warning("index warm-up: index count failed; skipping")
			return false
		}
		return count == 0
	}
	return true
}

// index_warm_crawl runs the whole-project crawl and stamps the marker on
// completion. Cancellation and hard errors leave the marker unset so the
// next daemon generation retries; unreadable files count in stats, not
// errors, and still count as crawled.
index_warm_crawl :: proc(d: ^Daemon) {
	stats: svc.Crawl_Stats
	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, context.temp_allocator)
	err := svc.ts_source_crawl(d.ts, "", &stats, ignore, &d.file_safety.deny_list, context.temp_allocator, d.root)
	// Release before the free_all calls below: the spec's PCRE2 code lives
	// outside the temp allocator, everything else in it dies wholesale.
	svc.spec_release_c_side(ignore.extra)
	if err != nil {
		if !stats.cancelled {
			util.log_warning(
				strings.concatenate(
					{"index warm-up: crawl failed; the next daemon start retries: ", platform.err_message(err)},
				),
			)
		}
	} else {
		if werr := store.kv_put(d.db, INDEX_WARM_KEY, "1"); werr != nil {
			util.log_warning("index warm-up: could not stamp the crawl marker; the next daemon start retries")
		}
		util.log_info(
			fmt.aprintf(
				"index warm-up: %d files, %d symbols indexed (%d failed, %d unsupported)",
				stats.files_indexed,
				stats.symbols,
				stats.files_failed,
				stats.files_unsupported,
				allocator = context.temp_allocator,
			),
		)
	}
	free_all(context.temp_allocator)
	// The crawl parsed the whole project; its trees and scratch are freed —
	// release the allocator-retained pages (see platform.heap_trim).
	platform.heap_trim()
}
