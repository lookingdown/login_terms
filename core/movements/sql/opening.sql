-- The opening (movements-code.md §3.4; the first half of migration 028): today's history ported into the journal,
-- once, in one transaction, on the correct data shape. It runs after layer.sql, cube.sql and readers.sql, on the
-- live data once the client's corrections are in, in the one release that switches every module (step C):
--
--   SELECT opening();
--
-- It refuses while the data breaks the shape (MV900: the guard's classes, each row the client's to settle). Then it
-- ports, and proves the port: every unit ends where today's tables say it stands, and every balance is today's
-- (MV901 otherwise). A refusal leaves nothing behind. On a database that has movements already it does nothing.
-- retire.sql, the second half, then retires the old state. Both files can be run again: their functions are
-- replaced, the opening does nothing a second time, and the retirement does nothing once it is done.
--
-- Its parts can be run on their own on a copy, in a transaction rolled back after: opening_guard() lists what the
-- client has to settle, opening_port() ports regardless, and opening_proof() lists every unit and balance the port
-- did not bring to where today's tables stand. That is the rehearsal.

-- The guard (§3.4.1): the five classes of movements-discrepancies.md, as diagnostics.sql reads them (D4, D1, D7 and
-- D8, D5, D6). Each row names what to settle, by ids.
CREATE OR REPLACE FUNCTION public.opening_guard() RETURNS TABLE (class text, ids text)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    -- a serial-tracked balance that is not its units
    WITH units AS (
        SELECT location_id, variants_id, count(*) AS n FROM serials WHERE status IN ('stock', 'assembly', 'returned') GROUP BY 1, 2)
    SELECT 'serial_balance', 'location ' || COALESCE(b.location_id, u.location_id) || ' · variant ' || COALESCE(b.variants_id, u.variants_id)
                             || ': balance ' || COALESCE(b.stock, 0) || ', units ' || COALESCE(u.n, 0)
      FROM (SELECT sb.* FROM stock_balances sb JOIN variants v ON v.id = sb.variants_id JOIN items i ON i.id = v.items_id
             WHERE i.serial AND sb.location_id IS NOT NULL) b
      FULL JOIN units u ON u.location_id = b.location_id AND u.variants_id = b.variants_id
     WHERE COALESCE(b.stock, 0) <> COALESCE(u.n, 0)
    UNION ALL
    -- a negative balance
    SELECT 'negative', 'location ' || location_id || ' · variant ' || variants_id || ': ' || stock
      FROM stock_balances WHERE location_id IS NOT NULL AND stock < 0
    UNION ALL
    -- a bike that left without its unit: sold on a line with no unit, or carried on a remessa line without its units
    SELECT 'left_without_unit', 'sale line ' || sa.id || ' (stock row ' || st.id || ')'
      FROM stock st JOIN sales sa ON st.ref_type = 'sales' AND sa.id = st.ref_id
      JOIN variants v ON v.id = st.variants_id JOIN items i ON i.id = v.items_id
     WHERE i.serial AND st.type = 'sale' AND sa.serials_id IS NULL
    UNION ALL
    SELECT 'left_without_unit', 'remessa ' || ti.transfers_id || ' · variant ' || ti.variants_id || ': ' || SUM(ti.qty)
                                || ' carried, ' || COALESCE(MAX(u.n), 0) || ' units'
      FROM transfer_items ti JOIN transfers t ON t.id = ti.transfers_id
      JOIN variants v ON v.id = ti.variants_id JOIN items i ON i.id = v.items_id
      LEFT JOIN LATERAL (SELECT count(DISTINCT e.serials_id) AS n FROM serial_events e   -- the remessa on the event, or its ref
                          WHERE e.variants_id = ti.variants_id AND e.event IN ('dispatched', 'arrived')
                            AND COALESCE(e.transfers_id, e.from_transfers_id, CASE WHEN e.ref_type = 'transfers' THEN e.ref_id END) = ti.transfers_id) u ON true
     WHERE i.serial AND t.status IN ('sent', 'received')
     GROUP BY ti.transfers_id, ti.variants_id
    HAVING SUM(ti.qty) <> COALESCE(MAX(u.n), 0)
    UNION ALL
    -- a unit 'sold' on no live line
    SELECT 'sold_on_no_live_line', 'unit ' || s.id
      FROM serials s
     WHERE s.status = 'sold'
       AND NOT EXISTS (SELECT 1 FROM sales sa JOIN orders o ON o.id = sa.orders_id
                        WHERE sa.serials_id = s.id AND sa.status NOT IN ('cancelled', 'refunded') AND sa.deleted_at IS NULL
                          AND o.status NOT IN ('cancelled', 'refunded', 'voided') AND o.deleted_at IS NULL)
    UNION ALL
    -- a chassis twice once normalised (the C collation: ci_ai refuses a regular expression)
    SELECT 'chassis_twice', 'units ' || array_to_string(array_agg(id ORDER BY id), ', ')
      FROM serials WHERE serial_number IS NOT NULL AND serial_number <> ''
     GROUP BY upper(regexp_replace(serial_number COLLATE "C", '[^A-Za-z0-9]', '', 'g'))
    HAVING count(*) > 1
