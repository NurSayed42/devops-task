#!/usr/bin/env bash
#
# system_health.sh - point-in-time health check for a Linux server.
#
# Collects CPU, memory, per-filesystem disk usage, load average and the top 5
# processes by memory; compares them with warning/critical thresholds; prints
# a report (text or JSON) and appends it to a rotating log file. Optionally
# notifies a Slack/Discord webhook when the overall status changes.
#
# Exit codes (Nagios/Icinga compatible, so monitoring tools can consume it):
#   0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (bad arguments or the check itself failed)

set -euo pipefail
set -E # let the ERR trap below fire inside functions too

readonly SCRIPT_NAME=${0##*/}
readonly EXIT_OK=0 EXIT_WARNING=1 EXIT_CRITICAL=2 EXIT_UNKNOWN=3

# An unexpected failure must not be mistaken for WARNING (1) or CRITICAL (2).
trap 'echo "$SCRIPT_NAME: unexpected error at line $LINENO" >&2; exit $EXIT_UNKNOWN' ERR

# ---- defaults (all overridable by flags) ----
CPU_WARN=90 CPU_CRIT=97
MEM_WARN=85 MEM_CRIT=95
DISK_WARN=80 DISK_CRIT=90
CPU_SAMPLE_SECONDS=1
OUTPUT_JSON=false
LOG_FILE=${HEALTH_LOG_FILE:-health_log.txt}
LOG_MAX_KB=1024
LOG_KEEP=5
WEBHOOK_URL=${HEALTH_WEBHOOK_URL:-}

# Pseudo/ephemeral filesystems: not "disks" and some are always 100% full.
readonly DF_EXCLUDES=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x ramfs)

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Point-in-time server health check: CPU, memory, disk (every mounted
filesystem), load average and the top 5 processes by memory.

Thresholds (percent; a value strictly above the threshold triggers it):
  --cpu N          CPU usage warning threshold        (default $CPU_WARN)
  --cpu-crit N     CPU usage critical threshold       (default $CPU_CRIT)
  --mem N          memory usage warning threshold     (default $MEM_WARN)
  --mem-crit N     memory usage critical threshold    (default $MEM_CRIT)
  --disk N         per-filesystem warning threshold   (default $DISK_WARN)
  --disk-crit N    per-filesystem critical threshold  (default $DISK_CRIT)

Output and logging:
  --json             print and log the report as one JSON object per run
  --log-file PATH    log file to append to   (default \$HEALTH_LOG_FILE or ./health_log.txt)
  --max-log-kb N     rotate the log once it reaches N KiB  (default $LOG_MAX_KB)
  --keep N           rotated logs to keep: PATH.1 .. PATH.N  (default $LOG_KEEP)
  --cpu-sample N     seconds to sample CPU usage over      (default $CPU_SAMPLE_SECONDS)
  -h, --help         show this help

Environment:
  HEALTH_WEBHOOK_URL  Slack or Discord incoming-webhook URL. When set, a message
                      is sent whenever the overall status changes (incl. recovery).
  HEALTH_LOG_FILE     default for --log-file.

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (usage error or check failure).
Example: $SCRIPT_NAME --disk 80 --cpu 90 --mem 85 --json
EOF
}

die() {
  echo "$SCRIPT_NAME: $*" >&2
  exit "$EXIT_UNKNOWN"
}
warn() { echo "$SCRIPT_NAME: $*" >&2; }

# ---- argument parsing ----

require_int() { # require_int <flag> <value> <min> <max>
  if [[ ! $2 =~ ^[0-9]+$ ]] || (($2 < $3 || $2 > $4)); then
    die "$1 needs an integer between $3 and $4, got '$2'"
  fi
}

