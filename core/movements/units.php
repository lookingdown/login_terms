<?php
/**
 * core/movements/units.php — a unit as every screen gets it (CONTRACT.md, the Unit), its word, and the units list.
 *
 * It replaces core/serialState.php and core/stockUnits.php. The position is the layer's (the cube's fact now), and
 * nothing here is a word for people: keys and parameters, which the module's i18n turns into words
 * (i18n/movements.js: unitWord_<word>, place_<key>, servicePhase_<phase>).
 */

use Atlas\Query\Select;

/** A service order's phase from its status: received, in_work or finished; null once completed or cancelled. */
function servicePhase(?string $status): ?string
{
    return match ($status) {
        'receiving', 'pending' => 'received',
        'diagnosing', 'awaiting_authorization', 'in_progress', 'waiting_parts' => 'in_work',
        'ready', 'delivery_scheduled' => 'finished',
        default => null,
    };
}

/**
 * A unit's word, one key of the vocabulary (CONTRACT.md, Word). Precedence: written off; the workshop (an open
 * service order, until step F makes the workshop a place); then where it stands and what holds it.
 */
function unitWord(?array $position, ?array $claim = null, ?array $bench = null, ?array $service = null, ?array $earmark = null): string
{
    if ($position === null) {
        return 'unknown';
    }
    if ($position['state'] === 'written_off') {
        return 'written_off';
    }
    if ($position['why'] === 'receipt_corrected') {
        return 'removed';                       // taken back from its receipt: it never was
    }
    if ($service !== null) {
        return 'workshop';
    }
    $placeKind = strtok($position['place'], ':');
    $ownerKind = strtok($position['owner'], ':');
    return match (true) {
        $placeKind === 'road' => 'transit',
        $placeKind === 'supplier' => 'provider',
        $placeKind === 'customer' && $ownerKind === 'customer' => 'delivered',
        $placeKind === 'customer' => $position['why'] === 'loaned' ? 'loaned' : 'rented',
        $placeKind === 'location' && $ownerKind === 'customer' => 'sold',
        $placeKind === 'location' && $position['place'] === $position['owner'] => unitWordAtHome($position['state'], $claim, $bench, $earmark),
        default => 'unknown',
    };
}

/** On its owner's own floor: the bench by its job's stage; the stock by what holds it. */
function unitWordAtHome(string $state, ?array $claim, ?array $bench, ?array $earmark): string
{
    if ($state === 'validating') {
        return match ($bench['stage'] ?? null) {
            'revised' => 'unboxed',
            'in_process' => 'assembling',
            default => 'boxed',
        };
    }
    return match (true) {
        ($claim['kind'] ?? null) === 'draft' => 'held',
        ($claim['kind'] ?? null) === 'order' => 'reserved',
        ($claim['kind'] ?? null) === 'fleet' => 'fleet',
        $earmark !== null => 'assigned',
        ($bench['stage'] ?? null) === 'ready' => 'built',
        default => 'stock',
    };
}

/**
 * Units, as every screen gets them, in the order of $ids: identity, model, position (the cube's fact now, with
 * its `where`), word, claim, bench, service and earmark. $with adds document facts: 'purchase', 'cost', 'price'.
 * An id that is no unit is left out.
 */
