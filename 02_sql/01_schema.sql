-- Only this demo's dedicated schema is reset; never run against production data.
DROP SCHEMA IF EXISTS card_lab CASCADE;
CREATE SCHEMA card_lab;
SET search_path TO card_lab, public;

CREATE TABLE analysis_config (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    as_of_date date NOT NULL
);
INSERT INTO analysis_config VALUES (true, DATE '2026-10-31');

CREATE TABLE channels (
    channel_id integer PRIMARY KEY,
    channel_name text NOT NULL UNIQUE
);
CREATE TABLE customers (
    customer_id integer PRIMARY KEY,
    registered_at date NOT NULL
);
CREATE TABLE applications (
    application_id integer PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES customers,
    channel_id integer NOT NULL REFERENCES channels,
    applied_at date NOT NULL,
    status text NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
    decided_at date,
    CHECK (decided_at >= applied_at),
    CHECK ((status = 'pending') = (decided_at IS NULL))
);
CREATE TABLE cards (
    card_id integer PRIMARY KEY,
    application_id integer NOT NULL REFERENCES applications,
    issued_at date NOT NULL,
    received_at date,
    CHECK (received_at >= issued_at)
);
CREATE TABLE transactions (
    transaction_id integer PRIMARY KEY,
    card_id integer NOT NULL REFERENCES cards,
    transaction_at date NOT NULL,
    kind text NOT NULL CHECK (kind IN ('purchase', 'refund')),
    status text NOT NULL CHECK (status IN ('success', 'declined')),
    amount numeric(14,2) NOT NULL CHECK (amount > 0),
    original_transaction_id integer REFERENCES transactions,
    CHECK ((kind = 'refund') = (original_transaction_id IS NOT NULL)),
    CHECK (kind != 'refund' OR status = 'success')
);
CREATE INDEX ix_applications_customer ON applications(customer_id, applied_at, application_id);
CREATE INDEX ix_cards_application ON cards(application_id);
CREATE INDEX ix_transactions_card_date ON transactions(card_id, transaction_at);
CREATE INDEX ix_successful_purchases ON transactions(transaction_at, card_id)
    WHERE kind = 'purchase' AND status = 'success';
