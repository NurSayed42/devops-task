#!/usr/bin/env bash
#
# Tests for scripts/system_health.sh. Linux only (the script reads /proc).
# Run: bash scripts/tests/test_system_health.sh   (needs python3 for JSON checks)

set -uo pipefail # no -e: the tests inspect exit codes themselves

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/system_health.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0 FAILED=0 RC=0 OUT="" ERR=""
# Thresholds nothing can exceed, so only the threshold under test can fire.
LOOSE=(--cpu 100 --cpu-crit 100 --mem 100 --mem-crit 100 --disk 100 --disk-crit 100)

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok   - %s\n' "$1"
}
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL - %s\n' "$1"
  if [[ -n ${2:-} ]]; then
    printf '       %s\n' "$2"
  fi
}

# run <args...>: run the script; sets RC, OUT and ERR.
run() {
  bash "$SCRIPT" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT=$(<"$WORK/out")
  ERR=$(<"$WORK/err")
}

expect_rc() {
  if [[ $RC -eq $2 ]]; then
    pass "$1"
  else
    fail "$1" "expected exit $2, got $RC. stderr: $ERR"
  fi
}

expect_match() { # expect_match <name> <haystack> <regex>
  if [[ $2 =~ $3 ]]; then
    pass "$1"
  else
    fail "$1" "no match for /$3/"
  fi
}

json_check() { # json_check <python expression over d> <json text>
  python3 -c 'import json, sys; d = json.loads(sys.argv[2]); sys.exit(0 if eval(sys.argv[1]) else 1)' "$1" "$2"
}

echo "# usage and argument validation"
run --help
expect_rc "--help exits 0" 0
expect_match "--help documents --json" "$OUT" "--json"

for args in "--bogus" "--cpu 150" "--disk abc" "--mem" "--disk 95 --disk-crit 90" "--keep 0"; do
  # shellcheck disable=SC2086 # word splitting is intended here
  run $args
  expect_rc "rejects '$args' with UNKNOWN (3)" 3
done
run "${LOOSE[@]}" --log-file /nonexistent-dir/health_log.txt
expect_rc "unwritable log directory is UNKNOWN (3)" 3

echo "# text report and status"
LOG="$WORK/text/health_log.txt"
mkdir -p "$WORK/text"
run "${LOOSE[@]}" --log-file "$LOG"
expect_rc "healthy host exits 0" 0
for section in "CPU usage" "Memory usage" "Load average" "Disk usage" "Top 5 processes by memory"; do
  expect_match "report contains '$section'" "$OUT" "$section"
done
expect_match "entry has a UTC timestamp header" "$OUT" "^===== [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z host=.+ status=OK ====="
run "${LOOSE[@]}" --log-file "$LOG"
if [[ $(grep -c '^===== ' "$LOG") -eq 2 ]]; then
  pass "each run appends one entry to the log"
else
  fail "each run appends one entry to the log" "$(grep -c '^===== ' "$LOG") entries"
fi

run "${LOOSE[@]}" --log-file "$LOG" --disk 0
expect_rc "disk above --disk threshold exits WARNING (1)" 1
expect_match "prints a [WARNING] line" "$OUT" "\[WARNING\] Disk usage on "

run "${LOOSE[@]}" --log-file "$LOG" --mem 0 --mem-crit 0
expect_rc "memory above --mem-crit exits CRITICAL (2)" 2
expect_match "prints a [CRITICAL] line" "$OUT" "\[CRITICAL\] Memory usage "

run "${LOOSE[@]}" --log-file "$LOG" --disk 0 --mem 0 --mem-crit 0
expect_rc "CRITICAL wins over WARNING" 2

echo "# JSON output"
JLOG="$WORK/json/health_log.txt"
mkdir -p "$WORK/json"
run "${LOOSE[@]}" --log-file "$JLOG" --json --disk 0
expect_rc "JSON mode keeps the exit code" 1
if json_check 'd["status"] == "WARNING" and {"timestamp", "hostname", "cpu", "memory", "load_average", "disks", "top_processes", "alerts"} <= d.keys()' "$OUT"; then
  pass "stdout is one valid JSON document with all sections"
else
  fail "stdout is one valid JSON document with all sections" "$OUT"
