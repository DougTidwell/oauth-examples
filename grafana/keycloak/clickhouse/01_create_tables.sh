#!/bin/bash
set -e
 
echo "Creating tables..."
 
clickhouse-client --multiquery << 'SQL'
CREATE DATABASE IF NOT EXISTS raw;
 
CREATE TABLE IF NOT EXISTS raw.orders
(
    order_id         UInt32,
    order_date       Date,
    customer_email   String,
    customer_name    String,
    shipping_address String,
    product_name     String,
    category         String,
    quantity         UInt8,
    unit_price       Decimal(10, 2),
    unit_cost        Decimal(10, 2),
    region           String,
    channel          String,
    status           LowCardinality(String)
)
ENGINE = MergeTree()
ORDER BY (order_date, order_id);
 
CREATE DATABASE IF NOT EXISTS analytics;
 
CREATE TABLE IF NOT EXISTS analytics.orders
(
    order_id     UInt32,
    order_date   Date,
    order_month  String,
    product_name String,
    category     String,
    quantity     UInt8,
    unit_price   Decimal(10, 2),
    unit_cost    Decimal(10, 2),
    revenue      Decimal(10, 2),
    cost         Decimal(10, 2),
    margin       Decimal(10, 2),
    margin_pct   Float32,
    region       String,
    channel      LowCardinality(String),
    status       LowCardinality(String)
)
ENGINE = MergeTree()
ORDER BY (order_date, order_id);
 
CREATE DATABASE IF NOT EXISTS reports;
 
CREATE TABLE IF NOT EXISTS reports.monthly_revenue
(
    order_month     String,
    region          String,
    category        String,
    orders          UInt32,
    units_sold      UInt32,
    revenue         Decimal(12, 2),
    cost            Decimal(12, 2),
    margin          Decimal(12, 2),
    margin_pct      Float32,
    returned_orders UInt32,
    return_rate     Float32
)
ENGINE = MergeTree()
ORDER BY (order_month, region, category);
 
CREATE TABLE IF NOT EXISTS reports.product_performance
(
    product_name String,
    category     String,
    orders       UInt32,
    units_sold   UInt32,
    revenue      Decimal(12, 2),
    margin       Decimal(12, 2),
    margin_pct   Float32,
    top_region   String,
    top_channel  String
)
ENGINE = MergeTree()
ORDER BY (category, product_name);
 
CREATE TABLE IF NOT EXISTS reports.channel_summary
(
    channel         String,
    orders          UInt32,
    revenue         Decimal(12, 2),
    avg_order_value Decimal(10, 2),
    return_rate     Float32
)
ENGINE = MergeTree()
ORDER BY channel;
SQL
 
echo "Tables created successfully"
clickhouse-client --query "SHOW DATABASES"
 
