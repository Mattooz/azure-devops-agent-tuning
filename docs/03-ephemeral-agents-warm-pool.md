# Ephemeral agents and a warm pool

An agent in a container that runs one job and exits (`run.sh --once`) gives every job a clean
machine. A small supervisor (one shell script and a systemd unit, no orchestrator) keeps N
agents registered and listening.

## The agent container

- **Image:** the toolchain image plus the agent, extracted at build time from a tarball whose
  SHA-256 is checked during the build. Nothing is downloaded at run time.
- **Start script:**
  1. read the PAT from a mounted secret file (e.g. a Podman secret), never from an
     environment variable visible in `inspect`;
  2. run `config.sh --unattended --replace` with `VSTS_AGENT_INPUT_TOKEN` exported for that
     command only;
  3. unset the token and run `run.sh --once`;
  4. on exit, and on `SIGTERM`, run `config.sh remove` with the token read again.
- **Work folder:** use a fixed path (e.g. `/azp/_work`). Jobs of the same run then see the same
  paths, which matters when a later job uses files that hold absolute paths from an earlier
  one (compiled test binaries, archives).
- **User:** run the agent as a non-root user, and **create its `~/.config`** (see
  [01](01-agent-in-container-overhead.md)).
- **Self-update:** `config.sh` has no flag to turn updates off. An ephemeral agent that
  receives an update request exits; the supervisor starts a fresh one from the image. To move
  to a newer agent, rebuild the image.

## The supervisor

Every few seconds it does two things:

1. **Keep N containers running.** It labels them (e.g. `--label pool=b`), starts one when
   fewer than N are running, and adopts containers that already exist by label after its own
   restart.
2. **Sweep the pool** through the REST API. It lists the pool's agents
   (`GET _apis/distributedtask/pools/{id}/agents`) and deletes those that match all of these:
   - named with its prefix;
   - **offline**;
   - **not a live container**;
   - **registered more than ~2 minutes ago**, so an agent that is still registering is left
     alone.

### Race conditions worth handling

| Case | Handling |
|---|---|
| A container exits between the list and the delete | it deregisters itself; a 404 on delete is harmless |
| An agent is registered but its container is not listed yet | the age check protects it |
| A container is killed (no graceful stop, no deregistration) | the sweep removes it once the server marks it offline. This is not immediate: a killed agent stayed **online** for 1–3 minutes |
| The supervisor is stopped | trap the signal, `podman stop -t 90` the containers (they deregister), then sweep with age 0 |

Run curl with the PAT from the file on stdin (`curl -K -` with `user = ":<pat>"`), so it never
appears in a process's arguments.

## Parallel jobs

A warm pool helps only up to the organization's parallel jobs. For a **private** project the
free tier gives **one self-hosted parallel job** (`FreeCount: 1` under `Private`/self-hosted in
`_apis/distributedtask/resourceusage`). Public projects are effectively unlimited. With one
parallel job, a second warm agent mostly waits. Each extra self-hosted parallel job is paid,
and a Visual Studio Enterprise subscriber adds one.

With a single parallel job, queue **one pipeline at a time** when measuring: two queued
runs interleave their jobs and both look slow.
