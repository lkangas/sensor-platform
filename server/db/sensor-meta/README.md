# Private tag metadata (names + categories)

Friendly names and categories for each sensor — **who owns it** (`mine` / `other`),
where it sits, etc. This information is personal (it reveals whose tag is in which room),
so unlike the rest of the config-as-code repo it is **kept out of git**. The split mirrors
`.env`:

| Committed (public)                | Git-ignored (private)         |
|-----------------------------------|-------------------------------|
| `../init/003_sensor_meta.sql` — empty table definition | `tags.csv` — the real names/owners |
| `load-tag-meta.sh` — the loader   |                               |
| `tags.example.csv` — blank template |                             |

Dashboards `LEFT JOIN sensor_meta` on `sensor_id` and display
`COALESCE(name, right(mac,4))`, so any tag **not** listed still self-labels with its
4-char code — nothing breaks when the table is empty or partial.

## Filling it in

1. `cp tags.example.csv tags.csv`  (git ignores `tags.csv`).
2. Edit `tags.csv` — one row per MAC. Columns:
   - `sensor_id` — the BLE MAC (the template shows placeholder examples; put your real MACs here).
   - `name` — friendly name, e.g. `Sauna`, `Fridge`, `Vaunu Ulko`.
   - `owner` — `mine` or `other` (category axis 1).
   - `place` — for your own tags, `Koti` or `Vaunu` (category axis 2); leave blank for
     others.
   - `category` — optional free-form panel grouping (axis 3). Dashboards filter on it so
     tag names never appear in the committed JSON and panels survive renames — e.g.
     `cold` puts a fridge/freezer tag on the Koti "Cold" temperature panel (and out of
     the main Temperature panel). Blank = ungrouped.
   - `notes` — optional free text.
   Leave a cell blank to store NULL; blanks fall back to the 4-char code in dashboards.

## Loading (on the VPS)

`sensor_meta` lives in the `sensors` database inside the TimescaleDB container, so load
runs on the VPS:

```bash
./load-tag-meta.sh                 # defaults to ./tags.csv, container server-timescaledb-1
```

Idempotent — re-run after any edit. Rows are upserted by `sensor_id`, and because the
metadata joins in at query time, a name you add **retroactively labels all history**, not
just new rows.

## Redeploy / backup

Keep a copy of `tags.csv` in your private store (password manager / private backup),
same as you would `.env`. To rebuild from scratch: `git clone`, restore `tags.csv` into
this directory, run the loader. On an existing DB volume (where `003_sensor_meta.sql`
won't re-run), create the table once by hand:

```bash
docker exec -i server-timescaledb-1 psql -U postgres -d sensors < ../init/003_sensor_meta.sql
```
