# Claude Code Setup for MCP Server

This guide configures Claude Code skills shipped with this repo.

## Prerequisites

1. **MCP Server running** on the Windows host (HTTP+SSE transport)
2. **Claude Code** configured to use the MCP server (see main README)

---

## Install the delphi-build-cmd Skill

The skill teaches Claude Code how to create and maintain Delphi MSBuild scripts (`.Build.cmd`).

**WSL / Linux:**
```bash
mkdir -p ~/.claude/skills/delphi-build-cmd
cp claude-code/delphi-build-cmd/SKILL.md ~/.claude/skills/delphi-build-cmd/SKILL.md
```

**Windows (cmd):**
```cmd
mkdir "%USERPROFILE%\.claude\skills\delphi-build-cmd"
copy claude-code\delphi-build-cmd\SKILL.md "%USERPROFILE%\.claude\skills\delphi-build-cmd\SKILL.md"
```

Claude Code picks up the skill automatically — no restart needed.

---

## Verification

After installation, test:

```
# Ask Claude Code to create a build script for a Delphi project
# It should use the delphi-build-cmd skill template with required parameters:
# .Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS]
```
