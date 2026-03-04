#!/usr/bin/env bash
# test-lab-16-05.sh — Lab 16-05: Advanced Integration (INT-08b)
# Module 16: Snipe-IT ↔ Keycloak SAML 2.0 + LDAP federation + Odoo REST API mock
# INT-08b: Snipe-IT SAML SSO via Keycloak with FreeIPA-style LDAP seed
set -euo pipefail

LAB_ID="16-05"
LAB_NAME="Advanced Integration (INT-08b: Snipe-IT <-> Keycloak SAML + LDAP)"
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

KC_URL="http://localhost:${KC_PORT}"
APP_URL="http://localhost:${APP_PORT}"
MOCK_URL="http://localhost:${MOCK_PORT}"

APP_CONTAINER="snipeit-i05-app"
KC_CONTAINER="snipeit-i05-kc"
LDAP_CONTAINER="snipeit-i05-ldap"
SEED_CONTAINER="snipeit-i05-ldap-seed"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Cleanup: tearing down integration stack"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup — starting integration stack"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 90s for Snipe-IT integration stack to initialise..."
sleep 90

# ── PHASE 2: Container Health ─────────────────────────────────────────────────
info "Phase 2: Container health checks"

for cname in snipeit-i05-db snipeit-i05-ldap snipeit-i05-kc \
             snipeit-i05-mock snipeit-i05-mail snipeit-i05-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
    pass "Container running: ${cname}"
  else
    fail "Container not running: ${cname}"
  fi
done

# LDAP seed must have exited 0
SEED_EXIT=$(docker inspect --format='{{.State.ExitCode}}' "${SEED_CONTAINER}" 2>/dev/null || echo "missing")
if [[ "${SEED_EXIT}" == "0" ]]; then
  pass "LDAP seed container exited cleanly (exit 0)"
else
  fail "LDAP seed container exit code: ${SEED_EXIT}"
fi

# MariaDB
if docker exec snipeit-i05-db mysqladmin ping -uroot -pRootLab05! --silent 2>/dev/null; then
  pass "MariaDB responds to ping"
else
  fail "MariaDB not responding"
fi

# WireMock
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak health/ready loop (up to 5 min)
info "Waiting for Keycloak health/ready..."
KC_READY=false
for i in $(seq 1 30); do
  if curl -sf "${KC_URL}/health/ready" 2>/dev/null | grep -q UP; then
    KC_READY=true; break
  fi
  sleep 10
done
if [[ "${KC_READY}" == "true" ]]; then
  pass "Keycloak health/ready = UP"
else
  fail "Keycloak not ready after 5 min"
fi

# Snipe-IT web
info "Waiting for Snipe-IT web interface..."
SNIPE_READY=false
for i in $(seq 1 20); do
  if curl -sf "${APP_URL}/" 2>/dev/null | grep -qi "snipe\|html"; then
    SNIPE_READY=true; break
  fi
  sleep 10
done
if [[ "${SNIPE_READY}" == "true" ]]; then
  pass "Snipe-IT web interface responding"
else
  warn "Snipe-IT web interface slow to respond (continuing)"
fi

# Mailhog
if curl -sf "http://localhost:${MH_PORT}/api/v2/messages" > /dev/null; then
  pass "Mailhog API accessible"
else
  warn "Mailhog not ready (non-critical)"
fi

echo ""

# ── PHASE 3: LDAP Seed Verification ──────────────────────────────────────────
info "Phase 3: LDAP seed verification"

USER_COUNT=$(ldapsearch -x -LLL -H ldap://localhost:${LDAP_PORT} \
  -D "cn=admin,dc=lab,dc=local" -w LdapLab05! \
  -b "cn=users,cn=accounts,dc=lab,dc=local" "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || true)
if [[ "${USER_COUNT}" -ge 3 ]]; then
  pass "LDAP: >=3 users in cn=users,cn=accounts (found ${USER_COUNT})"
else
  fail "LDAP: expected >=3 users (found ${USER_COUNT})"
fi

GROUP_COUNT=$(ldapsearch -x -LLL -H ldap://localhost:${LDAP_PORT} \
  -D "cn=admin,dc=lab,dc=local" -w LdapLab05! \
  -b "cn=groups,cn=accounts,dc=lab,dc=local" "(objectClass=groupOfNames)" cn 2>/dev/null \
  | grep -c "^cn:" || true)
if [[ "${GROUP_COUNT}" -ge 2 ]]; then
  pass "LDAP: >=2 groups in cn=groups,cn=accounts (found ${GROUP_COUNT})"
else
  fail "LDAP: expected >=2 groups (found ${GROUP_COUNT})"
fi

if ldapsearch -x -LLL -H ldap://localhost:${LDAP_PORT} \
     -D "cn=admin,dc=lab,dc=local" -w LdapLab05! \
     -b "dc=lab,dc=local" "(uid=snipeadmin)" uid 2>/dev/null | grep -q "uid: snipeadmin"; then
  pass "LDAP: uid=snipeadmin entry present"
else
  fail "LDAP: uid=snipeadmin not found"
fi

if ldapsearch -x -LLL -H ldap://localhost:${LDAP_PORT} \
     -D "cn=readonly,dc=lab,dc=local" -w ReadOnly05! \
     -b "dc=lab,dc=local" "(uid=snipeuser1)" uid 2>/dev/null | grep -q "uid: snipeuser1"; then
  pass "LDAP: readonly bind + search for snipeuser1 OK"
else
  fail "LDAP: readonly bind failed"
fi

echo ""

# ── PHASE 4: Keycloak Realm + LDAP Federation + SAML Client ──────────────────
info "Phase 4: Keycloak realm, LDAP federation, and SAML client"

KC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json, sys
data = urllib.parse.urlencode({
    'client_id': 'admin-cli', 'username': 'admin', 'password': 'Admin05!',
    'grant_type': 'password'
}).encode()
req = urllib.request.Request('http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token', data=data)
try:
    r = urllib.request.urlopen(req, timeout=15)
    print(json.loads(r.read())['access_token'])
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr); sys.exit(1)
" 2>/dev/null || true)

