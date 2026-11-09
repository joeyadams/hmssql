#!/usr/bin/env bash
#
# Compare Azure SQL's connection policies from inside Azure: run
# hmssql-bench-azure (connect time, round trips, downloads and
# uploads, with the endpoint each connection reached) in a container in
# Azure Container Instances (ACI), against the database of
# scripts/azure-sql-test.sh, under the Proxy policy (every packet through the
# gateway on port 1433) and the Redirect policy (the login redirected to the
# node hosting the database, on a port in 11000-11999, which connect
# follows).
#
# The benchmark is compiled for linux/amd64 with Docker, by the repository's
# Dockerfile (its build stage), and put on the Azure Files share of
# azure-sql-test.sh, which the container mounts; the CA bundle azure-sql-test.sh
# uploaded there validates the server's certificate.
#
# Commands:
#
#   build              compile the benchmark with Docker (linux/amd64) into
#                      $STATE_DIR/bench/
#   upload             put it on the share (bench/)
#   policy [NAME]      show the server's connection policy, or set it
#                      (Default, Proxy or Redirect)
#   run [LABEL]        run the benchmark once in ACI under the current policy
#                      (LABEL defaults to it), stream its output, save the log;
#                      BENCH_* variables set here are passed through
#   compare [ROUNDS]   run under Proxy, then Default (which redirects from
#                      inside Azure), alternating, ROUNDS times
#                      each (2 by default), then put the policy back as it
#                      was, and tabulate the RESULT lines of the runs
#   table LOG...       tabulate the RESULT lines of saved logs
#   cleanup            delete the benchmark's container group
#
# Configuration: the variables of azure-sql-test.sh (AZ_SUBSCRIPTION,
# AZ_PREFIX, ...).  The container has 1 vCPU and 1 GB.
#
set -euo pipefail

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
AZ_SQL_ADMIN=${AZ_SQL_ADMIN:-${AZ_PREFIX}_admin}
AZ_SQL_DATABASE=${AZ_SQL_DATABASE:-hmssql_test}
AZ_STORAGE_ACCOUNT=${AZ_STORAGE_ACCOUNT:-$(printf '%s' "${AZ_PREFIX}hmssqltest" | tr -cd 'a-z0-9' | cut -c1-24)}
AZ_SHARE=${AZ_SHARE:-hmssql}
AZ_CONTAINER=${AZ_CONTAINER:-hmssql-bench}
AZ_CONTAINER_IMAGE=${AZ_CONTAINER_IMAGE:-mcr.microsoft.com/mirror/docker/library/ubuntu:24.04}
STATE_DIR=${HMSSQL_AZURE_STATE_DIR:-$HOME/.config/hmssql-azure}
# How long a policy change is given before a run relies on it.
POLICY_SETTLE=${POLICY_SETTLE:-60}

MOUNT=/mnt/hmssql
EXE=hmssql-bench-azure
LOG_DIR=$STATE_DIR/logs
PASSWORD_FILE=$STATE_DIR/$AZ_SQL_SERVER.password
REPO=$(cd "$(dirname "$0")/.." && pwd)

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'azure-bench: %s\n' "$*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed"; done; }
az() { command az "$@" --subscription "$AZ_SUBSCRIPTION" --only-show-errors; }

server_fqdn() {
  az sql server show -g "$AZ_RESOURCE_GROUP" -n "$AZ_SQL_SERVER" --query fullyQualifiedDomainName -o tsv
}

storage_key() {
  az storage account keys list -g "$AZ_RESOURCE_GROUP" -n "$AZ_STORAGE_ACCOUNT" --query '[0].value' -o tsv
}

container_state() {
  az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" \
    --query 'containers[0].instanceView.currentState.state' -o tsv 2>/dev/null || true
}

current_policy() {
  az sql server conn-policy show -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" --query connectionType -o tsv
}

set_policy() {
  log "connection policy $1"
  az sql server conn-policy update -g "$AZ_RESOURCE_GROUP" -s "$AZ_SQL_SERVER" --connection-type "$1" -o none
}

# BENCH_* variables set here, as KEY=VALUE words.
passthrough_env() {
  local v
  for v in $(compgen -e | grep '^BENCH_' | grep -v '^BENCH_LABEL$' || true); do
    printf '%s=%s\n' "$v" "${!v}"
  done
}

cmd_build() {
  need docker
  mkdir -p "$STATE_DIR/bench"
  log "building $EXE for linux/amd64 with the Dockerfile's build stage"
  # Without the Dockerfile's syntax line, which makes BuildKit fetch its
  # frontend from Docker Hub (a pull that hangs where Hub is unreachable);
  # the built-in frontend reads this Dockerfile as well.
  sed '/^# syntax=/d' "$REPO/Dockerfile" \
    | docker build --platform linux/amd64 --target build --build-arg EXE=$EXE -t $EXE-build -f - "$REPO"
  local id
  id=$(docker create --platform linux/amd64 $EXE-build)
  docker cp "$id:/out/$EXE" "$STATE_DIR/bench/$EXE"
  docker rm "$id" >/dev/null
  log "built $STATE_DIR/bench/$EXE ($(du -h "$STATE_DIR/bench/$EXE" | cut -f1))"
}

