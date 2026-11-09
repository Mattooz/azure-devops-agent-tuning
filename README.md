# Azure DevOps self-hosted agent: tuning guide

Findings from running the same pipelines on two self-hosted setups and chasing every
difference down to the agent's source code:

- **A, container jobs**: the agent runs on the host as a service; every job declares
  `container:` and the agent runs each step with `docker exec`.
- **B, agent in a container**: the agent runs inside a container that already holds the
  toolchain, one job per container (`--once`); a small supervisor keeps N agents warm.

Agent version **5.281.1** (Linux x64), Ubuntu 24.04 host, rootless Podman 4.9 with a
`docker` shim. Source references point to the
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

Result for a pipeline of 4 jobs × 15 trivial script steps, per-step overhead (mean of 60 steps):

| Setup | Per step |
|---|---|
| B (agent in container), out of the box | 3.13 s |
| B + #2 | 1.25 s |
| B + #2 + #1 | **0.50 s** |
| A (container jobs) + #2 | 0.80 s |

Once fixed, the agent in a container is faster per step than container jobs, as expected: it
runs each step directly instead of going through `docker exec`.

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
