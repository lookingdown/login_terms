-- The cube on the fixture of dispatch-test.sql (run it first): facts as stays, slices in business time and
-- in system time, the roster from the documents, and the encounters that cannot happen.
-- Some statements fail on purpose: each \echo says what to look for.
\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
SELECT set_config('app.location', '1', false), set_config('app.user', '1', false) \g /dev/null

-- the documents that plan, their plain rows with today's triggers paused (as in dispatch-test)
SET session_replication_role = replica;
TRUNCATE bookings, workshop_appointments, service_orders, resources, resource_types RESTART IDENTITY CASCADE;
INSERT INTO customers (id, email) OVERRIDING SYSTEM VALUE VALUES (7, 'cliente@example.com') ON CONFLICT (id) DO NOTHING;
INSERT INTO resource_types (id, name) OVERRIDING SYSTEM VALUE VALUES (1, 'aluguel');
INSERT INTO resources (id, resource_type_id, name, serials_id, location_id) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'Moto X da frota', 502, 1);
-- bike 500 is on its way to Prudente: an appointment there tomorrow at 10:00
INSERT INTO workshop_appointments (starts_at, customers_id, serials_id, location_id, kind, status)
VALUES (date_trunc('day', LOCALTIMESTAMP) + interval '1 day 10 hours', 7, 500, 2, 'revisao', 'scheduled');
-- bike 502: rented from next week for two days, and a service order that starts the day after
INSERT INTO bookings (resource_type_id, resource_id, item_id, customer_id, start_at, end_at, price, status, location_id)
VALUES (1, 1, 10, 7, date_trunc('day', LOCALTIMESTAMP) + interval '7 days', date_trunc('day', LOCALTIMESTAMP) + interval '9 days', 100, 'confirmed', 1);
INSERT INTO service_orders (customers_id, users_id, serials_id, scheduled_date, expected_date, location_id)
VALUES (7, 1, 502, (LOCALTIMESTAMP + interval '8 days')::date, (LOCALTIMESTAMP + interval '10 days')::date, 1);
SET session_replication_role = origin;

\echo '== 1. bike 500''s stays: the master from 1 Oct, the road from the dispatch on.'
SELECT serials_id, coalesce('location ' || at_location_id, 'road ' || at_transfer_id) AS cell, owner_location_id AS owner, state,
       lower(during) AS from, upper(during) AS to
  FROM unit_residence WHERE serials_id = 500 ORDER BY lower(during);

\echo '== 2. one moment, every unit: 15 Oct, then now.'
SELECT '15 Oct' AS at, serials_id, place_kind, coalesce(location_id::text, transfers_id::text) AS place, state FROM whereabouts('2026-10-15')
UNION ALL
SELECT 'now', serials_id, place_kind, coalesce(location_id::text, transfers_id::text), state FROM whereabouts()
ORDER BY 1 DESC, 2;

\echo '== 3. the same 15 Oct as the books stood on 15 Oct. Expect 0: the opening was recorded only today.'
SELECT count(*) AS units_the_books_knew_on_15_oct FROM whereabouts('2026-10-15', '2026-10-15');

\echo '== 4. a moment next week: where each unit will be, and what its documents plan for it then.'
SELECT serials_id, place_kind, coalesce(location_id::text, transfers_id::text) AS place, waypoint, waypoint_ref
  FROM whereabouts(date_trunc('day', LOCALTIMESTAMP) + interval '8 days 12 hours') ORDER BY serials_id;

\echo '== 5. bike 502''s life: what happened, then what is planned.'
SELECT layer, starts, ends, place_kind, place_id, how FROM unit_trajectory WHERE serials_id = 502 ORDER BY starts, layer;

\echo '== 6. encounters that cannot happen. Expect two: bike 500 still on the road at its appointment, bike 502 rented and in service at once.'
SELECT serials_id, kind, ref_id, conflict, with_what, at FROM unit_waypoint_conflicts ORDER BY serials_id, kind;

\echo '== 7. an arrival dated before the unit''s last stay began. Expect MV002.'
WITH m AS (INSERT INTO movements (kind, occurred_at, users_id) VALUES ('arrived', '2026-10-05', 1) RETURNING id)
INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, at_transfer_id, owner_location_id, state)
SELECT m.id, 100, 500, x.q, x.l, x.t, 1, 'available' FROM m, (VALUES (-1, NULL::int4, 55::int8), (1, 2, NULL)) x(q, l, t);

\echo '== 8. a second stay over the first, written by hand. Expect the temporal key to refuse it.'
INSERT INTO unit_residence (serials_id, at_location_id, owner_location_id, state, during, movements_id)
SELECT 500, 2, 2, 'available', tsrange('2026-10-02', '2026-10-03'), min(id) FROM movements;

\echo '== 9. the axes: one value on one axis, every angle of the rest. Time: this moment.'
SELECT serials_id, layer, place, owner, state, starts, why FROM cube_dots(tsrange(LOCALTIMESTAMP, LOCALTIMESTAMP, '[]'));

\echo '== 10. entity: unit 502, every slice of its life, facts and plans.'
SELECT layer, place, owner, starts, ends, why, ref_id FROM cube_dots(p_units => '{502}');

\echo '== 11. place and a period: who stood at the master during October.'
SELECT serials_id, layer, starts, ends, why FROM cube_dots(tsrange('2026-10-01', '2026-11-01'), p_places => '{location:1}');

\echo '== 12. customer 7: every dot it takes part in.'
SELECT serials_id, layer, place, starts, ends, why, ref_id FROM cube_dots(p_customer => 7);

\echo '== 13. widened: a whole model (variant 100), counted per place now.'
SELECT place, count(*) AS units FROM cube_dots(tsrange(LOCALTIMESTAMP, LOCALTIMESTAMP, '[]'), p_models => '{100}') WHERE layer = 'fact' GROUP BY place ORDER BY place;

\echo '== 14. narrowed on two axes: customer 7 at a moment next week.'
SELECT serials_id, place, why, ref_id FROM cube_dots(tsrange(date_trunc('day', LOCALTIMESTAMP) + interval '7 days 12 hours',
       date_trunc('day', LOCALTIMESTAMP) + interval '7 days 12 hours', '[]'), p_customer => 7);

\echo '== 15. the second clock: 15 Oct as the books stood on 15 Oct. Expect nothing.'
SELECT count(*) AS dots FROM cube_dots(tsrange('2026-10-15', '2026-10-15', '[]'), p_known_at => '2026-10-15');
