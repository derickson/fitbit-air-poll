#!/usr/bin/env python3
"""Ingest a data-experiment snapshot run into Elasticsearch.

Targets (see design/ELASTICSEARCH-DESIGN.md):
  fitbit-metrics     TSDS data stream — heart-rate samples + step buckets.
                     Identity = dimensions (metric, user_id) + @timestamp;
                     re-ingesting an overlapping window overwrites in place
                     (last write wins), so runs are idempotent and revisions
                     are picked up automatically.
  fitbit-sleep       plain index, _id = server dataPoint id (upsert).
  fitbit-activities  plain index, _id = server dataPoint id (upsert).

Usage: ./ingest-to-elasticsearch.py [--run DIR] [--all-runs] [--dry-run]
  --run DIR    snapshot run directory (default: newest in data-experiment/)
  --all-runs   replay every run oldest→newest (one-time backfill)
  --dry-run    transform and report counts, write nothing

Connection comes from ELASTICSEARCH_URL / ELASTICSEARCH_API_KEY and the
metrics user_id dimension from FITBIT_USER_ID (environment, falling back to
.env in the script directory).
"""
import argparse
import datetime
import glob
import json
import os
import sys
import urllib.error
import urllib.request

BULK_CHUNK = 10_000   # actions per _bulk request
UTC = datetime.timezone.utc


