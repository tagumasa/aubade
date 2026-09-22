// LSP client. The wire layer is the shared jsonrpc Conn (Content-Length
// framing, Pending correlation table, bounded server->client dispatch);
// this package adds the LSP specifics: the request wrapper with per-client
// timeout and $/cancelRequest propagation, builtin answers for the
// server->client requests every language server sends, the bounded
// diagnostics store fed by textDocument/publishDiagnostics, the
// initialize/initialized handshake with the cached server capabilities,
// full-text document sync (didOpen/didChange/didClose), and the
// cross-file-reference readiness wait (first diagnostics or WorkDone
// progress end, with a fallback settle wait).
//
// The client owns no threads and no process: the process lifecycle
// (spawn/initialize/shutdown/kill-tree) lives in the lsproc layer, which
// hands a connected Conn to client_init.
package lsp
