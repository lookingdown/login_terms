-- Before the opening: the draft's B0 diagnostics and reconciliation checks (DESIGN_PRINCIPLES §8, §10)
-- and the discrepancy classes of movements-code.md §3.4.1, on today's tables. Every check must return
-- no rows; each row is a fact to settle before the layer opens (rule §0.2: built for the correct shape).
\pset footer off

\echo '== D1. negative stock (draft B0): a balance below zero at a place'
SELECT location_id, variants_id, stock FROM stock_balances WHERE stock < 0 ORDER BY 1, 2;

\echo '== D2. a remessa line whose two sides do not balance (draft v_recon_transfer_balance). Today the departure'
\echo '        is booked on the transfer and the arrival on the shop purchase line (transfer_items.shop_purchase_items_id)'
SELECT t.id AS transfers_id, t.status, ti.id AS line_id, ti.variants_id, ti.qty AS line_qty,
       COALESCE(out.qty, 0) AS left_source, COALESCE(arr.qty, 0) AS arrived, COALESCE(road.qty, 0) AS on_road
  FROM transfer_items ti
  JOIN transfers t ON t.id = ti.transfers_id
  LEFT JOIN LATERAL (SELECT SUM(st.qty) AS qty FROM stock st WHERE st.ref_type = 'transfers' AND st.ref_id = t.id
                        AND st.variants_id = ti.variants_id AND st.location_id = t.location_id) out ON true
  LEFT JOIN LATERAL (SELECT SUM(st.qty) AS qty FROM stock st WHERE st.ref_type = 'purchase_items'
                        AND st.ref_id = ti.shop_purchase_items_id) arr ON true
  LEFT JOIN LATERAL (SELECT SUM(st.qty) AS qty FROM stock st WHERE st.location_id IS NULL AND st.ref_type = 'transfers'
                        AND st.ref_id = t.id AND st.variants_id = ti.variants_id) road ON true
 WHERE t.status IN ('sent', 'received')
   AND COALESCE(out.qty, 0) + COALESCE(arr.qty, 0) + COALESCE(road.qty, 0) <> 0
 ORDER BY 1, 3;

\echo '== D3. ghost road rows (draft B0): something still on the road of a remessa that is not sent'
SELECT r.ref_id AS transfers_id, t.status, r.variants_id, SUM(r.qty) AS on_road
  FROM stock r LEFT JOIN transfers t ON t.id = r.ref_id
 WHERE r.location_id IS NULL
 GROUP BY r.ref_id, t.status, r.variants_id
HAVING SUM(r.qty) <> 0 AND t.status IS DISTINCT FROM 'sent'
 ORDER BY 1, 3;

\echo '== D4. a serial-tracked balance that is not its units (draft B0 mixed serialized/bulk; class 1)'
WITH units AS (
    SELECT location_id, variants_id, count(*) AS units
      FROM serials WHERE status IN ('stock', 'assembly', 'returned') GROUP BY 1, 2)
SELECT COALESCE(b.location_id, u.location_id) AS location_id, COALESCE(b.variants_id, u.variants_id) AS variants_id,
       COALESCE(b.stock, 0) AS balance, COALESCE(u.units, 0) AS units
  FROM (SELECT sb.* FROM stock_balances sb JOIN variants v ON v.id = sb.variants_id JOIN items i ON i.id = v.items_id
         WHERE i.serial AND sb.location_id IS NOT NULL) b
  FULL JOIN units u ON u.location_id = b.location_id AND u.variants_id = b.variants_id
 WHERE COALESCE(b.stock, 0) <> COALESCE(u.units, 0)
 ORDER BY 1, 2;

\echo '== D5. a unit sold on no live line (class 4)'
SELECT s.id AS serials_id, s.serial_number, s.location_id
  FROM serials s
 WHERE s.status = 'sold'
   AND NOT EXISTS (SELECT 1 FROM sales sa JOIN orders o ON o.id = sa.orders_id
                    WHERE sa.serials_id = s.id AND sa.status NOT IN ('cancelled', 'refunded') AND sa.deleted_at IS NULL
                      AND o.status NOT IN ('cancelled', 'refunded', 'voided') AND o.deleted_at IS NULL)
 ORDER BY 1;

