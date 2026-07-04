-- Per-tag metadata: friendly names + categories (owner mine/other, placement, …).
--
-- PRIVACY: this file defines only the EMPTY table. The actual names and ownership are
-- personal data (whose tag, in which room) and must never reach the public repo — they
-- live in a git-ignored CSV (server/db/sensor-meta/tags.csv) loaded by load-tag-meta.sh.
-- Same split as .env: the template + loader are committed, the real values are not.
--
-- Keyed on sensor_id (the BLE MAC) ALONE, not (site, sensor_id): a physical tag has one
-- owner and one name regardless of which site's gateway happens to hear it, so a single
-- row here labels that tag across every site (home, test, …) at once.
--
-- Runs automatically on FIRST database startup (empty volume). On an existing volume,
-- apply by hand — see server/db/sensor-meta/README.md.
CREATE TABLE IF NOT EXISTS sensor_meta (
    sensor_id  TEXT PRIMARY KEY,          -- BLE MAC, matches sensor_readings.sensor_id (upper-case)
    name       TEXT,                       -- friendly name, e.g. 'Sauna' (private)
    owner      TEXT,                       -- category axis 1: 'mine' | 'other'
    place      TEXT,                       -- category axis 2: 'Koti' | 'Vaunu' (for owner='mine'); blank for others
    notes      TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
