# How to measure

## Per-step overhead from the timeline

A pipeline of many trivial steps (here 4 jobs × 15 `script:` steps that take well under a
second each) measures what the agent costs per step. The build timeline has a start and finish
time for each task:

```bash
curl -s -u ":$PAT" "https://dev.azure.com/<org>/<project>/_apis/build/builds/<id>/timeline?api-version=7.1" |
  jq -r '[.records[] | select(.type=="Task" and (.name|startswith("step ")))
          | ((.finishTime|sub("\\.[0-9]+Z";"Z")|fromdate) - (.startTime|sub("\\.[0-9]+Z";"Z")|fromdate))]
         | "n=\(length) mean=\(add/length) max=\(max)"'
```

Read the step log next to it. The gap that mattered here was between `##[section]Starting:`
and `[Host] Selected Node version`: everything the agent does before the command starts.

## Worker diagnostic logs

Each job writes `_diag/Worker_<date>.log` in the agent folder. For an agent in a container,
mount the folder from the host (`-v /srv/agent-diag:/azp/agent/_diag:U`) or it disappears
with the container.

Useful lines:

| Line | Means |
|---|---|
| `Processing step: DisplayName='…'` | step boundaries, to cut the log per step |
| `Starting operation Location.GetConnectionData` | a new connection asking the server for its connection data (see [01](01-agent-in-container-overhead.md)) |
| `File name: '…/externals/node24/bin/node'`, `Arguments: '-v'` | the per-step glibc probe |

Timestamps are to the second, so count events per step and compare setups instead of timing
single lines.

## Read the source at your agent's version

The agent is open source:
[microsoft/azure-pipelines-agent](https://github.com/microsoft/azure-pipelines-agent). Check
out the tag of your version and follow the code path of the log lines. Knobs are declared in
`src/Agent.Sdk/Knob/AgentKnobs.cs`, with their environment variable names and sources
(environment, runtime variable, pipeline feature flag).

## Ruled out

| Hypothesis | How it was checked |
|---|---|
| Rootless container networking | `--network host` for the agent container: no change; `curl` timings to the organization equal from host and container (~0.1 s) |
| Node version selection | `AGENT_USE_NODE24=true`: no change |
| CPU limits | equal `--cpus`/`--memory` on both setups before measuring |
