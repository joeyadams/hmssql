#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p upstream
curl -fsSL https://hackage-content.haskell.org/package/odbc-0.3.0.tar.gz -o upstream/odbc-0.3.0.tar.gz
printf '%s  %s\n' d2653e222e9485e1a72862146347aeca6276308c31d2b5d771013e7670f6f54e upstream/odbc-0.3.0.tar.gz | shasum -a 256 -c -
tar -xzf upstream/odbc-0.3.0.tar.gz -C upstream
