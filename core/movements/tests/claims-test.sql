-- The claims, then the write-off and the return to the provider, on the fixture after road-test.sql: four new bikes
-- at the master, a draft, two orders, a fleet resource, two approvals. Run it after road-test.sql.
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents: bikes 510 to 513; draft 59 to Prudente; orders 907 (not paid) and 908 (paid), each a bike line
-- without its unit, for customer 8; fleet resource 2, of the bike's model; approvals 1 (bike 512) and 2 (bike 513)
SET session_replication_role = replica;
INSERT INTO serials (id, variants_id, serial_number, location_id) OVERRIDING SYSTEM VALUE
VALUES (510, 100, '9C2KC1650PR000510', 1), (511, 100, '9C2KC1650PR000511', 1), (512, 100, '9C2KC1650PR000512', 1),
       (513, 100, '9C2KC1650PR000513', 1);
INSERT INTO transfers (id, shop_purchases_id, status, location_id, to_location_id, expected_at) OVERRIDING SYSTEM VALUE
VALUES (59, 12, 'draft', 1, 2, date_trunc('day', LOCALTIMESTAMP) + interval '3 days 11 hours');
INSERT INTO orders (id, ordercart_id, paid, status, location_id, customers_id) OVERRIDING SYSTEM VALUE
VALUES (907, 'c-907', false, 'pending', 1, 8), (908, 'c-908', true, 'paid', 1, 8);
INSERT INTO sales (orders_id, items_id, variants_id, sku, segment, item_name, quantity, unit_price, line_subtotal, line_total, serials_id, location_id)
VALUES (907, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, NULL, 1),
       (908, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, NULL, 1);
INSERT INTO resources (id, resource_type_id, variants_id, name, location_id) OVERRIDING SYSTEM VALUE VALUES (2, 1, 100, 'Moto X da frota, 2', 1);
INSERT INTO approvals (id, action, ref_type, ref_id, requested_by, approved_by, approved_via, reason, location_id) OVERRIDING SYSTEM VALUE
VALUES (1, 'baixa_moto', 'serials', 512, 1, 1, 'self', 'theft', 1), (2, 'baixa_moto', 'serials', 513, 1, 1, 'self', 'wrong colour', 1);
SET session_replication_role = origin;
SELECT mv_post('opening', NULL, NULL, mv_pair(100, 510, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 511, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 512, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 513, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')) \g /dev/null

\echo '== 1. draft 59 holds bike 510, then again. Expect held, then nothing more.'
SELECT claim_hold(59, 510);
SELECT claim_hold(59, 510);

\echo '== 2. the draft holds bike 504, on the bench. Expect MV091.'
SELECT claim_hold(59, 504);

\echo '== 3. order 907 takes bike 510, which the draft holds. Expect MV055.'
SELECT claim_sale((SELECT id FROM sales WHERE orders_id = 907), 510);

\echo '== 4. the draft lets it go; order 907 takes it. Expect it attached, not sold: the order is not paid.'
SELECT claim_release(59, 510);
SELECT claim_sale((SELECT id FROM sales WHERE orders_id = 907), 510);
SELECT serials_id, kind, ref_id FROM unit_claims WHERE serials_id = 510;

\echo '== 5. order 907''s line takes bike 511 as well. Expect MV096.'
SELECT claim_sale((SELECT id FROM sales WHERE orders_id = 907), 511);

\echo '== 6. order 908, paid, takes bike 511. Expect it attached and sold at once: customer 8''s.'
SELECT claim_sale((SELECT id FROM sales WHERE orders_id = 908), 511);
SELECT serials_id, place_kind, location_id, owner_customer_id FROM unit_positions WHERE serials_id = 511;

\echo '== 7. order 908''s line lets bike 511 go. Expect MV097: it is sold.'
SELECT claim_sale_release((SELECT id FROM sales WHERE orders_id = 908));

\echo '== 8. order 907''s line lets bike 510 go; the fleet takes it, then lets it go. Expect each done.'
SELECT claim_sale_release((SELECT id FROM sales WHERE orders_id = 907));
SELECT claim_fleet(2, 510);
SELECT claim_fleet_release(2);

\echo '== 9. the fleet takes bike 511, customer 8''s. Expect MV091.'
SELECT claim_fleet(2, 511);

\echo '== 10. a draft of the master held from Prudente''s seat. Expect MV093.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT claim_hold(59, 512);

\echo '== 11. bike 512 written off from Prudente''s seat. Expect MV082.'
SELECT movement_write_off(512, 1, 'stolen');
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 12. bike 512 written off with bike 513''s approval. Expect MV080.'
SELECT movement_write_off(512, 2, 'stolen');

\echo '== 13. bike 512 written off, its own approval. Expect it written off where it stands, at the master.'
SELECT movement_write_off(512, 1, 'stolen from the yard');
SELECT serials_id, place_kind, location_id, state FROM unit_positions WHERE serials_id = 512;

\echo '== 14. written off again. Expect MV081.'
SELECT movement_write_off(512, 1);

\echo '== 15. bike 510 held by the draft, written off. Expect MV055.'
SELECT claim_hold(59, 510);
SELECT movement_write_off(510, 1);

\echo '== 16. bike 513 back to its provider, none named and none it was bought from. Expect MV083.'
SELECT movement_to_provider(513, 2);

\echo '== 17. bike 513 back to supplier 5. Expect it at the supplier''s.'
SELECT movement_to_provider(513, 2, 5, 'wrong colour');
SELECT serials_id, place_kind, suppliers_id, state FROM unit_positions WHERE serials_id = 513;

\echo '== 18. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
