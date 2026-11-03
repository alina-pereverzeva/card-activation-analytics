SET search_path TO card_lab, public;
CREATE OR REPLACE VIEW qa_checks AS
SELECT 'lifecycle_one_row_per_applicant' AS check_name,
    ABS((SELECT COUNT(*) FROM v_customer_lifecycle) -
        (SELECT COUNT(DISTINCT customer_id) FROM applications)) AS failures
UNION ALL SELECT 'no_duplicate_lifecycle', COUNT(*)-COUNT(DISTINCT customer_id) FROM v_customer_lifecycle
UNION ALL SELECT 'no_future_events', COUNT(*) FROM (
    SELECT registered_at AS d FROM customers UNION ALL SELECT applied_at FROM applications
    UNION ALL SELECT decided_at FROM applications UNION ALL SELECT issued_at FROM cards
    UNION ALL SELECT received_at FROM cards UNION ALL SELECT transaction_at FROM transactions
) t CROSS JOIN analysis_config cfg WHERE t.d>cfg.as_of_date
UNION ALL SELECT 'valid_card_application',COUNT(*) FROM cards c JOIN applications a USING(application_id)
    WHERE a.status!='approved' OR c.issued_at<a.decided_at
UNION ALL SELECT 'applications_after_registration',COUNT(*) FROM applications a JOIN customers c USING(customer_id)
    WHERE a.applied_at<c.registered_at
UNION ALL SELECT 'transactions_after_receipt',COUNT(*) FROM transactions t JOIN cards c USING(card_id)
    WHERE c.received_at IS NULL OR t.transaction_at<c.received_at
UNION ALL SELECT 'valid_refund_reference',COUNT(*) FROM transactions r
    JOIN transactions p ON p.transaction_id=r.original_transaction_id
    WHERE r.kind='refund' AND (p.kind!='purchase' OR p.status!='success'
        OR r.card_id!=p.card_id OR r.transaction_at<p.transaction_at)
UNION ALL SELECT 'refund_not_above_purchase',COUNT(*) FROM (
    SELECT p.transaction_id FROM transactions p JOIN transactions r ON r.original_transaction_id=p.transaction_id
    WHERE r.status='success' GROUP BY p.transaction_id,p.amount HAVING SUM(r.amount)>p.amount
) t
UNION ALL SELECT 'ordered_lifecycle',COUNT(*) FROM v_customer_lifecycle
    WHERE approved_at<applied_at OR received_at<approved_at OR first_purchase_at<received_at
UNION ALL SELECT 'channel_counts_valid',COUNT(*) FROM mart_channels
    WHERE activated>received OR received>approved OR approved>applicants
       OR activated_7d>eligible_7d OR activated_30d>eligible_30d
UNION ALL SELECT 'retention_in_range',COUNT(*) FROM mart_retention
    WHERE retention_rate<0 OR retention_rate>1 OR active_customers>cohort_size
UNION ALL SELECT 'retention_m0_equals_one',COUNT(*) FROM mart_retention
    WHERE month_number=0 AND active_customers!=cohort_size
UNION ALL SELECT 'no_incomplete_retention_month',COUNT(*) FROM mart_retention CROSS JOIN analysis_config cfg
    WHERE (activity_month+INTERVAL '1 month'-INTERVAL '1 day')::date>cfg.as_of_date
UNION ALL SELECT 'money_reconciles',CASE WHEN
    (SELECT SUM(net_amount) FROM v_transactions) = (SELECT SUM(net_turnover) FROM mart_monthly)
    AND (SELECT SUM(net_amount) FROM v_transactions) = (SELECT SUM(net_turnover) FROM mart_channels)
    THEN 0 ELSE 1 END;

DO $$ DECLARE r record; BEGIN
    FOR r IN SELECT * FROM card_lab.qa_checks WHERE failures != 0 LOOP
        RAISE EXCEPTION 'Quality check failed: %, failures=%',r.check_name,r.failures;
    END LOOP;
END $$;
SELECT * FROM qa_checks ORDER BY check_name;
