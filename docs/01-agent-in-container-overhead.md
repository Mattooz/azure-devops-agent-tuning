# Agent in a container: per-step overhead

## Symptom

The same trivial script step (`git log`, `node -e`, `jq` …) took **~3.1 s** per step when
the agent ran inside a container, and **~0.9 s** with container jobs on the same machine. The
command itself took the same time in both: the whole gap was before it, between
`##[section]Starting: <step>` and `[Host] Selected Node version: …` in the step log.

## Cause

Two things add up. Both happen on every step of every Node-based task (`script:` is the
`CmdLine` task, which runs on Node).

### 1. A glibc probe and two telemetry events per step

`NodeHandler.RunAsync`
([`Handlers/NodeHandler.cs` L230-L262](https://github.com/microsoft/azure-pipelines-agent/blob/v5.281.1/src/Agent.Worker/Handlers/NodeHandler.cs#L230-L262))
checks, on a Linux host, whether the agent's own Node 20 and Node 24 run on this system:
it runs `externals/node20_1/bin/node -v` and `externals/node24/bin/node -v`, then emits
one telemetry event per check (`EmitHostNode20FallbackTelemetry`,
`EmitHostNode24FallbackTelemetry`).

- The check depends on the **host OS only**, not on whether the step runs in a container:
  container jobs run it too.
- Its cache (`supportsNode20`, `supportsNode24`) is a field of the handler, and a handler is
  created per step; the "already emitted" flags live in the step's execution context. So
  the probes and the events repeat on **every step**.

### 2. Every telemetry event opens a new connection

`ExecutionContext.PublishTelemetry`
([`ExecutionContext.cs` L1149-L1199](https://github.com/microsoft/azure-pipelines-agent/blob/v5.281.1/src/Agent.Worker/ExecutionContext.cs#L1149-L1199))
creates a `TelemetryCommandExtension`; its `PublishEvent`
([`Telemetry/TelemetryCommandExtension.cs` L95-L119](https://github.com/microsoft/azure-pipelines-agent/blob/v5.281.1/src/Agent.Worker/Telemetry/TelemetryCommandExtension.cs#L95-L119))
calls `WorkerUtilities.GetVssConnection`
([`WorkerUtilties.cs`](https://github.com/microsoft/azure-pipelines-agent/blob/v5.281.1/src/Agent.Worker/WorkerUtilties.cs)),
which builds a **new `VssConnection`** each time, and then `connection.GetClient<…>()`
([`CustomerIntelligenceServer.cs` L29-L33](https://github.com/microsoft/azure-pipelines-agent/blob/v5.281.1/src/Agent.Worker/Telemetry/CustomerIntelligenceServer.cs#L29-L33)).
These two calls run **synchronously** in the step, before its command starts. The HTTP
publish of the event itself is asynchronous, and the step does not wait for it.

A new connection first needs the server's connection data (`Location.GetConnectionData`).
The Azure DevOps client keeps it in a file cache under the user's application-data folder:

```
~/.config/Microsoft\VisualStudio Services/12.0/Cache/LocationServerMap.xml
```

(the backslash is literal: the client joins a Windows-style path on Linux).

- On a host the folder `~/.config` usually exists (systemd user units, other tools), the cache
  is written when the agent is configured, and new connections read it: **8**
  `GetConnectionData` calls in a whole job.
- In a container built from a stock image, the agent's user has **no `~/.config`**. The
  cache is never written (no file and no folder appear, although `$HOME` is writable), so
  **every** new connection asks the server: **78** calls in a job of 15 steps, about 1 s
  each. This matches .NET returning an empty `ApplicationData` path on Unix when the folder
  does not exist.

## Fixes

### Create `~/.config` for the agent's user (the main one)

In the image of the agent container:

```dockerfile
# The Azure DevOps client keeps its location cache under ~/.config; without the folder every
# new connection asks the server for its connection data (~1 s, several times per step).
RUN install -d -o <agent-user> -g <agent-user> /home/<agent-user>/.config
```

Measured: per-step overhead **1.25 s → 0.50 s**, `GetConnectionData` per job **78 → 5**.

The same applies to any agent whose user has no `~/.config`: a service account created
with `--no-create-home`, a fresh user, a hardened image.

### Skip the per-step glibc probe (glibc images only)

```bash
AGENT_USE_NODE20_IN_UNSUPPORTED_SYSTEM=true
AGENT_USE_NODE24_IN_UNSUPPORTED_SYSTEM=true
```

Environment variables of the agent process (the agent's `.env` file, the service unit, or
`-e` on the container). They skip the probe and its telemetry event; the Node version the
agent picks does not change.

Measured: agent in a container **3.13 s → 1.25 s** per step (before the `~/.config` fix);
container jobs **0.92 s → 0.80 s**.

**Risk:** the probe exists to fall back to an older Node when the agent's Node cannot run
(musl images such as Alpine, a very old glibc). With these knobs set such a system fails
instead of falling back. Use them only where the agent runs on a glibc distribution you
control.

## What did not help

| Tried | Result |
|---|---|
| `AGENT_USE_NODE24=true` (force Node 24) | no change: node selection was not the cost |
| `--network host` for the agent container instead of rootless networking | no change: a request to the organization takes ~0.1 s from the container and from the host |
