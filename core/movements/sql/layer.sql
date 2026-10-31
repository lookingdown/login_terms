-- The movement layer (movements-code.md §3.1 and §3.3): its tables, the refusal helper, and
-- movement_dispatch as the pattern every event function follows. Step B: nothing calls it yet.
-- Runs on imobee (PostgreSQL 18) after today's schema.

-- A remessa draft's units: the draft's own rows, replacing serials.transfers_id (code §3.3).
CREATE TABLE public.transfer_units (
    transfers_id int8 NOT NULL REFERENCES public.transfers ON DELETE CASCADE,
    serials_id   int4 NOT NULL REFERENCES public.serials,
    PRIMARY KEY (transfers_id, serials_id)
);

-- A remessa's expected arrival, a date and a time (a same-day delivery has its hour): the road's forward end.
-- Dispatch refuses a remessa without one (MV018); the shop's order keeps its date in purchases.expected.
ALTER TABLE public.transfers ADD COLUMN IF NOT EXISTS expected_at timestamp(0);

-- One row per business event.
CREATE TABLE public.movements (
    id          int8 GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind        text COLLATE public.ci_ai NOT NULL CHECK (kind IN (
                    'received', 'receipt_corrected', 'built', 'back_to_bench', 'dispatched', 'arrived',
                    'not_sent', 'lost', 'swapped', 'flipped', 'sold', 'handed_over', 'sale_undone',
                    'returned', 'traded_in', 'rented', 'rental_back', 'loaned', 'loan_back',
                    'workshop_in', 'workshop_out', 'written_off', 'to_provider', 'adjusted', 'counted',
                    'corrected', 'opening')),
    -- truncated, not rounded: timestamp(0) rounds, which could stamp a movement up to half a second ahead
    -- of the moment it happened, and a slice taken right after would not see it yet
    occurred_at timestamp(0) NOT NULL DEFAULT date_trunc('second', LOCALTIMESTAMP),
    recorded_at timestamp(0) NOT NULL DEFAULT date_trunc('second', LOCALTIMESTAMP),
    users_id    int4 REFERENCES public.users,
    ref_type    text COLLATE public.ci_ai CHECK (ref_type IN ('purchase_items', 'transfers', 'sales', 'orders',
                    'assembly', 'stock_counts', 'loans', 'bookings', 'approvals')),
    ref_id      int8,
    note        varchar(500) COLLATE public.ci_ai,
    corrects_id int8 REFERENCES public.movements,
    CHECK (users_id IS NOT NULL OR kind = 'opening'),
    CHECK ((ref_type IS NULL) = (ref_id IS NULL))
);

-- The signed rows. A cell is where · owner · state; no where and no owner is the books.
CREATE TABLE public.movement_legs (
    id                int8 GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    movements_id      int8 NOT NULL REFERENCES public.movements,
    variants_id       int8 NOT NULL REFERENCES public.variants,
    serials_id        int4 REFERENCES public.serials,
    qty               int4 NOT NULL CHECK (qty <> 0),
    at_location_id    int4 REFERENCES public.locations,
    at_transfer_id    int8 REFERENCES public.transfers,
    at_customer_id    int4 REFERENCES public.customers,
    at_supplier_id    int8 REFERENCES public.suppliers,
    owner_location_id int4 REFERENCES public.locations,
    owner_customer_id int4 REFERENCES public.customers,
    owner_supplier_id int8 REFERENCES public.suppliers,
    state             text COLLATE public.ci_ai NOT NULL CHECK (state IN ('validating', 'available', 'written_off')),
    CHECK (serials_id IS NULL OR qty IN (-1, 1)),
    CHECK (num_nonnulls(at_location_id, at_transfer_id, at_customer_id, at_supplier_id) <= 1),
    CHECK (num_nonnulls(owner_location_id, owner_customer_id, owner_supplier_id) <= 1),
    CHECK ((num_nonnulls(at_location_id, at_transfer_id, at_customer_id, at_supplier_id) = 0)
         = (num_nonnulls(owner_location_id, owner_customer_id, owner_supplier_id) = 0))
);
CREATE INDEX movement_legs_unit     ON public.movement_legs (serials_id, id) WHERE serials_id IS NOT NULL;
CREATE INDEX movement_legs_movement ON public.movement_legs (movements_id);
CREATE INDEX movement_legs_road     ON public.movement_legs (at_transfer_id) WHERE at_transfer_id IS NOT NULL;

-- The balance per model and cell, kept by the trigger below. Nobody writes it.
CREATE TABLE public.positions (
    variants_id       int8 NOT NULL,
    at_location_id    int4,
    at_transfer_id    int8,
    at_customer_id    int4,
    at_supplier_id    int8,
    owner_location_id int4,
    owner_customer_id int4,
    owner_supplier_id int8,
    state             text COLLATE public.ci_ai NOT NULL,
    qty               int4 NOT NULL,
    CONSTRAINT positions_cell UNIQUE NULLS NOT DISTINCT (variants_id, at_location_id, at_transfer_id,
        at_customer_id, at_supplier_id, owner_location_id, owner_customer_id, owner_supplier_id, state),
    -- no negative balance at a location, on the road or with a person; the books and a provider's side may (plan §1.3.4)
    CONSTRAINT positions_not_negative CHECK (qty >= 0
        OR num_nonnulls(at_location_id, at_transfer_id, at_customer_id, at_supplier_id) = 0
        OR at_supplier_id IS NOT NULL)
);

