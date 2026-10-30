-- What ci_ai does to a view, a search and a posting function, on PostgreSQL 18.
-- Review M10.
--
-- Run on a UTF-8 scratch database:   psql -d scratch -f ci_ai.sql
-- Some statements fail on purpose: each \echo says what to look for.
-- The collation below is the review's assumption; put the house's definition in its place.

\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS probe_ci_ai CASCADE;
CREATE SCHEMA probe_ci_ai;
SET search_path = probe_ci_ai;

CREATE COLLATION ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false);

-- today's tables, as migrated from MySQL: text in ci_ai
CREATE TABLE serials (
  id            int PRIMARY KEY,
  serial_number varchar(100) COLLATE ci_ai UNIQUE,
  status        varchar(20)  COLLATE ci_ai
);
INSERT INTO serials VALUES (1, '9C2KC1650PR000001', 'stock'), (2, '9C2KC1650PR000002', 'assembly');

CREATE TABLE ops (ci text COLLATE ci_ai, plain text);
INSERT INTO ops VALUES ('Retrovisor Ação', 'Retrovisor Ação'), ('Capacete', 'Capacete');

\echo
\echo '== 1. search operators. Expect: LIKE and NOT LIKE work on ci_ai and ignore case and accents;'
\echo '      ILIKE, NOT ILIKE, regular expressions and starts_with() raise errors on ci_ai;'
\echo '      ILIKE on a plain column ignores case but not accents.'
SELECT 'ci_ai  LIKE ''%acao%''      -> ' || count(*) AS result FROM ops WHERE ci LIKE '%acao%';
SELECT 'ci_ai  NOT LIKE ''%acao%''  -> ' || count(*) AS result FROM ops WHERE ci NOT LIKE '%acao%';
SELECT 'ci_ai  ILIKE ''%acao%''     -> ' || count(*) AS result FROM ops WHERE ci ILIKE '%acao%';
SELECT 'ci_ai  NOT ILIKE ''%acao%'' -> ' || count(*) AS result FROM ops WHERE ci NOT ILIKE '%acao%';
SELECT 'ci_ai  ~* ''acao''          -> ' || count(*) AS result FROM ops WHERE ci ~* 'acao';
SELECT 'ci_ai  starts_with          -> ' || starts_with(ci, 'retro') AS result FROM ops LIMIT 1;
SELECT 'ci_ai  strpos ''acao''      -> ' || strpos(ci, 'acao') AS result FROM ops LIMIT 1;
SELECT 'plain  ILIKE ''%acao%''     -> ' || count(*) AS result FROM ops WHERE plain ILIKE '%acao%';
SELECT 'plain  ILIKE ''%AÇÃO%''     -> ' || count(*) AS result FROM ops WHERE plain ILIKE '%AÇÃO%';

\echo
\echo '== 2. the same view, step A (over today''s ci_ai column) and step C (over a layer column declared plain text).'
\echo '      Expect: A finds the chassis typed in lower case, C finds nothing; a CASE-computed column is not ci_ai.'
CREATE TABLE unit_now (serials_id int, serial_number text, state text);   -- a layer table, no COLLATE
INSERT INTO unit_now VALUES (1, '9C2KC1650PR000001', 'available'), (2, '9C2KC1650PR000002', 'validating');
CREATE VIEW unit_positions_a AS
  SELECT s.id AS serials_id, s.serial_number,
         CASE s.status WHEN 'assembly' THEN 'validating' ELSE 'available' END AS state
  FROM serials s;
CREATE VIEW unit_positions_c AS
  SELECT serials_id, serial_number, state FROM unit_now;
SELECT 'A  serial_number = lower case   -> ' || count(*) AS result FROM unit_positions_a WHERE serial_number = '9c2kc1650pr000001';
SELECT 'C  serial_number = lower case   -> ' || count(*) AS result FROM unit_positions_c WHERE serial_number = '9c2kc1650pr000001';
SELECT 'A  state = ''Available''          -> ' || count(*) AS result FROM unit_positions_a WHERE state = 'Available';
\echo '-- what a view contract test compares (name, type, collation):'
SELECT c.relname AS view, a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
       coalesce(co.collname, '-') AS collation
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_collation co ON co.oid = a.attcollation
WHERE n.nspname = 'probe_ci_ai' AND c.relname LIKE 'unit_positions_%' AND a.attnum > 0
ORDER BY 1, a.attnum;

\echo
\echo '== 3. inside a posting function. Expect: column = parameter matches (ci_ai wins);'
\echo '      variable = parameter and parameter = ANY(array) do not (both default collation).'
CREATE FUNCTION chassis_match(p_read text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_expected text;
  v_hits     int;
BEGIN
  SELECT serial_number INTO v_expected FROM serials WHERE id = 1;
  SELECT count(*) INTO v_hits FROM serials WHERE serial_number = p_read;
  RETURN format('column = parameter: %s | variable = parameter: %s | parameter = ANY(array): %s',
                v_hits, v_expected = p_read, p_read = ANY (ARRAY[v_expected]));
END $$;
SELECT chassis_match('9c2kc1650pr000001') AS result;

\echo
\echo '== 4. a UNION of a ci_ai column with a "C" column (an archive). Expect: CREATE VIEW fails.'
CREATE TABLE archive (serial_number text COLLATE "C");
CREATE VIEW trajectory AS
  SELECT serial_number FROM serials UNION ALL SELECT serial_number FROM archive;

\echo
\echo '== 5. a pg_trgm index on a ci_ai column (needs pg_trgm). Expect: the sequential scan finds "Ação"'
\echo '      for LIKE ''%acao%'', the index scan finds nothing: the index is blind to accents.'
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE TABLE items (id int, name varchar(100) COLLATE ci_ai);
INSERT INTO items SELECT g, 'Capacete ' || g FROM generate_series(1, 20000) g;
INSERT INTO items VALUES (0, 'Retrovisor Ação Plus');
CREATE INDEX items_name_trgm ON items USING gin (name gin_trgm_ops);
ANALYZE items;
SET enable_bitmapscan = off;
SELECT 'sequential scan  LIKE ''%acao%'' -> ' || count(*) AS result FROM items WHERE name LIKE '%acao%';
RESET enable_bitmapscan;
SELECT 'default plan     LIKE ''%acao%'' -> ' || count(*) AS result FROM items WHERE name LIKE '%acao%';
EXPLAIN (COSTS OFF) SELECT count(*) FROM items WHERE name LIKE '%acao%';

DROP SCHEMA probe_ci_ai CASCADE;
