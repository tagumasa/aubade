// Language-server launch definitions (data-driven), the registry that
// indexes them, runtime prerequisite checks, project language detection,
// and the manager that owns running server instances in the parent
// daemon. One daemon holds one Registry and one Manager per project root.
// The pinned-binary dependency installer (verified archive download) is a
// separate later addition; the entries here only probe the local system.
package langserver
