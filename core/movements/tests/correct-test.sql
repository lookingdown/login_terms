-- The supervisor's correction (event 24) and the removal of a unit that is nothing yet, on the fixture after
-- stock-test.sql: a supplier's delivery of three bikes, approvals for corrections and removals, a unit with no line.
-- Run it after stock-test.sql. Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents: order 13 from supplier 5 at the master, a line of three bikes; a unit 599 with no line
SET session_replication_role = replica;
INSERT INTO purchases (id, suppliers_id, supplier_name, status, location_id) OVERRIDING SYSTEM VALUE VALUES (13, 5, 'Fornecedor Teste', 'ordered', 1);
INSERT INTO purchase_items (id, purchases_id, variants_id, items_id, sku, qty_expected) OVERRIDING SYSTEM VALUE VALUES (331, 13, 100, 10, 'MX-VERDE', 3);
INSERT INTO serials (id, variants_id, serial_number, location_id) OVERRIDING SYSTEM VALUE VALUES (599, 100, '9C2KC1650PR000599', 1);
SET session_replication_role = origin;
SELECT movement_receive(331, 3, '[{"serial_number": "9C2KC1650PR000901"}, {"serial_number": "9C2KC1650PR000902"}]') \g /dev/null
SELECT id AS u901 FROM serials WHERE serial_number = '9C2KC1650PR000901' \gset
SELECT id AS u902 FROM serials WHERE serial_number = '9C2KC1650PR000902' \gset
SELECT id AS u903 FROM serials WHERE purchase_items_id = 331 AND serial_number IS NULL \gset

-- the supervisor's approvals: removals 20 (the first bike), 21 (the second), 22 (bike 516), 23 (the third);
-- corrections 31 (bike 512), 32 (511), 33 (517), 34 (510), 35 (599), 36 and 37 (514)
SET session_replication_role = replica;
INSERT INTO approvals (id, action, ref_type, ref_id, requested_by, approved_by, approved_via, reason, location_id) OVERRIDING SYSTEM VALUE
VALUES (20, 'unit_removal', 'serials', :u901, 1, 1, 'override', 'counted twice', 1),
       (21, 'unit_removal', 'serials', :u902, 1, 1, 'override', 'counted twice', 1),
       (22, 'unit_removal', 'serials', 516, 1, 1, 'override', 'no such bike', 1),
       (23, 'unit_removal', 'serials', :u903, 1, 1, 'override', 'counted twice', 1),
       (31, 'unit_correction', 'serials', 512, 1, 1, 'override', 'found', 1),
       (32, 'unit_correction', 'serials', 511, 1, 1, 'override', 'sold by hand', 1),
       (33, 'unit_correction', 'serials', 517, 1, 1, 'override', 'found at Prudente', 1),
       (34, 'unit_correction', 'serials', 510, 1, 1, 'override', 'at Prudente', 1),
       (35, 'unit_correction', 'serials', 599, 1, 1, 'override', 'stuck', 1),
       (36, 'unit_correction', 'serials', 514, 1, 1, 'override', 'came back unrecorded', 1),
       (37, 'unit_correction', 'serials', 514, 1, 1, 'override', 'at Prudente', 1);
INSERT INTO assembly (variants_id, serials_id, stage, location_id) VALUES (100, :u903, 'in_process', 1);
INSERT INTO stock_count_lines (counts_id, kind, serials_id, variants_id, expected_qty, location_id) VALUES (1, 'unit', :u902, 100, 1, 2);
SET session_replication_role = origin;

\echo '== 1. the first bike removed with the second''s approval. Expect MV160.'
SELECT movement_unit_remove(:u901, 21);

\echo '== 2. bike 516, which has moved since it came in. Expect MV161.'
SELECT movement_unit_remove(516, 22);

\echo '== 3. the third bike, on an assembly job; the second, read in a count. Expect MV162 twice (assembly, count).'
SELECT movement_unit_remove(:u903, 23);
SELECT movement_unit_remove(:u902, 21);

