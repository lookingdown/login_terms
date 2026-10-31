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

-- A loan names its customer (code §3.2, migration 026): a bike in someone's hands is with a customer. Null on the
-- loans written before it; movement_loan_out refuses a loan without one (MV146).
ALTER TABLE public.loans ADD COLUMN IF NOT EXISTS customers_id int4 REFERENCES public.customers;

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
    reason      text CHECK (reason ~ '^[a-z_]+$'),   -- a key, i18n reason_<key>: an adjustment's why, who bears a loss
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
                               p_occurred_at timestamp DEFAULT NULL, p_corrects_id int8 DEFAULT NULL, p_reason text DEFAULT NULL) RETURNS int8
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_movement int8;
BEGIN
    INSERT INTO movements (kind, users_id, ref_type, ref_id, note, occurred_at, corrects_id, reason)
    VALUES (p_kind, mv_user(), p_ref_type, p_ref_id, p_note,
            COALESCE(p_occurred_at, date_trunc('second', LOCALTIMESTAMP)), p_corrects_id, p_reason)
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
          FROM (SELECT DISTINCT ON (l.serials_id) l.serials_id, l.at_transfer_id, l.state
                  FROM movement_legs l
                 WHERE l.variants_id = v_line.variants_id AND l.qty = 1
                   AND l.serials_id IN (SELECT r.serials_id FROM movement_legs r
                                         WHERE r.at_transfer_id = p_transfers_id AND r.qty = 1 AND r.serials_id IS NOT NULL)
                 ORDER BY l.serials_id, l.id DESC) u
         WHERE u.at_transfer_id = p_transfers_id AND u.state <> 'written_off';
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
    RETURN jsonb_build_object('arrived', v_delta, 'units', to_jsonb(v_arriving), 'on_road', mv_on_road(p_transfers_id));
END $$;

-- What a remessa still carries on its road: what is lost there (written off on the road) is not carried.
CREATE FUNCTION public.mv_on_road(p_transfers_id int8) RETURNS int4
    LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT COALESCE(SUM(qty), 0)::int4 FROM positions WHERE at_transfer_id = p_transfers_id AND state <> 'written_off'
$$;

-- Events 7 and 8, taken off the road: not sent, (r·A·s) → (A·A·s), back at the origin; or lost on the road,
-- (r·A·s) → (r·A·written_off), with who bears it, the origin or the carrier, as its reason. A serial-tracked model
-- by its named units, counted goods by quantity. The master's (MV070).
CREATE FUNCTION public.mv_take_off(p_transfers_id int8, p_variants_id int8, p_qty int4, p_units jsonb, p_lost boolean,
                                   p_bears text, p_note text) RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_transfer transfers%ROWTYPE;
    v_serial   boolean;
    v_units    int4[] := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_units, '[]'))::int4 ORDER BY 1);
    v_unit     int4;
    v_cell     movement_legs%ROWTYPE;
    v_have     int4;
    v_legs     jsonb := '[]';
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id, 'variants_id', p_variants_id);
BEGIN
    IF NOT app_at_master() THEN
        PERFORM mv_refuse('MV070', 'Only the master corrects a transfer.', v_facts);
    END IF;
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF v_transfer.status <> 'sent' THEN
        PERFORM mv_refuse('MV012', format('Transfer %s is %s, not sent.', p_transfers_id, v_transfer.status),
                          v_facts || jsonb_build_object('status', v_transfer.status));
    END IF;
    IF p_lost AND p_bears IS DISTINCT FROM 'origin' AND p_bears IS DISTINCT FROM 'carrier' THEN
        PERFORM mv_refuse('MV074', 'Say who bears the loss: the origin or the carrier.', v_facts);
    END IF;
    SELECT i.serial INTO v_serial FROM variants v JOIN items i ON i.id = v.items_id WHERE v.id = p_variants_id;

    IF v_serial THEN
        IF cardinality(v_units) = 0 THEN
            PERFORM mv_refuse('MV073', 'Name the units of a serial-tracked model.', v_facts);
        END IF;
        PERFORM 1 FROM serials WHERE id = ANY (v_units) ORDER BY id FOR UPDATE;
        FOREACH v_unit IN ARRAY v_units LOOP
            v_cell := mv_unit_leg(v_unit);
            IF v_cell.id IS NULL OR v_cell.at_transfer_id IS DISTINCT FROM p_transfers_id OR v_cell.variants_id <> p_variants_id
               OR v_cell.state = 'written_off' THEN
                PERFORM mv_refuse('MV071', 'The unit is not on this road.', v_facts || jsonb_build_object('serials_id', v_unit));
            END IF;
            v_legs := v_legs || mv_pair(p_variants_id, v_unit, 1, mv_cell(v_cell),
                                        CASE WHEN p_lost THEN mv_cell(v_cell) || jsonb_build_object('state', 'written_off')
                                             ELSE mv_cell(v_cell) || jsonb_build_object('at_transfer_id', NULL,
                                                                                        'at_location_id', v_transfer.location_id) END);
        END LOOP;
        p_qty := cardinality(v_units);
    ELSE
        PERFORM pg_advisory_xact_lock(0, p_variants_id::int4);                         -- the road first, as 009
        PERFORM pg_advisory_xact_lock(v_transfer.location_id, p_variants_id::int4);
        SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
         WHERE variants_id = p_variants_id AND at_transfer_id = p_transfers_id AND state = 'available';
        IF p_qty IS NULL OR p_qty < 1 OR p_qty > v_have THEN
            PERFORM mv_refuse('MV072', format('Only %s on the road to take off %s.', v_have, p_qty),
                              v_facts || jsonb_build_object('have', v_have, 'want', p_qty));
        END IF;
        v_legs := mv_pair(p_variants_id, NULL, p_qty,
                          jsonb_build_object('at_transfer_id', p_transfers_id, 'owner_location_id', v_transfer.location_id, 'state', 'available'),
                          CASE WHEN p_lost
                               THEN jsonb_build_object('at_transfer_id', p_transfers_id, 'owner_location_id', v_transfer.location_id, 'state', 'written_off')
                               ELSE jsonb_build_object('at_location_id', v_transfer.location_id, 'owner_location_id', v_transfer.location_id, 'state', 'available') END);
    END IF;

    PERFORM mv_post(CASE WHEN p_lost THEN 'lost' ELSE 'not_sent' END, 'transfers', p_transfers_id, v_legs, p_note,
                    NULL, NULL, CASE WHEN p_lost THEN p_bears END);
    RETURN jsonb_build_object('taken_off', p_qty, 'units', to_jsonb(v_units), 'on_road', mv_on_road(p_transfers_id));
END $$;

