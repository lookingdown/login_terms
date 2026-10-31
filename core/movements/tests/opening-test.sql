-- The opening (sql/opening.sql) and the retirement (sql/retire.sql), on a scratch copy of its own: today's tables
-- filled with a small history in their own shapes (serials and their statuses, serial_events with the move's seeds
-- and a remessa's seeded trip, sale lines, the old ledger's balances), ported, proven, then retired. Run it on a
-- fresh copy after sql/layer.sql, sql/cube.sql, sql/readers.sql and sql/opening.sql, from core/movements (it reads
-- sql/retire.sql). Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- today's tables: the master and Prudente; a bike model, helmets, grease (a material); supplier 5's delivery (order
-- 10, line 301) and remessa 1 to Prudente; customer 7. Five units:
--   1  in stock at the master (a seed alone)          2  on the bench at the master (a seed alone)
--   3  received, sent on remessa 1, arrived, sold to customer 7 on a paid order, completed (its seeded trip)
--   4  sold at Prudente and refunded: returned (a seed alone)
--   5  sold to customer 7 at Prudente before the move (a seed alone), the order paid and completed
-- The ledger's balances: the master 2 bikes and 5 helmets, Prudente 1 bike and 2 helmets, grease 3 (not the layer's).
SET session_replication_role = replica;
INSERT INTO locations (id, code, name, kind) OVERRIDING SYSTEM VALUE VALUES (1, 'MTZ', 'Matriz', 'master'), (2, 'PRU', 'Prudente', 'shop');
INSERT INTO users (id, name, login, email, password_hash, location_id, role) OVERRIDING SYSTEM VALUE VALUES (1, 'Sistema', 'sistema', 's@example.com', 'x', 1, 'superadmin');
INSERT INTO items (id, name, serial, sellable) OVERRIDING SYSTEM VALUE VALUES (10, 'Moto X', true, true), (20, 'Capacete', false, true), (30, 'Graxa', false, false);
INSERT INTO variants (id, items_id, sku, low_stock) OVERRIDING SYSTEM VALUE VALUES (100, 10, 'MX-VERDE', NULL), (200, 20, 'CAP-M', 3), (300, 30, 'GRX', NULL);
INSERT INTO customers (id, email) OVERRIDING SYSTEM VALUE VALUES (7, 'cliente@example.com');
INSERT INTO suppliers (id, name) OVERRIDING SYSTEM VALUE VALUES (5, 'Fornecedor Teste');
INSERT INTO purchases (id, suppliers_id, supplier_name, status, location_id) OVERRIDING SYSTEM VALUE VALUES (10, 5, 'Fornecedor Teste', 'received', 1);
INSERT INTO purchase_items (id, purchases_id, variants_id, items_id, sku, qty_expected, qty_received, location_id) OVERRIDING SYSTEM VALUE
VALUES (301, 10, 100, 10, 'MX-VERDE', 1, 1, 1);
INSERT INTO transfers (id, shop_purchases_id, status, location_id, to_location_id) OVERRIDING SYSTEM VALUE VALUES (1, 20, 'received', 1, 2);
INSERT INTO transfer_items (transfers_id, variants_id, items_id, sku, qty) VALUES (1, 100, 10, 'MX-VERDE', 1);
INSERT INTO serials (id, variants_id, serial_number, status, location_id, purchase_items_id) OVERRIDING SYSTEM VALUE
VALUES (1, 100, 'O-0001', 'stock', 1, NULL), (2, 100, 'O-0002', 'assembly', 1, NULL), (3, 100, 'O-0003', 'sold', 2, 301),
       (4, 100, 'O-0004', 'returned', 2, NULL), (5, 100, 'O-0005', 'sold', 2, NULL);
INSERT INTO serial_events (serials_id, variants_id, event, to_status, location_id, ref_type, ref_id, at, happened_at) VALUES
    (1, 100, 'seed', 'stock', 1, NULL, NULL, '2026-09-22 09:00:01', '2026-09-22 09:00'),
    (2, 100, 'seed', 'assembly', 1, NULL, NULL, '2026-09-22 09:00:02', '2026-09-22 09:00'),
    (3, 100, 'seed', 'sold', 2, NULL, NULL, '2026-09-22 09:00:03', '2026-09-22 09:00'),
    (3, 100, 'received', NULL, 1, 'purchase_items', 301, '2026-09-22 09:00:04', '2026-09-01 00:00'),
    (3, 100, 'dispatched', 'transit', 1, 'transfers', 1, '2026-09-22 09:00:05', '2026-09-05 10:00'),
    (3, 100, 'arrived', 'stock', 2, 'transfers', 1, '2026-09-22 09:00:06', '2026-09-06 15:00'),
    (4, 100, 'seed', 'returned', 2, NULL, NULL, '2026-09-22 09:00:07', '2026-09-22 09:00'),
    (5, 100, 'seed', 'sold', 2, NULL, NULL, '2026-09-22 09:00:08', '2026-09-22 09:00');
INSERT INTO assembly (variants_id, serials_id, stage, stocked_at, location_id) VALUES (100, 3, 'delivered', '2026-09-03 16:00', 1);
INSERT INTO orders (id, ordercart_id, paid, paid_at, status, location_id, customers_id) OVERRIDING SYSTEM VALUE
VALUES (701, 'c-701', true, '2026-09-08 11:00', 'completed', 2, 7), (702, 'c-702', true, '2026-09-10 11:00', 'refunded', 2, 7),
       (703, 'c-703', true, '2026-09-12 11:00', 'completed', 2, 7);
