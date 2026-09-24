// The aubade version. This constant is the single source of the version
// string — the CLI banner, the LSP initialize handshake, the config
// overview, and the user agent all cite it; nothing else may hardcode a
// version number. (Semantic-version parsing and comparison stay in
// src/util — they are generic string utilities.)
package version

AUBADE_VERSION :: "1.0.3"

// The project's repository — the contact URL the honest user agent
// cites, so site operators can identify the bot. Kept beside the version
// so the tool's identity has one source; the git remote is the
// authority for its value.
AUBADE_REPO_URL :: "https://github.com/tagumasa/aubade"