def load_env():
    """Read needed vars from the environment, falling back to .env."""
    here = os.path.dirname(os.path.abspath(__file__))
    fallback = {}
    env_path = os.path.join(here, ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    fallback[k.strip()] = v.strip()
    def get(name):
        v = os.environ.get(name) or fallback.get(name)
        if not v:
            sys.exit(f"ERROR: {name} not set (environment or .env)")
        return v
    return get("ELASTICSEARCH_URL").rstrip("/"), get("ELASTICSEARCH_API_KEY"), get("FITBIT_USER_ID")


def parse_rfc3339(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def seconds(s):
    """'-14400s' / '720s' → int, passing through missing values."""
    return int(s[:-1]) if isinstance(s, str) and s.endswith("s") else s


def opt_int(v):
    return int(v) if v is not None else None


def prune(d):
    """Drop None values (recursively) so absent fields stay absent."""
    if isinstance(d, dict):
        return {k: prune(v) for k, v in d.items() if prune(v) not in (None, {})}
    return d


def point_id(dp):
    """Server dataPoint id: users/<uid>/dataTypes/<t>/dataPoints/<id> → <id>."""
    return dp["name"].rsplit("/", 1)[-1]


# ---- transforms: raw API point → (action, document) -------------------------

def hr_docs(points, user_id):
    for dp in points:
        st = dp["heartRate"]["sampleTime"]
        yield {"create": {"_index": "fitbit-metrics"}}, prune({
            "@timestamp": st["physicalTime"],
            "metric": "heart_rate",
            "user_id": user_id,
            "utc_offset_seconds": seconds(st.get("utcOffset")),
            "heart_rate": {"bpm": opt_int(dp["heartRate"].get("beatsPerMinute"))},
        })


def steps_docs(points, user_id):
    for dp in points:
        iv = dp["steps"]["interval"]
        width = (parse_rfc3339(iv["endTime"]) - parse_rfc3339(iv["startTime"]))
        yield {"create": {"_index": "fitbit-metrics"}}, prune({
            "@timestamp": iv["startTime"],
            "metric": "steps",
            "user_id": user_id,
            "utc_offset_seconds": seconds(iv.get("startUtcOffset")),
            "steps": {"count": opt_int(dp["steps"].get("count")),
                      "interval_seconds": int(width.total_seconds())},
        })


def sleep_docs(points, user_id):
    for dp in points:
        s = dp["sleep"]
        iv = s["interval"]
        summary = s.get("summary", {})
        stages_summary = {}
        for entry in summary.get("stagesSummary", []):
            t = entry["type"].lower()
            stages_summary[f"{t}_minutes"] = opt_int(entry.get("minutes"))
            stages_summary[f"{t}_count"] = opt_int(entry.get("count"))
        duration = (parse_rfc3339(iv["endTime"]) - parse_rfc3339(iv["startTime"]))
        yield {"index": {"_index": "fitbit-sleep", "_id": point_id(dp)}}, prune({
            "@timestamp": iv["startTime"],
            "end_time": iv["endTime"],
            "user_id": user_id,
            "utc_offset_seconds": seconds(iv.get("startUtcOffset")),
            "duration_minutes": int(duration.total_seconds() // 60),
            "type": s.get("type"),
            "create_time": s.get("createTime"),
            "update_time": s.get("updateTime"),
            "summary": {
                "minutes_asleep": opt_int(summary.get("minutesAsleep")),
                "minutes_awake": opt_int(summary.get("minutesAwake")),
                "minutes_in_sleep_period": opt_int(summary.get("minutesInSleepPeriod")),
                "minutes_to_fall_asleep": opt_int(summary.get("minutesToFallAsleep")),
                "minutes_after_wake_up": opt_int(summary.get("minutesAfterWakeUp")),
                "stages": stages_summary,
            },
            "stages": [{"start_time": st["startTime"],
                        "end_time": st["endTime"],
                        "type": st["type"]} for st in s.get("stages", [])],
        })


def exercise_docs(points, user_id):
    for dp in points:
        e = dp["exercise"]
        iv = e["interval"]
        m = e.get("metricsSummary", {})
        zones = m.get("heartRateZoneDurations", {})
        mm = m.get("distanceMillimeters")
        elev = m.get("elevationGainMillimeters")
        yield {"index": {"_index": "fitbit-activities", "_id": point_id(dp)}}, prune({
            "@timestamp": iv["startTime"],
            "end_time": iv["endTime"],
            "user_id": user_id,
            "utc_offset_seconds": seconds(iv.get("startUtcOffset")),
            "exercise_type": e.get("exerciseType"),
            "display_name": e.get("displayName"),
            "active_duration_seconds": seconds(e.get("activeDuration")),
            "create_time": e.get("createTime"),
            "update_time": e.get("updateTime"),
            "metrics": {
                "calories_kcal": m.get("caloriesKcal"),
                "distance_meters": mm / 1000 if mm is not None else None,
                "steps": opt_int(m.get("steps")),
                "average_pace_seconds_per_meter": m.get("averagePaceSecondsPerMeter"),
                "average_heart_rate_bpm": opt_int(m.get("averageHeartRateBeatsPerMinute")),
                "elevation_gain_meters": elev / 1000 if elev is not None else None,
                "active_zone_minutes": opt_int(m.get("activeZoneMinutes")),
                "hr_zone_seconds": {
                    "light": seconds(zones.get("lightTime")),
                    "moderate": seconds(zones.get("moderateTime")),
                    "vigorous": seconds(zones.get("vigorousTime")),
                    "peak": seconds(zones.get("peakTime")),
                },
            },
        })


TRANSFORMS = {
    "heart-rate": hr_docs,
    "steps": steps_docs,
    "sleep": sleep_docs,
    "exercise": exercise_docs,
}


# ---- bulk writer -------------------------------------------------------------

def bulk(es_url, api_key, actions):
    """POST one _bulk request; return (ok_count, skipped_count, item_errors).

    A 409 on a TSDS create means a point with the same dimensions and
    @timestamp is already stored — expected on every run, since each poll
    re-fetches a 2-day window. That is the dedup mechanism working, not an
    error. (Empirically — Elastic Cloud Serverless 9.5 — duplicates are
    rejected first-write-wins, NOT overwritten as older docs suggest.)
    """
    body = "".join(json.dumps(a, separators=(",", ":")) + "\n" +
                   json.dumps(d, separators=(",", ":")) + "\n"
                   for a, d in actions)
    req = urllib.request.Request(
        es_url + "/_bulk",
        data=body.encode(),
        headers={"Authorization": f"ApiKey {api_key}",
                 "Content-Type": "application/x-ndjson"},
        method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.load(resp)
    ok, skipped, errors = 0, 0, []
    for item in result.get("items", []):
        op = "create" if "create" in item else "index"
        info = item.get(op, {})
        if info.get("status", 500) < 300:
            ok += 1
        elif op == "create" and info.get("status") == 409:
            skipped += 1
        else:
            errors.append(info)
    return ok, skipped, errors


def ingest_run(run_dir, es_url, api_key, user_id, dry_run):
    print(f"[ingest] run {os.path.basename(run_dir.rstrip('/'))}")
    actions = []
    counts = {}
    for path in sorted(glob.glob(os.path.join(run_dir, "*", "*.json"))):
        type_name = os.path.splitext(os.path.basename(path))[0]
        transform = TRANSFORMS.get(type_name)
        if transform is None:
            continue  # meta.json etc.
        with open(path) as f:
            points = json.load(f).get("dataPoints", [])
        n = 0
        for action, doc in transform(points, user_id):
            actions.append((action, doc))
            n += 1
        counts[type_name] = counts.get(type_name, 0) + n
    total = sum(counts.values())
    summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    if dry_run:
        print(f"[ingest] dry run: would write {total} docs ({summary})")
        return 0

    ok, skipped, errors = 0, 0, []
    for i in range(0, len(actions), BULK_CHUNK):
        chunk_ok, chunk_skip, chunk_err = bulk(es_url, api_key, actions[i:i + BULK_CHUNK])
        ok += chunk_ok
        skipped += chunk_skip
        errors.extend(chunk_err)
    print(f"[ingest] wrote {ok}/{total} docs, {skipped} already present ({summary})")
    if errors:
        print(f"[ingest] {len(errors)} item errors; first 3:", file=sys.stderr)
        for e in errors[:3]:
            print(f"  {json.dumps(e)}", file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", help="snapshot run dir (default: newest)")
    ap.add_argument("--all-runs", action="store_true",
                    help="replay every data-experiment run oldest→newest")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    es_url, api_key, user_id = load_env()

    if args.all_runs:
        run_dirs = sorted(d for d in glob.glob(os.path.join(here, "data-experiment", "*"))
                          if os.path.isdir(d))
    elif args.run:
        run_dirs = [args.run]
    else:
        candidates = sorted(d for d in glob.glob(os.path.join(here, "data-experiment", "*"))
                            if os.path.isdir(d))
        if not candidates:
            sys.exit("No snapshot runs found in data-experiment/")
        run_dirs = [candidates[-1]]

    status = 0
    for run_dir in run_dirs:
        try:
            status |= ingest_run(run_dir, es_url, api_key, user_id, args.dry_run)
        except urllib.error.HTTPError as e:
            print(f"[ingest] HTTP {e.code} from Elasticsearch: "
                  f"{e.read().decode(errors='replace')[:500]}", file=sys.stderr)
            return 1
    return status


if __name__ == "__main__":
    sys.exit(main())
