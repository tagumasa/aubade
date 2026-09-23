// Builtin directory-name exclusions shared by every project file-tree
// walker — the tree-sitter symbol crawl, the language-detection scan,
// and the workspace-roots walk. Name-based only: any entry — file or
// directory — carrying one of these names is skipped during traversal.
package config

DEFAULT_IGNORED_DIRS :: []string{
	".git", ".svn", ".hg", ".bzr",
	"node_modules", "vendor",
	"dist", "build", "__pycache__",
	".venv", ".env",
	".cache", ".mypy_cache", ".pytest_cache", ".ruff_cache",
	".tox", ".nox",
	".idea", ".aubade", ".vscode",
}

// default_ignored_dir reports whether an entry name is excluded from
// project file-tree traversal by the builtin set.
default_ignored_dir :: proc(name: string) -> bool {
	dirs := DEFAULT_IGNORED_DIRS
	for i in 0..<len(dirs) {
		if dirs[i] == name {
			return true
		}
	}
	return false
}
