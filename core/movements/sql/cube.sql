-- The time axis of the movement layer: the cube's fourth dimension.
--
-- A unit's life is a line through where · owner · state over time. Here it is stored three ways:
--   facts      unit_residence: one row per stay in a cell, [from, to); the open stay is now.
--   intent     unit_waypoints: the stays its documents plan (a rental, an appointment, a service
--              order, a loan, an order's hold): the roster, with what really happened beside it.
--   slices     whereabouts(t[, known_at]): every unit at one moment, as known now or as the books
--              stood at known_at; the future is the current stay plus its waypoints.
-- Runs after layer.sql. PostgreSQL 18; btree_gist for the temporal key.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Facts. Kept from the legs by the trigger below; never written by hand. One place at a time is a
-- constraint: PostgreSQL 18's temporal primary key refuses two stays of a unit that overlap.
CREATE TABLE public.unit_residence (
    serials_id        int4 NOT NULL REFERENCES public.serials,
    at_location_id    int4,
    at_transfer_id    int8,
    at_customer_id    int4,
    at_supplier_id    int8,
    owner_location_id int4,
    owner_customer_id int4,
    owner_supplier_id int8,
    state             text COLLATE public.ci_ai NOT NULL,
    during            tsrange NOT NULL,
    movements_id      int8 NOT NULL REFERENCES public.movements,   -- the event that put it there
    PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)
);
CREATE INDEX unit_residence_slice ON public.unit_residence USING gist (during);
CREATE INDEX unit_residence_place ON public.unit_residence USING gist (at_location_id, during);

-- A unit's stays, rebuilt from its +1 legs in business time: each lasts until the next one starts.
-- A stay of no length (two hops in the same second) holds no moment and is left out.
CREATE FUNCTION public.unit_residence_rebuild(p_serial int4) RETURNS void
    LANGUAGE sql SET search_path = public, pg_temp AS $$
    DELETE FROM unit_residence WHERE serials_id = p_serial;
    INSERT INTO unit_residence (serials_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
                                owner_location_id, owner_customer_id, owner_supplier_id, state, during, movements_id)
    SELECT serials_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
           owner_location_id, owner_customer_id, owner_supplier_id, state, during, movements_id
      FROM (SELECT l.*, tsrange(m.occurred_at, lead(m.occurred_at) OVER (ORDER BY m.occurred_at, l.id)) AS during
              FROM movement_legs l JOIN movements m ON m.id = l.movements_id
             WHERE l.serials_id = p_serial AND l.qty = 1) s
     WHERE NOT isempty(during);
$$;

-- Business time runs forward per unit: an event dated before the unit's last stay began is refused,
-- unless it is a correction (corrects_id), which rewrites the stays from the legs (plan §1.3.5).
CREATE FUNCTION public.movement_legs_residence() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_at       timestamp;
    v_corrects int8;
    v_last     timestamp;
BEGIN
    SELECT occurred_at, corrects_id INTO v_at, v_corrects FROM movements WHERE id = NEW.movements_id;
    SELECT max(lower(during)) INTO v_last FROM unit_residence WHERE serials_id = NEW.serials_id;
    IF v_corrects IS NULL AND v_at < v_last THEN
        PERFORM mv_refuse('MV002', 'Um movimento não pode ser datado antes do último desta unidade: use uma correção.',
                          jsonb_build_object('serials_id', NEW.serials_id, 'occurred_at', v_at, 'last', v_last));
    END IF;
    PERFORM unit_residence_rebuild(NEW.serials_id);
    RETURN NULL;
END $$;
CREATE TRIGGER movement_legs_residence AFTER INSERT ON public.movement_legs
    FOR EACH ROW WHEN (NEW.serials_id IS NOT NULL AND NEW.qty = 1)
    EXECUTE FUNCTION public.movement_legs_residence();

