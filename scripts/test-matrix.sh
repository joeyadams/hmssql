#!/usr/bin/env bash
# Run the test suite across GHC versions, SQL Server versions and connection
# configurations, with nothing but Docker.  See docs/dev/testing.md.
#
# Usage: scripts/test-matrix.sh [OPTIONS] [CONFIG ...] [-- HSPEC-ARGS ...]
#        scripts/test-matrix.sh --down | --purge | --status
#
# The script sets up a bridge network, one container per SQL Server version
# (2017 on Ubuntu 18.04, 2019 on Ubuntu 20.04 and 2022 on Ubuntu 22.04, the
# newest each comes on, and 2025 on Ubuntu 24.04), one image per GHC
# version (Ubuntu 24.04 with GHC and cabal from ghcup,
# scripts/linux-toolchain.sh), and one volume per GHC version holding
# the cabal store and the build, so that a later run rebuilds only what
# changed.  It builds the suite for every GHC version, seeds each server's
# databases and fixtures with one build, and then runs the suite once per
# (GHC version, SQL Server, configuration), several at a time, each run in
# a container of its own with the working tree mounted read-only.  The
# runs of a GHC version alternate between the servers, so that those going
# at once are spread over them.  Every step is skipped when its result
# exists, so a second invocation goes straight to the runs.
#
# A CONFIG is a '+'-separated list of
#   strict | on | req | off | notsup   HMSSQL_TEST_ENCRYPTION
#   p<N>                               HMSSQL_TEST_PACKET_SIZE=N
#   arithabort                         HMSSQL_TEST_SESSION_SETUP=arithabort (a
#                                      one-statement session setup; the default
#                                      is none, as for applications)
#   mars                               HMSSQL_TEST_MARS=1 (every test connection
#                                      is a MARS connection)
#   w<N>                               HMSSQL_TEST_MARS_WINDOW=N (the SMP window
#                                      of every test connection; with mars)
#   slow                               HMSSQL_TEST_SLOW=1 (the slow tests too)
#   default                            none of these
# e.g. "on+p512".  Without CONFIGs, runs the default matrix (-h lists it).
# On SQL Server 2017 and 2019, which have no TDS 8.0, and on 2022, whose
# Linux build has no strict encryption, a configuration without an
# encryption component runs with `on` (TDS 7.4), and one with `strict` is
# skipped.  Every run gets HMSSQL_TEST_SQL_VERSION, so that there the tests
# of what later versions added, and the tests that connect with strict
# encryption themselves, are pending.
#
# Options:
#   --prepare       set up the servers, build the suite for every GHC version
#                   and seed the databases, then stop: nothing of the suite
#                   runs but the seed (the pure Wire.Primitives tests)
#   --ghc LIST      comma-separated GHC versions (default: the tested-with
#                   field of hmssql/hmssql.cabal)
#   --sql LIST      comma-separated SQL Server versions, from 2017, 2019, 2022
#                   and 2025 (default: all four)
#   -j N            builds and suite runs at once (default 3)
#   --cpus N        CPUs per build or run container (default 8), pinned when
#                   the machine has N for each of the -j slots
#   --memory SIZE   memory per build or run container (default 16g)
#   --sql-memory MB memory for each SQL Server, in megabytes (default 6144;
#                   its container may use 2 GB more)
#   -o DIR          write the logs to DIR (default: a new directory under
#                   ~/.config/hmssql-matrix/logs)
#   --rerun DIR     run only what did not pass in DIR, the log directory of
#                   an earlier invocation: of the GHC versions, servers and
#                   configurations given (by default all of them), the
#                   runs whose log there shows a failure or no summary.
#                   Given more than once, a run's log in the last DIR that
#                   has one decides (to go on after a rerun that was cut
#                   short: --rerun FIRST --rerun SECOND)
#   --status        show the containers, images and volumes, and exit
#   --down          stop and remove the servers and the network; keep the
#                   images, the builds and the servers' data
#   --purge         --down, then remove the images, the builds and the
#                   servers' data (the next run starts from scratch)
#
# HMSSQL_TEST_SLOW, HMSSQL_TEST_PROPERTY_SCALE and HMSSQL_TEST_KNOWN_BUGS are
# passed through to every run.  HMSSQL_MATRIX_STATE is the state directory
# (~/.config/hmssql-matrix: the SA password, the servers' certificates and
# the logs); HMSSQL_MATRIX_SQL<VERSION>_IMAGE (e.g. HMSSQL_MATRIX_SQL2019_IMAGE)
# and HMSSQL_MATRIX_UBUNTU_IMAGE pick other images.  Exits non-zero if any run
# failed.
set -euo pipefail

