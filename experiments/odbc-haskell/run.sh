#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f ${HMSSQL_ENV_FILE:-$HOME/.hmssql-test-env} ]]; then
  set -a
  source "${HMSSQL_ENV_FILE:-$HOME/.hmssql-test-env}"
  set +a
fi
flags=()
if command -v brew >/dev/null; then
  dm=$(brew --prefix unixodbc)
  flags=(--extra-include-dirs="$dm/include" --extra-lib-dirs="$dm/lib")
  printf 'package odbc\n  extra-include-dirs: %s/include\n  extra-lib-dirs: %s/lib\n' "$dm" "$dm" > cabal.project.local
  export DYLD_LIBRARY_PATH="$(brew --prefix openssl@3)/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
cabal build exe:odbc-haskell-probe "${flags[@]}"
exe=$(cabal list-bin exe:odbc-haskell-probe "${flags[@]}")
exec "$exe" "$@"
