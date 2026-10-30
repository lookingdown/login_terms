-- movement_dispatch on imobee's own tables (PostgreSQL 18). Run after movements-layer.sql on a scratch copy.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
-- a scratch copy only: clear the fixture, the append-only triggers paused for this session
SET session_replication_role = replica;
TRUNCATE movement_legs, movements, positions, transfer_units, transfer_items, transfers, sales, orders, serials, variants,
         items, users, locations RESTART IDENTITY CASCADE;
SET session_replication_role = origin;
-- the connect step: today's tables default location_id to app_location()
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null
BEGIN;
INSERT INTO locations (id, code, name, kind) OVERRIDING SYSTEM VALUE VALUES (1, 'MTZ', 'Matriz', 'master'), (2, 'PRU', 'Prudente', 'shop');
INSERT INTO users (id, name, login, email, password_hash, location_id, role) OVERRIDING SYSTEM VALUE VALUES (1, 'Johan', 'johan', 'j@example.com', 'x', 1, 'superadmin');
INSERT INTO items (id, name, serial, sellable) OVERRIDING SYSTEM VALUE VALUES (10, 'Moto X', true, true), (20, 'Capacete', false, true);
INSERT INTO variants (id, items_id, sku) OVERRIDING SYSTEM VALUE VALUES (100, 10, 'MX-VERDE'), (200, 20, 'CAP-M');
INSERT INTO serials (id, variants_id, serial_number, status, location_id) OVERRIDING SYSTEM VALUE VALUES (500, 100, '9C2KC1650PR000001', 'stock', 1);
INSERT INTO transfers (id, shop_purchases_id, status, location_id, to_location_id) OVERRIDING SYSTEM VALUE VALUES (55, 1, 'draft', 1, 2), (56, 2, 'sent', 1, 2);
INSERT INTO transfer_items (transfers_id, variants_id, items_id, sku, qty) VALUES (55, 100, 10, 'MX-VERDE', 1), (55, 200, 20, 'CAP-M', 2), (56, 200, 20, 'CAP-M', 9);
INSERT INTO transfer_units VALUES (55, 500);
-- the opening: the bike and five helmets at the master, from the books
WITH m AS (INSERT INTO movements (kind) VALUES ('opening') RETURNING id)
INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, owner_location_id, state)
SELECT m.id, x.* FROM m, (VALUES (100::int8, 500, -1, NULL::int4, NULL::int4, 'available'), (100, 500, 1, 1, 1, 'available'),
                                 (200, NULL, -5, NULL, NULL, 'available'), (200, NULL, 5, 1, 1, 'available')) x;
COMMIT;

\echo '== 1. a shop seat dispatches. Expect MV010.'
SELECT set_config('app.location', '2', false), set_config('app.user', '1', false) \g /dev/null
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
\set VERBOSITY default
SELECT movement_dispatch(56);
\echo '== 6. where things are now'
SELECT serials_id, serial_number, place_kind, transfers_id, owner_location_id, state FROM unit_positions;
SELECT variants_id, coalesce('location ' || at_location_id, 'road ' || at_transfer_id, 'the books') AS cell, owner_location_id AS owner, qty
  FROM positions ORDER BY variants_id, cell;
\echo '== 7. sellable: three more bikes arrive; one is on an unpaid order, one paid line waits for its unit. Expect 1.'
INSERT INTO serials (id, variants_id, serial_number, status, location_id) OVERRIDING SYSTEM VALUE
VALUES (501, 100, '9C2KC1650PR000002', 'stock', 1), (502, 100, '9C2KC1650PR000003', 'stock', 1), (503, 100, '9C2KC1650PR000004', 'stock', 1);
WITH m AS (INSERT INTO movements (kind) VALUES ('opening') RETURNING id)
INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, owner_location_id, state)
SELECT m.id, 100, u, q, CASE WHEN q = 1 THEN 1 END, CASE WHEN q = 1 THEN 1 END, 'available'
  FROM m, (VALUES (501), (502), (503)) s(u), (VALUES (-1), (1)) d(q);
INSERT INTO orders (id, ordercart_id, paid, status, location_id) OVERRIDING SYSTEM VALUE VALUES (900, 'c-900', false, 'pending', 1), (901, 'c-901', true, 'paid', 1);
INSERT INTO sales (orders_id, items_id, variants_id, sku, segment, item_name, quantity, unit_price, line_subtotal, line_total, serials_id, location_id)
VALUES (900, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 501, 1),
       (901, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, NULL, 1);
SELECT location_id, variants_id, qty AS sellable FROM stock_sellable WHERE variants_id = 100;
\echo '== 8. a leg edited by hand. Expect refused.'
UPDATE movement_legs SET qty = 2 WHERE id = 1;
\echo '== 9. an empty app.user. Expect MV001.'
SELECT set_config('app.user', '', false) \g /dev/null
SELECT movement_dispatch(56);
