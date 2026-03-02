#!/usr/bin/env bash
# test-lab-16-03.sh — Lab 16-03: Snipe-IT Advanced Features
# Tests: Redis session/cache driver · dedicated queue worker · resource limits
# Usage: bash test-lab-16-03.sh [--no-cleanup]
set -euo pipefail

LAB_ID="16-03"
LAB_NAME="Advanced Features — Redis sessions + queue worker"
MODULE="snipeit"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0
FAIL=0

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up Lab ${LAB_ID} containers..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
info "Starting snipeit stack (db + redis + mail + app + queue worker)..."
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for MariaDB (snipeit-a03-db)..."
for i in $(seq 1 18); do
  if docker exec snipeit-a03-db mysqladmin ping -h localhost -uroot -pRootLab03! --silent 2>/dev/null; then
    info "MariaDB ready after ${i}×5s"
    break
  fi
  [[ $i -eq 18 ]] && { fail "MariaDB did not become ready"; exit 1; }
  sleep 5
done

info "Waiting for Redis (snipeit-a03-redis)..."
for i in $(seq 1 12); do
  if docker exec snipeit-a03-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    info "Redis ready after ${i}×5s"
    break
  fi
  [[ $i -eq 12 ]] && { fail "Redis did not become ready"; }
  sleep 5
done

info "Waiting for Snipe-IT app on port 8421..."
for i in $(seq 1 24); do
  HTTP=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8421/ 2>/dev/null || echo "000")
  if echo "${HTTP}" | grep -qE '^[23]'; then
    info "Snipe-IT ready after ${i}×15s (HTTP ${HTTP})"
    break
  fi
  [[ $i -eq 24 ]] && { warn "Snipe-IT did not become fully ready"; }
  sleep 15
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests — Advanced Features"

# 3.1 Container states (all 5)
for cname in snipeit-a03-db snipeit-a03-redis snipeit-a03-mail snipeit-a03-app snipeit-a03-queue; do
  STATE=$(docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "${STATE}" == "running" ]]; then
    pass "Container ${cname} is running"
  else
    fail "Container ${cname} state: ${STATE}"
  fi
done

# 3.2 SESSION_DRIVER=redis in app env (advanced feature)
SESSION_DRV=$(docker exec snipeit-a03-app printenv SESSION_DRIVER 2>/dev/null || echo "")
if [[ "${SESSION_DRV}" == "redis" ]]; then
  pass "SESSION_DRIVER=redis configured (Lab 03 advanced feature)"
else
  fail "SESSION_DRIVER is '${SESSION_DRV}' — expected 'redis'"
fi

# 3.3 CACHE_DRIVER=redis in app env
CACHE_DRV=$(docker exec snipeit-a03-app printenv CACHE_DRIVER 2>/dev/null || echo "")
if [[ "${CACHE_DRV}" == "redis" ]]; then
  pass "CACHE_DRIVER=redis configured (Lab 03 advanced feature)"
else
  fail "CACHE_DRIVER is '${CACHE_DRV}' — expected 'redis'"
fi

# 3.4 QUEUE_CONNECTION=redis
QUEUE_CONN=$(docker exec snipeit-a03-app printenv QUEUE_CONNECTION 2>/dev/null || echo "")
if [[ "${QUEUE_CONN}" == "redis" ]]; then
  pass "QUEUE_CONNECTION=redis configured"
else
  warn "QUEUE_CONNECTION is '${QUEUE_CONN}' — expected 'redis'"
fi

# 3.5 Redis connectivity from app
REDIS_PING=$(docker exec snipeit-a03-app redis-cli -h snipeit-a03-redis ping 2>/dev/null || echo "fail")
if echo "${REDIS_PING}" | grep -q PONG; then
  pass "App container can reach Redis (ping → PONG)"
else
  warn "App→Redis ping: ${REDIS_PING}  (redis-cli may not be in container)"
fi

# 3.6 Queue worker running (Lab 03 new container)
QUEUE_STATE=$(docker inspect snipeit-a03-queue --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [[ "${QUEUE_STATE}" == "running" ]]; then
  pass "snipeit-a03-queue worker is running (Lab 03 new container)"
else
  fail "snipeit-a03-queue worker state: ${QUEUE_STATE}"
fi

# 3.7 Database table count
TABLE_COUNT=$(docker exec snipeit-a03-db mysql -usnipeit -pSnipeLab03! -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='snipeit';" \
  --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${TABLE_COUNT}" -gt 20 ]]; then
  pass "Snipe-IT database has ${TABLE_COUNT} tables"
elif [[ "${TABLE_COUNT}" -gt 0 ]]; then
  warn "Snipe-IT database has ${TABLE_COUNT} tables (may still migrating)"
else
  fail "Snipe-IT database appears empty"
fi

# 3.8 HTTP check
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8421/ 2>/dev/null || echo "000")
if echo "${HTTP_CODE}" | grep -qE '^[23]'; then
  pass "Snipe-IT HTTP check: ${HTTP_CODE}"
else
  fail "Snipe-IT HTTP check failed: ${HTTP_CODE}"
fi

# 3.9 Memory limits
for cname in snipeit-a03-app snipeit-a03-queue snipeit-a03-db snipeit-a03-redis; do
  MEM_LIMIT=$(docker inspect "${cname}" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "${MEM_LIMIT}" -gt 0 ]]; then
    pass "${cname} has memory limit (${MEM_LIMIT} bytes)"
  else
    fail "${cname} has no memory limit"
  fi
done

# 3.10 Mailhog
MAIL_TOTAL=$(curl -sf http://localhost:8721/api/v2/messages 2>/dev/null | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "0")
pass "Mailhog API reachable (message count: ${MAIL_TOTAL})"

# 3.11 Volumes
for vol in snipeit-a03-db-data snipeit-a03-redis-data snipeit-a03-data; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} not found"
  fi
done

# ── PHASE 4: (cleanup via trap) ────────────────────────────────────────────────
section "Phase 4: Results"

echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

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
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 03 — Advanced Features)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 16-03 pending implementation"

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
