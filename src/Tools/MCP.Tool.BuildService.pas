/// MCP Build Service Base
// - Shared functionality for build service tools (native Windows execution)
unit MCP.Tool.BuildService;

{$I mormot.defines.inc}

interface

uses
  sysutils, strUtils,
  classes,
  mormot.core.base,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.os,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Tool.Base;

const
  /// Default command timeout (milliseconds)
  CMD_TIMEOUT_MS = 60000;

  /// Default build timeout (milliseconds)
  BUILD_TIMEOUT_MS = 300000;

  /// Allowed working directories (security measure)
  ALLOWED_ROOTS: array[0..2] of RawUtf8 = (
    'D:\My Projects',
    'D:\ECL',
    'D:\VCL'
  );

var
  /// Global authentication token for build service tools
  g_AuthToken: RawUtf8 = '';

/// Set the global authentication token
procedure SetAuthToken(const Token: RawUtf8); forward;

/// Get the global authentication token
function GetAuthToken: RawUtf8; forward;

/// Check if authentication is enabled
function IsAuthEnabled: Boolean; forward;

/// Whether indexer tools are enabled (delphi_index, delphi_lookup)
var
  g_IndexerEnabled: Boolean = True;

/// Whether build/command tools are enabled (delphi_build, windows_exec)
var
  g_BuildToolsEnabled: Boolean = True;

/// Whether LSP tools are enabled (delphi_hover, delphi_definition, delphi_references, delphi_document_symbols)
var
  g_LspEnabled: Boolean = True;

/// Set whether indexer tools are enabled
procedure SetIndexerEnabled(Enabled: Boolean);

/// Set whether build tools are enabled
procedure SetBuildToolsEnabled(Enabled: Boolean);

/// Set whether LSP tools are enabled
procedure SetLspEnabled(Enabled: Boolean);

/// Check if indexer tools are enabled
function IsIndexerEnabled: Boolean;

/// Check if build tools are enabled
function IsBuildToolsEnabled: Boolean;

/// Check if LSP tools are enabled
function IsLspEnabled: Boolean;

type
  /// Callback for streaming output chunks during command execution
  TMCPOutputCallback = procedure(const Chunk: RawUtf8) of object;

  /// Base class for build service tools
  TMCPToolBuildServiceBase = class(TMCPToolBase)
  protected
    /// Optional callback invoked for each output chunk during ExecuteCommand
    fOnOutput: TMCPOutputCallback;
    /// Check if path is under an allowed root
    function IsPathAllowed(const Path: RawUtf8): Boolean;
    /// Execute a command and capture output
    function ExecuteCommand(const Cmd: RawUtf8; const WorkDir: RawUtf8;
      TimeoutMs: Integer; out Output: RawUtf8; out ExitCode: Integer): Boolean;
    /// Check if this tool requires authentication token
    function RequiresToken: Boolean; override;
    /// Validate authentication token
    function ValidateToken(const Token: RawUtf8): Boolean; override;
  public
    constructor Create; override;
  end;

implementation

{$IFDEF OSWINDOWS}
uses
  Windows;
{$ENDIF}

{ TMCPToolBuildServiceBase }

constructor TMCPToolBuildServiceBase.Create;
begin
  inherited Create;
end;

function TMCPToolBuildServiceBase.RequiresToken: Boolean;
begin
  // Build service tools require authentication when enabled
  Result := IsAuthEnabled;
end;

function TMCPToolBuildServiceBase.ValidateToken(const Token: RawUtf8): Boolean;
begin
  // If authentication is disabled, validation passes
  if not IsAuthEnabled then
    Result := True
  else
    // Otherwise check if token matches
    Result := (Token <> '') and (Token = g_AuthToken);
end;

function TMCPToolBuildServiceBase.IsPathAllowed(const Path: RawUtf8): Boolean;
var
  i: Integer;
  NormPath, UpperPath, UpperRoot: RawUtf8;
