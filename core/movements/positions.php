<?php
/**
 * core/movements/positions.php — the reading side of the movement layer (movements-code.md §2).
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
 * A slice of the cube: every unit's cell at $at (sql/cube.sql whereabouts()), with the waypoint its
 * documents plan for that moment. With $knownAt, the books as they stood then: only what had been
 * recorded by $knownAt. A moment ahead finds each unit's current stay with its plans.
 */
function positionsAt(PDO $pdo, DateTimeInterface $at, ?DateTimeInterface $knownAt = null, ?Select $parent = null, string $as = 'wa'): Select
{
    $select = $parent ? $parent->subSelect() : Select::new($pdo);
    $from = 'whereabouts(CAST(' . $select->bindInline($at->format('Y-m-d H:i:s')) . ' AS timestamp), CAST('
        . $select->bindInline($knownAt?->format('Y-m-d H:i:s')) . " AS timestamp)) AS {$as}";
    return $select->columns("{$as}.*")->from($from);
}

/**
 * The cube cut along any axes (sql/cube.sql cube_dots()). It always answers dots: a unit, in a place,
 * of an owner, in a state, for a stretch of time, for a reason. Leave an axis out to keep it whole;
 * give it to cut or widen:
 *   'at'       a moment; or 'between' => [from, to], either end null for open
 *   'units'    [serials_id, …]          'models'   [variants_id, …]
 *   'places'   ['location:2', 'road:55', 'customer:7', 'supplier:3', …]
 *   'customer' customers_id: every dot it takes part in
 *   'known'    a moment: the facts as the books stood then
 *
 *   positionsCube($pdo, ['at' => new DateTimeImmutable('2026-11-11 15:50')])   every angle of that moment
 *   positionsCube($pdo, ['units' => [502]])                                     every moment of that unit
 */
function positionsCube(PDO $pdo, array $axes = [], ?Select $parent = null, string $as = 'c'): Select
{
    $select = $parent ? $parent->subSelect() : Select::new($pdo);
    $stamp = fn (?DateTimeInterface $t): string => $t ? '"' . $t->format('Y-m-d H:i:s') . '"' : '';
    $time = match (true) {
        isset($axes['at']) => '[' . $stamp($axes['at']) . ',' . $stamp($axes['at']) . ']',
        isset($axes['between']) => '[' . $stamp($axes['between'][0]) . ',' . $stamp($axes['between'][1]) . ')',
        default => null,
    };
    $ids = fn (?array $list): ?string => $list === null ? null : '{' . implode(',', array_map('intval', $list)) . '}';
    $places = $axes['places'] ?? null;
    if ($places !== null) {
        foreach ($places as $place) {
            if (!preg_match('/^(location|road|customer|supplier):\d+$/', $place)) {
                throw new InvalidArgumentException("Not a place: {$place}");
            }
        }
        $places = '{' . implode(',', $places) . '}';
    }
    $args = [
        'p_time' => [$time, 'tsrange'],
        'p_units' => [$ids($axes['units'] ?? null), 'int4[]'],
        'p_models' => [$ids($axes['models'] ?? null), 'int8[]'],
        'p_places' => [$places, 'text[]'],
        'p_customer' => [$axes['customer'] ?? null, 'int4'],
        'p_known_at' => [isset($axes['known']) ? $axes['known']->format('Y-m-d H:i:s') : null, 'timestamp'],
    ];
    $call = [];
    foreach ($args as $name => [$value, $type]) {
        $call[] = "{$name} => CAST(" . $select->bindInline($value) . " AS {$type})";
    }
    return $select->columns("{$as}.*")->from('cube_dots(' . implode(', ', $call) . ") AS {$as}");
}

/** A unit's line through the cube: its stays in order, then what its documents plan from here on. */
function unitTrajectory(PDO $pdo, int $serialId): array
{
    return Select::new($pdo)->columns('ut.*')->from('unit_trajectory AS ut')
        ->where('ut.serials_id = ', $serialId)->orderBy('ut.starts', 'ut.layer')->fetchAll();
}

/** Encounters that cannot happen: two plans at once, a plan where the unit will not be, a rental of a sold unit. */
function positionsConflicts(PDO $pdo, ?Select $parent = null, string $as = 'wc'): Select
{
    return positionsFrom($pdo, $parent, "unit_waypoint_conflicts AS {$as}", $as);
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
