#!/bin/bash
# token_demo.sh
#
# Demonstrates JWT token auth against ClickHouse for all users,
# and contrasts priya's password-auth access vs his token-auth access.
#
# Prerequisites:
#   - docker compose up (all services running)
#   - clickhouse-client (uses containerized version via docker compose exec)
#   - curl, jq

KC="http://localhost:8080/realms/grafana/protocol/openid-connect/token"
CH_HTTP="http://localhost:8123"
CH_HOST="localhost"
CH_PORT="9000"

# ── Helpers ───────────────────────────────────────────────────────────────────

get_token() {
    local user="$1" pass="$2"
    curl -s -X POST "$KC" \
        -d "client_id=grafana-client&client_secret=grafana-secret&grant_type=password" \
        -d "username=$user&password=$pass&scope=openid" \
        | jq -r .access_token
}

# Token auth via native TCP: --jwt passes the token directly to the token processor
ch_jwt() {
    local token="$1" query="$2"
    docker compose exec clickhouse clickhouse-client \
        --host "$CH_HOST" --port "$CH_PORT" \
        --jwt "$token" \
        --query "$query" 2>&1
}

# Password auth via native TCP: regular username/password
ch_pass() {
    local user="$1" pass="$2" query="$3"
    docker compose exec clickhouse clickhouse-client \
        --host "$CH_HOST" --port "$CH_PORT" \
        --user "$user" --password "$pass" \
        --query "$query" 2>&1
}

# Token auth via HTTP: Authorization: Bearer header (same path Grafana uses)
ch_http_jwt() {
    local token="$1" query="$2"
    curl -s "$CH_HTTP/?query=$(python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")" \
        -H "Authorization: Bearer $token"
}

divider() {
    echo
    echo "══════════════════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════════════════"
}

ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; }

run_query() {
    # run_query <label> <expected ok|fail> <result>
    local label="$1" expect="$2" result="$3"
    if echo "$result" | grep -q "Exception\|Error\|AUTHENTICATION_FAILED\|ACCESS_DENIED"; then
        [ "$expect" = "fail" ] && fail "$label (blocked as expected)" \
                               || fail "$label — UNEXPECTED ERROR: $result"
    else
        [ "$expect" = "ok" ] && ok "$label: $result" \
                             || fail "$label — should have been blocked but got: $result"
    fi
}

# ── SECTION 1: Token auth via --jwt flag ─────────────────────────────────────

divider "amara — token auth (clickhouse-admins)"
AMARA_TOKEN=$(get_token amara amara)
echo "  Token (truncated): ${AMARA_TOKEN:0:50}..."
run_query "currentUser()"        ok   "$(ch_jwt "$AMARA_TOKEN" 'SELECT currentUser()')"
run_query "active roles"         ok   "$(ch_jwt "$AMARA_TOKEN" 'SELECT groupArray(role_name) FROM system.current_roles')"
run_query "raw.orders (admins)"  ok   "$(ch_jwt "$AMARA_TOKEN" 'SELECT count() FROM raw.orders')"

divider "helen — token auth (clickhouse-analysts)"
HELEN_TOKEN=$(get_token helen helen)
run_query "currentUser()"                    ok   "$(ch_jwt "$HELEN_TOKEN" 'SELECT currentUser()')"
run_query "analytics.orders (analysts+)"     ok   "$(ch_jwt "$HELEN_TOKEN" 'SELECT count() FROM analytics.orders')"
run_query "raw.orders (admins only)"         fail "$(ch_jwt "$HELEN_TOKEN" 'SELECT count() FROM raw.orders')"

divider "mateo — token auth (clickhouse-readers)"
MATEO_TOKEN=$(get_token mateo mateo)
run_query "currentUser()"                        ok   "$(ch_jwt "$MATEO_TOKEN" 'SELECT currentUser()')"
run_query "reports.monthly_revenue (readers+)"   ok   "$(ch_jwt "$MATEO_TOKEN" 'SELECT count() FROM reports.monthly_revenue')"
run_query "analytics.orders (analysts+)"         fail "$(ch_jwt "$MATEO_TOKEN" 'SELECT count() FROM analytics.orders')"

# ── SECTION 2: Priya — password vs token ──────────────────────────────────────

divider "priya — password auth (native ClickHouse user, reader_role only)"
echo "  Priya exists in ClickHouse with IDENTIFIED BY 'priya'."
echo "  His local grant: reader_role → reports.* only"
echo ""
run_query "currentUser()"                      ok   "$(ch_pass priya priya 'SELECT currentUser()')"
run_query "reports.monthly_revenue (granted)"  ok   "$(ch_pass priya priya 'SELECT count() FROM reports.monthly_revenue')"
run_query "analytics.orders (not granted)"     fail "$(ch_pass priya priya 'SELECT count() FROM analytics.orders')"

divider "priya — token auth (Keycloak: clickhouse-analysts)"
PRIYA_TOKEN=$(get_token priya priya)
echo "  Priya's Keycloak account is in clickhouse-analysts."
echo "  Via --jwt, ClickHouse ignores the local user definition"
echo "  and assigns roles from the JWT groups claim instead."
echo ""
run_query "currentUser()"                       ok   "$(ch_jwt "$PRIYA_TOKEN" 'SELECT currentUser()')"
run_query "analytics.orders (now accessible)"   ok   "$(ch_jwt "$PRIYA_TOKEN" 'SELECT count() FROM analytics.orders')"
run_query "raw.orders (still blocked)"          fail "$(ch_jwt "$PRIYA_TOKEN" 'SELECT count() FROM raw.orders')"

# ── SECTION 3: HTTP interface (same path as Grafana) ─────────────────────────

divider "HTTP interface — Authorization: Bearer (Grafana's path)"
echo "  This is how the Grafana plugin forwards tokens to ClickHouse."
echo ""
AMARA_HTTP=$(ch_http_jwt "$AMARA_TOKEN" "SELECT currentUser()")
HELEN_HTTP=$(ch_http_jwt "$HELEN_TOKEN" "SELECT currentUser()")
MATEO_HTTP=$(ch_http_jwt "$MATEO_TOKEN" "SELECT currentUser()")
ok "amara via HTTP: $AMARA_HTTP"
ok "helen   via HTTP: $HELEN_HTTP"
ok "mateo via HTTP: $MATEO_HTTP"

# ── Summary ───────────────────────────────────────────────────────────────────

divider "Summary"
cat << 'TABLE'

  User   Auth       Flag        Roles assigned          raw  analytics  reports
  ─────  ─────────  ──────────  ──────────────────────  ───  ─────────  ───────
  amara  token      --jwt       clickhouse_admins        ✓       ✓         ✓
  helen  token      --jwt       clickhouse_analysts      ✗       ✓         ✓
  mateo  token      --jwt       clickhouse_readers       ✗       ✗         ✓
  priya  password   --password  reader_role (local)      ✗       ✗         ✓
  priya  token      --jwt       clickhouse_analysts      ✗       ✓         ✓

TABLE