parse_args() {
  while (($# > 0)); do
    case $1 in
    -h | --help)
      usage
      exit "$EXIT_OK"
      ;;
    --json) OUTPUT_JSON=true ;;
    --cpu | --cpu-crit | --mem | --mem-crit | --disk | --disk-crit | --log-file | --max-log-kb | --keep | --cpu-sample)
      (($# >= 2)) || die "$1 requires a value"
      case $1 in
      --cpu) CPU_WARN=$2 ;;
      --cpu-crit) CPU_CRIT=$2 ;;
      --mem) MEM_WARN=$2 ;;
      --mem-crit) MEM_CRIT=$2 ;;
      --disk) DISK_WARN=$2 ;;
      --disk-crit) DISK_CRIT=$2 ;;
      --log-file) LOG_FILE=$2 ;;
      --max-log-kb) LOG_MAX_KB=$2 ;;
      --keep) LOG_KEEP=$2 ;;
      --cpu-sample) CPU_SAMPLE_SECONDS=$2 ;;
      esac
      shift
      ;;
    *) die "unknown option '$1' (see --help)" ;;
    esac
    shift
  done

  local pair
  for pair in "--cpu:$CPU_WARN" "--cpu-crit:$CPU_CRIT" "--mem:$MEM_WARN" "--mem-crit:$MEM_CRIT" \
    "--disk:$DISK_WARN" "--disk-crit:$DISK_CRIT"; do
    require_int "${pair%%:*}" "${pair#*:}" 0 100
  done
  ((CPU_WARN <= CPU_CRIT)) || die "--cpu ($CPU_WARN) must not exceed --cpu-crit ($CPU_CRIT)"
  ((MEM_WARN <= MEM_CRIT)) || die "--mem ($MEM_WARN) must not exceed --mem-crit ($MEM_CRIT)"
  ((DISK_WARN <= DISK_CRIT)) || die "--disk ($DISK_WARN) must not exceed --disk-crit ($DISK_CRIT)"
  require_int --max-log-kb "$LOG_MAX_KB" 1 1048576
  require_int --keep "$LOG_KEEP" 1 100
  require_int --cpu-sample "$CPU_SAMPLE_SECONDS" 1 60
  [[ -n $LOG_FILE ]] || die "--log-file must not be empty"
}

# ---- helpers ----

# Note: inside awk's printf/print, a bare ">" is output redirection, so every
# comparison there is wrapped in parentheses.
pct() { awk -v part="$1" -v whole="$2" 'BEGIN { printf "%.1f", ((whole > 0) ? part * 100 / whole : 0) }'; }

human_kb() { # 2048 -> "2.0 MiB"
  awk -v kb="$1" 'BEGIN {
    split("KiB MiB GiB TiB", unit); i = 1
    while (kb >= 1024 && i < 4) { kb /= 1024; i++ }
    printf "%.1f %s", kb, unit[i]
  }'
}

# level <value> <warn> <crit> -> OK | WARNING | CRITICAL ("exceeded" = strictly above)
level() {
  awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN { print ((v + 0 > c + 0) ? "CRITICAL" : (v + 0 > w + 0) ? "WARNING" : "OK") }'
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# ---- collection ----

# Aggregate CPU line of /proc/stat -> "<idle+iowait> <total>" jiffies.
cpu_times() {
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  echo "$((idle + iowait)) $((user + nice + system + idle + iowait + irq + softirq + steal))"
}

collect_cpu() {
  local idle1 total1 idle2 total2
  read -r idle1 total1 < <(cpu_times)
  sleep "$CPU_SAMPLE_SECONDS"
  read -r idle2 total2 < <(cpu_times)
  CPU_PCT=$(awk -v di=$((idle2 - idle1)) -v dt=$((total2 - total1)) \
    'BEGIN { printf "%.1f", ((dt > 0) ? (1 - di / dt) * 100 : 0) }')
}

collect_memory() {
  local key value
  MEM_TOTAL_KB="" MEM_AVAILABLE_KB=""
  while read -r key value _; do
    case $key in
    MemTotal:) MEM_TOTAL_KB=$value ;;
    MemAvailable:) MEM_AVAILABLE_KB=$value ;;
    esac
  done </proc/meminfo
  [[ -n $MEM_TOTAL_KB && -n $MEM_AVAILABLE_KB ]] || die "cannot read MemTotal/MemAvailable from /proc/meminfo"
  # "Used" = what applications hold; reclaimable page cache counts as available.
  MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAILABLE_KB))
  MEM_PCT=$(pct "$MEM_USED_KB" "$MEM_TOTAL_KB")
}

collect_load() {
  read -r LOAD1 LOAD5 LOAD15 _ </proc/loadavg
  CPU_COUNT=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
}

