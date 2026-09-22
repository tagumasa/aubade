// LSP method names as constants — callers reference these, never scattered
// string literals. The table grows with the slices that need them; every
// entry here is used through client_call/client_notify, a handler
// registration, or the raw cancel body, so there are no dead names.
package lsp

// --- client -> server (requests) ---

METHOD_INITIALIZE       :: "initialize"
METHOD_SHUTDOWN         :: "shutdown"
METHOD_DOCUMENT_SYMBOL  :: "textDocument/documentSymbol"
METHOD_WORKSPACE_SYMBOL :: "workspace/symbol"
METHOD_DEFINITION       :: "textDocument/definition"
METHOD_DECLARATION      :: "textDocument/declaration"
METHOD_TYPE_DEFINITION  :: "textDocument/typeDefinition"
METHOD_IMPLEMENTATION   :: "textDocument/implementation"
METHOD_REFERENCES       :: "textDocument/references"
METHOD_HOVER            :: "textDocument/hover"
METHOD_RENAME           :: "textDocument/rename"
METHOD_CODE_ACTION      :: "textDocument/codeAction"
METHOD_FORMATTING       :: "textDocument/formatting"
METHOD_INLAY_HINT      :: "textDocument/inlayHint"
METHOD_PREPARE_CALL_HIERARCHY :: "textDocument/prepareCallHierarchy"
METHOD_INCOMING_CALLS  :: "callHierarchy/incomingCalls"
METHOD_OUTGOING_CALLS  :: "callHierarchy/outgoingCalls"
METHOD_DOCUMENT_DIAGNOSTIC :: "textDocument/diagnostic"

// --- client -> server (notifications) ---

METHOD_INITIALIZED   :: "initialized"
METHOD_EXIT          :: "exit"
METHOD_CANCEL_REQUEST :: "$/cancelRequest"
METHOD_DID_OPEN      :: "textDocument/didOpen"
METHOD_DID_CHANGE    :: "textDocument/didChange"
METHOD_DID_CLOSE     :: "textDocument/didClose"

// --- server -> client (requests the client must answer) ---

METHOD_WORKSPACE_CONFIGURATION     :: "workspace/configuration"
METHOD_REGISTER_CAPABILITY         :: "client/registerCapability"
METHOD_UNREGISTER_CAPABILITY       :: "client/unregisterCapability"
METHOD_WORK_DONE_PROGRESS_CREATE   :: "window/workDoneProgress/create"

// --- server -> client (notifications) ---

METHOD_PUBLISH_DIAGNOSTICS :: "textDocument/publishDiagnostics"
METHOD_PROGRESS            :: "$/progress"