begin
  Result := False;
  if Path = '' then
    Exit(True); // Empty path is allowed (uses current dir)

  NormPath := StringReplaceAll(Path, '/', '\');
  UpperPath := UpperCaseU(NormPath);
  for i := Low(ALLOWED_ROOTS) to High(ALLOWED_ROOTS) do
  begin
    UpperRoot := UpperCaseU(ALLOWED_ROOTS[i]);
    if IdemPChar(Pointer(UpperPath), Pointer(UpperRoot)) then
      Exit(True);
  end;
end;

function TMCPToolBuildServiceBase.ExecuteCommand(const Cmd: RawUtf8;
  const WorkDir: RawUtf8; TimeoutMs: Integer; out Output: RawUtf8;
  out ExitCode: Integer): Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfoW;
  PI: TProcessInformation;
  hReadPipe, hWritePipe: THandle;
  CmdLine: SynUnicode;
  WorkDirW: SynUnicode;
  WorkDirPtr: PWideChar;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: Cardinal;
  WaitResult: Cardinal;
  OutputBuilder, Chunk: RawUtf8;
begin
  Result := False;
  Output := '';
  ExitCode := -1;

  // Setup security attributes for pipe inheritance
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;

  // Create pipe for stdout/stderr
  if not CreatePipe(hReadPipe, hWritePipe, @SA, 0) then
    Exit;

  try
    // Ensure read handle is not inherited
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    // Setup startup info
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.hStdOutput := hWritePipe;
    SI.hStdError := hWritePipe;
    SI.hStdInput := 0;
    SI.wShowWindow := SW_HIDE;

    // Prepare command line (must be writable for CreateProcessW)
    // Outer quotes required: cmd.exe /c "..." so paths with spaces work
    CmdLine := Utf8ToSynUnicode('cmd.exe /c "' + Cmd + '"');

    // Prepare working directory
    if WorkDir <> '' then
    begin
      WorkDirW := Utf8ToSynUnicode(WorkDir);
      WorkDirPtr := PWideChar(WorkDirW);
    end
    else
      WorkDirPtr := nil;

    // Create process
    FillChar(PI, SizeOf(PI), 0);
    if not CreateProcessW(nil, PWideChar(CmdLine), nil, nil, True,
      CREATE_NO_WINDOW, nil, WorkDirPtr, SI, PI) then
      Exit;

    try
      // Close write end of pipe in parent
      CloseHandle(hWritePipe);
      hWritePipe := 0;

      // Read output, streaming chunks via callback if assigned
      OutputBuilder := '';
      repeat
        BytesRead := 0;
        if ReadFile(hReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and
           (BytesRead > 0) then
        begin
          Buffer[BytesRead] := #0;
          FastSetString(Chunk, @Buffer, BytesRead);
          OutputBuilder := OutputBuilder + Chunk;
          if Assigned(fOnOutput) then
            fOnOutput(Chunk);
        end;
      until BytesRead = 0;

      // Wait for process with timeout
      WaitResult := WaitForSingleObject(PI.hProcess, TimeoutMs);
      if WaitResult = WAIT_OBJECT_0 then
      begin
        GetExitCodeProcess(PI.hProcess, Cardinal(ExitCode));
        Output := OutputBuilder;
        Result := True;
      end
      else if WaitResult = WAIT_TIMEOUT then
      begin
        TerminateProcess(PI.hProcess, 1);
        Output := 'Process timeout';
        ExitCode := -1;
      end;
    finally
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  finally
    if hWritePipe <> 0 then
      CloseHandle(hWritePipe);
    CloseHandle(hReadPipe);
  end;
end;

// Global authentication functions implementation
procedure SetAuthToken(const Token: RawUtf8);
begin
  g_AuthToken := Token;
end;

function GetAuthToken: RawUtf8;
begin
  Result := g_AuthToken;
end;

function IsAuthEnabled: Boolean;
begin
  Result := g_AuthToken <> '';
end;

procedure SetIndexerEnabled(Enabled: Boolean);
begin
  g_IndexerEnabled := Enabled;
  TSynLog.Add.Log(sllInfo, 'Indexer tools %', [ifthen(Enabled, 'enabled', 'disabled')]);
end;

procedure SetBuildToolsEnabled(Enabled: Boolean);
begin
  g_BuildToolsEnabled := Enabled;
  TSynLog.Add.Log(sllInfo, 'Build tools %', [ifthen(Enabled, 'enabled', 'disabled')]);
end;

function IsIndexerEnabled: Boolean;
begin
  Result := g_IndexerEnabled;
end;

function IsBuildToolsEnabled: Boolean;
begin
  Result := g_BuildToolsEnabled;
end;

procedure SetLspEnabled(Enabled: Boolean);
begin
  g_LspEnabled := Enabled;
  TSynLog.Add.Log(sllInfo, 'LSP tools %', [ifthen(Enabled, 'enabled', 'disabled')]);
end;

function IsLspEnabled: Boolean;
begin
  Result := g_LspEnabled;
end;

end.