CREATE FUNCTION public.movement_legs_position() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    -- update first: INSERT ... ON CONFLICT checks the CHECK on the proposed row (the leg's own qty)
    -- before it sees the existing one, so it could never take a balance down to 0
    UPDATE positions SET qty = qty + NEW.qty
     WHERE variants_id = NEW.variants_id AND state = NEW.state
       AND at_location_id    IS NOT DISTINCT FROM NEW.at_location_id
       AND at_transfer_id    IS NOT DISTINCT FROM NEW.at_transfer_id
       AND at_customer_id    IS NOT DISTINCT FROM NEW.at_customer_id
       AND at_supplier_id    IS NOT DISTINCT FROM NEW.at_supplier_id
       AND owner_location_id IS NOT DISTINCT FROM NEW.owner_location_id
       AND owner_customer_id IS NOT DISTINCT FROM NEW.owner_customer_id
       AND owner_supplier_id IS NOT DISTINCT FROM NEW.owner_supplier_id;
    IF NOT FOUND THEN
        -- a new cell; the event's locks keep two postings from opening it at once
        INSERT INTO positions (variants_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
                               owner_location_id, owner_customer_id, owner_supplier_id, state, qty)
        VALUES (NEW.variants_id, NEW.at_location_id, NEW.at_transfer_id, NEW.at_customer_id, NEW.at_supplier_id,
                NEW.owner_location_id, NEW.owner_customer_id, NEW.owner_supplier_id, NEW.state, NEW.qty);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER movement_legs_position AFTER INSERT ON public.movement_legs
    FOR EACH ROW EXECUTE FUNCTION public.movement_legs_position();

-- Rows are only ever added: a mistake is corrected by a movement.
CREATE FUNCTION public.movements_append_only() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    RAISE EXCEPTION '% only takes new rows: correct a mistake with a movement', TG_TABLE_NAME;
END $$;
CREATE TRIGGER movements_append_only BEFORE UPDATE OR DELETE ON public.movements
    FOR EACH ROW EXECUTE FUNCTION public.movements_append_only();
CREATE TRIGGER movements_no_truncate BEFORE TRUNCATE ON public.movements
    FOR EACH STATEMENT EXECUTE FUNCTION public.movements_append_only();
CREATE TRIGGER movement_legs_append_only BEFORE UPDATE OR DELETE ON public.movement_legs
    FOR EACH ROW EXECUTE FUNCTION public.movements_append_only();
CREATE TRIGGER movement_legs_no_truncate BEFORE TRUNCATE ON public.movement_legs
    FOR EACH STATEMENT EXECUTE FUNCTION public.movements_append_only();

-- A refusal: its code (MV0nn), the operator's Portuguese, and one line of facts PHP reads whole.
-- A refusal: its code, an English message for the log, and its facts. The code is the i18n key
-- (mvRefused_<code>, i18n/movements.js) and the facts are its parameters: no words for people leave here.
CREATE FUNCTION public.mv_refuse(p_code text, p_message text, p_facts jsonb DEFAULT '{}') RETURNS void
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = p_code, MESSAGE = p_message,
        DETAIL = 'mv:' || jsonb_build_object('message', p_message, 'facts', p_facts)::text;
END $$;

-- The session's user: an event without one is refused (app_enter allows an empty app.user).
CREATE FUNCTION public.mv_user() RETURNS int4
    LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v text := NULLIF(current_setting('app.user', true), '');
BEGIN
    IF v IS NULL THEN
        PERFORM mv_refuse('MV001', 'No user in this session: sign in.');
    END IF;
    RETURN v::integer;
END $$;

-- The posting primitive: the one way into the journal. An event function checks its guards, builds its legs, then
-- makes this one call: the movement and its legs go in together, and the legs must balance per model (a movement
-- makes nothing and loses nothing: MV003). Each leg is an object of p_legs: variants_id, serials_id (null for
-- counted goods), qty, and its cell's at_*, owner_* and state; a key left out is null.
CREATE FUNCTION public.mv_post(p_kind text, p_ref_type text, p_ref_id int8, p_legs jsonb, p_note text DEFAULT NULL,
                               p_occurred_at timestamp DEFAULT NULL, p_corrects_id int8 DEFAULT NULL) RETURNS int8
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_movement int8;
BEGIN
    INSERT INTO movements (kind, users_id, ref_type, ref_id, note, occurred_at, corrects_id)
    VALUES (p_kind, mv_user(), p_ref_type, p_ref_id, p_note,
            COALESCE(p_occurred_at, date_trunc('second', LOCALTIMESTAMP)), p_corrects_id)
    RETURNING id INTO v_movement;
    INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty, at_location_id, at_transfer_id, at_customer_id,
                               at_supplier_id, owner_location_id, owner_customer_id, owner_supplier_id, state)
    SELECT v_movement, (e->>'variants_id')::int8, (e->>'serials_id')::int4, (e->>'qty')::int4,
           (e->>'at_location_id')::int4, (e->>'at_transfer_id')::int8, (e->>'at_customer_id')::int4,
           (e->>'at_supplier_id')::int8, (e->>'owner_location_id')::int4, (e->>'owner_customer_id')::int4,
           (e->>'owner_supplier_id')::int8, e->>'state'
      FROM jsonb_array_elements(p_legs) WITH ORDINALITY AS x(e, n)
     ORDER BY n;
    IF EXISTS (SELECT 1 FROM movement_legs WHERE movements_id = v_movement GROUP BY variants_id HAVING SUM(qty) <> 0) THEN
        PERFORM mv_refuse('MV003', 'A movement''s legs must balance per model.', jsonb_build_object('kind', p_kind));
    END IF;
    RETURN v_movement;
END $$;

-- A leg's cell, where · owner · state, as the jsonb a leg is built from: every key present, so a cell can be
-- moved by overwriting some of them (mv_cell(v_cell) || jsonb_build_object('state', 'available')).
CREATE FUNCTION public.mv_cell(p_leg public.movement_legs) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('at_location_id', p_leg.at_location_id, 'at_transfer_id', p_leg.at_transfer_id,
                              'at_customer_id', p_leg.at_customer_id, 'at_supplier_id', p_leg.at_supplier_id,
                              'owner_location_id', p_leg.owner_location_id, 'owner_customer_id', p_leg.owner_customer_id,
                              'owner_supplier_id', p_leg.owner_supplier_id, 'state', p_leg.state)
$$;

