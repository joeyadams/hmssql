#!/usr/bin/env bash
#
# Run the hmssql test suite against Azure SQL Database, natively here with
# run-local, or from Azure Container Instances (ACI) in the same region.
# The round trip from a developer machine is 10-50x longer, and an
# application would run there anyway.
#
# The suite is compiled here (Ubuntu 24.04 or a derivative, so that the
# executable's glibc matches the container's) and uploaded to an Azure Files
# share, which a stock Ubuntu 24.04 container mounts; no Docker image is
# built.  The executable needs only libc, libm, libz and libgmp, which the
# stock image has; the CA bundle for the server certificate is uploaded next
# to it.  ACI is billed by the second while the container runs, and nothing
# while it is stopped; the database is billed as long as it exists.
#
# Commands (in the order you need them):
#
#   setup            create the resource group, SQL server (connection policy
#                    AZ_SQL_CONNECTION_POLICY, Azure services allowed through
#                    the firewall),
#                    database, storage account and file share; register the
#                    ACI provider if needed
#   check-local      run the built suite in the same Ubuntu image locally,
#                    with Docker (needs no server: pure and mock tests), to
#                    check that the executable runs there
#   upload           build the suite with stack and upload it (+ run.sh, CA
#                    bundle) to the share
#   seed             create the fixtures and the companion database before
#                    any real run: a run that matches only a pure module, so
#                    the pre-test hook does the setup and nothing races it
#   run [hspec args] run the suite in ACI, stream its output, save the log,
#                    exit with its status; HMSSQL_TEST_* variables set here
#                    (HMSSQL_TEST_SLOW, _ENCRYPTION, ...) are passed through
#   wait             pick up the current run again (Ctrl+C stops the watching,
#                    not the run): stream, wait, save the log, return its status
#   status           what exists, database SKUs, container state, share files
#   logs             the last container's output (and the saved logs)
#   stop             stop a running container
#   prune            drop the scratch databases failed runs left behind
#                    (hmssql_test..._<pid>_<time>_<n>), never the test
#                    database or the companion
#   scale <sku>      change the test database's service objective, e.g.
#                    Basic while idle (about $5/month, 2 GB), S3 to run
#   allow-my-ip      let this machine through the firewall (to run the suite
#                    or a client locally against the Azure database)
#   env              print HMSSQL_TEST_* exports for a local run
#   run-local [args] run the native test suite here against the seeded Azure
#                    database, without Docker or ACI; use HMSSQL_TEST_EXE
#                    for an existing executable, otherwise build with Stack
#   teardown [--yes] delete the resource group, with everything in it
#
# Sizing: the container defaults to 1 vCPU and 2 GB, which the no-server
# suite (check-local) fits in; run.sh gives the RTS one capability per CPU
# of the container's quota (64 MB of allocation area each).  With the
# suite's default of 16 parallel jobs on 1 vCPU, a timing test on the
# mock server (Concurrency.Attention) sometimes fails; --jobs 4 passes.
# For a bigger container, set both for the runs that need it, e.g.
# AZ_CONTAINER_CPU=8 AZ_CONTAINER_MEMORY=16 scripts/azure-sql-test.sh run.
# ACI can't change an existing group's CPU or memory, so a run with other
# sizes deletes the group first (and pulls the image afresh, a few
# seconds).  The subscription's ACI quota (StandardCores per region, 10 by
# default) caps the size; 'status' shows it.
#
# Configuration: the variables below, overridable from the environment.
# AZ_PREFIX (your prefix for Azure resource names, e.g. alice) and
# AZ_SUBSCRIPTION have no default: export them in ~/.hmssql-test-env, the
# file the live tests source, and run e.g. scripts/azure-sql-test.sh setup.
# The generated SQL admin password is kept in $HOME/.config/hmssql-azure (or
# set AZ_SQL_PASSWORD).
#
set -euo pipefail

# ---- Configuration ---------------------------------------------------------

AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION:-}
AZ_LOCATION=${AZ_LOCATION:-eastus}
# Names must be unique across Azure (the SQL server's DNS name, the storage
# account), so they carry a prefix.
AZ_PREFIX=${AZ_PREFIX:-}

# AZ_PREFIX and AZ_SUBSCRIPTION are the developer's own; export them in
# ~/.hmssql-test-env rather than writing them here.
case ${1:-} in
  -h|--help|help|"") ;;
  *)
    [ -n "$AZ_PREFIX" ] || { echo "$(basename "$0"): AZ_PREFIX is unset: your prefix for Azure resource names (e.g. alice); export it in ~/.hmssql-test-env" >&2; exit 1; }
    [ -n "$AZ_SUBSCRIPTION" ] || { echo "$(basename "$0"): AZ_SUBSCRIPTION is unset: the Azure subscription id; export it in ~/.hmssql-test-env" >&2; exit 1; }
    ;;
