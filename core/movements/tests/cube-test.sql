-- The cube on the fixture of dispatch-test.sql (run it first): the stays kept from the legs, a cut along each
-- axis (cube_dots), an instant, the encounters that cannot happen, and the rules that keep one place at a time.
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

\echo '== 1. bike 500''s stays, kept from the legs: the master from 1 Oct, the road from the dispatch on.'
SELECT serials_id, coalesce('location ' || at_location_id, 'road ' || at_transfer_id) AS cell, owner_location_id AS owner, state,
       lower(during) AS from, upper(during) AS to
  FROM unit_residence WHERE serials_id = 500 ORDER BY lower(during);

\echo '== 2. time, a moment: every unit on 15 Oct, then now.'
SELECT '15 Oct' AS at, unit, place, owner, state, why FROM cube_dots(tsrange('2026-10-15', '2026-10-15', '[]')) WHERE layer = 'fact'
UNION ALL
SELECT 'now', unit, place, owner, state, why FROM cube_dots(tsrange(LOCALTIMESTAMP, LOCALTIMESTAMP, '[]')) WHERE layer = 'fact'
ORDER BY 1, 2;

\echo '== 3. the second clock: 15 Oct as the books stood on 15 Oct. Expect 0: the opening was recorded only today.'
SELECT count(*) AS dots FROM cube_dots(tsrange('2026-10-15', '2026-10-15', '[]'), p_known_at => '2026-10-15');

\echo '== 4. a moment next week: each unit where it will be, and the plans that hold it then.'
SELECT unit, layer, place, owner, why, ref FROM cube_dots(tsrange(date_trunc('day', LOCALTIMESTAMP) + interval '8 days 12 hours',
       date_trunc('day', LOCALTIMESTAMP) + interval '8 days 12 hours', '[]'));

\echo '== 5. a unit: bike 502''s life, what happened, then what is planned.'
SELECT layer, place, owner, starts, ends, why, ref FROM cube_dots(p_units => '{502}');

\echo '== 6. a place and a period: who stood at the master during October.'
SELECT unit, layer, starts, ends, why FROM cube_dots(tsrange('2026-10-01', '2026-11-01'), p_places => '{location:1}');

\echo '== 7. a customer: every dot customer 7 takes part in.'
SELECT unit, layer, place, starts, ends, why, ref FROM cube_dots(p_customers => '{7}');

\echo '== 8. a model, widened: the units of variant 100, counted per place now.'
SELECT place, count(*) AS units FROM cube_dots(tsrange(LOCALTIMESTAMP, LOCALTIMESTAMP, '[]'), p_models => '{100}')
 WHERE layer = 'fact' GROUP BY place ORDER BY place;

\echo '== 9. two axes: customer 7 at a moment next week.'
SELECT unit, place, why, ref FROM cube_dots(tsrange(date_trunc('day', LOCALTIMESTAMP) + interval '7 days 12 hours',
       date_trunc('day', LOCALTIMESTAMP) + interval '7 days 12 hours', '[]'), p_customers => '{7}');

\echo '== 10. an instant: bike 504 built and back on the bench in one transaction, undone after. Expect the line'
\echo '       opening, built (starts = ends), back_to_bench; two dots in the period from then, one at that moment.'
BEGIN;
SELECT movement_built(504, 81) \g /dev/null
SELECT movement_back_to_bench(504, 81) \g /dev/null
SELECT why, state, starts, ends FROM cube_dots(p_units => '{504}');
SELECT (SELECT count(*) FROM cube_dots(tsrange(date_trunc('second', LOCALTIMESTAMP), NULL), p_units => '{504}')) AS in_the_period,
       (SELECT count(*) FROM cube_dots(tsrange(date_trunc('second', LOCALTIMESTAMP), date_trunc('second', LOCALTIMESTAMP), '[]'),
                                       p_units => '{504}')) AS at_the_moment;
ROLLBACK;

\echo '== 11. encounters that cannot happen. Expect two: bike 500 still on the road at its appointment, bike 502 rented and in service at once.'
SELECT serials_id, kind, ref_id, conflict, with_what, at FROM unit_waypoint_conflicts ORDER BY serials_id, kind;

\echo '== 12. an arrival dated before the unit''s last stay began. Expect MV002.'
WITH m AS (INSERT INTO movements (kind, occurred_at, users_id) VALUES ('arrived', '2026-10-05', 1) RETURNING id)
INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, at_transfer_id, owner_location_id, state)
SELECT m.id, 100, 500, x.q, x.l, x.t, 1, 'available' FROM m, (VALUES (-1, NULL::int4, 55::int8), (1, 2, NULL)) x(q, l, t);

\echo '== 13. a second stay over the first, written by hand. Expect the temporal key to refuse it.'
INSERT INTO unit_residence (serials_id, at_location_id, owner_location_id, state, during, movements_id)
SELECT 500, 2, 2, 'available', tsrange('2026-10-02', '2026-10-03'), min(id) FROM movements;
