#!/usr/bin/env bash
#
# Test Entra ID authentication with Azure Managed Identity: run
# examples/managed-identity in a container in Azure Container Instances
# (ACI) that has a managed identity, against the Azure SQL Database that
# scripts/azure-sql-test.sh set up.  The container asks its identity endpoint
# for a token and logs in with connectAccessToken; no password anywhere.
#
# The example is compiled for linux/amd64 (what ACI runs) in ACI too: a
# stock Ubuntu 24.04 container (Microsoft's mirror; Docker Hub's rate limits
# have refused ACI the haskell image) installs GHC and cabal with
# scripts/linux-toolchain.sh, as the repository's Dockerfile does, and
# builds a tarball of the working tree uploaded to the Azure Files share of
# azure-sql-test.sh; the executable lands on the share, which the run
# container mounts.  So a Mac works, and no Docker is needed (a Linux/amd64
# build of the example made any other way, 'docker build' with the
# Dockerfile included, can be put on the share with 'upload').
#
# Commands, in the order you need them:
#
#   build        upload the working tree and compile the example in ACI
#                (AZ_BUILD_CPU vCPUs, 4 by default; nothing is cached between
#                builds), streaming the build's output.  The subscription's
#                ACI quota (10 cores per region by default) is shared with
#                azure-sql-test.sh's container, stopped or not
#   upload FILE  put a Linux/amd64 executable built elsewhere on the share
#   identity     create the user-assigned managed identity, if it doesn't
#                exist; print its ids
#   create-user  create the identity's user in the database and make it a
#                db_datareader, connecting as the server's Entra admin with a
#                token from 'az account get-access-token' (so: az logged in as
#                the Entra admin, and this machine allowed through the
#                firewall, azure-sql-test.sh allow-my-ip)
#   run [args]   run the example in ACI with the identity ('whoami' by
#                default; 'query SQL' or 'exec SQL' otherwise), stream its
#                output, exit with its status
#   whoami-local run the example here with a CLI token instead (no container)
#   status       what exists
#   logs         the last container's output
#   stop         stop the container
#   cleanup      delete the container group and the identity (the database
#                user stays; drop it with 'exec' if you like)
#
# Configuration: the same variables as azure-sql-test.sh (AZ_SUBSCRIPTION,
# AZ_PREFIX, ...), plus AZ_IDENTITY, the identity's name.
#
set -euo pipefail

# ---- Configuration ---------------------------------------------------------

AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION:-}
AZ_LOCATION=${AZ_LOCATION:-eastus}
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
AZ_SQL_DATABASE=${AZ_SQL_DATABASE:-hmssql_test}
AZ_STORAGE_ACCOUNT=${AZ_STORAGE_ACCOUNT:-$(printf '%s' "${AZ_PREFIX}hmssqltest" | tr -cd 'a-z0-9' | cut -c1-24)}
AZ_SHARE=${AZ_SHARE:-hmssql}
# The identity, and its user in the database (the same name).
AZ_IDENTITY=${AZ_IDENTITY:-$AZ_PREFIX-hmssql-mi}
AZ_CONTAINER=${AZ_CONTAINER:-hmssql-mi}
AZ_CONTAINER_IMAGE=${AZ_CONTAINER_IMAGE:-mcr.microsoft.com/mirror/docker/library/ubuntu:24.04}
# The build: the same Ubuntu image as the run, in a container group of its
# own, with the GHC of stack.yaml's snapshot.
AZ_BUILD_CONTAINER=${AZ_BUILD_CONTAINER:-hmssql-mi-build}
BUILD_IMAGE=${BUILD_IMAGE:-$AZ_CONTAINER_IMAGE}
GHC_VERSION=${GHC_VERSION:-9.12.4}
AZ_BUILD_CPU=${AZ_BUILD_CPU:-4}
AZ_BUILD_MEMORY=${AZ_BUILD_MEMORY:-8}
STATE_DIR=${HMSSQL_AZURE_STATE_DIR:-$HOME/.config/hmssql-azure}

MOUNT=/mnt/hmssql
EXE=hmssql-example-managed-identity
LOG_DIR=$STATE_DIR/logs
REPO=$(cd "$(dirname "$0")/.." && pwd)

