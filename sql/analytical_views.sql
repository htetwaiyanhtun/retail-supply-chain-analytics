-- =============================================================================
-- RETAIL & SUPPLY CHAIN ANALYTICS: MODULAR ANALYTICAL VIEWS
-- Database: PostgreSQL (retail_analytics schema)
-- Description: Production views for financial performance, logistics SLA,
--              inventory Pareto analysis, and customer RFM segmentation.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS retail_analytics;

-- -----------------------------------------------------------------------------
-- 1. VIEW: Financial Performance (Fact Mart)
-- Filters out CANCELED and SUSPECTED_FRAUD orders ($1.41M leakage)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS retail_analytics.v_financial_performance CASCADE;

CREATE VIEW retail_analytics.v_financial_performance AS
SELECT 
    order_id,
    order_item_id,
    customer_id,
    order_date::date AS order_date,
    DATE_TRUNC('month', order_date)::date AS order_month,
    market,
    category_name,
    product_name,
    shipping_mode,
    order_status,
    order_item_quantity,
    sales AS gross_sales,
    order_item_discount,
    order_item_total AS net_sales,
    order_item_total AS sales_per_order,
    order_profit_per_order AS profit,
    (order_item_total - order_profit_per_order) AS cogs,
    ROUND(((order_profit_per_order / NULLIF(order_item_total, 0)) * 100)::numeric, 2) AS gross_margin_pct,
    ROUND((order_item_total / NULLIF(order_item_quantity, 0))::numeric, 2) AS asp,
    ROUND((sales / NULLIF(order_item_quantity, 0))::numeric, 2) AS aur,
    ROUND(((order_item_discount / NULLIF(sales, 0)) * 100)::numeric, 2) AS discount_depth_pct
FROM retail_analytics.datacosupplychaindataset
WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD');

-- -----------------------------------------------------------------------------
-- 2. VIEW: Logistics & Delivery SLA Health (Fact Mart)
-- Tracks shipment delays, variance, and binary on-time delivery compliance
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS retail_analytics.v_logistics_delivery_health CASCADE;

CREATE VIEW retail_analytics.v_logistics_delivery_health AS
SELECT 
    order_id,
    order_item_id,
    order_date::date AS order_date,
    shipping_date::date AS shipping_date,
    shipping_mode,
    delivery_status,
    days_for_shipping_real,
    days_for_shipment_scheduled,
    (days_for_shipping_real - days_for_shipment_scheduled) AS lead_time_variance,
    CASE 
        WHEN (days_for_shipping_real - days_for_shipment_scheduled) > 0 THEN 1 
        ELSE 0 
    END AS is_late,
    CASE 
        WHEN (days_for_shipping_real - days_for_shipment_scheduled) <= 0 THEN 1 
        ELSE 0 
    END AS is_on_time,
    order_status
FROM retail_analytics.datacosupplychaindataset
WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD');

-- -----------------------------------------------------------------------------
-- 3. VIEW: Pareto ABC Revenue Analysis (Dimension Mart)
-- Window function cumulative sales analysis across the product catalog
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS retail_analytics.v_pareto_abc_analysis CASCADE;

CREATE VIEW retail_analytics.v_pareto_abc_analysis AS
WITH product_sales AS (
    SELECT 
        product_name,
        category_name,
        SUM(order_item_quantity) AS total_units_sold,
        SUM(order_item_total) AS total_net_revenue,
        COUNT(DISTINCT order_id) AS total_orders
    FROM retail_analytics.datacosupplychaindataset
    WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY product_name, category_name
),
cumulative_ranked AS (
    SELECT 
        product_name,
        category_name,
        total_units_sold,
        total_net_revenue,
        total_orders,
        SUM(total_net_revenue) OVER (ORDER BY total_net_revenue DESC) AS cumulative_revenue,
        SUM(total_net_revenue) OVER () AS catalog_total_revenue,
        ROUND(
            (SUM(total_net_revenue) OVER (ORDER BY total_net_revenue DESC) / 
             NULLIF(SUM(total_net_revenue) OVER (), 0) * 100)::numeric, 
            2
        ) AS cumulative_revenue_pct
    FROM product_sales
)
SELECT 
    product_name,
    category_name,
    total_units_sold,
    total_net_revenue,
    total_orders,
    cumulative_revenue,
    cumulative_revenue_pct,
    CASE 
        WHEN cumulative_revenue_pct <= 80.00 THEN 'A'
        WHEN cumulative_revenue_pct <= 95.00 THEN 'B'
        ELSE 'C'
    END AS abc_class
FROM cumulative_ranked;

-- -----------------------------------------------------------------------------
-- 4. VIEW: Customer RFM Segmentation (Dimension Mart)
-- Unified at customer_id level using empirical percentiles
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS retail_analytics.v_customer_rfm_segmentation CASCADE;

CREATE VIEW retail_analytics.v_customer_rfm_segmentation AS
WITH customer_base AS (
    SELECT 
        customer_id,
        (SELECT MAX(order_date::date) FROM retail_analytics.datacosupplychaindataset WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')) - MAX(order_date::date) AS recency_days,
        COUNT(DISTINCT order_id) AS frequency_orders,
        SUM(order_item_total) AS monetary_total_spend,
        MIN(order_date::date) AS first_order_date,
        MAX(order_date::date) AS last_order_date
    FROM retail_analytics.datacosupplychaindataset
    WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY customer_id
)
SELECT 
    customer_id,
    recency_days,
    frequency_orders,
    monetary_total_spend,
    first_order_date,
    last_order_date,
    CASE 
        -- High-Value At Risk: Frequent/VIP buyers drifting past median cycle (~159d) toward P75 (~307d)
        WHEN monetary_total_spend >= 2600 AND recency_days BETWEEN 160 AND 499 THEN 'High-Value At Risk (Re-engage Now)'
        -- Loyal High-Value: Active VIP accounts within typical cycle
        WHEN monetary_total_spend >= 2600 AND recency_days < 160 THEN 'Loyal High-Value'
        -- Lost High-Value: Past VIP buyers fully dormant (>500 days / past P90)
        WHEN monetary_total_spend >= 2600 AND recency_days >= 500 THEN 'Lost High-Value (Win-back Targets)'
        -- Recent New Buyers: First order within active window
        WHEN frequency_orders = 1 AND recency_days <= 120 THEN 'Recent New Buyers'
        -- Lapsing Customers: Intermittent buyers exceeding active cycle
        WHEN recency_days BETWEEN 121 AND 307 THEN 'Lapsing Customers (Needs Engagement)'
        -- Standard At Risk: Mid-tier buyers approaching dormant phase
        WHEN monetary_total_spend < 2600 AND recency_days BETWEEN 308 AND 499 THEN 'Standard At Risk'
        -- Lost Low-Engaged: Fully inactive low-frequency accounts
        ELSE 'Lost Low-Engaged'
    END AS customer_segment
FROM customer_base;
