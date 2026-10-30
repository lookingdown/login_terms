<?php
/**
 * How a coded refusal, a list argument and a composed Select travel through PDO and Atlas Query.
 * Review findings 4, 6, 9 and 11.
 *
 *   composer require atlas/query:^2
 *   PGHOST=… PGPORT=… PGDATABASE=scratch PGUSER=… php errors.php [path/to/vendor/autoload.php]
 *
 * It creates the schema probe_errors and drops it at the end.
 */
declare(strict_types=1);

require $argv[1] ?? 'vendor/autoload.php';

use Atlas\Query\Select;

$dsn = sprintf('pgsql:host=%s;port=%s;dbname=%s', getenv('PGHOST') ?: 'localhost', getenv('PGPORT') ?: '5432', getenv('PGDATABASE') ?: 'postgres');
$pdo = new PDO($dsn, getenv('PGUSER') ?: 'postgres', getenv('PGPASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

$pdo->exec(<<<'SQL'
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS probe_errors CASCADE;
CREATE SCHEMA probe_errors;
SET search_path = probe_errors;
CREATE FUNCTION guard(p_id bigint) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'MVR07',
    MESSAGE = 'a moto não está nesta loja',
    DETAIL  = 'mv:' || jsonb_build_object('message', 'a moto não está nesta loja',
                                          'facts', jsonb_build_object('serials_id', p_id, 'note', E'linha 1\nlinha 2'))::text;
END $$;
CREATE FUNCTION movement_dispatch(p_transfers_id bigint) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN PERFORM guard(p_transfers_id); RETURN '{"legs": 2}'; END $$;
CREATE FUNCTION flag(p boolean) RETURNS text LANGUAGE sql AS $$ SELECT p::text $$;
CREATE FUNCTION chassis(p text[]) RETURNS int LANGUAGE sql AS $$ SELECT cardinality(p) $$;
CREATE FUNCTION chassis_jsonb(p jsonb) RETURNS int LANGUAGE sql AS $$ SELECT jsonb_array_length(p) $$;
CREATE FUNCTION count_close(p bigint) RETURNS TABLE (serials_id int, serial_number text) LANGUAGE sql AS $$
  VALUES (1, '9C2KC1650PR000001'), (2, '9C2KC1650PR000002') $$;
CREATE TABLE t (id int, grp text);
INSERT INTO t SELECT g, CASE WHEN g % 2 = 0 THEN 'a' ELSE 'b' END FROM generate_series(1, 10) g;
SQL);

function line(string $label, mixed $value): void
{
    echo str_pad($label, 44), is_string($value) ? $value : json_encode($value, JSON_UNESCAPED_UNICODE), "\n";
}

echo "== 1. a coded refusal through the plan's post() shape\n";
$q = Select::new($pdo);
$q->columns('movement_dispatch(CAST(' . $q->bindInline(42) . ' AS bigint)) AS answer');
try {
    $q->fetchValue();
} catch (PDOException $e) {
    line('getCode()', $e->getCode());
    echo "errorInfo[2], the only place the DETAIL is:\n", preg_replace('/^/m', '  ', $e->errorInfo[2]), "\n";
    echo "getMessage(), not an operator message:\n  ", strtok($e->getMessage(), "\n"), "\n";
    preg_match('/mv:(\{.*\})$/m', $e->errorInfo[2], $m);
    line('the mv: line, label-independent', json_decode($m[1], true));
    preg_match('/mv:(\{.*\})$/m', "ERRO:  …\nDETALHE:  " . 'mv:{"facts": {"serials_id": 42}, "message": "…"}' . "\nCONTEXTO:  …", $m);
    line('the same, under Portuguese labels', json_decode($m[1], true));
}

echo "\n== 2. a refusal inside the caller's transaction, then the caller carries on\n";
$pdo->beginTransaction();
try { $pdo->query('SELECT movement_dispatch(42)'); } catch (PDOException $e) { line('refused', $e->getCode()); }
try { $pdo->query('SELECT 1'); line('next statement', 'ok'); }
catch (PDOException $e) { line('next statement', $e->getCode() . ' ' . strtok($e->errorInfo[2], "\n")); }
$pdo->rollBack();

echo "\n== 3. the same, with the call inside a savepoint\n";
$pdo->beginTransaction();
$pdo->exec('SAVEPOINT movement');
try { $pdo->query('SELECT movement_dispatch(42)'); $pdo->exec('RELEASE SAVEPOINT movement'); }
catch (PDOException $e) { $pdo->exec('ROLLBACK TO SAVEPOINT movement'); line('refused', $e->getCode()); }
line('next statement', $pdo->query('SELECT 1')->fetchColumn());
$pdo->rollBack();

echo "\n== 4. arguments bound with bindInline\n";
$q = Select::new($pdo);
$q->columns('flag(CAST(' . $q->bindInline(false) . ' AS boolean))');
line('false AS boolean', $q->fetchValue());
$q = Select::new($pdo);
$q->columns('chassis(CAST(' . $q->bindInline(['9C2KC1', '9C2KC2']) . ' AS text[]))');
line('a PHP list AS text[]', preg_replace('/\s+/', ' ', $q->getQueryString()));
try { $q->fetchValue(); } catch (PDOException $e) { line('', strtok($e->errorInfo[2], "\n")); }
$q = Select::new($pdo);
$q->columns('chassis_jsonb(CAST(' . $q->bindInline(json_encode(['9C2KC1', 'a,"b}'])) . ' AS jsonb))');
line('the same list AS jsonb', $q->fetchValue());

echo "\n== 5. a table-returning function called as SELECT fn(...) AS answer\n";
$q = Select::new($pdo);
$q->columns('count_close(CAST(' . $q->bindInline(1) . ' AS bigint)) AS answer');
line('rows', $q->fetchAll());

echo "\n== 6. count() on a grouped select\n";
$base = Select::new($pdo)->columns('t.grp')->from('t AS t')->groupBy('t.grp')->orderBy('t.grp')->limit(1);
line('the rows it has', count((clone $base)->resetLimit()->fetchAll()));
$reset = (clone $base)->resetColumns()->resetOrderBy()->resetLimit()->columns('COUNT(*)');
line('clone + resetColumns + COUNT(*)', $reset->fetchAll());
$derived = Select::new($pdo)->columns('COUNT(*)')->from((clone $base)->resetOrderBy()->resetLimit()->as('c'));
line('COUNT(*) over a derived table', $derived->fetchValue());

echo "\n== 7. asOf() by swapping the FROM: the consumer's join\n";
$s = Select::new($pdo)->columns('oh.id')->from('t AS oh')->join('LEFT', 't AS x', 'x.id = oh.id');
line('before', preg_replace('/\s+/', ' ', $s->getQueryString()));
$s->resetFrom()->from('stock_at(now()) AS oh');
line('after resetFrom()', preg_replace('/\s+/', ' ', $s->getQueryString()));

$pdo->exec('DROP SCHEMA probe_errors CASCADE');
