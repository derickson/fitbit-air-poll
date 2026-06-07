#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# One-time Elasticsearch bootstrap (idempotent): index template for the
# fitbit-metrics TSDS plus the fitbit-sleep / fitbit-activities indices.
# See design/ELASTICSEARCH-DESIGN.md. Targets Elastic Cloud Serverless — no
# replica/sort settings (managed), no ILM.

set -a; source .env; set +a
: "${ELASTICSEARCH_URL:?missing in .env}" "${ELASTICSEARCH_API_KEY:?missing in .env}"

es() { # METHOD PATH [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  curl -sS -m 30 -X "$method" \
    -H "Authorization: ApiKey $ELASTICSEARCH_API_KEY" \
    -H 'Content-Type: application/json' \
    ${body:+-d "$body"} \
    "$ELASTICSEARCH_URL$path"
}

# Refuse to touch an existing fitbit-metrics that is not a TSDS data stream.
existing=$(es GET /_data_stream/fitbit-metrics)
if echo "$existing" | grep -q '"index_mode"' && ! echo "$existing" | grep -q '"index_mode":"time_series"'; then
  echo "ERROR: data stream fitbit-metrics exists but is not time_series:" >&2
  echo "$existing" >&2
  exit 1
fi

echo "== index template: fitbit-metrics (TSDS) =="
es PUT /_index_template/fitbit-metrics '{
  "index_patterns": ["fitbit-metrics"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.mode": "time_series",
      "index.look_back_time": "7d"
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
}'
echo

create_index() { # NAME MAPPINGS_JSON — tolerate already-exists
  local out
  out=$(es PUT "/$1" "$2")
  if echo "$out" | grep -q resource_already_exists_exception; then
    echo "{\"acknowledged\":true,\"note\":\"$1 already exists, left untouched\"}"
  else
    echo "$out"
  fi
}

echo "== index: fitbit-sleep =="
create_index fitbit-sleep '{
  "mappings": {
    "properties": {
      "@timestamp":   { "type": "date" },
      "end_time":     { "type": "date" },
      "user_id":      { "type": "keyword" },
      "utc_offset_seconds": { "type": "integer" },
      "duration_minutes":   { "type": "integer" },
      "type":         { "type": "keyword" },
      "create_time":  { "type": "date" },
      "update_time":  { "type": "date" },
      "summary": { "properties": {
        "minutes_asleep":          { "type": "integer" },
        "minutes_awake":           { "type": "integer" },
        "minutes_in_sleep_period": { "type": "integer" },
        "minutes_to_fall_asleep":  { "type": "integer" },
        "minutes_after_wake_up":   { "type": "integer" },
        "stages": { "properties": {
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
}'
echo

echo "== index: fitbit-activities =="
create_index fitbit-activities '{
  "mappings": {
    "properties": {
      "@timestamp":   { "type": "date" },
      "end_time":     { "type": "date" },
      "user_id":      { "type": "keyword" },
      "utc_offset_seconds": { "type": "integer" },
      "exercise_type": { "type": "keyword" },
      "display_name":  { "type": "keyword" },
      "active_duration_seconds": { "type": "integer" },
      "create_time":  { "type": "date" },
      "update_time":  { "type": "date" },
      "metrics": { "properties": {
        "calories_kcal":      { "type": "float" },
        "distance_meters":    { "type": "float" },
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
}'
echo
echo "Done."
