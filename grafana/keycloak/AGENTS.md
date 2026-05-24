# AGENTS.md

This file describes the project structure, configuration conventions, and gotchas for AI agents working on this codebase. Read it before making changes.

## What this project is

A Docker Compose demo showing OAuth-based access control across three services: Keycloak (identity provider), ClickHouse (database), and Grafana (dashboards). A JWT issued by Keycloak controls what data a user can query in ClickHouse and which dashboards they can see in Grafana — without any local user accounts in ClickHouse.

There is also a native ClickHouse user (`dave`) who demonstrates that password auth and token auth can coexist and yield different access levels for the same person.

## Directory structure

```
├── docker-compose.yml
├── token_demo.sh                          # CLI demo of JWT auth vs password auth
├── clickhouse/
│   ├── 01_create_tables.sh                # Creates raw, analytics, reports databases
│   ├── 02_load_data.sh                    # Loads orders_raw.csv, populates derived tables
│   ├── orders_raw.csv                     # 2000 rows of synthetic e-commerce data
│   ├── startup_scripts.xml                # Creates roles and grants on ClickHouse startup
│   ├── processor_directory.xml            # Configures JWT token processor (Keycloak)
│   ├── clickhouse-low-ram-config.xml      # Memory/thread limits for local dev
│   ├── clickhouse-low-ram-user-profile.xml
│   └── session-log.xml
├── keycloak/
│   └── grafana-realm.json                 # Full realm export: groups, users, client config
├── grafana/
│   ├── setup_permissions.sh               # Sets folder permissions via Grafana API
│   └── provisioning/
│       ├── datasources/
│       │   └── clickhouse.yml             # Auto-configures the ClickHouse datasource
│       └── dashboards/
│           ├── dashboards.yml             # Tells Grafana to load from subfolders
│           ├── public/
│           │   └── 01_executive_overview.json
│           ├── analytics/
│           │   └── 02_analytics.json
│           └── admin/
│               └── 03_admin.json
```

## How the access control works

### Keycloak → Grafana

Grafana's OAuth config maps Keycloak groups to Grafana roles via JMESPath:

```
grafana-admins  → Admin  (all dashboards)
grafana-editors → Editor (public + analytics)
everyone else   → Viewer (public only)
```

Folder permissions are set by `setup_permissions.sh` after startup, not by provisioning YAML (Grafana provisioning doesn't support permission assignments).

### Keycloak → ClickHouse

ClickHouse's token processor (`processor_directory.xml`) calls Keycloak's userinfo endpoint to validate JWTs. The `roles_transform` config converts hyphens to underscores in group names (`clickhouse-admins` → `clickhouse_admins`), matching ClickHouse role names defined in `startup_scripts.xml`.

**Important:** `jwks_uri` is intentionally absent from `processor_directory.xml`. If present, ClickHouse validates JWTs locally and checks the `iss` claim against the JWKS issuer (`http://keycloak:8080`). Tokens obtained via `curl` from the host use `iss: http://localhost:8080` and fail that check. Without `jwks_uri`, ClickHouse always calls the userinfo endpoint, which works regardless of how the token was obtained.

### Role hierarchy

```
clickhouse_readers  → SELECT on reports.*
clickhouse_analysts → SELECT on reports.* + analytics.*
clickhouse_admins   → SELECT on reports.* + analytics.* + raw.*
reader_role         → SELECT on reports.* (assigned to all token users via common_roles)
```

`dave` is a native ClickHouse user (`IDENTIFIED BY 'dave'`) with `reader_role` only. When he authenticates via JWT instead, his Keycloak group (`clickhouse-analysts`) gives him analyst access. Same person, different access depending on auth method.

## ClickHouse query format for Grafana dashboards

The Altinity plugin uses the `EvalQuery` struct, not a generic `rawSql` field. Queries in dashboard JSON must use:

```json
{
  "rawQuery": true,
  "query": "SELECT ..."
}
```

NOT `"rawSql": "SELECT ..."` — that field is silently ignored.

**Decimal columns** come back as strings in ClickHouse's JSON output because the plugin's type switch matches `"Decimal"` but not `"Decimal(12, 2)"`. Wrap all Decimal aggregations in `toFloat64()` or Grafana will report "No numeric fields found."

**Panel format field:**
- Timeseries panels: omit `format` entirely (plugin uses `toTimeSeries()` by default)
- All other panels (stat, barchart, piechart, bargauge, table): set `"format": "table"`

**Multi-series panels** (barchart, timeseries with multiple lines, piechart, bargauge) need wide-format data — one column per series, not long-format rows. Use `sumIf`, `countIf`, or `avgIf` to pivot in SQL:

```sql
-- Wide format (correct for barchart/piechart)
SELECT
  toFloat64(sumIf(revenue, region='Northeast')) AS Northeast,
  toFloat64(sumIf(revenue, region='West'))      AS West
FROM reports.monthly_revenue

-- Long format (wrong — produces "No data" or one big bar)
SELECT region, sum(revenue) AS revenue
FROM reports.monthly_revenue GROUP BY region
```

## Startup sequence

```
keycloak (healthy) → clickhouse + grafana start in parallel
grafana (healthy, ~90s) → grafana-setup runs setup_permissions.sh and exits
```

Grafana reports healthy before finishing plugin installation and dashboard provisioning. `setup_permissions.sh` polls `/api/folders` until all three folders appear before setting permissions.

## Common failure modes

**"No data" in dashboard panels** — check the query format (`rawQuery: true` + `query` field), `format: "table"` on non-timeseries panels, and `toFloat64()` on any Decimal columns.

**Token auth fails with AUTHENTICATION_FAILED** — check that `jwks_uri` is not in `processor_directory.xml`. Also confirm the token is a JWT (three base64 chunks separated by dots) not an opaque token.

**`--jwt` flag not recognized** — you're using a system `clickhouse-client`, not the one in the container. Use `docker compose exec clickhouse clickhouse-client --jwt "$TOKEN" ...`

**`setup_permissions.sh` exits with code 0 but permissions not set** — the script is probably running against `http://localhost:3000` instead of `http://grafana:3000`. The internal Docker hostname must be used, not localhost.

**Grafana folder permissions reset on restart** — `setup_permissions.sh` must be re-run after every `docker compose down && up`. Permissions are stored in Grafana's database (ephemeral), not in provisioning files.

## Token demo

`token_demo.sh` demonstrates the full access control matrix. Run it from the project root:

```bash
bash token_demo.sh
```

It fetches tokens from Keycloak for each user and runs test queries via `docker compose exec clickhouse clickhouse-client --jwt`. The dave section explicitly contrasts password auth (reader only) vs token auth (analyst).

## Data

`orders_raw.csv` contains 2000 synthetic e-commerce orders dated 2024-01-01 to 2024-12-30 across 5 regions (Midwest, Northeast, Southeast, Southwest, West), 3 channels (web, mobile, email_campaign), 3 statuses (completed, returned, cancelled), and 3 product categories (Electronics, Office, Accessories).

Dashboard time range is set to `2024-01-01 → 2024-12-31` to match. Do not use relative time ranges like `now-1y` — the data is static.
