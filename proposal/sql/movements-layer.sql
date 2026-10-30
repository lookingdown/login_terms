-- The movement layer (movements-code.md §3.1 and §3.3): its tables, the refusal helper, and
-- movement_dispatch as the pattern every event function follows. Step B: nothing calls it yet.
-- Runs on imobee (PostgreSQL 18) after today's schema.

-- A remessa draft's units: the draft's own rows, replacing serials.transfers_id (code §3.3).
CREATE TABLE public.transfer_units (
    transfers_id int8 NOT NULL REFERENCES public.transfers ON DELETE CASCADE,
    serials_id   int4 NOT NULL REFERENCES public.serials,
    PRIMARY KEY (transfers_id, serials_id)
);

-- One row per business event.
CREATE TABLE public.movements (
    id          int8 GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind        text COLLATE public.ci_ai NOT NULL CHECK (kind IN (
                    'received', 'receipt_corrected', 'built', 'back_to_bench', 'dispatched', 'arrived',
                    'not_sent', 'lost', 'swapped', 'flipped', 'sold', 'handed_over', 'sale_undone',
                    'returned', 'traded_in', 'rented', 'rental_back', 'loaned', 'loan_back',
                    'workshop_in', 'workshop_out', 'written_off', 'to_provider', 'adjusted', 'counted',
                    'corrected', 'opening')),
    occurred_at timestamp(0) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    recorded_at timestamp(0) NOT NULL DEFAULT CURRENT_TIMESTAMP,
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
        PERFORM mv_refuse('MV001', 'Nenhum usuário nesta sessão: entre pelo login.');
    END IF;
    RETURN v::integer;
END $$;

-- Event 5, dispatched: (A·A·s) → (r·A·s), the draft's units one by one and the counted lines by quantity.
-- The module has written its documents and set the remessa 'sent', as 009 expects.
CREATE FUNCTION public.movement_dispatch(p_transfers_id int8) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     int4 := mv_user();
    v_transfer transfers%ROWTYPE;
    v_movement int8;
    v_unit     record;
    v_cell     movement_legs%ROWTYPE;
    v_line     record;
    v_have     int4;
    v_legs     int4 := 0;
    v_facts    jsonb := jsonb_build_object('transfers_id', p_transfers_id);
BEGIN
    IF NOT app_at_master() THEN
        PERFORM mv_refuse('MV010', 'Uma remessa sai da matriz.', v_facts);
    END IF;
    SELECT * INTO v_transfer FROM transfers WHERE id = p_transfers_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM mv_refuse('MV011', 'Remessa não encontrada.', v_facts);
    END IF;
    IF v_transfer.status <> 'sent' THEN
        PERFORM mv_refuse('MV012', format('A remessa %s está como %s, não enviada.', p_transfers_id, v_transfer.status), v_facts);
    END IF;
    IF EXISTS (SELECT 1 FROM movement_legs WHERE at_transfer_id = p_transfers_id) THEN
        PERFORM mv_refuse('MV013', format('A remessa %s já está na estrada.', p_transfers_id), v_facts);
    END IF;

    INSERT INTO movements (kind, users_id, ref_type, ref_id)
    VALUES ('dispatched', v_user, 'transfers', p_transfers_id)
    RETURNING id INTO v_movement;

    -- the units the draft holds, locked in id order; each leaves the cell its last +1 leg put it in
    FOR v_unit IN SELECT s.id, s.variants_id
                    FROM transfer_units tu JOIN serials s ON s.id = tu.serials_id
                   WHERE tu.transfers_id = p_transfers_id
                   ORDER BY s.id FOR UPDATE OF s LOOP
        SELECT * INTO v_cell FROM movement_legs
         WHERE serials_id = v_unit.id AND qty = 1 ORDER BY id DESC LIMIT 1;
        IF NOT FOUND OR v_cell.at_location_id IS DISTINCT FROM v_transfer.location_id
                     OR v_cell.owner_location_id IS DISTINCT FROM v_transfer.location_id THEN
            PERFORM mv_refuse('MV014', 'A moto não está no estoque de quem envia.',
                              v_facts || jsonb_build_object('serials_id', v_unit.id));
        END IF;
        INSERT INTO movement_legs (movements_id, variants_id, serials_id, qty,
                                   at_location_id, at_transfer_id, owner_location_id, state)
        VALUES (v_movement, v_unit.variants_id, v_unit.id, -1, v_transfer.location_id, NULL, v_transfer.location_id, v_cell.state),
               (v_movement, v_unit.variants_id, v_unit.id,  1, NULL, p_transfers_id, v_transfer.location_id, v_cell.state);
        v_legs := v_legs + 2;
    END LOOP;

    FOR v_line IN SELECT ti.variants_id, SUM(ti.qty)::int4 AS qty, bool_or(i.serial) AS serial, bool_and(i.sellable) AS sellable
                    FROM transfer_items ti
                    JOIN variants v ON v.id = ti.variants_id
                    JOIN items i ON i.id = v.items_id
                   WHERE ti.transfers_id = p_transfers_id
                   GROUP BY ti.variants_id ORDER BY ti.variants_id LOOP
        IF NOT v_line.sellable THEN
            PERFORM mv_refuse('MV015', 'Materiais não entram nos movimentos.',
                              v_facts || jsonb_build_object('variants_id', v_line.variants_id));
        END IF;
        IF v_line.serial THEN
            -- a bike line leaves only with its units
            IF v_line.qty <> (SELECT count(*) FROM transfer_units tu JOIN serials s ON s.id = tu.serials_id
                               WHERE tu.transfers_id = p_transfers_id AND s.variants_id = v_line.variants_id) THEN
                PERFORM mv_refuse('MV016', 'Cada moto da remessa precisa da sua unidade.',
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
            PERFORM mv_refuse('MV017', format('Há %s em estoque para enviar %s.', v_have, v_line.qty),
                              v_facts || jsonb_build_object('variants_id', v_line.variants_id, 'have', v_have));
        END IF;
        INSERT INTO movement_legs (movements_id, variants_id, qty, at_location_id, at_transfer_id, owner_location_id, state)
        VALUES (v_movement, v_line.variants_id, -v_line.qty, v_transfer.location_id, NULL, v_transfer.location_id, 'available'),
               (v_movement, v_line.variants_id,  v_line.qty, NULL, p_transfers_id, v_transfer.location_id, 'available');
        v_legs := v_legs + 2;
    END LOOP;

    RETURN jsonb_build_object('legs', v_legs);
END $$;

-- The unit's position on the layer (the step-C definition; step A defines the same columns on today's tables).
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

-- Grants: the application reads, and posts only through the functions (code §3.1).
REVOKE ALL ON public.movements, public.movement_legs, public.positions, public.transfer_units FROM PUBLIC;
GRANT SELECT ON public.movements, public.movement_legs, public.positions, public.transfer_units, public.unit_positions,
      public.stock_on_hand, public.stock_sellable, public.owned_elsewhere, public.road_by_transfer, public.stock_total TO app_staff;
REVOKE EXECUTE ON FUNCTION public.movement_dispatch(int8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.movement_dispatch(int8) TO app_staff;
