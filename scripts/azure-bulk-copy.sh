#!/usr/bin/env bash
#
# The bulk copy example (examples/bulk-copy) between an on-premises SQL
# Server and Azure SQL Database: the example's scenarios.sh, run with the
# source on one server and the target on the other.
#
# Builds on scripts/azure-sql-test.sh: its 'setup' creates the Azure SQL
# server and the test database this uses (the demo's tables go in schema
# copydemo of that database, apart from the test suite's), and its 'env'
# supplies the connection settings, so the AZ_* configuration and the
# password file are the same.  The client is this machine, not a container
# in Azure: the rows cross the internet, which is the point of the exercise
# (a slow, long link between the two connections of one copy).  If the
# server's firewall refuses this machine, 'run' offers to add a rule for
# its address (azure-sql-test.sh allow-my-ip).
#
# The on-premises server is the one the MSSQL_* variables describe (see
# examples/README.md), with the demo's databases on it
# (hmssql_example_copy_a and _b, created if needed), e.g. the local test
# server:
#
#   source ~/.hmssql-test-env
#   export MSSQL_PASSWORD=$HMSSQL_TEST_PASSWORD MSSQL_CA_CERT=$HMSSQL_TEST_CERT
#   scripts/azure-bulk-copy.sh run
#
# Commands:
#
#   run [direction...]  run scenarios.sh in each direction: to-azure (on-premises
#                       source, Azure target), from-azure, within-azure (both
#                       tables in the Azure database, the rows going through
#                       this machine); default: to-azure from-azure
#   env <direction>     print the SOURCE_/TARGET_ exports of a direction, to run
#                       hmssql-example-bulk-copy by hand
#   clean               drop the demo's tables and schema from the Azure database
#
# ROWS (default 20000 here: each run copies the table about fifteen times
# over the link) and BULK_COPY are passed to scenarios.sh.  The logs are
# kept in $HOME/.config/hmssql-azure/logs/bulk-copy-<direction>-<time>.log.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AZURE_SQL_TEST=$ROOT/scripts/azure-sql-test.sh
SCENARIOS=$ROOT/examples/bulk-copy/scenarios.sh
LOG_DIR=${HMSSQL_AZURE_STATE_DIR:-$HOME/.config/hmssql-azure}/logs
LOCAL_SOURCE_DB=hmssql_example_copy_a
LOCAL_TARGET_DB=hmssql_example_copy_b
export ROWS=${ROWS:-20000}

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'azure-bulk-copy: %s\n' "$*" >&2; exit 1; }

bulk_copy_exe() {
  if [ -z "${BULK_COPY:-}" ]; then
    log "building the example"
    (cd "$ROOT" && stack build hmssql-example-bulk-copy >&2)
    BULK_COPY=$(cd "$ROOT" && stack exec -- which hmssql-example-bulk-copy)
    export BULK_COPY
  fi
}

# The Azure database's connection settings as exports of <prefix>MSSQL_*,
# from azure-sql-test.sh env (evaluated in a subshell, so its HMSSQL_TEST_*
# variables don't replace the local server's).  Every variable the local
# side might set is given a value, so none of the local settings (a CA
# file, MSSQL_TRUST_SERVER_CERT) applies to Azure: its certificate is
# validated against the system store, for the host connected to.
# (load_azure_env first, outside a subshell, so it runs az once.)
AZURE_ENV=
load_azure_env() {
  [ -n "$AZURE_ENV" ] && return
  AZURE_ENV=$("$AZURE_SQL_TEST" env) || die "azure-sql-test.sh env failed (has 'setup' been run? is az logged in?)"
}
azure_exports() {
  local prefix=$1
  [ -n "$AZURE_ENV" ] || die "internal: load_azure_env was not called"
  (
    eval "$AZURE_ENV"
    put() { printf 'export %sMSSQL_%s=%q\n' "$prefix" "$1" "$2"; }
    put HOST "$HMSSQL_TEST_HOST"
    put PORT "$HMSSQL_TEST_PORT"
    put USER "$HMSSQL_TEST_USER"
    put PASSWORD "$HMSSQL_TEST_PASSWORD"
    put DATABASE "$HMSSQL_TEST_DATABASE"
    put SERVER_NAME "$HMSSQL_TEST_SERVER_NAME"
    put ENCRYPT strict
    put CA_CERT ""
    put TRUST_SERVER_CERT 0
  )
}

