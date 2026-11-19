# Local secrets

Files in this folder are mounted into containers as Docker secrets
(`/run/secrets/<name>`). They are git-ignored; only this README is committed.

| File | Used by | Contents |
|------|---------|----------|
| `grafana_admin_password` | Grafana (`GF_SECURITY_ADMIN_PASSWORD__FILE`) | the admin password, one line (**required**) |
| `alertmanager/discord_webhook_url` | Alertmanager (`webhook_url_file`) | a Discord webhook URL (optional: without it alerts only show in Grafana) |

Alertmanager gets only the `alertmanager/` subfolder mounted, never the Grafana password.

Create it once before `docker compose up`:

```bash
# bash / Git Bash / WSL
openssl rand -base64 18 > secrets/grafana_admin_password
```

```powershell
# PowerShell
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | % {[char]$_}) | Set-Content -NoNewline secrets/grafana_admin_password
```

Line endings don't matter: Grafana's entrypoint strips a trailing CR/LF (Git Bash's `openssl`
writes CRLF). A missing or blank file stops Grafana from starting instead of falling back to
admin/admin.

Keep the file world-readable (the default `0644`): Grafana runs as UID 472 inside the container
and has to be able to read the bind-mounted file. It is still protected by the folder never leaving
your machine.

The password only takes effect when Grafana's database is first created. To change it later:
`docker compose exec grafana grafana cli admin reset-admin-password '<new>'`.
