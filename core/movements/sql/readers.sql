-- The readers' SQL: what the kernels read in one statement (CONTRACT.md). Runs after layer.sql and cube.sql.

-- The journal as one location sees it: one row per movement, model and unit, for every movement with a leg that
-- stands there or is its own. qty is what the movement changed in the location's own stock (standing there, its
-- own, validating or available); from_cell and to_cell are the cells it left and entered (mv_cell's keys); reason
-- is the movement's key (an adjustment's why, who bears a loss).
-- The documents' process lines ride beside them, as the screens show them: an assembly job's stage and a service
-- order's state, each a row of qty 0 whose cells are {"stage": …}.
CREATE FUNCTION public.movement_rows(p_location int4)
RETURNS TABLE (movements_id int8, occurred_at timestamp, recorded_at timestamp, kind text, variants_id int8,
               serials_id int4, qty int4, from_cell jsonb, to_cell jsonb, ref_type text, ref_id int8, note text,
               users_id int4, reason text)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT m.id, m.occurred_at, m.recorded_at, m.kind::text, l.variants_id, l.serials_id,
           SUM(CASE WHEN l.at_location_id = p_location AND l.owner_location_id = p_location
                     AND l.state IN ('validating', 'available') THEN l.qty ELSE 0 END)::int4,
           (array_agg(mv_cell(l) ORDER BY l.id) FILTER (WHERE l.qty < 0))[1],
           (array_agg(mv_cell(l) ORDER BY l.id) FILTER (WHERE l.qty > 0))[1],
           m.ref_type::text, m.ref_id, m.note::text, m.users_id, m.reason
      FROM movements m
      JOIN movement_legs l ON l.movements_id = m.id
     WHERE EXISTS (SELECT 1 FROM movement_legs t
                    WHERE t.movements_id = m.id AND (t.at_location_id = p_location OR t.owner_location_id = p_location))
     GROUP BY m.id, l.variants_id, l.serials_id
    UNION ALL
    SELECT NULL, kh.created_at, kh.created_at, 'assembly', a.variants_id, a.serials_id, 0,
           jsonb_build_object('stage', kh.from_state), jsonb_build_object('stage', kh.to_state),
           'assembly', a.id, kh.note::text, (substring(kh.actor FROM '^user:(\d+)$'))::int4, NULL
      FROM kanban_history kh JOIN assembly a ON a.id = kh.item_id
     WHERE kh.workflow = 'assembly' AND kh.location_id = p_location
    UNION ALL
    SELECT NULL, kh.created_at, kh.created_at, 'service', so.variants_id, so.serials_id, 0,
           jsonb_build_object('stage', kh.from_state), jsonb_build_object('stage', kh.to_state),
           'service_orders', so.id, kh.note::text, (substring(kh.actor FROM '^user:(\d+)$'))::int4, NULL
      FROM kanban_history kh JOIN service_orders so ON so.id = kh.item_id
     WHERE kh.workflow = 'service_orders' AND kh.location_id = p_location
$$;

GRANT EXECUTE ON FUNCTION public.movement_rows(int4) TO app_staff;
