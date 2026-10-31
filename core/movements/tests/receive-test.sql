-- Receive and arrive, on the fixture of dispatch-test.sql: a supplier's delivery received, its numbers checked,
-- corrected down; remessa 55 arriving at Prudente. Run it last: it changes what the other tests read.
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

\echo '== 1. the delivery''s bikes: two come, one with its chassis. Expect two units minted, on the bench at the master.'
SELECT movement_receive(301, 2, '[{"serial_number": "9C2KC1650PR000010"}]');
SELECT s.serial_number, up.place_kind, up.location_id, up.owner_location_id, up.state
  FROM serials s JOIN unit_positions up ON up.serials_id = s.id WHERE s.purchase_items_id = 301 ORDER BY s.id;

\echo '== 2. its four helmets. Expect them available at the master, and each line''s total following.'
SELECT movement_receive(302, 4);
SELECT id, qty_received FROM purchase_items WHERE id IN (301, 302) ORDER BY id;

\echo '== 3. a third bike whose chassis is bike 500''s, typed in lower case. Expect MV036.'
SELECT movement_receive(301, 3, '[{"serial_number": "9c2kc1650pr000001"}]');

\echo '== 4. two numbers for one new bike. Expect MV035.'
SELECT movement_receive(301, 3, '[{"serial_number": "A1"}, {"serial_number": "A2"}]');

\echo '== 5. the master''s order received from Prudente''s seat. Expect MV031.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_receive(301, 3);
SELECT set_config('app.location', '1', false) \g /dev/null

\echo '== 6. corrected down to one: the bike without a number goes back to the supplier. Expect the numbered one on the bench.'
SELECT movement_receive(301, 1);
SELECT s.serial_number, up.place_kind, up.location_id, up.suppliers_id, up.state
  FROM serials s JOIN unit_positions up ON up.serials_id = s.id WHERE s.purchase_items_id = 301 ORDER BY s.id;

\echo '== 7. corrected down to none: the last one has its chassis. Expect MV037.'
SELECT movement_receive(301, 0);

\echo '== 8. the shop''s line of remessa 55, received as a delivery. Expect MV032.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_receive(311, 1);

\echo '== 9. remessa 55 arriving at the master''s seat. Expect MV040.'
SELECT set_config('app.location', '1', false) \g /dev/null
SELECT movement_arrive(55, 311, 1);

\echo '== 10. at Prudente: bike 500, named, then one of the two helmets. Expect bike 500 Prudente''s, one helmet on the road.'
SELECT set_config('app.location', '2', false) \g /dev/null
SELECT movement_arrive(55, 311, 0, '[500]');
SELECT movement_arrive(55, 312, 1);
SELECT serials_id, place_kind, location_id, owner_location_id, state FROM unit_positions WHERE serials_id = 500;

\echo '== 11. five helmets when one is left on the road. Expect MV042.'
SELECT movement_arrive(55, 312, 5);

\echo '== 12. the helmets back to none. Expect MV043.'
SELECT movement_arrive(55, 312, 0);

\echo '== 13. the last helmet. Expect the road empty: on_road 0.'
SELECT movement_arrive(55, 312, 2);

\echo '== 14. bike 500''s arrival, planned and done; its line, from the opening to Prudente.'
SELECT kind, lower(planned) AS planned, lower(actual) AS actual FROM unit_waypoints WHERE serials_id = 500 AND kind = 'arrival';
SELECT why, place, owner, state FROM cube_dots(p_units => '{500}', p_layers => '{fact}');

\echo '== 15. the health checks. Expect every count 0.'
SELECT (SELECT count(*) FROM movement_check_balance) AS balance, (SELECT count(*) FROM movement_check_chain) AS chain,
       (SELECT count(*) FROM movement_check_positions) AS positions, (SELECT count(*) FROM movement_check_serial_mix) AS serial_mix,
       (SELECT count(*) FROM movement_check_roads) AS roads;
