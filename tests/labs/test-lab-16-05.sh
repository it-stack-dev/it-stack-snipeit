#!/usr/bin/env bash
# test-lab-16-05.sh — Lab 16-05: Advanced Integration
# Module 16: Snipe-IT IT asset management
# snipeit integrated with full IT-Stack ecosystem
set -euo pipefail

LAB_ID="16-05"
LAB_NAME="Advanced Integration"
MODULE="snipeit"
COMPOSE_FILE="docker/docker-compose.integration.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
APP_PORT=8441
MOCK_PORT=8762
KC_PORT=8541
LDAP_PORT=3886
MH_PORT=8741
MOCK_URL="http://localhost:${MOCK_PORT}"

APP_CONTAINER="snipeit-i05-app"
MOCK_CONTAINER="snipeit-i05-mock"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for Snipe-IT stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker ps --format '{{.Names}}' | grep -q "^${APP_CONTAINER}$"; then
  pass "Snipe-IT app container running"
else
  fail "Snipe-IT app container not running"
fi

if docker ps --format '{{.Names}}' | grep -q "^${MOCK_CONTAINER}$"; then
  pass "WireMock container running"
else
  fail "WireMock container not running"
fi

# App health
if curl -sf "http://localhost:${APP_PORT}/" > /dev/null 2>&1; then
  pass "Snipe-IT web interface responds"
else
  warn "Snipe-IT web interface not yet ready"
fi

# WireMock health
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
if curl -sf "http://localhost:${KC_PORT}/realms/master" > /dev/null 2>&1; then
  pass "Keycloak master realm accessible"
else
  warn "Keycloak not yet ready"
fi

# LDAP
if ldapsearch -x -H ldap://localhost:${LDAP_PORT} -b dc=lab,dc=local \
     -D cn=admin,dc=lab,dc=local -w LdapLab05! cn=admin > /dev/null 2>&1; then
  pass "OpenLDAP bind successful"
else
  warn "OpenLDAP bind failed"
fi

# ── PHASE 3: Integration Tests ────────────────────────────────────────────────
info "Phase 3: Integration Tests (Odoo REST API via WireMock)"

# 3a: Register Odoo REST API stub (asset procurement)
info "3a: Registering Odoo /web/dataset/call_kw stub..."
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/web/dataset/call_kw"},
    "response": {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":101,\"name\":\"Laptop Pro\",\"model\":\"stock.inventory\",\"state\":\"done\"}]}"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Odoo /web/dataset/call_kw stub registered (201)"
else
  fail "WireMock Odoo stub registration failed (HTTP ${HTTP_STATUS})"
fi

# Register Odoo authenticate stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/web/session/authenticate"},
    "response": {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"uid\":1,\"db\":\"odoo\",\"session_id\":\"lab-session-05\"}}"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Odoo /web/session/authenticate stub registered"
else
  fail "WireMock Odoo authenticate stub failed (HTTP ${HTTP_STATUS})"
fi

# 3b: Verify Odoo API mock responds
if curl -sf -X POST "${MOCK_URL}/web/dataset/call_kw" \
     -H "Content-Type: application/json" \
     -d '{"model":"stock.inventory","method":"search_read","args":[],"kwargs":{}}' | grep -q 'Laptop Pro'; then
  pass "WireMock Odoo /web/dataset/call_kw returns asset JSON"
else
  fail "WireMock Odoo call_kw returned unexpected response"
fi

# 3c: Integration env vars in app container
if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q 'ODOO_URL='; then
  pass "ODOO_URL env var present in Snipe-IT container"
else
  fail "ODOO_URL env var missing from Snipe-IT container"
fi

if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q 'ODOO_API_KEY='; then
  pass "ODOO_API_KEY env var present in Snipe-IT container"
else
  fail "ODOO_API_KEY env var missing from Snipe-IT container"
fi

if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q 'ODOO_ASSET_MODEL='; then
  pass "ODOO_ASSET_MODEL env var present in Snipe-IT container"
else
  fail "ODOO_ASSET_MODEL env var missing from Snipe-IT container"
fi

# 3d: Container-to-WireMock connectivity
if docker exec "${APP_CONTAINER}" curl -sf http://snipeit-i05-mock:8080/__admin/health > /dev/null 2>&1; then
  pass "Snipe-IT container can reach WireMock (snipeit-i05-mock:8080)"
else
  fail "Snipe-IT container cannot reach WireMock"
fi

# 3e: Volume assertions
if docker volume ls | grep -q 'snipeit-i05-data'; then
  pass "Snipe-IT data volume exists"
else
  fail "Snipe-IT data volume missing"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 16-05 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
