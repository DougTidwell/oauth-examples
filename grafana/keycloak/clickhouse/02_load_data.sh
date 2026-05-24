#!/bin/bash
set -e
set -x

# Wait for ClickHouse to be ready
until clickhouse-client --query "SELECT 1" > /dev/null 2>&1; do
    echo "Waiting for ClickHouse..."
    sleep 1
done

# Verify tables exist
clickhouse-client --query "SHOW TABLES FROM raw"
clickhouse-client --query "SHOW TABLES FROM analytics"
clickhouse-client --query "SHOW TABLES FROM reports"

# Load the CSV into raw.orders
echo "Loading CSV..."
clickhouse-client \
    --query "INSERT INTO raw.orders FORMAT CSVWithNames" \
    < /docker-entrypoint-initdb.d/orders_raw.csv

ROW_COUNT=$(clickhouse-client --query "SELECT count() FROM raw.orders")
echo "Loaded $ROW_COUNT rows into raw.orders"

if [ "$ROW_COUNT" -eq 0 ]; then
    echo "ERROR: raw.orders is empty, aborting"
    exit 1
fi

# Populate analytics.orders from raw
echo "Populating analytics.orders..."
clickhouse-client --multiquery << 'SQL'
INSERT INTO analytics.orders
SELECT
    order_id,
    order_date,
    formatDateTime(order_date, '%Y-%m')                         AS order_month,
    product_name,
    category,
    quantity,
    unit_price,
    unit_cost,
    quantity * unit_price                                       AS revenue,
    quantity * unit_cost                                        AS cost,
    (quantity * unit_price) - (quantity * unit_cost)            AS margin,
    toFloat32(
        ((quantity * unit_price) - (quantity * unit_cost))
        / (quantity * unit_price)
    )                                                           AS margin_pct,
    region,
    channel,
    status
FROM raw.orders;
SQL

echo "Populated $(clickhouse-client --query 'SELECT count() FROM analytics.orders') rows into analytics.orders"

# Populate reports.monthly_revenue
echo "Populating reports.monthly_revenue..."
clickhouse-client --multiquery << 'SQL'
INSERT INTO reports.monthly_revenue
SELECT
    order_month,
    region,
    category,
    orders,
    units_sold,
    revenue,
    cost,
    margin,
    toFloat32(margin / revenue)                                 AS margin_pct,
    returned_orders,
    toFloat32(returned_orders / orders)                         AS return_rate
FROM (
    SELECT
        order_month,
        region,
        category,
        count()                                                 AS orders,
        sum(quantity)                                           AS units_sold,
        sum(revenue)                                            AS revenue,
        sum(cost)                                               AS cost,
        sum(margin)                                             AS margin,
        countIf(status = 'returned')                            AS returned_orders
    FROM analytics.orders
    GROUP BY order_month, region, category
    ORDER BY order_month, region, category
);
SQL

echo "Populated $(clickhouse-client --query 'SELECT count() FROM reports.monthly_revenue') rows into reports.monthly_revenue"

# Populate reports.product_performance
echo "Populating reports.product_performance..."
clickhouse-client --multiquery << 'SQL'
INSERT INTO reports.product_performance
SELECT
    product_name,
    category,
    total_orders                                                AS orders,
    units_sold,
    total_revenue                                               AS revenue,
    total_margin                                                AS margin,
    toFloat32(total_margin / total_revenue)                     AS margin_pct,
    top_region,
    top_channel
FROM (
    SELECT
        product_name,
        category,
        count()                                                 AS total_orders,
        sum(quantity)                                           AS units_sold,
        sum(revenue)                                            AS total_revenue,
        sum(margin)                                             AS total_margin,
        argMax(region, revenue)                                 AS top_region,
        argMax(channel, revenue)                                AS top_channel
    FROM analytics.orders
    WHERE status = 'completed'
    GROUP BY product_name, category
);
SQL

echo "Populated $(clickhouse-client --query 'SELECT count() FROM reports.product_performance') rows into reports.product_performance"

# Populate reports.channel_summary
echo "Populating reports.channel_summary..."
clickhouse-client --multiquery << 'SQL'
INSERT INTO reports.channel_summary
SELECT
    channel,
    orders,
    revenue,
    toFloat32(revenue / orders)                                 AS avg_order_value,
    toFloat32(returned_orders / orders)                         AS return_rate
FROM (
    SELECT
        channel,
        count()                                                 AS orders,
        sum(revenue)                                            AS revenue,
        countIf(status = 'returned')                            AS returned_orders
    FROM analytics.orders
    GROUP BY channel
);
SQL

echo "Populated $(clickhouse-client --query 'SELECT count() FROM reports.channel_summary') rows into reports.channel_summary"

echo "Data load complete"