collect_disks() {
  DISKS=()
  local fs type size used avail capacity mount opts ro
  # Read-only mounts (images, snaps) are often 100% "full" by design and can't
  # fill up further: they are reported but not alerted on.
  local -A read_only=()
  while read -r _ mount _ opts _; do
    if [[ ,$opts, == *,ro,* ]]; then
      read_only[$mount]=1
    fi
  done </proc/self/mounts

  # timeout: a hung NFS mount must not hang the health check. df exits non-zero
  # if a single mount is unreadable; the rest of its output is still valid.
  while read -r fs type size used avail capacity mount; do
    # Zero-size pseudo mounts report "-" instead of a percentage.
    [[ $capacity =~ ^[0-9]+%$ ]] || continue
    ro=false
    if [[ -n ${read_only[$mount]:-} ]]; then
      ro=true
    fi
    DISKS+=("${mount}|${capacity%\%}|${ro}|${fs}|${type}|${size}|${used}|${avail}")
  done < <(timeout 15 df -P -T -k "${DF_EXCLUDES[@]}" 2>/dev/null | awk 'NR > 1')
  ((${#DISKS[@]} > 0)) || die "df reported no filesystems"
}

collect_top_processes() {
  TOP_PROCS=()
  local pid user mem rss comm
  # awk reads all of ps's output (unlike head), so ps never gets SIGPIPE.
  while read -r pid user mem rss comm; do
    TOP_PROCS+=("${pid}|${user}|${mem}|${rss}|${comm}")
  done < <(ps -eo pid=,user=,%mem=,rss=,comm= --sort=-rss | awk 'NR <= 5')
}

# ---- evaluation ----

STATUS=OK
ALERTS=() # "LEVEL|message"

raise() { # raise <LEVEL> <message>
  ALERTS+=("$1|$2")
  if [[ $1 == CRITICAL ]]; then
    STATUS=CRITICAL
  elif [[ $STATUS == OK ]]; then
    STATUS=WARNING
  fi
}

evaluate() {
  local lvl entry mount capacity ro
  lvl=$(level "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT")
  case $lvl in
  CRITICAL) raise CRITICAL "CPU usage ${CPU_PCT}% is above the critical threshold ${CPU_CRIT}%" ;;
  WARNING) raise WARNING "CPU usage ${CPU_PCT}% is above the threshold ${CPU_WARN}%" ;;
  esac

  lvl=$(level "$MEM_PCT" "$MEM_WARN" "$MEM_CRIT")
  case $lvl in
  CRITICAL) raise CRITICAL "Memory usage ${MEM_PCT}% is above the critical threshold ${MEM_CRIT}%" ;;
  WARNING) raise WARNING "Memory usage ${MEM_PCT}% is above the threshold ${MEM_WARN}%" ;;
  esac

  for entry in "${DISKS[@]}"; do
    IFS='|' read -r mount capacity ro _ <<<"$entry"
    if [[ $ro == true ]]; then
      continue
    fi
    lvl=$(level "$capacity" "$DISK_WARN" "$DISK_CRIT")
    case $lvl in
    CRITICAL) raise CRITICAL "Disk usage on ${mount} is ${capacity}%, above the critical threshold ${DISK_CRIT}%" ;;
    WARNING) raise WARNING "Disk usage on ${mount} is ${capacity}%, above the threshold ${DISK_WARN}%" ;;
    esac
  done
}

# ---- reporting ----

render_text() {
  local entry mount capacity ro fs type size pid user mem rss comm a note
  printf '===== %s host=%s status=%s =====\n' "$TIMESTAMP" "$HOST" "$STATUS"
  printf '%-14s %6s%%   (warn >%s%%, crit >%s%%)\n' "CPU usage" "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT"
  printf '%-14s %6s%%   %s of %s used (warn >%s%%, crit >%s%%)\n' "Memory usage" "$MEM_PCT" \
    "$(human_kb "$MEM_USED_KB")" "$(human_kb "$MEM_TOTAL_KB")" "$MEM_WARN" "$MEM_CRIT"
  printf '%-14s %s %s %s (1/5/15 min, %s CPUs)\n' "Load average" "$LOAD1" "$LOAD5" "$LOAD15" "$CPU_COUNT"
  printf 'Disk usage (warn >%s%%, crit >%s%%):\n' "$DISK_WARN" "$DISK_CRIT"
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r mount capacity ro fs type size _ <<<"$entry"
    note=""
    if [[ $ro == true ]]; then
      note=" (read-only, not alerted)"
    fi
    printf '  %-24s %4s%%  of %-10s %-8s %s%s\n' "$mount" "$capacity" "$(human_kb "$size")" "$type" "$fs" "$note"
  done
  printf 'Top 5 processes by memory:\n'
  printf '  %8s  %-12s %6s  %10s  %s\n' PID USER %MEM RSS COMMAND
  for entry in "${TOP_PROCS[@]}"; do
    IFS='|' read -r pid user mem rss comm <<<"$entry"
    printf '  %8s  %-12s %6s  %10s  %s\n' "$pid" "$user" "$mem" "$(human_kb "$rss")" "$comm"
  done
  for a in "${ALERTS[@]}"; do
    printf '[%s] %s\n' "${a%%|*}" "${a#*|}"
  done
}

