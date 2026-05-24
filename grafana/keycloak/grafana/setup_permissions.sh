#!/bin/sh
# Runs as a short-lived container on compose up.
# Sets Grafana folder permissions and org home dashboard.

apk add --quiet --no-cache curl jq

GRAFANA="http://grafana:3000"
AUTH="admin:admin"

echo "Waiting for Grafana API..."
until curl -sf -o /dev/null -u "$AUTH" "$GRAFANA/api/health"; do
    sleep 3
done

# Wait specifically for all three provisioned folders to appear.
# Grafana reports healthy before finishing provisioning, so we need
# to poll for the actual content rather than just the health endpoint.
echo "Waiting for provisioned folders (public, analytics, admin)..."
for i in $(seq 1 30); do
    FOLDERS=$(curl -s -u "$AUTH" "$GRAFANA/api/folders")
    HAS_PUBLIC=$(echo "$FOLDERS"    | jq -r '[.[].title] | contains(["public"])')
    HAS_ANALYTICS=$(echo "$FOLDERS" | jq -r '[.[].title] | contains(["analytics"])')
    HAS_ADMIN=$(echo "$FOLDERS"     | jq -r '[.[].title] | contains(["admin"])')
    if [ "$HAS_PUBLIC" = "true" ] && [ "$HAS_ANALYTICS" = "true" ] && [ "$HAS_ADMIN" = "true" ]; then
        echo "All folders found after ${i} attempts."
        break
    fi
    echo "  Attempt $i: folders not ready yet (public=$HAS_PUBLIC analytics=$HAS_ANALYTICS admin=$HAS_ADMIN), waiting 5s..."
    sleep 5
done

get_folder_uid() {
    curl -s -u "$AUTH" "$GRAFANA/api/folders" \
        | jq -r ".[] | select(.title==\"$1\") | .uid"
}

set_folder_perms() {
    local uid="$1" payload="$2" label="$3"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$GRAFANA/api/folders/$uid/permissions" \
        -H "Content-Type: application/json" \
        -u "$AUTH" \
        -d "$payload")
    echo "  $label -> HTTP $code"
}

echo "=== Setting folder permissions ==="

PUBLIC_UID=$(get_folder_uid "public")
ANALYTICS_UID=$(get_folder_uid "analytics")
ADMIN_UID=$(get_folder_uid "admin")
echo "  UIDs: public=$PUBLIC_UID analytics=$ANALYTICS_UID admin=$ADMIN_UID"

set_folder_perms "$PUBLIC_UID" \
    '{"items":[{"role":"Viewer","permission":1},{"role":"Editor","permission":1},{"role":"Admin","permission":4}]}' \
    "public (Viewer+)"

set_folder_perms "$ANALYTICS_UID" \
    '{"items":[{"role":"Editor","permission":1},{"role":"Admin","permission":4}]}' \
    "analytics (Editor+)"

set_folder_perms "$ADMIN_UID" \
    '{"items":[{"role":"Admin","permission":4}]}' \
    "admin (Admin only)"

echo "=== Setting org home dashboard ==="

DASH_ID=$(curl -s -u "$AUTH" \
    "$GRAFANA/api/search?query=Executive+Overview&type=dash-db" \
    | jq -r '.[0].id')
echo "  Executive Overview id: $DASH_ID"

if [ -n "$DASH_ID" ] && [ "$DASH_ID" != "null" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "$GRAFANA/api/org/preferences" \
        -H "Content-Type: application/json" \
        -u "$AUTH" \
        -d "{\"homeDashboardId\":$DASH_ID}")
    echo "  Set org home dashboard -> HTTP $code"
fi

echo "=== Setup complete ==="
