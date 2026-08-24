/*-------------------------------------------------------------------------
 *
 * pg_probe_explain.c
 *	  Log EXPLAIN ANALYZE of a query, but only when the planner reported
 *	  that some condition of interest was met while planning it.
 *
 * The condition itself is not implemented here.  The core is expected to
 * export a single boolean variable
 *
 *		extern PGDLLIMPORT bool planner_probe_hit;
 *
 * which a (throwaway, debugging-only) core patch sets from wherever the
 * event of interest happens - a specific path being built, a specific
 * estimate being clamped, a specific code branch being taken, and so on.
 * The core only ever sets the flag; clearing it is this module's job:
 *
 *		planner_hook		clears the flag, plans the query, reads the flag
 *		ExecutorStart_hook	arms instrumentation if the flag was set
 *		ExecutorEnd_hook	prints EXPLAIN (ANALYZE) into the server log
 *
 * That split is what makes the module reusable: to ask a different
 * question you rewrite two lines of the core patch and leave this file
 * alone.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/pg_probe_explain/pg_probe_explain.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "access/parallel.h"
#include "commands/explain.h"
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "optimizer/pathnode.h"
#include "optimizer/planner.h"
#include "utils/guc.h"

PG_MODULE_MAGIC_EXT(
					.name = "pg_probe_explain",
					.version = PG_VERSION
);

/* GUC variables */
static bool probe_explain_enabled = true;
static bool probe_explain_analyze = true;
static bool probe_explain_verbose = false;
static bool probe_explain_buffers = false;
static bool probe_explain_wal = false;
static bool probe_explain_triggers = false;
static bool probe_explain_timing = true;
static bool probe_explain_settings = false;
static int	probe_explain_format = EXPLAIN_FORMAT_TEXT;
static int	probe_explain_log_level = LOG;
static int	probe_explain_log_parameter_max_length = -1;

static const struct config_enum_entry format_options[] = {
	{"text", EXPLAIN_FORMAT_TEXT, false},
	{"xml", EXPLAIN_FORMAT_XML, false},
	{"json", EXPLAIN_FORMAT_JSON, false},
	{"yaml", EXPLAIN_FORMAT_YAML, false},
	{NULL, 0, false}
};

static const struct config_enum_entry loglevel_options[] = {
	{"debug5", DEBUG5, false},
	{"debug4", DEBUG4, false},
	{"debug3", DEBUG3, false},
	{"debug2", DEBUG2, false},
	{"debug1", DEBUG1, false},
	{"debug", DEBUG2, true},
	{"info", INFO, false},
	{"notice", NOTICE, false},
	{"warning", WARNING, false},
	{"log", LOG, false},
	{NULL, 0, false}
};

/* Saved hook values */
static planner_hook_type prev_planner_hook = NULL;
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;

/*
 * Nesting depth of the planner and of the executor.  We are only interested
 * in top-level statements: a query planned or executed from inside a
 * function, a trigger or an RI check is somebody else's business.
 */
static int	plan_nesting_level = 0;
static int	exec_nesting_level = 0;

/*
 * Did the probe fire while planning the statement we are about to execute?
 *
 * Set by the planner hook, consumed by the ExecutorStart hook.  This relies
 * on the executor being entered right after the planner, which is true for
 * a plain query but *not* for a plan taken from the plan cache - see the
 * README for that limitation.
 */
static bool probe_hit_while_planning = false;

/* Are we explaining the statement currently being executed? */
static bool current_query_probed = false;

/* Function declarations */
static PlannedStmt *probe_explain_planner(Query *parse,
										  const char *query_string,
										  int cursorOptions,
										  ParamListInfo boundParams);
static void probe_explain_ExecutorStart(QueryDesc *queryDesc, int eflags);
static void probe_explain_ExecutorRun(QueryDesc *queryDesc,
									  ScanDirection direction,
									  uint64 count);
static void probe_explain_ExecutorFinish(QueryDesc *queryDesc);
static void probe_explain_ExecutorEnd(QueryDesc *queryDesc);

/*
 * Module load callback
 */
void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_probe_explain.enabled",
							 "Watch the planner probe flag and log matching plans.",
							 NULL,
							 &probe_explain_enabled,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.analyze",
							 "Use EXPLAIN ANALYZE for logged plans.",
							 NULL,
							 &probe_explain_analyze,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.verbose",
							 "Use EXPLAIN VERBOSE for logged plans.",
							 NULL,
							 &probe_explain_verbose,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.buffers",
							 "Log buffer usage.",
							 NULL,
							 &probe_explain_buffers,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.wal",
							 "Log WAL usage.",
							 NULL,
							 &probe_explain_wal,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.triggers",
							 "Include trigger statistics in logged plans.",
							 NULL,
							 &probe_explain_triggers,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.timing",
							 "Collect timing data, not just row counts.",
							 NULL,
							 &probe_explain_timing,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_probe_explain.settings",
							 "Log modified configuration parameters affecting query planning.",
							 NULL,
							 &probe_explain_settings,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_probe_explain.format",
							 "EXPLAIN format to be used.",
							 NULL,
							 &probe_explain_format,
							 EXPLAIN_FORMAT_TEXT,
							 format_options,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_probe_explain.log_level",
							 "Log level for the plan.",
							 NULL,
							 &probe_explain_log_level,
							 LOG,
							 loglevel_options,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_probe_explain.log_parameter_max_length",
							"Sets the maximum length of query parameters to log.",
							NULL,
							&probe_explain_log_parameter_max_length,
							-1,
							-1, INT_MAX / 2,
							PGC_SUSET,
							GUC_UNIT_BYTE,
							NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_probe_explain");

	/* Install hooks */
	prev_planner_hook = planner_hook;
	planner_hook = probe_explain_planner;
	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = probe_explain_ExecutorStart;
	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = probe_explain_ExecutorRun;
	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = probe_explain_ExecutorFinish;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = probe_explain_ExecutorEnd;
}