CREATE FUNCTION public.movement_not_sent(p_transfers_id int8, p_variants_id int8, p_qty int4, p_units jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN
    RETURN mv_take_off(p_transfers_id, p_variants_id, p_qty, p_units, false, NULL, p_note);
END $$;

CREATE FUNCTION public.movement_lost(p_transfers_id int8, p_variants_id int8, p_qty int4, p_units jsonb, p_bears text,
                                     p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN
    RETURN mv_take_off(p_transfers_id, p_variants_id, p_qty, p_units, true, p_bears, p_note);
END $$;

-- Event 9, swapped: the chassis that went was not the one the remessa names. On the road, a correction dated at the
-- dispatch: the named unit (r·A·s) → (A·A·s), it never left; the real one (A·A·s) → (r·A·s), it went. Arrived (the
-- destination took the named unit in, but the real one is on its floor), a correction dated at the named unit's
-- arrival: the named unit (B·B·s) → (A·A·s), the real one (A·A·s) → (B·B·s), each where it really stands. The
-- master's (MV070); a remessa sent or received (MV012); the named unit on its road, or arrived by it and unmoved since
-- (MV071) and held by nothing there (MV055); the same model (MV075); the real one free at the origin (MV076) and
-- unmoved since the dispatch (MV077). The remessa's units follow (transfer_units).
CREATE FUNCTION public.movement_swap(p_transfers_id int8, p_named int4, p_real int4, p_note text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_transfer transfers%ROWTYPE;
    v_dispatch movements%ROWTYPE;
    v_arrival  movements%ROWTYPE;
    v_named    movement_legs%ROWTYPE;
    v_real     movement_legs%ROWTYPE;
    v_arrived  boolean;
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id, 'named', p_named, 'real', p_real);
BEGIN
    IF NOT app_at_master() THEN
        PERFORM mv_refuse('MV070', 'Only the master corrects a transfer.', v_facts);
    END IF;
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF v_transfer.status NOT IN ('sent', 'received') THEN
        PERFORM mv_refuse('MV012', format('Transfer %s is %s: it was not sent.', p_transfers_id, v_transfer.status),
                          v_facts || jsonb_build_object('status', v_transfer.status));
    END IF;
    PERFORM 1 FROM serials WHERE id IN (p_named, p_real) ORDER BY id FOR UPDATE;
    v_named := mv_unit_leg(p_named);
    v_real := mv_unit_leg(p_real);
    SELECT * INTO v_arrival FROM movements WHERE id = v_named.movements_id;
    v_arrived := v_arrival.kind = 'arrived' AND v_arrival.ref_type = 'transfers' AND v_arrival.ref_id = p_transfers_id
                 AND v_named.at_location_id = v_transfer.to_location_id AND v_named.owner_location_id = v_transfer.to_location_id;
    IF v_named.id IS NULL OR v_named.state = 'written_off'
       OR NOT (v_named.at_transfer_id IS NOT DISTINCT FROM p_transfers_id OR COALESCE(v_arrived, false)) THEN
        PERFORM mv_refuse('MV071', 'The unit is not on this road.', v_facts || jsonb_build_object('serials_id', p_named));
    END IF;
    IF v_arrived AND EXISTS (SELECT 1 FROM unit_claims c WHERE c.serials_id = p_named) THEN
        PERFORM mv_refuse('MV055', 'The unit is held by something else.', v_facts || jsonb_build_object('claim', mv_unit_claim(p_named)));
    END IF;
    IF v_real.id IS NULL OR v_real.variants_id <> v_named.variants_id THEN
        PERFORM mv_refuse('MV075', 'The real unit is another model.', v_facts);
    END IF;
    IF v_real.at_location_id IS DISTINCT FROM v_transfer.location_id OR v_real.owner_location_id IS DISTINCT FROM v_transfer.location_id
       OR v_real.state = 'written_off' OR EXISTS (SELECT 1 FROM unit_claims c WHERE c.serials_id = p_real) THEN
        PERFORM mv_refuse('MV076', 'The real unit is not free at the origin.', v_facts || jsonb_build_object('claim', mv_unit_claim(p_real)));
    END IF;
    SELECT * INTO v_dispatch FROM movements
     WHERE kind = 'dispatched' AND ref_type = 'transfers' AND ref_id = p_transfers_id ORDER BY id LIMIT 1;
    IF v_real.movements_id > v_dispatch.id THEN   -- posted after the dispatch, though it be the same second
        PERFORM mv_refuse('MV077', 'The real unit moved after the dispatch: correct it first.', v_facts);
    END IF;

    IF v_arrived THEN
        PERFORM mv_post('swapped', 'transfers', p_transfers_id,
                        mv_pair(v_named.variants_id, p_named, 1, mv_cell(v_named),
                                mv_cell(v_named) || jsonb_build_object('at_location_id', v_transfer.location_id, 'owner_location_id', v_transfer.location_id))
                        || mv_pair(v_real.variants_id, p_real, 1, mv_cell(v_real),
                                   mv_cell(v_real) || jsonb_build_object('at_location_id', v_transfer.to_location_id,
                                                                         'owner_location_id', v_transfer.to_location_id)),
                        p_note, v_arrival.occurred_at, v_arrival.id);
    ELSE
        PERFORM mv_post('swapped', 'transfers', p_transfers_id,
                        mv_pair(v_named.variants_id, p_named, 1, mv_cell(v_named),
                                mv_cell(v_named) || jsonb_build_object('at_transfer_id', NULL, 'at_location_id', v_transfer.location_id))
                        || mv_pair(v_real.variants_id, p_real, 1, mv_cell(v_real),
                                   mv_cell(v_real) || jsonb_build_object('at_location_id', NULL, 'at_transfer_id', p_transfers_id)),
                        p_note, v_dispatch.occurred_at, v_dispatch.id);
    END IF;
    DELETE FROM transfer_units WHERE transfers_id = p_transfers_id AND serials_id = p_named;
    INSERT INTO transfer_units VALUES (p_transfers_id, p_real) ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('swapped', true, 'named', p_named, 'real', p_real, 'arrived', COALESCE(v_arrived, false));
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
    SELECT sa.id, sa.orders_id, sa.variants_id, sa.serials_id, sa.quantity::int4 AS qty, i.serial,
           sa.status AS line_status, sa.deleted_at
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

-- The claims (code §3.3): what holds a unit, on the document that holds it. A claim moves nothing; it keeps a unit
-- for one document, and unit_claims reads them all. A unit is claimed only where its owner stands and available
-- (MV091: a bike on the bench is not, §0.5), and by one thing at a time (MV055). A wish is no claim: the earmark
-- blocks nothing. A pré-venda takes no unit by its shape: a quote's lines have none.
CREATE FUNCTION public.mv_claimable(p_serials_id int4, p_location int4, p_facts jsonb) RETURNS public.movement_legs
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_cell movement_legs%ROWTYPE;
BEGIN
    PERFORM 1 FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', p_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    IF v_cell.id IS NULL OR v_cell.at_location_id IS DISTINCT FROM p_location OR v_cell.owner_location_id IS DISTINCT FROM p_location
       OR v_cell.state <> 'available' THEN
        PERFORM mv_refuse('MV091', 'The unit is not available where it would be held.',
                          p_facts || jsonb_build_object('state', v_cell.state, 'location_id', p_location));
    END IF;
    IF EXISTS (SELECT 1 FROM unit_claims WHERE serials_id = p_serials_id) THEN
        PERFORM mv_refuse('MV055', 'The unit is held by something else.', p_facts || jsonb_build_object('claim', mv_unit_claim(p_serials_id)));
    END IF;
    RETURN v_cell;
END $$;

-- A remessa draft holds a unit at its origin (transfer_units): the draft's own rows. Holding twice is nothing. From
-- the draft's own seat, or the master's (a remessa the master decides from a shop, relocateStock).
CREATE FUNCTION public.claim_hold(p_transfers_id int8, p_serials_id int4) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_transfer transfers%ROWTYPE;
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id, 'serials_id', p_serials_id);
BEGIN
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF NOT (app_at_master() OR v_transfer.location_id = app_location()) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_transfer.location_id));
    END IF;
    IF v_transfer.status <> 'draft' THEN
        PERFORM mv_refuse('MV090', 'Only a draft holds units.', v_facts || jsonb_build_object('status', v_transfer.status));
    END IF;
    IF EXISTS (SELECT 1 FROM transfer_units WHERE transfers_id = p_transfers_id AND serials_id = p_serials_id) THEN
        RETURN jsonb_build_object('held', false);
    END IF;
    PERFORM mv_claimable(p_serials_id, v_transfer.location_id, v_facts);
    INSERT INTO transfer_units VALUES (p_transfers_id, p_serials_id);
    RETURN jsonb_build_object('held', true);