esac
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-$AZ_PREFIX-hmssql-test}
AZ_SQL_SERVER=${AZ_SQL_SERVER:-$AZ_PREFIX-hmssql-test}
AZ_SQL_ADMIN=${AZ_SQL_ADMIN:-${AZ_PREFIX}_admin}
AZ_SQL_DATABASE=${AZ_SQL_DATABASE:-hmssql_test}
# The shared test database: Standard tier, generous.
AZ_SQL_EDITION=${AZ_SQL_EDITION:-Standard}
AZ_SQL_OBJECTIVE=${AZ_SQL_OBJECTIVE:-S3}
AZ_SQL_MAX_SIZE=${AZ_SQL_MAX_SIZE:-250GB}
# The companion database: a second database the suite keeps, for the tests
# that need one (and SNAPSHOT isolation).  The suite creates it with
# AZ_SQL_SCRATCH_OPTIONS on its first run ('seed'), which takes 25-60 s, and
# keeps it: Basic, about $5/month.
AZ_SQL_COMPANION_DATABASE=${AZ_SQL_COMPANION_DATABASE:-${AZ_SQL_DATABASE}_companion}
# Default redirects logins from inside Azure to the node hosting the
# database, which connect follows; Proxy keeps every connection on the
# gateway (scripts/azure-bench.sh compares the two).
AZ_SQL_CONNECTION_POLICY=${AZ_SQL_CONNECTION_POLICY:-Default}
# What the suite appends to CREATE DATABASE for the databases it creates
# itself (the companion, and the scratch databases): without it, Azure SQL
# makes them General Purpose with 2 vCores, billed by the hour.
AZ_SQL_SCRATCH_OPTIONS=${AZ_SQL_SCRATCH_OPTIONS:-"(EDITION = 'Basic', MAXSIZE = 100 MB)"}
# The storage account (3-24 lowercase letters and digits) and share.
AZ_STORAGE_ACCOUNT=${AZ_STORAGE_ACCOUNT:-$(printf '%s' "${AZ_PREFIX}hmssqltest" | tr -cd 'a-z0-9' | cut -c1-24)}
AZ_SHARE=${AZ_SHARE:-hmssql}
# The container: stingy.  1 vCPU is enough, the tests wait for the server.
AZ_CONTAINER=${AZ_CONTAINER:-hmssql-tests}
AZ_CONTAINER_CPU=${AZ_CONTAINER_CPU:-1}
AZ_CONTAINER_MEMORY=${AZ_CONTAINER_MEMORY:-2}
# Microsoft's mirror of the Docker Hub image: no registry of our own, no
# Docker Hub rate limits.
AZ_CONTAINER_IMAGE=${AZ_CONTAINER_IMAGE:-mcr.microsoft.com/mirror/docker/library/ubuntu:24.04}
# Where the password, the staged upload and the downloaded logs live.
STATE_DIR=${HMSSQL_AZURE_STATE_DIR:-$HOME/.config/hmssql-azure}
# The CA bundle uploaded for the server certificate (DigiCert Global Root G2
# and friends): the local system store.
CA_BUNDLE=${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}

MOUNT=/mnt/hmssql
STAGE=$STATE_DIR/share
LOG_DIR=$STATE_DIR/logs
PASSWORD_FILE=$STATE_DIR/$AZ_SQL_SERVER.password

# ---- Helpers ---------------------------------------------------------------

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'azure-sql-test: %s\n' "$*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed"; done; }

# Every az call names the subscription explicitly: the script never
# switches the CLI's default subscription.
az() { command az "$@" --subscription "$AZ_SUBSCRIPTION" --only-show-errors; }

load_password() {
  [ -n "${AZ_SQL_PASSWORD:-}" ] && return
  [ -f "$PASSWORD_FILE" ] && AZ_SQL_PASSWORD=$(<"$PASSWORD_FILE") && return
  die "no SQL admin password: run 'setup' first, or set AZ_SQL_PASSWORD (expected $PASSWORD_FILE)"
}

# A jq definition, for 'az sql db list' output, of the databases a run of
# the suite left behind (its scratch databases), which 'prune' drops: every
# database the suite creates and drops has a name that starts with
# hmssql_test and ends with uniqueName's _<run>_<time>_<n> (the run tag
# was the process id before 2026-10-02, and is base 36 now).  Before
# 2026-10-01, Connection.DatabaseSpec's odd names started "hmssql test",
# "hmssql]test]", "hmssql_únïcödé" and "xyyy...", and runs whose drops
# silently failed left them on the server, so those shapes count too.  The
# test database and the companion are kept, whatever their names; the caller
# passes them as $keep and $companion.
LEFTOVER_JQ='def leftover: .name != $keep and .name != $companion and .name != "master"
  and (.name | test("^(hmssql.*|xy+)_[0-9a-z]+_[0-9a-z]+_[0-9]+$"));'

