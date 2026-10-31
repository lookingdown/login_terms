<?php
/**
 * core/movements/positions.php — the reading side of the movement layer (movements-code.md §2).
 *
 * The views are defined once, on the layer; the screens get them in the shapes of CONTRACT.md.
 * A list screen starts from a positions*() Select and narrows, pages, joins or nests it; a single
 * answer comes from a function here.
 *
 * This is now. Any other moment, a unit's line and the plans ahead are the cube (cube.php).
 */

use Atlas\Query\Select;

/** One unit's position: where, whose, its state and since when. Null when it has none. */
function unitPosition(PDO $pdo, int $serialId): ?array
{
    $row = positionsUnits($pdo)->where('up.serials_id = ', $serialId)->fetchOne();
    return $row ?: null;
}

/** The organisation's total per model, wherever its locations' goods stand: [variants_id => qty]. */
function stockTotal(PDO $pdo): array
{
    return Select::new($pdo)->columns('st.variants_id', 'st.qty')->from('stock_total AS st')->fetchKeyPair();
}

/** What is on a remessa's road right now, per model and state. */
function transferProgress(PDO $pdo, int $transferId): array
{
    return positionsRoad($pdo)->where('rd.transfers_id = ', $transferId)->orderBy('rd.variants_id')->fetchAll();
}

/** Per unit (unit_positions): place, owner, state, since. */
function positionsUnits(PDO $pdo, ?Select $parent = null, string $as = 'up'): Select
{
    return positionsFrom($pdo, $parent, "unit_positions AS {$as}", $as);
}

/** Per location × model: what it owns standing there, validating or available (stock_on_hand). */
function positionsOnHand(PDO $pdo, ?Select $parent = null, string $as = 'oh'): Select
{
    return positionsFrom($pdo, $parent, "stock_on_hand AS {$as}", $as);
}

/** Per location × model: what the till may sell (stock_sellable). */
function positionsSellable(PDO $pdo, ?Select $parent = null, string $as = 'ss'): Select
{
    return positionsFrom($pdo, $parent, "stock_sellable AS {$as}", $as);
}

/** What a location owns standing elsewhere: the road, a customer on rental or a loan (owned_elsewhere). */
function positionsOwnedElsewhere(PDO $pdo, ?Select $parent = null, string $as = 'oe'): Select
{
    return positionsFrom($pdo, $parent, "owned_elsewhere AS {$as}", $as);
}

/** Per remessa × model: what is on its road (road_by_transfer). */
function positionsRoad(PDO $pdo, ?Select $parent = null, string $as = 'rd'): Select
{
    return positionsFrom($pdo, $parent, "road_by_transfer AS {$as}", $as);
}

/**
 * The rows a Select would answer, counted over it as a derived table: right for a grouped
 * or DISTINCT select too, where counting by resetting its columns is not.
 */
function positionsCount(PDO $pdo, Select $select): int
{
    $rows = (clone $select)->resetOrderBy()->resetLimit()->as('c');
    return (int) Select::new($pdo)->columns('COUNT(*)')->from($rows)->fetchValue();
}

/** A Select over one view; born of $parent when it nests in the caller's query. */
function positionsFrom(PDO $pdo, ?Select $parent, string $from, string $as): Select
{
    $select = $parent ? $parent->subSelect() : Select::new($pdo);
    return $select->columns("{$as}.*")->from($from);
}

/**
 * The model lines of CONTRACT.md for these models at one location ($location null: the session's own), keyed by
 * variants_id in the order given: what it has standing there, its own, available and validating (`here`); what its
 * till may sell (`sellable`); what remessas carry to it and from it (`road`); its own standing elsewhere, out on a
 * rental or a loan or at another location (`elsewhere`). A model it has none of answers zeros.
 */
function modelLines(PDO $pdo, array $variantIds, ?int $location = null): array
{
    $ids = array_values(array_unique(array_map('intval', $variantIds)));
    if ($ids === []) {
        return [];
    }
    $location ??= (int) Select::new($pdo)->columns('app_location()')->fetchValue();
    $models = Select::new($pdo)
        ->columns('v.id', 'v.sku', 'v.items_id', 'i.name AS item_name', 'i.segment', 'i.serial', 'v.price', 'v.low_stock')
        ->from('variants AS v')->join('INNER', 'items AS i', 'i.id = v.items_id')
        ->where('v.id IN ', $ids)->fetchAll();
    $sums = Select::new($pdo);
    $l = fn (): string => 'CAST(' . $sums->bindInline($location) . ' AS int4)';
    $home = "p.at_location_id = {$l()} AND p.owner_location_id = {$l()}";
    $sums->columns('p.variants_id',
            "COALESCE(SUM(p.qty) FILTER (WHERE {$home} AND p.state = 'available'), 0) AS available",
            "COALESCE(SUM(p.qty) FILTER (WHERE p.at_location_id = {$l()} AND p.owner_location_id = {$l()} AND p.state = 'validating'), 0) AS validating",
            "COALESCE(SUM(p.qty) FILTER (WHERE t.to_location_id = {$l()} AND p.state <> 'written_off'), 0) AS road_in",
            "COALESCE(SUM(p.qty) FILTER (WHERE p.at_transfer_id IS NOT NULL AND p.owner_location_id = {$l()} AND p.state <> 'written_off'), 0) AS road_out",
            "COALESCE(SUM(p.qty) FILTER (WHERE p.owner_location_id = {$l()} AND p.at_transfer_id IS NULL
                                           AND p.at_location_id IS DISTINCT FROM {$l()} AND p.state <> 'written_off'), 0) AS elsewhere")
        ->from('positions AS p')
        ->join('LEFT', 'transfers AS t', 't.id = p.at_transfer_id')
        ->where('p.variants_id IN ', $ids)
        ->groupBy('p.variants_id');
    $at = array_column($sums->fetchAll(), null, 'variants_id');
    $sellable = positionsSellable($pdo)->resetColumns()->columns('ss.variants_id', 'ss.qty')
        ->where('ss.location_id = ', $location)->where('ss.variants_id IN ', $ids)->fetchKeyPair();

    $byId = array_column($models, null, 'id');
    $lines = [];
    foreach ($ids as $id) {
        if (!isset($byId[$id])) {
            continue;
        }
        $m = $byId[$id];
        $p = $at[$id] ?? [];
        $lines[$id] = [
            'variants_id' => $id, 'sku' => $m['sku'], 'items_id' => (int) $m['items_id'], 'item_name' => $m['item_name'],
            'segment' => $m['segment'], 'serial' => (bool) $m['serial'],
            'price' => $m['price'] === null ? null : (float) $m['price'],
            'low_stock' => $m['low_stock'] === null ? null : (int) $m['low_stock'],
            'here' => ['available' => (int) ($p['available'] ?? 0), 'validating' => (int) ($p['validating'] ?? 0)],
            'sellable' => (int) ($sellable[$id] ?? 0),
            'road' => ['in' => (int) ($p['road_in'] ?? 0), 'out' => (int) ($p['road_out'] ?? 0)],
            'elsewhere' => (int) ($p['elsewhere'] ?? 0),
        ];
    }
    return $lines;
}