END $$;

-- A draft lets a unit go, or every unit it holds (p_serials_id null): the draft saved without it, or discarded. From
-- the draft's own seat, or the master's.
CREATE FUNCTION public.claim_release(p_transfers_id int8, p_serials_id int4 DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_transfer transfers%ROWTYPE;
    v_released int4;
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id, 'serials_id', p_serials_id);
BEGIN
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Transfer not found.', v_facts);
    END IF;
    IF NOT (app_at_master() OR v_transfer.location_id = app_location()) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_transfer.location_id));
    END IF;
    IF v_transfer.status <> 'draft' THEN
        PERFORM mv_refuse('MV090', 'Only a draft holds units.', v_facts || jsonb_build_object('status', v_transfer.status));
    END IF;
    DELETE FROM transfer_units WHERE transfers_id = p_transfers_id AND (p_serials_id IS NULL OR serials_id = p_serials_id);
    GET DIAGNOSTICS v_released = ROW_COUNT;
    RETURN jsonb_build_object('released', v_released);
END $$;

-- The attach: an order line takes its unit (sales.serials_id), standing at the order's location and available.
-- Attached to a line of an order paid in full, the sale is posted at once (§0.3: whichever comes last).
CREATE FUNCTION public.claim_sale(p_sales_id int8, p_serials_id int4) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user   int4 := mv_user();   -- an empty session is refused before anything else
    v_line   record := mv_order_line(p_sales_id);
    v_order  orders%ROWTYPE := mv_order(v_line.orders_id, false);
    v_model  int8;
    v_answer jsonb;
    v_facts  jsonb := jsonb_build_object('sales_id', p_sales_id, 'serials_id', p_serials_id);
BEGIN
    IF v_order.status IN ('cancelled', 'refunded', 'voided') OR v_order.deleted_at IS NOT NULL
       OR v_line.line_status IN ('cancelled', 'refunded') OR v_line.deleted_at IS NOT NULL THEN
        PERFORM mv_refuse('MV094', 'The order or its line is no longer alive.', v_facts);
    END IF;
    SELECT variants_id INTO v_model FROM serials WHERE id = p_serials_id;
    IF NOT v_line.serial OR v_model IS DISTINCT FROM v_line.variants_id THEN
        PERFORM mv_refuse('MV095', 'The unit is another model.', v_facts);
    END IF;
    IF v_line.serials_id = p_serials_id THEN
        RETURN jsonb_build_object('attached', false, 'sold', mv_line_sold(p_sales_id));
    END IF;
    IF v_line.serials_id IS NOT NULL THEN
        PERFORM mv_refuse('MV096', 'The line has its unit: release it first.', v_facts || jsonb_build_object('held', v_line.serials_id));
    END IF;
    PERFORM mv_claimable(p_serials_id, v_order.location_id, v_facts);
    UPDATE sales SET serials_id = p_serials_id WHERE id = p_sales_id;
    IF v_order.paid IS TRUE THEN
        v_answer := movement_sell(v_line.orders_id);
    END IF;
    RETURN jsonb_build_object('attached', true, 'sold', COALESCE(v_answer->'sold' @> to_jsonb(p_sales_id), false));
END $$;

-- An order line lets its unit go, while it is not sold (MV097: undo the sale first).
CREATE FUNCTION public.claim_sale_release(p_sales_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user  int4 := mv_user();   -- an empty session is refused before anything else
    v_line  record := mv_order_line(p_sales_id);
    v_order orders%ROWTYPE := mv_order(v_line.orders_id, false);
BEGIN
    IF v_line.serials_id IS NULL THEN
        RETURN jsonb_build_object('released', false);
    END IF;
    IF mv_line_sold(p_sales_id) THEN
        PERFORM mv_refuse('MV097', 'The line is sold: undo the sale first.', jsonb_build_object('sales_id', p_sales_id));
    END IF;
    UPDATE sales SET serials_id = NULL WHERE id = p_sales_id;
    RETURN jsonb_build_object('released', true, 'serials_id', v_line.serials_id);
END $$;

-- The rental fleet takes a unit for one of its resources (resources.serials_id), of the resource's model, where the
-- resource is kept. A fleet bike is on hand and never sellable while it is in the fleet.
CREATE FUNCTION public.claim_fleet(p_resources_id int8, p_serials_id int4) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_resource resources%ROWTYPE;
    v_facts    jsonb := jsonb_build_object('resources_id', p_resources_id, 'serials_id', p_serials_id);
BEGIN
    SELECT * INTO v_resource FROM resources WHERE id = p_resources_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV098', 'Fleet resource not found.', v_facts);
    END IF;
    IF NOT (app_at_master() OR app_location() = v_resource.location_id) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_resource.location_id));
    END IF;
    IF v_resource.serials_id = p_serials_id THEN
        RETURN jsonb_build_object('held', false);
    END IF;
    IF v_resource.serials_id IS NOT NULL THEN
        PERFORM mv_refuse('MV099', 'The fleet resource has its unit.', v_facts || jsonb_build_object('held', v_resource.serials_id));
    END IF;
    IF v_resource.variants_id IS NOT NULL AND v_resource.variants_id IS DISTINCT FROM (SELECT variants_id FROM serials WHERE id = p_serials_id) THEN
        PERFORM mv_refuse('MV095', 'The unit is another model.', v_facts);
    END IF;
    PERFORM mv_claimable(p_serials_id, v_resource.location_id, v_facts);
    UPDATE resources SET serials_id = p_serials_id WHERE id = p_resources_id;
    RETURN jsonb_build_object('held', true);
END $$;

