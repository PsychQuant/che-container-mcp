# che-container-mcp

An MCP server that runs Linux container jobs — including ones far longer than a tool call — through Apple's [`container`](https://github.com/apple/container) CLI. No Docker Desktop needed.

- Start a job and get a `job_id` back at once; wait, read the result or cancel later.
- Job state lives on disk, so jobs survive a restart of the server (or of Claude).
- The source directory is mounted read-only by default; the output directory is writable.
- While a job runs, the server keeps the Mac from idle-sleeping and reports whether it slept anyway.
- Docker is used only when one `container_run` call explicitly authorizes it and `container` is unavailable.

Tested with `container` **1.7.1** on macOS 26 (Apple Silicon). The CLI's JSON output is still changing between 1.x releases; unknown fields are ignored and a missing required field returns `cli_output_unexpected` with the CLI version.

## Requirements

- macOS 26 on Apple Silicon, with the `container` CLI installed at `/usr/local/bin/container` (or set `container_path`).
- The service started once (`container system start`, or call `container_status` with `start: true`).
- **Images must contain `/bin/sh`.** Every job runs as `/bin/sh -c <wrapper> che-job <command…>`: the wrapper records the exit code (Apple's `container inspect` does not report one). The image's own `ENTRYPOINT` is replaced, so put the full command in `command`.

## Tools

| Tool | Input | Output |
|---|---|---|
| `container_status` | `start?` (default false) | `cli_path`, `client_version`, `server_version`, `status` (`running`/`stopped`/`unavailable`), `kernel_installed` (`true`/`false`/`"unknown"`), `started_now` |
| `container_image_ensure` | `image`, `platform?` | `image` (normalized, e.g. `docker.io/library/swift:6.0.3-noble`), `state` (`present`/`pulled`/`pulling`), `digest`, `size_bytes` |
| `container_run` | `image`, `command` (array), `source_dir?`, `source_writable?`, `output_dir?`, `cpus?`, `memory?`, `workdir?`, `env?`, `allow_docker?` | `job_id`, `container_name`, `runtime`, `state: "running"`, `started_at`, `mounts` |
| `container_job_status` | `job_id?` (omit for all jobs) | `state`, `runtime`, `image`, `started_at`, `ended_at`, `elapsed_seconds`; running jobs add `tail` (last 20 lines) |
| `container_job_wait` | `job_id`, `timeout_seconds?` (1–600, default 120) | status fields + `timed_out`, `waited_seconds`. A timeout is **not** an error |
| `container_job_result` | `job_id`, `tail_lines?` (1–1000, default 50), `keep_container?` | `exit_code`, `exit_code_source` (`file`/`log_marker`/`none`), `elapsed_seconds`, `tail`, `log_path`, `host_slept_during_job` (`true`/`false`/`"unknown"`), `sleep_events`, `container_deleted` |
| `container_job_cancel` | `job_id`, `grace_seconds?` (0–300, default 10) | `state`, `container_deleted`, `log_path` |

Every result carries `runtime` (`container` or `docker`). Errors come back as `{"error": {"code", "message"}}` with one of: `runtime_unavailable`, `kernel_missing`, `image_not_found`, `invalid_mount`, `invalid_argument`, `config_invalid`, `job_not_found`, `job_not_finished`, `cli_timeout`, `cli_failed`, `cli_output_unexpected`, `docker_unavailable`.

Job states: `running`, `exited`, `exited_unknown` (stopped, exit code not recoverable), `cancelled`, `lost` (container gone, no exit code), `failed_to_start`.

### Typical CI run

```text
container_image_ensure {"image": "swift:6.0.3-noble"}
container_run {"image": "swift:6.0.3-noble", "command": ["sh", "-c", "./ci.sh"],
               "source_dir": "/path/to/repo", "output_dir": "/path/to/ci-out"}
container_job_wait {"job_id": "cj-…", "timeout_seconds": 600}     # repeat until timed_out is false
container_job_result {"job_id": "cj-…", "tail_lines": 100}
```

### What runs before a container starts

`container_run` checks, in order: the config file, the CLI, that the service is running, the kernel, that the image is local (it never pulls), and the mounts. Any failure returns its error and starts nothing.

## Mounts

- `source_dir` → `/src`, read-only unless `source_writable: true`. `output_dir` → `/out`, writable. Working directory defaults to `/src`.
- Paths are resolved with `realpath` first. Rejected with `invalid_mount`: relative paths, missing paths, non-directories, `/`, your home directory itself, source and output nested in either direction (including through a symlink), paths inside the server's state directory, and paths containing a comma.
- `env` takes explicit `{"KEY": "value"}` pairs only. Host variables are never inherited; `--env-file`, `--secret` and `--ssh` are not supported. Job records keep the keys, not the values.

## Config

Optional `~/Library/Application Support/che-container-mcp/config.json` (or `$CHE_CONTAINER_MCP_HOME/config.json`):

```json
{
  "container_path": "/usr/local/bin/container",
  "docker_path": "/usr/local/bin/docker",
  "defaults": {
    "source_dir": "/path/to/repo",
    "output_dir": "/path/to/ci-out",
    "cpus": 8,
    "memory": "16G",
    "source_mount": "/src",
    "output_mount": "/out",
    "workdir": "/src"
  }
}
```

Built-in defaults: 8 CPUs, 16G memory, `/src`, `/out`. A malformed file makes every tool return `config_invalid` — it never silently falls back.

## Job records

Each job has `jobs/<job_id>/` under the state directory: `job.json` (the record, written atomically), `state/` (mounted at `/.che-job` for the exit code) and `output.log` (the full log, copied when the job finishes and before its container is deleted). Records are never removed automatically; delete finished job directories by hand when you no longer need them.

## Sleep

Apple's container VMs pause when the Mac sleeps, so a 40-minute CI run can stretch to hours. While any job runs, the server holds a `PreventUserIdleSystemSleep` assertion (the same kind as `caffeinate -i`) and records sleep/wake events.

- This assertion does **not** prevent closing the lid or Maintenance Sleep. For long jobs, keep the Mac on power with the lid open.
- The assertion lives only while the server process runs. If the server was not running for part of a job, `host_slept_during_job` is `"unknown"`, so you know an elapsed time is not comparable.

## Known issues

- Large downloads inside a container have been seen to stall (DNS and TCP fine, transfer stopped) while the same file downloads quickly on the host. Download large dependencies on the host into the source or output directory and mount them.

## Docker

Pass `allow_docker: true` to one `container_run` call. Docker is used only if `container` is unavailable (CLI missing or service not running); the authorization is not stored and covers only that call. Later status, wait, result and cancel calls for that job use Docker automatically. When `container` is available, `allow_docker` changes nothing.

## Build and test

```bash
make build          # debug build
make test           # unit tests (live tests are skipped)
make test-live      # integration tests against the real container service
DEVELOPER_ID=… NOTARY_PROFILE=… make release-signed   # universal, signed, notarized, packed
DEVELOPER_ID=… make release-signed-local              # same, without notarization
```

CLI mode for scripts: `CheContainerMCP --cli container_status` or `CheContainerMCP --cli container_run '{"image": "…", "command": ["true"]}'`.

## License

MIT
