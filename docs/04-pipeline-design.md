# Pipeline design notes

## The work folder depends on the repositories a job checks out

A host agent keeps one work folder per pipeline **and set of repositories**: a job that checks
out `self` and `repo_a` gets `_work/2`, while a job of the same run that checks out `repo_a`
and `repo_b` gets `_work/1`.

This breaks anything that carries absolute paths from one job to the next. In our case,
Rust test binaries built in one job (archived with `cargo nextest archive`) and run in
another use `env!("CARGO_MANIFEST_DIR")`, which is fixed at compile time. The test job then
looked for its fixtures in the wrong folder (`No such file or directory`, half the tests
failed).

**Fix:** jobs that share build output check out the **same repositories, in the same order**,
even if one of them does not need all of them. An agent in a container with a fixed work path
does not have the problem, but do it anyway so the pipeline works on both kinds of agent.

## Clean every job's workspace

```yaml
jobs:
  - job: build
    workspace:
      clean: all
```

A host agent keeps the work folder between jobs: `target/`, `node_modules`, a cargo home under
`$(Pipeline.Workspace)` all survive into the next job of the same pipeline. That makes jobs
faster by accident and hides missing cache steps. `clean: all` gives every job an empty
folder, which is what a hosted agent, or a fresh agent container, gives. Use it when comparing
setups, and whenever the pipeline must not depend on leftovers.

## `Cache@2` takes one path

```yaml
- task: Cache@2
  inputs:
    key: 'cargo | "$(Agent.OS)" | Cargo.lock'
    path: $(CARGO_HOME)        # one path; a multi-line list is taken as a single file name
```

A `path: |` block with two lines is read as one path containing a newline:
`tar: …/registry\n…/git: Cannot open: No such file or directory`, and the post-job step fails
the job. Cache a common parent, or use one `Cache@2` per folder.

Other points:
- The cache is scoped per pipeline and branch, so two pipelines do not share it.
- There is no "save only on the main branch" option.
- A multi-GB `target/` costs about 30 s to restore and 30–90 s to save, per job.

## Container job vs. agent in a container: the same steps

To compare the two setups fairly:
- keep one template with all the jobs and steps;
- let two thin entry files choose only `pool` and, for container jobs, `container` and its
  `options`;
- make every job use `pool: ${{ parameters.pool }}` and add the container with
  `${{ if ne(parameters.container, '') }}`.

Give both the same CPU and memory limits ([02](02-container-jobs-rootless-podman.md)).