# The databases of 'az sql db list' (JSON on stdin) that 'prune' drops, one
# name per line.
leftover_databases() {
  jq -r --arg keep "$AZ_SQL_DATABASE" --arg companion "$AZ_SQL_COMPANION_DATABASE" \
    "$LEFTOVER_JQ"' .[] | select(leftover) | .name'
}

server_fqdn() {
  az sql server show -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" --query fullyQualifiedDomainName -o tsv
}

storage_key() {
  az storage account keys list -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" --query '[0].value' -o tsv
}

# The container's state (Waiting, Running, Terminated, ...), or nothing if
# the group does not exist.
container_state() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" \
    --query 'containers[0].instanceView.currentState.state' -o tsv 2>/dev/null || true
}

# The container group's CPU and memory, as "cpu mem", or nothing if it
# does not exist.
container_size() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" \
    --query '[containers[0].resources.requests.cpu, containers[0].resources.requests.memoryInGb]' -o tsv 2>/dev/null \
    | tr '\n\t' '  ' || true
}

# The subscription's ACI core quota in the region, as "used limit".
aci_core_usage() {
  az rest --method get \
    --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.ContainerInstance/locations/$AZ_LOCATION/usages?api-version=2023-05-01" \
    --query "value[?name.value=='StandardCores'] | [0].[currentValue, limit]" -o tsv 2>/dev/null | tr '\n\t' '  ' || true
}

container_exit_code() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" \
    --query 'containers[0].instanceView.currentState.exitCode' -o tsv
}

# The test executable as stack builds it (stack.yaml's ghc-options:
# unoptimised tests, optimised library), built if needed.
build_tests() {
  need stack
  log "building the test suite"
  stack build hmssql-tests:test:hmssql-tests --no-run-tests >&2 || return
  local exe
  exe=$(stack path --project-root)/hmssql-tests/$(stack path --dist-dir) || return
  exe=$exe/build/hmssql-tests/hmssql-tests
  [ ! -f "$exe.exe" ] || exe=$exe.exe
  [ -x "$exe" ] || die "no test executable at $exe"
  echo "$exe"
}

# What the container runs: copies the executable off the SMB mount, runs it
# with the arguments from the args file, and keeps the output on the share.
write_run_sh() {
  cat > "$1" <<'RUNSH'
#!/bin/bash
# Runs the hmssql test suite from the mounted share (uploaded by
# scripts/azure-sql-test.sh; the same script runs under 'check-local').
set -u
# The stock image has no locale set, and the test output has non-ASCII
# characters (hedgehog's progress bars); C.UTF-8 is built into glibc.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
share=${HMSSQL_SHARE:-/mnt/hmssql}
run_id=${HMSSQL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$share/logs" /opt/hmssql
{
  echo "hmssql tests: run $run_id on $(hostname 2>/dev/null || cat /etc/hostname), $(nproc) cpu(s), $(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo) MB"
  if [ ! -f "$share/hmssql-tests" ]; then
    echo "hmssql tests: no hmssql-tests on the share; run 'scripts/azure-sql-test.sh upload' first"
    exit 2
  fi
  # Local disk: faster than the SMB mount, and certainly executable.
  cp "$share/hmssql-tests" /opt/hmssql/hmssql-tests
  chmod +x /opt/hmssql/hmssql-tests
  args=()
  [ -s "$share/args.txt" ] && mapfile -t args < "$share/args.txt"
  # The stock image has no system certificate store (no ca-certificates
  # package): the uploaded bundle is it, through crypton-x509-system's own
  # override.  Nothing else is trusted, so the connections validate the
  # server's certificate the way an application with default TLS settings
  # does: against the system store, for the host it connected to.
  export SYSTEM_CERTIFICATE_PATH=$share/certs
  # Capabilities: one per CPU the container may use.  The RTS's -N counts
  # the CPUs it sees, which a CPU quota (Docker's --cpus, cgroup cpu.max)
  # does not reduce: 32 capabilities with a 64 MB allocation area each
  # (-A64m) is 2 GB of nursery before the first test.
  cpus=$(nproc)
  if [ -r /sys/fs/cgroup/cpu.max ] && read -r quota period < /sys/fs/cgroup/cpu.max && [ "$quota" != max ]; then
    cpus=$(( (quota + period - 1) / period ))
    [ "$cpus" -lt 1 ] && cpus=1
  fi
  echo "hmssql-tests ${args[*]} +RTS -N$cpus (of $(nproc) visible cpus)"
  /opt/hmssql/hmssql-tests "${args[@]}" +RTS -N"$cpus" -RTS
  status=$?
  echo "hmssql tests: exit status $status"
  exit $status
} 2>&1 | tee "$share/logs/$run_id.log"
exit "${PIPESTATUS[0]}"
RUNSH
  chmod +x "$1"
}

# Build and lay out what the share holds: the executable, run.sh, the CA
# bundle.
stage() {
  local exe
  exe=$(build_tests)
  mkdir -p "$STAGE/certs"
  install -m 755 "$exe" "$STAGE/hmssql-tests"
  command -v strip >/dev/null && strip "$STAGE/hmssql-tests"
  write_run_sh "$STAGE/run.sh"
  [ -f "$CA_BUNDLE" ] || die "no CA bundle at $CA_BUNDLE (set CA_BUNDLE)"
  install -m 644 "$CA_BUNDLE" "$STAGE/certs/ca-certificates.crt"
  log "staged $(du -h "$STAGE/hmssql-tests" | cut -f1) executable in $STAGE"
}

# The test arguments, one per line, for run.sh (args.txt on the share).
write_args() {
  local file=$1; shift
  if [ $# -eq 0 ]; then : > "$file"; else printf '%s\n' "$@" > "$file"; fi
}

# HMSSQL_TEST_* variables set in this environment that the suite should see
# in the container, as KEY=VALUE words, except the ones the script sets.
passthrough_env() {
  local v
  for v in $(compgen -e | grep '^HMSSQL_TEST_' || true); do
    case $v in
      HMSSQL_TEST_HOST|HMSSQL_TEST_PORT|HMSSQL_TEST_USER|HMSSQL_TEST_PASSWORD|HMSSQL_TEST_DATABASE|HMSSQL_TEST_COMPANION_DATABASE|\
      HMSSQL_TEST_CERT|HMSSQL_TEST_TLS_HOSTNAME|HMSSQL_TEST_SERVER_NAME|HMSSQL_TEST_CREATE_DATABASE_OPTIONS|HMSSQL_TEST_REQUIRE_SERVER) ;;
      *) printf '%s=%s\n' "$v" "${!v}" ;;
    esac
  done
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "cancelled"
}

