# che-container-mcp — Plugin Overview

Runs Linux container jobs through Apple's `container` CLI (tested with 1.7.1). The binary is downloaded by the wrapper from the GitHub release on first use.

## Components

- **MCP server** (`.mcp.json`, server id `container`) → `bin/che-container-mcp-wrapper.sh`, which installs `~/bin/CheContainerMCP` at the version `plugin.json` pins and then execs it. The wrapper is the one from che-ical-mcp with the names changed; its tests are `scripts/tests/plugin-wrapper-test.sh` in the source repo.
- **Skill** `container-jobs` — how to run a CI suite, wait on long jobs, and the failure modes.
- **Command** `/container-status` — service status and the job list.
- **Hook** `hooks/check-mcp.sh` (SessionStart) — one status line for the binary and one for the container service. Read-only: it never downloads and never starts the service.

## Versions

`plugin.json` `version`, `.claude-plugin/marketplace.json` (repo root) and `AppVersion.current` move together. A plugin version bump with no matching GitHub release makes the wrapper fall back to the latest release.

## Source

https://github.com/PsychQuant/che-container-mcp
