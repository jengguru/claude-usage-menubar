#!/usr/bin/env bash
# Fails if the package gains a third-party Swift package dependency.
# Headroom deliberately has none: every dependency is code that ends up in an
# app that can read your Claude and Codex sign-ins. Adding one should be a
# conscious decision that also edits this check.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -nE '\.package\(' Package.swift; then
  echo "error: Package.swift declares a package dependency (see SECURITY.md)." >&2
  exit 1
fi
if [[ -e Package.resolved ]]; then
  echo "error: Package.resolved exists, so something resolved a dependency (see SECURITY.md)." >&2
  exit 1
fi
echo "OK: no third-party package dependencies."