function unitRows(PDO $pdo, array $ids, array $with = []): array
{
    $ids = array_values(array_unique(array_map('intval', $ids)));
    if (!$ids) {
        return [];
    }
    $rows = array_column(Select::new($pdo)
        ->columns('s.id', 's.serial_number', 's.observations', 's.earmark_location_id', 's.purchase_items_id',
                  's.variants_id', 'v.sku', 'v.price', 'i.id AS items_id', 'i.name AS item_name', 'i.segment')
        ->from('serials AS s')
        ->join('INNER', 'variants AS v', 'v.id = s.variants_id')
        ->join('INNER', 'items AS i', 'i.id = v.items_id')
        ->where('s.id IN ', $ids)
        ->fetchAll(), null, 'id');

    $dots = array_column(cube($pdo, ['unit' => $ids, 'at' => 'now', 'layer' => 'fact']), null, 'unit');
    $where = placeWhere($pdo, array_column($dots, 'place'));

    // what holds each, in the word's precedence (a draft, an order, the fleet): the first comes last, so it is kept
    $claims = [];
    foreach (Select::new($pdo)->columns('uc.serials_id', 'uc.kind', 'uc.ref_type', 'uc.ref_id')->from('unit_claims AS uc')
        ->where('uc.serials_id IN ', $ids)->orderBy("array_position(ARRAY['draft', 'order', 'fleet'], uc.kind) DESC")
        ->fetchAll() as $c) {
        $claims[(int) $c['serials_id']] = ['kind' => $c['kind'], 'ref' => ['type' => $c['ref_type'], 'id' => (int) $c['ref_id']]];
    }
    $bench = [];
    foreach (Select::new($pdo)->columns('DISTINCT ON (a.serials_id) a.serials_id', 'a.id', 'a.stage')->from('assembly AS a')
        ->where('a.serials_id IN ', $ids)->where("a.stage NOT IN ('delivered', 'cancelled')")
        ->orderBy('a.serials_id', 'a.id DESC')->fetchAll() as $b) {
        $bench[(int) $b['serials_id']] = ['assembly_id' => (int) $b['id'], 'stage' => $b['stage']];
    }
    $service = [];
    foreach (Select::new($pdo)->columns('DISTINCT ON (so.serials_id) so.serials_id', 'so.id', 'so.service_status')
        ->from('service_orders AS so')->where('so.serials_id IN ', $ids)
        ->where("so.service_status NOT IN ('completed', 'cancelled')")
        ->where('(so.scheduled_date IS NULL OR so.scheduled_date <= CURRENT_DATE)')   // its day has come: it is there
        ->orderBy('so.serials_id', 'so.id DESC')->fetchAll() as $o) {
        $service[(int) $o['serials_id']] = ['service_orders_id' => (int) $o['id'], 'status' => $o['service_status'],
                                            'phase' => servicePhase($o['service_status'])];
    }
    $names = locationNames($pdo);

    $lines = $arrivals = [];
    if (array_intersect(['purchase', 'cost'], $with)) {
        $lineIds = array_values(array_filter(array_map('intval', array_column($rows, 'purchase_items_id'))));
        $lines = $lineIds ? array_column(Select::new($pdo)
            ->columns('pi.id', 'pi.purchases_id', 'pi.unit_cost', 'pi.landed_unit_cost', 'p.nf', 'p.supplier_name', 'p.received')
            ->from('purchase_items AS pi')->join('INNER', 'purchases AS p', 'p.id = pi.purchases_id')
            ->where('pi.id IN ', $lineIds)->fetchAll(), null, 'id') : [];
        // a unit that came by remessa cost the location what the remessa charged for it
        $arrivals = Select::new($pdo)
            ->columns('DISTINCT ON (l.serials_id) l.serials_id', 'ti.unit_price')
            ->from('movement_legs AS l')
            ->join('INNER', 'movements AS m', "m.id = l.movements_id AND m.kind = 'arrived' AND m.ref_type = 'transfers'")
            ->join('INNER', 'transfer_items AS ti', 'ti.transfers_id = m.ref_id AND ti.variants_id = l.variants_id')
            ->where('l.serials_id IN ', $ids)->where('l.qty = 1')
            ->orderBy('l.serials_id', 'l.id DESC')->fetchKeyPair();
    }

    $units = [];
    foreach ($ids as $id) {
        if (!isset($rows[$id])) {
            continue;
        }
        $r = $rows[$id];
        $dot = $dots[$id] ?? null;
        $position = $dot === null ? null : ['place' => $dot['place'], 'owner' => $dot['owner'], 'state' => $dot['state'],
            'since' => $dot['starts'], 'why' => $dot['why'], 'where' => $where[$dot['place']]];
        $claim = $position !== null && str_starts_with($position['owner'], 'location:') ? ($claims[$id] ?? null) : null;
        $earmark = $r['earmark_location_id'] === null ? null
            : ['location_id' => (int) $r['earmark_location_id'], 'name' => $names[(int) $r['earmark_location_id']] ?? null];
        $unit = [
            'id' => $id, 'serial_number' => $r['serial_number'], 'observations' => $r['observations'],
            'model' => ['variants_id' => (int) $r['variants_id'], 'sku' => $r['sku'], 'items_id' => (int) $r['items_id'],
                        'item_name' => $r['item_name'], 'segment' => $r['segment']],
            'position' => $position,
            'word' => unitWord($position, $claim, $bench[$id] ?? null, $service[$id] ?? null, $earmark),
            'claim' => $claim, 'bench' => $bench[$id] ?? null, 'service' => $service[$id] ?? null, 'earmark' => $earmark,
        ];
        $line = $lines[(int) $r['purchase_items_id']] ?? null;
        if (in_array('purchase', $with, true)) {
            $unit['purchase'] = $line === null ? null : ['purchases_id' => (int) $line['purchases_id'], 'purchase_items_id' => (int) $line['id'],
                'nf' => $line['nf'], 'supplier_name' => $line['supplier_name'], 'arrived' => $line['received']];
        }
        if (in_array('cost', $with, true)) {
            $paid = $arrivals[$id] ?? ($line === null ? null : ((float) $line['landed_unit_cost'] ?: $line['unit_cost']));
            $unit['cost'] = $paid === null ? null : (float) $paid;
        }
        if (in_array('price', $with, true)) {
            $unit['price'] = $r['price'] === null ? null : (float) $r['price'];
        }
        $units[] = $unit;
    }
    return $units;
}