# ---- Helpers ---------------------------------------------------------------

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'azure-managed-identity: %s\n' "$*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed"; done; }

az() { command az "$@" --subscription "$AZ_SUBSCRIPTION" --only-show-errors; }

server_fqdn() {
  az sql server show -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" --query fullyQualifiedDomainName -o tsv
}

storage_key() {
  az storage account keys list -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" --query '[0].value' -o tsv
}

identity_query() {
  az identity show -g "$AZ_RESOURCE_GROUP" -n "$AZ_IDENTITY" --query "$1" -o tsv 2>/dev/null || true
}

container_state() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "${1:-$AZ_CONTAINER}" \
    --query 'containers[0].instanceView.currentState.state' -o tsv 2>/dev/null || true
}

container_exit_code() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "${1:-$AZ_CONTAINER}" \
    --query 'containers[0].instanceView.currentState.exitCode' -o tsv
}

# Wait for a container group to terminate (streaming its output), save the
# output under $LOG_DIR, and return its exit status.
wait_container() {
  local name=$1 label=$2 state waited=0
  mkdir -p "$LOG_DIR"
  az container attach -g "$AZ_RESOURCE_GROUP" -n "$name" 2>/dev/null &
  local attach=$!
  trap 'kill $attach 2>/dev/null' EXIT
  while :; do
    state=$(container_state "$name")
    [ "$state" = Terminated ] && break
    if [ "$state" != Running ] && [ $waited -ge 600 ]; then
      kill $attach 2>/dev/null || true
      az container show -g "$AZ_RESOURCE_GROUP" -n "$name" --query 'containers[0].instanceView.events' -o table >&2
      die "container $name is still ${state:-absent} after 10 minutes (events above)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  sleep 3
  kill $attach 2>/dev/null || true
  wait $attach 2>/dev/null || true
  trap - EXIT
  local code log
  code=$(container_exit_code "$name")
  log=$LOG_DIR/$label-$(date -u +%Y%m%dT%H%M%SZ).log
  az container logs -g "$AZ_RESOURCE_GROUP" -n "$name" > "$log"
  log "container $name finished with exit status $code (output in $log)"
  return "$code"
}

# The share's mi/ directory, where the tarball and the executable go.
ensure_share_dir() {
  az storage directory create --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$1" \
    --share-name "$AZ_SHARE" --name mi -o none
}

# A token for Azure SQL as the CLI's signed-in user.
cli_token() {
  az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
}

# The connection settings of the example, for a run from here.
local_env() {
  export MSSQL_HOST; MSSQL_HOST=$(server_fqdn)
  export MSSQL_SERVER_NAME=$AZ_SQL_SERVER MSSQL_DATABASE=$AZ_SQL_DATABASE MSSQL_ENCRYPT=strict
  export MSSQL_ACCESS_TOKEN; MSSQL_ACCESS_TOKEN=$(cli_token)
}

local_exe() {
  need stack
  stack build "$EXE" >&2
  stack exec -- "$EXE" "$@"
}

# ---- Commands --------------------------------------------------------------