# ---- Commands --------------------------------------------------------------

cmd_setup() {
  need az jq
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  chmod 700 "$STATE_DIR"
  if [ -z "${AZ_SQL_PASSWORD:-}" ] && [ -f "$PASSWORD_FILE" ]; then
    AZ_SQL_PASSWORD=$(<"$PASSWORD_FILE")
  elif [ -z "${AZ_SQL_PASSWORD:-}" ]; then
    # Letters and digits only: three character classes, and nothing to quote.
    AZ_SQL_PASSWORD=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-28)aZ9
  fi
  (umask 077; printf '%s' "$AZ_SQL_PASSWORD" > "$PASSWORD_FILE")

  if [ "$(az provider show -n Microsoft.ContainerInstance --query registrationState -o tsv)" != Registered ]; then
    log "registering the Microsoft.ContainerInstance provider (once per subscription)"
    az provider register --namespace Microsoft.ContainerInstance --wait
  fi

  log "resource group $AZ_RESOURCE_GROUP in $AZ_LOCATION"
  az group create -n "$AZ_RESOURCE_GROUP" -l "$AZ_LOCATION" -o none

  if az sql server show -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" -o none 2>/dev/null; then
    log "SQL server $AZ_SQL_SERVER exists"
  else
    log "SQL server $AZ_SQL_SERVER (admin $AZ_SQL_ADMIN)"
    az sql server create -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" -l "$AZ_LOCATION" \
      --admin-user "$AZ_SQL_ADMIN" --admin-password "$AZ_SQL_PASSWORD" \
      --minimal-tls-version 1.2 --enable-public-network true -o none
  fi
  log "connection policy $AZ_SQL_CONNECTION_POLICY, firewall open to Azure services"
  az sql server conn-policy update -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" --connection-type "$AZ_SQL_CONNECTION_POLICY" -o none
  # ACI's outbound address is not fixed, so the rule is the one for all Azure
  # services (0.0.0.0 - 0.0.0.0), as the portal's "Allow Azure services".
  az sql server firewall-rule create -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n AllowAzureServices \
    --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none

  if az sql db show -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "$AZ_SQL_DATABASE" -o none 2>/dev/null; then
    log "database $AZ_SQL_DATABASE exists"
  else
    log "database $AZ_SQL_DATABASE ($AZ_SQL_EDITION $AZ_SQL_OBJECTIVE, $AZ_SQL_MAX_SIZE)"
    az sql db create -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "$AZ_SQL_DATABASE" \
      --edition "$AZ_SQL_EDITION" --service-objective "$AZ_SQL_OBJECTIVE" --max-size "$AZ_SQL_MAX_SIZE" \
      --backup-storage-redundancy Local --zone-redundant false -o none
  fi

  if az storage account show -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" -o none 2>/dev/null; then
    log "storage account $AZ_STORAGE_ACCOUNT exists"
  else
    log "storage account $AZ_STORAGE_ACCOUNT"
    az storage account create -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" -l "$AZ_LOCATION" \
      --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false -o none
  fi
  if ! az storage share-rm show -g "$AZ_RESOURCE_GROUP" --storage-account "$AZ_STORAGE_ACCOUNT" -n "$AZ_SHARE" -o none 2>/dev/null; then
    log "file share $AZ_SHARE"
    az storage share-rm create -g "$AZ_RESOURCE_GROUP" --storage-account "$AZ_STORAGE_ACCOUNT" -n "$AZ_SHARE" --quota 5 -o none
  fi

  log "done: server $(server_fqdn), password in $PASSWORD_FILE"
  # The suite creates the companion database itself, with the options it
  # gives every database it creates, so setup leaves it to the first run.
  echo "next: $0 check-local; $0 upload; $0 seed (which creates the companion database $AZ_SQL_COMPANION_DATABASE); $0 run" >&2
}

