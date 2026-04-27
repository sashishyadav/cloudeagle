#!/bin/bash
# =============================================================================
# smoke-test.sh
# -----------------------------------------------------------------------------
# Post-deploy health check. Fails (exit 1) if any check doesn't pass, which
# triggers automatic rollback in the Jenkins pipeline.
#
# Usage:
#   ./smoke-test.sh <environment>
# =============================================================================

set -uo pipefail

ENVIRONMENT="${1:?Environment required}"

declare -A ENDPOINTS=(
    [qa]="http://sync-service-qa.internal:8080"
    [staging]="http://sync-service-staging.internal:8080"
    [prod]="http://sync-service-prod.internal:8080"
)

BASE_URL="${ENDPOINTS[$ENVIRONMENT]:?Unknown environment: $ENVIRONMENT}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Smoke Test"
echo "  Environment : $ENVIRONMENT"
echo "  Base URL    : $BASE_URL"
echo "═══════════════════════════════════════════════════════════════"

FAILED=0

check() {
    local name="$1" url="$2" expected="$3"
    local actual
    actual=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")

    if [ "$actual" = "$expected" ]; then
        echo "  ✅ $name ($actual)"
    else
        echo "  ❌ $name (expected $expected, got $actual)"
        FAILED=$((FAILED + 1))
    fi
}

check_json_field() {
    local name="$1" url="$2" field="$3" expected="$4"
    local actual
    actual=$(curl -s --max-time 10 "$url" 2>/dev/null | jq -r "$field" 2>/dev/null || echo "ERROR")

    if [ "$actual" = "$expected" ]; then
        echo "  ✅ $name ($field = $actual)"
    else
        echo "  ❌ $name ($field: expected $expected, got $actual)"
        FAILED=$((FAILED + 1))
    fi
}

echo ""
echo "▸ Basic health checks"

# Retry the initial liveness check 10x (app may still be warming up)
for i in $(seq 1 10); do
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "${BASE_URL}/actuator/health/liveness" 2>/dev/null || echo "000")
    [ "$STATUS" = "200" ] && break
    echo "  ⋯ Liveness attempt $i/10 — HTTP $STATUS (retrying)"
    sleep 6
done

check       "Liveness"    "${BASE_URL}/actuator/health/liveness"   "200"
check       "Readiness"   "${BASE_URL}/actuator/health/readiness"  "200"
check_json_field "Health"  "${BASE_URL}/actuator/health"            ".status" "UP"

echo ""
echo "▸ Application-level checks"

check       "Info endpoint"  "${BASE_URL}/actuator/info"      "200"
check       "Metrics"        "${BASE_URL}/actuator/metrics"   "200"

echo ""
echo "▸ MongoDB connectivity (via health component)"

check_json_field "MongoDB health" \
    "${BASE_URL}/actuator/health" \
    ".components.mongo.status" \
    "UP"

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
    echo "✅ All smoke tests passed"
    exit 0
else
    echo "❌ $FAILED smoke test(s) failed — deploy will be rolled back"
    exit 1
fi
