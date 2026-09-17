#!/usr/bin/env bash
# Headless tests for the helper extension. No VS Code required.
#
# extension.js is staged into this directory before running, because Node
# resolves `require('vscode')` from the requiring FILE's directory -- and the
# hand-written vscode stub lives here, not in source/. Keeping the stub out of
# source/ also keeps it out of the packaged .vsix.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
trap 'rm -f extension.js' EXIT
cp ../extension.js .
echo "Checking extension.js syntax..."
node --check extension.js
echo "Running column-marking tests..."
node column.test.js