cmd_check_local() {
  need docker
  stage
  mkdir -p "$LOG_DIR"
  # A copy of the staged share with this run's args, mounted like the ACI
  # share, with the logs going to the local log directory.
  local share=$STATE_DIR/local-share run_id
  rm -rf "$share"
  cp -a "$STAGE" "$share"
  write_args "$share/args.txt" "$@"
  run_id=local-$(date -u +%Y%m%dT%H%M%SZ)
  local envs=(-e "HMSSQL_RUN_ID=$run_id")
  local kv
  while IFS= read -r kv; do [ -n "$kv" ] && envs+=(-e "$kv"); done < <(passthrough_env)
  # A password set here reaches a local server through --network host
  # (HMSSQL_TEST_HOST defaults to ::1); without one, the pure and mock
  # tests run, which is what checks the executable.
  [ -n "${HMSSQL_TEST_PASSWORD:-}" ] && envs+=(-e HMSSQL_TEST_PASSWORD)
  [ -n "${HMSSQL_TEST_HOST:-}" ] && envs+=(-e HMSSQL_TEST_HOST)
  log "running in $AZ_CONTAINER_IMAGE locally (${AZ_CONTAINER_CPU} cpu, ${AZ_CONTAINER_MEMORY} GB)"
  local status=0
  # --cpus is a quota; --cpuset-cpus is what makes nproc (and the RTS's
  # -N) see that many CPUs, as ACI does.
  docker run --rm --network host --cpus "$AZ_CONTAINER_CPU" --cpuset-cpus "0-$((AZ_CONTAINER_CPU - 1))" -m "${AZ_CONTAINER_MEMORY}g" \
    -v "$share:$MOUNT" -v "$LOG_DIR:$MOUNT/logs" \
    "${envs[@]}" "$AZ_CONTAINER_IMAGE" bash "$MOUNT/run.sh" || status=$?
  rm -rf "$share"
  log "exit status $status; log saved to $LOG_DIR/$run_id.log"
  return $status
}

cmd_upload() {
  need az
  stage
  local key
  key=$(storage_key)
  log "uploading to share $AZ_SHARE of $AZ_STORAGE_ACCOUNT"
  az storage file upload-batch --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --destination "$AZ_SHARE" --source "$STAGE" --no-progress -o none
  log "uploaded"
}

