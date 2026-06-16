# pg_middleout

An optimiser-helper extension that adds a top-down pass after PostgreSQL's
normal bottom-up planning ("middle-out"), giving the planner a few paths it
wouldn't reach on its own.

## Overview

The first feature is **subplan memoization**. A correlated subquery that the
planner cannot pull up into a join becomes a `SubPlan`, and that `SubPlan` is
re-executed for every outer row — even when the same correlation values recur.
Core PostgreSQL only attaches a `Memoize` cache to the inner side of a
parameterised nested loop, never to such a `SubPlan`, so the repeated work is
left on the table. This is common in ORM- and tool-generated SQL, where a join
is often expressed as a correlated scalar subquery.

### Why core cannot do this, and why a separate pass is needed

The obstacle is one of ordering. A `SubPlan` is built during the parent query's
*expression preprocessing* — before the parent's own paths are generated. At
that moment the planner knows neither **how many times** the subplan will be
executed nor **the distribution of its parameter values**: both depend on where
the subplan ends up in the finished upper plan, and both are exactly what
`Memoize` costing needs (the number of calls and the number of distinct keys,
which together give the cache hit ratio). Those numbers only exist once
upper-query planning has finished — by which point every subplan has already
been planned and frozen. (Core acknowledges the same difficulty in
`make_subplan`, where it cannot decide a hashed vs. plain EXISTS subplan because
it is "much too early in planning the outer query to be able to guess" the
execution count, and defers that one choice to `setrefs.c`.)

`pg_middleout` resolves this chicken-and-egg by running *after* upper-query
planning, when the calling context is finally known: when caching then looks
profitable, it caps the subplan with a `Memoize` node keyed on the correlation
parameters, so a repeated parameter set returns the cached result instead of
re-running the subplan.

## How it works

The extension installs `create_upper_paths_hook` and runs once the final upper
relation has been planned (`UPPERREL_FINAL`):

1. It walks the chosen cheapest path tree and collects the correlated `SubPlan`
   nodes in each node's target list and qualifiers.
2. For each candidate it builds a `Memoize` path over the subplan's chosen path,
   keyed on the correlation parameters, and estimates its rescan cost using the
   same model core uses for nested-loop Memoize.
3. If memoization is predicted to win (or `force_memoize_subplan` is on), it
   swaps the plan the `SubPlan` points to — addressed by `plan_id` in the global
   subplans list — for the `Memoize`-capped plan. The `SubPlan` node itself is
   left untouched.

The decision is made at plan time from the planner's row estimates (the number
of executions is approximated by the driving relation's row count), not at run
time.

## Building and enabling

Built like any contrib module:

```
make
make install
```

Because the feature is driven by a planner hook, the library must be loaded into
the backend — either per session:

```sql
LOAD 'pg_middleout';
```

or for the whole instance via `shared_preload_libraries = 'pg_middleout'` in
`postgresql.conf` (requires a restart).

```sql
LOAD 'pg_middleout';
EXPLAIN (COSTS OFF)
SELECT count(*) FROM upper u
WHERE u.y < (SELECT avg(s.x) FROM sub s WHERE s.x = u.x);
--  ...
--  Filter: ((u.y)::numeric < (SubPlan expr_1))
--  SubPlan expr_1
--    ->  Memoize
--          Cache Key: u.x
--          ->  Aggregate ...
```

## Configuration

- `pg_middleout.memoize_subplan` (`USERSET`, default `on`)
  Enable/disable caching results of correlated subplans. It is similar to how a
  nested-loop join caches its inner side to avoid unnecessary rescanning.

- `pg_middleout.force_memoize_subplan` (`SUSET`, default `off`)
  Skip the extension's own cost check and always insert the `Memoize` node for
  any eligible subplan. Intended mainly for debugging and testing.

The feature also respects the core `enable_memoize` setting: turning that off
disables this extension's behaviour too.

## What is (not) memoized

To stay correct and conservative, a subplan is **skipped** when it:

- is not correlated (carries no parameters to key the cache on);
- references query levels above its immediate parent;
- uses the min/max-aggregate optimisation (its correlated InitPlans don't
  survive being wrapped in `Memoize`);
- contains grouping sets;
- contains volatile functions anywhere in its tree — caching would change how
  often a volatile function such as `random()` or `nextval()` is evaluated.

This is an early-stage feature; thorough testing is recommended before relying
on it in production, which is why `force_memoize_subplan` is restricted to
superusers.
