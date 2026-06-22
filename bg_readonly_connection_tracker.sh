#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage:
  ./bg_readonly_connection_tracker.sh

Environment variables:
  DB_CLUSTER_IDENTIFIER  RDS DB cluster identifier used for endpoint lookup.
                         Default: apg-maintenance-workshop-ten-tables-cluster2-cluster
  CLUSTER_ENDPOINT       Optional cluster endpoint override. If set, AWS lookup is skipped.
  PGPORT                 PostgreSQL port. Default: 5432
  PGDATABASE             Database to connect to. Default: postgres
  PGUSER                 User to connect as. Default: adminuser
  CONNECT_TIMEOUT        psql connect_timeout seconds. Default: 2
  INTERVAL_SECONDS       Sleep interval between attempts. Default: 1
  LOG_FILE               Log file path. Default: ./bg_readonly_connection_tracker_<UTC timestamp>.log
  STOP_AFTER_SECONDS     Optional total runtime. Default: empty, run until Ctrl+C

Authentication:
  Use ~/.pgpass, PGPASSWORD, or another standard libpq authentication method.

Example:
  ./bg_readonly_connection_tracker.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -gt 1 ]]; then
  echo "ERROR: too many arguments." >&2
  usage >&2
  exit 2
fi

DB_CLUSTER_IDENTIFIER="${DB_CLUSTER_IDENTIFIER:-apg-maintenance-workshop-ten-tables-cluster2-cluster}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
PGUSER="${PGUSER:-adminuser}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
STOP_AFTER_SECONDS="${STOP_AFTER_SECONDS:-}"
LOG_FILE="${LOG_FILE:-./bg_readonly_connection_tracker_$(date -u +%Y%m%d_%H%M%S).log}"

resolve_target_host() {
  local positional_endpoint="${1:-}"
  local endpoint=""

  if [[ -n "$positional_endpoint" ]]; then
    printf '%s\n' "$positional_endpoint"
    return 0
  fi

  if [[ -n "${CLUSTER_ENDPOINT:-}" ]]; then
    printf '%s\n' "$CLUSTER_ENDPOINT"
    return 0
  fi

  if command -v aws >/dev/null 2>&1; then
    endpoint="$(
      aws rds describe-db-clusters \
        --db-cluster-identifier "$DB_CLUSTER_IDENTIFIER" \
        --query 'DBClusters[0].Endpoint' \
        --output text 2>/dev/null || true
    )"
    if [[ -n "$endpoint" && "$endpoint" != "None" ]]; then
      printf '%s\n' "$endpoint"
      return 0
    fi
  fi

  echo "ERROR: could not resolve cluster endpoint." >&2
  echo "Set CLUSTER_ENDPOINT or DB_CLUSTER_IDENTIFIER, or make sure AWS CLI can describe the RDS cluster." >&2
  exit 2
}

TARGET_HOST="$(resolve_target_host "${1:-}")"

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql command is required but was not found in PATH." >&2
  exit 2
fi

QUERY="select now(), inet_server_addr(), aurora_version();"
START_EPOCH="$(date +%s)"

ok_count=0
fail_count=0
last_state="START"
failure_start_epoch=""
failure_start_at=""
failure_streak=0
first_fail_at=""
last_fail_at=""
first_recovered_at=""
last_writer_ip=""
last_aurora_version=""
last_outage_seconds=""

exec > >(tee -a "$LOG_FILE") 2>&1

line() {
  printf '%s\n' "--------------------------------------------------------------------------------"
}

epoch_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

print_summary() {
  local ended_at
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  line
  echo "SUMMARY"
  line
  echo "ended_at_utc          : $ended_at"
  echo "successful_attempts  : $ok_count"
  echo "failed_attempts      : $fail_count"
  echo "first_failure_utc    : ${first_fail_at:-none}"
  echo "last_failure_utc     : ${last_fail_at:-none}"
  echo "first_recovered_utc  : ${first_recovered_at:-none}"
  echo "observed_outage_sec  : ${last_outage_seconds:-none}"
  echo "last_writer_ip       : ${last_writer_ip:-unknown}"
  echo "last_aurora_version  : ${last_aurora_version:-unknown}"
  echo "log_file             : $LOG_FILE"
  echo "note                 : outage duration is measured from first failed attempt to first recovered attempt."
  if [[ -z "$last_outage_seconds" && -n "$first_fail_at" ]]; then
    echo "status               : stopped while connection was still failing or before recovery was observed."
  fi
}

trap 'print_summary; exit 0' INT TERM

line
echo "Blue/Green read-only connection tracker"
line
echo "started_at_utc       : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "db_cluster_identifier: $DB_CLUSTER_IDENTIFIER"
echo "target_host          : $TARGET_HOST"
echo "database             : $PGDATABASE"
echo "user                 : $PGUSER"
echo "port                 : $PGPORT"
echo "connect_timeout_sec  : $CONNECT_TIMEOUT"
echo "interval_sec         : $INTERVAL_SECONDS"
echo "log_file             : $LOG_FILE"
line
echo "Each attempt prints: timestamp | state | readable details"
line

while true; do
  now_epoch="$(date +%s)"
  if [[ -n "$STOP_AFTER_SECONDS" ]] && (( now_epoch - START_EPOCH >= STOP_AFTER_SECONDS )); then
    print_summary
    exit 0
  fi

  attempt_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  attempt_start_ms="$(epoch_ms)"
  output="$(
    psql \
      "host=$TARGET_HOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER connect_timeout=$CONNECT_TIMEOUT" \
      -X -A -t -v ON_ERROR_STOP=1 \
      -c "$QUERY" 2>&1
  )"
  rc=$?
  attempt_end_ms="$(epoch_ms)"
  latency_ms=$((attempt_end_ms - attempt_start_ms))

  if [[ "$rc" -eq 0 ]]; then
    ok_count=$((ok_count + 1))
    IFS='|' read -r db_time writer_ip aurora_version <<< "$output"
    last_writer_ip="$writer_ip"
    last_aurora_version="$aurora_version"

    if [[ "$last_state" == "FAIL" ]]; then
      recovered_at="$attempt_at"
      first_recovered_at="${first_recovered_at:-$recovered_at}"
      outage_seconds=$((now_epoch - failure_start_epoch))
      last_outage_seconds="$outage_seconds"
      echo "$attempt_at | RECOVERED | connection restored; outage_seconds=${outage_seconds}; failed_attempts=${failure_streak}; first_failure_utc=${failure_start_at}"
      failure_streak=0
      failure_start_epoch=""
      failure_start_at=""
    elif [[ "$last_state" == "START" ]]; then
      echo "$attempt_at | CONNECTED | initial connection succeeded"
    fi

    echo "$attempt_at | OK | writer_ip=${writer_ip}; aurora_version=${aurora_version}; latency_ms=${latency_ms}; db_time=${db_time}"
    last_state="OK"
  else
    fail_count=$((fail_count + 1))
    failure_streak=$((failure_streak + 1))
    first_fail_at="${first_fail_at:-$attempt_at}"
    last_fail_at="$attempt_at"

    if [[ "$last_state" != "FAIL" ]]; then
      failure_start_epoch="$now_epoch"
      failure_start_at="$attempt_at"
      echo "$attempt_at | OUTAGE_STARTED | first failed attempt after state=${last_state}"
    fi

    clean_output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
    echo "$attempt_at | FAIL | failed_attempt=${failure_streak}; rc=${rc}; latency_ms=${latency_ms}; error=${clean_output}"
    last_state="FAIL"
  fi

  sleep "$INTERVAL_SECONDS"
done
