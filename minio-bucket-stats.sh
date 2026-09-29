#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.0"
TOP_N=15
NO_OBJECTS=false
TRAFFIC_ONLY=false
JSON_OUTPUT=false

usage() {
cat <<EOF
MinIO Bucket Statistics v${VERSION}

Gebruik:
  $(basename "$0") [opties] <alias> <bucket>

Opties:
  -h, --help           Toon deze helptekst
  -t, --top N          Toon de N grootste objecten (standaard: 15)
      --no-objects     Sla recursieve objectanalyse over
      --traffic-only   Toon alleen API-/trafficstatistieken
      --json           Geef machine-leesbare JSON-output
      --version        Toon scriptversie
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

human_bytes() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || printf '%s B' "${1:-0}"
  else
    printf '%s B' "${1:-0}"
  fi
}

line() { printf '%*s\n' 78 '' | tr ' ' '='; }
section() { echo; line; echo "$1"; line; }

metric_sum() {
  awk -v metric="$1" '$0 !~ /^#/ && $1 ~ "^"metric"({|$)" {sum += $NF} END {printf "%.0f",sum+0}' "$2"
}
metric_api() {
  awk -v api="$1" '$0 !~ /^#/ && $1 ~ /^minio_bucket_api_total/ && $0 ~ "api=\""api"\"" {sum += $NF} END {printf "%.0f",sum+0}' "$2"
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    -t|--top) [[ $# -ge 2 ]] || die "--top vereist een getal."; TOP_N="$2"; shift 2 ;;
    --no-objects) NO_OBJECTS=true; shift ;;
    --traffic-only) TRAFFIC_ONLY=true; NO_OBJECTS=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done ;;
    -*) die "Onbekende optie: $1. Gebruik --help." ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