\echo '== 4. the first bike removed from Prudente''s seat. Expect MV093.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_unit_remove(:u901, 20);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 5. the first bike removed, its approval. Expect removed, its number given back and freed; the line''s total 3 → 2; the bike back at the supplier.'
SELECT movement_unit_remove(:u901, 20, 'counted twice') - 'purchase_items_id' AS removed;
SELECT qty_received FROM purchase_items WHERE id = 331;
SELECT s.serial_number, up.place_kind, up.suppliers_id, up.state FROM serials s JOIN unit_positions up ON up.serials_id = s.id WHERE s.id = :u901;

\echo '== 6. removed again. Expect MV161.'
SELECT movement_unit_remove(:u901, 20);

\echo '== 7. the freed number received on the line. Expect one new unit with it.'
SELECT movement_receive(331, 3, '[{"serial_number": "9C2KC1650PR000901"}]') ->> 'received' AS received;
SELECT count(*) AS units_with_it FROM serials WHERE serial_number = '9C2KC1650PR000901';

\echo '== 8. a correction without its note. Expect MV156.'
SELECT movement_correct(517, 33, 2, NULL, NULL, ' ');

\echo '== 9. bike 517 corrected with bike 512''s approval. Expect MV150.'
SELECT movement_correct(517, 31, 2, NULL, NULL, 'found at Prudente');

\echo '== 10. bike 511, customer 8''s, corrected back to the master. Expect MV152.'
SELECT movement_correct(511, 32, 1, NULL, 'available', 'sold by hand');

\echo '== 11. bike 517 to the inactive shop, then written off, then where it is. Expect MV153, MV154, MV155.'
SELECT movement_correct(517, 33, 3, NULL, NULL, 'elsewhere');
SELECT movement_correct(517, 33, 1, NULL, 'written_off', 'gone');
SELECT movement_correct(517, 33, 1, 1, 'available', 'here');

\echo '== 12. from Prudente''s seat, bike 517 (at the master) put on the master''s bench. Expect MV093.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_correct(517, 33, 1, NULL, 'validating', 'on the bench');
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 13. bike 510, which draft 59 holds at the master, to Prudente. Expect MV055.'
SELECT movement_correct(510, 34, 2, NULL, NULL, 'at Prudente');

\echo '== 14. bike 512, written off, found: available at the master. Expect it available there; then its approval again, MV151.'
SELECT movement_correct(512, 31, 1, NULL, 'available', 'found in the yard') - 'movement_id' AS corrected;
SELECT serials_id, place_kind, location_id, owner_location_id, state FROM unit_positions WHERE serials_id = 512;
SELECT movement_correct(512, 31, 2, NULL, NULL, 'again');

\echo '== 15. the unit "a mais": from Prudente''s seat, bike 517 corrected to here. Expect it Prudente''s, at Prudente, available.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_correct(517, 33, 2, NULL, NULL, 'found at the count') - 'movement_id' AS corrected;
SELECT serials_id, location_id, owner_location_id, state FROM unit_positions WHERE serials_id = 517;
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 16. unit 599, which has no line. Expect MV157.'
SELECT movement_correct(599, 35, 1, NULL, 'available', 'stuck');

\echo '== 17. the stuck rental: bike 514 out on rental 61, back unrecorded; corrected home. Expect it home; then the rental''s return MV144; then to Prudente MV055 (the fleet holds it at the master).'
SELECT movement_rent_out(61);
SELECT movement_correct(514, 36, 1, NULL, 'available', 'came back unrecorded') - 'movement_id' AS corrected;
SELECT serials_id, place_kind, location_id, owner_location_id FROM unit_positions WHERE serials_id = 514;
SELECT movement_rent_back(61);
SELECT movement_correct(514, 37, 2, NULL, NULL, 'at Prudente');

\echo '== 18. the journal: the corrections and the removal, newest first. Expect corrected ×3 by their approvals, then receipt_corrected.'
SELECT kind, ref_type, ref_id, note FROM movements WHERE kind IN ('corrected', 'receipt_corrected') ORDER BY id DESC LIMIT 4;

\echo '== 19. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