render_json() {
  local entry mount capacity ro fs type size used avail pid user mem rss comm a sep
  printf '{"timestamp":"%s","hostname":"%s","status":"%s"' "$TIMESTAMP" "$(json_escape "$HOST")" "$STATUS"
  printf ',"cpu":{"usage_percent":%s,"warn_percent":%s,"crit_percent":%s}' "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT"
  printf ',"memory":{"usage_percent":%s,"total_kb":%s,"used_kb":%s,"available_kb":%s,"warn_percent":%s,"crit_percent":%s}' \
    "$MEM_PCT" "$MEM_TOTAL_KB" "$MEM_USED_KB" "$MEM_AVAILABLE_KB" "$MEM_WARN" "$MEM_CRIT"
  printf ',"load_average":{"1m":%s,"5m":%s,"15m":%s,"cpus":%s}' "$LOAD1" "$LOAD5" "$LOAD15" "$CPU_COUNT"

  printf ',"disks":['
  sep=""
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r mount capacity ro fs type size used avail <<<"$entry"
    printf '%s{"mount":"%s","filesystem":"%s","type":"%s","usage_percent":%s,"read_only":%s,"size_kb":%s,"used_kb":%s,"available_kb":%s}' \
      "$sep" "$(json_escape "$mount")" "$(json_escape "$fs")" "$(json_escape "$type")" "$capacity" "$ro" "$size" "$used" "$avail"
    sep=","
  done
  printf '],"disk_warn_percent":%s,"disk_crit_percent":%s' "$DISK_WARN" "$DISK_CRIT"

  printf ',"top_processes":['
  sep=""
  for entry in "${TOP_PROCS[@]}"; do
    IFS='|' read -r pid user mem rss comm <<<"$entry"
    printf '%s{"pid":%s,"user":"%s","mem_percent":%s,"rss_kb":%s,"command":"%s"}' \
      "$sep" "$pid" "$(json_escape "$user")" "$mem" "$rss" "$(json_escape "$comm")"
    sep=","
  done

  printf '],"alerts":['
  sep=""
  for a in "${ALERTS[@]}"; do
    printf '%s{"level":"%s","message":"%s"}' "$sep" "${a%%|*}" "$(json_escape "${a#*|}")"
    sep=","
  done
  printf ']}\n'
}

# ---- log file ----

# Size-based rotation: PATH -> PATH.1 -> ... -> PATH.<keep>, oldest dropped.
rotate_log() {
  [[ -f $LOG_FILE ]] || return 0
  local size_kb i
  size_kb=$(($(wc -c <"$LOG_FILE") / 1024))
  ((size_kb >= LOG_MAX_KB)) || return 0
  rm -f "${LOG_FILE}.${LOG_KEEP}"
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    if [[ -f ${LOG_FILE}.${i} ]]; then
      mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    fi
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

write_log() {
  local dir
  dir=$(dirname "$LOG_FILE")
  [[ -d $dir && -w $dir ]] || die "log directory '$dir' does not exist or is not writable"
  rotate_log
  printf '%s\n' "$REPORT" >>"$LOG_FILE"
}

# ---- webhook (Slack / Discord) ----

notify() {
  [[ -n $WEBHOOK_URL ]] || return 0
  local state_file="${LOG_FILE}.state" previous="" text a key=text payload
  if [[ -r $state_file ]]; then
    previous=$(<"$state_file")
  fi
  printf '%s\n' "$STATUS" >"$state_file"

  # Alert on transitions only (incl. recovery), not every 5 minutes.
  [[ $STATUS != "$previous" ]] || return 0
  [[ -n $previous || $STATUS != OK ]] || return 0

  text="[$STATUS] $HOST health check"
  [[ -z $previous ]] || text+=" (was $previous)"
  for a in "${ALERTS[@]}"; do
    text+=$'\n'"- ${a#*|}"
  done
  # Slack expects {"text": ...}, Discord {"content": ...}.
  if [[ $WEBHOOK_URL == *discord.com/api/webhooks/* || $WEBHOOK_URL == *discordapp.com/api/webhooks/* ]]; then
    key=content
  fi
  payload=$(printf '{"%s":"%s"}' "$key" "$(json_escape "$text")")

  if ! command -v curl >/dev/null 2>&1; then
    warn "HEALTH_WEBHOOK_URL is set but curl is not installed; alert not sent"
    return 0
  fi
  # A broken webhook must not change the health result.
  curl --silent --show-error --fail --max-time 10 \
    -H 'Content-Type: application/json' --data "$payload" "$WEBHOOK_URL" >/dev/null ||
    warn "webhook delivery failed"
}

main() {
  parse_args "$@"
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] || die "this check requires Linux (/proc)"

  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  HOST=${HOSTNAME:-$(uname -n)}

  collect_cpu
  collect_memory
  collect_load
  collect_disks
  collect_top_processes
  evaluate

  if [[ $OUTPUT_JSON == true ]]; then
    REPORT=$(render_json)
    printf '%s\n' "$REPORT"
    # Keep stdout pure JSON; human-readable alerts go to stderr.
    local a
    for a in "${ALERTS[@]}"; do
      printf '[%s] %s\n' "${a%%|*}" "${a#*|}" >&2
    done
  else
    REPORT=$(render_text)
    printf '%s\n' "$REPORT"
  fi

  write_log
  notify

  case $STATUS in
  OK) exit "$EXIT_OK" ;;
  WARNING) exit "$EXIT_WARNING" ;;
  CRITICAL) exit "$EXIT_CRITICAL" ;;
  esac
}

main "$@"