cmd_build() {
  need az git
  local key state
  state=$(container_state "$AZ_BUILD_CONTAINER")
  case $state in
    Running|Waiting) die "build container $AZ_BUILD_CONTAINER is $state: wait for it, or stop it" ;;
  esac
  key=$(storage_key)
  ensure_share_dir "$key"
  # The working tree as it is (tracked and untracked files, not ignored
  # ones), so an uncommitted change is what gets built.
  local tarball
  tarball=$(mktemp -t hmssql-src.XXXXXX)
  # COPYFILE_DISABLE: no AppleDouble ._ files from a Mac, which cabal takes
  # for a second .cabal file.
  (cd "$REPO" && git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar czf "$tarball" --null -T -)
  log "uploading the working tree ($(du -h "$tarball" | cut -f1)) to share $AZ_SHARE (mi/src.tar.gz)"
  az storage file upload --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --share-name "$AZ_SHARE" --source "$tarball" --path mi/src.tar.gz --no-progress -o none
  rm -f "$tarball"
  log "building $EXE in ACI ($BUILD_IMAGE, $AZ_BUILD_CPU cpu, $AZ_BUILD_MEMORY GB, $AZ_LOCATION)"
  # The executable is written to the share when the build succeeds; the
  # previous one is removed first, so a failed build leaves none behind.
  az container create -g "$AZ_RESOURCE_GROUP" -n "$AZ_BUILD_CONTAINER" -l "$AZ_LOCATION" \
    --image "$BUILD_IMAGE" --os-type Linux --cpu "$AZ_BUILD_CPU" --memory "$AZ_BUILD_MEMORY" \
    --restart-policy Never \
    --azure-file-volume-account-name "$AZ_STORAGE_ACCOUNT" --azure-file-volume-account-key "$key" \
    --azure-file-volume-share-name "$AZ_SHARE" --azure-file-volume-mount-path "$MOUNT" \
    --environment-variables "HMSSQL_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)" \
    --command-line "bash -euo pipefail -c '
      rm -f $MOUNT/mi/$EXE
      mkdir -p /build && cd /build && tar xzf $MOUNT/mi/src.tar.gz
      GHC_VERSION=$GHC_VERSION bash scripts/linux-toolchain.sh
      export PATH=\$HOME/.ghcup/bin:\$HOME/.cabal/bin:\$PATH
      cabal update >/dev/null
      cabal build -j $EXE:exe:$EXE
      exe=\$(cabal list-bin $EXE)
      strip \$exe && ldd \$exe
      cp \$exe $MOUNT/mi/$EXE
      ls -l $MOUNT/mi/$EXE'" \
    -o none
  local code=0
  wait_container "$AZ_BUILD_CONTAINER" build || code=$?
  # A stopped group still counts against the subscription's ACI core quota
  # (10 StandardCores per region by default), so the build's goes away; its
  # output is in $LOG_DIR.
  az container delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_BUILD_CONTAINER" --yes -o none
  return "$code"
}

cmd_upload() {
  need az
  local file=${1:-}
  [ -f "$file" ] || die "usage: $0 upload FILE (a Linux/amd64 build of $EXE)"
  log "uploading $file to share $AZ_SHARE of $AZ_STORAGE_ACCOUNT as mi/$EXE"
  local key
  key=$(storage_key)
  ensure_share_dir "$key"
  # az takes a --path whose last component has no dot for a directory, so
  # the file goes up under its own name, from a copy named as the run
  # expects.
  local tmp
  tmp=$(mktemp -d)
  cp "$file" "$tmp/$EXE"
  az storage file upload --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --share-name "$AZ_SHARE" --source "$tmp/$EXE" --path mi --no-progress -o none
  rm -rf "$tmp"
  log "uploaded"
}

cmd_identity() {
  need az
  if [ -z "$(identity_query id)" ]; then
    log "creating user-assigned identity $AZ_IDENTITY in $AZ_RESOURCE_GROUP"
    az identity create -g "$AZ_RESOURCE_GROUP" -n "$AZ_IDENTITY" -l "$AZ_LOCATION" -o none
  fi
  printf 'identity     %s\nprincipal id %s\nclient id    %s\n' \
    "$AZ_IDENTITY" "$(identity_query principalId)" "$(identity_query clientId)"
}

cmd_create_user() {
  need az
  local principal
  principal=$(identity_query principalId)
  [ -n "$principal" ] || die "no identity $AZ_IDENTITY: run 'identity' first"
  local_env
  log "creating user [$AZ_IDENTITY] in $AZ_SQL_DATABASE as the Entra admin (token from az)"
  local create="CREATE USER [$AZ_IDENTITY] FROM EXTERNAL PROVIDER"
  # FROM EXTERNAL PROVIDER alone has the server look the name up in Entra,
  # which needs the server's own identity to read the directory; naming the
  # object id skips the lookup.
  if ! local_exe exec "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AZ_IDENTITY') $create;"; then
    log "retrying with the object id"
    local_exe exec "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AZ_IDENTITY') $create WITH OBJECT_ID = '$principal';"
  fi
  local_exe exec "ALTER ROLE db_datareader ADD MEMBER [$AZ_IDENTITY];"
  local_exe query "SELECT name, type_desc, authentication_type_desc FROM sys.database_principals WHERE name = N'$AZ_IDENTITY'"
}

