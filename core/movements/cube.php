<?php
/**
 * core/movements/cube.php — the consumer's door to the cube (CONSUMERS.md).
 *
 * One shape in, one shape out. In: axes. Out: dots.
 *
 * A dot:
 *   ['unit' => 504, 'model' => 100, 'layer' => 'fact', 'place' => 'location:1', 'owner' => 'location:1',
 *    'state' => 'available', 'starts' => '2026-10-31 09:12:40', 'ends' => null, 'why' => 'built',
 *    'ref' => 6, 'customer' => null]
 * why and ref say what put it there: a fact's movement (its kind and id), a plan's document. A plan has a
 * place but no owner or state. ends null: it runs on. starts = ends: an instant (two events in one second).
 *
 * The axes. Each takes a point to cut, a list to widen, or is left out to stay whole:
 *   'at'       a moment                                     'between'  [from, to), either end null
 *   'unit'     serials_id                                   'model'    variants_id
 *   'place'    'location:2', 'road:55', 'customer:7', …     'owner'    'location:1', 'customer:7', …
 *   'state'    'validating', 'available', 'written_off'     'customer' customers_id: every dot it is in
 *   'layer'    'fact' or 'plan'                             'known'    a moment: the books as they stood then
 * A moment is a DateTimeInterface or anything DateTimeImmutable reads; 'now' is the database's clock.
 */

use Atlas\Query\Select;

/** The dots along the axes given, as rows: by unit, then by time. */
function cube(PDO $pdo, array $axes = []): array
{
    return cubeSelect($pdo, $axes)->fetchAll();
}

/**
 * One unit's dot at a moment ('now' when no moment is given). With an action, the unit is advanced by that
 * event first, now, and the dot it is in afterwards is answered. A refused action throws MovementRefused,
 * its facts with it; nothing is posted.
 *
 *   cubeDot($pdo, ['unit' => 504])                                    where it is, whose, what, since when
 *   cubeDot($pdo, ['unit' => 504, 'at' => '2026-10-15 12:00'])        the same, then
 *   cubeDot($pdo, ['unit' => 504], 'built', ['assembly' => 81])       assembly passed: the dot it is in now
 */
function cubeDot(PDO $pdo, array $axes, ?string $action = null, array $with = []): ?array
{
    if (!is_int($axes['unit'] ?? null)) {
        throw new InvalidArgumentException('A single dot is one unit: give it as unit => serials_id.');
    }
    if ($action !== null) {
        if (array_keys($axes) !== ['unit']) {
            throw new InvalidArgumentException('An action happens now, to the unit alone: give it unit => serials_id only.');
        }
        $actions = cubeActions();
        if (!isset($actions[$action])) {
            throw new InvalidArgumentException("A dot has no action {$action}; it has " . implode(', ', array_keys($actions)) . '.');
        }
        [$needs, $advance] = $actions[$action];
        if ($missing = array_diff($needs, array_keys($with))) {
            throw new InvalidArgumentException("{$action} needs " . implode(', ', $missing) . '.');
        }
        $advance($pdo, $axes['unit'], $with);
    }
    unset($axes['between']);
    $axes += ['at' => 'now', 'layer' => 'fact'];
    return cubeSelect($pdo, $axes)->fetchOne() ?: null;
}

/**
 * The events a single dot can be advanced by: action => [what it needs in $with, the call]. One line per
 * event; the database holds its rules. Events of a document (a remessa's dispatch, a sale) move many dots
 * and stay on their document's function, movementDispatch() and the rest.
 */
function cubeActions(): array
{
    return [
        'built'         => [['assembly'], fn (PDO $pdo, int $unit, array $with) => movementBuilt($pdo, $unit, (int) $with['assembly'])],
        'back_to_bench' => [['assembly'], fn (PDO $pdo, int $unit, array $with) => movementBackToBench($pdo, $unit, (int) $with['assembly'])],
    ];
}

/** The dots along the axes given, as a Select: narrow it, page it, join it, or nest it in another query. */
function cubeSelect(PDO $pdo, array $axes = [], ?Select $parent = null, string $as = 'c'): Select
{
    $known = ['at', 'between', 'unit', 'model', 'place', 'owner', 'state', 'customer', 'layer', 'known'];
    if ($unknown = array_diff(array_keys($axes), $known)) {
        throw new InvalidArgumentException('Not an axis of the cube: ' . implode(', ', $unknown) . '. The axes: ' . implode(', ', $known) . '.');
    }
    if (isset($axes['at'], $axes['between'])) {
        throw new InvalidArgumentException('Time is a moment (at) or a period (between), not both.');
    }

    $select = $parent ? $parent->subSelect() : Select::new($pdo);
    $list = fn (mixed $value): array => is_array($value) ? array_values($value) : [$value];
    $bind = fn (?string $value, string $type): string => 'CAST(' . $select->bindInline($value) . " AS {$type})";
    $array = fn (string $axis, callable $each): ?string => isset($axes[$axis])
        ? '{' . implode(',', array_map($each, $list($axes[$axis]))) . '}' : null;
    $ids = fn (mixed $id): string => (string) (int) $id;
    $word = fn (mixed $w): string => '"' . addcslashes((string) $w, '"\\') . '"';
    $coordinate = fn (mixed $c): string => cubeCoordinates([(string) $c])[0];
    // a moment: 'now' is the database's clock; anything else is read here, to the second
    $moment = fn (mixed $t): string => $t === null ? 'NULL' : ($t === 'now' ? 'LOCALTIMESTAMP'
        : $bind(($t instanceof DateTimeInterface ? $t : new DateTimeImmutable($t))->format('Y-m-d H:i:s'), 'timestamp'));

    $time = 'NULL';
    if (isset($axes['at'])) {
        $time = 'tsrange(' . $moment($axes['at']) . ', ' . $moment($axes['at']) . ", '[]')";
    } elseif (isset($axes['between'])) {
        [$from, $to] = array_values($axes['between']) + [null, null];
        $time = 'tsrange(' . $moment($from) . ', ' . $moment($to) . ')';
    }

    $call = implode(', ', [
        "p_time => {$time}",
        'p_units => ' . $bind($array('unit', $ids), 'int4[]'),
        'p_models => ' . $bind($array('model', $ids), 'int8[]'),
        'p_places => ' . $bind($array('place', $coordinate), 'text[]'),
        'p_owners => ' . $bind($array('owner', $coordinate), 'text[]'),
        'p_states => ' . $bind($array('state', $word), 'text[]'),
        'p_customers => ' . $bind($array('customer', $ids), 'int4[]'),
        'p_layers => ' . $bind($array('layer', $word), 'text[]'),
        'p_known_at => ' . $moment($axes['known'] ?? null),
    ]);
    return $select->columns("{$as}.*")->from("cube_dots({$call}) AS {$as}");
}

/**
 * Encounters that cannot happen: two plans that hold one unit at once, a plan where the unit will not be,
 * a rental of a unit no location owns then. Each row names the plan, the conflict and what it meets.
 */
function cubeConflicts(PDO $pdo, ?Select $parent = null, string $as = 'wc'): Select
{
    return positionsFrom($pdo, $parent, "unit_waypoint_conflicts AS {$as}", $as);
}

/** Places and owners as the cube writes them: 'location:2', 'road:55', 'customer:7', 'supplier:3', 'books'. */
function cubeCoordinates(array $coordinates): array
{
    foreach ($coordinates as $coordinate) {
        if (!preg_match('/^(?:(?:location|road|customer|supplier):\d+|books)$/', (string) $coordinate)) {
            throw new InvalidArgumentException("Not a place or an owner of the cube: {$coordinate}");
        }
    }
    return $coordinates;
}
