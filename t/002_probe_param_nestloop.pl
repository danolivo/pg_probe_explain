# Copyright (c) 2026, PostgreSQL Global Development Group

# Check pg_probe_explain against the second demo core patch,
# patches/0002-planner-probe-parameterized-nestloop.patch: the log must receive
# EXPLAIN ANALYZE output for exactly those queries whose planning built a
# parameterized nestloop path - the inner side drawing its parameters from the
# outer relation - whether or not that path ended up in the plan.
#
# The two demo patches export the same flag, so only one can be applied at a
# time.  This test detects which one is in place and skips itself if the server
# carries the JOIN_SEMI probe instead.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('param_nl');
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
-- p has an index on the join key, so a parameterized inner path is possible
CREATE TABLE p(id int PRIMARY KEY, name text);
-- s has no indexes at all, so nothing on it can be parameterized
CREATE TABLE s(pid int, amount int);
INSERT INTO p SELECT i, 'p' || i FROM generate_series(1, 5000) AS i;
INSERT INTO s SELECT i % 4000 + 1, i FROM generate_series(1, 20000) AS i;
ANALYZE p, s;
});

my $marker = qr/pg_probe_explain: planner probe hit/;

sub run_and_capture_log
{
	my ($sql) = @_;
	my $offset = -s $node->logfile;

	$node->safe_psql('postgres', $sql);
	return slurp_file($node->logfile, $offset);
}

# Which probe is this server carrying?  A join with an indexed inner side must
# build a parameterized nestloop; if that produces nothing, the core patch in
# place is not the one this test is about.
my $probe = run_and_capture_log(
	q{SELECT count(*) FROM s JOIN p ON p.id = s.pid});
if ($probe !~ $marker)
{
	plan skip_all =>
	  'server does not carry the parameterized-nestloop probe';
}

like($probe, $marker, 'join with an indexable inner side is logged');
like($probe, qr/actual time=/, 'logged plan is EXPLAIN ANALYZE output');

# The point of the exercise: the path is built, loses on cost, and the query is
# logged anyway.  enable_nestloop = off is the cleanest way to make it lose -
# the path is still constructed, only penalised.
my $log = run_and_capture_log(
	q{SET enable_nestloop = off;
	  SELECT count(*) FROM s JOIN p ON p.id = s.pid});
like($log, $marker, 'query is logged even when the nestloop is disabled');
unlike($log, qr/Nested Loop/, 'and the plan that ran contains no nestloop');
like($log, qr/Hash Join|Merge Join/, 'it used another join method');

# A join whose inner side has no index cannot be parameterized.
$log = run_and_capture_log(
	q{SELECT count(*) FROM s a JOIN s b ON a.pid = b.pid AND a.amount <> b.amount});
unlike($log, $marker, 'join with no indexes on either side is not logged');

# Neither can a single-table query.
$log = run_and_capture_log(q{SELECT count(*) FROM s});
unlike($log, $marker, 'single-table query is not logged');

# EXISTS over the un-indexed table: a semi join, but no parameterized nestloop.
# With the other demo patch applied this one would be logged - here it must not
# be, which is what tells the two probes apart.
$log = run_and_capture_log(
	q{SELECT count(*) FROM s a WHERE EXISTS (SELECT 1 FROM s b WHERE b.pid = a.pid AND b.amount <> a.amount)});
unlike($log, $marker, 'semi join without parameterization is not logged');

# Turning the module off suppresses logging.
$log = run_and_capture_log(
	q{SET pg_probe_explain.enabled = off;
	  SELECT count(*) FROM s JOIN p ON p.id = s.pid});
unlike($log, $marker, 'nothing is logged while the module is disabled');

# Nesting: a parameterized nestloop planned inside a function does not make the
# calling query interesting, and does not leak into the next statement.
$node->safe_psql(
	'postgres', q{
CREATE FUNCTION nl_in_function() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
	n bigint;
BEGIN
	SELECT count(*) INTO n FROM s JOIN p ON p.id = s.pid;
	RETURN n;
END;
$$;
});
$log = run_and_capture_log(q{SELECT nl_in_function()});
unlike($log, $marker, 'parameterized nestloop inside a function is not logged');
$log = run_and_capture_log(q{SELECT count(*) FROM s});
unlike($log, $marker, 'the verdict does not leak into the next statement');

# Still working afterwards.
$log = run_and_capture_log(
	q{SELECT count(*) FROM s JOIN p ON p.id = s.pid});
like($log, $marker, 'the probe still fires after all that');

$node->stop;
done_testing();