$$;

-- A unit's sale lines as the port tells them: the lines that name it, on a paid order with a customer, in order.
-- A line becomes the customer's when it is paid and its unit attached, whichever comes last (§0.3); the attach is
-- not recorded, so its moment is the payment, no earlier than the line. A live line on a completed order, or
-- delivered, is in the customer's hands (§3.4.2); a refunded one is undone, at its own moment: no refund is dated.
CREATE OR REPLACE VIEW public.opening_sales AS
SELECT sa.serials_id, sa.id AS sales_id, sa.location_id, o.customers_id,
       GREATEST(sa.created_at, COALESCE(o.paid_at, sa.created_at)) AS sold_at,
       sa.status IN ('cancelled', 'refunded') OR o.status IN ('cancelled', 'refunded', 'voided') AS undone,
       sa.delivered_date, (o.status = 'completed' OR sa.delivered_date IS NOT NULL) AS handed_over
  FROM sales sa JOIN orders o ON o.id = sa.orders_id
 WHERE sa.serials_id IS NOT NULL AND sa.deleted_at IS NULL AND o.deleted_at IS NULL AND o.paid AND o.customers_id IS NOT NULL;

-- Where today's tables say a unit stands, as a cell (mv_cell's keys, nulls left out); null when they cannot say: a
-- sold unit with no live paid line of a customer, a status the layer has no cell for.
CREATE OR REPLACE FUNCTION public.opening_expected(p_serials_id int4) RETURNS jsonb
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT CASE s.status
        WHEN 'stock' THEN jsonb_build_object('at_location_id', s.location_id, 'owner_location_id', s.location_id, 'state', 'available')
        WHEN 'returned' THEN jsonb_build_object('at_location_id', s.location_id, 'owner_location_id', s.location_id, 'state', 'available')
        WHEN 'assembly' THEN jsonb_build_object('at_location_id', s.location_id, 'owner_location_id', s.location_id, 'state', 'validating')
        WHEN 'written_off' THEN jsonb_build_object('at_location_id', s.location_id, 'owner_location_id', s.location_id, 'state', 'written_off')
        WHEN 'transit' THEN (SELECT jsonb_build_object('at_transfer_id', t.id, 'owner_location_id', t.location_id, 'state', 'available')
                               FROM transfers t WHERE t.id = s.transfers_id)
        WHEN 'sold' THEN (SELECT CASE WHEN os.handed_over
                                      THEN jsonb_build_object('at_customer_id', os.customers_id, 'owner_customer_id', os.customers_id, 'state', 'available')
                                      ELSE jsonb_build_object('at_location_id', os.location_id, 'owner_customer_id', os.customers_id, 'state', 'available') END
                            FROM opening_sales os WHERE os.serials_id = s.id AND NOT os.undone ORDER BY os.sold_at DESC, os.sales_id DESC LIMIT 1)
        END
      FROM serials s WHERE s.id = p_serials_id
$$;

