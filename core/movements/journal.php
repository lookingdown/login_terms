<?php
/**
 * core/movements/journal.php — the movements as one location sees them (Movimentações, a model's last moves).
 *
 * It replaces core/movementLog.php: one row per event, read from the journal (sql/readers.sql movement_rows), with
 * the documents' process lines beside them (an assembly job's stage, a service order's state). Keys and
 * parameters only: the kinds' words are the i18n's (mvKind_<kind>). The spreadsheet is the screen's to build from
 * these rows, in its own words.
 */

use Atlas\Query\Select;

/** The movement kinds, and the documents' process lines, as the filter offers them. */
const MOVEMENT_ROW_KINDS = [
    'opening', 'received', 'receipt_corrected', 'built', 'back_to_bench', 'dispatched', 'arrived', 'not_sent', 'lost',
    'swapped', 'flipped', 'sold', 'handed_over', 'sale_undone', 'returned', 'traded_in', 'rented', 'rental_back',
    'loaned', 'loan_back', 'workshop_in', 'workshop_out', 'written_off', 'to_provider', 'adjusted', 'counted',
    'corrected', 'assembly', 'service',
];

/**
 * A page of movement rows, newest first, and the page with its kinds. $location null: the session's own.
 *   $in: q, kind, from, to (Y-m-d), variants_id, serial_id, page, pageSize. One model and nothing else: each row
 *   carries `balance`, the location's own stock of it after the row.
 */
function movementsList(PDO $pdo, array $in, ?int $location = null): array
{
    $location ??= (int) Select::new($pdo)->columns('app_location()')->fetchValue();
    $page = max(1, (int) ($in['page'] ?? 1));
    $pageSize = max(10, min(500, (int) ($in['pageSize'] ?? 50)));
    $q = trim((string) ($in['q'] ?? ''));
    $kind = (string) ($in['kind'] ?? '');
    $from = preg_match('/^\d{4}-\d{2}-\d{2}$/', (string) ($in['from'] ?? '')) ? $in['from'] . ' 00:00:00' : null;
    $to = preg_match('/^\d{4}-\d{2}-\d{2}$/', (string) ($in['to'] ?? '')) ? $in['to'] . ' 23:59:59' : null;
    $variantsId = (int) ($in['variants_id'] ?? 0);
    $serialId = (int) ($in['serial_id'] ?? 0);

    $select = Select::new($pdo);
    $select->columns('r.*', 'v.sku', 'i.name AS item_name', 's.serial_number', 'u.name AS who')
        ->from('movement_rows(CAST(' . $select->bindInline($location) . ' AS int4)) AS r')
        ->join('LEFT', 'variants AS v', 'v.id = r.variants_id')
        ->join('LEFT', 'items AS i', 'i.id = v.items_id')
        ->join('LEFT', 'serials AS s', 's.id = r.serials_id')
        ->join('LEFT', 'users AS u', 'u.id = r.users_id');
    if ($kind !== '') {
        $select->where('r.kind = ', $kind);
    }
    if ($from !== null) {
        $select->where('r.occurred_at >= ', $from);
    }
    if ($to !== null) {
        $select->where('r.occurred_at <= ', $to);
    }
    if ($variantsId > 0) {
        $select->where('r.variants_id = ', $variantsId);
    }
    if ($serialId > 0) {
        $select->where('r.serials_id = ', $serialId);
    }
    if ($q !== '') {
        $like = '%' . $q . '%';
        $select->where('(v.sku LIKE ', $like)->catWhere(' OR i.name LIKE ', $like)
            ->catWhere(' OR s.serial_number LIKE ', $like)->catWhere(' OR r.note LIKE ', $like)->catWhere(')');
    }
    $balance = $variantsId > 0 && $kind === '' && $from === null && $to === null && $serialId === 0 && $q === '';
    if ($balance) {
        $select->columns('SUM(r.qty) OVER (ORDER BY r.occurred_at, r.movements_id NULLS LAST) AS balance');
    }

    $total = positionsCount($pdo, $select);
    $pages = max(1, (int) ceil($total / $pageSize));
    $page = min($page, $pages);
    $rows = $select->orderBy('r.occurred_at DESC', 'r.movements_id DESC NULLS LAST')
        ->limit($pageSize)->offset(($page - 1) * $pageSize)->fetchAll();

    $cells = [];
    foreach ($rows as &$r) {
        foreach (['from_cell', 'to_cell'] as $k) {
            $r[$k] = $r[$k] === null ? null : movementCell(json_decode($r[$k], true));
            foreach (['place', 'owner'] as $c) {
                if (isset($r[$k][$c])) {
                    $cells[] = $r[$k][$c];
                }
            }
        }
    }
    unset($r);
    $where = placeWhere($pdo, $cells);

    $out = [];
    foreach ($rows as $r) {
        $names = [];
        foreach ([$r['from_cell'], $r['to_cell']] as $cell) {
            foreach (['place', 'owner'] as $c) {
                if (isset($cell[$c]) && $cell[$c] !== 'books') {
                    $names[$cell[$c]] = $where[$cell[$c]]['params']['to'] ?? $where[$cell[$c]]['params']['name'] ?? null;
                }
            }
        }
        $row = [
            'movement_id' => $r['movements_id'] === null ? null : (int) $r['movements_id'],
            'at' => $r['occurred_at'], 'recorded_at' => $r['recorded_at'], 'kind' => $r['kind'],
            'model' => $r['variants_id'] === null ? null
                : ['variants_id' => (int) $r['variants_id'], 'sku' => $r['sku'], 'item_name' => $r['item_name']],
            'unit' => $r['serials_id'] === null ? null : ['id' => (int) $r['serials_id'], 'serial_number' => $r['serial_number']],
            'qty' => (int) $r['qty'],
            'from' => $r['from_cell'], 'to' => $r['to_cell'], 'names' => $names,
            'ref' => $r['ref_type'] === null ? null : ['type' => $r['ref_type'], 'id' => (int) $r['ref_id']],
            'note' => $r['note'], 'who' => $r['who'],
        ];
        if ($balance) {
            $row['balance'] = (int) $r['balance'];
        }
        $out[] = $row;
    }
    return [
        'data' => $out,
        'meta' => [
            'totalRows' => $total, 'totalPages' => $pages, 'currentPage' => $page,
            'previousPage' => $page > 1 ? $page - 1 : null, 'nextPage' => $page < $pages ? $page + 1 : null,
            'kinds' => MOVEMENT_ROW_KINDS,
        ],
    ];
}

/**
 * A cell as a movement row shows it: ['place', 'owner', 'state'] as coordinates and a state, or ['stage'] for a
 * document's process line.
 */
function movementCell(array $cell): array
{
    if (array_key_exists('stage', $cell)) {
        return ['stage' => $cell['stage']];
    }
    $at = fn (array $kinds) => array_reduce(array_keys($kinds),
        fn (?string $found, string $key) => $found ?? ($cell[$key] !== null ? $kinds[$key] . ':' . $cell[$key] : null)) ?? 'books';
    return [
        'place' => $at(['at_location_id' => 'location', 'at_transfer_id' => 'road', 'at_customer_id' => 'customer', 'at_supplier_id' => 'supplier']),
        'owner' => $at(['owner_location_id' => 'location', 'owner_customer_id' => 'customer', 'owner_supplier_id' => 'supplier']),
        'state' => $cell['state'],
    ];
}