default_matrix=(default+slow on off notsup p512 p32767 arithabort on+p512 off+p512 on+arithabort notsup+p32767 mars+slow mars+on mars+off+p512 mars+arithabort)
all_sql=(2017 2019 2022 2025)
seed_ghc_preferred=9.10.3 # the latest GHC of a Stackage LTS
# Whether SQL Server $1 takes strict connections (TDS 8.0).  2017 and 2019
# have no TDS 8.0, and the Linux build of 2022 refuses it (error 17821;
# docs/dev/protocol-notes.md).
has_strict() { [ "$1" -ge 2025 ]; }
# The encryption a run uses unless its configuration says: strict, the
# suite's default, or on a server without it TDS 7.4 with TLS from
# PRELOGIN; a configuration that asks for strict is skipped there.
base_encryption() { if has_strict "$1"; then echo strict; else echo on; fi; }

STATE=${HMSSQL_MATRIX_STATE:-$HOME/.config/hmssql-matrix}
SQL2017_IMAGE=${HMSSQL_MATRIX_SQL2017_IMAGE:-mcr.microsoft.com/mssql/server:2017-CU31-GDR19-ubuntu-18.04}
SQL2019_IMAGE=${HMSSQL_MATRIX_SQL2019_IMAGE:-mcr.microsoft.com/mssql/server:2019-CU32-GDR12-ubuntu-20.04}
SQL2022_IMAGE=${HMSSQL_MATRIX_SQL2022_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-ubuntu-22.04}
SQL2025_IMAGE=${HMSSQL_MATRIX_SQL2025_IMAGE:-mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04}
UBUNTU_IMAGE=${HMSSQL_MATRIX_UBUNTU_IMAGE:-mcr.microsoft.com/mirror/docker/library/ubuntu:24.04}
NETWORK=hmssql-matrix
LABEL=hmssql-matrix
# The cabal store and the build, in the volume mounted here in every build
# and run container.
CACHE=/cache

prepare_only=0
mode=run
jobs=3
cpus=8
memory=16g
sql_memory_mb=6144
logdir=""
reruns=()
ghcs=""
sqls=""
configs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --prepare) prepare_only=1; shift ;;
    --ghc) ghcs=$2; shift 2 ;;
    --sql) sqls=$2; shift 2 ;;
    -j) jobs=$2; shift 2 ;;
    --cpus) cpus=$2; shift 2 ;;
    --memory) memory=$2; shift 2 ;;
    --sql-memory) sql_memory_mb=$2; shift 2 ;;
    -o) logdir=$2; shift 2 ;;
    --rerun) reruns+=("$2"); shift 2 ;;
    --status|--down|--purge) mode=${1#--}; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,74p' "$0" | sed 's/^# \{0,1\}//'; echo "Default matrix: ${default_matrix[*]}"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) configs+=("$1"); shift ;;
  esac
done
hspec_args=("$@")
[ ${#configs[@]} -gt 0 ] || configs=("${default_matrix[@]}")

cd "$(dirname "$0")/.."
repo=$PWD

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 2; }

# Prints the environment assignments for a config, one per line.
config_env() {
  local IFS=+ part
  for part in $1; do
    case "$part" in
      default) ;;
      strict|on|req|off|notsup) echo "HMSSQL_TEST_ENCRYPTION=$part" ;;
      p[0-9]*) echo "HMSSQL_TEST_PACKET_SIZE=${part#p}" ;;
      arithabort) echo "HMSSQL_TEST_SESSION_SETUP=arithabort" ;;
      mars) echo "HMSSQL_TEST_MARS=1" ;;
      w[0-9]*) echo "HMSSQL_TEST_MARS_WINDOW=${part#w}" ;;
      slow) echo "HMSSQL_TEST_SLOW=1" ;;
      *) echo "unknown config component: $part" >&2; return 1 ;;
    esac
  done
}

