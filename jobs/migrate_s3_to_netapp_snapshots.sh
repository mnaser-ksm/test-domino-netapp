#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# S3 -> NetApp Volume -> NetApp Snapshot (Domino RemoteFS)
# RemoteFS API base (from your Swagger):
#   https://ksm.domino.tech/remotefs/v1
#
# What this does:
#  1) aws s3 sync  s3://$S3_BUCKET/$S3_PREFIX  ->  $NETAPP_VOLUME_DIR/$DEST_SUBDIR
#  2) create a RemoteFS snapshot of the NetApp volume
#  3) optionally tag the snapshot
#
# Required env vars:
#   S3_BUCKET
#   NETAPP_VOLUME_DIR
#   DOMINO_BASE_URL          (e.g., https://ksm.domino.tech)
#   DOMINO_USER_API_KEY
#   NETAPP_VOLUME_ID         (recommended; e.g., 17866703-d866-4ec2-a5d6-16f6b8c8a3f9)
#
# Optional env vars:
#   S3_PREFIX (default sdtm/)
#   DEST_SUBDIR (default sdtm)
#   SNAPSHOT_TAG
#   LOG_DIR
#   RUN_ID
# ==========================================================

# --- REQUIRED INPUTS ---
: "${S3_BUCKET:?Must set S3_BUCKET (e.g., migration-demo-bucket-12345)}"
: "${NETAPP_VOLUME_DIR:?Must set NETAPP_VOLUME_DIR (e.g., /mnt/netapp-volumes/test_netapp)}"
: "${DOMINO_BASE_URL:?Must set DOMINO_BASE_URL (e.g., https://ksm.domino.tech)}"
: "${DOMINO_USER_API_KEY:?Must set DOMINO_USER_API_KEY (Domino user API key)}"
: "${NETAPP_VOLUME_ID:?Must set NETAPP_VOLUME_ID (e.g., 17866703-d866-4ec2-a5d6-16f6b8c8a3f9)}"

# --- OPTIONAL INPUTS ---
S3_PREFIX="${S3_PREFIX:-sdtm/}"
DEST_SUBDIR="${DEST_SUBDIR:-sdtm}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-}"                           # e.g., mig-latest
NETAPP_VOLUME_DIR="${NETAPP_VOLUME_DIR%/}"                 # strip trailing slash
LOG_DIR="${LOG_DIR:-$NETAPP_VOLUME_DIR/logs}"

# Avoid AWS CLI pager errors (less not installed)
export AWS_PAGER=""

# Normalize S3 prefix to always end with /
[[ "$S3_PREFIX" == */ ]] || S3_PREFIX="${S3_PREFIX}/"

SRC="s3://${S3_BUCKET}/${S3_PREFIX}"
DEST="${NETAPP_VOLUME_DIR}/${DEST_SUBDIR}"
LOG_FILE="${LOG_DIR}/migrate_${DEST_SUBDIR}_${RUN_ID}.log"

REMOTEFS_BASE="${DOMINO_BASE_URL%/}/remotefs/v1"
API_KEY_HEADER="X-Domino-Api-Key: ${DOMINO_USER_API_KEY}"
JSON_HEADER="Content-Type: application/json"
ACCEPT_HEADER="accept: application/json"

# Guard: destination mount must exist
if [[ ! -d "$NETAPP_VOLUME_DIR" ]]; then
  echo "ERROR: NETAPP_VOLUME_DIR does not exist: $NETAPP_VOLUME_DIR"
  echo "Check that the NetApp volume is mounted in this job/workspace."
  exit 1
fi

mkdir -p "$DEST" "$LOG_DIR"

echo "=== Migration Job: S3 -> NetApp Volume + Snapshot ===" | tee "$LOG_FILE"
echo "Time (UTC): $(date -u)" | tee -a "$LOG_FILE"
echo "S3 Source: $SRC" | tee -a "$LOG_FILE"
echo "NetApp Destination: $DEST" | tee -a "$LOG_FILE"
echo "RemoteFS API Base: $REMOTEFS_BASE" | tee -a "$LOG_FILE"
echo "NETAPP_VOLUME_ID: $NETAPP_VOLUME_ID" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Checking AWS identity..." | tee -a "$LOG_FILE"
aws sts get-caller-identity | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Listing S3 prefix (recursive)..." | tee -a "$LOG_FILE"
aws s3 ls "$SRC" --recursive | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Starting sync..." | tee -a "$LOG_FILE"
SYNC_OUT="$(mktemp)"
aws s3 sync "$SRC" "$DEST/" --exact-timestamps --only-show-errors | tee -a "$SYNC_OUT" | tee -a "$LOG_FILE"
if [[ ! -s "$SYNC_OUT" ]]; then
  echo "Sync finished: no changes detected (nothing copied)." | tee -a "$LOG_FILE"
