// The svc.shadow/* method names and their wire contracts. The child-side
// proxies live in client.odin; the daemon handlers in svc_shadow.odin.
package svc

METHOD_SHADOW_SNAPSHOT :: "svc.shadow/snapshot" // {message?} -> {hash}
METHOD_SHADOW_LOG :: "svc.shadow/log" // {count?} -> {text}
METHOD_SHADOW_DIFF :: "svc.shadow/diff" // {from, to} -> {text}
METHOD_SHADOW_PATCH :: "svc.shadow/patch" // {from, to} -> {text}
METHOD_SHADOW_RESTORE :: "svc.shadow/restore" // {hash} -> {}
METHOD_SHADOW_REVERT_FILE :: "svc.shadow/revert_file" // {hash, file_path} -> {}
