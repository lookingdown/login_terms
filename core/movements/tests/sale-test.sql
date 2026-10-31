-- The sale path, on the fixture of dispatch-test.sql after receive-test.sql: an order paid and sold, handed over,
-- returned; counted goods sold, returned, undone; each refusal. Run it after receive-test.sql.
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents: customer 8, and orders at the master: 902 two helmets, 903 the fleet's bike 502, 904 bike 504 on
-- the bench, 905 a bike with no customer, 906 ninety-nine helmets; all paid
SET session_replication_role = replica;
INSERT INTO customers (id, email, full_name) OVERRIDING SYSTEM VALUE VALUES (8, 'outro@example.com', 'Cliente Oito') ON CONFLICT (id) DO NOTHING;
INSERT INTO orders (id, ordercart_id, paid, status, location_id, customers_id) OVERRIDING SYSTEM VALUE
VALUES (902, 'c-902', true, 'paid', 1, 8), (903, 'c-903', true, 'paid', 1, 8), (904, 'c-904', true, 'paid', 1, 8),
       (905, 'c-905', true, 'paid', 1, NULL), (906, 'c-906', true, 'paid', 1, 8);
INSERT INTO sales (orders_id, items_id, variants_id, sku, segment, item_name, quantity, unit_price, line_subtotal, line_total, serials_id, location_id)
VALUES (902, 20, 200, 'CAP-M', 'acessorio', 'Capacete', 2, 100, 200, 200, NULL, 1),
       (903, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 502, 1),
       (904, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 504, 1),
       (905, 10, 100, 'MX-VERDE', 'moto', 'Moto X', 1, 1000, 1000, 1000, 503, 1),
       (906, 20, 200, 'CAP-M', 'acessorio', 'Capacete', 99, 100, 9900, 9900, NULL, 1);
SET session_replication_role = origin;

\echo '== 1. order 900, bike 501, not paid yet. Expect MV051.'
SELECT movement_sell(900);

\echo '== 2. order 905 sells a bike to no one. Expect MV053.'
SELECT movement_sell(905);

\echo '== 3. order 903 sells the fleet''s bike 502. Expect MV055.'
SELECT movement_sell(903);

\echo '== 4. order 904 sells bike 504, on the bench. Expect MV054.'
SELECT movement_sell(904);

\echo '== 5. order 906: ninety-nine helmets. Expect MV056.'
SELECT movement_sell(906);

\echo '== 6. order 900 paid, for customer 8; sold from Prudente''s seat. Expect MV052.'
SET session_replication_role = replica;
UPDATE orders SET paid = true, status = 'paid', customers_id = 8 WHERE id = 900;
SET session_replication_role = origin;
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_sell(900);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 7. order 900 sold at the master. Expect its line sold: bike 501 customer 8''s, still at the master.'
SELECT movement_sell(900);
SELECT serials_id, place_kind, location_id, owner_location_id, owner_customer_id, state FROM unit_positions WHERE serials_id = 501;

\echo '== 8. sold again. Expect nothing more to sell.'
SELECT movement_sell(900);

\echo '== 9. order 901 handed over: its bike line has no unit. Expect MV057.'
SELECT movement_hand_over(901);

\echo '== 10. order 900 handed over. Expect bike 501 with customer 8.'
SELECT movement_hand_over(900);
SELECT serials_id, place_kind, customers_id, owner_customer_id FROM unit_positions WHERE serials_id = 501;

\echo '== 11. its sale undone after the handover. Expect MV061.'
SELECT movement_unsell((SELECT id FROM sales WHERE orders_id = 900), 'cancel');

\echo '== 12. returned by customer 8. Expect bike 501 back at the master, available.'
SELECT movement_return((SELECT id FROM sales WHERE orders_id = 900), 1, 'defect');
SELECT serials_id, place_kind, location_id, owner_location_id, state FROM unit_positions WHERE serials_id = 501;

\echo '== 13. order 902 sells two helmets. Expect the master''s helmets down by two, the line''s cost stamped.'
SELECT qty AS helmets_before FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200;
SELECT movement_sell(902);
SELECT qty AS helmets_after FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200;

\echo '== 14. five helmets returned of the two. Expect MV062.'
SELECT movement_return((SELECT id FROM sales WHERE orders_id = 902), 5, 'regret');

\echo '== 15. one returned, then the rest undone. Expect one back, then one more: the helmets as before.'
SELECT movement_return((SELECT id FROM sales WHERE orders_id = 902), 1, 'regret');
SELECT movement_unsell((SELECT id FROM sales WHERE orders_id = 902), 'cancel');
SELECT qty AS helmets_now FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200;

\echo '== 16. the undone line undone again. Expect MV060.'
SELECT movement_unsell((SELECT id FROM sales WHERE orders_id = 902), 'cancel');

\echo '== 17. bike 501''s line through the sale: what happened, in order.'
SELECT why, place, owner FROM cube_dots(p_units => '{501}', p_layers => '{fact}');

\echo '== 18. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
