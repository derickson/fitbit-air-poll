# Elasticsearch ingestion design — fitbit-metrics / fitbit-sleep / fitbit-activities

Design for loading the Google Health (Fitbit) data pulled by this repo into
Elasticsearch, using modern time-series storage for the high-volume metrics
and plain indices for the low-volume session documents, with a write strategy
that is safe against everything the data-lag experiment taught us: late
arrival (up to ~1 h), re-pulled overlapping windows (every poll re-fetches two
civil days), and occasional after-the-fact revision of points.

---

## 1. What the data looks like (from `data-experiment/`)

| Type | Volume | Shape | Mutability observed |
|---|---|---|---|
| heart-rate | ~25k samples/day | point sample, `sampleTime` + `beatsPerMinute` | none in 41 runs |
| steps | ~hundreds/day | 1-minute interval buckets, `interval` + `count` | none in 41 runs |
| sleep | ~1/day | session with stages, summary, `createTime`/`updateTime`, stable server id | `updateTime` advances (processed ~20 min after wake) |
| exercise | ~0–2/day | session with metrics summary, `createTime`/`updateTime`, stable server id | 1 revision observed |

Measured availability lag (origin → first seen on API): heart-rate median
~22 m, p90 ~35 m, **max ~57 m**; steps max ~43 m; sleep sessions appear only
after the phone syncs (~20 min after wake in the best case, many hours if the
phone stays asleep). Every poll re-fetches yesterday + today, so **every poll
re-sees almost everything it already saw** — the ingest path must be
idempotent by construction.

The raw API points are extremely redundant: each heart-rate sample repeats
`dataSource` (constant), `civilTime` (derivable), and `utcOffset` (constant
-14400 s). We strip all of that at ingest and keep one offset field, letting
Elasticsearch's columnar storage do the rest.

## 2. Research summary — the modern Elasticsearch options

