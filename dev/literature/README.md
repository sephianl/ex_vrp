# Literature benchmarks

How good is ExVrp compared with the state of the art? This harness answers that on public
benchmark instances, against two references:

1. **PyVRP's published results.** PyVRP publishes, for every release, its average gap to the
   best-known solutions per problem variant. We share PyVRP's C++ core, so we should be about
   equal. Any difference comes from our own fork changes.
2. **Best-known and proven-optimal costs** from [CVRPLib](https://galgos.inf.puc-rio.br/cvrplib/en/instances)
   and [PyVRP/Instances](https://github.com/PyVRP/Instances). Many instances up to a few hundred
   clients are solved to proven optimality, so for those the gap is a gap to the true optimum.

## Quick start

```bash
# once: download instances (needs 7z, in devenv.nix) and check every best-known solution
mix bench.lit.fetch

# local smoke: 2% of the budget, 2 instances per group (~1 minute)
mix bench.lit.run --budget-scale 0.02 --limit 2 --out smoke.jsonl
mix bench.lit.report smoke.jsonl

# the real run, on an idle machine
mix bench.lit.run --passmark <single-thread PassMark of the CPU> --out run-$(date +%F).jsonl
mix bench.lit.report run-*.jsonl --html report.html
```

Look the CPU's **single-thread** PassMark score up on cpubenchmark.net. Without `--passmark` the
run assumes PyVRP's reference CPU (≈2000), which gives the longest, safest budgets.

The run is **resumable**. Each finished solve is appended to the output file at once, and
rerunning with the same `--out` skips what is already there. Ctrl-C and reboots are fine. A
file holding results at a different `--passmark` or `--budget-scale` is refused, so runs never mix.

While running, it prints one line per finished solve (`[37/140] cvrp X-n251-k28 seed 1: 0.21%`).
Every minute it also prints a line per running solve with its elapsed time and current gap.

## What is benchmarked

### Groups

| Group      | Source                                                     | Default sample            | Compared against                        | Why it matters for Zelo                                             |
| ---------- | ---------------------------------------------------------- | ------------------------- | --------------------------------------- | ------------------------------------------------------------------- |
| `cvrp`     | PyVRP/Instances, X set (Uchoa 2017), 100 inst., n 100–1000 | 25, one per size stratum  | PyVRP published + CVRPLib bound/optimum | Baseline routing quality                                            |
| `hfvrp`    | PyVRP/Instances, Pessoa 2018, 100 inst.                    | 25, one per size stratum  | PyVRP published                         | Mixed fleet: vehicle types with own capacity, fixed and per-km cost |
| `mtvrptwr` | PyVRP/Instances, Yang 2023/24, 171 inst.                   | 30, five per class × size | PyVRP published (most proven optimal)   | Multi-trip: reloading at the depot, release times                   |
| `mdvrptw`  | PyVRP/Instances, Vidal 2013 (PR11–PR24), 28 inst.          | 10, one per stratum       | PyVRP published                         | Several depots + time windows                                       |
| `solomon`  | CVRPLib, Solomon VRPTW, 56 inst., n 100                    | 12, two per class         | proven optimum (all)                    | Time windows                                                        |
| `hg200`    | CVRPLib, Homberger–Gehring, 60 inst., n 200                | 12, two per class         | proven optimum (all)                    | Time windows, larger                                                |
| `dimacs`   | CVRPLib, DIMACS 2021 ORTEC + Loggi                         | the 6 with n ≤ 500        | challenge best-knowns                   | Real delivery data (ORTEC is Dutch grocery)                         |

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

| Run                         | CPU-hours    | Wall-clock on 16 cores                                                  |
| --------------------------- | ------------ | ----------------------------------------------------------------------- |
| Default sample              | ~16          | ~1–1.5 h (the floor is the longest single solve, an MDVRPTW at ~30 min) |
| Default sample, 4 seeds     | ~64          | ~4–5 h                                                                  |
| Full sets                   | ~60 per seed | ~4 h per seed                                                           |
| `--budget-scale 0.1` sample | ~1.6         | ~10 min                                                                 |

The run prints its own estimate before it starts. The longest solves are started first, so the
run doesn't end on one long solve while the other cores sit idle.

## Multiple starts

`num_starts: K` is exactly K independent single-start solves with seeds `base..base+K-1`, keeping
the best (`ExVrp.Solver`'s parallel solve). Running with `--seeds 1,2,3,4` therefore gives both:

- the **single-start** mean, which is what PyVRP's protocol and its published numbers use;
- the **best-of-4**, which is what `num_starts: 4` would have returned.

So there is no separate multi-start mode. More seeds cost proportionally more CPU time.

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
| `iter/s`                      | median iterations per second per solve: a rough speed signal, not a speed benchmark (use `mix bench.speed` for that)                                 |

Then:

- **Mean gap at 10 / 25 / 50 / 100 % of the budget,** from each solve's convergence trace. "—"
  means no feasible solution yet at that point. This shows whether more time would help, and
  how a shorter budget would have scored, without rerunning.
- **The three worst instances per group,** where to look first.
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

One JSON object per line, per (instance, seed):

```json
{"instance": "X-n251-k28", "group": "cvrp", "seed": 1, "num_clients": 250,
 "objective": 38735, "feasible": true, "distance": 38735, "num_routes": 28,
 "bks": 38684, "best_known": 38684, "optimal": true,
 "budget_s": 274.3, "time_ms": 274512, "iterations": 812345,
 "trace": [[1001, 41022], [2003, 40210], ...],
 "passmark": 4200, "budget_scale": 1.0, "commit": "f8f813a",
 "cpu": "AMD Ryzen 9 7950X 16-Core Processor", "cores": 32}
```

`objective` is `Solution.cost/2` (distance plus vehicle costs), `nil` when infeasible. `trace`
holds each improvement of the best feasible cost as `[ms since the search started, cost]`.

## Code map

| File                                                               | Role                                                                                                 |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `benchmark_group.ex`                                               | The groups: source, rounding, budget protocol, PyVRP's published gaps. The one place to add a group. |
| `sample.ex`                                                        | The committed default sample                                                                         |
| `fetch.ex`, `download.ex`, `cvrplib_table.ex`, `solomon_format.ex` | Downloading, CVRPLib bound scraping, Solomon → VRPLIB                                                |
| `best_known_solution.ex`                                           | `.sol` parsing and evaluation on our model                                                           |
| `manifest.ex`, `benchmark_instance.ex`                             | The fetched instance list (gitignored `priv/benchmark_data/literature/manifest.json`)                |
| `runner.ex`, `run_settings.ex`, `progress_board.ex`                | The resumable run, traces, live progress                                                             |
| `group_summary.ex`, `gap.ex`, `html_report.ex`                     | The report                                                                                           |
| `../ab_benchmark/solve.ex`                                         | The single solve, shared with the A/B harness                                                        |
| `../mix/tasks/bench.lit.*.ex`                                      | `mix bench.lit.fetch` / `run` / `report`                                                             |

To add a group (say VRPTW at PyVRP's protocol), add a `%BenchmarkGroup{}` with its source glob,
rounding, budget and published gaps, refetch, and add its sample to `sample.ex`.