/*
 * planner_hook: clear the probe flag, plan the query, remember the verdict.
 *
 * Only top-level planner invocations are considered.  Note that the flag is
 * cleared *before* planning and read *after* it, so anything the core patch
 * does in between is visible here regardless of where in the planner it
 * happens.
 */
static PlannedStmt *
probe_explain_planner(Query *parse, const char *query_string,
					  int cursorOptions, ParamListInfo boundParams)
{
	PlannedStmt *result;
	bool		toplevel = (plan_nesting_level == 0 && exec_nesting_level == 0);

	if (toplevel && probe_explain_enabled)
		planner_probe_hit = false;

	plan_nesting_level++;
	PG_TRY();
	{
		if (prev_planner_hook)
			result = prev_planner_hook(parse, query_string, cursorOptions,
									   boundParams);
		else
			result = standard_planner(parse, query_string, cursorOptions,
									  boundParams);
	}
	PG_FINALLY();
	{
		plan_nesting_level--;
	}
	PG_END_TRY();

	if (toplevel && probe_explain_enabled)
		probe_hit_while_planning = planner_probe_hit;

	return result;
}

/*
 * ExecutorStart hook: arm instrumentation for a statement whose planning
 * tripped the probe.
 */
static void
probe_explain_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (exec_nesting_level == 0)
	{
		/*
		 * Consume the planner's verdict.  It is consumed even when we decide
		 * not to explain this statement, so that a verdict never leaks into
		 * an unrelated query.
		 */
		current_query_probed = (probe_hit_while_planning &&
								probe_explain_enabled &&
								(eflags & EXEC_FLAG_EXPLAIN_ONLY) == 0 &&
								!IsParallelWorker());
		probe_hit_while_planning = false;

		if (current_query_probed && probe_explain_analyze)
		{
			if (probe_explain_timing)
				queryDesc->instrument_options |= INSTRUMENT_TIMER;
			else
				queryDesc->instrument_options |= INSTRUMENT_ROWS;
			if (probe_explain_buffers)
				queryDesc->instrument_options |= INSTRUMENT_BUFFERS;
			if (probe_explain_wal)
				queryDesc->instrument_options |= INSTRUMENT_WAL;
		}
	}

	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);

	if (exec_nesting_level == 0 && current_query_probed)
	{
		/*
		 * Set up to track total elapsed time in ExecutorRun.  Allocate in the
		 * per-query context so that it goes away at ExecutorEnd.
		 */
		if (queryDesc->totaltime == NULL)
		{
			MemoryContext oldcxt;

			oldcxt = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);
			queryDesc->totaltime = InstrAlloc(1, INSTRUMENT_ALL, false);
			MemoryContextSwitchTo(oldcxt);
		}
	}
}

/*
 * ExecutorRun hook: all we need do is track nesting depth
 */
static void
probe_explain_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction,
						  uint64 count)
{
	exec_nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count);
		else
			standard_ExecutorRun(queryDesc, direction, count);
	}
	PG_FINALLY();
	{
		exec_nesting_level--;
	}
	PG_END_TRY();
}

/*
 * ExecutorFinish hook: all we need do is track nesting depth
 */
static void
probe_explain_ExecutorFinish(QueryDesc *queryDesc)
{
	exec_nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_FINALLY();
	{
		exec_nesting_level--;
	}
	PG_END_TRY();
}

/*
 * ExecutorEnd hook: print the plan of a probed statement into the log.
 */
static void
probe_explain_ExecutorEnd(QueryDesc *queryDesc)
{
	if (exec_nesting_level == 0 && current_query_probed &&
		queryDesc->totaltime)
	{
		MemoryContext oldcxt;
		ExplainState *es;
		double		msec;

		/*
		 * Operate in the per-query context, so any cruft is discarded later
		 * during ExecutorEnd.
		 */
		oldcxt = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);

		/* Make sure stats accumulation is done. */
		InstrEndLoop(queryDesc->totaltime);
		msec = queryDesc->totaltime->total * 1000.0;

		es = NewExplainState();
		es->analyze = (queryDesc->instrument_options && probe_explain_analyze);
		es->verbose = probe_explain_verbose;
		es->buffers = (es->analyze && probe_explain_buffers);
		es->wal = (es->analyze && probe_explain_wal);
		es->timing = (es->analyze && probe_explain_timing);
		es->summary = es->analyze;
		es->format = probe_explain_format;
		es->settings = probe_explain_settings;

		ExplainBeginOutput(es);
		ExplainQueryText(es, queryDesc);
		ExplainQueryParameters(es, queryDesc->params,
							   probe_explain_log_parameter_max_length);
		ExplainPrintPlan(es, queryDesc);
		if (es->analyze && probe_explain_triggers)
			ExplainPrintTriggers(es, queryDesc);
		if (es->costs)
			ExplainPrintJITSummary(es, queryDesc);
		ExplainEndOutput(es);

		/* Remove last line break */
		if (es->str->len > 0 && es->str->data[es->str->len - 1] == '\n')
			es->str->data[--es->str->len] = '\0';

		/* Fix JSON to output an object */
		if (probe_explain_format == EXPLAIN_FORMAT_JSON)
		{
			es->str->data[0] = '{';
			es->str->data[es->str->len - 1] = '}';
		}

		ereport(probe_explain_log_level,
				(errmsg("pg_probe_explain: planner probe hit; duration: %.3f ms  plan:\n%s",
						msec, es->str->data),
				 errhidestmt(true)));

		MemoryContextSwitchTo(oldcxt);
	}

	if (exec_nesting_level == 0)
		current_query_probed = false;

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}