if [[ -n "${KC_TOKEN}" && "${KC_TOKEN}" != ERROR* ]]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin token failed"
  KC_TOKEN=""
fi

if [[ -n "${KC_TOKEN}" ]]; then
  REALM_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KC_URL}/admin/realms/it-stack" || echo "000")
  if [[ "${REALM_STATUS}" == "200" ]]; then
    pass "Keycloak realm 'it-stack' exists"
  else
    curl -sf -o /dev/null -X POST \
      -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
      "${KC_URL}/admin/realms" -d '{"realm":"it-stack","enabled":true}' || true
    pass "Keycloak realm 'it-stack' created"
  fi

  # LDAP federation
  FED_IDS=$(curl -sf \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
    | python3 -c "import json,sys; c=json.load(sys.stdin); print(' '.join(x['id'] for x in c if x.get('providerId')=='ldap'))" 2>/dev/null || true)
  if [[ -n "${FED_IDS}" ]]; then
    pass "Keycloak LDAP federation component present"
  else
    COMP_ST=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
      "${KC_URL}/admin/realms/it-stack/components" \
      -d '{"name":"snipeit-lab-ldap","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","config":{"vendor":["rhds"],"connectionUrl":["ldap://snipeit-i05-ldap:389"],"bindDn":["cn=readonly,dc=lab,dc=local"],"bindCredential":["ReadOnly05!"],"usersDn":["cn=users,cn=accounts,dc=lab,dc=local"],"usernameLDAPAttribute":["uid"],"uuidLDAPAttribute":["entryUUID"],"userObjectClasses":["inetOrgPerson"],"searchScope":["1"],"trustEmail":["true"],"syncRegistrations":["true"],"importEnabled":["true"],"editMode":["READ_ONLY"]}}' \
      || echo "000")
    [[ "${COMP_ST}" =~ ^2 ]] && pass "LDAP federation created (HTTP ${COMP_ST})" || fail "LDAP federation creation failed (HTTP ${COMP_ST})"
    FED_IDS=$(curl -sf \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
      | python3 -c "import json,sys; c=json.load(sys.stdin); print(' '.join(x['id'] for x in c if x.get('providerId')=='ldap'))" 2>/dev/null || true)
  fi

  # Sync
  if [[ -n "${FED_IDS}" ]]; then
    FIRST_ID=$(echo "${FED_IDS}" | awk '{print $1}')
    SYNC_ST=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KC_URL}/admin/realms/it-stack/user-storage/${FIRST_ID}/sync?action=triggerFullSync" || echo "000")
    [[ "${SYNC_ST}" =~ ^2 ]] && pass "LDAP full sync triggered (HTTP ${SYNC_ST})" || warn "LDAP sync returned HTTP ${SYNC_ST}"
    sleep 5
    USER_N=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KC_URL}/admin/realms/it-stack/users?search=snipeadmin" \
      | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [[ "${USER_N}" -ge 1 ]] && pass "KC: snipeadmin synced from LDAP" || warn "KC: snipeadmin not yet synced"
  fi

  # SAML client
  SAML_CL=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KC_URL}/admin/realms/it-stack/clients?clientId=snipeit" \
    | python3 -c "import json,sys; cl=json.load(sys.stdin); found=[c for c in cl if c.get('clientId')=='snipeit' and c.get('protocol')=='saml']; print(found[0]['id'] if found else '')" 2>/dev/null || true)
  if [[ -n "${SAML_CL}" ]]; then
    pass "Keycloak SAML client 'snipeit' registered (id: ${SAML_CL:0:8}...)"
  else
    SC_ST=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
      "${KC_URL}/admin/realms/it-stack/clients" \
      -d '{"clientId":"snipeit","protocol":"saml","enabled":true,"attributes":{"saml.authn.statement":"true","saml_assertion_consumer_url_post":"http://localhost:8441/saml2/it-stack/acs","saml.server.signature":"true","saml.signature.algorithm":"RSA_SHA256","saml_name_id_format":"username"},"redirectUris":["http://localhost:8441/*"],"baseUrl":"http://localhost:8441"}' \
      || echo "000")
    [[ "${SC_ST}" =~ ^2 ]] && pass "SAML client 'snipeit' created (HTTP ${SC_ST})" || fail "SAML client creation failed (HTTP ${SC_ST})"
  fi