INSERT INTO sales (orders_id, items_id, variants_id, sku, segment, item_name, quantity, unit_price, line_subtotal, line_total, serials_id, status, created_at, location_id)
VALUES (701, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 3, 'confirmed', '2026-09-08 11:00', 2),
       (702, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 4, 'refunded', '2026-09-10 11:00', 2),
       (703, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 5, 'confirmed', '2026-09-12 11:00', 2);
INSERT INTO stock (id, location_id, variants_id, qty, stock_after, type, created_at) OVERRIDING SYSTEM VALUE
VALUES (1, 1, 100, 2, 2, 'initial', '2026-09-22 09:00'), (2, 2, 100, 1, 1, 'initial', '2026-09-22 09:00'),
       (3, 1, 200, 5, 5, 'initial', '2026-09-22 09:00'), (4, 2, 200, 2, 2, 'initial', '2026-09-22 09:00'),
       (5, 1, 300, 3, 3, 'initial', '2026-09-22 09:00');
SELECT setval(pg_get_serial_sequence('public.serials', 'id'), 100) \g /dev/null
SET session_replication_role = origin;

\echo '== 1. the guard on this history. Expect no row.'
SELECT * FROM opening_guard();

\echo '== 2. a negative balance at Prudente. Expect MV900, the class and the row; nothing ported.'
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO stock (id, location_id, variants_id, qty, stock_after, type) OVERRIDING SYSTEM VALUE VALUES (6, 2, 200, -3, -1, 'adjust');
SET LOCAL session_replication_role = origin;
SELECT opening();
ROLLBACK;
SELECT count(*) AS movements FROM movements;

\echo '== 3. a unit whose story does not end where it stands: unit 6 at Prudente, its history at the master. Expect MV901 naming unit 6.'
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO serials (id, variants_id, serial_number, status, location_id) OVERRIDING SYSTEM VALUE VALUES (6, 100, 'O-0006', 'stock', 2);
INSERT INTO serial_events (serials_id, variants_id, event, to_status, location_id, ref_type, ref_id, happened_at) VALUES (6, 100, 'received', NULL, 1, 'purchase_items', 301, '2026-09-02');
UPDATE stock SET qty = 2, stock_after = 2 WHERE id = 2;
SET LOCAL session_replication_role = origin;
SELECT opening();
ROLLBACK;

\echo '== 4. the retirement before the opening. Expect MV902, and nothing touched: serials keeps its status.'
\i sql/retire.sql
SELECT count(*) AS serials_status_column FROM information_schema.columns WHERE table_name = 'serials' AND column_name = 'status';

\echo '== 5. the opening. Expect opened: 5 units, their steps, 4 counted legs (helmets at both; grease is a material).'
SELECT opening();

\echo '== 6. where each unit is now. Expect 1 at the master, 2 on its bench, 3 and 5 with customer 7, 4 back at Prudente.'
SELECT serials_id, place_kind, location_id, customers_id, owner_location_id, owner_customer_id, state FROM unit_positions ORDER BY serials_id;

\echo '== 7. unit 3''s line: its receipt, built, the remessa, sold, handed over; unit 4 sold and undone; unit 5 opened and sold.'
SELECT unit, why, place, owner, starts FROM cube_dots(p_units => '{3, 4, 5}', p_layers => '{fact}');

\echo '== 8. the counted goods and the second clock: the helmets at each place, recorded at the opening.'
SELECT location_id, variants_id, qty FROM stock_on_hand WHERE variants_id = 200 ORDER BY location_id;
SELECT kind, count(*) AS movements, bool_and(recorded_at >= occurred_at) AS recorded_since FROM movements GROUP BY kind ORDER BY kind;

\echo '== 9. the opening again. Expect {"opened": false}: it does nothing.'
SELECT opening();

\echo '== 10. the proof and the health checks. Expect no row, then every count 0.'
SELECT * FROM opening_proof();
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;

\echo '== 11. the old state retired. Expect serials keeping its identity, the ledger archived, variants.stock gone.'
\i sql/retire.sql
SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) AS serials_columns FROM information_schema.columns WHERE table_name = 'serials';
SELECT to_regclass('public.stock') AS stock, to_regclass('public.stock_archive') AS stock_archive,
       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'variants' AND column_name = 'stock') AS variants_stock;

\echo '== 12. after it: a delivery received (a unit minted with its identity alone), and helmets taken to their low stock (an alert, once).'
SET session_replication_role = replica;
INSERT INTO purchases (id, suppliers_id, supplier_name, status, location_id) OVERRIDING SYSTEM VALUE VALUES (11, 5, 'Fornecedor Teste', 'ordered', 1);
INSERT INTO purchase_items (id, purchases_id, variants_id, items_id, sku, qty_expected, location_id) OVERRIDING SYSTEM VALUE VALUES (311, 11, 100, 10, 'MX-VERDE', 1, 1);
SET session_replication_role = origin;
SELECT movement_receive(311, 1, '[{"serial_number": "O-0011"}]') ->> 'received' AS received;
SELECT s.serial_number, up.place_kind, up.location_id, up.state FROM unit_positions up JOIN serials s ON s.id = up.serials_id WHERE s.serial_number = 'O-0011';
SELECT movement_adjust('[{"variants_id": 200, "qty": -2}]', 'damaged', 'the shelf fell') ->> 'adjusted' AS adjusted;
SELECT movement_adjust('[{"variants_id": 200, "qty": -1}]', 'damaged', 'again') ->> 'adjusted' AS adjusted;
SELECT location_id, level, ref_id, title, detail FROM alerts WHERE type = 'stock' ORDER BY id;

\echo '== 13. the retirement again. Expect a notice that it is done already, and nothing changed.'
\i sql/retire.sql

\echo '== 14. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
