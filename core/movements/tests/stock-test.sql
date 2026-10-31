-- The quick transfer, the rentals and the loans, the adjustments and the count, on the fixture after
-- claims-test.sql: four new bikes at the master, a fleet resource, four rentals, four loans, three counts.
-- Run it after claims-test.sql. Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents: an inactive shop 3; user 2, a seller at the master; grease (a material) and gloves (counted
-- goods); bikes 514 to 517; fleet resource 3; rentals 61 (open), 62 (cancelled), 63 (no bike), 64 (a customer
-- that is none); loans 1 (open), 2 (no customer), 3 (bike 510, which draft 59 holds), 4 (returned); counts 1 and
-- 2 at Prudente (open, closed), 3 at the master
SET session_replication_role = replica;
INSERT INTO locations (id, code, name, kind, active) OVERRIDING SYSTEM VALUE VALUES (3, 'VEL', 'Antiga', 'shop', false);
INSERT INTO users (id, name, login, email, password_hash, location_id, role) OVERRIDING SYSTEM VALUE
VALUES (2, 'Vendedor', 'vendedor', 'v@example.com', 'x', 1, 'sales');
INSERT INTO items (id, name, serial, sellable) OVERRIDING SYSTEM VALUE VALUES (30, 'Graxa', false, false), (40, 'Luva', false, true);
INSERT INTO variants (id, items_id, sku) OVERRIDING SYSTEM VALUE VALUES (300, 30, 'GRX'), (400, 40, 'LUV-M');
INSERT INTO serials (id, variants_id, serial_number, location_id) OVERRIDING SYSTEM VALUE
VALUES (514, 100, '9C2KC1650PR000514', 1), (515, 100, '9C2KC1650PR000515', 1), (516, 100, '9C2KC1650PR000516', 1),
       (517, 100, '9C2KC1650PR000517', 1);
INSERT INTO resources (id, resource_type_id, variants_id, name, location_id) OVERRIDING SYSTEM VALUE VALUES (3, 1, 100, 'Moto X da frota, 3', 1);
INSERT INTO bookings (id, resource_type_id, resource_id, item_id, customer_id, start_at, end_at, price, status, cancelled_at, location_id)
OVERRIDING SYSTEM VALUE VALUES
    (61, 1, 3, 1, 8, date_trunc('day', LOCALTIMESTAMP), date_trunc('day', LOCALTIMESTAMP) + interval '2 days', 100, 'confirmed', NULL, 1),
    (62, 1, 3, 1, 8, date_trunc('day', LOCALTIMESTAMP) + interval '20 days', date_trunc('day', LOCALTIMESTAMP) + interval '21 days', 100,
     'cancelled', LOCALTIMESTAMP, 1),
    (63, 1, NULL, 1, 8, date_trunc('day', LOCALTIMESTAMP) + interval '30 days', date_trunc('day', LOCALTIMESTAMP) + interval '31 days', 100, 'pending', NULL, 1),
    (64, 1, 3, 1, 99999, date_trunc('day', LOCALTIMESTAMP) + interval '40 days', date_trunc('day', LOCALTIMESTAMP) + interval '41 days', 100, 'confirmed', NULL, 1);
INSERT INTO loans (id, serials_id, borrower_name, due_at, status, customers_id, location_id) OVERRIDING SYSTEM VALUE
VALUES (1, 515, 'Cliente Oito', CURRENT_DATE + 7, 'preparando', 8, 1), (2, 515, 'Sem cadastro', CURRENT_DATE + 7, 'preparando', NULL, 1),
       (3, 510, 'Cliente Oito', CURRENT_DATE + 7, 'preparando', 8, 1), (4, 515, 'Cliente Oito', CURRENT_DATE - 1, 'devolvida', 8, 1);
INSERT INTO stock_counts (id, status, location_id) OVERRIDING SYSTEM VALUE VALUES (1, 'contando', 2), (2, 'fechado', 2), (3, 'contando', 1);
INSERT INTO stock_count_lines (counts_id, kind, serials_id, variants_id, expected_qty, counted_qty, extra, location_id)
VALUES (1, 'part', NULL, 200, 6, 3, false, 2), (1, 'part', NULL, 200, 0, 1, true, 2), (1, 'part', NULL, 400, 5, 5, false, 2),
       (1, 'part', NULL, 300, 2, 3, false, 2), (1, 'part', NULL, 200, 0, NULL, true, 2), (1, 'unit', 516, 100, 1, NULL, false, 2);
