SET search_path TO card_lab, public;

-- Transaction grain: one row per transaction, never multiply by all client cards.
CREATE VIEW v_transactions AS
SELECT t.*, a.customer_id,
       CASE WHEN t.status != 'success' THEN 0
            WHEN t.kind = 'refund' THEN -t.amount ELSE t.amount END AS net_amount
FROM transactions t
JOIN cards c USING (card_id)
JOIN applications a USING (application_id)
CROSS JOIN analysis_config cfg
WHERE t.transaction_at <= cfg.as_of_date;

-- Customer grain: aggregate each one-to-many table BEFORE joining.
CREATE VIEW v_customer_lifecycle AS
WITH ranked_applications AS (
    SELECT a.*, ROW_NUMBER() OVER (
        PARTITION BY customer_id ORDER BY applied_at, application_id
    ) AS rn
    FROM applications a CROSS JOIN analysis_config cfg
    WHERE a.applied_at <= cfg.as_of_date
), approvals AS (
    SELECT customer_id, MIN(decided_at) AS approved_at
    FROM applications CROSS JOIN analysis_config cfg
    WHERE status = 'approved' AND decided_at <= cfg.as_of_date
    GROUP BY customer_id
), receipts AS (
    SELECT a.customer_id, MIN(c.received_at) AS received_at
    FROM cards c JOIN applications a USING (application_id)
    CROSS JOIN analysis_config cfg
    WHERE c.received_at <= cfg.as_of_date
    GROUP BY a.customer_id
), purchases AS (
    SELECT customer_id, MIN(transaction_at) AS first_purchase_at
    FROM v_transactions WHERE kind = 'purchase' AND status = 'success'
    GROUP BY customer_id
)
SELECT a.customer_id, a.channel_id, ch.channel_name, a.applied_at,
       ap.approved_at, r.received_at, p.first_purchase_at,
       p.first_purchase_at - r.received_at AS days_to_first_purchase,
       DATE_TRUNC('month', p.first_purchase_at)::date AS cohort_month,
       COALESCE(r.received_at + 7 <= cfg.as_of_date, false) AS eligible_7d,
       COALESCE(r.received_at + 30 <= cfg.as_of_date, false) AS eligible_30d,
       COALESCE(p.first_purchase_at <= r.received_at + 7, false) AS activated_7d,
       COALESCE(p.first_purchase_at <= r.received_at + 30, false) AS activated_30d
FROM ranked_applications a
JOIN channels ch USING (channel_id)
LEFT JOIN approvals ap USING (customer_id)
LEFT JOIN receipts r USING (customer_id)
LEFT JOIN purchases p USING (customer_id)
CROSS JOIN analysis_config cfg
WHERE a.rn = 1;

CREATE VIEW mart_funnel AS
SELECT l.channel_name, s.stage_order, s.stage, COUNT(*) FILTER (WHERE s.reached) AS customers
FROM v_customer_lifecycle l
CROSS JOIN LATERAL (VALUES
    (1, '01 Application', true),
    (2, '02 Approved', l.approved_at IS NOT NULL),
    (3, '03 Card received', l.received_at IS NOT NULL),
    (4, '04 First purchase', l.first_purchase_at IS NOT NULL)
) s(stage_order, stage, reached)
GROUP BY l.channel_name, s.stage_order, s.stage;

CREATE VIEW mart_channels AS
WITH customer_money AS (
    SELECT l.customer_id,
        COALESCE(SUM(t.net_amount), 0) AS net_turnover,
        -- Equal window: days 0..30 after receipt, only mature clients in the KPI.
        COALESCE(SUM(t.net_amount) FILTER (
            WHERE t.transaction_at BETWEEN l.received_at AND l.received_at + 30
        ), 0) AS net_turnover_30d
    FROM v_customer_lifecycle l LEFT JOIN v_transactions t USING (customer_id)
    GROUP BY l.customer_id
)
SELECT l.channel_name, COUNT(*) AS applicants,
    COUNT(*) FILTER (WHERE l.approved_at IS NOT NULL) AS approved,
    COUNT(*) FILTER (WHERE l.received_at IS NOT NULL) AS received,
    COUNT(*) FILTER (WHERE l.first_purchase_at IS NOT NULL) AS activated,
    COUNT(*) FILTER (WHERE l.eligible_7d) AS eligible_7d,
    COUNT(*) FILTER (WHERE l.eligible_7d AND l.activated_7d) AS activated_7d,
    COUNT(*) FILTER (WHERE l.eligible_30d) AS eligible_30d,
    COUNT(*) FILTER (WHERE l.eligible_30d AND l.activated_30d) AS activated_30d,
    ROUND(COUNT(*) FILTER (WHERE l.eligible_7d AND l.activated_7d)::numeric /
          NULLIF(COUNT(*) FILTER (WHERE l.eligible_7d), 0), 6) AS activation_rate_7d,
    ROUND(COUNT(*) FILTER (WHERE l.eligible_30d AND l.activated_30d)::numeric /
          NULLIF(COUNT(*) FILTER (WHERE l.eligible_30d), 0), 6) AS activation_rate_30d,
    SUM(m.net_turnover) AS net_turnover,
    COALESCE(SUM(m.net_turnover_30d) FILTER (WHERE l.eligible_30d),0) AS net_turnover_30d,
    ROUND(AVG(m.net_turnover_30d) FILTER (WHERE l.eligible_30d),2) AS turnover_per_received_30d
