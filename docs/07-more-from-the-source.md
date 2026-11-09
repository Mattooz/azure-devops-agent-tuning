# More from the source: other per-job and per-step costs

A static read of the agent at
[`v5.281.1`](https://github.com/microsoft/azure-pipelines-agent/tree/v5.281.1), looking for
fixed costs and the settings that remove them. **Static only:** the costs below are estimates
from counting process spawns, server calls and waits, unless marked as measured. Paths are under
`src/`.

## How settings reach the agent

Knobs are declared in `Agent.Sdk/Knob/AgentKnobs.cs`, each with its sources in order:

- `EnvironmentKnobSource("X")`: an environment variable of the agent process;
- `RuntimeKnobSource("X")`: a pipeline variable (`variables:`);
- `PipelineFeatureSource("X")`: a server-side feature flag, outside your control;
- `BuiltInDefaultKnobSource`: the default.

A knob with only a runtime source **cannot** be set on the agent: it has to be a pipeline
variable.

## Candidates

| # | Setting | Where | Cost it removes | Risk |
|---|---|---|---|---|
| 1 | `AGENT_USE_NODE20_IN_UNSUPPORTED_SYSTEM`, `AGENT_USE_NODE24_IN_UNSUPPORTED_SYSTEM` | env or variable (`AgentKnobs.cs` L210, L225) | 2 `node -v` spawns and 2 telemetry connections per Node-based step on Linux. **Measured**, see [01](01-agent-in-container-overhead.md) | no glibc fallback |
| 2 | `~/.config` for the agent's user | the image or host user | one server round trip per new connection. **Measured**, see [01](01-agent-in-container-overhead.md) | none |
| 3 | `--init` in `container.options` (Podman) | pipeline | ~10 s per container job at teardown ([02](02-container-jobs-rootless-podman.md)) | none known |
| 4 | `localimage: true` on the container resource | pipeline (`Agent.Sdk/ContainerInfo.cs` L52) | the `docker pull` of a job image you build locally | the image must already be on every agent |
| 5 | Checkout: `fetchDepth: 1`, `fetchTags: false`, `lfs: false`; or the variables `agent.source.git.shallowFetchDepth` and `agent.source.git.lfs` | pipeline (`Agent.Plugins/GitSourceProvider.cs` L346-L355) | fetch time and size, which grow with history and tags | tools that need history (versioning from tags, `git describe`, diffs against a base) |
| 6 | `fetchFilter` (partial clone) and sparse checkout | pipeline, **only with** the variables `AGENT_USE_FETCH_FILTER_IN_CHECKOUT_TASK=true` / `AGENT_USE_SPARSE_CHECKOUT_IN_CHECKOUT_TASK=true` (`AgentKnobs.cs` L845, L960; runtime source only) | blob download for large repositories | blobs fetched on demand later |
| 7 | `agent.disablelogplugin: true` | pipeline variable (`Agent.Worker/AgentLogPlugin.cs` L63) | the per-job log plugin host process | turns off plugins that read the log (e.g. test result detection from output) |
| 8 | `task.publishTelemetry: false` | pipeline variable (`Constants.cs`, `TelemetryCommandExtension.cs` L50-L53) | job-level telemetry events and their connections | none, but limited: each task sets its own value in its scope, so per-task events are not affected |
| 9 | Leave `system.debug` and `Agent.Diagnostic` unset in normal runs | pipeline | verbose logging and extra diagnostics per job | none |

Already off by default, nothing to do:

- the vso-task-lib telemetry and copy at the start of each Node step (`IgnoreVSTSTaskLib`
  defaults to `true`, `AgentKnobs.cs` L754-L759);
- the resource-utilization monitors;
- the enhanced node selection and its telemetry;
- docker action retries.

## Fixed costs without a setting

| Cost | Where | Notes |
|---|---|---|
| Job pickup: when a poll for messages comes back empty, the listener sleeps a **random 5–15 s** before polling again | `Agent.Listener/MessageListener.cs` L332-L334 | A job that arrives during that sleep waits up to 15 s to start. Not measured here. |
| Container job setup: about 19 `docker exec` calls to create the user, the group and sudo in the job container | `Agent.Worker/ContainerOperationProvider.cs` (L808-L1090) | Part of the ~9 s "Initialize containers" per job; no setting skips it. |
| Azure VM detection: an instance-metadata request with a 5 s timeout at job start | `Agent.Sdk/Util/PlatformUtil.cs` L424-L440, awaited in `StepsRunner.cs` | It runs in parallel with job initialization. **Checked** on a non-Azure VM: already done when the first step starts, no visible wait. |
| Task re-extraction on every step | `Agent.Worker/TaskManager.cs` | Only when task signature verification or "always extract" is configured on the agent. |
| Per-job connections for telemetry and feature flags (about 5–7) | `JobExtension.cs`, `JobDispatcher.cs`, `FeatureFlagProvider.cs` | Cheap once the location cache works (#2). |

## Suggested order to try

1. The location cache (#2) and the glibc knobs (#1): measured, large on Node-heavy pipelines.
2. `--init` for container jobs on Podman (#3): ~10 s per job.
3. Checkout options (#5, #6) on large repositories.
4. `agent.disablelogplugin` (#7), if no task relies on log parsing.

The rest is small or already the default.