SET session_replication_role = origin;
SELECT mv_post('opening', NULL, NULL, mv_pair(100, 514, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 515, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 516, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')
                                   || mv_pair(100, 517, 1, '{"state": "available"}', '{"at_location_id": 1, "owner_location_id": 1, "state": "available"}')) \g /dev/null

\echo '== 1. the master''s helmets set to the 10 counted on the shelf. Expect after 10, delta whatever they were.'
SELECT movement_adjust('[{"variants_id": 200, "balance": 10}]', 'count', 'shelf count')->'items' AS items;

\echo '== 2. a quick transfer by a seller. Expect MV130.'
SELECT set_config('app.user', '2', false) \g /dev/null
SELECT movement_flip(1, 2, '[516]');
SELECT set_config('app.user', '1', false) \g /dev/null

\echo '== 3. by the superadmin, from Prudente''s seat. Expect MV130.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_flip(1, 2, '[516]');
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 4. from the master to itself, then to the inactive shop. Expect MV131 twice.'
SELECT movement_flip(1, 1, '[516]');
SELECT movement_flip(1, 3, '[516]');

\echo '== 5. bike 510, which draft 59 holds. Expect MV055.'
SELECT movement_flip(1, 2, '[510]');

\echo '== 6. bike 512, written off. Expect MV091.'
SELECT movement_flip(1, 2, '[512]');

\echo '== 7. the bike''s model by quantity. Expect MV073.'
SELECT movement_flip(1, 2, '[]', '[{"variants_id": 100, "qty": 1}]');

\echo '== 8. nothing. Expect MV133.'
SELECT movement_flip(1, 2);

\echo '== 9. bike 516 and three helmets to Prudente. Expect bike 516 Prudente''s and sellable there at once (gained 1); the master''s helmets 7.'
SELECT COALESCE((SELECT qty FROM stock_sellable WHERE location_id = 2 AND variants_id = 100), 0) AS sellable_before \gset
SELECT movement_flip(1, 2, '[516]', '[{"variants_id": 200, "qty": 3}]', 'for the weekend') - 'movement_id' AS flipped;
SELECT serials_id, place_kind, location_id, owner_location_id, state FROM unit_positions WHERE serials_id = 516;
SELECT (SELECT qty FROM stock_sellable WHERE location_id = 2 AND variants_id = 100) - :sellable_before AS gained,
       (SELECT qty FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200) AS master_helmets;

\echo '== 10. the helmet case: 100 helmets from Prudente, which has fewer. Expect MV132.'
SELECT movement_flip(2, 1, '[]', '[{"variants_id": 200, "qty": 100}]');

\echo '== 11. a second flip onward: bike 516 from Prudente back to the master. Expect it the master''s again.'
SELECT movement_flip(2, 1, '[516]') - 'movement_id' AS flipped;
SELECT serials_id, location_id, owner_location_id FROM unit_positions WHERE serials_id = 516;

\echo '== 12. rental 63 names no bike. Expect MV142.'
SELECT movement_rent_out(63);

\echo '== 13. rental 64''s customer is no customer. Expect MV146.'
SELECT claim_fleet(3, 514);
SELECT movement_rent_out(64);

\echo '== 14. rental 62, cancelled, goes out. Expect MV141.'
SELECT movement_rent_out(62);

\echo '== 15. rental 61 goes out from Prudente''s seat. Expect MV093.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_rent_out(61);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 16. rental 61 goes out, then again. Expect done, then not; bike 514 with customer 8, the master''s still, its fleet''s, owned elsewhere.'
SELECT movement_rent_out(61);
SELECT movement_rent_out(61);
SELECT serials_id, place_kind, customers_id, owner_location_id, state FROM unit_positions WHERE serials_id = 514;
SELECT kind, ref_id FROM unit_claims WHERE serials_id = 514;
SELECT place_kind, customers_id, qty FROM owned_elsewhere WHERE location_id = 1 AND variants_id = 100 AND place_kind = 'customer';

\echo '== 17. the fleet lets bike 514 go while it is out. Expect MV100.'
SELECT claim_fleet_release(3);

\echo '== 18. rental 62 comes back: it never went out. Expect MV144.'
SELECT movement_rent_back(62);

\echo '== 19. rental 61 comes back, then again. Expect done, then not; bike 514 at the master.'
SELECT movement_rent_back(61);
SELECT movement_rent_back(61);
SELECT serials_id, place_kind, location_id, owner_location_id FROM unit_positions WHERE serials_id = 514;

\echo '== 20. rental 999 and loan 999. Expect MV140, MV145.'
SELECT movement_rent_out(999);
SELECT movement_loan_out(999);

\echo '== 21. loan 2 names no customer. Expect MV146.'
SELECT movement_loan_out(2);

\echo '== 22. loan 3, of bike 510, which the draft holds. Expect MV055.'
SELECT movement_loan_out(3);

\echo '== 23. loan 4, returned already, goes out. Expect MV141.'
SELECT movement_loan_out(4);

\echo '== 24. loan 1 goes out. Expect done; bike 515 with customer 8, the master''s; its plan carries the customer.'
SELECT movement_loan_out(1);
SELECT serials_id, place_kind, customers_id, owner_location_id FROM unit_positions WHERE serials_id = 515;
SELECT kind, ref_id, customers_id FROM unit_waypoints WHERE serials_id = 515 ORDER BY ref_id;

\echo '== 25. bike 515 flipped while on loan. Expect MV091.'
SELECT movement_flip(1, 2, '[515]');

\echo '== 26. loan 1 comes back. Expect done; bike 515 at the master.'
SELECT movement_loan_back(1);
SELECT serials_id, place_kind, location_id FROM unit_positions WHERE serials_id = 515;

\echo '== 27. adjustments at Prudente: no reason, no note, a bike, a material, an unknown model. Expect MV111, MV112, MV110, MV015, MV113.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_adjust('[{"variants_id": 200, "qty": 1}]', 'misplaced', 'shelf');
SELECT movement_adjust('[{"variants_id": 200, "qty": 1}]', 'found', ' ');
SELECT movement_adjust('[{"variants_id": 100, "qty": 1}]', 'found', 'a bike');
SELECT movement_adjust('[{"variants_id": 300, "qty": 1}]', 'found', 'grease');
SELECT movement_adjust('[{"variants_id": 999, "qty": 1}]', 'found', 'no such model');

\echo '== 28. found as a loss, damaged as a gain. Expect MV115 twice.'
SELECT movement_adjust('[{"variants_id": 200, "qty": -1}]', 'found', 'shelf');
SELECT movement_adjust('[{"variants_id": 200, "qty": 1}]', 'damaged', 'shelf');

\echo '== 29. more lost than there is. Expect MV114.'
SELECT movement_adjust('[{"variants_id": 200, "qty": -1000}]', 'loss', 'shelf');

\echo '== 30. Prudente''s helmets (6) set to 5; then helmets and gloves found. Expect 6 → 5; then helmets 7 and gloves 5, one movement.'
SELECT movement_adjust('[{"variants_id": 200, "balance": 5}]', 'count', 'shelf count')->'items' AS items;
SELECT movement_adjust('[{"variants_id": 200, "qty": 2}, {"variants_id": 400, "qty": 5}]', 'found', 'in the back room') - 'movement_id' AS found;

\echo '== 31. a helmet damaged; then helmets set to a balance twice. Expect helmets 6; then MV116.'
SELECT movement_adjust('[{"variants_id": 200, "qty": -1}]', 'damaged', 'dropped')->'items' -> 0 -> 'after' AS helmets;
SELECT movement_adjust('[{"variants_id": 200, "balance": 6}, {"variants_id": 200, "qty": 1}]', 'count', 'twice');

\echo '== 32. nothing differs. Expect adjusted 0 and no movement.'
SELECT movement_adjust('[{"variants_id": 400, "balance": 5}]', 'count', 'checked');

\echo '== 33. Prudente''s journal of helmets, newest first. Expect adjusted −1 damaged, +2 found, −1 count.'
SELECT kind, qty, reason, note FROM movement_rows(2) WHERE variants_id = 200 ORDER BY movements_id DESC NULLS LAST LIMIT 3;

\echo '== 34. counts: the master''s from Prudente''s seat, a closed one, an unknown one. Expect MV093, MV121, MV120.'
SELECT movement_count_close(3);
SELECT movement_count_close(2);
SELECT movement_count_close(999);

\echo '== 35. count 1 closed: helmets counted on two lines (3 + 1), gloves 5, grease (a material), a line not counted, a unit. Expect helmets 6 → 4 alone, reason count.'
SELECT movement_count_close(1) - 'movement_id' AS closed;
SELECT kind, ref_type, ref_id, reason FROM movements ORDER BY id DESC LIMIT 1;

\echo '== 36. closed again, before the module marks it. Expect adjusted 0.'
SELECT movement_count_close(1);

\echo '== 37. a seat: an adjustment through its function, then a movement written by hand, then the primitive. Expect gloves 6; then 42501 twice.'
SET ROLE app_staff;
SELECT movement_adjust('[{"variants_id": 400, "qty": 1}]', 'found', 'under the counter')->'items' -> 0 -> 'after' AS gloves;
INSERT INTO movements (kind, users_id) VALUES ('adjusted', 1);
SELECT mv_post('adjusted', NULL, NULL, '[]');
RESET ROLE;
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 38. a loss on the road keeps who bears it as its reason. Expect lost, carrier or origin, the note alone.'
SELECT kind, reason, note FROM movements WHERE kind = 'lost' ORDER BY id;

\echo '== 39. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
