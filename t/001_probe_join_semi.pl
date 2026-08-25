# Copyright (c) 2026, PostgreSQL Global Development Group

# Check that pg_probe_explain logs EXPLAIN ANALYZE output for exactly those
# queries whose planning raised the core probe flag.  With the demo core patch
# (patches/0001-planner-probe-JOIN_SEMI.patch) that means: queries for which a
# JOIN_SEMI path was built, and no others.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('probe');
$node->init;
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'pg_probe_explain'
pg_probe_explain.enabled = on
pg_probe_explain.analyze = on
});
$node->start;

$node->safe_psql(
	'postgres', q{
CREATE TABLE parts(id int PRIMARY KEY, name text);
CREATE TABLE sales(part_id int, amount int);
INSERT INTO parts SELECT i, 'part' || i FROM generate_series(1, 1000) AS i;
INSERT INTO sales SELECT i % 900 + 1, i FROM generate_series(1, 20000) AS i;
ANALYZE parts, sales;
CREATE FUNCTION semi_in_function() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
	n bigint;
BEGIN
	SELECT count(*) INTO n FROM parts p
	WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id);
	RETURN n;
END;
$$;
});

# Run $sql and return whatever the server wrote to the log meanwhile.
sub run_and_capture_log
{
	my ($sql) = @_;
	my $offset = -s $node->logfile;

	$node->safe_psql('postgres', $sql);
	return slurp_file($node->logfile, $offset);
}

my $marker = qr/pg_probe_explain: planner probe hit/;

# Which probe is this server carrying?  The demo patches export the same flag,
# so only one can be applied at a time.  A semi join between two tables with no
# indexes at all can produce no parameterized path either, so it fires under the
# JOIN_SEMI probe and under nothing else.
$node->safe_psql(
	'postgres', q{
CREATE TABLE d1(x int);
CREATE TABLE d2(y int);
INSERT INTO d1 SELECT generate_series(1, 500);
INSERT INTO d2 SELECT generate_series(1, 500) % 100;
ANALYZE d1, d2;
});
my $probe = run_and_capture_log(
	q{SELECT count(*) FROM d1 WHERE EXISTS (SELECT 1 FROM d2 WHERE d2.y = d1.x)});
if ($probe !~ $marker)
{
	plan skip_all => 'server does not carry the JOIN_SEMI probe';
}

# 1. EXISTS gives a semi-join: the plan must be logged, and it must be an
#    ANALYZE plan, not a bare EXPLAIN.
my $log = run_and_capture_log(
	q{SELECT count(*) FROM parts p
	  WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)});
#
#    Note that the *chosen* plan need not contain a Semi Join node: the
#    planner may well prefer to unique-ify the inner side and do a plain
#    join.  The probe fires on the path being built, which is exactly the
#    kind of thing EXPLAIN cannot show you.
like($log, $marker, 'EXISTS query is logged');
like($log, qr/Query Text:/, 'logged plan includes the query text');
like($log, qr/actual time=/, 'logged plan is EXPLAIN ANALYZE output');

# 2. IN (subquery) is the same thing spelled differently.
$log = run_and_capture_log(
	q{SELECT count(*) FROM parts p WHERE p.id IN (SELECT s.part_id FROM sales s)});
like($log, $marker, 'IN (subquery) query is logged');

# 2a. A case where the semi join does survive into the final plan.
$log = run_and_capture_log(
	q{SELECT count(*) FROM parts p
	  WHERE EXISTS (SELECT 1 FROM sales s WHERE s.amount = p.id)});
like($log, $marker, 'query with a chosen semi join is logged');
like($log, qr/Semi Join/, 'logged plan contains a Semi Join node');

# 3. NOT EXISTS is an anti-join, not a semi-join: nothing must be logged.
$log = run_and_capture_log(
	q{SELECT count(*) FROM parts p
	  WHERE NOT EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)});
unlike($log, $marker, 'NOT EXISTS query is not logged');

# 4. A plain inner join must not be logged either.
$log = run_and_capture_log(
	q{SELECT count(*) FROM parts p JOIN sales s ON s.part_id = p.id});
unlike($log, $marker, 'inner join query is not logged');

# 5. A single-table query must not be logged.
$log = run_and_capture_log(q{SELECT count(*) FROM parts});
unlike($log, $marker, 'single-table query is not logged');

# 6. Turning the module off suppresses logging even for a semi-join.
$log = run_and_capture_log(
	q{SET pg_probe_explain.enabled = off;
	  SELECT count(*) FROM parts p
	  WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)});
unlike($log, $marker, 'nothing is logged while the module is disabled');

# 7. Only top-level statements are considered: a semi-join planned inside a
#    plpgsql function does not make the calling query interesting...
$log = run_and_capture_log(q{SELECT semi_in_function()});
unlike($log, $marker, 'semi join inside a function is not logged');

# ... and, more importantly, does not leak into the next statement.
$log = run_and_capture_log(q{SELECT count(*) FROM parts});
unlike($log, $marker, 'the verdict does not leak into the next statement');

# 8. Back to normal: the module still works after all that.
$log = run_and_capture_log(
	q{SELECT count(*) FROM parts p
	  WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)});
like($log, $marker, 'semi-join query is logged again');

$node->stop;
done_testing();