[[ ${#ARGS[@]} -eq 2 ]] || { usage >&2; exit 2; }
ALIAS="${ARGS[0]}"
BUCKET="${ARGS[1]}"
TARGET="${ALIAS}/${BUCKET}"
[[ "$TOP_N" =~ ^[1-9][0-9]*$ ]] || die "--top moet een positief geheel getal zijn."

for cmd in mc jq; do command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is niet geïnstalleerd."; done
mc stat "$TARGET" >/dev/null 2>&1 || die "Bucket '$TARGET' kan niet worden benaderd."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
OBJECTS="$TMPDIR/objects.jsonl"
METRICS="$TMPDIR/metrics.txt"
GENERATED="$(date -Is)"

OBJECT_COUNT=0 TOTAL_BYTES=0 AVG_BYTES=0 MIN_BYTES=0 MAX_BYTES=0
METRICS_AVAILABLE=false RECEIVED=0 SENT=0 ERR4=0 ERR5=0
declare -A API_COUNTS
APIS=(GetObject PutObject DeleteObject HeadObject ListObjects ListObjectsV2 CopyObject CompleteMultipartUpload CreateMultipartUpload)

if mc admin prometheus metrics "$ALIAS" api --bucket "$BUCKET" --api-version v3 >"$METRICS" 2>/dev/null; then
  METRICS_AVAILABLE=true
  RECEIVED="$(metric_sum minio_bucket_api_traffic_received_bytes "$METRICS")"
  SENT="$(metric_sum minio_bucket_api_traffic_sent_bytes "$METRICS")"
  ERR4="$(metric_sum minio_bucket_api_4xx_errors_total "$METRICS")"
  ERR5="$(metric_sum minio_bucket_api_5xx_errors_total "$METRICS")"
  for api in "${APIS[@]}"; do API_COUNTS["$api"]="$(metric_api "$api" "$METRICS")"; done
fi

if ! $NO_OBJECTS; then
  mc ls --recursive --json "$TARGET" >"$OBJECTS" || die "Objectinventarisatie is mislukt."
  OBJECT_COUNT="$(jq -s '[.[]|select((.size?|type)=="number")]|length' "$OBJECTS")"
  TOTAL_BYTES="$(jq -s '[.[]|select((.size?|type)=="number")|.size]|add//0' "$OBJECTS")"
  if (( OBJECT_COUNT > 0 )); then
    AVG_BYTES="$(jq -s '[.[]|select((.size?|type)=="number")|.size]|((add//0)/length|floor)' "$OBJECTS")"
    MIN_BYTES="$(jq -s '[.[]|select((.size?|type)=="number")|.size]|min//0' "$OBJECTS")"
    MAX_BYTES="$(jq -s '[.[]|select((.size?|type)=="number")|.size]|max//0' "$OBJECTS")"
  fi
fi

if $JSON_OUTPUT; then
  if ! $NO_OBJECTS; then
    largest="$(jq -s --argjson n "$TOP_N" '[.[]|select((.size?|type)=="number")|{key:(.key//.name//"<unknown>"),size_bytes:.size}]|sort_by(.size_bytes)|reverse|.[:$n]' "$OBJECTS")"
    prefixes="$(jq -s '[.[]|select((.size?|type)=="number")|{key:(.key//.name//""),size:.size}]|group_by(.key|split("/")[0])|map({prefix:(.[0].key|split("/")[0]),objects:length,size_bytes:(map(.size)|add//0)})|sort_by(.size_bytes)|reverse' "$OBJECTS")"
  else largest='[]'; prefixes='[]'; fi

  api_json="$(for api in "${APIS[@]}"; do printf '%s\t%s\n' "$api" "${API_COUNTS[$api]:-0}"; done | jq -Rn '[inputs|split("\t")|{key:.[0],value:(.[1]|tonumber)}]|from_entries')"
  jq -n --arg version "$VERSION" --arg generated "$GENERATED" --arg alias "$ALIAS" --arg bucket "$BUCKET" \
    --argjson object_analysis "$($NO_OBJECTS && echo false || echo true)" \
    --argjson metrics_available "$($METRICS_AVAILABLE && echo true || echo false)" \
    --argjson count "$OBJECT_COUNT" --argjson total "$TOTAL_BYTES" --argjson avg "$AVG_BYTES" \
    --argjson min "$MIN_BYTES" --argjson max "$MAX_BYTES" --argjson received "$RECEIVED" \
    --argjson sent "$SENT" --argjson err4 "$ERR4" --argjson err5 "$ERR5" \
    --argjson apis "$api_json" --argjson largest "$largest" --argjson prefixes "$prefixes" \
    '{script_version:$version,generated:$generated,alias:$alias,bucket:$bucket,object_analysis:$object_analysis,
      storage:{object_count:$count,total_bytes:$total,average_object_bytes:$avg,smallest_object_bytes:$min,largest_object_bytes:$max},
      traffic:{metrics_available:$metrics_available,received_bytes:$received,sent_bytes:$sent,errors_4xx:$err4,errors_5xx:$err5,api_requests:$apis},
      largest_objects:$largest,top_level_prefixes:$prefixes}'
  exit 0
fi

line
echo " MINIO BUCKET STATISTICS v$VERSION"
line
printf "Server alias : %s\nBucket       : %s\nGenerated    : %s\n" "$ALIAS" "$BUCKET" "$GENERATED"

if ! $TRAFFIC_ONLY; then
  section "BUCKET INFORMATION"; mc stat "$TARGET" || true
  section "STORAGE USAGE"; mc du "$TARGET" || true
  echo; echo "Inclusief versions:"; mc du --versions "$TARGET" 2>/dev/null || echo "Niet beschikbaar / onvoldoende rechten."

  if ! $NO_OBJECTS; then
    section "OBJECT STATISTICS"
    printf "%-30s %s\n" "Aantal objecten:" "$OBJECT_COUNT"
    printf "%-30s %s\n" "Totale logische grootte:" "$(human_bytes "$TOTAL_BYTES")"
    printf "%-30s %s\n" "Gemiddelde objectgrootte:" "$(human_bytes "$AVG_BYTES")"
    printf "%-30s %s\n" "Kleinste object:" "$(human_bytes "$MIN_BYTES")"
    printf "%-30s %s\n" "Grootste object:" "$(human_bytes "$MAX_BYTES")"

    section "TOP $TOP_N LARGEST OBJECTS"
    jq -r -s --argjson n "$TOP_N" '[.[]|select((.size?|type)=="number")|{key:(.key//.name//"<unknown>"),size:.size}]|sort_by(.size)|reverse|.[:$n]|.[]|[.size,.key]|@tsv' "$OBJECTS" |
      while IFS=$'\t' read -r size key; do printf "%12s   %s\n" "$(human_bytes "$size")" "$key"; done

    section "TOP-LEVEL PREFIX USAGE"
    jq -r -s '[.[]|select((.size?|type)=="number")|{key:(.key//.name//""),size:.size}]|group_by(.key|split("/")[0])|map({prefix:(.[0].key|split("/")[0]),objects:length,bytes:(map(.size)|add//0)})|sort_by(.bytes)|reverse|.[]|[.bytes,.objects,.prefix]|@tsv' "$OBJECTS" |
      while IFS=$'\t' read -r bytes count prefix; do [[ -z "$prefix" ]] && prefix="<root>"; printf "%12s   %10s objects   %s\n" "$(human_bytes "$bytes")" "$count" "$prefix"; done
  else
    section "OBJECT ANALYSIS"; echo "Overgeslagen (--no-objects)."
  fi

  section "VERSIONING"; mc version info "$TARGET" 2>/dev/null || echo "Niet beschikbaar."
  section "LIFECYCLE / ILM"; mc ilm rule ls "$TARGET" 2>/dev/null || echo "Geen regels of onvoldoende rechten."
  section "BUCKET QUOTA"; mc quota info "$TARGET" 2>/dev/null || echo "Geen quota of onvoldoende rechten."
fi

section "API / TRAFFIC STATISTICS"
if $METRICS_AVAILABLE; then
  printf "%-30s %s\n" "Data ontvangen:" "$(human_bytes "$RECEIVED")"
  printf "%-30s %s\n" "Data verzonden:" "$(human_bytes "$SENT")"
  printf "%-30s %s\n" "4xx errors:" "$ERR4"
  printf "%-30s %s\n" "5xx errors:" "$ERR5"
  echo; echo "API requests:"
  for api in "${APIS[@]}"; do printf "%-35s %12s\n" "$api" "${API_COUNTS[$api]:-0}"; done
else
  echo "Prometheus/API metrics konden niet worden opgehaald."
  echo "Controleer adminrechten en ondersteuning voor MinIO metrics v3."
fi
