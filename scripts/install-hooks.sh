#!/usr/bin/env bash
# Install Foder's local git hooks so CHANGELOG.md keeps itself up to date.
#
# Usage:  bash scripts/install-hooks.sh [--uninstall]
#
# What you get
#   post-commit   regenerates the "Unreleased" block of CHANGELOG.md after every
#                 commit (and folds it into that commit when it has not been
#                 pushed yet). Skip one commit with FODER_SKIP_CHANGELOG_HOOK=1.
#
# The same job also runs in CI (.github/workflows/changelog.yml), so this hook
# is a convenience, not a requirement.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--uninstall" ]; then
  git config --unset core.hooksPath || true
  echo "hooks disabled (core.hooksPath unset)"
  exit 0
fi

git config core.hooksPath .githooks
chmod +x .githooks/post-commit scripts/update_changelog.py 2>/dev/null || true

echo "git hooks installed -> $(pwd)/.githooks"
echo "CHANGELOG.md will now update itself on every commit."
echo "Disable with: bash scripts/install-hooks.sh --uninstall"