# --- Naming -----------------------------------------------------------------

sql_container() { echo "hmssql-matrix-sql$1"; }
sql_volume() { echo "hmssql-matrix-sql$1"; }
sql_image() { local v=SQL$1_IMAGE; echo "${!v}"; }
ghc_image() { echo "hmssql-matrix-ghc:$1"; }
ghc_volume() { echo "hmssql-matrix-ghc-$1"; }

# --- Status and teardown ----------------------------------------------------

cmd_status() {
  echo "containers:"; docker ps -a --filter "label=$LABEL" --format '  {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo "images:"; docker images --filter "label=$LABEL" --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}'
  echo "volumes:"; docker volume ls --filter "label=$LABEL" --format '  {{.Name}}'
  echo "network:"; docker network ls --filter "name=^$NETWORK\$" --format '  {{.Name}}'
  echo "state:     $STATE"
}

cmd_down() {
  local ids
  ids=$(docker ps -aq --filter "label=$LABEL")
  [ -z "$ids" ] || docker rm -f $ids >/dev/null
  docker network inspect "$NETWORK" >/dev/null 2>&1 && docker network rm "$NETWORK" >/dev/null
  log "the servers and the network are gone; the images, the builds and the servers' data remain"
}

cmd_purge() {
  cmd_down
  local ids
  ids=$(docker volume ls -q --filter "label=$LABEL")
  [ -z "$ids" ] || docker volume rm $ids >/dev/null
  ids=$(docker images -q --filter "label=$LABEL")
  [ -z "$ids" ] || docker rmi $ids >/dev/null
  log "the images, the builds and the servers' data are gone too"
}

case "$mode" in
  status) cmd_status; exit 0 ;;
  down) cmd_down; exit 0 ;;
  purge) cmd_purge; exit 0 ;;
esac

# --- The plan ---------------------------------------------------------------

for config in "${configs[@]}"; do config_env "$config" >/dev/null || exit 2; done
if [ -z "$ghcs" ]; then
  # The field's value, on its own line or the following indented ones.
  ghcs=$(awk '/^tested-with:/ { on = 1; sub(/^tested-with:/, ""); print; next } on && /^[ \t]/ { print; next } { on = 0 }' hmssql/hmssql.cabal \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd, - || true)
  [ -n "$ghcs" ] || die "no tested-with field in hmssql/hmssql.cabal"
fi
IFS=, read -ra ghc_list <<<"$ghcs"
[ -n "$sqls" ] || sqls=$(IFS=,; echo "${all_sql[*]}")
IFS=, read -ra sql_list <<<"$sqls"
for sql in "${sql_list[@]}"; do
  case " ${all_sql[*]} " in *" $sql "*) ;; *) die "unknown SQL Server version: $sql (one of ${all_sql[*]})" ;; esac
done
seed_ghc=${ghc_list[0]}
for ghc in "${ghc_list[@]}"; do [ "$ghc" != "$seed_ghc_preferred" ] || seed_ghc=$ghc; done

[ -n "$logdir" ] || logdir=$STATE/logs/$(date +%Y%m%d-%H%M%S)
mkdir -p "$STATE" "$logdir"
chmod 700 "$STATE"

# The CPUs of slot N (a cpuset when the machine has enough, else a quota).
ncpu=$(nproc)
slot_cpu_args() {
  if [ $((jobs * cpus)) -le "$ncpu" ]; then
    echo "--cpuset-cpus=$(($1 * cpus))-$((($1 + 1) * cpus - 1))"
  else
    echo "--cpus=$cpus"
  fi
}

