# contrib/pg_probe_explain/Makefile

MODULE_big = pg_probe_explain
OBJS = \
	$(WIN32RES) \
	pg_probe_explain.o
PGFILEDESC = "pg_probe_explain - log plans of queries whose planning tripped a probe"

TAP_TESTS = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_probe_explain
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
