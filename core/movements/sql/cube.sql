-- The time axis of the movement layer: the cube's fourth dimension.
--
-- A unit's life is a line through where · owner · state over time. Here it is kept three ways:
--   facts      unit_residence: one row per stay in a cell, [from, to); the open stay is now.
--   intent     unit_waypoints: the stays its documents plan (a rental, an appointment, a service
--              order, a loan, an order's hold): the roster, with what really happened beside it.
--   the axes   cube_dots(): any cut through facts and plans, as known now or as the books stood then.
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
        PERFORM mv_refuse('MV002', 'A movement cannot be dated before the unit''s last one: post a correction.',
                          jsonb_build_object('serials_id', NEW.serials_id, 'occurred_at', v_at, 'last', v_last));
    END IF;
    PERFORM unit_residence_rebuild(NEW.serials_id);
    RETURN NULL;
END $$;
CREATE TRIGGER movement_legs_residence AFTER INSERT ON public.movement_legs
    FOR EACH ROW WHEN (NEW.serials_id IS NOT NULL AND NEW.qty = 1)
    EXECUTE FUNCTION public.movement_legs_residence();

-- Intent: the stays the documents plan, with what really happened beside them where the document
-- records it (scheduled and actual, the crew roster's pair). An appointment and an arrival are moments.
-- What will not happen is no plan: a cancelled or missed appointment, a cancelled service order.
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
 WHERE a.serials_id IS NOT NULL AND a.status NOT IN ('cancelled', 'no_show')
UNION ALL
SELECT so.serials_id, 'service', so.id, 'location', so.location_id, so.customers_id,
       tsrange(so.scheduled_date, COALESCE(so.expected_date, so.scheduled_date) + 1),
       CASE WHEN so.completed_date IS NOT NULL THEN tsrange(so.scheduled_date, so.completed_date, '[]') END
  FROM service_orders so
 WHERE so.serials_id IS NOT NULL AND so.scheduled_date IS NOT NULL AND so.service_status <> 'cancelled'
UNION ALL
SELECT l.serials_id::int4, 'loan', l.id, 'customer', NULL, l.customers_id,
       tsrange(COALESCE(l.out_at, l.created_at), l.due_at + 1),
       CASE WHEN l.out_at IS NOT NULL THEN tsrange(l.out_at, l.returned_at) END
  FROM loans l
 WHERE l.status <> 'cancelado' AND l.due_at + 1 > COALESCE(l.out_at, l.created_at)
UNION ALL
SELECT sa.serials_id, 'reserved', o.id, 'location', o.location_id, o.customers_id,
       tsrange(o.created_at, o.reserved_until), NULL
  FROM orders o JOIN sales sa ON sa.orders_id = o.id
 WHERE sa.serials_id IS NOT NULL AND o.reserved_until > o.created_at AND o.deleted_at IS NULL
   AND o.status NOT IN ('cancelled', 'refunded', 'voided')
UNION ALL
-- a remessa's units, expected at its destination: the road's forward end, beside when each arrived
SELECT l.serials_id, 'arrival', t.id, 'location', t.to_location_id, NULL,
       tsrange(t.expected_at, t.expected_at, '[]'),
       (SELECT tsrange(m.occurred_at, m.occurred_at, '[]')
          FROM movement_legs a JOIN movements m ON m.id = a.movements_id
         WHERE a.serials_id = l.serials_id AND a.qty = 1 AND a.at_location_id = t.to_location_id
           AND m.kind = 'arrived' AND m.ref_type = 'transfers' AND m.ref_id = t.id
         ORDER BY m.occurred_at LIMIT 1)
  FROM movement_legs l JOIN transfers t ON t.id = l.at_transfer_id
 WHERE l.serials_id IS NOT NULL AND l.qty = 1 AND t.expected_at IS NOT NULL;

-- Encounters that cannot happen, from now on (each must answer nothing). conflict is a key, with_what a
-- coordinate: what a person reads is the i18n's (conflict_<key>).
--   two_plans  two plans that hold one unit at the same moment;
--   not_there  a plan at a place where, at that moment, the unit will not be: it stands elsewhere, or it is
--              on a road that is not expected there by then;
--   not_owned  a rental or a loan of a unit no location owns at that moment (sold, or with its customer).
CREATE VIEW public.unit_waypoint_conflicts WITH (security_invoker = true) AS
SELECT a.serials_id, a.kind, a.ref_id, 'two_plans'::text AS conflict,
       b.kind || ':' || b.ref_id AS with_what, lower(a.planned * b.planned) AS at
  FROM unit_waypoints a
  JOIN unit_waypoints b ON b.serials_id = a.serials_id AND (a.kind, a.ref_id) < (b.kind, b.ref_id)
 WHERE a.planned && b.planned AND 'arrival' NOT IN (a.kind, b.kind)
   AND (upper(a.planned * b.planned) > LOCALTIMESTAMP OR upper_inf(a.planned * b.planned))
UNION ALL
SELECT w.serials_id, w.kind, w.ref_id, 'not_there',
       COALESCE('location:' || r.at_location_id, 'road:' || r.at_transfer_id, 'customer:' || r.at_customer_id,
                'supplier:' || r.at_supplier_id, 'books'), lower(w.planned)
  FROM unit_waypoints w
  LEFT JOIN unit_residence r ON r.serials_id = w.serials_id AND r.during @> lower(w.planned)
  LEFT JOIN transfers t ON t.id = r.at_transfer_id
 WHERE w.place_kind = 'location' AND w.kind IN ('appointment', 'reserved')
   AND upper(w.planned) > LOCALTIMESTAMP
   AND r.at_location_id IS DISTINCT FROM w.location_id
   AND NOT COALESCE(t.to_location_id = w.location_id AND t.expected_at <= lower(w.planned), false)
UNION ALL
SELECT w.serials_id, w.kind, w.ref_id, 'not_owned', 'customer:' || r.owner_customer_id, lower(w.planned)
  FROM unit_waypoints w
  JOIN unit_residence r ON r.serials_id = w.serials_id AND r.during && w.planned
 WHERE w.kind IN ('rental', 'loan') AND r.owner_location_id IS NULL
   AND (upper(w.planned) > LOCALTIMESTAMP OR upper_inf(w.planned));

-- The axes. The cube is dots: a unit, in a place, of an owner, in a state, for a stretch of time, for a
-- reason. One function cuts it along any axes and always answers dots. Each axis is optional: left out it
-- is whole; given as a point it cuts; given as a range or a set it widens.
--   p_time      a moment '[t,t]' or a period '[a,b)': the dots that touch it
--   p_units     units (serials_id)                p_models     every unit of these models (variants_id)
--   p_places    'location:2', 'road:55', 'customer:7', 'supplier:3', 'books'
--   p_owners    the same coordinates: whose       p_states     'validating', 'available', 'written_off'
--   p_customers the dots a customer is the place or the owner of, and the plans it is in
--   p_layers    'fact', 'plan'                    p_known_at   the second clock: the facts as the books stood then
-- Facts are the stays from the legs; plans are the waypoints, which have a place but no owner or state.
-- A dot is always (unit, model, layer, place, owner, state, starts, ends, why, ref, customer); why and ref
-- say what put it there: a fact's movement (its kind and id), a plan's document. In order: by unit, then by time.
-- Two events of a unit in one second leave a stay of no length, an instant (starts = ends). It is on the
-- unit's line and in a period, never at a moment: at a moment a unit stands in one cell.
CREATE FUNCTION public.cube_dots(p_time tsrange DEFAULT NULL, p_units int4[] DEFAULT NULL, p_models int8[] DEFAULT NULL,
                                 p_places text[] DEFAULT NULL, p_owners text[] DEFAULT NULL, p_states text[] DEFAULT NULL,
                                 p_customers int4[] DEFAULT NULL, p_layers text[] DEFAULT NULL, p_known_at timestamp DEFAULT NULL)
RETURNS TABLE (unit int4, model int8, layer text, place text, owner text, state text,
               starts timestamp, ends timestamp, why text, ref int8, customer int4)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    WITH facts AS (
        SELECT l.serials_id, l.variants_id, 'fact'::text AS layer,
               CASE WHEN l.at_location_id IS NOT NULL THEN 'location:' || l.at_location_id
                    WHEN l.at_transfer_id IS NOT NULL THEN 'road:' || l.at_transfer_id
                    WHEN l.at_customer_id IS NOT NULL THEN 'customer:' || l.at_customer_id
                    WHEN l.at_supplier_id IS NOT NULL THEN 'supplier:' || l.at_supplier_id
                    ELSE 'books' END AS place,
               CASE WHEN l.owner_location_id IS NOT NULL THEN 'location:' || l.owner_location_id
                    WHEN l.owner_customer_id IS NOT NULL THEN 'customer:' || l.owner_customer_id
                    WHEN l.owner_supplier_id IS NOT NULL THEN 'supplier:' || l.owner_supplier_id
                    ELSE 'books' END AS owner,
               l.state::text AS state, m.occurred_at AS starts, lead(m.occurred_at) OVER line AS ends,
               tsrange(m.occurred_at, lead(m.occurred_at) OVER line) AS during,
               m.kind AS why, l.movements_id AS ref_id, COALESCE(l.at_customer_id, l.owner_customer_id) AS customers_id,
               l.id AS seq
          FROM movement_legs l JOIN movements m ON m.id = l.movements_id
         WHERE l.serials_id IS NOT NULL AND l.qty = 1 AND (p_known_at IS NULL OR m.recorded_at <= p_known_at)
        WINDOW line AS (PARTITION BY l.serials_id ORDER BY m.occurred_at, l.id)),
    plans AS (
        SELECT w.serials_id, s.variants_id, 'plan'::text,
               w.place_kind || ':' || COALESCE(w.location_id::text, w.customers_id::text, '?'),
               NULL::text, NULL::text, lower(w.planned), upper(w.planned), w.planned, w.kind, w.ref_id, w.customers_id,
               NULL::int8
          FROM unit_waypoints w JOIN serials s ON s.id = w.serials_id),
    dots AS (SELECT * FROM facts UNION ALL SELECT * FROM plans)
    SELECT d.serials_id, d.variants_id, d.layer, d.place, d.owner, d.state, d.starts, d.ends,
           d.why, d.ref_id, d.customers_id
      FROM dots d
     WHERE (p_time IS NULL OR d.during && p_time
            OR (isempty(d.during) AND p_time @> d.starts AND NOT coalesce(lower(p_time) = upper(p_time), false)))
       AND (p_units IS NULL OR d.serials_id = ANY (p_units))
       AND (p_models IS NULL OR d.variants_id = ANY (p_models))
       AND (p_places IS NULL OR d.place = ANY (p_places))
       AND (p_owners IS NULL OR d.owner = ANY (p_owners))
       AND (p_states IS NULL OR d.state = ANY (p_states))
       AND (p_customers IS NULL OR d.customers_id = ANY (p_customers))
       AND (p_layers IS NULL OR d.layer = ANY (p_layers))
     ORDER BY d.serials_id, d.starts, d.layer, d.seq, d.ref_id
$$;
GRANT EXECUTE ON FUNCTION public.cube_dots(tsrange, int4[], int8[], text[], text[], text[], int4[], text[], timestamp) TO app_staff;

GRANT SELECT ON public.unit_residence, public.unit_waypoints, public.unit_waypoint_conflicts TO app_staff;
ALTER TABLE public.unit_residence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.unit_residence FORCE ROW LEVEL SECURITY;
CREATE POLICY unit_residence_read ON public.unit_residence FOR SELECT TO app_staff USING (
    (SELECT app_at_master())
    OR at_location_id = (SELECT app_location()) OR owner_location_id = (SELECT app_location())
    OR at_transfer_id IN (SELECT t.id FROM transfers t));
