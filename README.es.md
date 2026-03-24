# Delphi MCP Server

[🇬🇧 Read in English](README.md)

Servidor [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) de alto rendimiento para Delphi, construido sobre el framework [mORMot2](https://github.com/synopse/mORMot2).

**Implementa la especificación MCP 2025-06-18** (también soporta 2025-11-25, 2025-03-26, 2024-11-05) con soporte completo para notificaciones bidireccionales vía SSE.

## Novedades (Fork)

Este fork es exclusivo para **Delphi** (12+ Athens/Florence). Los archivos de Lazarus/FPC han sido eliminados.

### Por qué Lookup y LSP en un Contenedor?

Los tools `delphi_lookup` y LSP (`delphi_hover`, `delphi_definition`, `delphi_references`, `delphi_document_symbols`) proporcionan **acceso de solo lectura a información de símbolos Delphi** que vive fuera del sistema de archivos del contenedor. Dado que los agentes de IA típicamente se ejecutan en contenedores sandboxed sin acceso al host Windows donde Delphi está instalado, estos tools cubren esa brecha — el servidor MCP corre en el host Windows y expone navegación de símbolos a través del protocolo, permitiendo al agente resolver tipos, encontrar declaraciones y rastrear referencias sin necesidad de acceso directo al código fuente RTL/VCL o DCUs compilados.

Esto se complementa bien con [DelphiAST_MCP](https://github.com/fschetterer/DelphiAST_MCP), un servidor MCP complementario que proporciona análisis estructural de código (parsing AST, detalle de tipos, grafos de llamadas, cadenas de herencia) para proyectos Delphi. Juntos dan al agente de IA una visión completa: **DelphiAST_MCP** para entender la estructura del proyecto y el flujo de código, y **este servidor** para resolución profunda de símbolos contra todo el ecosistema Delphi incluyendo librerías de terceros.

### Por qué solo HTTP (sin Stdio)

Este servidor existe para dar a un **Claude Code sandboxed ejecutándose en un contenedor Linux** acceso a herramientas de compilación y búsqueda de símbolos en el host Windows a través de la red. El transporte stdio requiere que el cliente lance el servidor como proceso hijo — un contenedor no puede ejecutar un `.exe` de Windows. HTTP+SSE es el único transporte que funciona a través de esa frontera.

Para uso **local solo en Windows** (Git Bash, Claude Desktop), el repo [delphi-lookup](https://github.com/JavierusTk/delphi-lookup) ya incluye skills de Claude Code que funcionan sin un servidor MCP.

### Autenticación

Se genera un token aleatorio de 32 caracteres hexadecimales al iniciar y se muestra en la consola. Los clientes deben pasar este token como parámetro `token` en cada llamada a tool. Deshabilitar con `--no-auth` o alternar en tiempo de ejecución vía el menú de consola.

### Opciones Adicionales de Línea de Comandos

```bash
MCPServer.exe                          # HTTP en puerto 3000 (por defecto)
MCPServer.exe --port=8080              # Puerto personalizado
MCPServer.exe --no-auth                # Deshabilitar autenticación
MCPServer.exe --daemon                 # Sin menú de consola (headless)
```

### HTTPS / TLS

```bash
MCPServer.exe --transport=http --tls-self-signed
MCPServer.exe --transport=http --tls --cert=server.crt --key=server.key
MCPServer.exe --transport=http --tls --cert=server.crt --key=server.key --key-password=secret
```

TLS usa el soporte nativo de mORMot2: SChannel en Windows (sin DLLs extra), OpenSSL en Linux.

### Scripts de Compilación

```bash
~Build.cmd 23 Debug Win64       # Debug, Delphi 12 Athens
~Build.cmd 23 Release Win64     # Release
~Build.cmd 23 NoCodeSite Win64  # Debug sin CodeSite
```

**Requerido**: variable de entorno `mormot2` apuntando al directorio fuente de mORMot2.

### Flujo de Compilación: MCP Tool + Claude Code Skill

El **tool MCP `delphi_build`** (parte de este servidor) solo **ejecuta** el script `~Build.cmd` existente y retorna la salida estructurada del compilador. **No** crea scripts.

El **skill de Claude Code `delphi-build-cmd`** (plugin separado del lado del cliente) **crea** scripts de compilación cuando no existen. Conoce las convenciones de MSBuild, rutas de rsvars.bat, configuración de logs, y mejores prácticas de clean vs incremental.

**Flujo de trabajo:**
1. Usar `windows_dir` con patrón `~Build.cmd` para buscar el script
2. Si no existe, el skill `delphi-build-cmd` crea uno
3. Usar `delphi_build` para ejecutarlo y obtener errores/warnings/hints estructurados

**Instalar el skill:** Copiar `skills/delphi-build-cmd/` de este repo a `~/.claude/skills/delphi-build-cmd/`. Claude Code lo detecta automáticamente — no requiere reinicio.

### Streaming en Vivo con CodeSite

La salida de compilación y comandos se transmite en tiempo real a [CodeSite](https://docwiki.embarcadero.com/RADStudio/en/CodeSite_Overview) para depuración en el IDE de Delphi. Esto se controla con la directiva de compilador `CODESITE`, que está **activada por defecto** en el `.dproj`.

- **Con CodeSite**: Compilar con configuración `Debug` o `Release` (por defecto)
- **Sin CodeSite**: Compilar con configuración `NoCodeSite` o `Release_NoCodeSite`
- **Archivos afectados**: `MCP.Tool.DelphiBuild.pas`, `MCP.Tool.WindowsExec.pas`

Para desactivar permanentemente, eliminar `CODESITE` de `DCC_Define` en `MCPServer.dproj`.

### Tools de Compilación y Sistema Delphi

Tools nativos de Windows (sandboxed a rutas permitidas):

| Tool | Descripción |
|------|-------------|
| `delphi_build` | Ejecuta `~Build.cmd` con parsing estructurado de errores/warnings/hints |
| `delphi_lookup` | Busca en bases de datos de símbolos Delphi (archivos .db) |
| `delphi_index` | Indexa archivos fuente Pascal en bases de datos de símbolos |
| `windows_exec` | Ejecuta comandos Windows (sandboxed) |
| `windows_dir` | Lista contenido de directorio con filtro de patrón |
| `windows_exists` | Verifica existencia de archivo/directorio |

### Tools LSP Delphi

Navegación de símbolos vía subproceso `delphi-lsp-server.exe`:

| Tool | Descripción |
|------|-------------|
| `delphi_hover` | Declaración y documentación de símbolo en una posición del archivo |
| `delphi_definition` | Ir a definición (ruta de archivo y número de línea) |
| `delphi_references` | Buscar todas las referencias a un símbolo en el código |
| `delphi_document_symbols` | Listar todos los símbolos declarados en un archivo |

### Ejecutables Complementarios

Los siguientes ejecutables deben estar en el mismo directorio que `MCPServer.exe` (raíz del proyecto):

- `delphi-lookup.exe` — búsqueda en base de datos de símbolos
- `delphi-indexer.exe` — indexador de código Pascal
- `delphi-lsp-server.exe` — navegación de símbolos vía LSP

Los tres provienen del proyecto [delphi-lookup](https://github.com/JavierusTk/delphi-lookup). Sigue sus instrucciones de configuración para crear las bases de datos de símbolos en el subdirectorio `dbs/`. Todos los tools usan el parámetro `database` para resolver archivos `.db` desde `dbs/` automáticamente (ej. `"database": "delphi13"` resuelve a `dbs\delphi13.db`). También se aceptan rutas completas de Windows.

### Rutas Sandboxed

Los tools que acceden al sistema de archivos están restringidos a las rutas listadas en `.SandboxedPaths`, ubicado en el mismo directorio que `MCPServer.exe`. El archivo por defecto contiene:
- `D:\My Projects`
- `D:\ECL`
- `D:\VCL`

Para cambiarlas, editar `.SandboxedPaths` — una ruta por línea, `#` para comentarios. Los cambios se detectan automáticamente en la siguiente llamada al tool — no es necesario reiniciar.

### Estructura del Proyecto Actualizada

```
MCP-Server/
├── MCPServer.dpr               # Archivo de proyecto Delphi
├── MCPServer.dproj             # Opciones de proyecto Delphi
├── ~Build.cmd                  # Script de compilación parametrizado (RTL CONFIG PLATFORM)
├── src/
│   ├── Core/
│   │   ├── MCP.Manager.Registry.pas   # Registro y despacho de managers
│   │   └── MCP.Events.pas             # Event bus (pub/sub)
│   ├── Protocol/
│   │   └── MCP.Types.pas              # Tipos, configuración, helpers JSON-RPC
│   ├── Transport/
│   │   ├── MCP.Transport.Base.pas     # Abstracción de transporte
│   │   └── MCP.Transport.Http.pas     # Transporte HTTP + SSE
│   ├── Server/
│   │   └── MCP.Server.pas             # Servidor HTTP legacy
│   ├── Managers/
│   │   ├── MCP.Manager.Core.pas       # initialize, ping
│   │   ├── MCP.Manager.Tools.pas      # tools/list, tools/call
│   │   ├── MCP.Manager.Resources.pas  # resources/*, subscriptions
│   │   ├── MCP.Manager.Prompts.pas    # prompts/list, prompts/get
│   │   ├── MCP.Manager.Logging.pas    # logging/setLevel
│   │   └── MCP.Manager.Completion.pas # completion/complete
│   ├── Tools/
│   │   ├── MCP.Tool.Base.pas          # Clase base de tool
│   │   ├── MCP.Tool.Echo.pas          # Tool Echo
│   │   ├── MCP.Tool.GetTime.pas       # Tool GetTime
│   │   ├── MCP.Tool.BuildService.pas  # Base compartida para tools sandboxed
│   │   ├── MCP.Tool.DelphiBuild.pas   # Compilación Delphi vía MSBuild
│   │   ├── MCP.Tool.DelphiLookup.pas  # Búsqueda en base de símbolos
│   │   ├── MCP.Tool.DelphiIndexer.pas # Indexador de código Pascal
│   │   ├── MCP.Tool.LSPClient.pas     # Gestor de subproceso LSP
│   │   ├── MCP.Tool.DelphiHover.pas   # Hover de símbolos (vía LSP)
│   │   ├── MCP.Tool.DelphiDefinition.pas    # Ir a definición (vía LSP)
│   │   ├── MCP.Tool.DelphiReferences.pas    # Buscar referencias (vía LSP)
│   │   ├── MCP.Tool.DelphiDocSymbols.pas    # Símbolos del documento (vía LSP)
│   │   ├── MCP.Tool.WindowsExec.pas   # Ejecutar comandos (sandboxed)
│   │   ├── MCP.Tool.WindowsDir.pas    # Listar contenido de directorio
│   │   └── MCP.Tool.WindowsExists.pas # Verificar existencia de archivo/dir
│   ├── Resources/
│   │   └── MCP.Resource.Base.pas      # Clase base de resource
│   └── Prompts/
│       └── MCP.Prompt.Base.pas        # Clase base de prompt
├── skills/
│   └── delphi-build-cmd/
│       └── SKILL.md                   # Skill de Claude Code para crear scripts de compilación
```

---

## README Original — mORMot2 MCP Server

> El contenido a continuación es del repositorio upstream original.

## Características

### Core
- **Implementación pura mORMot2** - Sin dependencias externas más allá de mORMot2
- **Transporte HTTP+SSE** - Para acceso contenedor-a-Windows
- **JSON-RPC 2.0** - Soporte completo del protocolo usando `TDocVariant`
- **Arquitectura modular** - Fácil de extender con tools, resources y prompts personalizados

### Capacidades MCP
- **Tools** - Registra tools personalizados con validación JSON Schema y notificaciones `listChanged`
- **Resources** - List, read, templates y subscriptions con acceso basado en URI
- **Prompts** - List y get con múltiples tipos de contenido (text, image, audio, resource)
- **Logging** - Método `setLevel` con niveles de log RFC 5424
- **Completion** - Auto-completado de argumentos para prompts y resources

### Capa de Transporte
- **Transporte HTTP** - API REST con Server-Sent Events (SSE) y soporte CORS
- **Gestión de sesiones** - IDs de sesión criptográficos (128-bit)
- **Notificaciones SSE** - Comunicación bidireccional en tiempo real
- **Keepalive** - SSE keepalive configurable (por defecto 30s)
- **Graceful shutdown** - Manejo de SIGTERM/SIGINT con timeout de 5s
- **Event bus** - Pub/sub thread-safe para enrutamiento interno de notificaciones

### Notificaciones
- `notifications/tools/list_changed` - Cambios en registro de tools
- `notifications/resources/list_changed` - Cambios en resources
- `notifications/resources/updated` - Actualizaciones de resources suscritos
- `notifications/prompts/list_changed` - Cambios en prompts
- `notifications/message` - Mensajes de log
- `notifications/progress` - Actualizaciones de progreso
- `notifications/cancelled` - Cancelación de requests

## Requisitos

- Framework [mORMot2](https://github.com/synopse/mORMot2)
- Delphi 12+ (probado con Athens y Florence)

## Compilación

Abre `MCPServer.dproj` en el IDE de Delphi. Asegúrate de que las rutas de mORMot2 estén configuradas.

```bash
# O desde línea de comandos
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64
```

## Uso

### Transporte HTTP

```bash
# Puerto por defecto 3000
MCPServer.exe --transport=http

# Puerto personalizado
MCPServer.exe --transport=http --port=8080
```

### Conexión SSE

```bash
# Abrir stream SSE para notificaciones
curl -N -H "Accept: text/event-stream" http://localhost:3000/mcp
```

## Ejemplos de API

### Inicializar Sesión

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

### Listar Tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### Llamar Tool

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
      "arguments": {"message": "¡Hola, Mundo!"}
    }
  }'
```

## Añadir Tools Personalizados

```pascal
unit MCP.Tool.MiTool;

{$I mormot.defines.inc}

interface

uses
  mormot.core.base,
  mormot.core.variants,
  MCP.Tool.Base;

type
  TMCPToolMiTool = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

constructor TMCPToolMiTool.Create;
begin
  inherited;
  fName := 'mi_tool';
  fDescription := 'Mi tool personalizado';
end;

function TMCPToolMiTool.BuildInputSchema: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  // Añadir propiedades...
end;

function TMCPToolMiTool.Execute(const Arguments: Variant): Variant;
begin
  // Retornar éxito
  Result := ToolResultText('¡Hecho!');

  // O retornar error
  // Result := ToolResultText('Mensaje de error', True);
end;

end.
```

Registrar en `MCPServer.dpr`:
```pascal
ToolsManager.RegisterTool(TMCPToolMiTool.Create);
```

## Configuración

Configuración en `MCP.Types.pas`:

```pascal
Settings.ServerName := 'mORMot-MCP-Server';
Settings.ServerVersion := '1.0.0';
Settings.Port := 3000;
Settings.Host := '0.0.0.0';
Settings.Endpoint := '/mcp';
Settings.SSEKeepaliveIntervalMs := 30000;  // 30 segundos
```

## Rendimiento

| Aspecto | mORMot2 MCP Server |
|---------|-------------------|
| Servidor HTTP | `THttpAsyncServer` (async I/O) |
| JSON | `TDocVariant` (zero-copy) |
| Memoria | Asignación mínima |
| Threading | Pool de threads |
| SSE | Implementación nativa |

## Licencia

Licencia MIT - Ver archivo [LICENSE](LICENSE).

## Ver También

- [Documentación mORMot2](https://synopse.info/files/doc/mORMot2.html)
- [Especificación MCP](https://spec.modelcontextprotocol.io/)
- [MCP Protocol Version 2025-06-18](https://modelcontextprotocol.io/docs/concepts/transports)