Sources: [Elasticsearch as a columnar metrics engine](https://www.elastic.co/search-labs/blog/elasticsearch-columnar-metrics-engine-30x-faster-prometheus),
[TSDS docs](https://www.elastic.co/docs/manage-data/data-store/data-streams/time-series-data-stream-tsds),
[TSDS reference (8.18)](https://www.elastic.co/guide/en/elasticsearch/reference/8.18/tsds.html),
[logsdb docs](https://www.elastic.co/docs/manage-data/data-store/data-streams/logs-data-stream).

- **TSDS (`index.mode: time_series`)** is the right store for metrics. GA
  since 8.7; the 9.x line turned it into a true columnar metrics engine
  (~3.75 bytes per OTel data point, queries up to 30× faster than Prometheus):
  doc-value skippers replace inverted indices on `@timestamp`/dimensions
  (9.3), synthetic `_id` derived from `_tsid`+`@timestamp` (9.4), sequence
  number trimming (9.4), synthetic `_source` (no stored JSON — docs are
  reconstructed from doc values), and the ES|QL `TS` command
  (`TS fitbit-metrics | STATS AVG_OVER_TIME(...) BY TBUCKET(1h)`, GA 9.4).
- **Document identity in TSDS**: `_id` is *synthesized* from the dimension
  hash (`_tsid`) and `@timestamp`. Custom `_id` is not allowed. Two documents
  with the same dimensions + timestamp are the *same document*. The 8.18
  reference claims `_bulk` overwrites such duplicates (last write wins), but
  **empirically on our target — Elastic Cloud Serverless 9.5 — duplicate
  creates are rejected with item-level 409** (first write wins). Either way
  duplicates cannot accumulate; this is the crux of our dedup story (§5).
- **Time bounds**: each backing index accepts only
  `[index.time_series.start_time, end_time)`. Documents are routed to the
  backing index matching their `@timestamp`; a document outside *every*
  backing index's range is **rejected**. The first backing index starts at
  `now - index.look_back_time` (default **2 h**, max 7 d) — so backfilling
  our existing snapshots requires raising `look_back_time` *before* first
  ingest. Late-arriving data after that is fine: old backing indices remain
  writable by timestamp routing until ILM deletes them.
- **logsdb (`index.mode: logsdb`)** is the analogous mode for *logs* (60 %
  smaller storage, synthetic `_source`, sorted on `host.name`/`@timestamp`).
  It is the wrong fit for our metrics (no `_tsid`, no dimension-based
  dedup/overwrite, no `TS` query support) and unnecessary for sleep/exercise
  (a few documents per day — storage efficiency is irrelevant, and we want
  ordinary update semantics). We use it nowhere; noted here because it was
  considered.

**Version target: Elasticsearch ≥ 8.13 works; ≥ 9.3 recommended** to get the
columnar engine wins; 9.4+ adds synthetic `_id` and `TS` GA. Nothing in the
design depends on 9.4 — it just gets cheaper and faster there.

## 3. `fitbit-metrics` — TSDS for heart rate + steps

One time-series data stream holding both metric types, separated by a
`metric` dimension (dimensions feed `_tsid`, so heart-rate and steps samples
at the same instant can never collide).

### Document shape (what we actually store)

```json
{ "@timestamp": "2026-06-07T12:29:40Z", "metric": "heart_rate",
  "user_id": "2172866075555756931", "utc_offset_seconds": -14400,
  "heart_rate": { "bpm": 75 } }

{ "@timestamp": "2026-06-07T12:05:00Z", "metric": "steps",
  "user_id": "2172866075555756931", "utc_offset_seconds": -14400,
  "steps": { "count": 30, "interval_seconds": 60 } }
```

- HR `@timestamp` = `sampleTime.physicalTime`.
- Steps `@timestamp` = **interval start** (Prometheus-style bucket label);
  `interval_seconds` preserves the bucket width (observed: always 60).
- Dropped entirely: `dataSource` (constant `PASSIVELY_MEASURED`/`FITBIT`),
  `civilTime` (derivable from `@timestamp` + offset), per-field
  `utcOffset` repetition (kept once, as a plain field — it changes only when
  travelling/DST, and we may want local-time analysis).
- `bpm`/`count` arrive as JSON *strings* — cast to int at ingest.

### Index template

```json
PUT _index_template/fitbit-metrics
{
  "index_patterns": ["fitbit-metrics"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.mode": "time_series",
      "index.look_back_time": "7d",
      "index.sort.field": [],
      "index.number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "@timestamp":         { "type": "date" },
        "metric":             { "type": "keyword", "time_series_dimension": true },
        "user_id":            { "type": "keyword", "time_series_dimension": true },
        "utc_offset_seconds": { "type": "integer" },
        "heart_rate": { "properties": {
          "bpm":   { "type": "integer", "time_series_metric": "gauge" } } },
        "steps": { "properties": {
          "count": { "type": "integer", "time_series_metric": "gauge" },
          "interval_seconds": { "type": "integer" } } }
      }
    }
  }
}
```

Notes:
- `steps.count` is a **gauge**, not a `counter` — Fitbit gives per-minute
  *deltas*, not a cumulative total (TSDS counters must be monotonic).
- `index.look_back_time: 7d` (the maximum) so the first ingest can backfill
  the existing `data-experiment/` snapshots. Backfill older than 7 days would
  need a manually-created backing index with explicit
  `index.time_series.start_time` — not needed for our data.
- Replicas 0 assumes single-node/homelab; raise for a real cluster.
- The data stream is created implicitly on first write to `fitbit-metrics`.

## 4. `fitbit-sleep` and `fitbit-activities` — plain indices, upsert by server id

Sleep and exercise points carry a stable server identity —
`"name": "users/<uid>/dataTypes/sleep/dataPoints/7909817802118039424"` — plus
`createTime`/`updateTime`. That makes the right model a **plain index with a
deterministic `_id`** (the trailing number of `name`), written with the
`index` bulk op: first write creates, every re-pull harmlessly rewrites, and a
*revised* session (new `updateTime`) **overwrites in place**. No duplicates,
no version juggling, full update/delete freedom — exactly what TSDS/logsdb
would take away, and at ~1 doc/day storage modes are irrelevant.

```json
PUT fitbit-sleep
{
  "mappings": {
    "properties": {
      "@timestamp":   { "type": "date" },          // session start
      "end_time":     { "type": "date" },
      "user_id":      { "type": "keyword" },
      "utc_offset_seconds": { "type": "integer" },
      "duration_minutes":   { "type": "integer" }, // end - start
      "type":         { "type": "keyword" },        // STAGES
      "create_time":  { "type": "date" },
      "update_time":  { "type": "date" },
      "summary": { "properties": {
        "minutes_asleep":          { "type": "integer" },
        "minutes_awake":           { "type": "integer" },
        "minutes_in_sleep_period": { "type": "integer" },
        "minutes_to_fall_asleep":  { "type": "integer" },
        "minutes_after_wake_up":   { "type": "integer" },
        "stages": { "properties": {                 // from stagesSummary
          "awake_minutes": { "type": "integer" }, "awake_count": { "type": "integer" },
          "light_minutes": { "type": "integer" }, "light_count": { "type": "integer" },
          "deep_minutes":  { "type": "integer" }, "deep_count":  { "type": "integer" },
          "rem_minutes":   { "type": "integer" }, "rem_count":   { "type": "integer" } } }
      } },
      "stages": { "type": "nested", "properties": {
        "start_time": { "type": "date" },
        "end_time":   { "type": "date" },
        "type":       { "type": "keyword" } } }
    }
  }
}
```

```json
PUT fitbit-activities
{
  "mappings": {
    "properties": {
      "@timestamp":   { "type": "date" },          // exercise start
      "end_time":     { "type": "date" },
      "user_id":      { "type": "keyword" },
      "utc_offset_seconds": { "type": "integer" },
      "exercise_type": { "type": "keyword" },       // WALKING, ...
      "display_name":  { "type": "keyword" },
      "active_duration_seconds": { "type": "integer" },
      "create_time":  { "type": "date" },
      "update_time":  { "type": "date" },
      "metrics": { "properties": {
        "calories_kcal":      { "type": "float" },
        "distance_meters":    { "type": "float" },   // mm / 1000
        "steps":              { "type": "integer" },
        "average_pace_seconds_per_meter": { "type": "float" },
        "average_heart_rate_bpm":         { "type": "integer" },
        "elevation_gain_meters":          { "type": "float" },
        "active_zone_minutes":            { "type": "integer" },
        "hr_zone_seconds": { "properties": {
          "light":    { "type": "integer" },
          "moderate": { "type": "integer" },
          "vigorous": { "type": "integer" },
          "peak":     { "type": "integer" } } }
      } }
    }
  }
}
```

Flattened `stagesSummary` → fixed fields (instead of a nested array) so
Kibana lens/ES|QL can chart "deep minutes per night" without nested queries;
the per-stage timeline stays available under nested `stages`. Units are
normalized at ingest (mm→m, `"720s"`→720, numeric strings→numbers).

## 5. Dedup + revision strategy (the heart of the design)

**Strategy: idempotent full-window rewrite, leaning on each store's natural
overwrite semantics. No state files, no high-water marks, no dedup queries.**

Every ingest run takes the most recent snapshot (or fetches fresh) for
yesterday + today and bulk-writes *everything*:

| Store | Identity | Re-pull of unchanged point | Late-arriving point | Back-revised point |
|---|---|---|---|---|
| `fitbit-metrics` (TSDS) | `_tsid` (= dims) + `@timestamp` → synthetic `_id` | item-level 409, counted as "already present" — no duplicate ✔ | routed to correct backing index by `@timestamp` (within retention) | 409 → **first-seen value kept** (accepted risk: zero HR/steps revisions in 41 experiment runs) |
| `fitbit-sleep` / `fitbit-activities` | explicit `_id` = server dataPoint id | `index` op rewrites same doc | normal index | **`index` op overwrites; `update_time` records it** ✔ |

Why this beats the alternatives:

- *High-water-mark / delta ingestion* (only write points newer than the last
  run) minimizes writes but is fragile: it needs persisted state and breaks
  if a run is skipped. Our volume (~50k docs per run, ~25k/day/type max)
  makes the full rewrite cheap — seconds of `_bulk`.
- *Waiting for points to "finalize"* (only ingest buckets older than the p90
  lag) sacrifices freshness and still needs the 409-tolerant path for
  overlap.

Answering the open question directly: **on Elastic Cloud Serverless 9.5,
TSDS does *not* allow overwriting** — duplicate dims+timestamp creates are
rejected 409 (verified empirically; the stateful 8.18 docs describe bulk
last-write-wins instead, so behavior differs by deployment). For metrics
that means first-seen-wins, which the experiment shows is indistinguishable
from latest (no HR/steps revision ever observed). The mutable session
documents (sleep, exercise) deliberately live *outside* TSDS in plain
indices precisely so revisions overwrite cleanly there — and that is where
revisions actually happen (`updateTime`).

Two practical caveats:
1. **Retention bound**: a revision arriving after ILM has deleted the backing
   index covering its timestamp is unwritable (rejected). With revisions
   observed only minutes-to-hours after origin, any retention ≥ a few days is
   safe.
2. **Within-pull duplicates**: the analyzer occasionally flags duplicate keys
   inside a single pull; in a single `_bulk` body the later line wins —
   matching the analyzer's own semantics.

## 6. Ingest pipeline

New script `ingest-to-elasticsearch.py` (stdlib `urllib` or `requests`; no
client-library dependency needed):

```
fitbit-poll.sh                     (cron, every 30 min)
        └─ fetch-health-data.sh ×2 → <tmpdir>/<day>/{heart-rate,steps,sleep,exercise}.json
ingest-to-elasticsearch.py [--run <dir>] [--all-runs] [--dry-run]
        ├─ transform: strip redundancy, cast numeric strings, normalize units
        ├─ _bulk → fitbit-metrics      (create-on-write data stream, op: create*)
        ├─ _bulk → fitbit-sleep        (op: index, _id = dataPoint id)
        └─ _bulk → fitbit-activities   (op: index, _id = dataPoint id)
```

\* data streams accept only `create` in `_bulk`; on identical dims+timestamp
the duplicate is rejected with item-level 409, which the script counts as
"already present" rather than an error (§5).

- **Hook**: `fitbit-poll.sh` (formerly `refresh-token.sh`) fetches the
  two-day window into a temp dir and runs the ingest, with failure isolation
  (`|| echo ... >&2`) so an ES outage never breaks the token refresh. Each
  poll therefore lands in ES ≤ 30 min after the API has it. The original
  design ingested from `data-experiment/` snapshots; once the data-lag
  experiment ended, the cron cycle switched to throwaway temp dirs.
- **Backfill**: `--all-runs` iterates every existing `data-experiment/` run
  oldest→newest. Idempotency makes this safe to re-run; replaying oldest→
  newest means the final state reflects the latest pull of every point.
  (Must run *after* the template with `look_back_time: 7d` exists and before
  the snapshots age past 7 days.)
- **Bootstrap**: `setup-elasticsearch.sh` PUTs the index template (§3) and
  the two plain indices (§4); refuses to run if `fitbit-metrics` already
  exists with a different mode.
- **Error handling**: parse the `_bulk` response; item-level 409 on TSDS
  creates is the dedup mechanism firing (reported as a "already present"
  count), all other item errors logged with the offending doc.
- **Config**: `ELASTICSEARCH_URL`, `ELASTICSEARCH_API_KEY`, and
  `FITBIT_USER_ID` in `.env`.

## 7. Lifecycle / future

- **ILM** on `fitbit-metrics`: rollover (30 d max age), then — optionally —
  **downsample** to 5 m resolution after 90 d and 1 h after 1 y instead of
  deleting; personal health history is small enough to keep forever
  (~25k HR points/day ≈ <100 KB/day at ~3.75 B/point).
- **Queries**: ES|QL `TS fitbit-metrics | WHERE metric == "heart_rate" |
  STATS MIN(heart_rate.bpm), AVG(...) BY TBUCKET(1h)` for resting-HR style
  dashboards (9.4+); standard Lens/aggregations work on all versions.
- **Extensible**: new metric types (SpO₂, HRV, weight) are new `metric`
  dimension values + one mapped field each — no new indices.

## 8. Open items

1. **Where does Elasticsearch run?** Nothing is listening on `:9200` locally;
   docker-compose for a single-node 9.4 instance is a 10-line addition if
   wanted.
2. **Civil-day fetch boundary**: snapshots are keyed by *local* civil day but
   contain UTC instants; the TSDS doesn't care (it routes purely on
   `@timestamp`), so this is cosmetic only.
3. Whether to also index the *food/weight* write-path data later — same
   plain-index + deterministic-id pattern as sleep would apply.
