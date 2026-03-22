/// MCP LSP Client
// - Manages delphi-lsp-server.exe subprocess for LSP requests
unit MCP.Tool.LSPClient;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti;

const
  LSP_SERVER_EXE = 'delphi-lsp-server.exe';
  LSP_TIMEOUT_MS = 10000;

type
  /// Manages a single delphi-lsp-server.exe subprocess
  // - Keeps the process alive across calls to avoid startup overhead
  // - Thread-safe: serialises send+receive pairs via internal lock
  TMCPLSPClient = class
  private
    fDatabasePath: RawUtf8;
    fProcessHandle: THandle;
    fThreadHandle: THandle;
    fStdinWrite: THandle;
    fStdoutRead: THandle;
    fLock: TRTLCriticalSection;
    fNextId: Integer;
    fInitialized: Boolean;
    function IsAlive: Boolean;
    procedure CloseHandles;
    function LaunchProcess: Boolean;
    function SendInitialize: Boolean;
    function WriteFrame(const Json: RawUtf8): Boolean;
    function ReadFrame(TimeoutMs: Integer; out Json: RawUtf8): Boolean;
  public
    constructor Create(const DatabasePath: RawUtf8);
    destructor Destroy; override;
    /// Send a JSON-RPC request and return the parsed result variant
    // - Transparently restarts the process if it has died
    // - Returns False and sets ErrorMsg on any failure
    function SendRequest(const Method: RawUtf8; const Params: Variant;
      TimeoutMs: Integer; out ResultValue: Variant; out ErrorMsg: RawUtf8): Boolean;
    property DatabasePath: RawUtf8 read fDatabasePath;
  end;

  /// Thread-safe registry of LSP clients keyed by database path
  // - One process per database, reused across tool calls
  TMCPLSPClientStore = class
  private
  class var
    fClients: array of TMCPLSPClient;
    fCount: Integer;
    fLock: TRTLCriticalSection;
    class constructor Create;
    class destructor Destroy;
  public
    /// Get or create LSP client for given database path
    class function GetClient(const DatabasePath: RawUtf8): TMCPLSPClient;
    /// Free all LSP clients (called on server shutdown)
    class procedure Shutdown;
  end;

/// Convert Windows path to LSP file URI
// - D:\Foo\bar.pas -> file:///D:/Foo/bar.pas
function PathToFileUri(const WinPath: RawUtf8): RawUtf8;

/// Convert LSP file URI to Windows path
function FileUriToPath(const Uri: RawUtf8): RawUtf8;

/// Resolve database parameter to full Windows path
// - Full path (contains \ or :) returned as-is
// - Short name resolved to <exe>\dbs\<name>.db
function ResolveDatabasePath(const Database: RawUtf8): RawUtf8;

/// Return LSP symbol kind as a short name
function LspSymbolKindName(Kind: Integer): RawUtf8;

implementation

{$IFDEF OSWINDOWS}
uses
  Windows;
{$ENDIF}

function PathToFileUri(const WinPath: RawUtf8): RawUtf8;
const
  HEX: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  S: RawUtf8;
  i: Integer;
  C: AnsiChar;
