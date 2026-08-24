#!/bin/bash
#
# End-to-end demonstration of pg_probe_explain on a patched server.
#
# Starts a throwaway cluster, runs a handful of queries, and checks that the
# server log got an EXPLAIN ANALYZE plan for exactly those queries whose
# planning built a JOIN_SEMI path.  Prints what it found, so that the output
# is useful on its own (in CI, for example).
#
# Usage: test/demo.sh [bindir]
#
set -euo pipefail

BINDIR=${1:-$(pg_config --bindir)}
WORK=$(mktemp -d)
PGDATA=$WORK/data
LOGFILE=$WORK/server.log
MARKER='pg_probe_explain: planner probe hit'

cleanup()
{
	"$BINDIR/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "### server: $("$BINDIR/postgres" --version)"

"$BINDIR/initdb" -D "$PGDATA" -N -U postgres >/dev/null
cat >>"$PGDATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_probe_explain'
pg_probe_explain.enabled = on
pg_probe_explain.analyze = on
listen_addresses = ''
unix_socket_directories = '$WORK'
log_statement = 'none'
EOF

"$BINDIR/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -w start >/dev/null
echo "### cluster started, module loaded"

psql()
{
	"$BINDIR/psql" -h "$WORK" -U postgres -d postgres -qAtX -v ON_ERROR_STOP=1 "$@"
}

psql -c "
CREATE TABLE parts(id int PRIMARY KEY, name text);
CREATE TABLE sales(part_id int, amount int);
INSERT INTO parts SELECT i, 'part' || i FROM generate_series(1, 1000) AS i;
INSERT INTO sales SELECT i % 900 + 1, i FROM generate_series(1, 20000) AS i;
ANALYZE parts, sales;" >/dev/null

failures=0

# run_query <expected: yes|no> <label> <sql>
run_query()
{
	local expected=$1 label=$2 sql=$3
	local before after got

	before=$(grep -c "$MARKER" "$LOGFILE" || true)
	psql -c "$sql" >/dev/null
	after=$(grep -c "$MARKER" "$LOGFILE" || true)

	if [ "$after" -gt "$before" ]; then got=yes; else got=no; fi

	if [ "$got" = "$expected" ]; then
		echo "ok       logged=$got (expected $expected)  $label"
	else
		echo "NOT OK   logged=$got (expected $expected)  $label"
		failures=$((failures + 1))
	fi
}

echo
echo "### queries"
run_query yes "EXISTS - semi join" \
	"SELECT count(*) FROM parts p WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)"
run_query yes "IN (subquery) - semi join" \
	"SELECT count(*) FROM parts p WHERE p.id IN (SELECT s.part_id FROM sales s)"
run_query yes "EXISTS - semi join kept in the final plan" \
	"SELECT count(*) FROM parts p WHERE EXISTS (SELECT 1 FROM sales s WHERE s.amount = p.id)"
run_query no "NOT EXISTS - anti join" \
	"SELECT count(*) FROM parts p WHERE NOT EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)"
run_query no "plain inner join" \
	"SELECT count(*) FROM parts p JOIN sales s ON s.part_id = p.id"
run_query no "single table" \
	"SELECT count(*) FROM parts"
run_query no "semi join, module disabled" \
	"SET pg_probe_explain.enabled = off;
	 SELECT count(*) FROM parts p WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)"

echo
echo "### what ended up in the log"
sed -n "/$MARKER/,/^\$/p" "$LOGFILE"

echo
if [ "$failures" -eq 0 ]; then
	echo "DEMO PASSED"
else
	echo "DEMO FAILED: $failures unexpected results"
	exit 1
fi
