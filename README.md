# Delphi MCP Server

[🇪🇸 Leer en español](README.es.md)

High-performance [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server for Delphi, built on the [mORMot2](https://github.com/synopse/mORMot2) framework.

**Implements MCP Specification 2025-06-18** (also supports 2025-11-25, 2025-03-26, 2024-11-05) with full support for bidirectional notifications via SSE.

## What's New (Fork)

This fork targets **Delphi only** (12+ Athens/Florence). Lazarus/FPC files have been removed.

### Why Lookup & LSP in a Container?

The `delphi_lookup` and LSP tools (`delphi_hover`, `delphi_definition`, `delphi_references`, `delphi_document_symbols`) provide **read-only access to Delphi symbol information** that lives outside the container's filesystem. Since AI coding agents typically run in sandboxed containers without access to the Windows host where Delphi is installed, these tools bridge that gap — the MCP server runs on the Windows host and exposes symbol navigation over the protocol, so the agent can resolve types, find declarations, and trace references without needing direct access to the Delphi RTL/VCL source or compiled DCUs.

This pairs well with [DelphiAST_MCP](https://github.com/fschetterer/DelphiAST_MCP), a companion MCP server that provides structural code analysis (AST parsing, type detail, call graphs, inheritance chains) for Delphi projects. Together they give an AI agent a complete picture: **DelphiAST_MCP** for understanding project structure and code flow, and **this server** for deep symbol resolution against the full Delphi ecosystem including third-party libraries.

### Why HTTP Only (No Stdio)

This server exists to give a **sandboxed Claude Code running in a Linux container** access to Windows-host build tools and symbol lookup over the network. Stdio transport requires the client to spawn the server as a child process — a container cannot launch a Windows `.exe`. HTTP+SSE is the only transport that works across that boundary.

For **local Windows-only** use (Git Bash, Claude Desktop), the [delphi-lookup](https://github.com/JavierusTk/delphi-lookup) repo already ships Claude Code skills that work without an MCP server.

### Authentication

A random 32-hex token is generated on startup and displayed in the console. Clients must pass this token as the `token` parameter in every tool call. Disable with `--no-auth` or toggle at runtime via the console menu.

### Additional Command Line Options

```bash
MCPServer.exe                          # HTTP on port 3000 (default)
MCPServer.exe --port=8080              # Custom port
MCPServer.exe --no-auth                # Disable authentication
MCPServer.exe --daemon                 # No console menu (headless)
```

### HTTPS / TLS

```bash
MCPServer.exe --transport=http --tls-self-signed
MCPServer.exe --transport=http --tls --cert=server.crt --key=server.key
MCPServer.exe --transport=http --tls --cert=server.crt --key=server.key --key-password=secret
```

TLS uses mORMot2's native support: SChannel on Windows (no extra DLLs), OpenSSL on Linux.

### Build Scripts

```bash
.Build.cmd 23 Debug Win64       # Debug, Delphi 12 Athens
.Build.cmd 23 Release Win64     # Release
.Build.cmd 23 NoCodeSite Win64  # Debug without CodeSite
```

**Required**: `mormot2` environment variable pointing to the mORMot2 source directory.

### Build Workflow: MCP Tool + Claude Code Skill

The **`delphi_build` MCP tool** (part of this server) only **runs** the existing `.Build.cmd` script and returns structured compiler output. It does **not** create scripts.

The **`delphi-build-cmd` Claude Code skill** (separate client-side plugin) **creates** build scripts when none exist. It knows the MSBuild conventions, rsvars.bat paths, logging setup, and clean-vs-incremental best practices.

**Workflow:**
1. Use `windows_dir` with pattern `.Build.cmd` to check for the script
2. If no script exists, the `delphi-build-cmd` skill creates one
3. Use `delphi_build` to run it and get structured errors/warnings/hints

**Installing the skill:** Copy `skills/delphi-build-cmd/` from this repo to `~/.claude/skills/delphi-build-cmd/`. Claude Code picks it up automatically — no restart needed.

### CodeSite Live Streaming

Build and command output is streamed in real-time to [CodeSite](https://docwiki.embarcadero.com/RADStudio/en/CodeSite_Overview) for debugging in the Delphi IDE. This is controlled by the `CODESITE` compiler directive, which is **on by default** in the `.dproj`.

- **With CodeSite**: Build with `Debug` or `Release` config (default)
- **Without CodeSite**: Build with `NoCodeSite` or `Release_NoCodeSite` config
- **Files affected**: `MCP.Tool.DelphiBuild.pas`, `MCP.Tool.WindowsExec.pas`

To disable permanently, remove `CODESITE` from `DCC_Define` in `MCPServer.dproj`.

### Delphi Build & System Tools

Native Windows tools (sandboxed to allowed paths):

| Tool | Description |
|------|-------------|
| `delphi_build` | Run `.Build.cmd` script with structured error/warning/hint parsing |
| `delphi_lookup` | Search Delphi symbol databases (.db files) |
| `delphi_index` | Index Pascal source files into symbol databases |
| `windows_exec` | Execute Windows commands (sandboxed) |
| `windows_dir` | List directory contents with pattern filter |
| `windows_exists` | Check file/directory existence |

### Delphi LSP Tools

Symbol navigation via `delphi-lsp-server.exe` subprocess:

| Tool | Description |
|------|-------------|
| `delphi_hover` | Symbol declaration and documentation at a file position |
| `delphi_definition` | Go-to-definition (file path and line number) |
| `delphi_references` | Find all references to a symbol across the codebase |
| `delphi_document_symbols` | List all symbols declared in a file |

### Companion Executables

The following executables must be in the same directory as `MCPServer.exe` (project root):

- `delphi-lookup.exe` — symbol database search
- `delphi-indexer.exe` — Pascal source indexer
- `delphi-lsp-server.exe` — LSP symbol navigation

All three are from the [delphi-lookup](https://github.com/JavierusTk/delphi-lookup) project. Follow its setup instructions to create the symbol databases in the `dbs/` subdirectory. All tools use the `database` parameter to resolve `.db` files from `dbs/` automatically (e.g. `"database": "delphi13"` resolves to `dbs\delphi13.db`). Full Windows paths are also accepted.

### Sandboxed Paths

Tools that access the filesystem are restricted to the paths listed in `.SandboxedPaths` in the same directory as `MCPServer.exe`. The default file contains:
- `D:\My Projects`
- `D:\ECL`
- `D:\VCL`

To change these, edit `.SandboxedPaths` — one path per line, `#` for comments. Changes are picked up automatically on the next tool call — no restart required.

### Updated Project Structure

```
MCP-Server/
├── MCPServer.dpr               # Delphi project file
├── MCPServer.dproj             # Delphi project options
├── .Build.cmd                  # Parameterized build script (RTL CONFIG PLATFORM)
├── src/
│   ├── Core/
│   │   ├── MCP.Manager.Registry.pas   # Manager registration & dispatch
│   │   └── MCP.Events.pas             # Event bus (pub/sub)
│   ├── Protocol/
│   │   └── MCP.Types.pas              # Core types, settings, JSON-RPC helpers
│   ├── Transport/
│   │   ├── MCP.Transport.Base.pas     # Transport abstraction
│   │   └── MCP.Transport.Http.pas     # HTTP + SSE transport
│   ├── Server/
│   │   └── MCP.Server.pas             # Legacy HTTP server
│   ├── Managers/
│   │   ├── MCP.Manager.Core.pas       # initialize, ping
│   │   ├── MCP.Manager.Tools.pas      # tools/list, tools/call
│   │   ├── MCP.Manager.Resources.pas  # resources/*, subscriptions
│   │   ├── MCP.Manager.Prompts.pas    # prompts/list, prompts/get
│   │   ├── MCP.Manager.Logging.pas    # logging/setLevel
│   │   └── MCP.Manager.Completion.pas # completion/complete
│   ├── Tools/
│   │   ├── MCP.Tool.Base.pas          # Base tool class
│   │   ├── MCP.Tool.Echo.pas          # Echo tool
│   │   ├── MCP.Tool.GetTime.pas       # Get time tool
│   │   ├── MCP.Tool.BuildService.pas  # Shared base for sandboxed tools
│   │   ├── MCP.Tool.DelphiBuild.pas   # Delphi build via MSBuild
│   │   ├── MCP.Tool.DelphiLookup.pas  # Symbol database search
│   │   ├── MCP.Tool.DelphiIndexer.pas # Pascal source indexer
│   │   ├── MCP.Tool.LSPClient.pas     # LSP subprocess manager
│   │   ├── MCP.Tool.DelphiHover.pas   # Symbol hover (via LSP)
│   │   ├── MCP.Tool.DelphiDefinition.pas    # Go-to-definition (via LSP)
│   │   ├── MCP.Tool.DelphiReferences.pas    # Find references (via LSP)
│   │   ├── MCP.Tool.DelphiDocSymbols.pas    # Document symbols (via LSP)
│   │   ├── MCP.Tool.WindowsExec.pas   # Execute commands (sandboxed)
│   │   ├── MCP.Tool.WindowsDir.pas    # List directory contents
│   │   └── MCP.Tool.WindowsExists.pas # Check file/dir existence
│   ├── Resources/
│   │   └── MCP.Resource.Base.pas      # Base resource class
│   └── Prompts/
│       └── MCP.Prompt.Base.pas        # Base prompt class
├── skills/
│   └── delphi-build-cmd/
│       └── SKILL.md                   # Claude Code skill for creating build scripts
```

---

## Original README — mORMot2 MCP Server

> The content below is from the original upstream repository.

## Features

### Core
- **Pure mORMot2 implementation** - No external dependencies beyond mORMot2
- **HTTP+SSE transport** - For container-to-Windows access
- **JSON-RPC 2.0** - Full protocol support using `TDocVariant`
- **Modular architecture** - Easy to extend with custom tools, resources, and prompts

### MCP Capabilities
- **Tools** - Register custom tools with JSON Schema validation and `listChanged` notifications
- **Resources** - List, read, templates, and subscriptions with URI-based access
- **Prompts** - List and get with multiple content types (text, image, audio, resource)
- **Logging** - `setLevel` method with RFC 5424 log levels
- **Completion** - Argument auto-completion for prompts and resources

### Transport Layer
- **HTTP transport** - REST API with Server-Sent Events (SSE) and CORS support
- **Session management** - Cryptographic session IDs (128-bit)
- **SSE notifications** - Real-time bidirectional communication
- **Keepalive** - Configurable SSE keepalive (default 30s)
- **Graceful shutdown** - SIGTERM/SIGINT handling with 5s timeout
- **Event bus** - Thread-safe pub/sub for internal notification routing

### Notifications
- `notifications/tools/list_changed` - Tool registration changes
- `notifications/resources/list_changed` - Resource changes
- `notifications/resources/updated` - Subscribed resource updates
- `notifications/prompts/list_changed` - Prompt changes
- `notifications/message` - Log messages
- `notifications/progress` - Progress updates
- `notifications/cancelled` - Request cancellation

## Requirements

- [mORMot2](https://github.com/synopse/mORMot2) framework
- Delphi 12+ (tested with Athens and Florence)

## Building

Open `MCPServer.dproj` in Delphi IDE. Ensure mORMot2 source paths are configured.

```bash
# Or from command line
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64
```

## Usage

### HTTP Transport

```bash
# Default port 3000
MCPServer.exe --transport=http

# Custom port
MCPServer.exe --transport=http --port=8080
```

### SSE Connection

```bash
# Open SSE stream for notifications
curl -N -H "Accept: text/event-stream" http://localhost:3000/mcp
```

## API Examples

### Initialize Session

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Protocol-Version: 2025-06-18" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {"name": "test", "version": "1.0"}
    }
  }'
```

### List Tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### Call Tool

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {"message": "Hello, World!"}
    }
  }'
```

## Adding Custom Tools

```pascal
unit MCP.Tool.MyTool;

{$I mormot.defines.inc}

interface

uses
  mormot.core.base,
  mormot.core.variants,
  MCP.Tool.Base;

type
  TMCPToolMyTool = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

constructor TMCPToolMyTool.Create;
begin
  inherited;
  fName := 'my_tool';
  fDescription := 'My custom tool';
end;

function TMCPToolMyTool.BuildInputSchema: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  // Add properties...
end;

function TMCPToolMyTool.Execute(const Arguments: Variant): Variant;
begin
  // Return success
  Result := ToolResultText('Done!');

  // Or return error
  // Result := ToolResultText('Error message', True);
end;

end.
```

Register in `MCPServer.dpr`:
```pascal
ToolsManager.RegisterTool(TMCPToolMyTool.Create);
```

## Configuration

Settings in `MCP.Types.pas`:

```pascal
Settings.ServerName := 'mORMot-MCP-Server';
Settings.ServerVersion := '1.0.0';
Settings.Port := 3000;
Settings.Host := '0.0.0.0';
Settings.Endpoint := '/mcp';
Settings.SSEKeepaliveIntervalMs := 30000;  // 30 seconds
```

## Performance

| Aspect | mORMot2 MCP Server |
|--------|-------------------|
| HTTP Server | `THttpAsyncServer` (async I/O) |
| JSON | `TDocVariant` (zero-copy) |
| Memory | Minimal allocation |
| Threading | Thread pool |
| SSE | Native implementation |

## License

MIT License - See [LICENSE](LICENSE) file.

## See Also

- [mORMot2 Documentation](https://synopse.info/files/doc/mORMot2.html)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP Protocol Version 2025-06-18](https://modelcontextprotocol.io/docs/concepts/transports)