begin
  S := StringReplaceAll(WinPath, '\', '/');
  // Uppercase the drive letter so URIs match database-stored Windows paths
  if (Length(S) >= 2) and (S[2] = ':') and (S[1] >= 'a') and (S[1] <= 'z') then
    S[1] := AnsiChar(Ord(S[1]) - 32);
  Result := 'file:///';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    case C of
      'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/', ':', '(', ')':
        Result := Result + C;
    else
      Result := Result + '%' + HEX[Ord(C) shr 4] + HEX[Ord(C) and $F];
    end;
  end;
end;

function FileUriToPath(const Uri: RawUtf8): RawUtf8;
begin
  if IdemPChar(Pointer(Uri), 'FILE:///') then
    Result := StringReplaceAll(Copy(Uri, 9, MaxInt), '/', '\')
  else
    Result := StringReplaceAll(Uri, '/', '\');
end;

function ResolveDatabasePath(const Database: RawUtf8): RawUtf8;
var
  ExeDir, DbPath: RawUtf8;
begin
  if (PosEx('\', Database) > 0) or (PosEx(':', Database) > 0) then
  begin
    Result := Database;
    Exit;
  end;
  // Try <exedir>\dbs\ first, then parent dir\dbs\ (e.g. if exe is in bin\)
  ExeDir := StringToUtf8(Executable.ProgramFilePath);
  DbPath := ExeDir + 'dbs\' + Database;
  if ExtractFileExt(Utf8ToString(Database)) = '' then
    DbPath := DbPath + '.db';
  if FileExists(Utf8ToString(DbPath)) then
  begin
    Result := DbPath;
    Exit;
  end;
  ExeDir := StringToUtf8(ExtractFilePath(
    ExcludeTrailingPathDelimiter(Executable.ProgramFilePath)));
  Result := ExeDir + 'dbs\' + Database;
  if ExtractFileExt(Utf8ToString(Database)) = '' then
    Result := Result + '.db';
end;

function LspSymbolKindName(Kind: Integer): RawUtf8;
const
  NAMES: array[1..26] of RawUtf8 = (
    'File', 'Module', 'Namespace', 'Package', 'Class', 'Method',
    'Property', 'Field', 'Constructor', 'Enum', 'Interface', 'Function',
    'Variable', 'Constant', 'String', 'Number', 'Boolean', 'Array',
    'Object', 'Key', 'Null', 'EnumMember', 'Struct', 'Event',
    'Operator', 'TypeParameter');
begin
  if (Kind >= 1) and (Kind <= 26) then
    Result := NAMES[Kind]
  else
    Result := 'Symbol';
end;

{ TMCPLSPClient }

constructor TMCPLSPClient.Create(const DatabasePath: RawUtf8);
begin
  inherited Create;
  fDatabasePath := DatabasePath;
  fProcessHandle := 0;
  fThreadHandle := 0;
  fStdinWrite := INVALID_HANDLE_VALUE;
  fStdoutRead := INVALID_HANDLE_VALUE;
  InitializeCriticalSection(fLock);
  fNextId := 1;
  fInitialized := False;
end;

destructor TMCPLSPClient.Destroy;
begin
  EnterCriticalSection(fLock);
  try
    CloseHandles;
  finally
    LeaveCriticalSection(fLock);
  end;
  DeleteCriticalSection(fLock);
  inherited;
end;

procedure TMCPLSPClient.CloseHandles;
begin
  if fProcessHandle <> 0 then
  begin
    TerminateProcess(fProcessHandle, 0);
    CloseHandle(fProcessHandle);
    CloseHandle(fThreadHandle);
    fProcessHandle := 0;
    fThreadHandle := 0;
  end;
  if fStdinWrite <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(fStdinWrite);
    fStdinWrite := INVALID_HANDLE_VALUE;
  end;
  if fStdoutRead <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(fStdoutRead);
    fStdoutRead := INVALID_HANDLE_VALUE;
  end;
  fInitialized := False;
end;

function TMCPLSPClient.IsAlive: Boolean;
begin
  Result := (fProcessHandle <> 0) and
            (WaitForSingleObject(fProcessHandle, 0) = WAIT_TIMEOUT);
end;

function TMCPLSPClient.LaunchProcess: Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfoW;
  PI: TProcessInformation;
  hStdinRead, hStdinWrite: THandle;
  hStdoutRead, hStdoutWrite: THandle;
  CmdLine, ExeDirW: SynUnicode;
  ExeDir, ExePath: RawUtf8;
begin
  Result := False;
  // Find delphi-lsp-server.exe: check exe dir, then parent (e.g. bin\ vs project root)
  ExeDir := StringToUtf8(Executable.ProgramFilePath);
  ExePath := ExeDir + LSP_SERVER_EXE;
  if not FileExists(Utf8ToString(ExePath)) then
  begin
    ExeDir := StringToUtf8(ExtractFilePath(
      ExcludeTrailingPathDelimiter(Executable.ProgramFilePath)));
    ExePath := ExeDir + LSP_SERVER_EXE;
  end;
  TSynLog.Add.Log(sllInfo, 'LSP exe path: %', [ExePath]);

  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;

  if not CreatePipe(hStdinRead, hStdinWrite, @SA, 0) then
    Exit;
  SetHandleInformation(hStdinWrite, HANDLE_FLAG_INHERIT, 0);

  if not CreatePipe(hStdoutRead, hStdoutWrite, @SA, 0) then
  begin
    CloseHandle(hStdinRead);
    CloseHandle(hStdinWrite);
    Exit;
  end;
  SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput  := hStdinRead;
  SI.hStdOutput := hStdoutWrite;
  SI.hStdError  := hStdoutWrite;

  CmdLine  := Utf8ToSynUnicode('"' + ExePath + '" --database "' + fDatabasePath + '"');
  ExeDirW  := Utf8ToSynUnicode(ExeDir);

  FillChar(PI, SizeOf(PI), 0);
  if CreateProcessW(nil, PWideChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, PWideChar(ExeDirW), SI, PI) then
  begin
    fProcessHandle := PI.hProcess;
    fThreadHandle  := PI.hThread;
    fStdinWrite    := hStdinWrite;
    fStdoutRead    := hStdoutRead;
    Result := True;
    TSynLog.Add.Log(sllInfo, 'LSP process launched for: %', [fDatabasePath]);
  end
  else
  begin
    CloseHandle(hStdinWrite);
    CloseHandle(hStdoutRead);
  end;

  CloseHandle(hStdinRead);
  CloseHandle(hStdoutWrite);
end;

function TMCPLSPClient.WriteFrame(const Json: RawUtf8): Boolean;
var
  Frame: RawUtf8;
  BytesWritten: DWORD;
begin
  Frame := FormatUtf8('Content-Length: %'#13#10#13#10, [Length(Json)]) + Json;
  Result := WriteFile(fStdinWrite, Pointer(Frame)^, Length(Frame), BytesWritten, nil)
    and (Integer(BytesWritten) = Length(Frame));
end;

function TMCPLSPClient.ReadFrame(TimeoutMs: Integer; out Json: RawUtf8): Boolean;
var
  Deadline: QWord;
  Available, BytesRead, ReadCount: DWORD;
  Buf: array[0..4095] of AnsiChar;
  Acc, Chunk, Header, LenStr: RawUtf8;
  Sep, CL, i: Integer;
begin
  Result := False;
  Json   := '';
  Acc    := '';
  CL     := -1;
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    Available := 0;
    if not PeekNamedPipe(fStdoutRead, nil, 0, nil, @Available, nil) then
      Exit;
    if Available > 0 then
    begin
      ReadCount := Available;
      if ReadCount > SizeOf(Buf) - 1 then
        ReadCount := SizeOf(Buf) - 1;
      BytesRead := 0;
      if ReadFile(fStdoutRead, Buf[0], ReadCount, BytesRead, nil) and (BytesRead > 0) then
      begin
        FastSetString(Chunk, @Buf[0], BytesRead);
        Acc := Acc + Chunk;
        if CL < 0 then
        begin
          Sep := PosEx(#13#10#13#10, Acc);
          if Sep > 0 then
          begin
            Header := Copy(Acc, 1, Sep - 1);
            Acc    := Copy(Acc, Sep + 4, MaxInt);
            i := PosEx('Content-Length:', Header);
            if i > 0 then
            begin
              LenStr := TrimU(Copy(Header, i + 15, 20));
              CL := GetInteger(Pointer(LenStr));
            end;
          end;
        end;
        if (CL > 0) and (Length(Acc) >= CL) then
        begin
          Json := Copy(Acc, 1, CL);
          Result := True;
          Exit;
        end;
      end;
    end
    else
      Sleep(10);
  until GetTickCount64 >= Deadline;
end;

function TMCPLSPClient.SendInitialize: Boolean;
var
  ReqJson, RespJson, DbEscaped: RawUtf8;
  RespDoc: TDocVariantData;
begin
  Result := False;
  DbEscaped := StringReplaceAll(fDatabasePath, '\', '\\');
  ReqJson := FormatUtf8(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"processId":%,' +
    '"clientInfo":{"name":"mcp-server","version":"1.0"},' +
    '"rootUri":null,' +
    '"capabilities":{"textDocument":{"hover":{},"definition":{},' +
    '"references":{},"documentSymbol":{}}},' +
    '"initializationOptions":{"database":"%"}}}',
    [GetCurrentProcessId, DbEscaped]);

  if not WriteFrame(ReqJson) then
    Exit;
  if not ReadFrame(LSP_TIMEOUT_MS, RespJson) then
    Exit;

  RespDoc.InitJson(RespJson, JSON_FAST);
  if not VarIsEmptyOrNull(RespDoc.Value['error']) then
    Exit;

  WriteFrame('{"jsonrpc":"2.0","method":"initialized","params":{}}');

  fInitialized := True;
  TSynLog.Add.Log(sllInfo, 'LSP initialized for: %', [fDatabasePath]);
  Result := True;
end;

function TMCPLSPClient.SendRequest(const Method: RawUtf8; const Params: Variant;
  TimeoutMs: Integer; out ResultValue: Variant; out ErrorMsg: RawUtf8): Boolean;
var
  ReqDoc: TDocVariantData;
  ReqJson, RespJson: RawUtf8;
  RespDoc: TDocVariantData;
  RespId: Variant;
  RequestId: Integer;
  ErrorDoc: PDocVariantData;
begin
  Result := False;
  VarClear(ResultValue);
  ErrorMsg := '';

  EnterCriticalSection(fLock);
  try
    if not IsAlive then
    begin
      CloseHandles;
      if not LaunchProcess then
      begin
        ErrorMsg := 'Failed to launch ' + LSP_SERVER_EXE;
        Exit;
      end;
    end;

    if not fInitialized then
      if not SendInitialize then
      begin
        ErrorMsg := 'LSP initialization failed';
        Exit;
      end;

    Inc(fNextId);
    RequestId := fNextId;

    ReqDoc.InitFast;
    ReqDoc.U['jsonrpc'] := '2.0';
    ReqDoc.I['id'] := RequestId;
    ReqDoc.U['method'] := Method;
    if not VarIsEmptyOrNull(Params) then
      ReqDoc.AddValue('params', Params);
    ReqJson := ReqDoc.ToJson;

    TSynLog.Add.Log(sllDebug, 'LSP >> %', [ReqJson]);

    if not WriteFrame(ReqJson) then
    begin
      ErrorMsg := 'Failed to write to LSP stdin';
      Exit;
    end;

    // Loop to skip any unsolicited notifications
    repeat
      if not ReadFrame(TimeoutMs, RespJson) then
      begin
        fInitialized := False;
        ErrorMsg := 'LSP response timeout';
        Exit;
      end;
      TSynLog.Add.Log(sllDebug, 'LSP << %', [RespJson]);
      RespDoc.InitJson(RespJson, JSON_FAST);
      RespId := RespDoc.Value['id'];
    until (not VarIsEmptyOrNull(RespId)) and (integer(RespId) = RequestId);

    if not VarIsEmptyOrNull(RespDoc.Value['error']) then
    begin
      ErrorDoc := _Safe(RespDoc.Value['error']);
      ErrorMsg := ErrorDoc^.U['message'];
      if ErrorMsg = '' then
        ErrorMsg := 'LSP error';
      Exit;
    end;

    // Re-parse through JSON to get an independent copy, avoiding dangling
    // references into RespDoc's internal buffer (which is freed on return)
    begin
      var ResultJson: RawUtf8;
      ResultJson := _Safe(RespDoc.Value['result'])^.ToJson;
      if ResultJson <> '' then
        TDocVariantData(ResultValue).InitJson(ResultJson, JSON_FAST_FLOAT)
      else
        VarClear(ResultValue);
    end;
    Result := True;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

{ TMCPLSPClientStore }

class constructor TMCPLSPClientStore.Create;
begin
  InitializeCriticalSection(fLock);
  fCount := 0;
end;

class destructor TMCPLSPClientStore.Destroy;
begin
  Shutdown;
  DeleteCriticalSection(fLock);
end;

class function TMCPLSPClientStore.GetClient(const DatabasePath: RawUtf8): TMCPLSPClient;
var
  i: Integer;
  Client: TMCPLSPClient;
begin
  EnterCriticalSection(fLock);
  try
    for i := 0 to fCount - 1 do
      if IdemPropNameU(fClients[i].DatabasePath, DatabasePath) then
        Exit(fClients[i]);
    Client := TMCPLSPClient.Create(DatabasePath);
    if Length(fClients) <= fCount then
      SetLength(fClients, fCount + 4);
    fClients[fCount] := Client;
    Inc(fCount);
    Result := Client;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

class procedure TMCPLSPClientStore.Shutdown;
var
  i: Integer;
begin
  EnterCriticalSection(fLock);
  try
    for i := 0 to fCount - 1 do
      fClients[i].Free;
    fCount := 0;
    SetLength(fClients, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

end.
