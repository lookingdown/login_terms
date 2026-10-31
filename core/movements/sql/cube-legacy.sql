-- The cube read from the history today's tables already hold (serial_events, the paid sale lines, the
-- documents' dates): what the opening will port, seen before it is ported. Read-only; ids and location
-- codes only. A 'seed' event is the move's snapshot of the state, not a movement: it stands for a unit
-- only until the unit's first real event, and its time is borrowed.
\pset footer off

CREATE TEMP VIEW legacy_events AS
SELECT e.serials_id, e.happened_at AS t, e.event,
       CASE WHEN e.to_status = 'transit' THEN 'road' ELSE l.code END AS place,
       CASE e.to_status WHEN 'assembly' THEN 'validating' WHEN 'written_off' THEN 'written_off'
                        WHEN 'transit' THEN 'available' WHEN NULL THEN 'validating' ELSE 'available' END AS state
  FROM serial_events e LEFT JOIN locations l ON l.id = e.location_id;

CREATE TEMP VIEW legacy_sales AS
SELECT DISTINCT ON (sa.serials_id) sa.serials_id, o.paid_at AS t
  FROM sales sa JOIN orders o ON o.id = sa.orders_id
 WHERE sa.serials_id IS NOT NULL AND o.paid AND o.paid_at IS NOT NULL
   AND sa.status NOT IN ('cancelled', 'refunded') AND o.status NOT IN ('cancelled', 'refunded', 'voided')
 ORDER BY sa.serials_id, o.paid_at;

-- where a unit stood at t: its last real event by t (else its seed, if the seed is by t), and whose
CREATE TEMP VIEW legacy_moments AS
SELECT m.at, s.id AS serials_id,
       COALESCE(ev.place, sd.place, 'not yet known') AS place,
       COALESCE(ev.state, sd.state) AS state,
       CASE WHEN ls.t <= m.at THEN 'customer' WHEN COALESCE(ev.place, sd.place) IS NULL THEN '' ELSE 'location' END AS owner
  FROM (VALUES (timestamp '2026-09-21 23:59'), ('2026-09-22 12:00'), ('2026-09-23 12:00'), ('2026-10-10 12:00'),
               ('2026-10-21 23:59')) m(at)
 CROSS JOIN serials s
  LEFT JOIN LATERAL (SELECT place, state FROM legacy_events e WHERE e.serials_id = s.id AND e.event <> 'seed' AND e.t <= m.at
                      ORDER BY e.t DESC LIMIT 1) ev ON true
  LEFT JOIN LATERAL (SELECT place, state FROM legacy_events e WHERE e.serials_id = s.id AND e.event = 'seed' AND e.t <= m.at
                       AND NOT EXISTS (SELECT 1 FROM legacy_events r WHERE r.serials_id = s.id AND r.event <> 'seed' AND r.t <= m.at)
                      LIMIT 1) sd ON true
  LEFT JOIN legacy_sales ls ON ls.serials_id = s.id;

\echo '== 1. the fleet in five slices: where the 98 units stood, and whose they were'
SELECT to_char(at, 'DD Mon HH24:MI') AS moment,
       count(*) FILTER (WHERE place = 'IMO' AND owner = 'location') AS at_master,
       count(*) FILTER (WHERE place = 'PRU' AND owner = 'location') AS at_pru,
       count(*) FILTER (WHERE place = 'CDV' AND owner = 'location') AS at_cdv,
       count(*) FILTER (WHERE place = 'road') AS on_the_road,
       count(*) FILTER (WHERE owner = 'customer') AS customers,
       count(*) FILTER (WHERE place = 'not yet known' AND owner <> 'customer') AS not_yet_known
  FROM legacy_moments GROUP BY at ORDER BY at;

\echo '== 2. one unit''s line through the cube (unit 69): recorded order and business order'
SELECT e.event, to_char(e.at, 'DD Mon HH24:MI:SS') AS recorded, to_char(e.happened_at, 'DD Mon HH24:MI:SS') AS happened,
       coalesce(e.to_status, '') AS status, coalesce(l.code, '') AS place
  FROM serial_events e LEFT JOIN locations l ON l.id = e.location_id WHERE e.serials_id = 69
UNION ALL
SELECT 'paid', '', to_char(t, 'DD Mon HH24:MI:SS'), 'the customer''s', '' FROM legacy_sales WHERE serials_id = 69
ORDER BY 3;

\echo '== 3. dwell: how long a trip spent on the road, and how long a bike stood at a shop before it was paid'
WITH trips AS (
    SELECT d.serials_id, a.t - d.t AS on_road
      FROM legacy_events d
      JOIN LATERAL (SELECT t FROM legacy_events a WHERE a.serials_id = d.serials_id AND a.event = 'arrived' AND a.t >= d.t
                     ORDER BY a.t LIMIT 1) a ON true
     WHERE d.event = 'dispatched'),
shelf AS (
    SELECT a.serials_id, ls.t - a.t AS before_paid
      FROM legacy_events a JOIN legacy_sales ls ON ls.serials_id = a.serials_id AND ls.t > a.t
     WHERE a.event = 'arrived')
SELECT 'on the road' AS what, count(*) AS cases, min(on_road) AS shortest, avg(on_road)::interval(0) AS average, max(on_road) AS longest FROM trips
UNION ALL
SELECT 'at a shop before paid', count(*), min(before_paid), avg(before_paid)::interval(0), max(before_paid) FROM shelf;

\echo '== 4. the roster beside the facts: purchases expected and received, service orders scheduled and done'
SELECT 'purchases' AS document, count(*) FILTER (WHERE received IS NOT NULL) AS done,
       count(*) FILTER (WHERE received > expected) AS late, count(*) FILTER (WHERE received <= expected) AS on_time,
       max(received - expected) AS latest_by_days,
       count(*) FILTER (WHERE received IS NULL AND expected >= date '2026-10-30') AS still_expected
  FROM purchases WHERE expected IS NOT NULL
UNION ALL
SELECT 'service orders (with a unit)', count(*) FILTER (WHERE completed_date IS NOT NULL),
       count(*) FILTER (WHERE completed_date::date > scheduled_date), count(*) FILTER (WHERE completed_date::date <= scheduled_date),
       max(completed_date::date - scheduled_date), count(*) FILTER (WHERE completed_date IS NULL)
  FROM service_orders WHERE serials_id IS NOT NULL AND scheduled_date IS NOT NULL;

\echo '== 5. what the history cannot say: the handovers (where a sold bike is); and the remessas'' expected arrivals,'
\echo '       which dispatch writes on the shop''s order (purchases.expected), the dispatch day unless one is given'
SELECT (SELECT count(*) FROM legacy_sales) AS units_paid,
       (SELECT count(*) FROM sales WHERE serials_id IS NOT NULL AND delivered_date IS NOT NULL) AS handovers_recorded;
WITH r AS (
    SELECT t.id, sp.expected, sp.received,
           (SELECT min(st.created_at)::date FROM stock st
             WHERE st.ref_type = 'transfers' AND st.ref_id = t.id AND st.location_id = t.location_id AND st.qty < 0) AS dispatched_on
      FROM transfers t JOIN purchases sp ON sp.id = t.shop_purchases_id)
SELECT count(*) AS remessas, count(expected) AS with_an_expected_arrival,
       count(*) FILTER (WHERE expected = dispatched_on) AS on_the_dispatch_day,
       count(*) FILTER (WHERE expected < dispatched_on) AS before_it,
       count(*) FILTER (WHERE expected > dispatched_on) AS set_ahead,
       count(*) FILTER (WHERE received > expected) AS received_after_it
  FROM r;