-- The port (§3.4.2). Every unit's known story becomes its legs, dated when each step happened and recorded now, by
-- the system's account (the second clock tells the port apart). Its steps, in time order, each no earlier than the
-- one before:
--   its entry: its receipt (serial_events 'received', from the order's supplier, onto the bench at the receiving
--   location); a unit with no history but the move's snapshot (a 'seed') opens from the books where the seed puts
--   it, on the bench or available, at the seed's time or its first sale's, whichever is first;
--   built, when a unit on the bench goes on (a remessa, a sale), at its card's stocked_at or else just before;
--   its remessas, dispatched and arrived (serial_events);
--   its sales (opening_sales): sold, then handed over (at its delivery, else at the sale) or undone; a sale no
--   earlier than the unit's arrival at the sale's location, an undone sale before the live one.
-- A seed stands for a unit only until its first real event: a unit with a history ignores its seed. A draft's hold
-- becomes its transfer_units row. Counted goods open from their balance at each location (stock_balances) and on
-- each road (the old ledger's road rows), at the opening. Materials are not the layer's.
CREATE OR REPLACE FUNCTION public.opening_port() RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_unit  record;
    v_step  record;
    v_cell  jsonb;
    v_at    timestamp;
    v_units int4 := 0;
    v_steps int4 := 0;
    v_legs  jsonb;
BEGIN
    CREATE TEMP TABLE opening_steps (serials_id int4, variants_id int8, at timestamp, rank int4, kind text,
                                     ref_type text, ref_id int8, from_cell jsonb, to_cell jsonb) ON COMMIT DROP;

    -- entries: a receipt, else the seed
    INSERT INTO opening_steps
    SELECT e.serials_id, s.variants_id, e.happened_at, 1, 'received', 'purchase_items', e.ref_id,
           COALESCE((SELECT jsonb_build_object('at_supplier_id', p.suppliers_id, 'owner_supplier_id', p.suppliers_id, 'state', 'available')
                       FROM purchase_items pi JOIN purchases p ON p.id = pi.purchases_id
                      WHERE pi.id = e.ref_id AND p.suppliers_id IS NOT NULL), '{"state": "available"}'),
           jsonb_build_object('at_location_id', e.location_id, 'owner_location_id', e.location_id, 'state', 'validating')
      FROM serial_events e JOIN serials s ON s.id = e.serials_id
     WHERE e.event = 'received';
    INSERT INTO opening_steps
    SELECT sd.serials_id, s.variants_id,
           LEAST(sd.happened_at, (SELECT min(os.sold_at) FROM opening_sales os WHERE os.serials_id = sd.serials_id)),
           1, 'opening', NULL, NULL, '{"state": "available"}',
           jsonb_build_object('at_location_id', COALESCE(sd.location_id, s.location_id), 'owner_location_id', COALESCE(sd.location_id, s.location_id),
                              'state', CASE WHEN sd.to_status = 'assembly' THEN 'validating' ELSE 'available' END)
      FROM serial_events sd JOIN serials s ON s.id = sd.serials_id
     WHERE sd.event = 'seed'
       AND NOT EXISTS (SELECT 1 FROM serial_events r WHERE r.serials_id = sd.serials_id AND r.event <> 'seed');

    -- the remessas: the remessa is on the event, or (the seeded history) its ref
    INSERT INTO opening_steps
    SELECT e.serials_id, s.variants_id, e.happened_at, 3, e.event, 'transfers', COALESCE(e.transfers_id, e.from_transfers_id, CASE WHEN e.ref_type = 'transfers' THEN e.ref_id END), NULL,
           CASE e.event WHEN 'dispatched'
                THEN jsonb_build_object('at_transfer_id', COALESCE(e.transfers_id, e.from_transfers_id, CASE WHEN e.ref_type = 'transfers' THEN e.ref_id END), 'owner_location_id', e.location_id, 'state', 'available')
                ELSE jsonb_build_object('at_location_id', e.location_id, 'owner_location_id', e.location_id, 'state', 'available') END
      FROM serial_events e JOIN serials s ON s.id = e.serials_id
     WHERE e.event IN ('dispatched', 'arrived');

    -- the sales: sold, then in the customer's hands or undone. A sale is the customer's once paid and attached; a
    -- bike sold before it reached the shop was attached there, so the sale is no earlier than its arrival at the
    -- sale's location. The live line is the unit's end: an undone line comes before it.
    CREATE TEMP TABLE opening_unit_sales ON COMMIT DROP AS
    SELECT os.*, GREATEST(os.sold_at, (SELECT max(e.happened_at) FROM serial_events e
                                        WHERE e.serials_id = os.serials_id AND e.event = 'arrived' AND e.location_id = os.location_id)) AS at
      FROM opening_sales os;
    UPDATE opening_unit_sales l SET at = GREATEST(l.at, (SELECT max(u.at) FROM opening_unit_sales u WHERE u.serials_id = l.serials_id AND u.undone))
     WHERE NOT l.undone;
    INSERT INTO opening_steps
    SELECT us.serials_id, s.variants_id, us.at, CASE WHEN us.undone THEN 4 ELSE 6 END, 'sold', 'sales', us.sales_id, NULL,
           jsonb_build_object('owner_customer_id', us.customers_id)   -- the place it stands, the customer's now
      FROM opening_unit_sales us JOIN serials s ON s.id = us.serials_id;
    INSERT INTO opening_steps
    SELECT us.serials_id, s.variants_id, us.at, 5, 'sale_undone', 'sales', us.sales_id, NULL,
           jsonb_build_object('at_location_id', us.location_id, 'owner_location_id', us.location_id, 'state', 'available')
      FROM opening_unit_sales us JOIN serials s ON s.id = us.serials_id
     WHERE us.undone;
    INSERT INTO opening_steps
    SELECT us.serials_id, s.variants_id, GREATEST(COALESCE(us.delivered_date, us.at), us.at), 7, 'handed_over', 'sales', us.sales_id, NULL,
           jsonb_build_object('at_customer_id', us.customers_id, 'owner_customer_id', us.customers_id, 'state', 'available')
      FROM opening_unit_sales us JOIN serials s ON s.id = us.serials_id
     WHERE us.handed_over AND NOT us.undone;

    -- built: before a unit on the bench goes on, at its card's stocked_at, no later than the step it goes on by
    INSERT INTO opening_steps
    SELECT e.serials_id, e.variants_id, LEAST(COALESCE(b.stocked_at, b.next_at), COALESCE(b.next_at, b.stocked_at)),
           2, 'built', 'assembly', b.assembly_id, NULL, e.to_cell || '{"state": "available"}'
      FROM opening_steps e
      CROSS JOIN LATERAL (SELECT (SELECT max(a.stocked_at) FROM assembly a WHERE a.serials_id = e.serials_id) AS stocked_at,
                                 (SELECT max(a.id) FROM assembly a WHERE a.serials_id = e.serials_id) AS assembly_id,
                                 (SELECT min(n.at) FROM opening_steps n WHERE n.serials_id = e.serials_id AND n.rank > 1) AS next_at) b
     WHERE e.rank = 1 AND e.to_cell ->> 'state' = 'validating'
       AND (EXISTS (SELECT 1 FROM opening_steps n WHERE n.serials_id = e.serials_id AND n.rank > 1)
            OR (SELECT status FROM serials WHERE id = e.serials_id) IN ('stock', 'returned', 'sold'));

    -- each unit, its steps in order, each from the cell the one before put it in
    FOR v_unit IN SELECT DISTINCT serials_id FROM opening_steps ORDER BY serials_id LOOP
        v_cell := NULL;
        v_at := NULL;
        FOR v_step IN SELECT * FROM opening_steps WHERE serials_id = v_unit.serials_id ORDER BY at NULLS LAST, rank, ref_id LOOP
            v_at := GREATEST(v_at, COALESCE(v_step.at, v_at, LOCALTIMESTAMP));
            CONTINUE WHEN v_step.from_cell IS NULL AND v_cell IS NULL;   -- a step with nothing to move from
            PERFORM mv_post(v_step.kind, CASE WHEN v_step.ref_id IS NULL THEN NULL ELSE v_step.ref_type END, v_step.ref_id,
                            mv_pair(v_step.variants_id, v_unit.serials_id, 1, COALESCE(v_step.from_cell, v_cell),
                                    CASE WHEN v_step.kind = 'sold'
                                         THEN v_cell || '{"owner_location_id": null}' || v_step.to_cell
                                         ELSE v_step.to_cell END),
                            NULL, v_at);
            v_cell := CASE WHEN v_step.kind = 'sold' THEN v_cell || '{"owner_location_id": null}' || v_step.to_cell ELSE v_step.to_cell END;
            v_steps := v_steps + 1;
        END LOOP;
        v_units := v_units + 1;
    END LOOP;

    -- a draft's holds
    INSERT INTO transfer_units (transfers_id, serials_id)
    SELECT s.transfers_id, s.id FROM serials s JOIN transfers t ON t.id = s.transfers_id WHERE t.status = 'draft'
        ON CONFLICT DO NOTHING;

    -- counted goods, at each location and on each road, at the opening
    SELECT COALESCE(jsonb_agg(leg), '[]') INTO v_legs FROM (
        SELECT jsonb_array_elements(mv_pair(sb.variants_id, NULL, sb.stock, '{"state": "available"}',
                   jsonb_build_object('at_location_id', sb.location_id, 'owner_location_id', sb.location_id, 'state', 'available'))) AS leg
          FROM stock_balances sb JOIN variants v ON v.id = sb.variants_id JOIN items i ON i.id = v.items_id
         WHERE sb.location_id IS NOT NULL AND NOT i.serial AND i.sellable AND sb.stock > 0
        UNION ALL
        SELECT jsonb_array_elements(mv_pair(r.variants_id, NULL, r.qty::int4, '{"state": "available"}',
                   jsonb_build_object('at_transfer_id', r.transfers_id, 'owner_location_id', t.location_id, 'state', 'available')))
          FROM (SELECT st.ref_id AS transfers_id, st.variants_id, SUM(st.qty) AS qty FROM stock st
                 WHERE st.location_id IS NULL AND st.ref_type = 'transfers' GROUP BY 1, 2 HAVING SUM(st.qty) > 0) r
          JOIN transfers t ON t.id = r.transfers_id
          JOIN variants v ON v.id = r.variants_id JOIN items i ON i.id = v.items_id
         WHERE NOT i.serial AND i.sellable) x;
    IF v_legs <> '[]' THEN
        PERFORM mv_post('opening', NULL, NULL, v_legs);
    END IF;
    RETURN jsonb_build_object('units', v_units, 'steps', v_steps, 'counted_legs', jsonb_array_length(v_legs));
END $$;

-- The proof (§3.4.3): every unit ends where today's tables say it stands, and every counted balance is today's,
-- at each location and on each road. Each row is a difference: what today's tables say, what the port says.
CREATE OR REPLACE FUNCTION public.opening_proof() RETURNS TABLE (what text, id text, today jsonb, ported jsonb)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT 'unit', s.id::text, opening_expected(s.id), jsonb_strip_nulls(mv_cell(mv_unit_leg(s.id)))
      FROM serials s
     WHERE opening_expected(s.id) IS DISTINCT FROM jsonb_strip_nulls(mv_cell(mv_unit_leg(s.id)))
    UNION ALL
    SELECT 'balance', 'location ' || COALESCE(b.location_id, p.location_id) || ' · variant ' || COALESCE(b.variants_id, p.variants_id),
           to_jsonb(COALESCE(b.stock, 0)), to_jsonb(COALESCE(p.qty, 0))
      FROM (SELECT sb.location_id, sb.variants_id, sb.stock FROM stock_balances sb
              JOIN variants v ON v.id = sb.variants_id JOIN items i ON i.id = v.items_id
             WHERE sb.location_id IS NOT NULL AND NOT i.serial AND i.sellable AND sb.stock <> 0) b
      FULL JOIN (SELECT ps.at_location_id AS location_id, ps.variants_id, SUM(ps.qty) AS qty FROM positions ps
                   JOIN variants v ON v.id = ps.variants_id JOIN items i ON i.id = v.items_id
                  WHERE NOT i.serial AND ps.at_location_id = ps.owner_location_id AND ps.state = 'available'
                  GROUP BY 1, 2 HAVING SUM(ps.qty) <> 0) p
        ON p.location_id = b.location_id AND p.variants_id = b.variants_id
     WHERE COALESCE(b.stock, 0) <> COALESCE(p.qty, 0)
$$;

-- The opening itself: the guard, the port, the proof, in the caller's transaction. A refusal rolls it all back.
CREATE OR REPLACE FUNCTION public.opening() RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_guard  text;
    v_proof  text;
    v_ported jsonb;
BEGIN
    IF EXISTS (SELECT 1 FROM movements) THEN
        RETURN jsonb_build_object('opened', false, 'why', 'the journal has movements already');
    END IF;
    -- the port is the system's, at the master
    PERFORM set_config('app.user', '1', true);
    PERFORM set_config('app.location', app_master_location()::text, true);
    SELECT string_agg(class || ': ' || ids, E'\n' ORDER BY class, ids) INTO v_guard FROM opening_guard();
    IF v_guard IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'MV900', MESSAGE = 'The opening refuses: the data breaks the shape. Settle each row first.',
                              DETAIL = v_guard;
    END IF;
    v_ported := opening_port();
    SELECT string_agg(what || ' ' || id || ': today ' || COALESCE(today::text, 'says nothing') || ', ported ' || COALESCE(ported::text, 'nothing'),
                      E'\n' ORDER BY what, id) INTO v_proof FROM opening_proof();
    IF v_proof IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'MV901', MESSAGE = 'The port does not end where today''s tables stand.', DETAIL = v_proof;
    END IF;
    RETURN v_ported || jsonb_build_object('opened', true);
END $$;

REVOKE ALL ON FUNCTION public.opening(), public.opening_port(), public.opening_proof(), public.opening_guard(),
       public.opening_expected(int4) FROM PUBLIC;
