# Plan: Wire TLS Support in mORMot-MCP-Server

<!-- PLAN-METADATA
spec: SPEC-tls-support.md
created: 2026-02-20
levels: 3
tasks: 5
dag_validated: false
dag_adjustments: 0
alignment_reviewed: true
alignment_corrections: 0
alignment_improvements_accepted: 0
alignment_improvements_rejected: 0
-->

## Spec

Basado en: SPEC-tls-support.md

## Objetivo

Enable HTTPS for the mORMot-MCP-Server so it can serve MCP over TLS — required for production deployments, Cloudflare tunnels with TLS termination, and secure remote connections from Claude Code.

## NO Hacer

- ❌ Do NOT change the default behavior (no flags = plain HTTP)
- ❌ Do NOT force OpenSSL dependency — keep it optional
- ❌ Do NOT modify `MCP.Transport.Stdio.pas` (TLS is irrelevant for stdio)

## Decisiones de Diseño

| Decisión | Justificación |
|----------|---------------|
| Don't add `mormot.crypt.openssl` to uses | Let the user/deployer decide TLS backend. SChannel works on Windows without OpenSSL DLLs. |
| No mutual TLS (client certs) | Not needed for MCP protocol. |
| `--tls-self-signed` as convenience | Lowers barrier for dev/testing. Production should use real certs. |
| `WaitStarted(30, cert, key, password)` with 30s timeout | Consistent with mORMot2 defaults. |

## Tareas

### Nivel 0

- [x] REQ-002: Add SSLKeyPassword and SSLSelfSigned to config records `MUST`
  - Files: `src/Protocol/MCP.Types.pas`, `src/Transport/MCP.Transport.Base.pas`
  - Add `SSLKeyPassword: RawUtf8` and `SSLSelfSigned: Boolean` to `TMCPServerSettings` record (after `SSLKeyFile`)
  - Add `SSLKeyPassword: RawUtf8` and `SSLSelfSigned: Boolean` to `TMCPTransportConfig` record (after `SSLKeyFile`)
  - Initialize both to `''`/`False` in `InitDefaultSettings` and `InitDefaultTransportConfig`
  - Copy both fields in `TMCPTransportFactory.ConfigFromSettings`
  - Criterios:
    - [ ] `TMCPServerSettings` has `SSLKeyPassword` and `SSLSelfSigned` fields
    - [ ] `TMCPTransportConfig` has `SSLKeyPassword` and `SSLSelfSigned` fields
    - [ ] `InitDefaultSettings` initializes both to empty/false
    - [ ] `InitDefaultTransportConfig` initializes both to empty/false
    - [ ] `ConfigFromSettings` copies both fields

### Nivel 1 [parallel]

- [x] REQ-001: Wire TLS to THttpAsyncServer creation `MUST` (depende de: REQ-002)
  - File: `src/Transport/MCP.Transport.Http.pas`
  - In `TMCPHttpTransport.Start`:
    - Add local var `Options: THttpServerOptions`
    - Build options: `Options := [hsoNoXPoweredHeader]; if fConfig.SSLEnabled then Include(Options, hsoEnableTls);`
    - Pass `Options` to `THttpAsyncServer.Create` instead of hardcoded `[hsoNoXPoweredHeader]`
    - After creating server, branch on TLS mode:
      - If `fConfig.SSLSelfSigned`: call `fHttpServer.WaitStartedHttps`
      - Elif `fConfig.SSLEnabled`: call `fHttpServer.WaitStarted(30, Utf8ToString(fConfig.SSLCertFile), Utf8ToString(fConfig.SSLKeyFile), fConfig.SSLKeyPassword)`
      - Else: call `fHttpServer.WaitStarted` (no change from current)
  - Criterios:
    - [ ] `MCPServer.exe --transport=http --tls --cert=server.crt --key=server.key` starts HTTPS server
    - [ ] `curl -k https://localhost:3000/mcp` returns server info JSON
    - [ ] `MCPServer.exe --transport=http` (no TLS flags) starts plain HTTP as before — no regression

- [x] REQ-003: CLI switches for TLS `MUST` (depende de: REQ-002)
  - File: `MCPServer.dpr`
  - In `ParseCommandLine`, add parsing for:
    - `--tls` → `Settings.SSLEnabled := True`
    - `--cert=path` → `Settings.SSLCertFile := StringToUtf8(val)`
    - `--key=path` → `Settings.SSLKeyFile := StringToUtf8(val)`
    - `--key-password=pass` → `Settings.SSLKeyPassword := StringToUtf8(val)`
    - `--tls-self-signed` → `Settings.SSLSelfSigned := True; Settings.SSLEnabled := True`
  - Use existing `HasSwitch`/`GetSwitchValue` helpers
  - Criterios:
    - [ ] `--tls` sets `SSLEnabled := True`
    - [ ] `--cert=server.crt` sets `SSLCertFile`
    - [ ] `--key=server.key` sets `SSLKeyFile`
    - [ ] `--key-password=pass` sets `SSLKeyPassword`
    - [ ] `--tls-self-signed` sets `SSLSelfSigned := True` (implies `SSLEnabled`)

### Nivel 2 [parallel]

- [x] REQ-004: Self-signed TLS for development `SHOULD` (depende de: REQ-003)
  - Files: `src/Transport/MCP.Transport.Http.pas` (already handled in REQ-001 via `SSLSelfSigned` branch)
  - This is implicitly covered by the `fConfig.SSLSelfSigned` branch in REQ-001's `Start` method
  - Verify end-to-end: `--tls-self-signed` triggers `WaitStartedHttps` correctly
  - Criterios:
    - [ ] `MCPServer.exe --transport=http --tls-self-signed` starts HTTPS with auto-generated cert
    - [ ] No cert/key files needed on disk
    - [ ] Console output shows `https://` URL

- [x] REQ-005: Console output reflects TLS state `SHOULD` (depende de: REQ-001)
  - Files: `MCPServer.dpr`, `src/Transport/MCP.Transport.Http.pas`
  - In `MCPServer.dpr` `RunWithTransport`:
    - Change `WriteLn('Server listening on http://...')` to use `https://` when `Settings.SSLEnabled`
    - Use a local `Protocol` variable: `if Settings.SSLEnabled then Protocol := 'https' else Protocol := 'http'`
  - In `MCP.Transport.Http.pas` `Start`:
    - Update `TSynLog.Add.Log` message to show `https://` when TLS enabled
  - Criterios:
    - [ ] With `--tls`: console shows `Server listening on https://0.0.0.0:3000/mcp`
    - [ ] Without `--tls`: console shows `Server listening on http://0.0.0.0:3000/mcp`
    - [ ] TSynLog entry reflects the protocol used

### Verificación

- [x] Compilar proyecto con `delphi-compiler.exe`
- [x] `MCPServer.exe --transport=http` starts plain HTTP (no regression)
- [x] `MCPServer.exe --transport=http --tls-self-signed` starts HTTPS
- [x] Console output shows correct protocol prefix

## Recursos (para preflight)

**Carpetas:**
- /mnt/w/Public/mORMot-MCP-Server/src/Protocol/ (read/write)
- /mnt/w/Public/mORMot-MCP-Server/src/Transport/ (read/write)
- /mnt/w/Public/mORMot-MCP-Server/ (read/write - MCPServer.dpr)

**Herramientas:**
- delphi-compiler.exe (compilación)