-- The fleet lets a resource's unit go, unless it is out with a customer (MV100).
CREATE FUNCTION public.claim_fleet_release(p_resources_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_resource resources%ROWTYPE;
    v_facts    jsonb := jsonb_build_object('resources_id', p_resources_id);
BEGIN
    SELECT * INTO v_resource FROM resources WHERE id = p_resources_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV098', 'Fleet resource not found.', v_facts);
    END IF;
    IF NOT (app_at_master() OR app_location() = v_resource.location_id) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_resource.location_id));
    END IF;
    IF v_resource.serials_id IS NULL THEN
        RETURN jsonb_build_object('released', false);
    END IF;
    IF (mv_unit_leg(v_resource.serials_id::int4)).at_customer_id IS NOT NULL THEN
        PERFORM mv_refuse('MV100', 'The unit is out with a customer.', v_facts || jsonb_build_object('serials_id', v_resource.serials_id));
    END IF;
    UPDATE resources SET serials_id = NULL WHERE id = p_resources_id;
    RETURN jsonb_build_object('released', true, 'serials_id', v_resource.serials_id);
END $$;

-- Events 20 and 21, written off and returned to the provider (the baixa: theft, a total loss, a return to the
-- supplier). Written off: (x·o·s) → (x·o·written_off), where it stands. To the provider: (L·L·s) → (p·p·s), p the
-- supplier named or else the unit's purchase supplier (MV083). Both: the master's (MV082); a unit in stock or on the
-- bench where its owner stands (MV081); nothing holding it (MV055); the baixa_moto approval for this unit (MV080).
CREATE FUNCTION public.mv_baixa(p_serials_id int4, p_approval_id int8, p_to_provider boolean, p_suppliers_id int8, p_note text)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_cell     movement_legs%ROWTYPE;
    v_supplier int8;
    v_facts    jsonb := jsonb_build_object('serials_id', p_serials_id, 'approvals_id', p_approval_id);
BEGIN
    IF NOT app_at_master() THEN
        PERFORM mv_refuse('MV082', 'Only the master writes off a unit.', v_facts);
    END IF;
    PERFORM 1 FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', v_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    IF v_cell.id IS NULL OR v_cell.at_location_id IS NULL OR v_cell.at_location_id IS DISTINCT FROM v_cell.owner_location_id
       OR v_cell.state NOT IN ('validating', 'available') THEN
        PERFORM mv_refuse('MV081', 'Only a unit in stock or on the bench is written off.', v_facts || jsonb_build_object('state', v_cell.state));
    END IF;
    IF EXISTS (SELECT 1 FROM unit_claims WHERE serials_id = p_serials_id) THEN
        PERFORM mv_refuse('MV055', 'The unit is held by something else.', v_facts || jsonb_build_object('claim', mv_unit_claim(p_serials_id)));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM approvals WHERE id = p_approval_id AND action = 'baixa_moto'
                      AND ref_type = 'serials' AND ref_id = p_serials_id) THEN
        PERFORM mv_refuse('MV080', 'A write-off needs its approval (baixa_moto).', v_facts);
    END IF;
    IF NOT p_to_provider THEN
        PERFORM mv_post('written_off', 'approvals', p_approval_id,
                        mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell), mv_cell(v_cell) || jsonb_build_object('state', 'written_off')), p_note);
        RETURN jsonb_build_object('state', 'written_off');
    END IF;
    v_supplier := COALESCE(p_suppliers_id, (SELECT p.suppliers_id FROM serials s JOIN purchase_items pi ON pi.id = s.purchase_items_id
                                              JOIN purchases p ON p.id = pi.purchases_id WHERE s.id = p_serials_id));
    IF v_supplier IS NULL OR NOT EXISTS (SELECT 1 FROM suppliers WHERE id = v_supplier) THEN
        PERFORM mv_refuse('MV083', 'Say which supplier it goes back to.', v_facts);
    END IF;
    PERFORM mv_post('to_provider', 'approvals', p_approval_id,
                    mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell),
                            jsonb_build_object('at_supplier_id', v_supplier, 'owner_supplier_id', v_supplier, 'state', v_cell.state)), p_note);
    RETURN jsonb_build_object('state', v_cell.state, 'suppliers_id', v_supplier);
END $$;