cmd_run() {
  need az jq
  load_password
  mkdir -p "$LOG_DIR"
  local state
  state=$(container_state)
  case $state in
    Running|Waiting) die "container $AZ_CONTAINER is $state: wait for it (logs: $0 logs) or stop it ($0 stop)" ;;
  esac
  local fqdn key run_id args
  fqdn=$(server_fqdn)
  key=$(storage_key)
  run_id=$(date -u +%Y%m%dT%H%M%SZ)
  # az takes a --path whose last component has no dot for a directory (and
  # appends the source file's name), hence the extension.
  local args
  args=$(mktemp)
  write_args "$args" "$@"
  az storage file upload --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --share-name "$AZ_SHARE" --source "$args" --path args.txt --no-progress -o none
  rm -f "$args"

  # HMSSQL_TEST_TLS_HOSTNAME is empty on purpose: the certificate is
  # validated against the host, and only the system store is trusted, as
  # an application with default TLS settings does it.
  local envs=(
    "HMSSQL_TEST_HOST=$fqdn"
    "HMSSQL_TEST_PORT=1433"
    "HMSSQL_TEST_USER=$AZ_SQL_ADMIN"
    "HMSSQL_TEST_DATABASE=$AZ_SQL_DATABASE"
    "HMSSQL_TEST_COMPANION_DATABASE=$AZ_SQL_COMPANION_DATABASE"
    "HMSSQL_TEST_TLS_HOSTNAME="
    "HMSSQL_TEST_SERVER_NAME=$AZ_SQL_SERVER"
    "HMSSQL_TEST_CREATE_DATABASE_OPTIONS=$AZ_SQL_SCRATCH_OPTIONS"
    "HMSSQL_TEST_REQUIRE_SERVER=1"
    "HMSSQL_RUN_ID=$run_id"
  )
  local kv
  while IFS= read -r kv; do [ -n "$kv" ] && envs+=("$kv"); done < <(passthrough_env)

  # ACI can't change CPU or memory in place: another size means a new group.
  # The quota is checked first, counting the cores of the group this run
  # replaces, so that a size that doesn't fit leaves the old group alone.
  local size used limit
  size=$(container_size)
  read -r used limit <<< "$(aci_core_usage)"
  if [ -n "${limit:-}" ]; then
    local free
    free=$(awk -v u="$used" -v l="$limit" -v s="${size%% *}" 'BEGIN { print l - u + (s == "" ? 0 : s) }')
    awk -v c="$AZ_CONTAINER_CPU" -v f="$free" 'BEGIN { exit !(c + 0 > f + 0) }' \
      && die "$AZ_CONTAINER_CPU cpu is more than the $free left of the subscription's ACI quota ($used of $limit StandardCores in $AZ_LOCATION); ask for more under Quotas > Azure Container Instances in the portal"
  fi
  if [ -n "$size" ] && ! awk -v s="$size" -v c="$AZ_CONTAINER_CPU" -v m="$AZ_CONTAINER_MEMORY" \
       'BEGIN { split(s, a, " "); exit !(a[1] + 0 == c + 0 && a[2] + 0 == m + 0) }'; then
    log "container $AZ_CONTAINER is sized ${size% }; deleting it to create one with $AZ_CONTAINER_CPU cpu, $AZ_CONTAINER_MEMORY GB"
    az container delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" --yes -o none
  fi

  log "run $run_id: hmssql-tests $* (${AZ_CONTAINER_CPU} cpu, ${AZ_CONTAINER_MEMORY} GB, $AZ_LOCATION)"
  # Creating a group that exists (stopped) redeploys it with the new
  # settings; HMSSQL_RUN_ID always differs, so it always restarts.
  az container create -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" -l "$AZ_LOCATION" \
    --image "$AZ_CONTAINER_IMAGE" --os-type Linux --cpu "$AZ_CONTAINER_CPU" --memory "$AZ_CONTAINER_MEMORY" \
    --restart-policy Never \
    --azure-file-volume-account-name "$AZ_STORAGE_ACCOUNT" --azure-file-volume-account-key "$key" \
    --azure-file-volume-share-name "$AZ_SHARE" --azure-file-volume-mount-path "$MOUNT" \
    --command-line "bash $MOUNT/run.sh" \
    --environment-variables "${envs[@]}" \
    --secure-environment-variables "HMSSQL_TEST_PASSWORD=$AZ_SQL_PASSWORD" \
    -o none
  printf '%s' "$run_id" > "$STATE_DIR/last-run"
  log "started; Ctrl+C stops watching, not the run: '$0 wait' picks it up again"
  follow_run "$run_id"
}

# Stream the running container's output, wait for it to end, save its log
# and return its exit status.
follow_run() {
  local run_id=$1 state
  # Stream the output while polling for the end: attach doesn't always
  # notice the container terminating.
  az container attach -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" 2>/dev/null &
  local attach=$!
  trap 'kill $attach 2>/dev/null' EXIT
  local waited=0
  while :; do
    state=$(container_state)
    [ "$state" = Terminated ] && break
    if [ "$state" != Running ] && [ $waited -ge 600 ]; then
      kill $attach 2>/dev/null || true
      az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" --query 'containers[0].instanceView.events' -o table >&2
      die "container $AZ_CONTAINER is still $state after 10 minutes (events above)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  local n=0
  while kill -0 $attach 2>/dev/null && [ $n -lt 6 ]; do sleep 2; n=$((n + 1)); done
  kill $attach 2>/dev/null || true
  wait $attach 2>/dev/null || true
  trap - EXIT
  local code
  code=$(container_exit_code)
  az storage file download --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$(storage_key)" \
    --share-name "$AZ_SHARE" --path "logs/$run_id.log" --dest "$LOG_DIR/$run_id.log" --no-progress -o none 2>/dev/null \
    && log "log saved to $LOG_DIR/$run_id.log"
  log "run $run_id finished with exit status $code"
  return "${code:-1}"
}

# Pick up the last run started here (after a Ctrl+C, or from another
# terminal): the container runs on regardless of this script.
cmd_wait() {
  need az jq
  mkdir -p "$LOG_DIR"
  local run_id
  run_id=$(cat "$STATE_DIR/last-run" 2>/dev/null) || die "no run started from here (no $STATE_DIR/last-run)"
  log "run $run_id: container $AZ_CONTAINER is $(container_state || echo absent)"
  follow_run "$run_id"
}

