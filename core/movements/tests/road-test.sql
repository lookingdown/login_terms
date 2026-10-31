-- The remessa corrections, on the fixture after sale-test.sql: remessa 58 dispatched with a bike and three helmets,
-- then a chassis swapped, a helmet not sent, one lost on the way, the rest arriving. Run it after sale-test.sql.
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents: remessa 58 to Prudente, its draft holding the bike numbered 9C2KC1650PR000010 (received in
-- receive-test, on the bench; :bike, found by its number, since an id is the sequence's), its shop order 11 and lines;
-- order 900's line refunded, which frees bike 501
SELECT id AS bike FROM serials WHERE serial_number = '9C2KC1650PR000010' \gset
SET session_replication_role = replica;
INSERT INTO purchases (id, supplier_name, status, location_id, source_location_id) OVERRIDING SYSTEM VALUE VALUES (11, 'Matriz', 'ordered', 2, 1);
INSERT INTO purchase_items (id, purchases_id, variants_id, items_id, sku, qty_expected) OVERRIDING SYSTEM VALUE
VALUES (321, 11, 100, 10, 'MX-VERDE', 1), (322, 11, 200, 20, 'CAP-M', 3);
INSERT INTO transfers (id, shop_purchases_id, status, location_id, to_location_id, expected_at) OVERRIDING SYSTEM VALUE
VALUES (58, 11, 'sent', 1, 2, date_trunc('day', LOCALTIMESTAMP) + interval '1 day 15 hours');
INSERT INTO transfer_items (transfers_id, variants_id, items_id, sku, qty, shop_purchase_items_id)
VALUES (58, 100, 10, 'MX-VERDE', 1, 321), (58, 200, 20, 'CAP-M', 3, 322);
INSERT INTO transfer_units VALUES (58, :bike);
SET session_replication_role = origin;

\echo '== 1. remessa 58 dispatched. Expect {"legs": 4}: the bike and three helmets on the road.'
SELECT movement_dispatch(58);

\echo '== 2. the bike that went was bike 501, still held by order 900. Expect MV076.'
SELECT movement_swap(58, :bike, 501);

\echo '== 3. order 900''s line refunded; now the swap. Expect the bike back at the master, bike 501 on the road since the dispatch.'
SET session_replication_role = replica;
UPDATE sales SET status = 'refunded' WHERE orders_id = 900;
SET session_replication_role = origin;
SELECT movement_swap(58, :bike, 501, 'the van carried 501');
SELECT serials_id, place_kind, transfers_id, location_id FROM unit_positions WHERE serials_id IN (:bike, 501) ORDER BY serials_id;
SELECT serials_id FROM transfer_units WHERE transfers_id = 58;

\echo '== 4. a bike received after the dispatch, swapped in. Expect MV077.'
SELECT movement_receive(301, 2);
SELECT movement_swap(58, 501, (SELECT max(id) FROM serials WHERE purchase_items_id = 301));

\echo '== 5. a swap from Prudente''s seat. Expect MV070.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_swap(58, 501, :bike);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 6. one helmet not sent. Expect it back at the master, two on the road.'
SELECT qty AS helmets_at_the_master FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200;
SELECT movement_not_sent(58, 200, 1, '[]', 'left in the yard');
SELECT qty AS helmets_at_the_master FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200;

\echo '== 7. five helmets not sent, of two. Expect MV072.'
SELECT movement_not_sent(58, 200, 5, '[]');

\echo '== 8. bike 504, not on this road, taken off it. Expect MV071.'
SELECT movement_not_sent(58, 100, 1, '[504]');

\echo '== 9. a bike taken off by quantity. Expect MV073.'
SELECT movement_not_sent(58, 100, 1, '[]');

\echo '== 10. a helmet lost, no one bearing it. Expect MV074.'
SELECT movement_lost(58, 200, 1, '[]', NULL);

\echo '== 11. a helmet lost on the way, the carrier''s. Expect it written off on the road; one helmet and bike 501 carried.'
SELECT movement_lost(58, 200, 1, '[]', 'carrier', 'fell off the van');
SELECT state, qty FROM positions WHERE at_transfer_id = 58 AND variants_id = 200 ORDER BY state;

\echo '== 12. at Prudente: bike 501 and the last helmet. Expect the road empty of what it carries: on_road 0.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_arrive(58, 321, 0, '[501]');
SELECT movement_arrive(58, 322, 1);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 13. the bike''s line and bike 501''s: what happened, in order.'
SELECT unit, why, place, owner, starts = ends AS instant FROM cube_dots(p_units => ARRAY[:bike, 501], p_layers => '{fact}');

\echo '== 14. the health checks, once the remessa is marked received. Expect every count 0.'
SET session_replication_role = replica;
UPDATE transfers SET status = 'received' WHERE id = 58;
SET session_replication_role = origin;
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
