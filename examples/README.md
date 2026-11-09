# Examples

The files behind the measurements in the guide: the two agent setups, the pipelines that were run
on both, and the scripts that read the results. Copy what you need and replace the placeholders.

Nothing here is ready to run as is. Every value that depends on your organization is a
placeholder (`<org>`, `<project>`, `<github-service-connection>`, `<owner>/<repo>`, `<host-user>`,
numeric pool ids), and the environment variables listed below must be set.

## The two setups

- **A, container jobs** (`pipelines/a-*.yml`): the agent runs on the host as a systemd user unit.
  Every job declares `container:` and the agent runs its steps with `docker exec`, through the
  `docker` shim, on rootless Podman.
- **B, agent in a container** (`pipelines/b-*.yml`): the agent runs inside the toolchain image, one
  job per container (`run.sh --once`). A supervisor keeps N of them registered in the pool.

Both variants run the same template (`pipelines/templates/`), so the steps and jobs are identical;
only the pool, and for A the container, differ.

## Files

### `pipelines/`

| File | What it is |
|---|---|
| `templates/steps.yml` | Benchmark "steps": 4 jobs of 15 small `script:` steps each, on one npm repository. Measures the cost of each step. |
| `a-steps.yml`, `b-steps.yml` | Entry files of "steps" for variant A (container job) and B (agent in a container). |
| `templates/mix.yml` | Benchmark "mix": a spread of jobs typical of an app and a backend repository (npm install, type check, unit tests, build and publish an artifact, cargo fmt, migrations on PostgreSQL, Python lint and tests, a small Rust crate), then a verify stage and a report. |
| `a-mix.yml`, `b-mix.yml` | Entry files of "mix" for A and B. |
| `scripts/start-postgres.sh` | A throwaway PostgreSQL 17 started by the job (initdb + pg_ctl, no root, no container). Sets `DATABASE_URL`. `stop` removes it. |
| `bench/rust-small/` | A small standalone Rust crate (no dependencies beyond serde and anyhow) with unit tests. Built, tested and linted by the mix pipeline. |

### `agent-container/`

| File | What it is |
|---|---|
| `toolchain/Containerfile` | `agent-bench-toolchain:1`: the job image. Node 24, Rust (rustup, clippy, rustfmt), cargo-nextest, PostgreSQL 17 from PGDG (no cluster is created), uv, Python 3, jq, git. The base is a Playwright image; pin it to your app's `@playwright/test` version, or use any glibc base with the same tools. |
| `agent/Containerfile` | `agent-bench-toolchain-agent:1`: the toolchain plus the Azure Pipelines agent, verified by sha256 at build time. It creates `~/.config` for the agent's user (see [guide 01](../docs/01-agent-in-container-overhead.md)). |
| `agent/start.sh` | The entrypoint of that image: reads the PAT from a secret file, registers the agent with `config.sh --replace`, runs one job with `run.sh --once`, deregisters on exit and on SIGTERM. |

### `host/`

| File | What it is |
|---|---|
| `docker` | The `docker` -> `podman` shim. Installed as `/opt/agent-bench/bin/docker`, first on the agent's PATH. Pulls of a local-only image succeed without a registry. |
| `supervisor.sh` | Variant B's warm pool: keeps `N` ephemeral agent containers running, adopts them by label after a restart, and deletes offline registrations older than two minutes. |
| `teardown.sh` | Removes the whole experiment: supervisor and containers, variant A's agent, the REST sweep of the pools, unit files, the secret and images, and `/opt/agent-bench`. `--dry-run` only lists what it would do. |
| `systemd/agent-bench-a-agent.service` | Variant A's agent as a systemd user unit. |
| `systemd/agent-bench-b-supervisor.service` | Variant B's supervisor as a systemd user unit. |

### `measure/`

| File | What it is |
|---|---|
| `run-status.sh` | Status of a run: build status and result, each job's state and result, and the first issue of each failed task. |
| `step-mean.sh` | Count, mean and maximum duration of the steps of a run, from the build timeline. Used for the per-step overhead of the guide. |

## Parameters and names

Names that must match across the files:

| Name | Where it appears |
|---|---|
| `/opt/agent-bench` | the host folder: `bin/docker`, `bin/supervisor.sh`, `agents/a-1` (the agent installed by its `config.sh`), `secrets/azdo_pat`, `diag-b/`, `supervisor.env` |
| `agent-bench-toolchain:1` (`localhost/`) | the job image: `toolchain/Containerfile`, the entry files, `teardown.sh` |
| `agent-bench-toolchain-agent:1` (`localhost/`) | the agent image: `agent/Containerfile`, `supervisor.sh` (default `AGENT_IMAGE`), `teardown.sh` |
| `agent-bench-azp-token` | the podman secret holding the PAT, read by `agent/start.sh` and `supervisor.sh` |
| `agent-bench-a-agent` | the variant A unit (`systemd/`) and `teardown.sh` |
| `agent-bench-b-supervisor` | the variant B unit (`systemd/`) and `teardown.sh` |
| `agent-bench-b-*` / `agent-bench-a-*` | agent names: the supervisor's names, the teardown's sweep prefixes |
| `bench-a-containerjob`, `bench-b-agentincontainer` | the two agent pools (names). Pipelines and `supervisor.sh` use them. |