cmd_seed() {
  log "seeding: a run that matches only pure tests, so the pre-test hook creates the fixtures alone"
  cmd_run --match Wire.Primitives
}

cmd_status() {
  need az jq
  if ! az group show -n "$AZ_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "resource group $AZ_RESOURCE_GROUP does not exist (run setup)"
    return
  fi
  echo "resource group:    $AZ_RESOURCE_GROUP ($AZ_LOCATION), subscription $AZ_SUBSCRIPTION"
  if az sql server show -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" -o none 2>/dev/null; then
    echo "SQL server:        $(server_fqdn), admin $AZ_SQL_ADMIN, connection policy $(az sql server conn-policy show -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" --query connectionType -o tsv)"
    echo "databases:"
    az sql db list -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -o json \
      | jq -r --arg keep "$AZ_SQL_DATABASE" --arg companion "$AZ_SQL_COMPANION_DATABASE" "$LEFTOVER_JQ"'
          .[] | select(.name != "master")
          | "  \(.name)\t\(.edition) \(.currentServiceObjectiveName)\t\(.status)\t"
            + (if .name == $keep then "test database"
               elif .name == $companion then "companion (kept)"
               elif leftover then "left behind by a run: prune drops it"
               else "not made by the suite" end)'
    az sql db show -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "$AZ_SQL_COMPANION_DATABASE" -o none 2>/dev/null \
      || echo "  ($AZ_SQL_COMPANION_DATABASE, the companion, does not exist yet: the next run creates it, or run seed)"
  else
    echo "SQL server:        $AZ_SQL_SERVER does not exist"
  fi
  local state
  state=$(container_state)
  if [ -n "$state" ]; then
    local size
    size=$(container_size)
    echo "container:         $AZ_CONTAINER is $state$([ "$state" = Terminated ] && echo ", exit status $(container_exit_code)"), cpu/memory ${size% }"
  else
    echo "container:         $AZ_CONTAINER does not exist (created by the first run)"
  fi
  if az storage account show -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" -o none 2>/dev/null; then
    echo "share $AZ_SHARE:"
    az storage file list --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$(storage_key)" --share-name "$AZ_SHARE" -o json \
      | jq -r '.[] | "  \(.name)\t\(.properties.contentLength // "dir")"'
  else
    echo "storage account:   $AZ_STORAGE_ACCOUNT does not exist"
  fi
  local usage
  usage=$(aci_core_usage)
  [ -n "$usage" ] && echo "ACI cores:         ${usage% } in $AZ_LOCATION (used, limit)"
  echo "local state:       $STATE_DIR (password: $([ -f "$PASSWORD_FILE" ] && echo present || echo missing); logs: $(ls "$LOG_DIR" 2>/dev/null | wc -l))"
}

cmd_logs() {
  need az
  az container logs -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER"
  log "saved logs in $LOG_DIR:"
  ls -1t "$LOG_DIR" 2>/dev/null | head >&2
}

cmd_stop() {
  need az
  az container stop -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER"
  log "stopped $AZ_CONTAINER"
}

# Scratch databases the suite failed to drop (withScratchDatabase's
# hmssql_test_<suffix>_<unique>, and Connection.DatabaseSpec's odd names,
# which start with hmssql_test too): see LEFTOVER_JQ.
cmd_prune() {
  need az jq
  local dbs
  dbs=$(az sql db list -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -o json | leftover_databases)
  [ -n "$dbs" ] || { log "no scratch databases"; return; }
  while IFS= read -r db; do
    log "dropping $db"
    az sql db delete -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "$db" --yes -o none
  done <<< "$dbs"
}

# The max size goes with the tier: Basic allows 2 GB at most, so it is set
# in the same update (the data must fit), and scaling back up restores
# AZ_SQL_MAX_SIZE.  Either direction takes a few minutes.
cmd_scale() {
  need az
  local sku=${1:-} edition size
  case $sku in
    Basic) edition=Basic size=2GB ;;
    S[0-9]*) edition=Standard size=$AZ_SQL_MAX_SIZE ;;
    P[0-9]*) edition=Premium size=$AZ_SQL_MAX_SIZE ;;
    GP_*) edition=GeneralPurpose size=32GB ;;
    *) die "scale: expected Basic, S0..S12, P1..P15 or GP_..., not '$sku'" ;;
  esac
  log "scaling $AZ_SQL_DATABASE to $edition $sku, max size $size"
  az sql db update -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "$AZ_SQL_DATABASE" \
    --edition "$edition" --service-objective "$sku" --max-size "$size" -o none
}

