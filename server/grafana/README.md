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
2. **Find its uid** — it's in the URL: `https://vps.example.com/d/<uid>/<slug>`.
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

## Panel query pattern (Koti / Vaunu)

The environmental panels are **time-range adaptive** — each target is a `UNION ALL`
of two branches gated on the selected window:
`($__unixEpochTo() - $__unixEpochFrom()) <= 10800` reads raw `sensor_readings[_cal]`
(full resolution, windows ≤ 3 h) and `> 10800` reads the 1-minute continuous aggregate
`sensor_readings_1min[_cal]` (migration `005`; fast for long windows). Postgres prunes
whichever branch is constant-false, so exactly one runs. The `10800` (seconds = 3 h) **is**
the crossover — change it in every panel to retune. Zooming/painting a ≤ 3 h range makes
every panel switch to raw automatically.

**When editing these panels in the browser:** keep the target in raw-SQL mode and preserve
both `UNION ALL` branches. The visual query builder (or "simplifying" the SQL) will flatten
the adaptive behavior and long windows go slow again. The Calibrated|Raw switch on Koti is
the `series` dashboard variable (`cal`/`raw`), applied via `CASE` in the same SQL.

## Files

| Path | What |
|------|------|
| `provisioning/datasources/timescaledb.yml` | the TimescaleDB datasource (uid `timescaledb`) |
| `provisioning/dashboards/provider.yml` | loads every `*.json` in that dir |
| `provisioning/dashboards/*.json` | the dashboards |
| `provisioning/alerting/*.yml` | alert rules |