Values to set (no default in the files, or a placeholder in a pipeline):

| Value | Set in | Example |
|---|---|---|
| Organization URL | `ADO_ORG_URL` (supervisor, teardown); `AZP_URL` set by the supervisor | `https://dev.azure.com/<org>` |
| Pool ids | `ADO_POOL_ID` (supervisor, one per pool); `ADO_POOL_IDS` (teardown, both) | the number in the pool's settings URL |
| Pool names | `ADO_POOL_NAME` (supervisor) and the `pool:` of the entry files | `bench-b-agentincontainer` |
| PAT | `/opt/agent-bench/secrets/azdo_pat` (mode 600); `podman secret create agent-bench-azp-token <file>` | a PAT with agent pool (read & manage) and build (read) scopes |
| GitHub service connection | `endpoint:` in the entry files | `<github-service-connection>` |
| Repositories | `name:` of each `repository` resource | `<owner>/<repo>` |
| Host user | `--tmpfs /home/<host-user>` in `a-*.yml` (the HOME of the user running the host agent) | output of `whoami` |
| Agent version and tarball | `AGENT_VERSION` build arg; the tarball and `SHA256SUMS` in the build context | the release notes of the agent |
| Toolchain versions | `ARG`s in `toolchain/Containerfile` (Node, Rust, uv, each with its sha256) | pin your own |
| Container limits | `containerOptions` (`--cpus`, `--memory`) in the A entry files; `--cpus`, `--memory` in `supervisor.sh` | the same numbers on both variants |
| Warm agents | `N` in `systemd/agent-bench-b-supervisor.service` | 2 |

Set these in `/opt/agent-bench/supervisor.env` (read by the B unit):

```bash
ADO_ORG_URL=https://dev.azure.com/<org>
ADO_POOL_ID=<id-of-pool-b>
ADO_POOL_NAME=bench-b-agentincontainer
```

and in the shell where you run `teardown.sh` or the measure scripts:

```bash
export ADO_ORG_URL=https://dev.azure.com/<org>   # teardown.sh
export ADO_POOL_IDS="<id-of-pool-a> <id-of-pool-b>"  # teardown.sh
export ADO_ORG=<org> ADO_PROJECT=<project>           # measure/*.sh
export AZDO_PAT_FILE=/opt/agent-bench/secrets/azdo_pat  # measure/*.sh
```

## How the pieces fit

Variant A: the host agent (`systemd/agent-bench-a-agent.service`) runs with `PATH` starting at
`/opt/agent-bench/bin`, so every `docker` call of the agent goes to `host/docker`, which runs
`podman`. A job's `container:` image is pulled (locally, by the shim) and started by Podman with the
options in `a-*.yml`.

Variant B: `systemd/agent-bench-b-supervisor.service` runs `supervisor.sh`, which runs
`agent-bench-toolchain-agent:1` containers with `--secret agent-bench-azp-token`. Each container
registers one agent in pool B, runs one job, deregisters and exits; the supervisor starts the next
one. The containers use the host network (see the note in `supervisor.sh`).

Set up, in order:

1. Install Podman (rootless) and create the folders: `sudo install -d -o "$USER" /opt/agent-bench/{bin,secrets,diag-b,agents}`.
2. Build the images: `agent-bench-toolchain:1` from `toolchain/Containerfile`, then `agent-bench-toolchain-agent:1` from `agent/Containerfile` with the agent tarball and `SHA256SUMS` in its context. Use `podman build` (not Docker).
3. Install `host/docker` as `/opt/agent-bench/bin/docker` and `host/supervisor.sh` as `/opt/agent-bench/bin/supervisor.sh`.
4. Create the PAT file and the podman secret.
5. Configure agent A on the host into `/opt/agent-bench/agents/a-1` with `config.sh` (pool A, name `agent-bench-a-1`), then enable its unit.
6. Write `supervisor.env` and enable the supervisor unit.
7. Copy `examples/pipelines` into a repository of yours, or check out this one, and create the two pipelines from `a-*.yml` and `b-*.yml`, with the placeholders filled in.

`teardown.sh --dry-run` lists what the removal would do without changing anything.

## Running a comparison

With a private project, the organization gives one self-hosted parallel job. Run one pipeline at a
time: a second queued run interleaves its jobs with the first, and both timings get worse.

1. Check that nothing else is running on the pools.
2. Queue `a-steps` (or `b-steps`), and wait for it to finish. Note the build id.
3. Read the result: `measure/step-mean.sh <org> <project> <build-id>` prints the mean per step;
   `measure/run-status.sh <org> <project> <build-id>` shows whether every job passed.
4. Repeat for the other variant, then for `a-mix` and `b-mix`. Alternate the variants between
   repetitions to spread out drift.
5. Use the same container limits on both variants, and the same toolchain image.

The variables of the measure scripts can replace the arguments: `ADO_ORG`, `ADO_PROJECT`,
`BUILD_ID`, and `AZDO_PAT_FILE` or `AZDO_PAT`.
