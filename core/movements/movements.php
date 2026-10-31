<?php
/**
 * core/movements — the movement layer's PHP face. One require loads it:
 *
 *   require_once '/var/sys/core/movements/movements.php';
 *
 * ledger.php is the writing side (one function per event), positions.php the reading side
 * (where things are, were and are planned to be). The database holds the rules: sql/.
 */

require_once __DIR__ . '/ledger.php';
require_once __DIR__ . '/positions.php';
