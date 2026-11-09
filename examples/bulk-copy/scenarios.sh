#!/usr/bin/env bash
#
# Runs every copy scenario and checks its outcome: creates the tables with
# setup-demo, runs the catalog check against each target, then copies copydemo.event with
# and without batches and transactions, making it fail three ways (a
# duplicate key on the server, a value refused on the client, the source
# stream failing), and checks how many rows each copy leaves in the target.
# Prints each command with its output, then a summary; exits 1 if any
# outcome differs from the expected one.
#
# The two connections come from the environment (see the README):
# SOURCE_MSSQL_* and TARGET_MSSQL_*, falling back to MSSQL_*.  Without
# SOURCE_MSSQL_DATABASE and TARGET_MSSQL_DATABASE, the databases are
# hmssql_example_copy_a and hmssql_example_copy_b on the one server, created
# if they don't exist.
#
#   ROWS=50000         rows in the source table; the failures are placed
#                      in proportion (the long title and the duplicate key
#                      at 4/5, the source failure at 1/2, batches of 1/5)
#   BULK_COPY=path     the executable (default: the one stack built)
#
set -euo pipefail

ROWS=${ROWS:-50000}
LONG_AT=$((ROWS * 4 / 5))
BATCH=$((ROWS / 5))
FAIL_AT=$((ROWS / 2))
export SOURCE_MSSQL_DATABASE=${SOURCE_MSSQL_DATABASE:-hmssql_example_copy_a}
export TARGET_MSSQL_DATABASE=${TARGET_MSSQL_DATABASE:-hmssql_example_copy_b}
if [ -z "${BULK_COPY:-}" ]; then
  BULK_COPY=$(cd "$(dirname "$0")/../.." && stack exec -- which hmssql-example-bulk-copy)
fi

# What each outcome leaves: the complete batches before the failing row.
# The duplicate key and the long title are at id LONG_AT (row LONG_AT - 1
# from 0); the source fails when row FAIL_AT + 1 is pulled.
BATCHES_BEFORE_LONG=$(( (LONG_AT - 1) / BATCH * BATCH ))
BATCHES_BEFORE_FAIL=$(( FAIL_AT / BATCH * BATCH ))

summary=()
failures=0

bulk_copy() { "$BULK_COPY" "$@"; }

# Run the tool, showing the command and its output; the exit status is in
# $status.
run() {
  printf '\n$ hmssql-example-bulk-copy %s\n' "$*"
  set +e
  bulk_copy "$@" 2>&1 | sed 's/^/    /'
  status=${PIPESTATUS[0]}
  set -e
}

# expect <what> <expected> <actual>
expect() {
  local verdict=ok
  if [ "$2" != "$3" ]; then verdict=FAIL; failures=$((failures + 1)); fi
  summary+=("$(printf '%-72s %9s %9s  %s' "$1" "$2" "$3" "$verdict")")
}

target_rows() { bulk_copy sql target "SELECT COUNT(*) FROM $1"; }

# copy_case <what> <expected exit status> <expected rows> <target> <copy arguments...>
copy_case() {
  local what=$1 want_status=$2 want_rows=$3 table=$4
  shift 4
  run copy --quiet copydemo.event "$table" "$@"
  expect "$what: exit status" "$want_status" "$status"
  expect "$what: rows in the target" "$want_rows" "$(target_rows "$table")"
}

empty() { bulk_copy sql target "SET NOCOUNT ON; DELETE FROM $1; SELECT COUNT(*) FROM $1" >/dev/null; }

# One row already in event_copy, with the id of the source's row LONG_AT.
seed_collision() {
  bulk_copy sql target "SET NOCOUNT ON; DELETE FROM copydemo.event_copy;
    INSERT INTO copydemo.event_copy (id, code, title, amount, qty, happened, logged_at, flag, ref)
    VALUES ($LONG_AT, 'SEED', N'already here', 0, 0, '2020-01-01', '2020-01-01', 0, NEWID());
    SELECT COUNT(*) FROM copydemo.event_copy" >/dev/null
}

echo "source: ${SOURCE_MSSQL_HOST:-${MSSQL_HOST:-localhost}} / $SOURCE_MSSQL_DATABASE"
echo "target: ${TARGET_MSSQL_HOST:-${MSSQL_HOST:-localhost}} / $TARGET_MSSQL_DATABASE"
echo "$ROWS rows; long title and duplicate key at id $LONG_AT; batches of $BATCH; source failure after $FAIL_AT rows"

run setup-demo --rows "$ROWS" --long-title-at "$LONG_AT"
expect "setup-demo" 0 "$status"