-- Two legs: p_qty leaves one cell and enters another.
CREATE FUNCTION public.mv_pair(p_variants_id int8, p_serials_id int4, p_qty int4, p_from jsonb, p_to jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(
        p_from || jsonb_build_object('variants_id', p_variants_id, 'serials_id', p_serials_id, 'qty', -p_qty),
        p_to   || jsonb_build_object('variants_id', p_variants_id, 'serials_id', p_serials_id, 'qty', p_qty))
$$;

-- The leg that put a unit where it is: its last +1 leg. Null when it has none.
CREATE FUNCTION public.mv_unit_leg(p_serials_id int4) RETURNS public.movement_legs
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT * FROM movement_legs WHERE serials_id = p_serials_id AND qty = 1 ORDER BY id DESC LIMIT 1
$$;

-- Event 5, dispatched: (A·A·s) → (r·A·s), the draft's units one by one and the counted lines by quantity.
-- The module has written its documents and set the remessa 'sent', as 009 expects.
CREATE FUNCTION public.movement_dispatch(p_transfers_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_transfer transfers%ROWTYPE;
    v_unit     record;
    v_cell     movement_legs%ROWTYPE;
    v_line     record;
    v_have     int4;
    v_legs     jsonb := '[]';
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id);
BEGIN
    IF NOT app_at_master() THEN
        PERFORM mv_refuse('MV010', 'A transfer leaves from the master.', v_facts);
    END IF;
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF v_transfer.status <> 'sent' THEN
        PERFORM mv_refuse('MV012', format('Transfer %s is %s, not sent.', p_transfers_id, v_transfer.status),
                          v_facts || jsonb_build_object('status', v_transfer.status));
    END IF;
    IF EXISTS (SELECT 1 FROM movement_legs WHERE at_transfer_id = p_transfers_id) THEN
        PERFORM mv_refuse('MV013', format('Transfer %s is already on the road.', p_transfers_id), v_facts);
    END IF;
    IF v_transfer.expected_at IS NULL THEN
        PERFORM mv_refuse('MV018', format('Transfer %s has no expected arrival.', p_transfers_id), v_facts);
    END IF;

    -- the units the draft holds, locked in id order; each leaves the cell its last +1 leg put it in
    FOR v_unit IN SELECT s.id, s.variants_id
                    FROM transfer_units tu JOIN serials s ON s.id = tu.serials_id
                   WHERE tu.transfers_id = p_transfers_id
                   ORDER BY s.id FOR UPDATE OF s LOOP
        v_cell := mv_unit_leg(v_unit.id);
        IF v_cell.id IS NULL OR v_cell.at_location_id IS DISTINCT FROM v_transfer.location_id
                     OR v_cell.owner_location_id IS DISTINCT FROM v_transfer.location_id THEN
            PERFORM mv_refuse('MV014', 'The unit is not in the sender''s stock.',
                              v_facts || jsonb_build_object('serials_id', v_unit.id));
        END IF;
        v_legs := v_legs || mv_pair(v_unit.variants_id, v_unit.id, 1, mv_cell(v_cell),
                                    mv_cell(v_cell) || jsonb_build_object('at_location_id', NULL, 'at_transfer_id', p_transfers_id));
    END LOOP;

    FOR v_line IN SELECT ti.variants_id, SUM(ti.qty)::int4 AS qty, bool_or(i.serial) AS serial, bool_and(i.sellable) AS sellable
                    FROM transfer_items ti
                    JOIN variants v ON v.id = ti.variants_id
                    JOIN items i ON i.id = v.items_id
                   WHERE ti.transfers_id = p_transfers_id
                   GROUP BY ti.variants_id ORDER BY ti.variants_id LOOP
        IF NOT v_line.sellable THEN
            PERFORM mv_refuse('MV015', 'Materials do not move through the ledger.',
                              v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.serial THEN
            -- a bike line leaves only with its units
            IF v_line.qty <> (SELECT count(*) FROM transfer_units tu JOIN serials s ON s.id = tu.serials_id
                               WHERE tu.transfers_id = p_transfers_id AND s.variants_id = v_line.variants_id) THEN
                PERFORM mv_refuse('MV016', 'Every serial-tracked line of the transfer needs its units.',
                                  v_facts || jsonb_build_object('variants_id', v_line.variants_id));
            END IF;
            CONTINUE;
        END IF;
        PERFORM pg_advisory_xact_lock(0, v_line.variants_id::int4);                         -- the road first, as 009
        PERFORM pg_advisory_xact_lock(v_transfer.location_id, v_line.variants_id::int4);
        SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
         WHERE variants_id = v_line.variants_id AND state = 'available'
           AND at_location_id = v_transfer.location_id AND owner_location_id = v_transfer.location_id;
        IF v_have < v_line.qty THEN
            PERFORM mv_refuse('MV017', format('Only %s in stock to send %s.', v_have, v_line.qty),
                              v_facts || jsonb_build_object('variants_id', v_line.variants_id, 'have', v_have, 'want', v_line.qty));
        END IF;
        v_legs := v_legs || mv_pair(v_line.variants_id, NULL, v_line.qty,
                                    jsonb_build_object('at_location_id', v_transfer.location_id,
                                                       'owner_location_id', v_transfer.location_id, 'state', 'available'),
                                    jsonb_build_object('at_transfer_id', p_transfers_id,
                                                       'owner_location_id', v_transfer.location_id, 'state', 'available'));
    END LOOP;

    PERFORM mv_post('dispatched', 'transfers', p_transfers_id, v_legs);
    RETURN jsonb_build_object('legs', jsonb_array_length(v_legs));
END $$;

-- What holds a unit (code §3.3): a live order line, a remessa draft, the rental fleet, each with its document.
-- An order's line holds a unit only while a location owns it: once sold, it is the customer's.
CREATE VIEW public.unit_claims WITH (security_invoker = true) AS
SELECT sa.serials_id, 'order'::text AS kind, 'orders'::text AS ref_type, o.id::int8 AS ref_id
  FROM sales sa JOIN orders o ON o.id = sa.orders_id
 WHERE sa.serials_id IS NOT NULL AND sa.status NOT IN ('cancelled', 'refunded') AND sa.deleted_at IS NULL
   AND o.status NOT IN ('cancelled', 'refunded', 'voided') AND o.deleted_at IS NULL
UNION ALL
SELECT tu.serials_id, 'draft', 'transfers', t.id
  FROM transfer_units tu JOIN transfers t ON t.id = tu.transfers_id
 WHERE t.status = 'draft'
UNION ALL
SELECT r.serials_id, 'fleet', 'resources', r.id
  FROM resources r
 WHERE r.serials_id IS NOT NULL;

-- A unit's claim, if it has one: 'order', 'draft' or 'fleet', in that order.
CREATE FUNCTION public.mv_unit_claim(p_serials_id int4) RETURNS text
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT kind FROM unit_claims WHERE serials_id = p_serials_id
     ORDER BY array_position(ARRAY['order', 'draft', 'fleet'], kind) LIMIT 1
$$;

-- Events 3 and 4, built and back to the bench: the state alone changes, (L·L·validating) ⇄ (L·L·available),
-- where the bike stands and by its assembly job. Back to the bench is refused for a claimed unit (plan §2).
CREATE FUNCTION public.movement_assembly_state(p_serials_id int4, p_assembly_id int8, p_to text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_from     text := CASE p_to WHEN 'available' THEN 'validating' ELSE 'available' END;
    v_cell     movement_legs%ROWTYPE;
    v_claim    text;
    v_facts    jsonb := jsonb_build_object('serials_id', p_serials_id, 'assembly_id', p_assembly_id);
BEGIN
    PERFORM 1 FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', v_facts);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM assembly WHERE id = p_assembly_id AND serials_id = p_serials_id) THEN
        PERFORM mv_refuse('MV021', 'The unit is not this assembly job''s.', v_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    IF v_cell.id IS NULL OR v_cell.at_location_id IS NULL OR v_cell.at_location_id IS DISTINCT FROM v_cell.owner_location_id
       OR v_cell.state <> v_from THEN
        PERFORM mv_refuse(CASE p_to WHEN 'available' THEN 'MV022' ELSE 'MV025' END,
                          CASE p_to WHEN 'available' THEN 'The unit is not on the bench.'
                                    ELSE 'The unit is not in stock to go back to the bench.' END,
                          v_facts || jsonb_build_object('state', v_cell.state));
    END IF;
    IF v_cell.at_location_id <> app_location() THEN
        PERFORM mv_refuse('MV023', 'The unit stands at another location.', v_facts || jsonb_build_object('location_id', v_cell.at_location_id));
    END IF;
    IF p_to = 'validating' THEN
        v_claim := mv_unit_claim(p_serials_id);
        IF v_claim IS NOT NULL THEN
            PERFORM mv_refuse('MV024', 'The unit is held and cannot go back to the bench.', v_facts || jsonb_build_object('claim', v_claim));
        END IF;
    END IF;

    PERFORM mv_post(CASE p_to WHEN 'available' THEN 'built' ELSE 'back_to_bench' END, 'assembly', p_assembly_id,
                    mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell),
                            mv_cell(v_cell) || jsonb_build_object('state', p_to)));
    RETURN jsonb_build_object('state', p_to);
END $$;

CREATE FUNCTION public.movement_built(p_serials_id int4, p_assembly_id int8) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT movement_assembly_state(p_serials_id, p_assembly_id, 'available')
$$;

CREATE FUNCTION public.movement_back_to_bench(p_serials_id int4, p_assembly_id int8) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT movement_assembly_state(p_serials_id, p_assembly_id, 'validating')
$$;

-- Events 1 and 2, received and the receipt corrected down: a supplier's delivery line, to its new total p_total.
-- Received: (p·p) → (L·L·validating) for each unit it mints, (L·L·available) for counted goods; p is the order's
-- supplier, or the books when the order names none. Corrected down: the opposite, of units that are nothing yet (no
-- number, no assembly job, nothing holding them, never sold, still where the receipt put them), the newest first.
-- p_numbers: [{serial_number, observations}] for the new units, in order; the rest are minted without a number.
-- The line's qty_received follows the total here, under the line's lock.
CREATE FUNCTION public.movement_receive(p_line int8, p_total int4, p_numbers jsonb DEFAULT '[]') RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user   int4 := mv_user();   -- an empty session is refused before anything else
    v_line   record;
    v_here   int4;
    v_from   jsonb;
    v_delta  int4;
    v_legs   jsonb := '[]';
    v_units  int4[] := '{}';
    v_unit   int4;
    v_number text;
    v_taken  int4;
    v_have   int4;
    v_facts  jsonb := jsonb_build_object('purchase_items_id', p_line);
BEGIN
    SELECT pi.id, pi.variants_id, pi.qty_received::int4 AS qty_received, p.id AS purchases_id, p.location_id,
           p.suppliers_id, p.status, i.serial, i.sellable
      INTO v_line
      FROM purchase_items pi
      JOIN purchases p ON p.id = pi.purchases_id
      JOIN variants v ON v.id = pi.variants_id
      JOIN items i ON i.id = v.items_id
     WHERE pi.id = p_line
       FOR UPDATE OF pi;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV030', 'Purchase line not found.', v_facts);
    END IF;
    IF EXISTS (SELECT 1 FROM transfers WHERE shop_purchases_id = v_line.purchases_id) THEN
        PERFORM mv_refuse('MV032', 'A transfer''s line arrives; it is not received.', v_facts);
    END IF;
    IF v_line.location_id IS DISTINCT FROM app_location() THEN
        PERFORM mv_refuse('MV031', 'The order is another location''s.', v_facts || jsonb_build_object('location_id', v_line.location_id));
    END IF;
    IF v_line.status = 'cancelled' THEN
        PERFORM mv_refuse('MV033', 'The order is cancelled.', v_facts);
    END IF;
    IF NOT v_line.sellable THEN
        PERFORM mv_refuse('MV015', 'Materials do not move through the ledger.', v_facts || jsonb_build_object('variants_id', v_line.variants_id));
    END IF;
    IF p_total < 0 THEN
        PERFORM mv_refuse('MV034', 'A received total cannot be below zero.', v_facts || jsonb_build_object('total', p_total));
    END IF;

    v_here := v_line.location_id;
    v_from := CASE WHEN v_line.suppliers_id IS NULL THEN jsonb_build_object('state', 'available')
                   ELSE jsonb_build_object('at_supplier_id', v_line.suppliers_id, 'owner_supplier_id', v_line.suppliers_id,
                                           'state', 'available') END;
    v_delta := p_total - v_line.qty_received;
    IF v_delta = 0 THEN
        RETURN jsonb_build_object('received', 0, 'units', '[]'::jsonb);
    END IF;

    IF v_line.serial AND v_delta > 0 THEN
        IF jsonb_array_length(p_numbers) > v_delta THEN
            PERFORM mv_refuse('MV035', format('%s numbers for %s new units.', jsonb_array_length(p_numbers), v_delta),
                              v_facts || jsonb_build_object('numbers', jsonb_array_length(p_numbers), 'units', v_delta));
        END IF;
        FOR i IN 1..v_delta LOOP
            v_number := NULLIF(trim(p_numbers -> (i - 1) ->> 'serial_number'), '');
            IF v_number IS NOT NULL THEN
                SELECT id INTO v_taken FROM serials WHERE serial_number = v_number COLLATE public.ci_ai;
                IF FOUND THEN
                    PERFORM mv_refuse('MV036', 'The number is another unit''s.',
                                      v_facts || jsonb_build_object('serial_number', v_number, 'serials_id', v_taken));
                END IF;
            END IF;
            INSERT INTO serials (variants_id, serial_number, observations, created_at, purchase_items_id, location_id)
            VALUES (v_line.variants_id, v_number, NULLIF(trim(p_numbers -> (i - 1) ->> 'observations'), ''),
                    date_trunc('second', LOCALTIMESTAMP), p_line, v_here)
            RETURNING id INTO v_unit;
            v_units := v_units || v_unit;
            v_legs := v_legs || mv_pair(v_line.variants_id, v_unit, 1, v_from,
                                        jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'validating'));
        END LOOP;
    ELSIF v_line.serial THEN
        SELECT coalesce(array_agg(free.id), '{}') INTO v_units FROM (
            SELECT s.id FROM serials s
             WHERE s.purchase_items_id = p_line AND s.serial_number IS NULL
               AND NOT EXISTS (SELECT 1 FROM assembly a WHERE a.serials_id = s.id)
               AND NOT EXISTS (SELECT 1 FROM unit_claims c WHERE c.serials_id = s.id)
               AND NOT EXISTS (SELECT 1 FROM sales sa WHERE sa.serials_id = s.id)
               AND (SELECT m.kind FROM movement_legs l JOIN movements m ON m.id = l.movements_id
                     WHERE l.serials_id = s.id AND l.qty = 1 ORDER BY l.id DESC LIMIT 1) = 'received'
             ORDER BY s.id DESC LIMIT -v_delta
               FOR UPDATE OF s) free;
        IF cardinality(v_units) < -v_delta THEN
            PERFORM mv_refuse('MV037', 'Units of the line are something already: correct them first.',
                              v_facts || jsonb_build_object('free', cardinality(v_units), 'want', -v_delta));
        END IF;
        FOREACH v_unit IN ARRAY v_units LOOP
            v_legs := v_legs || mv_pair(v_line.variants_id, v_unit, 1, mv_cell(mv_unit_leg(v_unit)), v_from);
        END LOOP;
    ELSE
        PERFORM pg_advisory_xact_lock(v_here, v_line.variants_id::int4);
        IF v_delta < 0 THEN
            SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
             WHERE variants_id = v_line.variants_id AND state = 'available' AND at_location_id = v_here AND owner_location_id = v_here;
            IF v_have < -v_delta THEN
                PERFORM mv_refuse('MV037', format('Only %s in stock to take back %s.', v_have, -v_delta),
                                  v_facts || jsonb_build_object('free', v_have, 'want', -v_delta));
            END IF;
        END IF;
        v_legs := mv_pair(v_line.variants_id, NULL, abs(v_delta),
                          CASE WHEN v_delta > 0 THEN v_from
                               ELSE jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available') END,
                          CASE WHEN v_delta > 0 THEN jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available')
                               ELSE v_from END);
    END IF;

    PERFORM mv_post(CASE WHEN v_delta > 0 THEN 'received' ELSE 'receipt_corrected' END, 'purchase_items', p_line, v_legs);
    UPDATE purchase_items SET qty_received = p_total WHERE id = p_line;
    RETURN jsonb_build_object('received', v_delta, 'units', to_jsonb(v_units));
END $$;

-- Event 6, arrived: (r·A·s) → (B·B·s), a transfer's line received at its destination B, the shop's purchase line
-- p_line. Named units (p_units: the set the shop has) arrive if they are still on the road; with none named, the
-- oldest of the line's model on the road arrive, up to the line's new total p_total. Counted goods arrive by
-- quantity. What arrived does not go back: a shortfall is the divergence the master resolves.
CREATE FUNCTION public.movement_arrive(p_transfers_id int8, p_line int8, p_total int4, p_units jsonb DEFAULT '[]') RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_transfer transfers%ROWTYPE;
    v_line     record;
    v_on_road  int4[];
    v_named    int4[];
    v_arriving int4[] := '{}';
    v_unit     int4;
    v_cell     movement_legs%ROWTYPE;
    v_delta    int4;
    v_have     int4;
    v_legs     jsonb := '[]';
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id, 'purchase_items_id', p_line);
BEGIN
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF v_transfer.to_location_id IS DISTINCT FROM app_location() THEN
        PERFORM mv_refuse('MV040', 'The transfer is addressed to another location.',
                          v_facts || jsonb_build_object('to_location_id', v_transfer.to_location_id));
    END IF;
    SELECT ti.variants_id, pi.qty_received::int4 AS qty_received, i.serial
      INTO v_line
      FROM transfer_items ti
      JOIN purchase_items pi ON pi.id = ti.shop_purchase_items_id
      JOIN variants v ON v.id = ti.variants_id
      JOIN items i ON i.id = v.items_id
     WHERE ti.transfers_id = p_transfers_id AND ti.shop_purchase_items_id = p_line
       FOR UPDATE OF pi;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV041', 'The line is not this transfer''s.', v_facts);
    END IF;

    IF v_line.serial THEN
        -- the line's model on this road, by model and not by delivery line (a swapped chassis may be another
        -- delivery's), locked in id order
        SELECT coalesce(array_agg(u.serials_id ORDER BY u.serials_id), '{}') INTO v_on_road
          FROM (SELECT DISTINCT ON (l.serials_id) l.serials_id, l.at_transfer_id
                  FROM movement_legs l
                 WHERE l.variants_id = v_line.variants_id AND l.qty = 1
                   AND l.serials_id IN (SELECT r.serials_id FROM movement_legs r
                                         WHERE r.at_transfer_id = p_transfers_id AND r.qty = 1 AND r.serials_id IS NOT NULL)
                 ORDER BY l.serials_id, l.id DESC) u
         WHERE u.at_transfer_id = p_transfers_id;
        PERFORM 1 FROM serials WHERE id = ANY (v_on_road) ORDER BY id FOR UPDATE;
        v_named := ARRAY(SELECT jsonb_array_elements_text(p_units)::int4);
        IF cardinality(v_named) > 0 THEN
            v_arriving := ARRAY(SELECT u FROM unnest(v_on_road) u WHERE u = ANY (v_named) ORDER BY u);
        ELSE
            v_delta := p_total - v_line.qty_received;
            IF v_delta < 0 THEN
                PERFORM mv_refuse('MV043', 'What arrived does not go back: record the divergence.', v_facts);
            END IF;
            IF v_delta > cardinality(v_on_road) THEN
                PERFORM mv_refuse('MV042', format('Only %s on the road to receive %s.', cardinality(v_on_road), v_delta),
                                  v_facts || jsonb_build_object('have', cardinality(v_on_road), 'want', v_delta));
            END IF;
            v_arriving := v_on_road[1:v_delta];
        END IF;
        v_delta := cardinality(v_arriving);
        FOREACH v_unit IN ARRAY v_arriving LOOP
            v_cell := mv_unit_leg(v_unit);
            v_legs := v_legs || mv_pair(v_line.variants_id, v_unit, 1, mv_cell(v_cell),
                                        jsonb_build_object('at_location_id', v_transfer.to_location_id,
                                                           'owner_location_id', v_transfer.to_location_id, 'state', v_cell.state));
        END LOOP;
    ELSE
        v_delta := p_total - v_line.qty_received;
        IF v_delta < 0 THEN
            PERFORM mv_refuse('MV043', 'What arrived does not go back: record the divergence.', v_facts);
        END IF;
        PERFORM pg_advisory_xact_lock(0, v_line.variants_id::int4);                         -- the road first, as 009
        PERFORM pg_advisory_xact_lock(v_transfer.to_location_id, v_line.variants_id::int4);
        SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
         WHERE variants_id = v_line.variants_id AND at_transfer_id = p_transfers_id AND state = 'available';
        IF v_delta > v_have THEN
            PERFORM mv_refuse('MV042', format('Only %s on the road to receive %s.', v_have, v_delta),
                              v_facts || jsonb_build_object('have', v_have, 'want', v_delta));
        END IF;
        IF v_delta > 0 THEN
            v_legs := mv_pair(v_line.variants_id, NULL, v_delta,
                              jsonb_build_object('at_transfer_id', p_transfers_id, 'owner_location_id', v_transfer.location_id, 'state', 'available'),
                              jsonb_build_object('at_location_id', v_transfer.to_location_id,
                                                 'owner_location_id', v_transfer.to_location_id, 'state', 'available'));
        END IF;
    END IF;

    IF v_delta > 0 THEN
        PERFORM mv_post('arrived', 'transfers', p_transfers_id, v_legs);
        UPDATE purchase_items SET qty_received = qty_received + v_delta WHERE id = p_line;
    END IF;
    RETURN jsonb_build_object('arrived', v_delta, 'units', to_jsonb(v_arriving),
                              'on_road', (SELECT COALESCE(SUM(qty), 0) FROM positions WHERE at_transfer_id = p_transfers_id));
