# system_health.sh

[`scripts/system_health.sh`](../scripts/system_health.sh) is a point-in-time health check for
Linux servers. It collects:

- CPU usage (sampled from `/proc/stat` over 1 second)
- memory usage
- disk usage of every mounted filesystem
- load average
- the top 5 processes by memory

It compares these against thresholds, prints a report (text or JSON), appends it to a rotating
log, and exits with a status code that monitoring tools understand.

## Usage

```bash
./scripts/system_health.sh                              # defaults, text report, ./health_log.txt
./scripts/system_health.sh --disk 80 --cpu 90 --mem 85  # custom warning thresholds
./scripts/system_health.sh --json | jq .                # machine-readable
./scripts/system_health.sh --help
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--cpu N` / `--cpu-crit N` | 90 / 97 | CPU usage % that triggers WARNING / CRITICAL |
| `--mem N` / `--mem-crit N` | 85 / 95 | memory usage % |
| `--disk N` / `--disk-crit N` | 80 / 90 | usage % of **each** filesystem |
| `--json` | off | report (stdout and log) as one JSON object per run |
| `--log-file PATH` | `$HEALTH_LOG_FILE` or `./health_log.txt` | log to append to |
| `--max-log-kb N` / `--keep N` | 1024 / 5 | rotate at N KiB, keep `PATH.1` … `PATH.N` |
| `--cpu-sample N` | 1 | seconds to sample CPU over |

A threshold is "exceeded" when the value is strictly above it. Every value is validated (an
integer from 0 to 100, warning ≤ critical), and a bad flag exits with 3 plus a clear message.

### Exit codes

| Code | Status | When |
|------|--------|------|
| 0 | OK | nothing above a warning threshold |
| 1 | WARNING | at least one value above its warning threshold |
| 2 | CRITICAL | at least one value above its critical threshold (wins over WARNING) |
| 3 | UNKNOWN | bad arguments, or the check itself failed (e.g. `df` returned nothing) |

These are the Nagios/Icinga plugin conventions, so the script can be dropped into those tools,
Zabbix, Sensu or a cron/systemd alert unchanged. Code 3 exists because, with `set -euo pipefail`,
an unexpected failure would otherwise exit 1 or 2 and be **misread as a real WARNING or CRITICAL**.
An `ERR` trap (with `set -E`, so it also fires inside functions) maps every unexpected error to 3.

## Output

Text (example):

```
===== 2026-11-17T15:32:44Z host=web-1 status=WARNING =====
CPU usage        12.4%   (warn >90%, crit >97%)
Memory usage     41.0%   1.5 GiB of 3.7 GiB used (warn >85%, crit >95%)
Load average   0.52 0.40 0.31 (1/5/15 min, 2 CPUs)
Disk usage (warn >80%, crit >90%):
  /                          83%  of 15.9 GiB   xfs      /dev/nvme0n1p1
  /boot/efi                   7%  of 10.0 MiB   vfat     /dev/nvme0n1p128
Top 5 processes by memory:
       PID  USER           %MEM         RSS  COMMAND
      2210  root            3.1   118.2 MiB  dockerd
      2405  10001           1.6    61.0 MiB  python
       ...
[WARNING] Disk usage on / is 83%, above the threshold 80%
```

JSON (`--json`, shortened): one line per run, so the log is valid JSON Lines and can be fed to
`jq`, Loki or any log pipeline.

```json
{"timestamp":"2026-11-17T15:32:44Z","hostname":"web-1","status":"WARNING",
 "cpu":{"usage_percent":12.4,"warn_percent":90,"crit_percent":97},
 "memory":{"usage_percent":41.0,"total_kb":3880000,"used_kb":1590000,"available_kb":2290000,...},
 "load_average":{"1m":0.52,"5m":0.40,"15m":0.31,"cpus":2},
 "disks":[{"mount":"/","filesystem":"/dev/nvme0n1p1","type":"xfs","usage_percent":83,"read_only":false,...}],
 "top_processes":[{"pid":2210,"user":"root","mem_percent":3.1,"rss_kb":121036,"command":"dockerd"},...],
 "alerts":[{"level":"WARNING","message":"Disk usage on / is 83%, above the threshold 80%"}]}
```

In JSON mode, stdout stays pure JSON and the `[WARNING]`/`[CRITICAL]` lines go to stderr.

## Log rotation

