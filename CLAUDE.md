# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mORMot2 MCP Server: a high-performance Model Context Protocol (MCP) server implementing the **2025-06-18 specification** (also supports 2025-11-25, 2025-03-26, 2024-11-05), built on the [mORMot2](https://github.com/synopse/mORMot2) framework. Pure Pascal, no external dependencies beyond mORMot2.

**Output**: `MCPServer.exe` in project root (DCU intermediates: `Win64/Debug/` or `Win64/Release/`)

## Building

Use `~BuildDEBUG.cmd` or `~BuildRELEASE.cmd` in the project root. The `delphi_build` tool only runs existing scripts.

```bash
# Manual MSBuild
msbuild MCPServer.dproj /p:Config=Debug /p:Platform=Win64
```

**mORMot2 dependency**: `D:\ECL\mORMot2\src` (set via `mormot2` env var)

## Running

```
MCPServer.exe                          # HTTP on port 3000 (default)
MCPServer.exe --port=8080              # Custom port
MCPServer.exe --no-auth                # Disable authentication
MCPServer.exe --transport=stdio        # For stdio MCP clients
MCPServer.exe --daemon                 # No console menu
```

**Console menu** (when not --daemon): press 1-6 to manage auth token, toggle tools, exit.

### Authentication

By default a random 32-hex token is generated on startup and shown in the console. Clients must pass it as the `token` parameter in every tool call. Disable with `--no-auth` or press [2] in the console menu.

## Architecture

### Request Flow

```
Client (JSON-RPC 2.0)
  → Transport (stdio or HTTP+SSE)
    → TMCPRequestProcessor.HandleRequest()
      → TMCPManagerRegistry.GetManagerForMethod()
        → IMCPCapabilityManager.ExecuteMethod()
          → Response (JSON-RPC 2.0)
```

### Layer Responsibilities

| Layer | Location | Purpose |
|-------|----------|---------|
| **Protocol** | `src/Protocol/MCP.Types.pas` | Core types, settings, JSON-RPC helpers, error codes |
| **Transport** | `src/Transport/` | `TMCPStdioTransport` and `TMCPHttpTransport` (THttpAsyncServer + SSE) |
| **Core** | `src/Core/` | `TMCPManagerRegistry` (dispatch) and `TMCPEventBus` (thread-safe pub/sub) |
| **Managers** | `src/Managers/` | Core, Tools, Resources, Prompts, Logging, Completion |
| **Tools** | `src/Tools/` | Tool implementations |
| **Entry** | `MCPServer.dpr` | Wiring, `TMCPRequestProcessor`, console menu |

### Registered Tools

| Tool | Class | Description |
|------|-------|-------------|
| `echo` | `TMCPToolEcho` | Echo input back |
| `get_time` | `TMCPToolGetTime` | Current date/time |
| `delphi_build` | `TMCPToolDelphiBuild` | Run `~Build*.cmd` scripts, parse errors |
| `delphi_lookup` | `TMCPToolDelphiLookup` | Search symbol databases (.db) |
| `delphi_index` | `TMCPToolDelphiIndexer` | Index Pascal source into .db |
| `windows_exec` | `TMCPToolWindowsExec` | Run Windows commands (sandboxed paths) |
| `windows_dir` | `TMCPToolWindowsDir` | List directory contents |
| `windows_exists` | `TMCPToolWindowsExists` | Check file/directory existence |
| `delphi_hover` | `TMCPToolDelphiHover` | Symbol declaration + docs via LSP |
| `delphi_definition` | `TMCPToolDelphiDefinition` | Go-to-definition via LSP |
| `delphi_references` | `TMCPToolDelphiReferences` | Find all references via LSP |
| `delphi_document_symbols` | `TMCPToolDelphiDocSymbols` | List all symbols in a file via LSP |

**Sandboxed paths** (windows_exec, delphi_build): `D:\My Projects`, `D:\ECL`, `D:\VCL`

### LSP Tools

The four `delphi_*` LSP tools communicate with `delphi-lsp-server.exe` via stdin/stdout pipes.

- **Executable location**: project root (same folder as MCPServer.exe)
- **Database location**: `dbs\<name>.db` in project root (or full path)
- `TMCPLSPClient` keeps the subprocess alive across calls (one per database)
- `TMCPLSPClientStore` is a thread-safe singleton registry
- Path resolution: searches exe dir first, then parent directory

**Important bug fixed (50ebd5d)**: `RespDoc.Value['result']` returns a reference into a stack-allocated TDocVariantData. Must round-trip through JSON (`ToJson` + `InitJson`) to get an independent copy before the stack frame is freed.

### Key Design Patterns

**Manager Registry**: Each manager implements `IMCPCapabilityManager` with `HandlesMethod()` and `ExecuteMethod()`.

**Event Bus**: `TMCPEventBus.GetInstance` singleton. Publish/subscribe for SSE notifications. Thread-safe with critical sections.

**Transport Abstraction**: `IMCPTransport` + `TMCPTransportBase`. Graceful shutdown (5s timeout), pending request tracking, signal handling.

### Extending the Server

**Adding a Tool**: Inherit `TMCPToolBase` (or `TMCPToolBuildServiceBase` for sandboxed tools). Override `Create` (set `fName`, `fDescription`), `BuildInputSchema`, and `Execute`. Register in `MCPServer.dpr` `RegisterTools()`. Add to `.dpr` uses clause and `.dproj` file list.

### JSON Handling Convention

```pascal
TDocVariantData(Result).InitFast;
TDocVariantData(Result).U['field'] := 'value';  // RawUtf8
TDocVariantData(Result).I['count'] := 42;
TDocVariantData(Result).B['flag']  := True;
TDocVariantData(Result).AddValue('obj', SubVariant);
```

Use `RawUtf8` everywhere. Convert at boundaries: `StringToUtf8()` / `Utf8ToString()`.

### HTTP Transport Details

- Endpoints: `GET /mcp` (SSE), `POST /mcp` (JSON-RPC), `DELETE /mcp` (terminate session)
- 128-bit cryptographic session IDs via `TAesPrng`
- SSE keepalive every 30s
- CORS enabled (all origins)
- POST always returns `application/json` (not SSE-wrapped)

### Protocol Version Negotiation

Server echoes client's requested version if it's in the supported list, otherwise falls back to `2025-06-18`. Unknown versions are accepted with a debug log (not rejected).

Supported: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`

### Initialization Order (MCPServer.dpr)

1. Logging (`TSynLog`, 10MB rotation, 5 files, `LOG_VERBOSE`)
2. `InitDefaultSettings`
3. `ParseCommandLine`
4. Registry → CoreManager → LoggingManager → ToolsManager → ResourcesManager → PromptsManager → CompletionManager
5. `RegisterTools(ToolsManager)`
6. `RunWithTransport()` (blocks) + console menu thread
