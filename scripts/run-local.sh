#!/usr/bin/env bash
#
# run-local.sh — run the full security gate locally using Docker.
#
# What it does:
#   1. Starts OWASP Juice Shop (docker compose) and waits until it is healthy.
#   2. Runs Gitleaks (secret scanning) against this repo.
#   3. Runs Trivy (HIGH/CRITICAL vulnerabilities) against this repo.
#   4. Runs the OWASP ZAP baseline scan against Juice Shop.
#   5. Prints a PASS/FAIL summary and leaves reports in ./reports/.
#
# Requirements: Docker Engine with the compose plugin (Docker Desktop counts).
# No credentials needed. First run takes a few minutes: Docker pulls the
# Juice Shop image and the scanner images, and Trivy downloads its
# vulnerability database once (cached in a Docker volume afterwards).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORTS_DIR="$PROJECT_DIR/reports"
TARGET_URL="http://localhost:3000"

# ":latest" is used so this script works out of the box; pin versions here
# for reproducible runs, e.g. GITLEAKS_IMAGE="zricethezav/gitleaks:v8.28.0".
GITLEAKS_IMAGE="zricethezav/gitleaks:latest"
TRIVY_IMAGE="aquasec/trivy:latest"
ZAP_IMAGE="ghcr.io/zaproxy/zaproxy:stable"

pass_fail() {
  if [ "$1" -eq 0 ]; then printf 'PASS'; else printf 'FAIL (exit %s)' "$1"; fi
}

cd "$PROJECT_DIR"
mkdir -p "$REPORTS_DIR"

echo "=================================================================="
echo " Security Gate — local run"
echo " Target : $TARGET_URL (OWASP Juice Shop)"
echo " Reports: $REPORTS_DIR"
echo "=================================================================="
echo

echo "==> [1/4] Starting OWASP Juice Shop ..."
docker compose up -d juice-shop

echo "==> Waiting for Juice Shop to become healthy ..."
HEALTHY=0
for i in $(seq 1 36); do
  if curl -fsS "$TARGET_URL/" > /dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 5
done
if [ "$HEALTHY" -ne 1 ]; then
  echo "ERROR: Juice Shop did not become healthy in time." >&2
  docker compose logs --tail 50 juice-shop
  exit 1
fi
echo "    Juice Shop is up at $TARGET_URL"
echo

echo "==> [2/4] Secret scan (Gitleaks) ..."
set +e
docker run --rm \
  -v "$PROJECT_DIR:/path" \
  "$GITLEAKS_IMAGE" detect \
    --source=/path --no-git -v \
    --report-format=json --report-path=/path/reports/gitleaks.json
GITLEAKS_EXIT=$?
set -e
echo

echo "==> [3/4] Dependency scan (Trivy, HIGH/CRITICAL) ..."
set +e
docker run --rm \
  -v "$PROJECT_DIR:/path" \
  -v trivy-cache:/root/.cache/ \
  "$TRIVY_IMAGE" fs \
    --severity HIGH,CRITICAL \
    --exit-code 1 \
    --format json --output /path/reports/trivy.json \
    /path
TRIVY_EXIT=$?
set -e
echo

echo "==> [4/4] DAST baseline scan (OWASP ZAP) ..."
chmod 777 "$REPORTS_DIR"
set +e
docker run --rm \
  --network secgate \
  -v "$PROJECT_DIR/zap:/zap/wrk:ro" \
  -v "$REPORTS_DIR:/zap/reports" \
  "$ZAP_IMAGE" \
  zap-baseline.py \
    -t http://juice-shop:3000 \
    -c /zap/wrk/rules.tsv \
    -r /zap/reports/zap-baseline.html \
    -J /zap/reports/zap-baseline.json \
    -a
ZAP_EXIT=$?
set -e
echo

if [ "$ZAP_EXIT" -eq 1 ] || [ "$ZAP_EXIT" -eq 3 ]; then
  ZAP_STATUS="FAIL (HIGH-risk findings or scan error, exit $ZAP_EXIT)"
  ZAP_GATE=1
elif [ "$ZAP_EXIT" -eq 2 ]; then
  ZAP_STATUS="PASS with warnings (exit 2)"
  ZAP_GATE=0
else
  ZAP_STATUS="PASS"
  ZAP_GATE=0
fi

echo "=================================================================="
echo " SECURITY GATE SUMMARY"
echo "=================================================================="
printf '  %-28s %s\n' "Gitleaks (secrets):" "$(pass_fail "$GITLEAKS_EXIT")"
printf '  %-28s %s\n' "Trivy (HIGH/CRITICAL):" "$(pass_fail "$TRIVY_EXIT")"
printf '  %-28s %s\n' "ZAP baseline (DAST):" "$ZAP_STATUS"
echo "------------------------------------------------------------------"
echo "  Reports in $REPORTS_DIR:"
ls -1 "$REPORTS_DIR"
echo "=================================================================="

OVERALL=0
if [ "$GITLEAKS_EXIT" -ne 0 ]; then OVERALL=1; fi
if [ "$TRIVY_EXIT" -ne 0 ]; then OVERALL=1; fi
if [ "$ZAP_GATE" -ne 0 ]; then OVERALL=1; fi

if [ "$OVERALL" -ne 0 ]; then
  echo "RESULT: FAIL — address the findings above, then re-run ./scripts/run-local.sh"
  echo "(Tip: stop Juice Shop with: docker compose down)"
  exit 1
fi
echo "RESULT: PASS — security gate is green."
echo "(Tip: stop Juice Shop with: docker compose down)"