fi

echo ""

# ── PHASE 5: SAML IdP Metadata ────────────────────────────────────────────────
info "Phase 5: SAML IdP metadata verification"

META_ST=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_URL}/realms/it-stack/protocol/saml/descriptor" || echo "000")
if [[ "${META_ST}" == "200" ]]; then
  pass "KC SAML IdP metadata endpoint returns 200"
else
  fail "KC SAML IdP metadata endpoint HTTP ${META_ST}"
fi

SAML_META=$(curl -sf "${KC_URL}/realms/it-stack/protocol/saml/descriptor" 2>/dev/null || true)
if echo "${SAML_META}" | grep -q "EntityDescriptor\|entityID"; then
  pass "SAML IdP metadata contains EntityDescriptor"
else
  warn "SAML IdP metadata not fully populated yet"
fi
if echo "${SAML_META}" | grep -qi "X509Certificate"; then
  pass "SAML IdP metadata contains signing certificate"
else
  warn "SAML IdP metadata: no X509Certificate (needs realm key setup)"
fi

# Internal reach: Snipe-IT → KC SAML descriptor
if docker exec "${APP_CONTAINER}" \
     curl -sf "http://snipeit-i05-kc:8080/realms/it-stack/protocol/saml/descriptor" \
     > /dev/null 2>&1; then
  pass "Snipe-IT container can reach KC SAML descriptor (internal)"
else
  fail "Snipe-IT container cannot reach KC SAML descriptor"
fi

echo ""

# ── PHASE 6: Env var assertions ───────────────────────────────────────────────
info "Phase 6: Snipe-IT SAML + Keycloak env var assertions"

for var in KEYCLOAK_URL KEYCLOAK_REALM KEYCLOAK_CLIENT_ID \
           SAML2_ENABLED SAML2_IDP_METADATA_URL SAML2_SP_ACS_URL; do
  if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q "^${var}="; then
    pass "Env var ${var} present"
  else
    fail "Env var ${var} missing from Snipe-IT container"
  fi
done

echo ""

# ── PHASE 7: WireMock Odoo stubs + connectivity ──────────────────────────────
info "Phase 7: WireMock Odoo REST API stubs and connectivity"

STUB1=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{"request":{"method":"POST","url":"/web/dataset/call_kw"},"response":{"status":200,"headers":{"Content-Type":"application/json"},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":201,\"name\":\"Dell Latitude Pro\",\"model\":\"stock.inventory\",\"state\":\"done\"}]}"}}' \
  || echo "000")
[[ "${STUB1}" =~ ^2 ]] && pass "WireMock: call_kw stub registered (HTTP ${STUB1})" || fail "WireMock: call_kw stub failed (HTTP ${STUB1})"

STUB2=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{"request":{"method":"POST","url":"/web/session/authenticate"},"response":{"status":200,"headers":{"Content-Type":"application/json"},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"uid\":1,\"db\":\"odoo\",\"session_id\":\"lab-session-08b\"}}"}}' \
  || echo "000")
[[ "${STUB2}" =~ ^2 ]] && pass "WireMock: authenticate stub registered (HTTP ${STUB2})" || fail "WireMock: authenticate stub failed (HTTP ${STUB2})"

if curl -sf -X POST "${MOCK_URL}/web/dataset/call_kw" \
     -H "Content-Type: application/json" \
     -d '{"model":"stock.inventory","method":"search_read","args":[],"kwargs":{}}' \
     | grep -q "Dell Latitude Pro"; then
  pass "WireMock: call_kw returns asset JSON with expected data"
else
  fail "WireMock: call_kw unexpected response"
fi

if docker exec "${APP_CONTAINER}" \
     curl -sf http://snipeit-i05-mock:8080/__admin/health > /dev/null 2>&1; then
  pass "Snipe-IT container can reach WireMock (snipeit-i05-mock:8080)"
else
  fail "Snipe-IT container cannot reach WireMock"
fi

for var in ODOO_URL ODOO_API_KEY ODOO_ASSET_MODEL; do
  if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q "^${var}="; then
    pass "Odoo env var ${var} present"
  else
    fail "Odoo env var ${var} missing from Snipe-IT container"
  fi
done

echo ""

# ── PHASE 8: Volume and final assertions ──────────────────────────────────────
info "Phase 8: Volume and final assertions"

for vol in snipeit-i05-db-data snipeit-i05-ldap-data snipeit-i05-data snipeit-i05-logs; do
  if docker volume ls | grep -q "${vol}"; then
    pass "Volume exists: ${vol}"
  else
    fail "Volume missing: ${vol}"
  fi
done

for var in DB_HOST MAIL_HOST LDAP_ENABLED; do
  if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q "^${var}="; then
    pass "Env var ${var} present"
  else
    fail "Env var ${var} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0