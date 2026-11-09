#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f ${HMSSQL_ENV_FILE:-$HOME/.hmssql-test-env} ]]; then
  set -a
  source "${HMSSQL_ENV_FILE:-$HOME/.hmssql-test-env}"
  set +a
fi
if command -v brew >/dev/null; then
  dm=$(brew --prefix unixodbc)
  driver=$(brew --prefix msodbcsql18)
  includes=(-I"$dm/include" -I"$driver/include/msodbcsql18")
  libs=(-L"$dm/lib")
  # The driver dlopens OpenSSL. Keep the fix local to this process; do not
  # change Homebrew links or the user's system trust store.
  if [[ ${ODBC_TEST_OPENSSL_AUTO:-1} == 1 ]]; then
    export DYLD_LIBRARY_PATH="$(brew --prefix openssl@3)/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  fi
else
  includes=(-I/opt/microsoft/msodbcsql18/include)
  libs=()
fi
"${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE -O2 -g \
  -Wall -Wextra -Werror "${includes[@]}" odbc-probe.c \
  "${libs[@]}" -lodbc -lpthread -o odbc-probe
exec ./odbc-probe "$@"