# ---- The catalog check ----------------------------------------------------

run check copydemo.event copydemo.event_copy
expect "check event -> event_copy (accepted)" 0 "$status"
run check copydemo.event copydemo.event_bad
expect "check event -> event_bad (refused)" 2 "$status"
run check copydemo.event copydemo.event_narrow --only id,code,title
expect "check event -> event_narrow --only id,code,title (accepted)" 0 "$status"
run copy copydemo.event copydemo.event_bad
expect "copy event -> event_bad (refused before reading a row)" 2 "$status"

# ---- A copy, compared -----------------------------------------------------

run copy copydemo.event copydemo.event_copy
expect "copy: exit status" 0 "$status"
expect "copy: rows in the target" "$ROWS" "$(target_rows copydemo.event_copy)"
# The same aggregates on both sides; the target's columns cast back to the
# source's types where the rounding or the type differs.
src_sums=$(bulk_copy sql source "SELECT COUNT(*), SUM(amount), SUM(CAST(qty AS bigint)), COUNT(note), SUM(CAST(LEN(note) AS bigint)),
  COUNT(doc), COUNT(payload), MAX(title), CHECKSUM_AGG(CHECKSUM(code, ref, happened, flag, payload)),
  CHECKSUM_AGG(CHECKSUM(CAST(logged_at AS datetime))) FROM copydemo.event")
dst_sums=$(bulk_copy sql target "SELECT COUNT(*), CAST(SUM(amount) AS decimal(38,2)), SUM(CAST(qty AS bigint)), COUNT(note), SUM(CAST(LEN(note) AS bigint)),
  COUNT(doc), COUNT(payload), MAX(title), CHECKSUM_AGG(CHECKSUM(CAST(code AS varchar(20)), ref, CAST(happened AS datetime), flag, payload)),
  CHECKSUM_AGG(CHECKSUM(logged_at)) FROM copydemo.event_copy")
echo "    source: $src_sums"
echo "    target: $dst_sums"
expect "copy: source and target aggregates agree" "same" "$([ "$src_sums" = "$dst_sums" ] && echo same || echo differ)"

copy_case "append again (duplicate key at id 1)" 1 "$ROWS" copydemo.event_copy
copy_case "--replace" 0 "$ROWS" copydemo.event_copy --replace
copy_case "--replace, the source failing midway" 1 "$ROWS" copydemo.event_copy --replace --fail-after "$FAIL_AT"
copy_case "--replace --table-lock --batch-size $BATCH" 0 "$ROWS" copydemo.event_copy --replace --table-lock --batch-size "$BATCH"

# ---- A duplicate key: the server refuses row LONG_AT ----------------------

seed_collision
copy_case "duplicate key, one load" 1 1 copydemo.event_copy
seed_collision
copy_case "duplicate key, --batch-size $BATCH" 1 $((BATCHES_BEFORE_LONG + 1)) copydemo.event_copy --batch-size "$BATCH"
seed_collision
copy_case "duplicate key, --batch-size $BATCH --transaction" 1 1 copydemo.event_copy --batch-size "$BATCH" --transaction

# ---- A value the column can't hold: refused on the client -----------------

empty copydemo.event_narrow
copy_case "long title, one load" 1 0 copydemo.event_narrow --only id,code,title
copy_case "long title, --batch-size $BATCH" 1 "$BATCHES_BEFORE_LONG" copydemo.event_narrow --only id,code,title --batch-size "$BATCH"
empty copydemo.event_narrow
copy_case "long title, --batch-size $BATCH --transaction" 1 0 copydemo.event_narrow --only id,code,title --batch-size "$BATCH" --transaction

# ---- The source failing midway --------------------------------------------

empty copydemo.event_copy
copy_case "source fails, one load" 1 0 copydemo.event_copy --fail-after "$FAIL_AT"
copy_case "source fails, --batch-size $BATCH" 1 "$BATCHES_BEFORE_FAIL" copydemo.event_copy --fail-after "$FAIL_AT" --batch-size "$BATCH"
empty copydemo.event_copy
copy_case "source fails, --batch-size $BATCH --transaction" 1 0 copydemo.event_copy --fail-after "$FAIL_AT" --batch-size "$BATCH" --transaction

# ---- Summary ----------------------------------------------------------------

printf '\n%-72s %9s %9s\n' "" expected actual
printf '%s\n' "${summary[@]}"
if [ "$failures" -gt 0 ]; then
  printf '\n%d outcome(s) differ\n' "$failures"
  exit 1
fi
printf '\nall %d outcomes as expected\n' "${#summary[@]}"
