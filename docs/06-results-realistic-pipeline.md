# Results on a realistic pipeline

The `mix` benchmark ([examples/pipelines](../examples/pipelines)) has 12 short jobs that do
real work, in two stages:

- an npm app: install, type-check, unit tests, build and package;
- a Rust crate: fmt, build, test, clippy, with `Cache@2`;
- Postgres: migrations applied to a fresh database;
- Python: `uv` with ruff and pytest;
- a fan-out of three jobs that download and verify the packaged artifact;
- a report job.

Only one job runs at a time (one parallel job), so the run time is the sum of the jobs plus
the gaps between them.

Machine: Contabo Cloud VPS 8 (8 vCPU, 24 GB RAM), Ubuntu 24.04. Both setups got the same
limits (6 CPUs, 14 GiB), `workspace: clean: all`, warm caches and the
glibc knobs; the agent in a container also got `~/.config`.

| | A: container jobs | B: agent in a container |
|---|---|---|
| Run time | **14:58** | **9:52** |
| Sum of the jobs | 764 s | 475 s |

Per job (seconds):

| Job | A | B |
|---|---|---|
| fmt | 37 | 14 |
| migrations (Postgres) | 44 | 19 |
| python (ruff, pytest) | 143 | 118 |
| npm install | 65 | 38 |
| type-check | 103 | 61 |
| unit tests | 81 | 56 |
| build and package | 106 | 83 |
| Rust crate | 62 | 41 |
| verify × 3 | 33 / 30 / 30 | 12 / 10 / 10 |
| report | 30 | 13 |

## Where A loses its time

Task durations summed over the run:

| Task | A | B |
|---|---|---|
| Stop Containers (12 jobs) | **146 s**, ~12 s per job | — |
| Initialize containers (12 jobs) | **112 s**, ~9 s per job | — |
| Initialize job (12 jobs) | included above | 17 s in total |

The container lifecycle costs A about **4 minutes per run**, about **20 s per job**. On a
pipeline of many short jobs this is most of the difference. The rest is a slower task time in
each step, the `docker exec` of every step and of its setup.

## Possible gains for A

| Change | Expected gain | Notes |
|---|---|---|
| Stop the job container at once: `--init` in `container.options`, or `rm --force --time 0` in the shim | up to **~10 s per job** (~2 min per run here) | Podman only. The agent removes the container with `rm --force`. Podman then sends `SIGTERM` and waits 10 s before `SIGKILL`, and the container's PID 1 (`tail -f /dev/null`) ignores `SIGTERM`. See [02](02-container-jobs-rootless-podman.md#stopping-the-job-container-podman-waits-10-s). Not measured yet. |
| Fewer, longer jobs | ~20 s per job removed | Every job pays the container lifecycle; merge short jobs that need no isolation. |
| Keep the job image small and local | part of the ~9 s start | Pull is skipped for a local image (shim); creation time grows with the image's layers and with `--userns=keep-id`. |
| A per-run cache for tools fetched at run time (e.g. `uv` caching its tools) | on the slowest job | Same for both setups. |

The agent in a container pays none of the container lifecycle. Its own costs per job are
starting the warm agent's worker and checking out, which it shares with A.
