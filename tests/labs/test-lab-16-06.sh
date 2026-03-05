#!/usr/bin/env bash
# test-lab-16-06.sh — Lab 16-06: Production Deployment
# Module 16: Snipe-IT IT asset management
# snipeit in production-grade HA configuration with monitoring
set -euo pipefail

LAB_ID="16-06"
LAB_NAME="Production Deployment"
MODULE="snipeit"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

# ── Colors ─────────────────────────────────────────────────────────────────────
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
echo ""

# ── PHASE 1: Setup ─────────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 75s for ${MODULE} production stack to initialize..."
sleep 75

# ── PHASE 2: Health Checks ─────────────────────────────────────────────────────────
info "Phase 2: Container Health Checks"

for svc in snipeit-p06-db snipeit-p06-redis snipeit-p06-ldap snipeit-p06-kc snipeit-p06-mail snipeit-p06-app snipeit-p06-queue; do
  if docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null | grep -q running; then
    pass "$svc is running"
  else
    fail "$svc is NOT running"
  fi
done

# DB check
if docker exec snipeit-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MariaDB is ready"
else
  fail "MariaDB not ready"
fi

# Redis check
if docker exec snipeit-p06-redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis responds to PING"
else
  fail "Redis PING failed"
fi

# KC check
if curl -sf http://localhost:8561/realms/master | grep -q realm; then
  pass "Keycloak accessible on port 8561"
else
  fail "Keycloak not accessible on port 8561"
fi

# App check
if curl -sf http://localhost:8461/ | grep -q -i 'snipe\|html'; then
  pass "Snipe-IT accessible on port 8461"
else
  fail "Snipe-IT not accessible on port 8461"
fi

# ── PHASE 3: Production Checks ───────────────────────────────────────────────────
info "Phase 3a: Compose config validation"
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Production compose config is valid"
else
  fail "Production compose config validation failed"
fi

info "Phase 3b: Resource limits applied"
MEM=$(docker inspect --format '{{.HostConfig.Memory}}' snipeit-p06-app 2>/dev/null || echo 0)
if [ "${MEM}" -gt 0 ] 2>/dev/null; then
  pass "Resource memory limit applied on snipeit-p06-app (${MEM} bytes)"
else
  fail "No memory limit found on snipeit-p06-app"
fi

info "Phase 3c: Restart policy check"
POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' snipeit-p06-app 2>/dev/null || echo none)
if [ "${POLICY}" = "unless-stopped" ]; then
  pass "Restart policy is unless-stopped on snipeit-p06-app"
else
  fail "Restart policy is '${POLICY}' (expected unless-stopped)"
fi

info "Phase 3d: Production environment variables"
IT_ENV=$(docker exec snipeit-p06-app env 2>/dev/null | grep IT_STACK_ENV= | cut -d= -f2 || echo "")
if [ "${IT_ENV}" = "production" ]; then
  pass "IT_STACK_ENV=production set on snipeit-p06-app"
else
  fail "IT_STACK_ENV not set to production (got: ${IT_ENV})"
fi

if docker exec snipeit-p06-app env 2>/dev/null | grep -q 'SESSION_DRIVER=redis'; then
  pass "SESSION_DRIVER=redis set on snipeit-p06-app"
else
  fail "SESSION_DRIVER not set to redis"
fi

info "Phase 3e: MySQL database backup test"
if docker exec snipeit-p06-db mysqldump -uroot -pRootProd06! snipeit > /dev/null 2>&1; then
  pass "mysqldump backup of snipeit database succeeded"
else
  fail "mysqldump backup failed"
fi

info "Phase 3f: Redis session persistence test"
if docker exec snipeit-p06-redis redis-cli SET test:session:prod06 "snipeit-lab06" EX 300 2>/dev/null | grep -q OK; then
  VAL=$(docker exec snipeit-p06-redis redis-cli GET test:session:prod06 2>/dev/null)
  if [ "${VAL}" = "snipeit-lab06" ]; then
    pass "Redis session SET/GET test passed"
  else
    fail "Redis GET returned wrong value: ${VAL}"
  fi
else
  fail "Redis SET command failed"
fi

info "Phase 3g: Keycloak admin API token acquisition"
KC_TOKEN=$(curl -sf -X POST http://localhost:8561/realms/master/protocol/openid-connect/token \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin API token acquired"
else
  fail "Failed to acquire Keycloak admin API token"
fi

info "Phase 3h: Queue worker container running"
if docker inspect --format '{{.State.Status}}' snipeit-p06-queue 2>/dev/null | grep -q running; then
  pass "Queue worker container is running"
else
  fail "Queue worker container is NOT running"
fi

info "Phase 3i: Redis restart resilience test"
docker restart snipeit-p06-redis > /dev/null 2>&1
info "Waiting 15s for Redis to recover..."
sleep 15
if docker exec snipeit-p06-redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis recovered after container restart"
else
  fail "Redis did NOT recover after container restart"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
if [ "${CLEANUP}" = true ]; then
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
  info "Cleanup complete"
else
  warn "Cleanup skipped (--no-cleanup flag set)"
fi

# ── Results ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi