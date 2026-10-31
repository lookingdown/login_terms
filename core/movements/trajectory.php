<?php
/**
 * core/movements/trajectory.php — one unit's whole life: Rastrear, the passport, the Rastreio of an order.
 *
 * It replaces core/unitTimeline.php. The line is the cube's (its facts and its plans); the story adds the documents'
 * chapters that are no movements: the purchase, the bench's work, the service orders. Keys and parameters only:
 * a fact's words are mvKind_<kind>, a document's story_<kind>, a step's trail_<key> (i18n/movements.js).
 */

use Atlas\Query\Select;

/**
 * ['unit' => the Unit with purchase, cost and price, 'facts', 'trail', 'line' => its dots, 'events' => the story].
 * Throws when the id is no unit.
 */
function unitTrajectory(PDO $pdo, int $serialId): array
{
    $unit = unitRows($pdo, [$serialId], ['purchase', 'cost', 'price'])[0] ?? null;
    if ($unit === null) {
        throw new InvalidArgumentException("No unit {$serialId}.");
    }
    $line = cube($pdo, ['unit' => $serialId]);
    $facts = array_values(array_filter($line, fn (array $d) => $d['layer'] === 'fact'));
    $master = 'location:' . locationMasterId($pdo);
    $first = function (callable $test) use ($facts): ?string {
        foreach ($facts as $d) {
            if ($test($d)) {
                return $d['starts'];
            }
        }
        return null;
    };

    $deliveredAt = $first(fn (array $d) => $d['why'] === 'handed_over');
    $months = Select::new($pdo)->columns('warranty_months')->from('items')->where('id = ', $unit['model']['items_id'])->fetchValue();
    $months = $months === false || $months === null ? null : (int) $months;
    $about = [
        'where' => $unit['position']['where'] ?? null,
        'since' => $unit['position']['since'] ?? null,
        'entered_stock' => $first(fn (array $d) => $d['state'] === 'available' && str_starts_with($d['place'], 'location:')),
        'cost' => $unit['cost'], 'price' => $unit['price'],
        'delivered_at' => $deliveredAt,
        'warranty_months' => $months,
        'warranty_until' => $deliveredAt !== null && $months
            ? (new DateTimeImmutable($deliveredAt))->modify("+{$months} months")->format('Y-m-d') : null,
    ];

    // the five steps, read off the line; the first not done is where it waits, and what for
    $was = fn (callable $test) => array_filter($facts, $test) !== [];
    $done = [
        'supplier' => $unit['purchase'] !== null || $was(fn (array $d) => $d['why'] === 'received'),
        'central' => $was(fn (array $d) => $d['place'] === $master),
        'assembly' => $was(fn (array $d) => $d['state'] === 'available'),
        'shop' => $was(fn (array $d) => str_starts_with($d['place'], 'road:')
            || (str_starts_with($d['place'], 'location:') && $d['place'] !== $master)),
        'customer' => $was(fn (array $d) => str_starts_with($d['owner'], 'customer:')),
    ];
    $trail = [];
    $current = null;
    foreach ($done as $key => $isDone) {
        $state = $isDone ? 'done' : ($current === null ? 'current' : 'todo');
        $current ??= $isDone ? null : $key;
        $trail[] = ['key' => $key, 'state' => $state, 'sub' => $state === 'current' ? match ($key) {
            'assembly' => ['key' => ($unit['bench']['stage'] ?? null) === 'in_process' ? 'on_bench' : 'waiting_assembly', 'params' => []],
            'shop' => $unit['earmark'] !== null ? ['key' => 'earmarked', 'params' => ['name' => $unit['earmark']['name']]]
                : ['key' => 'waiting_shop', 'params' => []],
            'customer' => ['key' => 'for_sale', 'params' => []],
            default => null,
        } : null];
    }

    return ['unit' => $unit, 'facts' => $about, 'trail' => $trail, 'line' => $line,
            'events' => unitStory($pdo, $serialId, $facts, $unit)];
}

/**
 * The story: each fact on the line, with the document behind its movement, and beside them the documents' own
 * chapters, all in time order (an undated one last): [{at, source: movement | document, kind, ref, params}].
 */
function unitStory(PDO $pdo, int $serialId, array $facts, array $unit): array
{
    $refs = [];
    $movementIds = array_values(array_unique(array_column($facts, 'ref')));
    if ($movementIds) {
        foreach (Select::new($pdo)->columns('id', 'ref_type', 'ref_id')->from('movements')->where('id IN ', $movementIds)->fetchAll() as $m) {
            $refs[(int) $m['id']] = $m['ref_type'] === null ? ['type' => 'movements', 'id' => (int) $m['id']]
                : ['type' => $m['ref_type'], 'id' => (int) $m['ref_id']];
        }
    }
    $events = [];
    foreach ($facts as $d) {
        $events[] = ['at' => $d['starts'], 'source' => 'movement', 'kind' => $d['why'], 'ref' => $refs[$d['ref']] ?? null,
                     'params' => ['place' => $d['place'], 'owner' => $d['owner'], 'state' => $d['state']]];
    }
    $document = function (?string $at, string $kind, string $type, int $id, array $params = []) use (&$events): void {
        $events[] = ['at' => $at, 'source' => 'document', 'kind' => $kind, 'ref' => ['type' => $type, 'id' => $id], 'params' => $params];
    };

    if ($unit['purchase'] !== null) {
        $order = Select::new($pdo)->columns('created_at', 'supplier_name', 'nf')->from('purchases')
            ->where('id = ', $unit['purchase']['purchases_id'])->fetchOne();
        if ($order) {
            $document($order['created_at'], 'purchase', 'purchases', $unit['purchase']['purchases_id'],
                      ['supplier' => $order['supplier_name'], 'nf' => $order['nf']]);
        }
    }
    foreach (Select::new($pdo)->columns('a.id', 'a.created_at', 'a.revised_at', 'a.condition_state', 'a.condition_notes', 'u.name AS technician')
        ->from('assembly AS a')->join('LEFT', 'users AS u', 'u.id = a.users_id')
        ->where('a.serials_id = ', $serialId)->orderBy('a.id')->fetchAll() as $job) {
        $document($job['created_at'], 'assembly_started', 'assembly', (int) $job['id'], ['technician' => $job['technician']]);
        if ($job['condition_state'] !== null && $job['condition_state'] !== 'complete') {
            $document($job['created_at'], 'assembly_issue', 'assembly', (int) $job['id'],
                      ['condition' => $job['condition_state'], 'notes' => $job['condition_notes']]);
        }
        if ($job['revised_at'] !== null) {
            $document($job['revised_at'], 'assembly_revised', 'assembly', (int) $job['id'], ['technician' => $job['technician']]);
        }
    }
    foreach (Select::new($pdo)->columns('so.id', 'so.created_at', 'so.completed_date', 'so.service_status', 'u.name AS technician')
        ->from('service_orders AS so')->join('LEFT', 'users AS u', 'u.id = so.users_id')
        ->where('so.serials_id = ', $serialId)->orderBy('so.id')->fetchAll() as $so) {
        $document($so['created_at'], 'service_opened', 'service_orders', (int) $so['id'], ['so' => (int) $so['id'], 'status' => $so['service_status']]);
        if ($so['completed_date'] !== null) {
            $document($so['completed_date'], 'service_done', 'service_orders', (int) $so['id'], ['so' => (int) $so['id'], 'technician' => $so['technician']]);
        }
    }

    // in time order, an undated one last; two at one moment keep the order they were told in
    $order = array_keys($events);
    usort($order, fn (int $a, int $b) => [$events[$a]['at'] === null, (string) $events[$a]['at'], $a]
                                     <=> [$events[$b]['at'] === null, (string) $events[$b]['at'], $b]);
    return array_map(fn (int $i) => $events[$i], $order);
}
