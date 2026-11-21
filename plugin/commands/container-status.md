---
name: container-status
description: Show the container service status and every che-container-mcp job
allowed-tools:
  - mcp__plugin_che-container-mcp_container__container_status
  - mcp__plugin_che-container-mcp_container__container_job_status
---

# Container status

1. Call `container_status` (without `start`) and report the service status, the CLI and server versions, and whether the kernel is installed.
2. Call `container_job_status` without `job_id` and list the jobs as a table: job id, state, image, started at, elapsed. For running jobs, show the last few log lines.
3. If the service is stopped, say that `container_status` with `start: true` starts it; do not start it unless the user asks.
