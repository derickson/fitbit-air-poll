#!/usr/bin/env python3
"""Analyze data-experiment/ snapshots to see how Google Health data evolves
between pulls.

For every consecutive pair of snapshot runs this reports, per civil day and
data type:
  - ADDED   points (new data became available on the API)
  - CHANGED points (same key, different value — data revised after the fact)
  - REMOVED points (present before, gone now)

It also measures availability lag: the gap between when a data point
originated on the device (sample time / interval end) and the first snapshot
run that contained it. Points already present in the earliest snapshot are
"baseline" — their true arrival time is unknown, so they are excluded from
lag statistics.

Usage: ./analyze_experiment_deltas.py [--dir data-experiment] [--verbose]
"""
import argparse
import datetime
import glob
import json
import os
import statistics
import sys

UTC = datetime.timezone.utc


def parse_rfc3339(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def run_started(run_dir):
    """Run start time from meta.json, falling back to the folder name."""
    meta = os.path.join(run_dir, "meta.json")
    if os.path.exists(meta):
        with open(meta) as f:
            return datetime.datetime.fromtimestamp(
                json.load(f)["run_started_epoch"], tz=UTC)
    name = os.path.basename(run_dir.rstrip("/"))  # 2026-06-06T18-30-01Z
    return datetime.datetime.strptime(name, "%Y-%m-%dT%H-%M-%SZ").replace(tzinfo=UTC)


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def extract_points(type_name, data_points):
    """→ {key: (origin_time, value, raw_point)}.

    key    uniquely identifies a point across runs
    origin describes when the data was generated on-device:
           sample time for samples, interval END for interval/session types
           (a steps bucket can't be final before the minute ends).
    value  is what we compare run-to-run to detect revisions.
    """
    out = {}
    dupes = 0
    for dp in data_points:
        if type_name == "heart-rate":
            st = dp["heartRate"]["sampleTime"]["physicalTime"]
            key, origin, value = st, parse_rfc3339(st), dp["heartRate"].get("beatsPerMinute")
        elif type_name == "steps":
            iv = dp["steps"]["interval"]
            key, origin, value = iv["startTime"], parse_rfc3339(iv["endTime"]), dp["steps"].get("count")
        else:  # exercise / sleep — session types, compare the whole payload
            body = dp.get("exercise") if type_name == "exercise" else dp.get("sleep")
            iv = (body or {}).get("interval", {})
            key = dp.get("name") or iv.get("startTime", "?")
            end = iv.get("endTime") or iv.get("startTime")
            origin = parse_rfc3339(end) if end else None
            value = canonical(dp)
        if key in out:
            dupes += 1
        out[key] = (origin, value, dp)
    return out, dupes


def describe_change(type_name, key, old, new):
    """One-line human description of a revised point."""
    if type_name in ("heart-rate", "steps"):
        what = "bpm" if type_name == "heart-rate" else "steps"
        return f"{key}: {old[1]} → {new[1]} {what}"
    # Session types: name the top-level fields that differ.
    o, n = json.loads(old[1]), json.loads(new[1])
    body_o = o.get("sleep") or o.get("exercise") or {}
    body_n = n.get("sleep") or n.get("exercise") or {}
    diffs = []
    iv_o, iv_n = body_o.get("interval", {}), body_n.get("interval", {})
    if iv_o.get("endTime") != iv_n.get("endTime"):
        diffs.append(f"endTime {iv_o.get('endTime')} → {iv_n.get('endTime')}")
    so, sn = body_o.get("stages", []), body_n.get("stages", [])
    if len(so) != len(sn):
        diffs.append(f"stages {len(so)} → {len(sn)}")
    elif so != sn:
        diffs.append("stage contents revised")
    for fld in set(body_o) | set(body_n):
        if fld in ("interval", "stages"):
            continue
        if body_o.get(fld) != body_n.get(fld):
            diffs.append(f"{fld}: {body_o.get(fld)!r} → {body_n.get(fld)!r}")
    return f"{key}: " + ("; ".join(diffs) if diffs else "changed (non-body fields)")


def fmt_lag(seconds):
    if seconds < 0:
        return f"-{fmt_lag(-seconds)}"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m" if h else (f"{m}m{s:02d}s" if m else f"{s}s")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", default="data-experiment", help="snapshot root")
    ap.add_argument("--verbose", action="store_true",
                    help="list every added point, not just summaries")
    args = ap.parse_args()

    run_dirs = sorted(d for d in glob.glob(os.path.join(args.dir, "*"))
                      if os.path.isdir(d))
    if len(run_dirs) < 2:
        sys.exit(f"Need at least 2 snapshot runs in {args.dir}/, found {len(run_dirs)}")

    runs = [(d, run_started(d)) for d in run_dirs]
    print(f"# Snapshot delta analysis — {len(runs)} runs, "
          f"{runs[0][1]:%Y-%m-%d %H:%M} → {runs[-1][1]:%H:%M} UTC\n")

    # state[(date, type)] = {key: (origin, value, raw)} from the previous run
    state = {}
    first_seen = {}   # (date, type, key) -> (run_idx, lag_seconds) for non-baseline points
    lags = {}         # type -> [lag_seconds]
    freshness = []    # (run_idx, type, lag of newest point at pull time)

    for idx, (run_dir, run_ts) in enumerate(runs):
        label = "baseline" if idx == 0 else f"run {idx}"
        print(f"## {os.path.basename(run_dir)}  ({label}, started {run_ts:%H:%M:%S} UTC)")
        date_dirs = sorted(d for d in glob.glob(os.path.join(run_dir, "*"))
                           if os.path.isdir(d))
        newest_origin = {}
        any_change = False
        for date_dir in date_dirs:
            date = os.path.basename(date_dir)
            for path in sorted(glob.glob(os.path.join(date_dir, "*.json"))):
                type_name = os.path.splitext(os.path.basename(path))[0]
                with open(path) as f:
                    pts, dupes = extract_points(type_name, json.load(f)["dataPoints"])
                if dupes:
                    print(f"  ⚠ {date}/{type_name}: {dupes} duplicate keys in one pull")

                for origin, _, _ in pts.values():
                    if origin and (type_name not in newest_origin or origin > newest_origin[type_name]):
                        newest_origin[type_name] = origin

                prev = state.get((date, type_name))
                state[(date, type_name)] = pts
                if prev is None:
                    if idx > 0:
                        # New civil day appearing mid-experiment: all points count as new.
                        prev = {}
                    else:
                        continue  # baseline — nothing to diff against

                added = {k: v for k, v in pts.items() if k not in prev}
                removed = {k: v for k, v in prev.items() if k not in pts}
                changed = {k: (prev[k], pts[k]) for k in pts
                           if k in prev and pts[k][1] != prev[k][1]}

                for k, (origin, _, _) in added.items():
                    if origin is not None:
                        lag = (run_ts - origin).total_seconds()
                        first_seen[(date, type_name, k)] = (idx, lag)
                        lags.setdefault(type_name, []).append(lag)

                if not (added or removed or changed):
                    continue
                any_change = True
                parts = []
                if added:
                    origins = sorted(o for o, _, _ in added.values() if o)
                    span = (f", origins {origins[0]:%H:%M:%S}–{origins[-1]:%H:%M:%S}"
                            if origins else "")
                    parts.append(f"+{len(added)} added{span}")
                if changed:
                    parts.append(f"~{len(changed)} changed")
                if removed:
                    parts.append(f"-{len(removed)} removed")
                print(f"  {date}/{type_name}: " + ", ".join(parts))
                for k, (old, new) in sorted(changed.items()):
                    print(f"      ~ {describe_change(type_name, k, old, new)}")
                if args.verbose:
                    for k in sorted(added):
                        print(f"      + {k}")
                    for k in sorted(removed):
                        print(f"      - {k}")

        for type_name, origin in sorted(newest_origin.items()):
            freshness.append((idx, type_name, (run_ts - origin).total_seconds()))
        if idx > 0 and not any_change:
            print("  (no changes vs previous run)")
        print()

    # ---- Availability lag: origin time vs first appearance on the API ----
    print("## Availability lag (origin → first seen on API; baseline points excluded)")
    if not lags:
        print("  No new points arrived after the baseline run yet.")
    for type_name, vals in sorted(lags.items()):
        vals.sort()
        med = statistics.median(vals)
        p90 = vals[max(0, int(len(vals) * 0.9) - 1)]
        print(f"  {type_name:11s} n={len(vals):6d}  "
              f"min={fmt_lag(vals[0]):>8s}  median={fmt_lag(med):>8s}  "
              f"p90={fmt_lag(p90):>8s}  max={fmt_lag(vals[-1]):>8s}")
    print("\n  Note: lag is an upper bound — a point first seen in run N actually "
          "arrived\n  somewhere between run N-1 and run N (≤30 min uncertainty).")

    # ---- Freshness: how stale is the newest data at each pull? ----
    print("\n## Freshness at pull time (run start − newest point's origin)")
    by_type = {}
    for idx, type_name, lag in freshness:
        by_type.setdefault(type_name, []).append((idx, lag))
    for type_name, entries in sorted(by_type.items()):
        cells = "  ".join(f"r{idx}:{fmt_lag(lag)}" for idx, lag in entries)
        print(f"  {type_name:11s} {cells}")


if __name__ == "__main__":
    main()
