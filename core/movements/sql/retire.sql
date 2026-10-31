-- The old state retired (movements-code.md §3.4.4 and §3.4.5; the second half of migration 028). It runs after
-- opening(), in the same release, once every module reads and writes through the layer: after it nothing writes the
-- old columns, and nothing can read them. Irreversible: rehearse it on a copy. All of it is one statement, so it is
-- done whole or not at all: it refuses before the opening (MV902: the journal must hold the units first), and once
-- it is done, running it again does nothing.

-- The low-stock alert, on the layer, measured on sellable (decided 2026-10-31): when what a location's till may sell
-- of a model falls to its low_stock or below, an alert opens, as stock_low_alert opened it on the old ledger, one at
-- a time per location and model.
CREATE OR REPLACE FUNCTION public.positions_low_alert() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_low      int4;
    v_name     text;
    v_sku      text;
    v_sellable int4;
BEGIN
    IF NEW.at_location_id IS NULL OR NEW.at_location_id IS DISTINCT FROM NEW.owner_location_id OR NEW.state <> 'available' THEN
        RETURN NULL;
    END IF;
    SELECT v.low_stock, i.name, v.sku INTO v_low, v_name, v_sku
      FROM variants v LEFT JOIN items i ON i.id = v.items_id
     WHERE v.id = NEW.variants_id;
    IF v_low IS NULL THEN
        RETURN NULL;
    END IF;
    v_sellable := COALESCE((SELECT qty FROM stock_sellable WHERE location_id = NEW.at_location_id AND variants_id = NEW.variants_id), 0);
    IF v_sellable > v_low OR EXISTS (SELECT 1 FROM alerts WHERE type = 'stock' AND ref_type = 'variants' AND ref_id = NEW.variants_id
                                         AND status = 'open' AND location_id = NEW.at_location_id) THEN
        RETURN NULL;
    END IF;
    INSERT INTO alerts (location_id, type, level, ref_type, ref_id, title, detail)
    VALUES (NEW.at_location_id, 'stock', CASE WHEN v_sellable <= 0 THEN 'critical' ELSE 'warning' END, 'variants', NEW.variants_id,
            CONCAT('Low stock: ', v_name, ' - ', v_sku), CONCAT('Current: ', v_sellable, ', Threshold: ', v_low));
    RETURN NULL;
END $$;
DO $retire$
DECLARE
    v_function regprocedure;
BEGIN
    IF to_regclass('public.stock_archive') IS NOT NULL THEN
        RAISE NOTICE 'The old state is retired already: nothing to do.';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.movements) THEN
        RAISE EXCEPTION USING ERRCODE = 'MV902', MESSAGE = 'Retire the old state after the opening: the journal is empty.';
    END IF;

    -- The history: kept, read-only, as the archive of what was ported. No trigger writes it any more.
    DROP TRIGGER serials_events ON public.serials;
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.serial_events FROM PUBLIC, app_staff;

    -- The old ledger: archived, read-only. Its balances view, its two triggers (the variant cache, the low-stock
    -- alert) and its kernel's functions go; the layer has them all.
    DROP VIEW public.stock_balances;
    DROP TRIGGER stock_low_alert ON public.stock;
    DROP TRIGGER stock_update_variant ON public.stock;
    FOR v_function IN SELECT p.oid::regprocedure FROM pg_proc p
                       WHERE p.pronamespace = 'public'::regnamespace
                         AND p.proname IN ('stock_low_alert', 'stock_to_variant', 'stock_transfer_dispatch', 'stock_transfer_row',
                                           'stock_transfer_on_road', 'stock_transfer_lost', 'stock_transfer_back',
                                           'stock_transfer_receive', 'serial_event_record') LOOP
        EXECUTE 'DROP FUNCTION ' || v_function;
    END LOOP;
    ALTER TABLE public.stock RENAME TO stock_archive;
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.stock_archive FROM PUBLIC, app_staff;

    -- A unit keeps its identity: its number, observations, photos, passport token, earmark and receipt line. Where
    -- it stands, whose it is and its state are its legs'. A model's stock is the positions'.
    ALTER TABLE public.serials DROP COLUMN status, DROP COLUMN location_id, DROP COLUMN transfers_id;
    ALTER TABLE public.variants DROP COLUMN stock;

    -- The low-stock alert moves to the positions.
    CREATE TRIGGER positions_low_alert AFTER INSERT OR UPDATE OF qty ON public.positions
        FOR EACH ROW EXECUTE FUNCTION public.positions_low_alert();

    -- The grants (§3.4.5): the application cannot write a movement, a position or a unit's state (layer.sql grants
    -- it SELECT alone on the journal), nor mint or delete a unit (the layer's events do). Of a unit it writes the
    -- identity, through core/serials.php.
    REVOKE INSERT, UPDATE, DELETE ON public.serials FROM app_staff;
    GRANT UPDATE (serial_number, observations, earmark_location_id, passport_token) ON public.serials TO app_staff;
END $retire$;
