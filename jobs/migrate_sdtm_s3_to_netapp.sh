#!/usr/bin/env bash
set -euo pipefail

# --- REQUIRED INPUTS ---
: "${S3_BUCKET:?Must set S3_BUCKET (e.g., migration-demo-bucket-12345)}"
: "${NETAPP_VOLUME_DIR:?Must set NETAPP_VOLUME_DIR (e.g., /mnt/netapp-volumes/test_netapp)}"

# --- OPTIONAL INPUTS ---
S3_PREFIX="${S3_PREFIX:-sdtm/}"          # default: sdtm/
DEST_SUBDIR="${DEST_SUBDIR:-sdtm}"       # default: sdtm
LOG_DIR="${LOG_DIR:-$NETAPP_VOLUME_DIR/logs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

# Avoid AWS CLI pager errors (less not installed)
export AWS_PAGER=""

SRC="s3://${S3_BUCKET}/${S3_PREFIX}"
DEST="${NETAPP_VOLUME_DIR}/${DEST_SUBDIR}"
LOG_FILE="${LOG_DIR}/migrate_${DEST_SUBDIR}_${RUN_ID}.log"

mkdir -p "$DEST" "$LOG_DIR"

echo "=== SDTM Migration Job ===" | tee "$LOG_FILE"
echo "Time (UTC): $(date -u)" | tee -a "$LOG_FILE"
echo "Source: $SRC" | tee -a "$LOG_FILE"
echo "Destination: $DEST" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Checking AWS identity..." | tee -a "$LOG_FILE"
aws sts get-caller-identity | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Listing S3 prefix (top-level)..." | tee -a "$LOG_FILE"
aws s3 ls "$SRC" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Starting sync..." | tee -a "$LOG_FILE"
aws s3 sync "$SRC" "$DEST" --only-show-errors | tee -a "$LOG_FILE"
echo "Sync complete." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Validating destination..." | tee -a "$LOG_FILE"
echo "File count:" | tee -a "$LOG_FILE"
find "$DEST" -type f | wc -l | tee -a "$LOG_FILE"
echo "Size:" | tee -a "$LOG_FILE"
du -sh "$DEST" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "Done. Log written to: $LOG_FILE" | tee -a "$LOG_FILE"
