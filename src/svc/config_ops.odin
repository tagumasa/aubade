// The svc.config/* family: method names for the session-side project
// config write surface. Both methods mutate .aubade/project.jsonc (via
// the format-preserving JSONC editor, validated against the loader) and
// register as mutating — read-only sessions are refused at the boundary.
// The daemon owns the file write; the child never edits config files
// directly.
package svc

METHOD_CONFIG_SET :: "svc.config/set"      // {key, value, member?} -> {action, created, live_applied, stopped, local_override}
METHOD_CONFIG_DELETE :: "svc.config/delete" // {key, member?} -> {action, live_applied, stopped, local_override}