log "GHC ${ghc_list[*]}; SQL Server ${sql_list[*]}; ${#configs[@]} configurations; $jobs at a time, $cpus CPUs and $memory each; seed with GHC $seed_ghc"
log "logs: $logdir"

# --- A pool of slots --------------------------------------------------------

# run_jobs N JOB...: runs each JOB (a command line, eval'd in a subshell with
# $slot set to its slot number) with at most N at a time, and returns the
# number of jobs that failed.
run_jobs() {
  local n=$1; shift
  local -a pids=() slot_job=() status=()
  local job i=0 slot
  for job in "$@"; do
    while :; do
      for ((slot = 0; slot < n; slot++)); do
        if [ -z "${pids[slot]:-}" ]; then break; fi
        if ! kill -0 "${pids[slot]}" 2>/dev/null; then
          wait "${pids[slot]}" && status[slot_job[slot]]=0 || status[slot_job[slot]]=$?
          pids[slot]=""
          break
        fi
      done
      [ "$slot" -lt "$n" ] && break
      sleep 1
    done
    ( slot=$slot; eval "$job" ) & pids[slot]=$!
    slot_job[slot]=$i
    i=$((i + 1))
  done
  for ((slot = 0; slot < n; slot++)); do
    [ -n "${pids[slot]:-}" ] || continue
    wait "${pids[slot]}" && status[slot_job[slot]]=0 || status[slot_job[slot]]=$?
  done
  local failed=0
  for ((i = 0; i < $#; i++)); do [ "${status[i]:-1}" = 0 ] || failed=$((failed + 1)); done
  return "$failed"
}

# On Ctrl-C, stop the containers the jobs started.
cleanup_runs() {
  local ids
  ids=$(docker ps -q --filter "label=$LABEL-role=job")
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true
}
trap 'cleanup_runs; exit 130' INT TERM

# --- The SQL Servers --------------------------------------------------------

sa_password_file=$STATE/sa.password
if [ ! -s "$sa_password_file" ]; then
  random=$(head -c 300 /dev/urandom | tr -dc A-Za-z0-9)
  (umask 077; echo "Hmssql1!${random:0:20}" >"$sa_password_file")
fi
sa_password=$(cat "$sa_password_file")

docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || docker network create --label "$LABEL=1" "$NETWORK" >/dev/null

# sql_query CONTAINER SQLCMD-ARGS...: sqlcmd in the server's container, as
# SA.  The 2019, 2022 and 2025 images have it in mssql-tools18, and the
# 2017 image in mssql-tools.
sql_query() {
  local name=$1; shift
  docker exec -e SQLCMDPASSWORD="$sa_password" "$name" bash -c '
    for s in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
      [ ! -x "$s" ] || exec "$s" -S localhost -U sa -C "$@"
    done
    echo "no sqlcmd in the image" >&2; exit 127' bash "$@"
}

# Waits until the server in container $1 answers a query as SA.
wait_for_sql() {
  local i
  for ((i = 0; i < 90; i++)); do
    if sql_query "$1" -Q "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_sql() {
  local sql=$1 name vol image cert
  name=$(sql_container "$sql"); vol=$(sql_volume "$sql"); image=$(sql_image "$sql"); cert=$STATE/sql$sql.crt
  # The data volume, with the server's configuration and its certificate
  # (for localhost, the name the tests validate against, and for the
  # container's name on the network), written before the server's first
  # start, by the server's own image, which has openssl.
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    log "sql$sql: creating the data volume, the configuration and the certificate"
    docker volume create --label "$LABEL=1" "$vol" >/dev/null
    if ! docker run --rm --user root --entrypoint bash -v "$vol:/var/opt/mssql" "$image" -c '
      set -e
      mkdir -p /var/opt/mssql/certs
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:'"$name"'" \
        -keyout /var/opt/mssql/certs/server.key -out /var/opt/mssql/certs/server.crt 2>/dev/null
      cat >/var/opt/mssql/mssql.conf <<EOF
[network]
tlscert = /var/opt/mssql/certs/server.crt
tlskey = /var/opt/mssql/certs/server.key
forceencryption = 0

[memory]
memorylimitmb = '"$sql_memory_mb"'
EOF
      chown -R 10001:10001 /var/opt/mssql
      chmod 600 /var/opt/mssql/certs/server.key
      cat /var/opt/mssql/certs/server.crt' >"$cert"; then
      rm -f "$cert"
      docker volume rm "$vol" >/dev/null
      die "sql$sql: setting up the data volume failed"
    fi
  fi
  [ -s "$cert" ] || die "sql$sql: $cert is missing; --purge and start again"
  if ! docker container inspect "$name" >/dev/null 2>&1; then
    log "sql$sql: creating the container from $image"
    docker run -d --name "$name" --label "$LABEL=1" --label "$LABEL-role=sql" \
      --network "$NETWORK" --memory "$((sql_memory_mb + 2048))m" \
      -v "$vol:/var/opt/mssql" \
      -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$sa_password" -e MSSQL_PID=Developer \
      "$image" >/dev/null
  elif [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
    log "sql$sql: starting the container"
    docker start "$name" >/dev/null
  fi
  if ! wait_for_sql "$name"; then
    docker logs --tail 30 "$name" >&2 || true
    die "sql$sql: the server did not come up (docker logs $name)"
  fi
  local version
  version=$(sql_query "$name" -h -1 -W -Q "SET NOCOUNT ON; SELECT LEFT(@@VERSION, CHARINDEX(' (', @@VERSION) - 1)" | head -1)
  log "sql$sql: ready, $version"
}

for sql in "${sql_list[@]}"; do start_sql "$sql"; done

# --- The builds -------------------------------------------------------------

# A container of GHC $2's image in slot $1, with the cache volume and the
# working tree (read-only); the rest of the arguments follow the image.
ghc_container() {
  local slot=$1 ghc=$2; shift 2
  # shellcheck disable=SC2046 # the cpu argument is one word
  docker run --rm --label "$LABEL=1" --label "$LABEL-role=job" --network "$NETWORK" \
    $(slot_cpu_args "$slot") --memory "$memory" \
    -v "$(ghc_volume "$ghc"):$CACHE" -v "$repo:/src:ro" -w /src \
    "$@"
}

prepare_ghc() {
  local ghc=$1 image vol plog
  image=$(ghc_image "$ghc"); vol=$(ghc_volume "$ghc"); plog=$logdir/prepare-$ghc.log
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "ghc $ghc: building the toolchain image"
    docker build -q -t "$image" --label "$LABEL=1" \
      --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --build-arg GHC_VERSION="$ghc" \
      -f - scripts >"$plog" 2>&1 <<'EOF' || { tail -20 "$plog" >&2; log "ghc $ghc: the image build failed (see $plog)"; return 1; }
ARG UBUNTU_IMAGE
FROM ${UBUNTU_IMAGE}
ARG GHC_VERSION
COPY linux-toolchain.sh /tmp/linux-toolchain.sh
RUN GHC_VERSION=${GHC_VERSION} bash /tmp/linux-toolchain.sh && rm /tmp/linux-toolchain.sh
ENV PATH=/root/.ghcup/bin:${PATH} CABAL_DIR=/cache/cabal
EOF
  fi
  docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create --label "$LABEL=1" "$vol" >/dev/null
  log "ghc $ghc: building the test suite"
  # The package index once per volume; the dependencies into the store and
  # the suite into the build directory, both in the volume; then the
  # executable where the runs find it without cabal.  Four packages at a
  # time, each with four GHC threads, for the slot's CPUs.
  ghc_container "$slot" "$ghc" "$image" bash -c '
    set -e
    # cabal update, outside the project: in it, it would write to /src.
    [ -d "$CABAL_DIR/packages/hackage.haskell.org" ] || (cd '"$CACHE"' && cabal update)
    opts=(--builddir='"$CACHE"'/dist --enable-tests "--ghc-options=-j4 +RTS -A64m -RTS")
    cabal build -j4 "${opts[@]}" hmssql-tests:test:hmssql-tests
    # The caller-side size check catches large unfoldings even when the library
    # and its tests still compile and behave correctly on this GHC version.
    scripts/code-size.sh --quick --check --cabal-builddir='"$CACHE"'/dist '"$CACHE"'/code-size
    mkdir -p '"$CACHE"'/bin
    cp "$(cabal list-bin "${opts[@]}" hmssql-tests:test:hmssql-tests)" '"$CACHE"'/bin/hmssql-tests
    ghc --version' >"$plog" 2>&1 \
    || { tail -30 "$plog" >&2; log "ghc $ghc: the build failed (see $plog)"; return 1; }
  log "ghc $ghc: built ($(tail -1 "$plog"))"
}

prepare_jobs=()
for ghc in "${ghc_list[@]}"; do prepare_jobs+=("prepare_ghc $ghc"); done
run_jobs "$jobs" "${prepare_jobs[@]}" || die "$? GHC versions failed to build"

# --- Running the suite ------------------------------------------------------

# run_suite SLOT GHC SQL LOG [ENV=VALUE ...] [-- HSPEC-ARGS ...]: one run of
# GHC's build against the SQL Server, its output in LOG.
run_suite() {
  local slot=$1 ghc=$2 sql=$3 rlog=$4; shift 4
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=(-e "$1"); shift; done
  [ $# -eq 0 ] || shift
  ghc_container "$slot" "$ghc" \
    -v "$STATE/sql$sql.crt:/certs/sql$sql.crt:ro" \
    -e HMSSQL_TEST_HOST="$(sql_container "$sql")" -e HMSSQL_TEST_PASSWORD="$sa_password" \
    -e HMSSQL_TEST_CERT="/certs/sql$sql.crt" -e HMSSQL_TEST_REQUIRE_SERVER=1 \
    -e HMSSQL_TEST_ENCRYPTION="$(base_encryption "$sql")" -e HMSSQL_TEST_SQL_VERSION="$sql" \
    ${HMSSQL_TEST_SLOW:+-e HMSSQL_TEST_SLOW="$HMSSQL_TEST_SLOW"} \
    ${HMSSQL_TEST_PROPERTY_SCALE:+-e HMSSQL_TEST_PROPERTY_SCALE="$HMSSQL_TEST_PROPERTY_SCALE"} \
    ${HMSSQL_TEST_KNOWN_BUGS:+-e HMSSQL_TEST_KNOWN_BUGS="$HMSSQL_TEST_KNOWN_BUGS"} \
    ${envs[@]+"${envs[@]}"} \
    "$(ghc_image "$ghc")" "$CACHE/bin/hmssql-tests" "$@" >"$rlog" 2>&1
}

# The summary line of a log, or nothing.
log_summary() { grep -E '^[0-9]+ examples?, ' "$1" | tail -1 || true; }
log_passed() { grep -qE '^[0-9]+ examples?, 0 failures' "$1"; }

# A run that matches only pure tests, so that the pre-test hook creates the
# databases and the fixtures alone, before the parallel runs race for them.
seed_sql() {
  local sql=$1 slog
  slog=$logdir/seed-sql$sql.log
  log "sql$sql: seeding the databases with the GHC $seed_ghc build"
  run_suite "$slot" "$seed_ghc" "$sql" "$slog" -- --match Wire.Primitives || true
  if ! log_passed "$slog"; then
    tail -20 "$slog" >&2
    log "sql$sql: the seed failed (see $slog)"
    return 1
  fi
  log "sql$sql: seeded ($(log_summary "$slog"))"
}

seed_jobs=()
for sql in "${sql_list[@]}"; do seed_jobs+=("seed_sql $sql"); done
run_jobs "$jobs" "${seed_jobs[@]}" || die "$? servers failed to seed"

if [ "$prepare_only" = 1 ]; then
  log "prepared: the servers are up and seeded, and the suite is built for every GHC version; run again without --prepare"
  exit 0
fi

run_config() {
  local ghc=$1 sql=$2 config=$3 rlog started
  rlog=$logdir/ghc$ghc-sql$sql-$config.log
  if ! has_strict "$sql" && config_env "$config" | grep -q '^HMSSQL_TEST_ENCRYPTION=strict$'; then
    log "ghc $ghc sql$sql $config: skipped, SQL Server $sql on Linux has no strict encryption"
    echo "skipped: SQL Server $sql on Linux has no strict encryption" >"$rlog"
    return 0
  fi
  started=$SECONDS
  log "ghc $ghc sql$sql $config: started"
  local rc=0
  # shellcheck disable=SC2046 # one assignment per line, no spaces
  run_suite "$slot" "$ghc" "$sql" "$rlog" $(config_env "$config") -- ${hspec_args[@]+"${hspec_args[@]}"} || rc=$?
  local summary
  summary=$(log_summary "$rlog")
  # Without a summary the test process did not end by itself: 137 is a
  # kill, which is Docker's for a container over its memory limit ('docker
  # events --filter event=oom' says so) or somebody's 'docker kill'.
  [ -n "$summary" ] || echo "no summary: the test process ended with status $rc" >>"$rlog"
  log "ghc $ghc sql$sql $config: ${summary:-no summary (exit status $rc)} ($(( (SECONDS - started) / 60 ))m$(( (SECONDS - started) % 60 ))s)"
  log_passed "$rlog"
}

# Whether to run this one: always, or with --rerun only if its newest log
# (in the last of the directories that has one) shows neither a pass nor a
# skip.
wanted() {
  [ ${#reruns[@]} -gt 0 ] || return 0
  local dir old=""
  for dir in "${reruns[@]}"; do
    [ ! -f "$dir/ghc$1-sql$2-$3.log" ] || old=$dir/ghc$1-sql$2-$3.log
  done
  [ -n "$old" ] && ! log_passed "$old" && ! grep -q '^skipped: ' "$old"
}

# The runs of a GHC version, alternating between the servers: three runs
# at once on one server are more than it serves without stalls
# (docs/dev/protocol-notes.md, "The server under load").
run_jobs_list=()
ran=()
for ghc in "${ghc_list[@]}"; do
  for config in "${configs[@]}"; do
    for sql in "${sql_list[@]}"; do
      wanted "$ghc" "$sql" "$config" || continue
      run_jobs_list+=("run_config $ghc $sql $config")
      ran+=("$ghc $sql $config")
    done
  done
done
[ ${#run_jobs_list[@]} -gt 0 ] || { log "nothing to run: every run in the --rerun directories passed or was skipped"; exit 0; }
log "running ${#run_jobs_list[@]} suite runs"
run_jobs "$jobs" "${run_jobs_list[@]}" || true

status=0
{
  printf '\n%-8s %-5s %-18s %s\n' GHC SQL CONFIG RESULT
  for one in "${ran[@]}"; do
    read -r ghc sql config <<<"$one"
    rlog=$logdir/ghc$ghc-sql$sql-$config.log
    summary=$(log_summary "$rlog")
    [ -n "$summary" ] || summary=$(grep '^skipped: ' "$rlog" 2>/dev/null || true)
    [ -n "$summary" ] || summary="($(grep -m1 '^no summary: ' "$rlog" 2>/dev/null || echo 'no summary: crashed?'); see $rlog)"
    printf '%-8s %-5s %-18s %s\n' "$ghc" "$sql" "$config" "$summary"
    if ! log_passed "$rlog" && ! grep -q '^skipped: ' "$rlog"; then
      status=1
      # hspec's failure list: "  Foo.hs:12:3: " then "  1) Foo.Bar, does x"
      grep -E '^  [0-9]+\) ' "$rlog" | sed 's/^/    /' || true
    fi
  done
  echo "logs: $logdir"
} | tee "$logdir/summary.txt"
exit $status
