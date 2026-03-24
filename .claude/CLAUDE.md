# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

High-performance Model Context Protocol (MCP) server implementing specification 2025-06-18 (also supports 2025-11-25, 2025-03-26, 2024-11-05), built with mORMot2 framework in Object Pascal.

## Build Commands

```bash
# Using build scripts (recommended)
~Build.cmd 23 Debug Win64
~Build.cmd 23 Release Win64

# Or manual MSBuild
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64
```

**Required environment variable:** `mormot2` pointing to mORMot2 library path.

## Running the Server

**HTTP transport with SSE:**
```bash
MCPServer --transport=http --port=3000
```

> **Why no stdio?** This server exists to give sandboxed Claude Code (running in a Linux container) access to Windows-host build tools over the network. Stdio requires the client to spawn the server as a child process — a container can't launch a Windows .exe. For local Windows-only use, the [delphi-lookup](https://github.com/JavierusTk/delphi-lookup) repo already ships Claude Code skills.

## Architecture

### Core Patterns

1. **Registry Pattern** (`src/Core/MCP.Manager.Registry.pas`): Central router that dispatches JSON-RPC methods to capability managers. Single registry instance routes calls like `tools/call` → `TMCPToolsManager`.

2. **Event Bus** (`src/Core/MCP.Events.pas`): Thread-safe pub/sub singleton for notifications. Queues events for late subscribers. Standard events include `notifications/tools/list_changed`, `notifications/resources/updated`.

3. **Transport Abstraction** (`src/Transport/`): `IMCPTransport` interface with HTTP implementation. Uses `THttpAsyncServer` with SSE streaming and 128-bit crypto session IDs.

4. **Capability Managers** (`src/Managers/`): Each manager handles a method prefix:
   - `TMCPCoreManager` → initialize, ping
   - `TMCPToolsManager` → tools/list, tools/call
   - `TMCPResourcesManager` → resources/*, subscriptions
   - `TMCPPromptsManager` → prompts/list, prompts/get
   - `TMCPLoggingManager` → logging/setLevel
   - `TMCPCompletionManager` → completion/complete

### Extensibility

Custom tools, resources, and prompts extend base classes:
- `TMCPToolBase` in `src/Tools/MCP.Tool.Base.pas`
- `TMCPResourceBase` in `src/Resources/MCP.Resource.Base.pas`
- `TMCPPromptBase` in `src/Prompts/MCP.Prompt.Base.pas`

See `MCP.Tool.Echo.pas` and `MCP.Tool.GetTime.pas` for tool implementation examples.

### Build Service Tools (`src/Tools/MCP.Tool.BuildService.pas`)

Native Windows tools for Delphi compilation and file operations:

| Tool | Description |
|------|-------------|
| `delphi_build` | Run existing build scripts (.cmd) with structured error/warning/hint parsing and CodeSite streaming |
| `windows_exec` | Execute Windows commands (sandboxed). Optional `log_file` parameter redirects output to file; on failure returns last 10 lines in `output_tail` |
| `windows_dir` | List directory contents with pattern filter |
| `windows_exists` | Check file/directory existence |

**Sandboxed paths:** `D:\My Projects`, `D:\ECL`, `D:\VCL` (applies to `cwd` and `log_file`)

**Delphi versions:** athens/d12 (23.0), florence/d13 (37.0)

### Delphi Symbol Tools (`src/Tools/MCP.Tool.DelphiLookup.pas`, `MCP.Tool.DelphiIndexer.pas`)

| Tool | Description |
|------|-------------|
| `delphi_lookup` | Search indexed symbol databases (.db) for types, functions, constants |
| `delphi_index` | Index Pascal source folders into SQLite symbol databases |

### LSP Tools (`src/Tools/MCP.Tool.LSPClient.pas`)

Symbol navigation via `delphi-lsp-server.exe` subprocess (stdin/stdout pipes):

| Tool | Description |
|------|-------------|
| `delphi_hover` | Symbol declaration + XML doc comments at a file position |
| `delphi_definition` | Go-to-definition (file path and line) |
| `delphi_references` | Find all references across the codebase |
| `delphi_document_symbols` | List all symbols in a file with kinds and line numbers |

- `TMCPLSPClient` keeps the subprocess alive across calls (one instance per database)
- `TMCPLSPClientStore` is a thread-safe singleton registry
- Databases in `dbs/` subdirectory or specified by full path

### Key Types

- `TDocVariant`: mORMot2's zero-copy variant for JSON (no external JSON library)
- `TMCPServerSettings`: Server configuration (port, host, SSL, CORS, SSE keepalive)
- `TMCPTransportConfig`: Transport-specific settings

### Entry Points

- `MCPServer.dpr`: Initialize logging → parse CLI → create registry → register managers → run transport

### Protocol Constants (`src/Protocol/MCP.Types.pas`)

```pascal
MCP_PROTOCOL_VERSION = '2025-06-18'
MCP_SUPPORTED_VERSIONS = '2025-11-25,2025-06-18,2025-03-26,2024-11-05'
```

### Build Scripts

Build scripts live in the project directory with `~Build` prefix:
- `~Build.cmd` — Parameterized: `RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS]`

The `delphi_build` MCP tool only **runs** existing scripts — it is part of this server. The `delphi-build-cmd` Claude Code skill **creates** new scripts when none exist — it is a **separate client-side plugin** (`~/.claude/skills/`), not part of this repo. Workflow: (1) `windows_dir` to find `~Build.cmd`, (2) skill creates if missing, (3) `delphi_build` runs it.

## Code Conventions

- Uses `RawUtf8` for strings (mORMot2 convention)
- Do NOT use `Move()` on arrays containing managed types (`RawUtf8`, `string`, etc.) — use element-by-element assignment instead to preserve reference counting
- Thread safety via critical sections in event bus, resource manager, session tracking
- Logging via `TSynLog` with file rotation (10MB, 5 files)
- Build output streamed live to CodeSite via `TMCPOutputCallback` in `ExecuteCommand` — controlled by `{$IFDEF CODESITE}`, on by default. Build with config `NoCodeSite` or `Release_NoCodeSite` to exclude
- Graceful shutdown: SIGTERM/SIGINT with 5s pending request timeout
