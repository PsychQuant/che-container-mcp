# Privacy

che-container-mcp runs entirely on your Mac. It sends nothing to its author or to any analytics service.

- **What it runs**: Apple's `container` CLI (and Docker only when you authorize one call). Pulling an image contacts the image's registry, as `container image pull` always does.
- **What it stores**: job records, exit codes and copies of job logs under `~/Library/Application Support/che-container-mcp/` (or `$CHE_CONTAINER_MCP_HOME`). Environment variable *values* passed to jobs are not stored; only their names are. Nothing is deleted automatically.
- **What it reads**: the directories you pass as `source_dir` and `output_dir`, which are mounted into your containers.
- **Power**: it asks macOS to prevent idle sleep while a job runs and listens for sleep and wake notifications. It changes no system setting.
