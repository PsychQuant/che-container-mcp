---
name: container-jobs
description: Run Linux commands, test suites and long CI jobs in containers through Apple's `container` CLI with the che-container-mcp tools, instead of `docker run` or `container run` from Bash. Use when asked to run something on Linux, run a project's Linux CI locally, test in an OCI image (swift, ubuntu, python…), or when a container job would outlast Bash's 10-minute limit. Also covers checking a job, waiting on it, reading its result and cancelling it.
allowed-tools:
  - mcp__plugin_che-container-mcp_container__container_status
  - mcp__plugin_che-container-mcp_container__container_image_ensure
  - mcp__plugin_che-container-mcp_container__container_run
  - mcp__plugin_che-container-mcp_container__container_job_status
  - mcp__plugin_che-container-mcp_container__container_job_wait
  - mcp__plugin_che-container-mcp_container__container_job_result
  - mcp__plugin_che-container-mcp_container__container_job_cancel
---

# Container jobs

Prefer these tools over Bash `docker run` / `container run` for anything longer than a quick command: a job returns its id at once, survives a restart of the server, and its exit code, log tail and host-sleep status come back in one result.

## Tools

| Tool | Use |
|---|---|
| `container_status` | Is the service running, which version, is the kernel installed. `start: true` starts a stopped service |
| `container_image_ensure` | Make an image local. Returns `state: "pulling"` (not an error) if the pull outlasts 600 s — call again to keep waiting |
| `container_run` | Start a job: `image`, `command` (argv array), `source_dir` (→ `/src`, read-only), `output_dir` (→ `/out`, writable), `cpus`, `memory`, `env`. Returns `job_id` immediately |
| `container_job_status` | One job or all; running jobs include the last 20 log lines |
| `container_job_wait` | Wait up to `timeout_seconds` (≤ 600). `timed_out: true` is normal for long jobs — call again |
| `container_job_result` | Exit code, elapsed, log tail, full log path, `host_slept_during_job`. Deletes the container after copying its log (`keep_container: true` keeps it) |
| `container_job_cancel` | Stop a job (TERM to its processes, KILL after `grace_seconds`) and delete its container |

## Running a CI suite

Create these tasks with `TaskCreate` before step 1 and mark each completed as it is done. Why: a long job spans many tool calls, and the step most often dropped is the last one — without `container_job_result` the exit code is never read and the container is never removed.

| Task | Kind | Skip when |
|---|---|---|
| `check_service` | mechanical | — |
| `ensure_image` | mechanical | the image was ensured earlier in this session |
| `start_job` | mechanical | — |
| `wait_until_done` | mechanical, repeated | — |
| `read_result` | verification | — |

1. `container_status` — if `stopped`, call it again with `start: true`.
2. `container_image_ensure` with the image (e.g. `swift:6.0.3-noble`).
3. `container_run` with `command: ["bash", "/out/run.sh"]` (or `["sh", "-c", "…"]`), `source_dir` = the repo, `output_dir` = a scratch directory for logs. The source is read-only: a script that builds in place should first `cp -a /src /work && cd /work`.
4. Loop `container_job_wait` with `timeout_seconds: 600` until `timed_out` is false. Report progress to the user between calls; do not poll faster.
5. `container_job_result` with a `tail_lines` large enough for the summary.

## Things that go wrong

- **The image must contain `/bin/sh`.** It wraps the command to record the exit code; the image's ENTRYPOINT is replaced, so put the full command in `command`.
- **`command` is an argv array**, not a shell string. Use `["sh", "-c", "a && b"]` for shell syntax.
- **Mounts are validated before anything starts**: absolute, existing directories; not `/` or the home directory itself; source and output not nested in each other; no commas. A rejected mount returns `invalid_mount` and starts nothing.
- **Sleep**: the server prevents idle sleep while a job runs, but not closing the lid or Maintenance Sleep. If `host_slept_during_job` is `true` or `"unknown"`, the elapsed time is not comparable with other runs.
- **Large downloads inside a container have been seen to stall.** Download big dependencies on the host into `source_dir` or `output_dir` and use them from there.
- **Docker** is used only when a single `container_run` passes `allow_docker: true` and `container` is unavailable. Ask the user before passing it; the authorization covers that one call.
- Errors are `{"error": {"code", "message"}}`; the code says what to do: `image_not_found` → `container_image_ensure`; `runtime_unavailable` → `container_status` with `start: true`; `job_not_finished` → `container_job_wait`.
