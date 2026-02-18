#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# REQUIRED INPUTS
# -----------------------
: "${S3_BUCKET:?Must set S3_BUCKET (e.g., migration-demo-bucket-12345)}"
: "${NETAPP_VOLUME_DIR:?Must set NETAPP_VOLUME_DIR (e.g., /mnt/netapp-volumes/test_netapp)}"

: "${DOMINO_BASE_URL:?Must set DOMINO_BASE_URL (e.g., https://ksm.domino.tech)}"
: "${DOMINO_USER_API_KEY:?Must set DOMINO_USER_API_KEY (Domino user API key)}"
: "${NETAPP_VOLUME_UNIQUE_NAME:?Must set NETAPP_VOLUME_UNIQUE_NAME (e.g., test_netapp)}"

# -----------------------
# OPTIONAL INPUTS
# -----------------------
S3_PREFIX="${S3_PREFIX:-sdtm/}"                 # default: sdtm/
DEST_SUBDIR="${DEST_SUBDIR:-sdtm}"              # default: sdtm
SNAPSHOT_TAG="${SNAPSHOT_TAG:-}"                # e.g. latest, mig-20260218
SNAPSHOT_MESSAGE="${SNAPSHOT_MESSAGE:-S3 sync}" # commit message (NetApp volumes support this)
LOG_DIR="${LOG_DIR:-$NETAPP_VOLUME_DIR/logs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

# Avoid AWS CLI pager issues
export AWS_PAGER=""

SRC="s3://${S3_BUCKET}/${S3_PREFIX}"
DEST="${NETAPP_VOLUME_DIR}/${DEST_SUBDIR}"
LOG_FILE="${LOG_DIR}/migrate_${DEST_SUBDIR}_${RUN_ID}.log"

mkdir -p "$DEST" "$LOG_DIR"

echo "=== SDTM Migration Job (S3 -> NetApp Volume) ===" | tee "$LOG_FILE"
echo "Time (UTC): $(date -u)" | tee -a "$LOG_FILE"
echo "Source: $SRC" | tee -a "$LOG_FILE"
echo "Destination: $DEST" | tee -a "$LOG_FILE"
echo "NetApp Volume Unique Name: $NETAPP_VOLUME_UNIQUE_NAME" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Checking AWS identity..." | tee -a "$LOG_FILE"
aws sts get-caller-identity | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Listing S3 prefix (recursive)..." | tee -a "$LOG_FILE"
aws s3 ls "$SRC" --recursive | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Starting sync..." | tee -a "$LOG_FILE"
aws s3 sync "$SRC" "$DEST" --exact-timestamps | tee -a "$LOG_FILE"
echo "Sync complete." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Validating destination..." | tee -a "$LOG_FILE"
echo "File count:" | tee -a "$LOG_FILE"
find "$DEST" -type f | wc -l | tee -a "$LOG_FILE"
echo "Size:" | tee -a "$LOG_FILE"
du -sh "$DEST" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# -----------------------
# SNAPSHOT (NetApp Volume)
# -----------------------
# The NetApp Volumes API provides /volumes and /snapshots endpoints. :contentReference[oaicite:2]{index=2}
# Auth header for Domino API key is X-Domino-Api-Key. :contentReference[oaicite:3]{index=3}

API_KEY_HEADER="X-Domino-Api-Key: ${DOMINO_USER_API_KEY}"
JSON_HEADER="Content-Type: application/json"

echo "Creating NetApp Volume snapshot via Domino NetApp Volumes API..." | tee -a "$LOG_FILE"

# 1) Lookup Volume ID by unique name
VOLUME_JSON="$(curl -fsS \
  -H "$API_KEY_HEADER" \
  "${DOMINO_BASE_URL}/volumes/unique-name/${NETAPP_VOLUME_UNIQUE_NAME}")"

# Parse volume id without jq (works everywhere)
VOLUME_ID="$(python3 - <<'PY'
import json,sys
obj=json.loads(sys.stdin.read())
# Most Domino APIs return 'id' at top-level for volume objects
print(obj.get("id",""))
PY
<<< "$VOLUME_JSON")"

if [[ -z "$VOLUME_ID" ]]; then
  echo "ERROR: Could not resolve volume id from /volumes/unique-name/${NETAPP_VOLUME_UNIQUE_NAME}" | tee -a "$LOG_FILE"
  echo "Response was: $VOLUME_JSON" | tee -a "$LOG_FILE"
  exit 1
fi

SNAPSHOT_NAME="migration_${DEST_SUBDIR}_${RUN_ID}"

# 2) Create snapshot
# NOTE: Field names can vary slightly by Domino version. If your instance returns 400,
# open your Domino Swagger UI for the NetApp Volumes API and copy the exact request body. :contentReference[oaicite:4]{index=4}
SNAPSHOT_CREATE_BODY="$(python3 - <<PY
import json
print(json.dumps({
  "volumeId": "${VOLUME_ID}",
  "name": "${SNAPSHOT_NAME}",
  "commitMessage": "${SNAPSHOT_MESSAGE}"
}))
PY
)"

SNAPSHOT_JSON="$(curl -fsS -X POST \
  -H "$API_KEY_HEADER" -H "$JSON_HEADER" \
  -d "$SNAPSHOT_CREATE_BODY" \
  "${DOMINO_BASE_URL}/snapshots")"

SNAPSHOT_ID="$(python3 - <<'PY'
import json,sys
obj=json.loads(sys.stdin.read())
print(obj.get("id",""))
PY
<<< "$SNAPSHOT_JSON")"

if [[ -z "$SNAPSHOT_ID" ]]; then
  echo "ERROR: Snapshot creation returned no snapshot id." | tee -a "$LOG_FILE"
  echo "Response was: $SNAPSHOT_JSON" | tee -a "$LOG_FILE"
  exit 1
fi

echo "Snapshot created: name=${SNAPSHOT_NAME}, id=${SNAPSHOT_ID}" | tee -a "$LOG_FILE"

# 3) Optional: add a tag (so you can mount/use by tag later)
# Endpoint exists: /snapshots/{id}/tags :contentReference[oaicite:5]{index=5}
if [[ -n "$SNAPSHOT_TAG" ]]; then
  TAG_BODY="$(python3 - <<PY
import json
print(json.dumps({"name":"${SNAPSHOT_TAG}"}))
PY
)"
  curl -fsS -X POST \
    -H "$API_KEY_HEADER" -H "$JSON_HEADER" \
    -d "$TAG_BODY" \
    "${DOMINO_BASE_URL}/snapshots/${SNAPSHOT_ID}/tags" >/dev/null

  echo "Tag added: ${SNAPSHOT_TAG}" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "Done. Log written to: $LOG_FILE" | tee -a "$LOG_FILE"