fi
if json_check 'len(d["top_processes"]) <= 5 and all(isinstance(x["usage_percent"], int) for x in d["disks"])' "$OUT"; then
  pass "JSON has typed disk and process fields"
else
  fail "JSON has typed disk and process fields"
fi
expect_match "alerts go to stderr in JSON mode" "$ERR" "\[WARNING\] Disk usage on "
run "${LOOSE[@]}" --log-file "$JLOG" --json
bad_lines=0
while read -r line; do
  json_check 'True' "$line" || bad_lines=$((bad_lines + 1))
done <"$JLOG"
if [[ $(wc -l <"$JLOG") -eq 2 && $bad_lines -eq 0 ]]; then
  pass "JSON log is one valid JSON object per line"
else
  fail "JSON log is one valid JSON object per line"
fi

echo "# log rotation"
RLOG="$WORK/rot/health_log.txt"
mkdir -p "$WORK/rot"
head -c 3072 /dev/zero | tr '\0' 'x' >"$RLOG"
run "${LOOSE[@]}" --log-file "$RLOG" --max-log-kb 2 --keep 2
if [[ -f $RLOG.1 && $(wc -c <"$RLOG.1") -eq 3072 && $(grep -c '^===== ' "$RLOG") -eq 1 ]]; then
  pass "a log over --max-log-kb is rotated to .1 and a fresh log started"
else
  fail "a log over --max-log-kb is rotated to .1 and a fresh log started"
fi
for _ in 1 2 3; do
  head -c 3072 /dev/zero | tr '\0' 'y' >"$RLOG"
  run "${LOOSE[@]}" --log-file "$RLOG" --max-log-kb 2 --keep 2
done
if [[ -f $RLOG.1 && -f $RLOG.2 && ! -e $RLOG.3 ]]; then
  pass "--keep limits the number of rotated files"
else
  fail "--keep limits the number of rotated files" "$(ls "$WORK/rot")"
fi

echo "# webhook alerts (fake curl)"
mkdir -p "$WORK/bin" "$WORK/hook"
cat >"$WORK/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/curl_calls"
EOF
chmod +x "$WORK/bin/curl"
HLOG="$WORK/hook/health_log.txt"
calls() { if [[ -f $WORK/curl_calls ]]; then wc -l <"$WORK/curl_calls"; else echo 0; fi; }

PATH="$WORK/bin:$PATH" HEALTH_WEBHOOK_URL=https://hooks.slack.com/services/T0/B0/X run "${LOOSE[@]}" --log-file "$HLOG" --disk 0
if [[ $(calls) -eq 1 ]] && grep -q '"text":"\[WARNING\]' "$WORK/curl_calls"; then
  pass "first WARNING sends a Slack-formatted alert"
else
  fail "first WARNING sends a Slack-formatted alert" "$(cat "$WORK/curl_calls" 2>/dev/null)"
fi
PATH="$WORK/bin:$PATH" HEALTH_WEBHOOK_URL=https://hooks.slack.com/services/T0/B0/X run "${LOOSE[@]}" --log-file "$HLOG" --disk 0
if [[ $(calls) -eq 1 ]]; then
  pass "unchanged status does not re-alert"
else
  fail "unchanged status does not re-alert"
fi
PATH="$WORK/bin:$PATH" HEALTH_WEBHOOK_URL=https://discord.com/api/webhooks/1/abc run "${LOOSE[@]}" --log-file "$HLOG"
if [[ $(calls) -eq 2 ]] && tail -n 1 "$WORK/curl_calls" | grep -q '"content":"\[OK\].*(was WARNING)'; then
  pass "recovery is announced, Discord-formatted for Discord URLs"
else
  fail "recovery is announced, Discord-formatted for Discord URLs" "$(tail -n 1 "$WORK/curl_calls" 2>/dev/null)"
fi
expect_rc "webhook does not change the exit code" 0

echo "# failures inside the check"
cat >"$WORK/bin/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/bin/df"
PATH="$WORK/bin:$PATH" run "${LOOSE[@]}" --log-file "$WORK/text/broken.txt"
expect_rc "a check that cannot collect data exits UNKNOWN (3), not WARNING/CRITICAL" 3

echo
echo "passed: $PASSED, failed: $FAILED"
((FAILED == 0))