CREATE FUNCTION public.movement_write_off(p_serials_id int4, p_approval_id int8, p_note text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN
    RETURN mv_baixa(p_serials_id, p_approval_id, false, NULL, p_note);
END $$;

CREATE FUNCTION public.movement_to_provider(p_serials_id int4, p_approval_id int8, p_suppliers_id int8 DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN
    RETURN mv_baixa(p_serials_id, p_approval_id, true, p_suppliers_id, p_note);
END $$;

-- Whether the session's user is an admin or a superadmin (user 1 is always one), as app_user_superadmin()
-- reads it. The flip is the master's admin's (step D).
CREATE FUNCTION public.app_user_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM users u
                    WHERE u.id = NULLIF(current_setting('app.user', true), '')::integer
                      AND u.active AND (u.id = 1 OR u.role IN ('admin', 'superadmin')))
$$;

-- Event 10, flipped (Transferência rápida, step D): (A·A·available) → (B·B·available) at once, with no road. Only
-- the master's admin or superadmin (MV130), from one active location to another (MV131). Units by name, each
-- available at A and held by nothing (mv_claimable: MV020, MV091, MV055); counted goods by quantity, up to what A
-- has (MV132). p_units: [serials_id]; p_counted: [{variants_id, qty}].
CREATE FUNCTION public.movement_flip(p_from int4, p_to int4, p_units jsonb DEFAULT '[]', p_counted jsonb DEFAULT '[]',
                                     p_note text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_units    int4[] := ARRAY(SELECT DISTINCT u::int4 FROM jsonb_array_elements_text(COALESCE(p_units, '[]')) AS x(u) ORDER BY 1);
    v_unit     int4;
    v_cell     movement_legs%ROWTYPE;
    v_line     record;
    v_have     int4;
    v_lines    int4 := 0;
    v_legs     jsonb := '[]';
    v_movement int8;
    v_facts    jsonb := jsonb_build_object('from', p_from, 'to', p_to);
BEGIN
    IF NOT (app_at_master() AND app_user_admin()) THEN
        PERFORM mv_refuse('MV130', 'Only the master''s admin flips stock.', v_facts);
    END IF;
    IF p_from IS NOT DISTINCT FROM p_to OR (SELECT count(*) FROM locations WHERE id IN (p_from, p_to) AND active) < 2 THEN
        PERFORM mv_refuse('MV131', 'A flip goes from one active location to another.', v_facts);
    END IF;
    FOREACH v_unit IN ARRAY v_units LOOP
        v_cell := mv_claimable(v_unit, p_from, v_facts || jsonb_build_object('serials_id', v_unit));
        v_legs := v_legs || mv_pair(v_cell.variants_id, v_unit, 1, mv_cell(v_cell),
                                    jsonb_build_object('at_location_id', p_to, 'owner_location_id', p_to, 'state', 'available'));
    END LOOP;
    FOR v_line IN SELECT c.variants_id, SUM(c.qty)::int4 AS qty, bool_or(i.serial) AS serial, bool_and(i.sellable) AS sellable,
                         count(v.id) AS known
                    FROM jsonb_to_recordset(COALESCE(p_counted, '[]')) AS c(variants_id int8, qty int4)
                    LEFT JOIN variants v ON v.id = c.variants_id LEFT JOIN items i ON i.id = v.items_id
                   GROUP BY c.variants_id HAVING SUM(c.qty) <> 0 ORDER BY c.variants_id LOOP
        IF v_line.known = 0 THEN
            PERFORM mv_refuse('MV113', 'Unknown model.', v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.serial THEN
            PERFORM mv_refuse('MV073', 'Name the units of a serial-tracked model.', v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF NOT v_line.sellable THEN
            PERFORM mv_refuse('MV015', 'Materials do not move through the ledger.', v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        -- both locations' keys, the lower first, as every event takes them
        PERFORM pg_advisory_xact_lock(least(p_from, p_to), v_line.variants_id::int4);
        PERFORM pg_advisory_xact_lock(greatest(p_from, p_to), v_line.variants_id::int4);
        SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
         WHERE variants_id = v_line.variants_id AND state = 'available' AND at_location_id = p_from AND owner_location_id = p_from;
        IF v_line.qty < 0 OR v_have < v_line.qty THEN
            PERFORM mv_refuse('MV132', format('Only %s in stock to flip %s.', v_have, v_line.qty),
                              v_facts || jsonb_build_object('variants_id', v_line.variants_id, 'have', v_have, 'want', v_line.qty));
        END IF;
        v_legs := v_legs || mv_pair(v_line.variants_id, NULL, v_line.qty,
                                    jsonb_build_object('at_location_id', p_from, 'owner_location_id', p_from, 'state', 'available'),
                                    jsonb_build_object('at_location_id', p_to, 'owner_location_id', p_to, 'state', 'available'));
        v_lines := v_lines + 1;
    END LOOP;
    IF v_legs = '[]' THEN
        PERFORM mv_refuse('MV133', 'Nothing to flip.', v_facts);
    END IF;
    v_movement := mv_post('flipped', NULL, NULL, v_legs, p_note);
    RETURN jsonb_build_object('movement_id', v_movement, 'units', cardinality(v_units), 'lines', v_lines);
END $$;

-- Events 16 and 17, out with a customer on a rental or a loan, and back: (L·L·s) → (c·L·s) → (L·L·s). The bike
-- stays its location's. The document names the unit (MV142), its customer (MV146) and its location (MV093: the
-- session there, or at the master). Out: the unit available where its owner stands (MV143), held by nothing but the
-- rental's own fleet resource (MV055). Back: only what went out on this document (MV144), home to its owner. Each
-- is once: again is nothing ({done: false}).
CREATE FUNCTION public.mv_lend(p_out boolean, p_kind_out text, p_kind_back text, p_ref_type text, p_ref_id int8,
                               p_serials_id int4, p_customer int4, p_location int4, p_own_resource int8) RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_cell  movement_legs%ROWTYPE;
    v_last  movements%ROWTYPE;
    v_mine  boolean;
    v_kind  text := CASE WHEN p_out THEN p_kind_out ELSE p_kind_back END;
    v_facts jsonb := jsonb_build_object('ref_type', p_ref_type, 'ref_id', p_ref_id, 'serials_id', p_serials_id);
BEGIN
    IF NOT (app_at_master() OR app_location() = p_location) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', p_location));
    END IF;
    IF p_serials_id IS NULL THEN
        PERFORM mv_refuse('MV142', 'The document names no bike.', v_facts);
    END IF;
    IF p_customer IS NULL OR NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer) THEN
        PERFORM mv_refuse('MV146', 'A bike out with someone is with a customer: the document names none.', v_facts);
    END IF;
    PERFORM 1 FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', v_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    SELECT * INTO v_last FROM movements WHERE id = v_cell.movements_id;
    v_mine := v_last.ref_type IS NOT DISTINCT FROM p_ref_type AND v_last.ref_id IS NOT DISTINCT FROM p_ref_id;
    IF v_mine AND v_last.kind = v_kind THEN
        RETURN jsonb_build_object('done', false);
    END IF;
    IF p_out THEN
        IF v_cell.id IS NULL OR v_cell.at_location_id IS DISTINCT FROM p_location OR v_cell.owner_location_id IS DISTINCT FROM p_location
           OR v_cell.state <> 'available' THEN
            PERFORM mv_refuse('MV143', 'The unit is not available to go out.',
                              v_facts || jsonb_build_object('state', v_cell.state, 'location_id', p_location));
        END IF;
        IF EXISTS (SELECT 1 FROM unit_claims c WHERE c.serials_id = p_serials_id
                      AND NOT (c.kind = 'fleet' AND c.ref_id IS NOT DISTINCT FROM p_own_resource)) THEN
            PERFORM mv_refuse('MV055', 'The unit is held by something else.', v_facts || jsonb_build_object('claim', mv_unit_claim(p_serials_id)));
        END IF;
        PERFORM mv_post(p_kind_out, p_ref_type, p_ref_id,
                        mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell),
                                mv_cell(v_cell) || jsonb_build_object('at_location_id', NULL, 'at_customer_id', p_customer)));
    ELSE
        IF NOT (v_mine AND v_last.kind = p_kind_out) THEN
            PERFORM mv_refuse('MV144', 'The unit is not out on this document.', v_facts);
        END IF;
        PERFORM mv_post(p_kind_back, p_ref_type, p_ref_id,
                        mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell),
                                mv_cell(v_cell) || jsonb_build_object('at_customer_id', NULL, 'at_location_id', v_cell.owner_location_id)));
    END IF;
    RETURN jsonb_build_object('done', true);
END $$;

-- A rental (bookings): its fleet resource's bike, its customer, its location. Found (MV140); out only while it is
-- to come or under way (MV141); back whatever its status, as a bike comes back whatever its document says.
CREATE FUNCTION public.mv_rental(p_bookings_id int8, p_out boolean) RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_booking record;
BEGIN
    SELECT b.id, b.customer_id, b.status, b.location_id, b.resource_id, r.serials_id::int4 AS serials_id
      INTO v_booking
      FROM bookings b LEFT JOIN resources r ON r.id = b.resource_id
     WHERE b.id = p_bookings_id
       FOR UPDATE OF b;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV140', 'Booking not found.', jsonb_build_object('bookings_id', p_bookings_id));
    END IF;
    IF p_out AND v_booking.status NOT IN ('pending', 'reserved', 'confirmed', 'in_use') THEN
        PERFORM mv_refuse('MV141', 'The document is not open.', jsonb_build_object('bookings_id', p_bookings_id, 'document_status', v_booking.status));
    END IF;
    RETURN mv_lend(p_out, 'rented', 'rental_back', 'bookings', p_bookings_id, v_booking.serials_id,
                   v_booking.customer_id, v_booking.location_id, v_booking.resource_id);
END $$;