# The exports for a direction: the Azure side by prefix, the on-premises
# side from MSSQL_* with only its database named.
direction_exports() {
  case $1 in
    to-azure)
      printf 'export SOURCE_MSSQL_DATABASE=%q\n' "$LOCAL_SOURCE_DB"
      azure_exports TARGET_ ;;
    from-azure)
      azure_exports SOURCE_
      printf 'export TARGET_MSSQL_DATABASE=%q\n' "$LOCAL_TARGET_DB" ;;
    within-azure)
      azure_exports SOURCE_
      azure_exports TARGET_ ;;
    *) die "unknown direction '$1' (to-azure, from-azure, within-azure)" ;;
  esac
}

need_local() {
  [ -n "${MSSQL_PASSWORD:-}" ] || die "MSSQL_PASSWORD (and the other MSSQL_* variables) must describe the on-premises server"
}

# Run SQL on the Azure database, printing the first result set.
azure_query() {
  (eval "$(azure_exports TARGET_)"; "$BULK_COPY" sql target "$1")
}

# Connect to the Azure database; if its firewall refuses this machine
# (error 40615), offer to add a rule, and wait for it to apply.
check_azure() {
  local out answer i
  if out=$(azure_query "SELECT CONCAT(@@SERVERNAME, ' / ', DB_NAME(), ', ',
      CAST(DATABASEPROPERTYEX(DB_NAME(), 'Edition') AS nvarchar(30)), ' ',
      CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(30)))" 2>&1); then
    log "Azure: $out"
    return
  fi
  case $out in
    *40615*)
      printf '%s\n' "$out" >&2
      read -r -p "add a firewall rule for this machine's address? [y/N] " answer
      [ "$answer" = y ] || [ "$answer" = Y ] || die "cancelled"
      "$AZURE_SQL_TEST" allow-my-ip
      for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 10
        if azure_query "SELECT 1" >/dev/null 2>&1; then
          log "the firewall lets this machine in"
          return
        fi
      done
      die "the firewall rule has not taken effect after two minutes; try again" ;;
    *) die "can't connect to the Azure database: $out" ;;
  esac
}

cmd_run() {
  need_local
  bulk_copy_exe
  load_azure_env
  check_azure
  [ $# -gt 0 ] || set -- to-azure from-azure
  mkdir -p "$LOG_DIR"
  local direction failed=() exports logfile status
  for direction in "$@"; do
    exports=$(direction_exports "$direction")
    logfile=$LOG_DIR/bulk-copy-$direction-$(date -u +%Y%m%dT%H%M%SZ).log
    log "$direction ($ROWS rows), log in $logfile"
    set +e
    (eval "$exports"; "$SCENARIOS") 2>&1 | tee "$logfile"
    status=${PIPESTATUS[0]}
    set -e
    [ "$status" -eq 0 ] || failed+=("$direction")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    die "outcomes differed: ${failed[*]}"
  fi
  log "every direction as expected: $*"
}

cmd_env() {
  [ $# -eq 1 ] || die "env: expected one direction (to-azure, from-azure, within-azure)"
  load_azure_env
  direction_exports "$1"
}

cmd_clean() {
  bulk_copy_exe
  load_azure_env
  log "dropping schema copydemo from the Azure database"
  (
    eval "$(azure_exports TARGET_)"
    "$BULK_COPY" sql target "SET NOCOUNT ON;
      DROP TABLE IF EXISTS copydemo.event, copydemo.event_copy, copydemo.event_narrow, copydemo.event_bad;
      DROP SCHEMA IF EXISTS copydemo;
      SELECT 'dropped'"
  )
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case ${1:-} in
  run) shift; cmd_run "$@" ;;
  env) shift; cmd_env "$@" ;;
  clean) shift; cmd_clean "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
