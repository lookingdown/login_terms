-- movement_dispatch, the views, the time axis and the health checks on imobee's own schema (PostgreSQL 18).
-- Run on a scratch copy after sql/layer.sql: psql -d scratch -f dispatch-test.sql
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;

-- the connect step: today's tables default location_id to app_location()
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the fixture's plain rows go in with today's triggers paused (the serial_events trigger and the document
-- guards keep a session to its own location); the layer's own trigger runs for every leg below
SET session_replication_role = replica;
TRUNCATE movement_legs, movements, positions, transfer_units, transfer_items, transfers, sales, orders, assembly,
         serials, variants, items, users, locations RESTART IDENTITY CASCADE;
INSERT INTO locations (id, code, name, kind) OVERRIDING SYSTEM VALUE VALUES (1, 'MTZ', 'Matriz', 'master'), (2, 'PRU', 'Prudente', 'shop');
INSERT INTO users (id, name, login, email, password_hash, location_id, role) OVERRIDING SYSTEM VALUE
VALUES (1, 'Johan', 'johan', 'j@example.com', 'x', 1, 'superadmin');
INSERT INTO items (id, name, serial, sellable) OVERRIDING SYSTEM VALUE VALUES (10, 'Moto X', true, true), (20, 'Capacete', false, true);
INSERT INTO variants (id, items_id, sku) OVERRIDING SYSTEM VALUE VALUES (100, 10, 'MX-VERDE'), (200, 20, 'CAP-M');
INSERT INTO serials (id, variants_id, serial_number, status, location_id) OVERRIDING SYSTEM VALUE
VALUES (500, 100, '9C2KC1650PR000001', 'stock', 1), (501, 100, '9C2KC1650PR000002', 'stock', 1),
       (502, 100, '9C2KC1650PR000003', 'stock', 1), (503, 100, '9C2KC1650PR000004', 'stock', 1),
       (504, 100, '9C2KC1650PR000005', 'assembly', 1);
INSERT INTO assembly (id, variants_id, serials_id, stage, location_id) OVERRIDING SYSTEM VALUE
VALUES (81, 100, 504, 'in_process', 1), (82, 100, 501, 'delivered', 1);
-- 55 and 56 expected at Prudente the day after tomorrow at 09:00; 57 was sent without an expected arrival
INSERT INTO transfers (id, shop_purchases_id, status, location_id, to_location_id, expected_at) OVERRIDING SYSTEM VALUE
VALUES (55, 1, 'draft', 1, 2, date_trunc('day', LOCALTIMESTAMP) + interval '2 days 9 hours'),
       (56, 2, 'sent', 1, 2, date_trunc('day', LOCALTIMESTAMP) + interval '2 days 9 hours'),
       (57, 4, 'sent', 1, 2, NULL);
INSERT INTO transfer_items (transfers_id, variants_id, items_id, sku, qty)
VALUES (55, 100, 10, 'MX-VERDE', 1), (55, 200, 20, 'CAP-M', 2), (56, 200, 20, 'CAP-M', 9);
INSERT INTO transfer_units VALUES (55, 500);
INSERT INTO orders (id, ordercart_id, paid, status, location_id) OVERRIDING SYSTEM VALUE
VALUES (900, 'c-900', false, 'pending', 1), (901, 'c-901', true, 'paid', 1);
INSERT INTO sales (orders_id, items_id, variants_id, sku, segment, item_name, quantity, unit_price, line_subtotal, line_total, serials_id, location_id)
VALUES (900, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 501, 1),    -- bike 501 on an unpaid order
       (901, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, NULL, 1);   -- a paid line waiting for its unit
SET session_replication_role = origin;

-- the opening, on 1 Oct: four bikes and five helmets at the master, and bike 504 on the bench, from the books
WITH m AS (INSERT INTO movements (kind, occurred_at) VALUES ('opening', '2026-10-01 09:00') RETURNING id)
INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, owner_location_id, state)
SELECT m.id, x.* FROM m, (VALUES
    (100::int8, 500, -1, NULL::int4, NULL::int4, 'available'), (100, 500, 1, 1, 1, 'available'),
    (100, 501, -1, NULL, NULL, 'available'), (100, 501, 1, 1, 1, 'available'),
    (100, 502, -1, NULL, NULL, 'available'), (100, 502, 1, 1, 1, 'available'),
    (100, 503, -1, NULL, NULL, 'available'), (100, 503, 1, 1, 1, 'available'),
    (100, 504, -1, NULL, NULL, 'validating'), (100, 504, 1, 1, 1, 'validating'),
    (200, NULL, -5, NULL, NULL, 'available'), (200, NULL, 5, 1, 1, 'available')) x;

\echo '== 1. a shop seat dispatches. Expect MV010.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_dispatch(55);
\echo '== 2. the master dispatches a draft. Expect MV012.'
SELECT set_config('app.location', '1', false) \g /dev/null
SELECT movement_dispatch(55);
\echo '== 3. the module sets it sent, then dispatches. Expect {"legs": 4}.'
UPDATE transfers SET status = 'sent' WHERE id = 55;
SELECT movement_dispatch(55);
\echo '== 4. dispatched again. Expect MV013.'
SELECT movement_dispatch(55);
\echo '== 5. nine helmets when three are left. Expect MV017, its facts on one line.'
SELECT movement_dispatch(56);
\echo '== 6. a remessa without an expected arrival. Expect MV018.'
SELECT movement_dispatch(57);
\echo '== 7. where things are now: bike 500 on road 55, still the master''s; two helmets beside it'
SELECT serials_id, place_kind, transfers_id, owner_location_id, state FROM unit_positions WHERE serials_id = 500;
SELECT variants_id, coalesce('location ' || at_location_id, 'road ' || at_transfer_id, 'the books') AS cell, owner_location_id AS owner, qty
  FROM positions ORDER BY variants_id, cell;
\echo '== 8. sellable at the master: three bikes, one on an unpaid order, one paid line waiting. Expect bikes 1, helmets 3.'
SELECT location_id, variants_id, qty AS sellable FROM stock_sellable ORDER BY variants_id;
\echo '== 9. the time axis: the master on 15 Oct, and where bike 500 stood then and stands now.'
SELECT * FROM stock_at('2026-10-15') ORDER BY 1, 2;
SELECT 'then: ' || coalesce('location ' || at_location_id, 'road ' || at_transfer_id) AS unit_500 FROM unit_at(500, '2026-10-15')
UNION ALL
SELECT 'now:  ' || coalesce('location ' || at_location_id, 'road ' || at_transfer_id) FROM unit_at(500, LOCALTIMESTAMP);
\echo '== 10. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
\echo '== 11. a leg edited by hand. Expect refused.'
UPDATE movement_legs SET qty = 2 WHERE id = 1;
\echo '== 12. an unknown unit is built. Expect MV020.'
SELECT movement_built(999999, 81);
\echo '== 13. bike 500 built by the job of bike 504. Expect MV021.'
SELECT movement_built(500, 81);
\echo '== 14. bike 504 back to the bench while it is on it. Expect MV025.'
SELECT movement_back_to_bench(504, 81);
\echo '== 15. bike 504 built from Prudente''s seat. Expect MV023.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_built(504, 81);
SELECT set_config('app.location', '1', false) \g /dev/null
\echo '== 16. bike 501 back to the bench: order 900 holds it. Expect MV024.'
SELECT movement_back_to_bench(501, 82);
\echo '== 17. an empty app.user. Expect MV001.'
SELECT set_config('app.user', '', false) \g /dev/null
SELECT movement_dispatch(56);
