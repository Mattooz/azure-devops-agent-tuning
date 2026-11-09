# Azure DevOps self-hosted agent: tuning guide

Findings from running the same pipelines on two self-hosted setups and chasing every
difference down to the agent's source code:

- **A, container jobs**: the agent runs on the host as a service; every job declares
  `container:` and the agent runs each step with `docker exec`.
- **B, agent in a container**: the agent runs inside a container that already holds the
  toolchain, one job per container (`--once`); a small supervisor keeps N agents warm.

Agent version **5.281.1** (Linux x64), Ubuntu 24.04 host, rootless Podman 4.9 with a
`docker` shim. All measurements ran on a **Contabo Cloud VPS 8** (8 vCPU, 24 GB RAM); both
setups were limited to 6 CPUs and 14 GiB per job, and only one job ran at a time. Source references point to the
[`v5.281.1` tag](https://github.com/microsoft/azure-pipelines-agent/tree/v5.281.1).

## Quick wins

| # | What | Applies to | Effect measured |
|---|------|------------|-----------------|
| 1 | Make sure `~/.config` exists for the agent's user | agent in a container, any agent whose user has no `~/.config` | per-step overhead 1.25 s → 0.50 s; connection-data calls per job 78 → 5 |
| 2 | `AGENT_USE_NODE20_IN_UNSUPPORTED_SYSTEM=true` and `AGENT_USE_NODE24_IN_UNSUPPORTED_SYSTEM=true` (glibc images only) | every Linux agent | B 3.13 s → 1.25 s per step; A 0.92 s → 0.80 s |
| 3 | Give the job container its own limits in `container.options` | container jobs on Podman/Docker | the agent unit's `CPUQuota`/`MemoryMax` do not reach job containers |
| 4 | `workspace: clean: all` on every job | host agents | removes leftover `target/`, caches and files of the previous job (fair, reproducible jobs) |
| 5 | Check out the same set of repositories in jobs that share build paths | host agents | the work folder (`_work/<n>`) depends on that set |
| 6 | Count your parallel jobs before adding warm agents | private projects | the free tier gives **one** self-hosted parallel job |
| 7 | `--init` in `container.options` | container jobs on **Podman** | `rm --force` waits Podman's 10 s stop timeout on every job (~12 s measured per job); expected ~10 s saved per job, not measured yet |

Result for a pipeline of 4 jobs × 15 trivial script steps, per-step overhead (mean of 60 steps):

| Setup | Per step |
|---|---|
| B (agent in container), out of the box | 3.13 s |
| B + #2 | 1.25 s |
| B + #2 + #1 | **0.50 s** |
| A (container jobs) + #2 | 0.80 s |

Once fixed, the agent in a container is faster per step than container jobs, as expected: it
runs each step directly instead of going through `docker exec`.

On a realistic pipeline of 12 short jobs (npm, Rust, Postgres, Python, artifact fan-out),
with equal limits and warm caches: **A 14:58, B 9:52**. Container jobs pay ~20 s per job to
start and stop the job container ([06](docs/06-results-realistic-pipeline.md)).

## Realistic gains

Everything in this guide makes the **agent** cheaper: how it starts a job, runs a step, starts
and stops a job container, and talks to the server. None of it makes your **tools** faster.
`npm`, `pip`/`uv`, `cargo`, `maven`, `gradle`, `dotnet`, compilers and test runners take the
same time before and after: in the realistic benchmark the slowest job (Python checks, ~2 min)
barely moved.

So the gain is a fixed amount per step and per job, and it matters in proportion to how many
steps and jobs a pipeline has, not to how long they run:

```
time saved ≈ steps × (saving per step) + jobs × (saving per job)
```

Saving per step, measured: up to **2.6 s** for an agent in a container (3.13 s → 0.50 s),
**0.1 s** for container jobs. Saving per job, estimated: **~10 s** for container jobs if the
job container stops at once.

| Pipeline | Steps / jobs | Time in tools | Agent overhead removed | Share of the run |
|---|---|---|---|---|
| many short checks (lint, unit tests, packaging, fan-out) | 200 / 20 | ~10 min | **~9 min** | large |
| a typical CI (build, test, publish) | 40 / 5 | ~15 min | ~2 min | ~10 % |
| one long build (a 30-minute compile and test) | 10 / 1 | ~30 min | ~25 s | ~1 % |

Rows are illustrations from the per-step and per-job savings above, for an agent in a container;
only the first two numbers of each row are inputs.

To speed up the tools themselves, look elsewhere: caches keyed on lockfiles (`Cache@2`),
incremental builds, test splitting, more parallel jobs, faster machines. The one tool-related
point here is to give every setup the **same** CPU and memory limits, or the comparison measures
the machine instead of the agent ([02](docs/02-container-jobs-rootless-podman.md)).

## Guides

1. [Agent in a container: per-step overhead](docs/01-agent-in-container-overhead.md):
   findings #1 and #2, with the code path that causes them.
2. [Container jobs on rootless Podman](docs/02-container-jobs-rootless-podman.md):
   what it takes to make them work, and resource limits.
3. [Ephemeral agents and a warm pool](docs/03-ephemeral-agents-warm-pool.md):
   `--once`, deregistration, orphaned registrations, self-update.
4. [Pipeline design notes](docs/04-pipeline-design.md): work folders, clean workspaces,
   `Cache@2`, parallel jobs.
5. [How to measure](docs/05-measuring.md): per-step timings from the REST API, worker
   diagnostic logs, what was ruled out.
6. [Results on a realistic pipeline](docs/06-results-realistic-pipeline.md): job by job, where
   container jobs lose their time, possible gains.
7. [More from the source](docs/07-more-from-the-source.md): other per-job and per-step costs
   found by reading the agent's code, the settings that remove them, and the fixed costs that
   have none (static analysis, mostly not measured).

The benchmark pipelines, the agent images, the warm-pool supervisor and the measuring
scripts are in [examples/](examples/).
