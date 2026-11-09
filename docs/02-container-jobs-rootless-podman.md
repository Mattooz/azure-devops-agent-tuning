# Container jobs on rootless Podman

The agent drives container jobs through the `docker` CLI: `docker version`, `docker network
create`, `docker pull`, `docker create`, `docker exec`. Rootless Podman can stand in for it,
with a few adjustments. Tested with Podman 4.9 (netavark), agent 5.281.1, no root on the host.

## A `docker` shim

No `podman-docker` package is needed: a script named `docker` first on the agent's `PATH`
(e.g. `Environment=PATH=/opt/agent-bin:/usr/bin:/bin` in its unit) is enough.

```bash
#!/bin/bash
# docker → podman for the agent. A local-only image (localhost/...) cannot be pulled: when it
# is already present, `docker pull` succeeds without contacting a registry.
if [ "$1" = pull ] && podman image exists "${@: -1}"; then
  exit 0
fi
exec podman "$@"
```

The agent always pulls the job image first; without the pull exception a locally built image
fails the job.

## Container options

```yaml
container:
  image: localhost/toolchain:1
  options: --userns=keep-id --user 0:0 --tmpfs /home/<host-user>:rw,exec,mode=1777 --cpus 6 --memory 14g
```

| Option | Why |
|---|---|
| `--userns=keep-id` | the agent mounts its work folder (owned by the host user) and runs every step as the host user's uid (`docker exec -u <uid>`); keep-id maps that uid to itself, so steps can write the mounts. Without it, the uid is mapped to a sub-uid and every write to the workspace fails. |
| `--user 0:0` | with keep-id the container starts as the host user, but the agent's setup runs `groupadd`/`useradd` in the container with `docker exec` and needs root: `groupadd: Permission denied`, `cannot lock /etc/group`. The steps still run as the host uid. |
| `--tmpfs /home/<host-user>` | the agent runs each step with `-w $HOME` of that user (from the container's `/etc/passwd`, filled by keep-id); the image has no such folder: `crun: chdir to '/home/<user>': No such file or directory`, exit 127. |
| `--cpus`, `--memory` | see below. |

Requirements for the job image: glibc, bash, no `ENTRYPOINT` (the agent starts it with
`--entrypoint tail … -f /dev/null`). Node is mounted from the agent.

## Resource limits do not reach job containers

`CPUQuota=` and `MemoryMax=` on the agent's service unit limit the agent, **not** the job
containers: Podman puts each container in its own cgroup scope (`libpod-<id>.scope`),
outside the unit. A job container then has every core of the machine.

Set the limits in `container.options` (`--cpus`, `--memory`). When comparing setups, this is
the difference that showed up first: the same `cargo clippy` took 4:13 with container jobs
(no limit, 8 cores) and 5:44 in an agent container limited to 6 cores.