else
  echo "Sync finished: changes applied (see lines above)." | tee -a "$LOG_FILE"
fi
rm -f "$SYNC_OUT"
echo "" | tee -a "$LOG_FILE"

echo "Validating destination..." | tee -a "$LOG_FILE"
echo "File count:" | tee -a "$LOG_FILE"
find "$DEST" -type f | wc -l | tee -a "$LOG_FILE"
echo "Size:" | tee -a "$LOG_FILE"
du -sh "$DEST" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# -----------------------
# Create Snapshot (RemoteFS)
# -----------------------
SNAPSHOT_NAME="migration_${DEST_SUBDIR}_${RUN_ID}"
CREATE_BODY="$(python3 - <<PY
import json
print(json.dumps({
  "volumeId": "$NETAPP_VOLUME_ID",
  "name": "$SNAPSHOT_NAME"
}))
PY
)"

echo "Creating snapshot..." | tee -a "$LOG_FILE"
RESP="$(curl -sS -w "\nHTTP_STATUS:%{http_code}\n" -X POST \
  -H "$API_KEY_HEADER" -H "$JSON_HEADER" -H "$ACCEPT_HEADER" \
  -d "$CREATE_BODY" \
  "$REMOTEFS_BASE/snapshots" || true)"

HTTP_STATUS="$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')"
BODY="$(echo "$RESP" | sed '/^HTTP_STATUS:/d')"

echo "Snapshot create HTTP status: $HTTP_STATUS" | tee -a "$LOG_FILE"

if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  echo "ERROR: Snapshot create failed. Response body (first 2000 chars):" | tee -a "$LOG_FILE"
  echo "$BODY" | head -c 2000 | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  exit 1
fi

# Extract snapshot id robustly (avoid JSONDecodeError issues)
SNAPSHOT_ID="$(printf '%s' "$BODY" | tr -d '\r\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)"

if [[ -z "$SNAPSHOT_ID" ]]; then
  echo "ERROR: Snapshot creation returned an unexpected response (could not extract id)." | tee -a "$LOG_FILE"
  echo "$BODY" | tee -a "$LOG_FILE"
  exit 1
fi


echo "Snapshot created: name=$SNAPSHOT_NAME id=$SNAPSHOT_ID" | tee -a "$LOG_FILE"

# -----------------------
# Optional: Tag Snapshot
# -----------------------
if [[ -n "$SNAPSHOT_TAG" ]]; then
  echo "Tagging snapshot with: $SNAPSHOT_TAG" | tee -a "$LOG_FILE"

  TAG_RESP="$(curl -sS -w "\nHTTP_STATUS:%{http_code}\n" -X POST \
    -H "$API_KEY_HEADER" -H "$JSON_HEADER" -H "$ACCEPT_HEADER" \
    -d "{\"name\":\"$SNAPSHOT_TAG\"}" \
    "$REMOTEFS_BASE/snapshots/$SNAPSHOT_ID/tags" || true)"

  TAG_STATUS="$(echo "$TAG_RESP" | sed -n 's/^HTTP_STATUS://p')"
  TAG_BODY="$(echo "$TAG_RESP" | sed '/^HTTP_STATUS:/d')"

  echo "Snapshot tag HTTP status: $TAG_STATUS" | tee -a "$LOG_FILE"

  if [[ "$TAG_STATUS" != "200" && "$TAG_STATUS" != "201" && "$TAG_STATUS" != "204" ]]; then
    echo "ERROR: Tagging failed. Response body (first 2000 chars):" | tee -a "$LOG_FILE"
    echo "$TAG_BODY" | head -c 2000 | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    exit 1
  fi

  echo "Tag added." | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "Done. Log written to: $LOG_FILE" | tee -a "$LOG_FILE"