cmd_whoami_local() {
  local_env
  local_exe "$@"
}

cmd_run() {
  need az
  mkdir -p "$LOG_DIR"
  local identity_id client_id fqdn key state
  identity_id=$(identity_query id)
  client_id=$(identity_query clientId)
  [ -n "$identity_id" ] || die "no identity $AZ_IDENTITY: run 'identity' first"
  state=$(container_state)
  case $state in
    Running|Waiting) die "container $AZ_CONTAINER is $state: wait for it ($0 logs) or stop it ($0 stop)" ;;
  esac
  fqdn=$(server_fqdn)
  key=$(storage_key)
  local args=("$@")
  [ ${#args[@]} -eq 0 ] && args=(whoami)
  local quoted
  quoted=$(printf '%q ' "${args[@]}")
  # The share is mounted noexec, so the executable is copied off it first.
  # The CA bundle azure-sql-test.sh uploaded validates the server certificate
  # (the stock image has no certificate store).
  log "running $EXE ${args[*]} in ACI with identity $AZ_IDENTITY ($AZ_LOCATION)"
  az container create -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" -l "$AZ_LOCATION" \
    --image "$AZ_CONTAINER_IMAGE" --os-type Linux --cpu 1 --memory 1 \
    --restart-policy Never \
    --assign-identity "$identity_id" \
    --azure-file-volume-account-name "$AZ_STORAGE_ACCOUNT" --azure-file-volume-account-key "$key" \
    --azure-file-volume-share-name "$AZ_SHARE" --azure-file-volume-mount-path "$MOUNT" \
    --command-line "bash -c 'cp $MOUNT/mi/$EXE /tmp/$EXE && chmod +x /tmp/$EXE && exec /tmp/$EXE $quoted'" \
    --environment-variables \
      "MSSQL_HOST=$fqdn" "MSSQL_SERVER_NAME=$AZ_SQL_SERVER" "MSSQL_DATABASE=$AZ_SQL_DATABASE" \
      "MSSQL_ENCRYPT=strict" "MSSQL_CA_CERT=$MOUNT/certs/ca-certificates.crt" \
      "AZURE_CLIENT_ID=$client_id" "HMSSQL_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)" \
    -o none
  wait_container "$AZ_CONTAINER" run
}

cmd_status() {
  need az
  printf 'identity   %s (principal %s)\n' "$AZ_IDENTITY" "$(identity_query principalId)"
  printf 'container  %s: %s\n' "$AZ_CONTAINER" "$(container_state)"
  printf 'build      %s: %s\n' "$AZ_BUILD_CONTAINER" "$(container_state "$AZ_BUILD_CONTAINER")"
  printf 'share      %s\n' "$(az storage file list --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$(storage_key)" \
    --share-name "$AZ_SHARE" --path mi --query '[].{n:name,s:properties.contentLength}' -o tsv 2>/dev/null | tr '\n\t' ' :' || echo none)"
}

cmd_logs() { need az; az container logs -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER"; }
cmd_stop() {
  need az
  az container stop -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" 2>/dev/null || true
  az container stop -g "$AZ_RESOURCE_GROUP" -n "$AZ_BUILD_CONTAINER" 2>/dev/null || true
}

cmd_cleanup() {
  need az
  log "deleting container group $AZ_CONTAINER and identity $AZ_IDENTITY"
  az container delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" --yes -o none 2>/dev/null || true
  az container delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_BUILD_CONTAINER" --yes -o none 2>/dev/null || true
  az identity delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_IDENTITY" -o none 2>/dev/null || true
}

# ---- Main ------------------------------------------------------------------

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  build) cmd_build ;;
  upload) cmd_upload "$@" ;;
  identity) cmd_identity ;;
  create-user) cmd_create_user ;;
  run) cmd_run "$@" ;;
  whoami-local) cmd_whoami_local "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  stop) cmd_stop ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit 1 ;;
esac