cmd_upload() {
  need az
  [ -f "$STATE_DIR/bench/$EXE" ] || die "no $STATE_DIR/bench/$EXE: run 'build' first"
  local key
  key=$(storage_key)
  az storage directory create --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --share-name "$AZ_SHARE" --name bench -o none
  log "uploading $EXE to share $AZ_SHARE (bench/)"
  az storage file upload --account-name "$AZ_STORAGE_ACCOUNT" --account-key "$key" \
    --share-name "$AZ_SHARE" --source "$STATE_DIR/bench/$EXE" --path bench --no-progress -o none
}

cmd_policy() {
  need az
  if [ $# -eq 0 ]; then current_policy; else set_policy "$1"; fi
}

cmd_run() {
  need az
  mkdir -p "$LOG_DIR"
  local password label fqdn key state
  password=${AZ_SQL_PASSWORD:-$(cat "$PASSWORD_FILE" 2>/dev/null)} || true
  [ -n "$password" ] || die "no SQL admin password (expected $PASSWORD_FILE, or set AZ_SQL_PASSWORD)"
  label=${1:-$(current_policy)}
  state=$(container_state)
  case $state in
    Running|Waiting) die "container $AZ_CONTAINER is $state: wait for it, or 'az container stop'" ;;
  esac
  fqdn=$(server_fqdn)
  key=$(storage_key)
  local envs=(
    "HMSSQL_TEST_HOST=$fqdn" "HMSSQL_TEST_PORT=1433" "HMSSQL_TEST_USER=$AZ_SQL_ADMIN"
    "HMSSQL_TEST_DATABASE=$AZ_SQL_DATABASE" "HMSSQL_TEST_SERVER_NAME=$AZ_SQL_SERVER"
    "HMSSQL_TEST_TLS_HOSTNAME=" "BENCH_LABEL=$label"
    "SYSTEM_CERTIFICATE_PATH=$MOUNT/certs" "LANG=C.UTF-8"
  )
  local kv
  while IFS= read -r kv; do [ -n "$kv" ] && envs+=("$kv"); done < <(passthrough_env)
  log "running $EXE in ACI ($label, 1 cpu, $AZ_LOCATION)"
  # A new container every run: the benchmark measures its own cold start.
  az container create -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" -l "$AZ_LOCATION" \
    --image "$AZ_CONTAINER_IMAGE" --os-type Linux --cpu 1 --memory 1 \
    --restart-policy Never \
    --azure-file-volume-account-name "$AZ_STORAGE_ACCOUNT" --azure-file-volume-account-key "$key" \
    --azure-file-volume-share-name "$AZ_SHARE" --azure-file-volume-mount-path "$MOUNT" \
    --command-line "bash -c 'cp $MOUNT/bench/$EXE /tmp/$EXE && chmod +x /tmp/$EXE && exec /tmp/$EXE'" \
    --environment-variables "${envs[@]}" "BENCH_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)" \
    --secure-environment-variables "HMSSQL_TEST_PASSWORD=$password" \
    -o none
  local waited=0
  while :; do
    state=$(container_state)
    [ "$state" = Terminated ] && break
    [ $waited -ge 1800 ] && die "container $AZ_CONTAINER is still $state after 30 minutes"
    sleep 10
    waited=$((waited + 10))
  done
  local out code
  out=$LOG_DIR/bench-$label-$(date -u +%Y%m%dT%H%M%SZ).log
  az container logs -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" > "$out"
  code=$(az container show -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" --query 'containers[0].instanceView.currentState.exitCode' -o tsv)
  grep -v '^RESULT' "$out" >&2 || true
  log "exit status $code; log saved to $out"
  echo "$out"
  return "$code"
}

cmd_compare() {
  need az
  local rounds=${1:-2} original logs=() i p
  original=$(current_policy)
  log "comparing Proxy and Default, $rounds rounds each (policy now $original)"
  trap 'set_policy "$original"' EXIT
  for ((i = 1; i <= rounds; i++)); do
    for p in Proxy Default; do
      set_policy "$p"
      log "waiting ${POLICY_SETTLE}s for the policy to take effect"
      sleep "$POLICY_SETTLE"
      logs+=("$(cmd_run "$p")")
    done
  done
  set_policy "$original"
  trap - EXIT
  cmd_table "${logs[@]}"
}

# The median of each measurement's medians across runs, by label.
cmd_table() {
  [ $# -gt 0 ] || die "usage: $0 table LOG..."
  grep -h '^RESULT' "$@" | awk -F'\t' '
    { key = $3 "\t" $4; lab[$2] = 1; if (!(key in seen)) { seen[key] = 1; order[++n] = key }
      v[key, $2] = v[key, $2] (v[key, $2] == "" ? "" : " ") sprintf("%.2f", $7) }
    END {
      printf "%-8s %-28s", "enc", "measurement (p50 ms per run)"
      for (l in lab) printf "  %-24s", l; printf "\n"
      for (i = 1; i <= n; i++) {
        split(order[i], k, "\t"); printf "%-8s %-28s", k[1], k[2]
        for (l in lab) printf "  %-24s", v[order[i], l]; printf "\n"
      }
    }'
}

cmd_cleanup() {
  need az
  az container delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_CONTAINER" --yes -o none 2>/dev/null || true
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case ${1:-} in
  build) shift; cmd_build "$@" ;;
  upload) shift; cmd_upload "$@" ;;
  policy) shift; cmd_policy "$@" ;;
  run) shift; cmd_run "$@" ;;
  compare) shift; cmd_compare "$@" ;;
  table) shift; cmd_table "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
