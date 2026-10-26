# Literature benchmarks

How good is ExVrp compared with the state of the art? This harness answers that on public
benchmark instances, against two references:

1. **PyVRP's published results.** PyVRP publishes, for every release, its average gap to the
   best-known solutions per problem variant. We share PyVRP's C++ core, so we should be about
   equal. Any difference comes from our own fork changes.
2. **Best-known and proven-optimal costs** from [CVRPLib](https://galgos.inf.puc-rio.br/cvrplib/en/instances)
   and [PyVRP/Instances](https://github.com/PyVRP/Instances). Many instances up to a few hundred
   clients are solved to proven optimality, so for those the gap is a gap to the true optimum.

## Running it on the benchmark machine

Step by step, for a person or an agent. Every step says what to expect; if a step does not
give that, stop and report it instead of working around it.

**1. Set up the checkout.** In the repo root, enter the dev shell (`devenv shell`, or let
direnv load it). It provides Elixir, GCC 13 and `7z`. Then:

```bash
mix deps.get && mix compile
```

This loads the precompiled solver. To benchmark a branch that changes C++ under `c_src/`, use
`EX_VRP_FORCE_BUILD=1 mix compile` instead, or the run measures the released solver, not the
branch (see CLAUDE.md, "NIF build gotcha").

**2. Check the machine is idle and count its cores.**

```bash
uptime                                   # load average should be near 0
grep -m1 "model name" /proc/cpuinfo      # the CPU model, for step 3
lscpu | grep -E "^(Socket|Core|Thread)"  # physical cores = sockets × cores per socket
```

Solves stop on wall-clock time, so any other load costs them iterations and makes gaps worse.
Use the **physical** core count for `--workers` below. Two solves sharing a core through
hyperthreading each get about half the iterations.

**3. Find the CPU's single-thread PassMark score.** Search the CPU model from step 2 on
<https://www.cpubenchmark.net> and take its **Single Thread Rating** (not the multi-thread CPU
Mark). The time limits are scaled by it, so the run matches PyVRP's protocol. If no score can
be found, leave `--passmark` out and say so in the results. The run then uses PyVRP's reference
CPU (≈2000), so a faster machine gets more search time than PyVRP had, and gaps look better
than a fair comparison would.

**4. Download the instances and check them.**

```bash
mix bench.lit.fetch
```

Expect a table of groups and instance counts, ending with `Every best-known solution checks
out on our model.` Any `PROBLEM` line means we read an instance differently from its source.
Stop there.

**5. Smoke test (about a minute).**

```bash
mix bench.lit.run --budget-scale 0.02 --limit 2 --out smoke.jsonl && mix bench.lit.report smoke.jsonl
```

Expect every solve to finish with a percentage (not `infeasible`) and a report table. The
gaps mean nothing at 2 % of the budget.

**6. The real run: four seeds, detached.** About 3 hours on 16 cores (the run prints its own
estimate on the first line of the log).

```bash
RUN=run-$(date +%F)
nohup mix bench.lit.run --passmark <score> --seeds 1,2,3,4 --workers <physical cores> \
  --out $RUN.jsonl > $RUN.log 2>&1 &
```

Follow it with `tail -f $RUN.log`. Each line `[n/total] group instance seed s: gap` is a finished
solve, and every minute it prints the running ones with their current gap. `wc -l $RUN.jsonl`
counts finished solves. If it stops for any reason (crash, reboot, Ctrl-C), run **the same
command with the same `--out`**: it skips finished solves and continues. A file with results at
another `--passmark` or `--budget-scale` is refused, so runs never mix.

**7. Report.**

```bash
mix bench.lit.report $RUN.jsonl --html $RUN.html > $RUN-report.txt
```

**8. Hand back:**

- `$RUN.jsonl` (all raw data), `$RUN-report.txt`, `$RUN.html` and `$RUN.log`;
- the CPU model, the PassMark score used (or that none was found), and `--workers`;
- anything unusual: warnings in the report, `PROBLEM` lines, a non-idle machine.

## What is benchmarked

### Groups

| Group      | Source                                                     | Default sample                                     | Compared against                        | Why it matters for Zelo                                             |
| ---------- | ---------------------------------------------------------- | -------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------- |
| `cvrp`     | PyVRP/Instances, X set (Uchoa 2017), 100 inst., n 100–1000 | 25, one per size stratum                           | PyVRP published + CVRPLib bound/optimum | Baseline routing quality                                            |
| `hfvrp`    | PyVRP/Instances, Pessoa 2018, 100 inst.                    | 25, one per size stratum                           | PyVRP published                         | Mixed fleet: vehicle types with own capacity, fixed and per-km cost |
| `mtvrptwr` | PyVRP/Instances, Yang 2023/24, 171 inst.                   | 30, five per class × size                          | PyVRP published (most proven optimal)   | Multi-trip: reloading at the depot, release times                   |
| `mdvrptw`  | PyVRP/Instances, Vidal 2013 (PR11–PR24), 28 inst.          | none: opt-in with `--groups mdvrptw --subset full` | PyVRP published                         | Several depots + time windows; Zelo plans from one start depot      |
| `solomon`  | CVRPLib, Solomon VRPTW, 56 inst., n 100                    | 12, two per class                                  | proven optimum (all)                    | Time windows                                                        |
| `hg200`    | CVRPLib, Homberger–Gehring, 60 inst., n 200                | 12, two per class                                  | proven optimum (all)                    | Time windows, larger                                                |
| `dimacs`   | CVRPLib, DIMACS 2021 ORTEC + Loggi                         | the 6 with n ≤ 500                                 | challenge best-knowns                   | Real delivery data (ORTEC is Dutch grocery)                         |

The sample (`sample.ex`) is drawn once with a fixed seed and committed, so runs stay comparable
over time. Stratifying on size and class makes the sample's mean gap an **unbiased estimate of
the full set's mean gap**, which is what PyVRP publishes. The price is sampling noise. With
per-instance gaps spread around ±0.25 %, a 25-instance sample has a standard error of about
±0.05 %. That is enough to tell 0.31 % from 0.45 %, but not from 0.33 %. `--subset full` runs
every instance.

### PyVRP's published gaps (in `benchmark_group.ex`)

From `docs/source/setup/benchmarks.rst` in PyVRP: average over the full set, ten seeds, one core
per run.

| PyVRP                   | CVRP   | HFVRP  | MTVRPTWR | MDVRPTW |
| ----------------------- | ------ | ------ | -------- | ------- |
| 0.13.0 (our fork point) | 0.31 % | 0.53 % | 0.33 %   | 0.69 %  |
| 0.14.0                  | 0.31 % | 0.51 % | 0.58 %   | 0.81 %  |

For scale, the same page lists HGS-CVRP at 0.11 % on CVRP and Google OR-Tools at 4.42 %.

We use the published numbers instead of running PyVRP ourselves. The comparison is only fair
because the run follows **PyVRP's protocol** (`docs/source/dev/benchmarking.rst`):

- one single-start solve per instance and seed, **each on one core**;
- time limits per group, in seconds on a CPU with PassMark ≈ 2000:
  - CVRP and HFVRP: 2.4 × n
  - MTVRPTWR: 600
  - MDVRPTW: 3600
- those limits are **scaled by `reference / passmark`** of the machine;
- gaps against the best-known costs in `PyVRP/Instances`.

The report flags any run at `--budget-scale` ≠ 1 as not comparable with these numbers.
Short-budget runs are still useful for smoke tests and trends.

### Not included (yet)

- **VRPTW and PCVRPTW at PyVRP's protocol.** These are the HG 1000-client sets at two hours per
  instance, about 120 CPU-h per seed each. Adding them is one group entry each.
- **XL (up to 10 001 clients) and Belgium (up to 30 000).** `ExVrp.Read` builds Euclidean matrices
  as nested lists, which won't scale to 10k nodes; the reader would have to build binary
  matrices directly.
- **Running PyVRP side by side**, for a per-instance head-to-head instead of averages. Not
  needed while the published averages answer the question.
- VRPB, PDPTW and SDVRPTW: features Zelo doesn't use, and we support no pickup-delivery or split
  deliveries.

## How much time it takes

At the full protocol, on a CPU about twice PyVRP's reference, with 16 cores and one seed:

| Run                         | CPU-hours    | Wall-clock on 16 cores                                             |
| --------------------------- | ------------ | ------------------------------------------------------------------ |
| Default sample (110 inst.)  | ~12          | ~45 min (the floor is the longest single solve, X-n957 at ~20 min) |
| Default sample, 4 seeds     | ~46          | ~3 h                                                               |
| Full sets (incl. MDVRPTW)   | ~65 per seed | ~4 h per seed                                                      |
| `--budget-scale 0.1` sample | ~1.2         | ~5 min                                                             |

The run prints its own estimate before it starts. The longest solves are started first, so the
run doesn't end on one long solve while the other cores sit idle.

## Multiple seeds: we probably want them

`num_starts: K` is exactly K independent single-start solves with seeds `base..base+K-1`, keeping
the best (`ExVrp.Solver`'s parallel solve). Running with `--seeds 1,2,3,4` therefore gives both:

- the **single-start** mean, which is what PyVRP's protocol and its published numbers use;
- the **best-of-4**, which is what `num_starts: 4` would have returned.

So there is no separate multi-start mode. More seeds cost proportionally more CPU time.

**Run with several seeds, at least for the first real run.** One seed answers "how do we
compare with PyVRP", but not "does a single start get stuck in a bad local optimum". The
search restarts from its best solution when it stops improving, but a start can still settle
in a worse region than another start would. The gap between the single-start mean and the
best-of-K measures exactly that. The short local check already showed it on X: 0.66 % for
the average seed against 0.32 % for the better of two, at 2 % of the budget. At full budget
the difference should shrink; how much is what the run will tell us.

It also matters for production. Zelo already multi-starts: the nightly plan solves with
`FlavorPlacement.starts_per_runner/0` starts, which is cores − 1 on Northflank. The
best-of-K numbers show what those extra starts buy, and the per-seed `progress` tables
show whether the seeds diverge early (different regions) or late (luck near the end).

The recommended first run on the dedicated machine:

```bash
mix bench.lit.run --passmark <score> --seeds 1,2,3,4 --out run-$(date +%F).jsonl   # ~3 h on 16 cores
```

## Iteration speed

The report's `iter/s` is iterations per second of search time (`search_ms`, so without setup
and model loading), as the median per group. It also lists each group's three slowest
instances. It is wall-clock speed under the run's own load: a signal for spotting slow
instances, not a speed benchmark. `mix bench.speed` measures speed precisely, as instructions
per iteration. On a laptop shared with other work, the numbers drop by half or more; use
the idle machine.

Iterations get more expensive as instances grow, and also with the number of vehicles the
model allows. A standalone 10 s solve on a lightly loaded laptop:

| Instance                 | Clients | Vehicles allowed | Iterations/s |
| ------------------------ | ------- | ---------------- | ------------ |
| X-n115-k10               | 114     | 114              | 837          |
| C104 (Solomon)           | 100     | 25               | 730          |
| X106-FSMD (mixed fleet)  | 105     | 315              | 501          |
| X-n957-k87               | 956     | 956              | 112          |
| X1001-FSMF (mixed fleet) | 1000    | 5000             | 35           |

X1001-FSMF is the outlier, and it is still more than 100 % off its best known after 2 % of the
budget. Two causes show in its record:

- it allows 5000 vehicles (an unlimited fleet over 5 types), against 24 routes in the best-known
  solution, and the per-iteration work grows with the vehicles the model allows;
- the initial solution uses 97 routes, and with fixed vehicle costs dominating the objective,
  the search spends its iterations removing routes (87 left after 48 s).

Zelo's models allow 1–30 vehicles, so production does not hit this, but an unlimited fleet is
a known weak spot to look into.

## How the groups relate to Zelo's plans

The five real-depot models in `priv/benchmark_data/production/` share a shape:

- every route starts at one depot (some end at another), so multi-depot benchmarks do not apply;
- every client has a time window, with a median of 3–5 hours in a 15–16 hour shift; this is
  where the difficulty lies;
- 13–20 stops per route, about 8 minutes of service each;
- vehicles share capacity and costs and differ only in routing profile, and loads use 22–42 %
  of capacity;
- every client is optional, with a large prize; reload depots are set but `max_reloads` is 0;
- the objective is mostly driving time, and distances are real road distances.

The closest public groups are therefore the time-window ones (Solomon and Homberger–Gehring,
especially the mixed RC classes) and ORTEC/Loggi for real road data. Mixed fleet (`hfvrp`) and
multi-trip (`mtvrptwr`) stay in the default run: they are features ExVrp has, and these are
the benchmarks that exercise them. Multi-depot does not apply, so it is opt-in. Nothing public
covers per-vehicle routing profiles, 8 load dimensions or separate end depots; the production
benchmarks cover those.

## First results

A short local check (2 % of the budget, 2 instances per group, 2 seeds, on a loaded laptop)
already found the **proven optimum on every Solomon and Homberger–Gehring 200 instance it ran**.
On X it was at 0.66 % on average, 0.32 % for the better seed. These numbers are not comparable
with PyVRP's yet; the full run on the dedicated machine is.

## Why the gaps can be trusted: the fetch check

The sources state best-known costs on different scales:

- X uses rounded integer distances;
- VRPTW and MTVRPTWR use DIMACS, ×10 truncated;
- MDVRPTW uses ×1000;
- HFVRP states costs in original units (35170.24), while its instance files are already scaled ×100.

Getting one of those wrong makes every gap meaningless while still looking plausible. So
`mix bench.lit.fetch` rebuilds **every** best-known solution as a solution of our own model
(`best_known_solution.ex`) and evaluates it with our cost function. It fails if:

- the solution is infeasible on our model (we read the instance differently from the source), or
- its cost doesn't match what the source states (up to a power of ten), or
- it is cheaper than CVRPLib's upper bound (our evaluation would be wrong).

All 527 fetched best-known solutions pass. That covers mixed fleets mapped onto the right vehicle
types, multi-trip routes with reloads, multi-depot routes and explicit road-distance matrices.
Gaps are then always computed in our own units.

Two best-known values are kept per instance:

- `bks`: the source's own solution file. This is what PyVRP's published gaps are measured
  against, so the PyVRP comparison uses it.
- `cvrplib_bound`: CVRPLib's current upper bound, scraped on every fetch. Records keep falling,
  and 12 X instances already have a newer bound than PyVRP's files. "Gap to best known" uses the
  lower of the two, and an instance counts as **optimal** only when CVRPLib marks that bound
  proven optimal.

The fetch also converts Solomon-format `.txt` files to VRPLIB. And it needed a fix in
`ExVrp.Read`: the ORTEC and Loggi instances store their road distances as a lower triangle
(`EDGE_WEIGHT_FORMAT : LOWER_ROW`), which `Read` used to misread silently. It now handles all
four triangular formats, as PyVRP's reader does.

## Reading the report

`mix bench.lit.report run.jsonl` prints, per group:

| Column                        | Meaning                                                                                                                                              |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inst`, `seeds`               | instances and seeds in the file                                                                                                                      |
| `gap→BKS`                     | mean gap to the source's best-known cost: seeds averaged per instance, then instances weigh equally (PyVRP's method)                                 |
| `±se`                         | standard error of that mean across instances: the sampling noise                                                                                     |
| `PyVRP 0.13` / `0.14`, `vs …` | the published gap, and our verdict: **≈ noise** when the difference is within 2 standard errors, otherwise **better** or **worse** by the difference |
| `gap→best`                    | mean gap to the lowest known cost (CVRPLib's newer bounds included)                                                                                  |
| `best-of`                     | mean gap of the best seed per instance, i.e. the `num_starts: K` result                                                                              |
| `optimum`                     | proven optima reached by the best seed / proven optima in the group                                                                                  |
| `iter/s`                      | median iterations per second of search time per solve; see [Iteration speed](#iteration-speed)                                                       |

Then:

- **Mean gap at 10 / 25 / 50 / 100 % of the budget,** from each solve's convergence trace. "—"
  means no feasible solution yet at that point. This shows whether more time would help, and
  how a shorter budget would have scored, without rerunning.
- **The three worst instances per group,** where to look first.
- **The three slowest instances per group,** in iterations per second.
- **Warnings** for infeasible solves and for budget scales ≠ 1.

`--html report.html` writes a self-contained page with the same table and, per group, a
gap-over-budget line and a per-instance gap-vs-size scatter with PyVRP's published gaps as
dashed reference lines. It works in light and dark mode and can be shared as is.

### Caveats when interpreting

- **Sample vs full set.** PyVRP's numbers are full-set means over ten seeds; ours is a sample
  estimate, usually from fewer seeds. Trust the verdict column, which accounts for the sample
  size, over the raw difference.
- **PassMark is approximate.** It is how PyVRP normalises CPUs, but a 10 % error in the score
  is a 10 % budget difference. On these instances that moves gaps by a few hundredths of a
  percent at most.
- **Wall-clock budgets need an idle machine.** Other load means fewer iterations and worse
  gaps. Use the uncontested machine for real numbers.
- **The convergence trace is sampled about once a second** (`on_progress`). Fine for the
  10 / 25 / 50 / 100 % profile, too coarse for sub-second timing.

## Output format

One JSON object per line, per (instance, seed). Every solve records as much as the solver
reports, so later questions can be answered from the file without rerunning. This one is
a real record from a short local run:

```json
{"instance": "X-n115-k10", "group": "cvrp", "seed": 1, "num_clients": 114,
 "objective": 12747, "feasible": true, "distance": 12747, "duration": 12747, "num_routes": 10,
 "bks": 12747, "best_known": 12747, "optimal": true,
 "budget_s": 5.5, "load_ms": 56, "time_ms": 5560, "search_ms": 5464,
 "iterations": 2174, "improvements": 19, "restarts": 1,
 "initial_solution": {"at_ms": 100, "feasible": true, "distance": 15070, "duration": 15070,
                      "num_routes": 10, "num_clients": 114},
 "progress": {"columns": ["elapsed_ms", "iteration", "best_cost", "current_cost", "feasible",
                          "improvements", "restarts", "num_routes", "num_clients",
                          "best_distance", "total_duration"],
              "rows": [[1001, 395, 12823, 12823, true, 14, 0, 10, 114, 12823, 12823],
                       [2001, 779, 12747, 12801, true, 19, 0, 10, 114, 12747, 12747], ...]},
 "trace": [[1001, 12823], [2001, 12747]],
 "passmark": null, "budget_scale": 0.02, "commit": "cccccdf",
 "cpu": "AMD Ryzen 7 PRO 6850U with Radeon Graphics", "cores": 16}
```

| Field                                    | Meaning                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `objective`                              | `Solution.cost/2`: distance plus vehicle costs plus missed prizes; `null` when infeasible                                                                                                                                                                                                                                                     |
| `load_ms`                                | reading the instance file into a model                                                                                                                                                                                                                                                                                                        |
| `time_ms`                                | the whole solve: problem data, initial solution and search                                                                                                                                                                                                                                                                                    |
| `search_ms`                              | the search alone; `time_ms − search_ms` is setup                                                                                                                                                                                                                                                                                              |
| `iterations`, `improvements`, `restarts` | the search's final counters; restarts are its restarts from the best solution after too long without improvement                                                                                                                                                                                                                              |
| `initial_solution`                       | the solution the search started from, and when it was ready (ms after the solve started)                                                                                                                                                                                                                                                      |
| `progress`                               | the search's progress report, about once a second, as a column table: `elapsed_ms` since the search started, iterations so far, best and current (penalised) cost, whether the best is feasible, the counters, and the best solution's routes, clients, distance and duration. Iterations per second over time is the difference of two rows. |
| `trace`                                  | the best feasible cost each time it improved, from `progress` plus the final result (the last improvement can fall between two reports)                                                                                                                                                                                                       |

A full sample run with one seed writes about 110 records; with the progress table at one row
per second, the file stays in the tens of megabytes.

## Code map

| File                                                               | Role                                                                                                 |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `benchmark_group.ex`                                               | The groups: source, rounding, budget protocol, PyVRP's published gaps. The one place to add a group. |
| `sample.ex`                                                        | The committed default sample                                                                         |
| `fetch.ex`, `download.ex`, `cvrplib_table.ex`, `solomon_format.ex` | Downloading, CVRPLib bound scraping, Solomon → VRPLIB                                                |
| `best_known_solution.ex`                                           | `.sol` parsing and evaluation on our model                                                           |
| `manifest.ex`, `benchmark_instance.ex`                             | The fetched instance list (gitignored `priv/benchmark_data/literature/manifest.json`)                |
| `runner.ex`, `run_settings.ex`, `progress_board.ex`                | The resumable run and its live progress                                                              |
| `search_recording.ex`                                              | What each solve records while it runs: initial solution, progress table, best-cost trace             |
| `group_summary.ex`, `gap.ex`, `html_report.ex`                     | The report                                                                                           |
| `../ab_benchmark/solve.ex`                                         | The single solve, shared with the A/B harness                                                        |
| `../mix/tasks/bench.lit.*.ex`                                      | `mix bench.lit.fetch` / `run` / `report`                                                             |

To add a group (say VRPTW at PyVRP's protocol), add a `%BenchmarkGroup{}` with its source glob,
rounding, budget and published gaps, refetch, and add its sample to `sample.ex`.
