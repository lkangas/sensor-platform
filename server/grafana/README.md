# Grafana as code

Datasource, dashboards, and alert rules are all provisioned from files here — a
fresh Grafana container reproduces everything with no clicking. **The JSON/YAML
files in git are the source of truth.**

## Designing dashboards in the browser and committing them

You can edit dashboards in the UI (`allowUiUpdates: true`), but a UI save only
writes to Grafana's database — it is **not** in git and would be lost on a
rebuild. To make a change permanent, pull it back into the repo:

1. **Design** in the browser. Edit an existing dashboard, or build a new one
   (New → Dashboard). Save it in the UI.
2. **Find its uid** — it's in the URL: `https://petzval.dy.fi/d/<uid>/<slug>`.
3. **Pull it into the repo:**
   ```bash
   scripts/grafana-pull-dashboard.sh <uid>
   # writes server/grafana/provisioning/dashboards/<uid>.json
   ```
4. **Commit & push**, then on the VPS `git pull` (the provider hot-reloads within
   ~30 s; no restart needed).

Or just tell Claude "I made a dashboard `<uid>`, commit it" and it runs the pull.

### Notes
- Keep a stable dashboard **uid** so pulls overwrite the same file instead of
  creating duplicates. "Save As" mints a new uid (a new dashboard) — fine when you
  mean to.
- Don't use **Share → Export → "Export for external sharing"**: it rewrites the
  datasource into `${DS_...}` template inputs. The pull script avoids this and
  keeps the concrete `timescaledb` datasource uid (which we pinned), so the file
  works as-is on any rebuild.
- The pull strips the internal `id` and `version` so files stay portable.

## Files

| Path | What |
|------|------|
| `provisioning/datasources/timescaledb.yml` | the TimescaleDB datasource (uid `timescaledb`) |
| `provisioning/dashboards/provider.yml` | loads every `*.json` in that dir |
| `provisioning/dashboards/*.json` | the dashboards |
| `provisioning/alerting/*.yml` | alert rules |