cmd_allow_my_ip() {
  need az curl
  local ip
  ip=$(curl -fsS https://api.ipify.org) || die "could not find this machine's public address"
  log "allowing $ip through the firewall of $AZ_SQL_SERVER"
  az sql server firewall-rule create -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" -n "client-$(date -u +%Y%m%d-%H%M%S)" \
    --start-ip-address "$ip" --end-ip-address "$ip" -o none
}

cmd_env() {
  need az
  load_password
  local fqdn
  fqdn=$(server_fqdn) || return
  [ -n "$fqdn" ] || die "Azure returned no hostname for $AZ_SQL_SERVER"
  # This is sourced after a developer's local SQL Server configuration.
  # Select the Azure transport and certificate validation explicitly so
  # localhost's plaintext/trusted-certificate settings cannot leak into it.
  # Bash quoting also preserves passwords containing shell metacharacters.
  # Use the FQDN explicitly: GHC on Windows treats an empty environment
  # variable as unset, which would select the test harness's localhost.
  printf 'export %s=%q\n' \
    HMSSQL_TEST_HOST "$fqdn" \
    HMSSQL_TEST_PORT 1433 \
    HMSSQL_TEST_PROTOCOL tcp \
    HMSSQL_TEST_USER "$AZ_SQL_ADMIN" \
    HMSSQL_TEST_PASSWORD "$AZ_SQL_PASSWORD" \
    HMSSQL_TEST_DATABASE "$AZ_SQL_DATABASE" \
    HMSSQL_TEST_COMPANION_DATABASE "$AZ_SQL_COMPANION_DATABASE" \
    HMSSQL_TEST_ENCRYPTION strict \
    HMSSQL_TEST_SQL_VERSION 2025 \
    HMSSQL_TEST_STRICT_ENCRYPTION 1 \
    HMSSQL_TEST_TRUST_SERVER_CERTIFICATE 0 \
    HMSSQL_TEST_TLS_HOSTNAME "$fqdn" \
    HMSSQL_TEST_SERVER_NAME "$AZ_SQL_SERVER" \
    HMSSQL_TEST_CREATE_DATABASE_OPTIONS "$AZ_SQL_SCRATCH_OPTIONS" \
    HMSSQL_TEST_REQUIRE_SERVER 1
  printf 'unset HMSSQL_TEST_CERT\n'
}

cmd_run_local() {
  need az tee
  local exports exe=${HMSSQL_TEST_EXE:-} run_id status=0
  exports=$(cmd_env) || return
  eval "$exports"
  if [ -z "$exe" ]; then exe=$(build_tests) || return; fi
  if command -v cygpath >/dev/null; then exe=$(cygpath -u "$exe"); fi
  [ -x "$exe" ] || die "no executable at $exe (set HMSSQL_TEST_EXE or build the suite)"
  mkdir -p "$LOG_DIR"
  run_id=local-$(date -u +%Y%m%dT%H%M%SZ)-$$
  log "running $exe against $HMSSQL_TEST_HOST/$HMSSQL_TEST_DATABASE over TCP with validated strict TLS"
  # MSYS2 otherwise rewrites hspec patterns beginning with / as paths.
  MSYS2_ARG_CONV_EXCL='*' "$exe" "$@" 2>&1 | tee "$LOG_DIR/$run_id.log" || status=$?
  log "exit status $status; log saved to $LOG_DIR/$run_id.log"
  return "$status"
}

cmd_teardown() {
  need az
  local wait=()
  local yes=false
  for a in "$@"; do
    case $a in
      --yes|-y) yes=true ;;
      --no-wait) wait=(--no-wait) ;;
      *) die "teardown: unknown option $a" ;;
    esac
  done
  az group show -n "$AZ_RESOURCE_GROUP" -o none 2>/dev/null || { log "resource group $AZ_RESOURCE_GROUP does not exist"; return; }
  $yes || confirm "delete resource group $AZ_RESOURCE_GROUP (SQL server $AZ_SQL_SERVER and every database, the companion included, storage account $AZ_STORAGE_ACCOUNT, container $AZ_CONTAINER)?"
  log "deleting resource group $AZ_RESOURCE_GROUP"
  az group delete -n "$AZ_RESOURCE_GROUP" --yes "${wait[@]}"
  rm -f "$PASSWORD_FILE"
  log "deleted (the logs in $LOG_DIR are kept)"
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case ${1:-} in
  setup) shift; cmd_setup "$@" ;;
  check-local) shift; cmd_check_local "$@" ;;
  upload) shift; cmd_upload "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  run) shift; cmd_run "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  status) shift; cmd_status "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  scale) shift; cmd_scale "$@" ;;
  allow-my-ip) shift; cmd_allow_my_ip "$@" ;;
  env) shift; cmd_env "$@" ;;
  run-local) shift; cmd_run_local "$@" ;;
  teardown) shift; cmd_teardown "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