FROM v_customer_lifecycle l JOIN customer_money m USING (customer_id)
GROUP BY l.channel_name;

-- Dense client-month spine: LAG refers to the previous CALENDAR month,
-- including months without transactions. Rows start at first receipt.
CREATE VIEW mart_customer_month AS
WITH monthly AS (
    SELECT customer_id, DATE_TRUNC('month',transaction_at)::date AS activity_month,
        COUNT(*) FILTER (WHERE kind = 'purchase' AND status = 'success') AS purchases,
        SUM(CASE WHEN kind = 'purchase' AND status = 'success' THEN amount ELSE 0 END) AS gross_turnover,
        SUM(CASE WHEN kind = 'refund' AND status = 'success' THEN amount ELSE 0 END) AS refunds,
        SUM(net_amount) AS net_turnover
    FROM v_transactions GROUP BY 1,2
), dense AS (
    SELECT l.customer_id,l.channel_name,gs.month::date AS activity_month,
        COALESCE(m.purchases,0) AS purchases, COALESCE(m.gross_turnover,0) AS gross_turnover,
        COALESCE(m.refunds,0) AS refunds,COALESCE(m.net_turnover,0) AS net_turnover
    FROM v_customer_lifecycle l CROSS JOIN analysis_config cfg
    CROSS JOIN LATERAL GENERATE_SERIES(DATE_TRUNC('month',l.received_at),
        DATE_TRUNC('month',cfg.as_of_date),INTERVAL '1 month') gs(month)
    LEFT JOIN monthly m ON m.customer_id=l.customer_id AND m.activity_month=gs.month::date
)
SELECT *, LAG(net_turnover) OVER (PARTITION BY customer_id ORDER BY activity_month) AS previous_month_turnover,
    net_turnover - LAG(net_turnover) OVER (PARTITION BY customer_id ORDER BY activity_month) AS turnover_change
FROM dense;

CREATE VIEW mart_monthly AS
SELECT m.channel_name,m.activity_month,
    COUNT(*) FILTER (WHERE m.purchases>0) AS active_customers,
    SUM(m.purchases) AS purchases,SUM(m.gross_turnover) AS gross_turnover,
    SUM(m.refunds) AS refunds,SUM(m.net_turnover) AS net_turnover,
    (m.activity_month + INTERVAL '1 month' - INTERVAL '1 day')::date <= cfg.as_of_date AS is_complete_month
FROM mart_customer_month m CROSS JOIN analysis_config cfg
GROUP BY m.channel_name,m.activity_month,cfg.as_of_date;

-- Calendar-month retention; not rolling retention and not exact 30-day retention.
-- Only fully observed months are emitted. Future periods remain absent, not zero.
CREATE VIEW mart_retention AS
WITH sizes AS (
    SELECT channel_name,cohort_month,COUNT(*) AS cohort_size
    FROM v_customer_lifecycle WHERE cohort_month IS NOT NULL GROUP BY 1,2
), active AS (
    SELECT l.channel_name,l.cohort_month,m.activity_month,COUNT(*) AS active_customers
    FROM mart_customer_month m JOIN v_customer_lifecycle l USING (customer_id)
    WHERE m.purchases>0 GROUP BY 1,2,3
)
SELECT s.channel_name,s.cohort_month,gs.month::date AS activity_month,
    ((EXTRACT(YEAR FROM gs.month)-EXTRACT(YEAR FROM s.cohort_month))*12
     + EXTRACT(MONTH FROM gs.month)-EXTRACT(MONTH FROM s.cohort_month))::int AS month_number,
    s.cohort_size,COALESCE(a.active_customers,0) AS active_customers,
    ROUND(COALESCE(a.active_customers,0)::numeric/NULLIF(s.cohort_size,0),6) AS retention_rate
FROM sizes s CROSS JOIN analysis_config cfg
CROSS JOIN LATERAL GENERATE_SERIES(s.cohort_month,
    DATE_TRUNC('month',cfg.as_of_date),INTERVAL '1 month') gs(month)
LEFT JOIN active a ON a.channel_name=s.channel_name AND a.cohort_month=s.cohort_month
    AND a.activity_month=gs.month::date
WHERE (gs.month + INTERVAL '1 month' - INTERVAL '1 day')::date <= cfg.as_of_date;

CREATE VIEW mart_activation_days AS
SELECT channel_name,CASE WHEN days_to_first_purchase <=7 THEN '01 Days 0-7'
    WHEN days_to_first_purchase<=30 THEN '02 Days 8-30'
    WHEN days_to_first_purchase IS NOT NULL THEN '03 Days 31+'
    ELSE '04 No purchase yet' END AS activation_bucket,
    COUNT(*) AS customers
FROM v_customer_lifecycle WHERE received_at IS NOT NULL AND eligible_30d
GROUP BY 1,2;