/**
 * One location's units, a page of them (Estoque atual · Pelo chassi). $location null: the session's own.
 *   $in: scope (current | all), word, search, variants_id, page, pageSize
 * current: standing there, its own anywhere, or on a road to it. all: every unit whose line passed through it.
 * Answers ['data' => Units with purchase, cost and price, 'meta' => the page with scope, scopeTotal and counts per word].
 */
function stockUnitsList(PDO $pdo, array $in, ?int $location = null): array
{
    $location ??= (int) Select::new($pdo)->columns('app_location()')->fetchValue();
    $here = "location:{$location}";
    $scope = ($in['scope'] ?? 'current') === 'all' ? 'all' : 'current';

    $candidates = unitCandidates($pdo, $in);
    $dots = cubeSelect($pdo, $scope === 'current' ? ['at' => 'now', 'layer' => 'fact'] : ['layer' => 'fact'], $candidates)
        ->resetColumns()->columns('c.unit')
        ->join('LEFT', 'transfers AS t', "c.place = 'road:' || t.id")
        ->where('(c.place = ', $here)->catWhere(' OR c.owner = ', $here);
    if ($scope === 'current') {
        $dots->catWhere(' OR t.to_location_id = ', $location);
    }
    $dots->catWhere(')');
    $candidates->where('s.id IN ', $dots);
    return unitsPage($pdo, $candidates, $in, ['scope' => $scope]);
}

/**
 * Every unit of the organisation (Unidades), a page of them: $in as stockUnitsList()'s, without a scope. A seat sees
 * the units RLS lets it see; the master, all of them.
 */
function unitsList(PDO $pdo, array $in): array
{
    return unitsPage($pdo, unitCandidates($pdo, $in), $in, ['scope' => 'organisation']);
}

/** The units a list starts from: serials, narrowed by $in's search (number, SKU, name; 2 characters) and model. */
function unitCandidates(PDO $pdo, array $in): Select
{
    $candidates = Select::new($pdo)->columns('s.id')->from('serials AS s')
        ->join('INNER', 'variants AS v', 'v.id = s.variants_id')
        ->join('INNER', 'items AS i', 'i.id = v.items_id');
    $search = trim((string) ($in['search'] ?? ''));
    if (mb_strlen($search) >= 2) {
        $like = '%' . $search . '%';
        $candidates->where('(s.serial_number LIKE ', $like)->catWhere(' OR v.sku LIKE ', $like)
            ->catWhere(' OR i.name LIKE ', $like)->catWhere(')');
    }
    if ((int) ($in['variants_id'] ?? 0) > 0) {
        $candidates->where('s.variants_id = ', (int) $in['variants_id']);
    }
    return $candidates;
}

