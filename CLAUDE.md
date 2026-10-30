# Language

Write everything in English: code identifiers, comments, commit messages,
user-facing strings and documentation. Keep it English even when the
conversation is in another language.

# Licensing

The source is public, but realm is proprietary: keep the all-rights-reserved
LICENSE (at the root and in `packages/realm/`) and `license = "Proprietary"`
in package.lua. Never relicense it.

# Releases

This repository is its own pkg registry (see README): any change under
`packages/realm/` needs a new `version` in package.lua, or the CI fails.