\echo '== D6. a chassis twice once normalised (class 5); ci_ai refuses a regular expression, so the C collation'
SELECT upper(regexp_replace(serial_number COLLATE "C", '[^A-Za-z0-9]', '', 'g')) AS chassis,
       array_agg(id ORDER BY id) AS serials_ids
  FROM serials WHERE serial_number IS NOT NULL AND serial_number <> ''
 GROUP BY 1 HAVING count(*) > 1 ORDER BY 1;

\echo '== D7. a bike that left without its unit (class 3): a sale of a serial-tracked model on a line with no unit'
SELECT st.id AS stock_id, st.location_id, st.variants_id, st.qty, sa.id AS sales_id, sa.orders_id
  FROM stock st
  JOIN sales sa ON st.ref_type = 'sales' AND sa.id = st.ref_id
  JOIN variants v ON v.id = st.variants_id JOIN items i ON i.id = v.items_id
 WHERE i.serial AND st.type = 'sale' AND sa.serials_id IS NULL
 ORDER BY 1;

\echo '== D8. a remessa line of bikes without the units it carried (class 3 on the road). A unit leaves'
\echo '        serials.transfers_id on arrival, so the trip is read from serial_events'
SELECT ti.transfers_id, t.status, ti.variants_id, SUM(ti.qty) AS line_qty, COALESCE(MAX(u.units), 0) AS units_that_travelled
  FROM transfer_items ti
  JOIN transfers t ON t.id = ti.transfers_id
  JOIN variants v ON v.id = ti.variants_id JOIN items i ON i.id = v.items_id
  LEFT JOIN LATERAL (SELECT count(DISTINCT e.serials_id) AS units FROM serial_events e
                      WHERE e.variants_id = ti.variants_id
                        AND (e.transfers_id = ti.transfers_id OR e.from_transfers_id = ti.transfers_id)) u ON true
 WHERE i.serial AND t.status IN ('sent', 'received')
 GROUP BY ti.transfers_id, t.status, ti.variants_id
HAVING SUM(ti.qty) <> COALESCE(MAX(u.units), 0)
 ORDER BY 1, 3;

\echo '== D9. a unit whose story does not end where it stands (§3.4.2 stops the opening): its last event and,'
\echo '        for a sold unit, its live sale line, disagree with its row'
WITH last AS (
    SELECT DISTINCT ON (serials_id) serials_id, to_status, location_id, transfers_id, event, happened_at
      FROM serial_events ORDER BY serials_id, at DESC),
live_sale AS (
    SELECT DISTINCT sa.serials_id FROM sales sa JOIN orders o ON o.id = sa.orders_id
     WHERE sa.serials_id IS NOT NULL AND sa.status NOT IN ('cancelled', 'refunded') AND sa.deleted_at IS NULL
       AND o.status NOT IN ('cancelled', 'refunded', 'voided') AND o.deleted_at IS NULL)
SELECT s.id AS serials_id, s.status, s.location_id, s.transfers_id,
       l.event AS last_event, l.to_status, l.location_id AS event_location_id, (ls.serials_id IS NOT NULL) AS live_sale
  FROM serials s
  LEFT JOIN last l ON l.serials_id = s.id
  LEFT JOIN live_sale ls ON ls.serials_id = s.id
 WHERE l.serials_id IS NULL
    OR l.location_id IS DISTINCT FROM s.location_id
    OR l.transfers_id IS DISTINCT FROM s.transfers_id
    OR (l.to_status IS DISTINCT FROM s.status AND NOT (s.status = 'sold' AND ls.serials_id IS NOT NULL))
 ORDER BY 1;

\echo '== D10. a unit in transit on a remessa that is not on the road'
SELECT s.id AS serials_id, s.serial_number, s.transfers_id, t.status
  FROM serials s LEFT JOIN transfers t ON t.id = s.transfers_id
 WHERE s.status = 'transit' AND t.status IS DISTINCT FROM 'sent'
 ORDER BY 1;

\echo '== the legacy words the opening must map (code §3.4.2), with how many units carry each'
SELECT status, count(*) AS units FROM serials GROUP BY status ORDER BY 2 DESC;