/**
 * A page of Units (with purchase, cost and price) from a candidates Select, newest first, filtered by $in's word;
 * the page counts every candidate's word (scopeTotal, counts) beside $meta.
 */
function unitsPage(PDO $pdo, Select $candidates, array $in, array $meta): array
{
    $word = (string) ($in['word'] ?? '');
    $page = max(1, (int) ($in['page'] ?? 1));
    $pageSize = max(1, min(100, (int) ($in['pageSize'] ?? 30)));
    $units = unitRows($pdo, array_map('intval', $candidates->orderBy('s.created_at DESC', 's.id DESC')->fetchColumn()),
                      ['purchase', 'cost', 'price']);
    $counts = array_count_values(array_column($units, 'word'));
    $listed = $word === '' ? $units : array_values(array_filter($units, fn (array $u) => $u['word'] === $word));
    $totalPages = max(1, (int) ceil(count($listed) / $pageSize));
    $page = min($page, $totalPages);
    return [
        'data' => array_slice($listed, ($page - 1) * $pageSize, $pageSize),
        'meta' => [
            'totalRows' => count($listed), 'totalPages' => $totalPages, 'currentPage' => $page,
            'previousPage' => $page > 1 ? $page - 1 : null, 'nextPage' => $page < $totalPages ? $page + 1 : null,
        ] + $meta + ['scopeTotal' => count($units), 'counts' => $counts],
    ];
}

/**
 * Places as people read them: coordinate => ['key' => master | location | road | customer | supplier | books,
 * 'params' => the names its words need]. The words are the i18n's (place_<key>).
 */
function placeWhere(PDO $pdo, array $places): array
{
    $places = array_values(array_unique($places));
    $wanted = ['road' => [], 'customer' => [], 'supplier' => []];
    foreach ($places as $place) {
        [$kind, $id] = explode(':', $place) + [1 => null];
        if (isset($wanted[$kind])) {
            $wanted[$kind][] = (int) $id;
        }
    }
    $names = locationNames($pdo);
    $master = locationMasterId($pdo);
    $roads = $wanted['road'] ? Select::new($pdo)->columns('id', 'to_location_id')->from('transfers')->where('id IN ', $wanted['road'])->fetchKeyPair() : [];
    $customers = $wanted['customer'] ? Select::new($pdo)->columns('id', 'full_name')->from('customers')->where('id IN ', $wanted['customer'])->fetchKeyPair() : [];
    $suppliers = $wanted['supplier'] ? Select::new($pdo)->columns('id', 'name')->from('suppliers')->where('id IN ', $wanted['supplier'])->fetchKeyPair() : [];

    $where = [];
    foreach ($places as $place) {
        [$kind, $id] = explode(':', $place) + [1 => null];
        $id = (int) $id;
        $where[$place] = match ($kind) {
            'location' => ['key' => $id === $master ? 'master' : 'location', 'params' => ['name' => $names[$id] ?? null]],
            'road' => ['key' => 'road', 'params' => ['to' => $names[$roads[$id] ?? 0] ?? null, 'transfers_id' => $id]],
            'customer' => ['key' => 'customer', 'params' => ['name' => $customers[$id] ?? null, 'customers_id' => $id]],
            'supplier' => ['key' => 'supplier', 'params' => ['name' => $suppliers[$id] ?? null, 'suppliers_id' => $id]],
            default => ['key' => 'books', 'params' => []],
        };
    }
    return $where;
}

/** The organisation's locations, id => name. */
function locationNames(PDO $pdo): array
{
    return Select::new($pdo)->columns('id', 'name')->from('locations')->fetchKeyPair();
}

/** The master's location id. */
function locationMasterId(PDO $pdo): ?int
{
    $id = Select::new($pdo)->columns('id')->from('locations')->where("kind = 'master'")->orderBy('id')->limit(1)->fetchValue();
    return $id === false || $id === null ? null : (int) $id;
}