END $$;

-- What a unit or a model cost a location, from its receipt there: a remessa's price if it arrived by remessa, else
-- its purchase line's landed cost (the invoice cost while the landing is not computed). Counted goods: the latest
-- receipt or arrival of the model at the location. A unit from before the layer: its purchase line.
CREATE FUNCTION public.mv_cost(p_variants_id int8, p_serials_id int4, p_location int4) RETURNS numeric
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT price FROM (
        SELECT CASE WHEN m.kind = 'arrived' THEN ti.unit_price
                    ELSE COALESCE(NULLIF(pi.landed_unit_cost, 0), pi.unit_cost) END AS price, m.occurred_at AS at, l.id
          FROM movement_legs l
          JOIN movements m ON m.id = l.movements_id AND m.kind IN ('received', 'arrived')
          LEFT JOIN transfer_items ti ON m.kind = 'arrived' AND ti.transfers_id = m.ref_id AND ti.variants_id = l.variants_id
          LEFT JOIN purchase_items pi ON m.kind = 'received' AND pi.id = m.ref_id
         WHERE l.qty > 0 AND l.at_location_id = p_location AND l.variants_id = p_variants_id
           AND (p_serials_id IS NULL OR l.serials_id = p_serials_id)
        UNION ALL
        SELECT COALESCE(NULLIF(pi.landed_unit_cost, 0), pi.unit_cost), NULL, NULL
          FROM serials s JOIN purchase_items pi ON pi.id = s.purchase_items_id
         WHERE s.id = p_serials_id) c
     ORDER BY at DESC NULLS LAST, id DESC NULLS LAST
     LIMIT 1
