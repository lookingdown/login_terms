<?php
/**
 * core/positions.php — the reading side of the movement layer (movements-code.md §2).
 *
 * The views are the contract: the same names, columns and answers on today's tables (step A)
 * and on the layer (step C). A list screen starts from a positions*() Select and narrows,
 * pages, joins or nests it; a single answer comes from a function here.
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