-- A loan (loans): its bike, its customer (migration 026; a loan without one is refused, MV146), its location.
-- Found (MV145); out only while it is being prepared or with the person (MV141); back whatever its status.
CREATE FUNCTION public.mv_loan(p_loans_id int8, p_out boolean) RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_loan loans%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM loans WHERE id = p_loans_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV145', 'Loan not found.', jsonb_build_object('loans_id', p_loans_id));
    END IF;
    IF p_out AND v_loan.status NOT IN ('preparando', 'com_a_pessoa') THEN
        PERFORM mv_refuse('MV141', 'The document is not open.', jsonb_build_object('loans_id', p_loans_id, 'document_status', v_loan.status));
    END IF;
    RETURN mv_lend(p_out, 'loaned', 'loan_back', 'loans', p_loans_id, v_loan.serials_id::int4,
                   v_loan.customers_id, v_loan.location_id, NULL);
END $$;

CREATE FUNCTION public.movement_rent_out(p_bookings_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN RETURN mv_rental(p_bookings_id, true); END $$;

CREATE FUNCTION public.movement_rent_back(p_bookings_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN RETURN mv_rental(p_bookings_id, false); END $$;

CREATE FUNCTION public.movement_loan_out(p_loans_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN RETURN mv_loan(p_loans_id, true); END $$;

CREATE FUNCTION public.movement_loan_back(p_loans_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN RETURN mv_loan(p_loans_id, false); END $$;

-- Counted goods at the session's location, line by line, as one movement. A line gives its difference (qty) or the
-- balance it is to have (balance), worked out under the model's lock, as adjustStock's qty_new was; a model set to a
-- balance is given once (MV116). A gain comes from the books → (L·L·available); a loss goes
-- (L·L·available) → (L·L·written_off), up to what is there (MV114). Found is a gain; damaged, loss and expired are
-- losses (MV115). A serial-tracked model is adjusted through its unit (MV110), materials not at all (MV015).
-- Answers each model's balance before and after, and the movement (none when nothing differs).
CREATE FUNCTION public.mv_adjust(p_kind text, p_ref_type text, p_ref_id int8, p_lines jsonb, p_reason text, p_note text)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_here     int4 := app_location();
    v_line     record;
    v_have     int4;
    v_delta    int4;
    v_legs     jsonb := '[]';
    v_items    jsonb := '[]';
    v_movement int8;
BEGIN
    FOR v_line IN SELECT c.variants_id, SUM(c.qty)::int4 AS qty, MAX(c.balance)::int4 AS balance,
                         count(*) AS n, count(c.balance) AS balances,
                         bool_or(i.serial) AS serial, bool_and(i.sellable) AS sellable, count(v.id) AS known
                    FROM jsonb_to_recordset(COALESCE(p_lines, '[]')) AS c(variants_id int8, qty int4, balance int4)
                    LEFT JOIN variants v ON v.id = c.variants_id LEFT JOIN items i ON i.id = v.items_id
                   GROUP BY c.variants_id ORDER BY c.variants_id LOOP
        IF v_line.known = 0 THEN
            PERFORM mv_refuse('MV113', 'Unknown model.', jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.serial THEN
            PERFORM mv_refuse('MV110', 'A bike is adjusted through its unit.', jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF NOT v_line.sellable THEN
            PERFORM mv_refuse('MV015', 'Materials do not move through the ledger.', jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.balances > 0 AND v_line.n > 1 THEN
            PERFORM mv_refuse('MV116', 'A model set to a balance is given once.', jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        PERFORM pg_advisory_xact_lock(v_here, v_line.variants_id::int4);
        SELECT COALESCE(SUM(qty), 0) INTO v_have FROM positions
         WHERE variants_id = v_line.variants_id AND state = 'available' AND at_location_id = v_here AND owner_location_id = v_here;
        v_delta := CASE WHEN v_line.balances > 0 THEN v_line.balance - v_have ELSE COALESCE(v_line.qty, 0) END;
        CONTINUE WHEN v_delta = 0;
        IF (p_reason = 'found' AND v_delta < 0) OR (p_reason IN ('damaged', 'loss', 'expired') AND v_delta > 0) THEN
            PERFORM mv_refuse('MV115', 'Found is a gain; damaged, loss and expired are losses.',
                              jsonb_build_object('variants_id', v_line.variants_id, 'reason', p_reason, 'delta', v_delta));
        END IF;
        IF v_have + v_delta < 0 THEN
            PERFORM mv_refuse('MV114', format('Only %s in stock to take %s.', v_have, -v_delta),
                              jsonb_build_object('variants_id', v_line.variants_id, 'have', v_have, 'want', -v_delta));
        END IF;
        v_legs := v_legs || CASE WHEN v_delta > 0
            THEN mv_pair(v_line.variants_id, NULL, v_delta, jsonb_build_object('state', 'available'),
                         jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available'))
            ELSE mv_pair(v_line.variants_id, NULL, -v_delta,
                         jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'available'),
                         jsonb_build_object('at_location_id', v_here, 'owner_location_id', v_here, 'state', 'written_off')) END;
        v_items := v_items || jsonb_build_object('variants_id', v_line.variants_id, 'before', v_have,
                                                 'after', v_have + v_delta, 'delta', v_delta);
    END LOOP;
    IF v_legs <> '[]' THEN
        v_movement := mv_post(p_kind, p_ref_type, p_ref_id, v_legs, p_note, NULL, NULL, p_reason);
    END IF;
    RETURN jsonb_build_object('adjusted', jsonb_array_length(v_items), 'movement_id', v_movement, 'items', v_items);
END $$;

-- Event 22, adjusted (Ajuste, both modules; replaces adjustStock and adjustStockBatch): one line or many, with its
-- reason (MV111: found, damaged, loss, expired, count, other) and its note (MV112), as adjustStock asked.
CREATE FUNCTION public.movement_adjust(p_lines jsonb, p_reason text, p_note text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user int4 := mv_user();   -- an empty session is refused before anything else
BEGIN
    IF p_reason IS NULL OR p_reason NOT IN ('found', 'damaged', 'loss', 'expired', 'count', 'other') THEN
        PERFORM mv_refuse('MV111', 'Say why: found, damaged, loss, expired, count or other.', jsonb_build_object('given', p_reason));
    END IF;
    IF NULLIF(trim(p_note), '') IS NULL THEN
        PERFORM mv_refuse('MV112', 'An adjustment needs its note.');
    END IF;
    RETURN mv_adjust('adjusted', NULL, NULL, p_lines, p_reason, trim(p_note));
END $$;

-- Event 23, counted (Inventário, core/stockCount.php's close): each counted part of an open count (MV121) of this
-- location (MV093) set to what was counted, as one movement with reason count. Several lines of one model add up;
-- a line not counted is left alone; materials and units are not the ledger's to adjust here. The module closes
-- its document after (fechado, parts_adjusted from the answer); closing twice posts nothing the second time.
CREATE FUNCTION public.movement_count_close(p_counts_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user  int4 := mv_user();   -- an empty session is refused before anything else
    v_count stock_counts%ROWTYPE;
    v_lines jsonb;
BEGIN
    SELECT * INTO v_count FROM stock_counts WHERE id = p_counts_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV120', 'Stock count not found.', jsonb_build_object('stock_counts_id', p_counts_id));
    END IF;
    IF v_count.location_id IS DISTINCT FROM app_location() THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', jsonb_build_object('location_id', v_count.location_id));
    END IF;
    IF v_count.status <> 'contando' THEN
        PERFORM mv_refuse('MV121', 'The count is not open.', jsonb_build_object('stock_counts_id', p_counts_id, 'document_status', v_count.status));
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('variants_id', l.variants_id, 'balance', l.counted) ORDER BY l.variants_id), '[]')
      INTO v_lines
      FROM (SELECT cl.variants_id, SUM(cl.counted_qty)::int4 AS counted
              FROM stock_count_lines cl JOIN variants v ON v.id = cl.variants_id JOIN items i ON i.id = v.items_id
             WHERE cl.counts_id = p_counts_id AND cl.kind = 'part' AND cl.counted_qty IS NOT NULL AND NOT i.serial AND i.sellable
             GROUP BY cl.variants_id) l;
    RETURN mv_adjust('counted', 'stock_counts', p_counts_id, v_lines, 'count', NULL);
END $$;

-- Event 24, corrected (the supervisor, on the unit's page; it replaces the status set by hand and unstick.php): the
-- unit's cell → the cell it really is in, a location's, validating or available, with a note (MV156). The supervisor's
-- word is an approval for this unit (action unit_correction: MV150), each used once (MV151). Never a sale: a customer's
-- unit is undone or returned on its order (MV152); a write-off is its own event (MV154). From the master's seat, or
-- from the seat of the unit's place, its owner or the place it goes to (MV093). A unit something holds goes only
-- where its holder stands, available, so the claim stays whole (MV055). The owner is the place's unless given, the
-- state the unit's own unless given.
CREATE FUNCTION public.movement_correct(p_serials_id int4, p_approval_id int8, p_place int4, p_owner int4 DEFAULT NULL,
                                        p_state text DEFAULT NULL, p_note text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();   -- an empty session is refused before anything else
    v_cell     movement_legs%ROWTYPE;
    v_owner    int4 := COALESCE(p_owner, p_place);
    v_state    text;
    v_to       jsonb;
    v_movement int8;
    v_facts    jsonb := jsonb_build_object('serials_id', p_serials_id, 'approvals_id', p_approval_id);
BEGIN
    IF NULLIF(trim(p_note), '') IS NULL THEN
        PERFORM mv_refuse('MV156', 'A correction needs its note.', v_facts);
    END IF;
    PERFORM 1 FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', v_facts);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM approvals WHERE id = p_approval_id AND action = 'unit_correction'
                      AND ref_type = 'serials' AND ref_id = p_serials_id) THEN
        PERFORM mv_refuse('MV150', 'A correction needs the supervisor''s approval for this unit (unit_correction).', v_facts);
    END IF;
    IF EXISTS (SELECT 1 FROM movements WHERE ref_type = 'approvals' AND ref_id = p_approval_id) THEN
        PERFORM mv_refuse('MV151', 'The approval was used already.', v_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    IF v_cell.id IS NULL THEN
        PERFORM mv_refuse('MV157', 'The unit has no line yet: the opening gives it one.', v_facts);
    END IF;
    IF v_cell.owner_customer_id IS NOT NULL THEN
        PERFORM mv_refuse('MV152', 'The unit is a customer''s: a sale is undone or returned on its order.', v_facts);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM locations WHERE id = p_place AND active)
       OR NOT EXISTS (SELECT 1 FROM locations WHERE id = v_owner AND active) THEN
        PERFORM mv_refuse('MV153', 'A correction puts the unit at an active location, an active location''s.',
                          v_facts || jsonb_build_object('place', p_place, 'owner', v_owner));
    END IF;
    v_state := COALESCE(p_state, v_cell.state);
    IF v_state NOT IN ('validating', 'available') THEN
        PERFORM mv_refuse('MV154', 'A correction leaves the unit validating or available: a write-off is its own event.',
                          v_facts || jsonb_build_object('state', v_state));
    END IF;
    IF NOT (app_at_master() OR app_location() IS NOT DISTINCT FROM v_cell.at_location_id
            OR app_location() IS NOT DISTINCT FROM v_cell.owner_location_id OR app_location() = p_place) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_cell.at_location_id));
    END IF;
    v_to := mv_cell(NULL::movement_legs) || jsonb_build_object('at_location_id', p_place, 'owner_location_id', v_owner, 'state', v_state);
    IF mv_cell(v_cell) = v_to THEN
        PERFORM mv_refuse('MV155', 'The unit is there already.', v_facts);
    END IF;
    IF EXISTS (SELECT 1 FROM unit_claims c
                 LEFT JOIN orders o ON c.kind = 'order' AND o.id = c.ref_id
                 LEFT JOIN transfers t ON c.kind = 'draft' AND t.id = c.ref_id
                 LEFT JOIN resources r ON c.kind = 'fleet' AND r.id = c.ref_id
                WHERE c.serials_id = p_serials_id
                  AND (COALESCE(o.location_id, t.location_id, r.location_id) IS DISTINCT FROM p_place
                       OR v_owner <> p_place OR v_state <> 'available')) THEN
        PERFORM mv_refuse('MV055', 'The unit is held by something else.', v_facts || jsonb_build_object('claim', mv_unit_claim(p_serials_id)));
    END IF;
    v_movement := mv_post('corrected', 'approvals', p_approval_id, mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell), v_to),
                          trim(p_note));
    RETURN jsonb_build_object('movement_id', v_movement);
END $$;

-- Removing a unit that is nothing yet (deleteSerial, the supervisor's): its receipt corrected down by this very unit,
-- numbered or not, back to where the receipt brought it from. Only a unit whose one movement is its receipt (MV161),
-- named by no document (MV162): an order line, an assembly job, a service order, a workshop appointment, a loan, a
-- remessa draft, the rental fleet, a stock count, an issued NF-e. The supervisor's word is an approval for this unit
-- (action unit_removal: MV160); from the master's seat or the receipt's (MV093). The line's received total goes down
-- by one, and the unit's number is freed for the bike that really has it. The identity row stays, its line ending
-- where it began: a unit is never deleted once the journal names it.
CREATE FUNCTION public.movement_unit_remove(p_serials_id int4, p_approval_id int8, p_note text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user  int4 := mv_user();   -- an empty session is refused before anything else
    v_unit  serials%ROWTYPE;
    v_cell  movement_legs%ROWTYPE;
    v_entry movements%ROWTYPE;
    v_where int4;
    v_named text;
    v_facts jsonb := jsonb_build_object('serials_id', p_serials_id, 'approvals_id', p_approval_id);
BEGIN
    SELECT * INTO v_unit FROM serials WHERE id = p_serials_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV020', 'Unit not found.', v_facts);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM approvals WHERE id = p_approval_id AND action = 'unit_removal'
                      AND ref_type = 'serials' AND ref_id = p_serials_id) THEN
        PERFORM mv_refuse('MV160', 'Removing a unit needs the supervisor''s approval for it (unit_removal).', v_facts);
    END IF;
    v_cell := mv_unit_leg(p_serials_id);
    SELECT * INTO v_entry FROM movements WHERE id = v_cell.movements_id;
    IF v_cell.id IS NULL OR v_entry.kind <> 'received'
       OR (SELECT count(*) FROM movement_legs WHERE serials_id = p_serials_id) <> 2 THEN
        PERFORM mv_refuse('MV161', 'Only a unit whose one movement is its receipt is removed.', v_facts || jsonb_build_object('last', v_entry.kind));
    END IF;
    SELECT p.location_id INTO v_where
      FROM purchase_items pi JOIN purchases p ON p.id = pi.purchases_id
     WHERE pi.id = v_entry.ref_id
       FOR UPDATE OF pi;
    IF NOT (app_at_master() OR app_location() IS NOT DISTINCT FROM v_where) THEN
        PERFORM mv_refuse('MV093', 'The document is another location''s.', v_facts || jsonb_build_object('location_id', v_where));
    END IF;
    v_named := CASE
        WHEN EXISTS (SELECT 1 FROM sales WHERE serials_id = p_serials_id) THEN 'order'
        WHEN EXISTS (SELECT 1 FROM assembly WHERE serials_id = p_serials_id) THEN 'assembly'
        WHEN EXISTS (SELECT 1 FROM service_orders WHERE serials_id = p_serials_id) THEN 'service_order'
        WHEN EXISTS (SELECT 1 FROM workshop_appointments WHERE serials_id = p_serials_id) THEN 'appointment'
        WHEN EXISTS (SELECT 1 FROM loans WHERE serials_id = p_serials_id) THEN 'loan'
        WHEN EXISTS (SELECT 1 FROM transfer_units WHERE serials_id = p_serials_id) THEN 'draft'
        WHEN EXISTS (SELECT 1 FROM resources WHERE serials_id = p_serials_id) THEN 'fleet'
        WHEN EXISTS (SELECT 1 FROM stock_count_lines WHERE serials_id = p_serials_id) THEN 'count'
        WHEN v_unit.serial_number IS NOT NULL
             AND EXISTS (SELECT 1 FROM nfe_document_items WHERE serial_number = v_unit.serial_number) THEN 'nfe' END;
    IF v_named IS NOT NULL THEN
        PERFORM mv_refuse('MV162', 'The unit is named by a document: correct that first.', v_facts || jsonb_build_object('named', v_named));
    END IF;
    PERFORM mv_post('receipt_corrected', 'purchase_items', v_entry.ref_id,
                    mv_pair(v_cell.variants_id, p_serials_id, 1, mv_cell(v_cell),
                            (SELECT mv_cell(l) FROM movement_legs l
                              WHERE l.movements_id = v_entry.id AND l.serials_id = p_serials_id AND l.qty = -1)),
                    NULLIF(trim(p_note), ''));
    UPDATE purchase_items SET qty_received = qty_received - 1 WHERE id = v_entry.ref_id;
    IF v_unit.serial_number IS NOT NULL THEN
        UPDATE serials SET serial_number = NULL WHERE id = p_serials_id;
    END IF;
    RETURN jsonb_build_object('removed', true, 'purchase_items_id', v_entry.ref_id, 'serial_number', v_unit.serial_number);
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
 WHERE p.qty <> 0 AND t.status <> 'sent' AND p.state <> 'written_off';

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
REVOKE EXECUTE ON FUNCTION public.movement_dispatch(int8), public.mv_portal_units(), public.mv_post(text, text, int8, jsonb, text, timestamp, int8, text),
       public.movement_assembly_state(int4, int8, text), public.movement_built(int4, int8), public.movement_back_to_bench(int4, int8),
       public.movement_receive(int8, int4, jsonb), public.movement_arrive(int8, int8, int4, jsonb),
       public.movement_sell(int8), public.movement_hand_over(int8), public.movement_unsell(int8, text), public.movement_return(int8, int4, text),
       public.mv_take_off(int8, int8, int4, jsonb, boolean, text, text), public.movement_not_sent(int8, int8, int4, jsonb, text),
       public.movement_lost(int8, int8, int4, jsonb, text, text), public.movement_swap(int8, int4, int4, text),
       public.mv_claimable(int4, int4, jsonb), public.claim_hold(int8, int4), public.claim_release(int8, int4),
       public.claim_sale(int8, int4), public.claim_sale_release(int8), public.claim_fleet(int8, int4), public.claim_fleet_release(int8),
       public.mv_baixa(int4, int8, boolean, int8, text), public.movement_write_off(int4, int8, text),
       public.movement_to_provider(int4, int8, int8, text), public.movement_flip(int4, int4, jsonb, jsonb, text),
       public.app_user_admin(), public.mv_lend(boolean, text, text, text, int8, int4, int4, int4, int8),
       public.mv_rental(int8, boolean), public.mv_loan(int8, boolean), public.movement_rent_out(int8), public.movement_rent_back(int8),
       public.movement_loan_out(int8), public.movement_loan_back(int8), public.mv_adjust(text, text, int8, jsonb, text, text),
       public.movement_adjust(jsonb, text, text), public.movement_count_close(int8),
       public.movement_correct(int4, int8, int4, int4, text, text), public.movement_unit_remove(int4, int8, text) FROM PUBLIC;
GRANT SELECT ON public.movements, public.movement_legs TO app_portal;
GRANT EXECUTE ON FUNCTION public.mv_portal_units() TO app_portal;
GRANT EXECUTE ON FUNCTION public.movement_dispatch(int8), public.movement_built(int4, int8), public.movement_back_to_bench(int4, int8),
      public.movement_receive(int8, int4, jsonb), public.movement_arrive(int8, int8, int4, jsonb),
      public.movement_sell(int8), public.movement_hand_over(int8), public.movement_unsell(int8, text), public.movement_return(int8, int4, text),
      public.movement_not_sent(int8, int8, int4, jsonb, text), public.movement_lost(int8, int8, int4, jsonb, text, text),
      public.movement_swap(int8, int4, int4, text), public.claim_hold(int8, int4), public.claim_release(int8, int4),
      public.claim_sale(int8, int4), public.claim_sale_release(int8), public.claim_fleet(int8, int4), public.claim_fleet_release(int8),
      public.movement_write_off(int4, int8, text), public.movement_to_provider(int4, int8, int8, text),
      public.app_user_admin(), public.movement_flip(int4, int4, jsonb, jsonb, text), public.movement_rent_out(int8),
      public.movement_rent_back(int8), public.movement_loan_out(int8), public.movement_loan_back(int8),
      public.movement_adjust(jsonb, text, text), public.movement_count_close(int8),
      public.movement_correct(int4, int8, int4, int4, text, text), public.movement_unit_remove(int4, int8, text) TO app_staff;