$$;

-- Whether an order line is sold now: its last sale or undoing is a sale. A return gives goods back; it does not
-- undo the line.
CREATE FUNCTION public.mv_line_sold(p_sales_id int8) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT COALESCE((SELECT kind = 'sold' FROM movements
                      WHERE ref_type = 'sales' AND ref_id = p_sales_id AND kind IN ('sold', 'sale_undone')
                      ORDER BY id DESC LIMIT 1), false)
$$;

-- What a counted line has out of its location now: sold, less what came back.
CREATE FUNCTION public.mv_line_out(p_sales_id int8, p_location int4) RETURNS int4
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT COALESCE(-SUM(l.qty), 0)::int4
      FROM movements m JOIN movement_legs l ON l.movements_id = m.id
     WHERE m.ref_type = 'sales' AND m.ref_id = p_sales_id AND m.kind IN ('sold', 'returned', 'sale_undone')
       AND l.at_location_id = p_location AND l.owner_location_id = p_location
$$;

-- An order as the sale path reads it, locked, with its guards: found (MV050), at the session's location or the
-- master's (MV052), and, unless p_any, paid in full and alive (MV051).
CREATE FUNCTION public.mv_order(p_orders_id int8, p_paid boolean DEFAULT true) RETURNS public.orders
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_order orders%ROWTYPE;
    v_facts jsonb := jsonb_build_object('orders_id', p_orders_id);
BEGIN
    SELECT * INTO v_order FROM orders WHERE id = p_orders_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV050', 'Order not found.', v_facts);
    END IF;
    IF NOT (app_at_master() OR app_location() = v_order.location_id) THEN
        PERFORM mv_refuse('MV052', 'The order is another location''s.', v_facts || jsonb_build_object('location_id', v_order.location_id));
    END IF;
    IF p_paid AND (v_order.paid IS NOT TRUE OR v_order.status IN ('cancelled', 'refunded', 'voided') OR v_order.deleted_at IS NOT NULL) THEN
        PERFORM mv_refuse('MV051', 'The order is not paid in full.', v_facts);
    END IF;
    RETURN v_order;
END $$;

