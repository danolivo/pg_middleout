# contrib/pg_middleout/Makefile

MODULE_big = pg_middleout
OBJS = pg_middleout.o

REGRESS = memoize_subplan

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_middleout
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
