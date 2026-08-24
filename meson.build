# Copyright (c) 2026, PostgreSQL Global Development Group

pg_probe_explain_sources = files(
  'pg_probe_explain.c',
)

if host_system == 'windows'
  pg_probe_explain_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'pg_probe_explain',
    '--FILEDESC', 'pg_probe_explain - log plans of queries whose planning tripped a probe',])
endif

pg_probe_explain = shared_module('pg_probe_explain',
  pg_probe_explain_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += pg_probe_explain

tests += {
  'name': 'pg_probe_explain',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'tests': [
      't/001_probe_join_semi.pl',
    ],
  },
}
