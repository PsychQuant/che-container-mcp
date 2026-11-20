# Changelog

## [0.1.0] - Unreleased

### Added

- Seven tools wrapping Apple's `container` CLI (tested with 1.7.1): `container_status`, `container_image_ensure`, `container_run`, `container_job_status`, `container_job_wait`, `container_job_result`, `container_job_cancel`.
- Detached jobs with a `/bin/sh` wrapper that records the exit code to a job-owned mount, with a log marker as fallback.
- Job records on disk, reconciled on startup and on every query, so jobs survive a server restart.
- Logs copied to the host before a job's container is deleted.
- Mount validation (read-only source, writable output, `realpath`, no nesting, no `/` or home, no commas).
- Idle-sleep assertion while jobs run, sleep/wake recording and `host_slept_during_job`.
- Docker only with a single-call `allow_docker: true` while `container` is unavailable.
- `--cli` mode, universal Developer ID build script and `.mcpb` manifest.
