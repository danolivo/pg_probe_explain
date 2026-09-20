# Copyright (c) 2026, PostgreSQL Global Development Group

# Check pg_probe_explain against the third demo core patch,
# patches/0003-planner-probe-self-outer-join.patch: the log must receive
# EXPLAIN ANALYZE output for exactly those queries that join a table to itself
# under an outer join, on a self-join condition - the "X = X" that the
# self-join elimination code looks for and then refuses to act on because the
# two relations are not on the same side of the join.
#
# The demo patches export the same flag, so only one can be applied at a time.
# This test detects which one is in place and skips itself if the server
# carries one of the others.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('self_oj');
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
CREATE TABLE sj_a(id int PRIMARY KEY, x int, y int);
CREATE TABLE sj_b(id int PRIMARY KEY, x int);
INSERT INTO sj_a SELECT i, i % 10, i FROM generate_series(1, 1000) AS i;
INSERT INTO sj_b SELECT i, i FROM generate_series(1, 100) AS i;
ANALYZE sj_a, sj_b;
CREATE FUNCTION self_oj_in_function() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
	n bigint;
BEGIN
	SELECT count(t2.y) INTO n
	FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id;
	RETURN n;
END;
$$;
});

my $marker = qr/pg_probe_explain: planner probe hit/;

# Run $sql and return whatever the server wrote to the log meanwhile.
sub run_and_capture_log
{
	my ($sql) = @_;
	my $offset = -s $node->logfile;

	$node->safe_psql('postgres', $sql);
	return slurp_file($node->logfile, $offset);
}

# Which probe is this server carrying?  A table with no indexes at all, joined
# to itself by a left join, gives neither a semi join nor a parameterized
# inner path, so this query fires under the self-outer-join probe and under
# nothing else.
$node->safe_psql(
	'postgres', q{
CREATE TABLE d1(x int);
INSERT INTO d1 SELECT generate_series(1, 500) % 100;
ANALYZE d1;
});
my $probe = run_and_capture_log(
	q{SELECT count(t2.x) FROM d1 t1 LEFT JOIN d1 t2 ON t1.x = t2.x});
if ($probe !~ $marker)
{
	plan skip_all => 'server does not carry the self-outer-join probe';
}

# 1. The basic case: a left join of a table to itself on its primary key.
#
#    Note that the join is still there in the plan, and always will be - the
#    probe reports the case, it does not make the planner handle it.  Note
#    also that t2 has to be referenced by the query, or remove_useless_outer_
#    joins() drops the join before the self-join code ever sees it.
my $log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id});
like($log, $marker, 'self left join is logged');
like($log, qr/Query Text:/, 'logged plan includes the query text');
like($log, qr/actual time=/, 'logged plan is EXPLAIN ANALYZE output');

# 2. The join column need not be unique: the probe asks whether the join runs
#    on a self-join condition, not whether it could be eliminated.
$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.x = t2.x});
like($log, $marker, 'self left join on a non-unique column is logged');

# 3. Right and full joins are the same case spelled differently.  The two
#    sides of a full join are separate subproblems of the joinlist, which is
#    why the patch looks at them separately.
$log = run_and_capture_log(
	q{SELECT count(t1.y) FROM sj_a t1 RIGHT JOIN sj_a t2 ON t1.id = t2.id});
like($log, $marker, 'self right join is logged');

$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 FULL JOIN sj_a t2 ON t1.id = t2.id});
like($log, $marker, 'self full join is logged');

# 4. An extra qual on the join does not hide the self-join condition, and
#    neither does another join standing next to it.
$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2
	  ON t1.id = t2.id AND t2.x = 3});
like($log, $marker, 'self left join with an extra qual is logged');

$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id
	  LEFT JOIN sj_b b1 ON b1.id = t1.id});
like($log, $marker, 'self left join next to another join is logged');

# 5. An anti join is reported too: its quals are ordinary join quals, and the
#    self-join code refuses to touch it for the same reason.
$log = run_and_capture_log(
	q{SELECT count(*) FROM sj_a t1
	  WHERE NOT EXISTS (SELECT 1 FROM sj_a t2 WHERE t1.id = t2.id)});
like($log, $marker, 'self anti join is logged');

# 6. Two columns that merely have the same type are not a self-join
#    condition.
$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.x});
unlike($log, $marker, 'left join on different columns is not logged');

$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.x = t2.y});
unlike($log, $marker, 'left join on another pair of columns is not logged');

# 7. Two different tables are not a self join, whatever the condition.
$log = run_and_capture_log(
	q{SELECT count(t2.x) FROM sj_a t1 LEFT JOIN sj_b t2 ON t1.id = t2.id});
unlike($log, $marker, 'left join of two tables is not logged');

# 8. An inner self join is not an outer join: the self-join elimination code
#    deals with it itself, and the probe stays out of the way.
$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 JOIN sj_a t2 ON t1.id = t2.id});
unlike($log, $marker, 'inner self join is not logged');

$log = run_and_capture_log(
	q{SELECT count(*) FROM sj_a t1, sj_a t2 WHERE t1.id = t2.id});
unlike($log, $marker, 'comma-join form of a self join is not logged');

# 9. A single-table query must not be logged.
$log = run_and_capture_log(q{SELECT count(*) FROM sj_a});
unlike($log, $marker, 'single-table query is not logged');

# 10. Turning the module off suppresses logging even for a self outer join.
$log = run_and_capture_log(
	q{SET pg_probe_explain.enabled = off;
	  SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id});
unlike($log, $marker, 'nothing is logged while the module is disabled');

# 11. The probe lives inside the self-join elimination pass, so turning that
#     pass off turns the probe off with it.  Worth knowing before trusting a
#     quiet log.
$log = run_and_capture_log(
	q{SET enable_self_join_elimination = off;
	  SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id});
unlike($log, $marker,
	'nothing is logged while self-join elimination is disabled');

# 12. Only top-level statements are considered: a self outer join planned
#     inside a plpgsql function does not make the calling query interesting...
$log = run_and_capture_log(q{SELECT self_oj_in_function()});
unlike($log, $marker, 'self outer join inside a function is not logged');

# ... and does not leak into the next statement.
$log = run_and_capture_log(q{SELECT count(*) FROM sj_a});
unlike($log, $marker, 'the verdict does not leak into the next statement');

# 13. Back to normal: the module still works after all that.
$log = run_and_capture_log(
	q{SELECT count(t2.y) FROM sj_a t1 LEFT JOIN sj_a t2 ON t1.id = t2.id});
like($log, $marker, 'self left join is logged again');

$node->stop;
done_testing();
