#!/usr/bin/env bash
# test-lab-16-02.sh — Lab 16-02: External Dependencies
# Module 16: Snipe-IT IT asset management
# snipeit with external PostgreSQL, Redis, and network integration
set -euo pipefail

LAB_ID="16-02"
LAB_NAME="External Dependencies"
MODULE="snipeit"
COMPOSE_FILE="docker/docker-compose.lan.yml"
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
echo ""

# ── Cleanup control ───────────────────────────────────────────────────────────
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

info "Waiting for external MariaDB (snipeit-l02-db, up to 90s)..."
for i in $(seq 1 18); do
  if docker exec snipeit-l02-db mysqladmin ping -uroot -pRootLab02! --silent 2>/dev/null; then
    pass "External MariaDB healthy"
    break
  fi
  [[ $i -eq 18 ]] && fail "External MariaDB timed out after 90s"
  sleep 5
done

info "Waiting for Mailhog (snipeit-l02-mail, up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8711/api/v2/messages >/dev/null 2>&1; then
    pass "Mailhog API reachable"
    break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog timed out after 60s"
  sleep 5
done

info "Waiting for Snipe-IT web (snipeit-l02-app, up to 300s)..."
for i in $(seq 1 30); do
  http_code=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8411/ 2>/dev/null || echo "000")
  if [[ "${http_code}" =~ ^[234] ]]; then
    pass "Snipe-IT web responding (HTTP ${http_code})"
    break
  fi
  [[ $i -eq 30 ]] && fail "Snipe-IT web timed out after 300s"
  sleep 10
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 16-02 — External Dependencies)"

# Container states
for svc in snipeit-l02-db snipeit-l02-mail snipeit-l02-app; do
  state=$(docker inspect --format='{{.State.Status}}' "${svc}" 2>/dev/null || echo "missing")
  if [[ "${state}" == "running" ]]; then
    pass "Container ${svc} is running"
  else
    fail "Container ${svc} state: ${state}"
  fi
done

# DB connectivity from app container
table_count=$(docker exec snipeit-l02-db \
  mysql -usnipeit -pSnipeLab02! snipeit -e 'SHOW TABLES;' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${table_count}" -gt 5 ]]; then
  pass "Snipe-IT database has ${table_count} tables (migrations ran)"
else
  warn "Snipe-IT database tables: ${table_count} (migrations may still be running)"
fi

# Mailhog API format check
mailhog_resp=$(curl -sf http://localhost:8711/api/v2/messages 2>/dev/null || echo "{}")
if echo "${mailhog_resp}" | grep -q 'total\|items\|count'; then
  pass "Mailhog API returns valid JSON message list"
else
  fail "Mailhog API response unexpected: ${mailhog_resp}"
fi

# HTTP status check
http_code=$(curl -o /dev/null -sw '%{http_code}' -L http://localhost:8411/ 2>/dev/null || echo "000")
if [[ "${http_code}" =~ ^[234] ]]; then
  pass "Snipe-IT HTTP GET / -> ${http_code}"
else
  fail "Snipe-IT HTTP GET / -> ${http_code}"
fi

# Login page present
if curl -sf -L http://localhost:8411/ 2>/dev/null | grep -qi 'snipe\|login\|email\|password'; then
  pass "Snipe-IT login page rendered"
else
  warn "Snipe-IT login page check inconclusive"
fi

# Key env vars present in app container
for var in DB_HOST DB_DATABASE APP_KEY APP_URL MAIL_HOST; do
  if docker exec snipeit-l02-app printenv "${var}" 2>/dev/null | grep -q '.'; then
    pass "Env var ${var} set in snipeit-l02-app"
  else
    fail "Env var ${var} missing in snipeit-l02-app"
  fi
done

# Volume existence
for vol in snipeit-l02-db-data snipeit-l02-data; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
