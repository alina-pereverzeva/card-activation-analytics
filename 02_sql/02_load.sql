\copy card_lab.channels FROM '/project/data/raw/channels.csv' WITH (FORMAT csv, HEADER true)
\copy card_lab.customers FROM '/project/data/raw/customers.csv' WITH (FORMAT csv, HEADER true)
\copy card_lab.applications FROM '/project/data/raw/applications.csv' WITH (FORMAT csv, HEADER true)
\copy card_lab.cards FROM '/project/data/raw/cards.csv' WITH (FORMAT csv, HEADER true)
\copy card_lab.transactions FROM '/project/data/raw/transactions.csv' WITH (FORMAT csv, HEADER true)
ANALYZE card_lab.applications;
ANALYZE card_lab.cards;
ANALYZE card_lab.transactions;