Before each append, if the log has reached `--max-log-kb`, it is shifted
(`health_log.txt` → `.1` → `.2` … up to `--keep`, oldest dropped). With the defaults the log uses
at most about 6 MiB. Writing to a missing or read-only directory is reported as UNKNOWN rather than
silently skipped.

## Running it every 5 minutes

### systemd (recommended)

```bash
sudo install -m 0755 scripts/system_health.sh /usr/local/bin/system_health.sh
sudo install -m 0644 scripts/systemd/system-health.service scripts/systemd/system-health.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now system-health.timer

systemctl list-timers system-health.timer      # next run
journalctl -u system-health.service -n 30      # output of recent runs
tail /var/log/system-health/health_log.txt
```

- `OnCalendar=*:0/5` runs on the wall clock (:00, :05, …). Unlike cron, systemd never starts a
  second run while one is still going, and every run's output lands in the journal.
- `SuccessExitStatus=1 2`: WARNING and CRITICAL are results, not a broken unit. Only UNKNOWN
  marks the unit failed, so `systemctl --failed` means "the check is broken", not "the disk is full".
- Hardened: `DynamicUser=yes` (no root), `ProtectSystem=strict`, `ProtectHome=read-only`,
  `PrivateTmp`, `NoNewPrivileges`, no capabilities. It can only write to its own `LogsDirectory`.
  Reading `/proc` and `statfs()` on mount points need no privileges.
- Overrides go in `/etc/default/system-health`, e.g. `HEALTH_ARGS=--disk 85 --json` and
  `HEALTH_WEBHOOK_URL=...`.

### cron (alternative)

```cron
# /etc/cron.d/system-health
*/5 * * * * root flock -n /run/system-health.lock /usr/local/bin/system_health.sh --log-file /var/log/system-health/health_log.txt >/dev/null
```

`flock -n` prevents overlapping runs. stdout is discarded (the report is in the log file), and
stderr, i.e. errors, still reaches cron's mail.

## Slack / Discord alerts (bonus)

Set `HEALTH_WEBHOOK_URL` to a Slack or Discord incoming-webhook URL. The payload format is chosen
from the URL (`{"text": …}` for Slack, `{"content": …}` for Discord).

- **Alerts are sent on status changes only** (OK → WARNING, WARNING → CRITICAL, and back to OK as
  a recovery message). The last status is kept in `<log-file>.state`. Without this, a full disk
  would post a message every 5 minutes until someone muted the channel.
- The URL is a credential, so it is read from the environment (e.g. from
  `/etc/default/system-health` with mode `0600`), never from flags, which would show in `ps` output.
- A failing webhook prints a warning and never changes the exit code.

## Design notes

- **Memory** is `MemTotal - MemAvailable`. Page cache the kernel can reclaim does not count as
  used, otherwise every Linux box looks ~100% full.
- **Disks**: `df -P -T` excludes pseudo filesystems (`tmpfs`, `devtmpfs`, `overlay`, `squashfs`,
  …). **Read-only mounts are listed but not alerted**, because images and snaps are 100% full by
  design and can't grow. Mount flags are read from PID 1's mount table: under `ProtectSystem=strict`
  the service's own namespace shows *every* filesystem read-only, which would silently disable all
  disk alerts. This was caught when testing the hardened unit for real.
- `df` runs under `timeout 15`, so a hung NFS mount can't hang the check. `ps | awk 'NR<=5'`
  instead of `head` avoids SIGPIPE under `pipefail`.
- **CPU** is a short sample, so a single run is noisy. Trends and sustained-load alerts belong to
  Prometheus/node_exporter (see the monitoring stack). This script is the lightweight, dependency-free
  check that still works when the monitoring stack doesn't.
- Dependencies: bash 4+, coreutils, procps, awk. curl only for webhooks.

## Tests

```bash
bash scripts/tests/test_system_health.sh    # Linux; needs python3 for the JSON checks
```

34 checks:
- every exit code and argument validation
- report sections and the timestamp format
- append behaviour
- JSON validity on stdout and in the log
- rotation and `--keep`
- webhook payloads and change-only alerting, using a fake `curl`
- a failing collector mapping to UNKNOWN, using a fake `df`

CI runs the suite and shellcheck on every PR, and posts a sample report to the job summary. The
systemd units were verified with `systemd-analyze verify` and by running the hardened service for
real under systemd.