-- Intent: the stays the documents plan, with what really happened beside them where the document
-- records it (scheduled and actual, the crew roster's pair). An appointment is a moment, not a stay.
CREATE VIEW public.unit_waypoints WITH (security_invoker = true) AS
SELECT r.serials_id::int4 AS serials_id, 'rental'::text AS kind, b.id::int8 AS ref_id,
       'customer'::text AS place_kind, NULL::int4 AS location_id, b.customer_id AS customers_id,
       tsrange(b.start_at, b.end_at) AS planned,
       CASE WHEN b.picked_up_at IS NOT NULL THEN tsrange(b.picked_up_at, b.returned_at) END AS actual
  FROM bookings b JOIN resources r ON r.id = b.resource_id
 WHERE b.cancelled_at IS NULL AND r.serials_id IS NOT NULL AND b.end_at > b.start_at
UNION ALL
SELECT a.serials_id, 'appointment', a.id, 'location', a.location_id, a.customers_id,
       tsrange(a.starts_at, a.starts_at, '[]'), NULL
  FROM workshop_appointments a
 WHERE a.serials_id IS NOT NULL
UNION ALL
SELECT so.serials_id, 'service', so.id, 'location', so.location_id, so.customers_id,
       tsrange(so.scheduled_date, COALESCE(so.expected_date, so.scheduled_date) + 1),
       CASE WHEN so.completed_date IS NOT NULL THEN tsrange(so.scheduled_date, so.completed_date, '[]') END
  FROM service_orders so
 WHERE so.serials_id IS NOT NULL AND so.scheduled_date IS NOT NULL
UNION ALL
SELECT l.serials_id::int4, 'loan', l.id, 'customer', NULL, NULL,
       tsrange(COALESCE(l.out_at, l.created_at), l.due_at + 1),
       CASE WHEN l.out_at IS NOT NULL THEN tsrange(l.out_at, l.returned_at) END
  FROM loans l
 WHERE l.status <> 'cancelado' AND l.due_at + 1 > COALESCE(l.out_at, l.created_at)
UNION ALL
SELECT sa.serials_id, 'reserved', o.id, 'location', o.location_id, o.customers_id,
       tsrange(o.created_at, o.reserved_until), NULL
  FROM orders o JOIN sales sa ON sa.orders_id = o.id
 WHERE sa.serials_id IS NOT NULL AND o.reserved_until > o.created_at AND o.deleted_at IS NULL
   AND o.status NOT IN ('cancelled', 'refunded', 'voided');

-- One unit, one moment: every unit's cell at p_at. As known now by default; with p_known_at, as the books
-- stood then (only what had been recorded by then: the system time beside the business time). A moment
-- after now finds the current stay, which runs on, with the waypoint the documents plan for that moment.
CREATE FUNCTION public.whereabouts(p_at timestamp DEFAULT LOCALTIMESTAMP, p_known_at timestamp DEFAULT NULL)
RETURNS TABLE (serials_id int4, place_kind text, location_id int4, transfers_id int8, customers_id int4,
               suppliers_id int8, owner_location_id int4, owner_customer_id int4, state text, since timestamp,
               waypoint text, waypoint_ref int8, waypoint_location_id int4)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    WITH fact AS (
        SELECT r.serials_id, r.at_location_id, r.at_transfer_id, r.at_customer_id, r.at_supplier_id,
               r.owner_location_id, r.owner_customer_id, r.state, lower(r.during) AS since
          FROM unit_residence r
         WHERE p_known_at IS NULL AND r.during @> p_at
        UNION ALL
        (SELECT DISTINCT ON (l.serials_id) l.serials_id, l.at_location_id, l.at_transfer_id, l.at_customer_id,
                l.at_supplier_id, l.owner_location_id, l.owner_customer_id, l.state, m.occurred_at
           FROM movement_legs l JOIN movements m ON m.id = l.movements_id
          WHERE p_known_at IS NOT NULL AND l.serials_id IS NOT NULL AND l.qty = 1
            AND m.occurred_at <= p_at AND m.recorded_at <= p_known_at
          ORDER BY l.serials_id, m.occurred_at DESC, l.id DESC))
    SELECT f.serials_id,
           CASE WHEN f.at_location_id IS NOT NULL THEN 'location' WHEN f.at_transfer_id IS NOT NULL THEN 'road'
                WHEN f.at_customer_id IS NOT NULL THEN 'customer' WHEN f.at_supplier_id IS NOT NULL THEN 'supplier'
                ELSE 'the books' END,
           f.at_location_id, f.at_transfer_id, f.at_customer_id, f.at_supplier_id,
           f.owner_location_id, f.owner_customer_id, f.state, f.since,
           w.kind, w.ref_id, w.location_id
      FROM fact f
      LEFT JOIN LATERAL (SELECT * FROM unit_waypoints w WHERE w.serials_id = f.serials_id AND w.planned @> p_at
                          ORDER BY lower(w.planned) DESC LIMIT 1) w ON true
$$;

-- A unit's life in order: its stays, then what its documents plan from here on.
CREATE VIEW public.unit_trajectory WITH (security_invoker = true) AS
SELECT r.serials_id, 'fact'::text AS layer, lower(r.during) AS starts, upper(r.during) AS ends,
       CASE WHEN r.at_location_id IS NOT NULL THEN 'location' WHEN r.at_transfer_id IS NOT NULL THEN 'road'
            WHEN r.at_customer_id IS NOT NULL THEN 'customer' WHEN r.at_supplier_id IS NOT NULL THEN 'supplier'
            ELSE 'the books' END AS place_kind,
       COALESCE(r.at_location_id::int8, r.at_transfer_id, r.at_customer_id::int8, r.at_supplier_id) AS place_id,
       r.owner_location_id, r.owner_customer_id, r.state, m.kind AS how, r.movements_id AS ref_id
  FROM unit_residence r JOIN movements m ON m.id = r.movements_id
UNION ALL
SELECT w.serials_id, 'plan', lower(w.planned), upper(w.planned), w.place_kind,
       COALESCE(w.location_id::int8, w.customers_id::int8), NULL, NULL, NULL, w.kind, w.ref_id
  FROM unit_waypoints w
 WHERE upper(w.planned) > LOCALTIMESTAMP OR upper_inf(w.planned);

-- Encounters that cannot happen (each must answer nothing):
--   two plans that hold one unit at the same moment;
--   a plan at a place where, at that moment, the unit will not be (it is elsewhere, or on its way);
--   a rental or a loan of a unit no location owns at that moment (sold, or with its customer).
CREATE VIEW public.unit_waypoint_conflicts WITH (security_invoker = true) AS
SELECT a.serials_id, a.kind, a.ref_id, 'two plans at once'::text AS conflict,
       b.kind || ' ' || b.ref_id AS with_what, lower(a.planned * b.planned) AS at
  FROM unit_waypoints a
  JOIN unit_waypoints b ON b.serials_id = a.serials_id AND (a.kind, a.ref_id) < (b.kind, b.ref_id)
 WHERE a.planned && b.planned
UNION ALL
SELECT w.serials_id, w.kind, w.ref_id, 'the unit will not be there',
       COALESCE('location ' || r.at_location_id, 'road ' || r.at_transfer_id, 'customer ' || r.at_customer_id,
                'supplier ' || r.at_supplier_id, 'nowhere known'), lower(w.planned)
  FROM unit_waypoints w
  LEFT JOIN unit_residence r ON r.serials_id = w.serials_id AND r.during @> lower(w.planned)
 WHERE w.place_kind = 'location' AND w.kind IN ('appointment', 'reserved')
   AND upper(w.planned) > LOCALTIMESTAMP
   AND r.at_location_id IS DISTINCT FROM w.location_id
UNION ALL
SELECT w.serials_id, w.kind, w.ref_id, 'no location owns the unit then', 'owner customer ' || r.owner_customer_id,
       lower(w.planned)
  FROM unit_waypoints w
  JOIN unit_residence r ON r.serials_id = w.serials_id AND r.during && w.planned
 WHERE w.kind IN ('rental', 'loan') AND r.owner_location_id IS NULL;

GRANT SELECT ON public.unit_residence, public.unit_waypoints, public.unit_trajectory, public.unit_waypoint_conflicts TO app_staff;
GRANT EXECUTE ON FUNCTION public.whereabouts(timestamp, timestamp) TO app_staff;
ALTER TABLE public.unit_residence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.unit_residence FORCE ROW LEVEL SECURITY;
CREATE POLICY unit_residence_read ON public.unit_residence FOR SELECT TO app_staff USING (
    (SELECT app_at_master())
    OR at_location_id = (SELECT app_location()) OR owner_location_id = (SELECT app_location())
    OR at_transfer_id IN (SELECT t.id FROM transfers t));
