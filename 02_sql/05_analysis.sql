SET search_path TO card_lab, public;

-- 1. Overall customer funnel and conversion between adjacent steps.
WITH f AS (
 SELECT stage_order,stage,SUM(customers) AS customers
 FROM mart_funnel GROUP BY 1,2
)
SELECT *,ROUND(customers::numeric/NULLIF(LAG(customers) OVER (ORDER BY stage_order),0),4) AS step_conversion
FROM f ORDER BY stage_order;

-- 2. Compare acquisition channels with equal 30-day observation windows.
SELECT channel_name,applicants,eligible_30d,activated_30d,activation_rate_30d,
 turnover_per_received_30d,
 DENSE_RANK() OVER (ORDER BY activation_rate_30d DESC NULLS LAST) AS activation_rank
FROM mart_channels ORDER BY activation_rank;

-- 3. Weighted pooled retention: never take AVG of channel percentages.
SELECT cohort_month,month_number,SUM(active_customers) AS active_customers,
 SUM(cohort_size) AS cohort_size,
 ROUND(SUM(active_customers)::numeric/NULLIF(SUM(cohort_size),0),4) AS retention
FROM mart_retention GROUP BY 1,2 ORDER BY 1,2;

-- 4. First-purchase delay among activated clients only: this is NOT all recipients.
SELECT channel_name,COUNT(*) AS activated_clients,
 PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_first_purchase) AS median_days
FROM v_customer_lifecycle WHERE first_purchase_at IS NOT NULL GROUP BY 1;

-- 5. Monthly net purchase turnover; turnover is not bank revenue or profit.
SELECT activity_month,SUM(active_customers) AS active_customers,SUM(net_turnover) AS net_turnover
FROM mart_monthly WHERE is_complete_month GROUP BY 1 ORDER BY 1;

-- 6. Clients returning after a month with no successful purchases.
WITH x AS (
 SELECT *,LAG(purchases) OVER(PARTITION BY customer_id ORDER BY activity_month) AS previous_purchases,
 SUM(purchases) OVER(PARTITION BY customer_id ORDER BY activity_month
    ROWS BETWEEN UNBOUNDED PRECEDING AND 2 PRECEDING) AS older_purchases
 FROM mart_customer_month
)
SELECT activity_month,COUNT(*) AS reactivated_clients FROM x
WHERE purchases>0 AND previous_purchases=0 AND older_purchases>0 GROUP BY 1 ORDER BY 1;

-- 7. Inspect the actual plan. No unsupported claims of measured acceleration.
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id,COUNT(*),SUM(amount) FROM transactions
WHERE kind='purchase' AND status='success'
 AND transaction_at>=DATE '2026-10-01' AND transaction_at<DATE '2026-11-01'
GROUP BY card_id;