-- Event 11, sold: (L·L·available) → (L·c·available) for each line of a paid order that has its unit, c the order's
-- customer; counted goods leave to the books (they are not followed into the customer's hands). A bike becomes the
-- customer's when its line is paid in full and its unit attached, whichever comes last: so this runs when the order
-- is paid and again after a late attach, and sells only what is not sold yet. It stamps each line's cost
-- (sales.unit_cost). A line without its unit waits: it is answered in `waiting`.
CREATE FUNCTION public.movement_sell(p_orders_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user    int4 := mv_user();   -- an empty session is refused before anything else
    v_order   orders%ROWTYPE := mv_order(p_orders_id);
    v_here    int4 := v_order.location_id;
    v_line    record;
    v_cell    movement_legs%ROWTYPE;
    v_have    int4;
    v_sold    int8[] := '{}';
    v_waiting int8[] := '{}';
    v_facts   jsonb := jsonb_build_object('orders_id', p_orders_id);
BEGIN
    FOR v_line IN SELECT sa.id, sa.variants_id, sa.serials_id, sa.quantity::int4 AS qty, i.serial, i.sellable
                    FROM sales sa JOIN variants v ON v.id = sa.variants_id JOIN items i ON i.id = v.items_id
                   WHERE sa.orders_id = p_orders_id AND sa.deleted_at IS NULL AND sa.status NOT IN ('cancelled', 'refunded')
                   ORDER BY sa.id FOR UPDATE OF sa LOOP
        CONTINUE WHEN mv_line_sold(v_line.id);
        IF NOT v_line.sellable THEN
            PERFORM mv_refuse('MV015', 'Materials do not move through the ledger.', v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.serial THEN
            IF v_line.serials_id IS NULL THEN
                v_waiting := v_waiting || v_line.id;
                CONTINUE;
            END IF;
            IF v_order.customers_id IS NULL THEN
                PERFORM mv_refuse('MV053', 'A bike is sold to a customer: the order names none.', v_facts || jsonb_build_object('sales_id', v_line.id));
            END IF;
            PERFORM 1 FROM serials WHERE id = v_line.serials_id FOR UPDATE;
            v_cell := mv_unit_leg(v_line.serials_id);
            IF v_cell.id IS NULL OR v_cell.at_location_id IS DISTINCT FROM v_here OR v_cell.owner_location_id IS DISTINCT FROM v_here
               OR v_cell.state <> 'available' THEN
                PERFORM mv_refuse('MV054', 'The unit is not available where the order is.',
                                  v_facts || jsonb_build_object('serials_id', v_line.serials_id, 'state', v_cell.state));
            END IF;
            IF EXISTS (SELECT 1 FROM unit_claims c WHERE c.serials_id = v_line.serials_id
                          AND NOT (c.kind = 'order' AND c.ref_id = p_orders_id)) THEN
                PERFORM mv_refuse('MV055', 'The unit is held by something else.',
                                  v_facts || jsonb_build_object('serials_id', v_line.serials_id, 'claim', mv_unit_claim(v_line.serials_id)));
            END IF;
            PERFORM mv_post('sold', 'sales', v_line.id,
                            mv_pair(v_line.variants_id, v_line.serials_id, 1, mv_cell(v_cell),
                                    mv_cell(v_cell) || jsonb_build_object('owner_location_id', NULL, 'owner_customer_id', v_order.customers_id)));
        ELSE
            PERFORM pg_advisory_xact_lock(v_here, v_line.variants_id::int4);
            SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
             WHERE variants_id = v_line.variants_id AND state = 'available' AND at_location_id = v_here AND owner_location_id = v_here;
            IF v_have < v_line.qty THEN
                PERFORM mv_refuse('MV056', format('Only %s in stock to sell %s.', v_have, v_line.qty),
                                  v_facts || jsonb_build_object('variants_id', v_line.variants_id, 'have', v_have, 'want', v_line.qty));
            END IF;
            PERFORM mv_post('sold', 'sales', v_line.id,
                            mv_pair(v_line.variants_id, NULL, v_line.qty,
                                    jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available'),
                                    jsonb_build_object('state', 'available')));
        END IF;
        UPDATE sales SET unit_cost = mv_cost(v_line.variants_id, v_line.serials_id, v_here) WHERE id = v_line.id;
        v_sold := v_sold || v_line.id;
    END LOOP;
    RETURN jsonb_build_object('sold', to_jsonb(v_sold), 'waiting', to_jsonb(v_waiting));
END $$;

-- Event 12, handed over: (L·c·s) → (c·c·s), every sold unit of a paid order, at the counter or sent to the customer.
-- No handover while a bike line of the order has no unit (MV057). Counted goods left at the sale.
CREATE FUNCTION public.movement_hand_over(p_orders_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user   int4 := mv_user();   -- an empty session is refused before anything else
    v_order  orders%ROWTYPE := mv_order(p_orders_id);
    v_line   record;
    v_cell   movement_legs%ROWTYPE;
    v_done   int8[] := '{}';
    v_facts  jsonb := jsonb_build_object('orders_id', p_orders_id);
BEGIN
    FOR v_line IN SELECT sa.id, sa.variants_id, sa.serials_id
                    FROM sales sa JOIN variants v ON v.id = sa.variants_id JOIN items i ON i.id = v.items_id
                   WHERE sa.orders_id = p_orders_id AND sa.deleted_at IS NULL AND sa.status NOT IN ('cancelled', 'refunded')
                     AND i.serial
                   ORDER BY sa.id FOR UPDATE OF sa LOOP
        IF v_line.serials_id IS NULL THEN
            PERFORM mv_refuse('MV057', 'A bike line has no unit: no handover without it.', v_facts || jsonb_build_object('sales_id', v_line.id));
        END IF;
        PERFORM 1 FROM serials WHERE id = v_line.serials_id FOR UPDATE;
        v_cell := mv_unit_leg(v_line.serials_id);
        CONTINUE WHEN v_cell.at_customer_id IS NOT NULL AND v_cell.at_customer_id = v_order.customers_id;   -- with them already
        IF NOT mv_line_sold(v_line.id) OR v_cell.at_location_id IS NULL OR v_cell.owner_customer_id IS DISTINCT FROM v_order.customers_id THEN
            PERFORM mv_refuse('MV058', 'The unit is not sold on this order.', v_facts || jsonb_build_object('sales_id', v_line.id, 'serials_id', v_line.serials_id));
        END IF;
        PERFORM mv_post('handed_over', 'sales', v_line.id,
                        mv_pair(v_line.variants_id, v_line.serials_id, 1, mv_cell(v_cell),
                                mv_cell(v_cell) || jsonb_build_object('at_location_id', NULL, 'at_customer_id', v_order.customers_id)));
        v_done := v_done || v_line.id;
    END LOOP;
    RETURN jsonb_build_object('handed_over', to_jsonb(v_done));
END $$;

-- An order line as undoing and returning read it, locked: found (MV059), its order's guards (mv_order, paid or not).
CREATE FUNCTION public.mv_order_line(p_sales_id int8) RETURNS record
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_line record;
BEGIN
    SELECT sa.id, sa.orders_id, sa.variants_id, sa.serials_id, sa.quantity::int4 AS qty, i.serial
      INTO v_line
      FROM sales sa JOIN variants v ON v.id = sa.variants_id JOIN items i ON i.id = v.items_id
     WHERE sa.id = p_sales_id
       FOR UPDATE OF sa;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV059', 'Order line not found.', jsonb_build_object('sales_id', p_sales_id));
    END IF;
    RETURN v_line;
END $$;

-- Event 13, the sale undone (a void, a cancel, a refund before the handover): the opposite of 11, for one line.
-- A handed-over unit is returned instead (MV061). p_why: the reason, as the module words it.
CREATE FUNCTION public.movement_unsell(p_sales_id int8, p_why text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user  int4 := mv_user();   -- an empty session is refused before anything else
    v_line  record := mv_order_line(p_sales_id);
    v_order orders%ROWTYPE := mv_order(v_line.orders_id, false);
    v_here  int4 := v_order.location_id;
    v_cell  movement_legs%ROWTYPE;
    v_out   int4;
    v_facts jsonb := jsonb_build_object('sales_id', p_sales_id);
BEGIN
    IF NOT mv_line_sold(p_sales_id) THEN
        PERFORM mv_refuse('MV060', 'The line is not sold.', v_facts);
    END IF;
    IF v_line.serial THEN
        PERFORM 1 FROM serials WHERE id = v_line.serials_id FOR UPDATE;
        v_cell := mv_unit_leg(v_line.serials_id);
        IF v_cell.at_location_id IS NULL THEN
            PERFORM mv_refuse('MV061', 'Handed over: it is returned, not undone.', v_facts || jsonb_build_object('serials_id', v_line.serials_id));
        END IF;
        PERFORM mv_post('sale_undone', 'sales', p_sales_id,
                        mv_pair(v_line.variants_id, v_line.serials_id, 1, mv_cell(v_cell),
                                mv_cell(v_cell) || jsonb_build_object('owner_customer_id', NULL, 'owner_location_id', v_here)), p_why);
        RETURN jsonb_build_object('undone', 1);
    END IF;
    PERFORM pg_advisory_xact_lock(v_here, v_line.variants_id::int4);
    v_out := mv_line_out(p_sales_id, v_here);
    IF v_out > 0 THEN
        PERFORM mv_post('sale_undone', 'sales', p_sales_id,
                        mv_pair(v_line.variants_id, NULL, v_out, jsonb_build_object('state', 'available'),
                                jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available')), p_why);
    ELSE
        PERFORM mv_post('sale_undone', 'sales', p_sales_id, '[]', p_why);
    END IF;
    RETURN jsonb_build_object('undone', v_out);
END $$;

-- Event 14, returned (after the handover): (c·c·s) → (L·L·available), from the order's customer only (MV063), at
-- the order's location. Counted goods: up to what the line has out (MV062). p_why: the reason, as the module words it.
CREATE FUNCTION public.movement_return(p_sales_id int8, p_qty int4 DEFAULT 1, p_why text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user  int4 := mv_user();   -- an empty session is refused before anything else
    v_line  record := mv_order_line(p_sales_id);
    v_order orders%ROWTYPE := mv_order(v_line.orders_id, false);
    v_here  int4 := v_order.location_id;
    v_cell  movement_legs%ROWTYPE;
    v_out   int4;
    v_facts jsonb := jsonb_build_object('sales_id', p_sales_id);
BEGIN
    IF v_line.serial THEN
        PERFORM 1 FROM serials WHERE id = v_line.serials_id FOR UPDATE;
        v_cell := mv_unit_leg(v_line.serials_id);
        IF v_cell.id IS NULL OR v_cell.at_customer_id IS DISTINCT FROM v_order.customers_id
           OR v_cell.owner_customer_id IS DISTINCT FROM v_order.customers_id THEN
            PERFORM mv_refuse('MV063', 'The unit is not with the order''s customer.', v_facts || jsonb_build_object('serials_id', v_line.serials_id));
        END IF;
        PERFORM mv_post('returned', 'sales', p_sales_id,
                        mv_pair(v_line.variants_id, v_line.serials_id, 1, mv_cell(v_cell),
                                jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available')), p_why);
        RETURN jsonb_build_object('returned', 1);
    END IF;
    PERFORM pg_advisory_xact_lock(v_here, v_line.variants_id::int4);
    v_out := mv_line_out(p_sales_id, v_here);
    IF p_qty < 1 OR p_qty > v_out THEN
        PERFORM mv_refuse('MV062', format('%s back of %s out.', p_qty, v_out), v_facts || jsonb_build_object('want', p_qty, 'out', v_out));
    END IF;
    PERFORM mv_post('returned', 'sales', p_sales_id,
                    mv_pair(v_line.variants_id, NULL, p_qty, jsonb_build_object('state', 'available'),
                            jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available')), p_why);
    RETURN jsonb_build_object('returned', p_qty);
END $$;

-- The unit's position on the layer: where, whose, its state and since when.
CREATE VIEW public.unit_positions WITH (security_invoker = true) AS
SELECT DISTINCT ON (l.serials_id)
       l.serials_id, s.serial_number, l.variants_id, v.sku,
       CASE WHEN l.at_location_id IS NOT NULL THEN 'location'
            WHEN l.at_transfer_id IS NOT NULL THEN 'road'
            WHEN l.at_customer_id IS NOT NULL THEN 'customer'
            WHEN l.at_supplier_id IS NOT NULL THEN 'supplier' END AS place_kind,
       l.at_location_id AS location_id, l.at_transfer_id AS transfers_id,
       l.at_customer_id AS customers_id, l.at_supplier_id AS suppliers_id,
       l.owner_location_id, l.owner_customer_id, l.state, m.occurred_at AS since
  FROM movement_legs l
  JOIN movements m ON m.id = l.movements_id
  JOIN serials s ON s.id = l.serials_id
  JOIN variants v ON v.id = l.variants_id
 WHERE l.serials_id IS NOT NULL AND l.qty = 1
 ORDER BY l.serials_id, l.id DESC;

-- What a location owns standing there, validating or available (code §2).
CREATE VIEW public.stock_on_hand WITH (security_invoker = true) AS
SELECT at_location_id AS location_id, variants_id, SUM(qty)::int4 AS qty
  FROM positions
 WHERE at_location_id = owner_location_id AND state IN ('validating', 'available')
 GROUP BY at_location_id, variants_id;

-- Per location and model: available, owned and standing there, minus the units claimed (an order line,
-- a remessa draft, the fleet), minus the paid bike lines still waiting for a unit (rule §0.3).
-- A line is live when neither it nor its order is cancelled, refunded, voided or deleted.
CREATE VIEW public.stock_sellable WITH (security_invoker = true) AS
WITH live_lines AS (
    SELECT sa.serials_id, sa.location_id, sa.variants_id, sa.items_id, sa.quantity, o.paid
      FROM sales sa JOIN orders o ON o.id = sa.orders_id
     WHERE sa.status NOT IN ('cancelled', 'refunded') AND sa.deleted_at IS NULL
       AND o.status NOT IN ('cancelled', 'refunded', 'voided') AND o.deleted_at IS NULL AND o.deleted IS NOT TRUE),
claimed AS (
    SELECT up.location_id, up.variants_id, count(*)::int4 AS n
      FROM unit_positions up
     WHERE up.place_kind = 'location' AND up.owner_location_id = up.location_id AND up.state = 'available'
       AND (EXISTS (SELECT 1 FROM live_lines l WHERE l.serials_id = up.serials_id)
         OR EXISTS (SELECT 1 FROM transfer_units tu JOIN transfers t ON t.id = tu.transfers_id
                     WHERE tu.serials_id = up.serials_id AND t.status = 'draft')
         OR EXISTS (SELECT 1 FROM resources r WHERE r.serials_id = up.serials_id))
     GROUP BY up.location_id, up.variants_id),
waiting AS (
    SELECT l.location_id, l.variants_id, SUM(l.quantity)::int4 AS n
      FROM live_lines l JOIN items i ON i.id = l.items_id
     WHERE i.serial AND l.paid AND l.serials_id IS NULL
     GROUP BY l.location_id, l.variants_id)
SELECT p.at_location_id AS location_id, p.variants_id,
       (SUM(p.qty) - COALESCE(MAX(c.n), 0) - COALESCE(MAX(w.n), 0))::int4 AS qty
  FROM positions p
  LEFT JOIN claimed c ON c.location_id = p.at_location_id AND c.variants_id = p.variants_id
  LEFT JOIN waiting w ON w.location_id = p.at_location_id AND w.variants_id = p.variants_id
 WHERE p.at_location_id = p.owner_location_id AND p.state = 'available'
 GROUP BY p.at_location_id, p.variants_id;

-- What a location owns standing elsewhere: on the road, with a customer on rental or a loan (code §2).
CREATE VIEW public.owned_elsewhere WITH (security_invoker = true) AS
SELECT owner_location_id AS location_id, variants_id,
       CASE WHEN at_transfer_id IS NOT NULL THEN 'road' WHEN at_customer_id IS NOT NULL THEN 'customer'
            ELSE 'location' END AS place_kind,
       at_location_id, at_transfer_id AS transfers_id, at_customer_id AS customers_id, SUM(qty)::int4 AS qty
  FROM positions
 WHERE owner_location_id IS NOT NULL AND at_location_id IS DISTINCT FROM owner_location_id AND state <> 'written_off'
 GROUP BY 1, 2, 3, 4, 5, 6
HAVING SUM(qty) <> 0;

-- Per remessa and model: what is on its road right now (code §2; per unit, read unit_positions).
CREATE VIEW public.road_by_transfer WITH (security_invoker = true) AS
SELECT at_transfer_id AS transfers_id, owner_location_id AS from_location_id, variants_id, state, SUM(qty)::int4 AS qty
  FROM positions
 WHERE at_transfer_id IS NOT NULL
 GROUP BY 1, 2, 3, 4
HAVING SUM(qty) <> 0;

-- The organisation's total per model: everything its locations own, wherever it stands (itemsedit; replaces variants.stock).
CREATE VIEW public.stock_total WITH (security_invoker = true) AS
SELECT variants_id, SUM(qty)::int4 AS qty
  FROM positions
 WHERE owner_location_id IS NOT NULL AND state <> 'written_off'
 GROUP BY variants_id;

-- The time axis (the draft's f_stock_at / f_serial_at): stock_on_hand and a unit's position as they stood at a moment.
CREATE FUNCTION public.stock_at(p_at timestamp) RETURNS TABLE (location_id int4, variants_id int8, qty int4)
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT l.at_location_id, l.variants_id, SUM(l.qty)::int4
      FROM movement_legs l JOIN movements m ON m.id = l.movements_id
     WHERE m.occurred_at <= p_at AND l.at_location_id = l.owner_location_id AND l.state IN ('validating', 'available')
     GROUP BY l.at_location_id, l.variants_id
    HAVING SUM(l.qty) <> 0
$$;

CREATE FUNCTION public.unit_at(p_serial int4, p_at timestamp) RETURNS SETOF public.movement_legs
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT l.* FROM movement_legs l JOIN movements m ON m.id = l.movements_id
     WHERE l.serials_id = p_serial AND l.qty = 1 AND m.occurred_at <= p_at
     ORDER BY m.occurred_at DESC, l.id DESC LIMIT 1
$$;

-- The health checks (the draft's v_recon_*): each must answer nothing. Anything found is fixed by a movement.
-- An event balances per model and unit.
CREATE VIEW public.movement_check_balance AS
SELECT movements_id, variants_id, serials_id, SUM(qty) AS net
  FROM movement_legs GROUP BY movements_id, variants_id, serials_id HAVING SUM(qty) <> 0;

-- A unit is one chain: each −1 leaves the cell the unit's previous +1 put it in. The first comes from outside: the
-- books (the opening), its supplier (a receipt) or a customer (a trade-in); never from a location or a road.
CREATE VIEW public.movement_check_chain AS
SELECT o.id AS leg_id, o.serials_id, prev.id AS previous_leg_id
  FROM movement_legs o
  LEFT JOIN LATERAL (SELECT i.* FROM movement_legs i
                      WHERE i.serials_id = o.serials_id AND i.qty = 1 AND i.id < o.id
                      ORDER BY i.id DESC LIMIT 1) prev ON true
 WHERE o.serials_id IS NOT NULL AND o.qty = -1
   AND CASE WHEN prev.id IS NULL
            THEN num_nonnulls(o.at_location_id, o.at_transfer_id) > 0
            ELSE (o.at_location_id, o.at_transfer_id, o.at_customer_id, o.at_supplier_id,
                  o.owner_location_id, o.owner_customer_id, o.owner_supplier_id, o.state)
                 IS DISTINCT FROM
                 (prev.at_location_id, prev.at_transfer_id, prev.at_customer_id, prev.at_supplier_id,
                  prev.owner_location_id, prev.owner_customer_id, prev.owner_supplier_id, prev.state) END;

-- positions is the fold of the legs, cell by cell.
CREATE VIEW public.movement_check_positions AS
SELECT variants_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
       owner_location_id, owner_customer_id, owner_supplier_id, state, SUM(q) AS drift
  FROM (SELECT variants_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
               owner_location_id, owner_customer_id, owner_supplier_id, state, qty AS q FROM movement_legs
        UNION ALL
        SELECT variants_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
               owner_location_id, owner_customer_id, owner_supplier_id, state, -qty FROM positions) x
 GROUP BY variants_id, at_location_id, at_transfer_id, at_customer_id, at_supplier_id,
          owner_location_id, owner_customer_id, owner_supplier_id, state
HAVING SUM(q) <> 0;

-- A serial-tracked model moves unit by unit, a counted one by quantity, and a unit as its own model
-- (the draft's v_recon_serialized_bulk_mix).
CREATE VIEW public.movement_check_serial_mix AS
SELECT l.id AS leg_id, l.variants_id, l.serials_id
  FROM movement_legs l
  JOIN variants v ON v.id = l.variants_id JOIN items i ON i.id = v.items_id
  LEFT JOIN serials s ON s.id = l.serials_id
 WHERE (i.serial AND l.serials_id IS NULL) OR (NOT i.serial AND l.serials_id IS NOT NULL)
    OR s.variants_id IS DISTINCT FROM CASE WHEN l.serials_id IS NULL THEN NULL ELSE l.variants_id END;

-- Nothing stays on the road of a remessa that is not on its way.
CREATE VIEW public.movement_check_roads AS
SELECT p.at_transfer_id AS transfers_id, t.status, p.variants_id, p.qty
  FROM positions p JOIN transfers t ON t.id = p.at_transfer_id
 WHERE p.qty <> 0 AND t.status <> 'sent';

-- RLS in the house's way (code §3.1): forced, with policies for app_staff and app_portal. The master reads all;
-- a shop reads where it is the place or the owner, and the road of a remessa from or to it (transfers' own
-- policies decide which remessas those are); the portal reads its own units, through a definer function.
ALTER TABLE public.movements      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movements      FORCE ROW LEVEL SECURITY;
ALTER TABLE public.movement_legs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movement_legs  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.positions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.positions      FORCE ROW LEVEL SECURITY;
ALTER TABLE public.transfer_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfer_units FORCE ROW LEVEL SECURITY;

CREATE POLICY movement_legs_read ON public.movement_legs FOR SELECT TO app_staff USING (
    (SELECT app_at_master())
    OR at_location_id = (SELECT app_location()) OR owner_location_id = (SELECT app_location())
    OR at_transfer_id IN (SELECT t.id FROM transfers t));
CREATE POLICY positions_read ON public.positions FOR SELECT TO app_staff USING (
    (SELECT app_at_master())
    OR at_location_id = (SELECT app_location()) OR owner_location_id = (SELECT app_location())
    OR at_transfer_id IN (SELECT t.id FROM transfers t));
CREATE POLICY movements_read ON public.movements FOR SELECT TO app_staff USING (
    (SELECT app_at_master()) OR EXISTS (SELECT 1 FROM movement_legs l WHERE l.movements_id = movements.id));
CREATE POLICY transfer_units_read ON public.transfer_units FOR SELECT TO app_staff USING (
    transfers_id IN (SELECT t.id FROM transfers t));

CREATE FUNCTION public.mv_portal_units() RETURNS SETOF int4
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT DISTINCT serials_id FROM movement_legs WHERE owner_customer_id = app_customer() AND serials_id IS NOT NULL
$$;
CREATE POLICY movement_legs_portal ON public.movement_legs FOR SELECT TO app_portal USING (
    serials_id IN (SELECT mv_portal_units()));
CREATE POLICY movements_portal ON public.movements FOR SELECT TO app_portal USING (
    EXISTS (SELECT 1 FROM movement_legs l WHERE l.movements_id = movements.id));

-- Grants: the application reads, and posts only through the functions (code §3.1).
REVOKE ALL ON public.movements, public.movement_legs, public.positions, public.transfer_units FROM PUBLIC;
GRANT SELECT ON public.movements, public.movement_legs, public.positions, public.transfer_units, public.unit_positions,
      public.stock_on_hand, public.stock_sellable, public.owned_elsewhere, public.road_by_transfer, public.stock_total,
      public.movement_check_balance, public.movement_check_chain, public.movement_check_positions,
      public.movement_check_serial_mix, public.movement_check_roads, public.unit_claims TO app_staff;
REVOKE EXECUTE ON FUNCTION public.movement_dispatch(int8), public.mv_portal_units(), public.mv_post(text, text, int8, jsonb, text, timestamp, int8),
       public.movement_assembly_state(int4, int8, text), public.movement_built(int4, int8), public.movement_back_to_bench(int4, int8),
       public.movement_receive(int8, int4, jsonb), public.movement_arrive(int8, int8, int4, jsonb),
       public.movement_sell(int8), public.movement_hand_over(int8), public.movement_unsell(int8, text), public.movement_return(int8, int4, text) FROM PUBLIC;
GRANT SELECT ON public.movements, public.movement_legs TO app_portal;
GRANT EXECUTE ON FUNCTION public.mv_portal_units() TO app_portal;
GRANT EXECUTE ON FUNCTION public.movement_dispatch(int8), public.movement_built(int4, int8), public.movement_back_to_bench(int4, int8),
      public.movement_receive(int8, int4, jsonb), public.movement_arrive(int8, int8, int4, jsonb),
      public.movement_sell(int8), public.movement_hand_over(int8), public.movement_unsell(int8, text), public.movement_return(int8, int4, text) TO app_staff;
