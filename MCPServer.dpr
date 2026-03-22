/// mORMot2 MCP Server - Console Application
// - High-performance MCP server using mORMot2 framework
// - Supports multiple transports: stdio, http
program MCPServer;

{$I mormot.defines.inc}

{$APPTYPE CONSOLE}

uses
  {$I mormot.uses.inc}
  WinApi.Windows,
  sysutils, strUtils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.log,
  mormot.core.rtti,
  mormot.core.variants,
  mormot.core.json,
  mormot.crypt.core,
  MCP.Types in 'src\Protocol\MCP.Types.pas',
  MCP.Server in 'src\Server\MCP.Server.pas',
  MCP.Manager.Registry in 'src\Core\MCP.Manager.Registry.pas',
  MCP.Events in 'src\Core\MCP.Events.pas',
  MCP.Manager.Core in 'src\Managers\MCP.Manager.Core.pas',
  MCP.Manager.Logging in 'src\Managers\MCP.Manager.Logging.pas',
  MCP.Manager.Tools in 'src\Managers\MCP.Manager.Tools.pas',
  MCP.Tool.Base in 'src\Tools\MCP.Tool.Base.pas',
  MCP.Tool.Echo in 'src\Tools\MCP.Tool.Echo.pas',
  MCP.Tool.GetTime in 'src\Tools\MCP.Tool.GetTime.pas',
  MCP.Tool.BuildService in 'src\Tools\MCP.Tool.BuildService.pas',
  MCP.Tool.DelphiBuild in 'src\Tools\MCP.Tool.DelphiBuild.pas',
  MCP.Tool.DelphiLookup in 'src\Tools\MCP.Tool.DelphiLookup.pas',
  MCP.Tool.DelphiIndexer in 'src\Tools\MCP.Tool.DelphiIndexer.pas',
  MCP.Tool.WindowsExec in 'src\Tools\MCP.Tool.WindowsExec.pas',
  MCP.Tool.WindowsDir in 'src\Tools\MCP.Tool.WindowsDir.pas',
  MCP.Tool.WindowsExists in 'src\Tools\MCP.Tool.WindowsExists.pas',
  MCP.Tool.LSPClient in 'src\Tools\MCP.Tool.LSPClient.pas',
  MCP.Tool.DelphiHover in 'src\Tools\MCP.Tool.DelphiHover.pas',
  MCP.Tool.DelphiDefinition in 'src\Tools\MCP.Tool.DelphiDefinition.pas',
  MCP.Tool.DelphiReferences in 'src\Tools\MCP.Tool.DelphiReferences.pas',
  MCP.Tool.DelphiDocSymbols in 'src\Tools\MCP.Tool.DelphiDocSymbols.pas',
  MCP.Resource.Base in 'src\Resources\MCP.Resource.Base.pas',
  MCP.Manager.Resources in 'src\Managers\MCP.Manager.Resources.pas',
  MCP.Prompt.Base in 'src\Prompts\MCP.Prompt.Base.pas',
  MCP.Manager.Prompts in 'src\Managers\MCP.Manager.Prompts.pas',
  MCP.Manager.Completion in 'src\Managers\MCP.Manager.Completion.pas',
  MCP.Transport.Base in 'src\Transport\MCP.Transport.Base.pas',
  MCP.Transport.Http in 'src\Transport\MCP.Transport.Http.pas',
  MCP.Transport.Stdio in 'src\Transport\MCP.Transport.Stdio.pas';

type
  /// Helper class to provide request handler method
  TMCPRequestProcessor = class
  private
    fRegistry: IMCPManagerRegistry;
  public
    constructor Create(ARegistry: IMCPManagerRegistry);
    function HandleRequest(const RequestJson: RawUtf8;
      const SessionId: RawUtf8): RawUtf8;
    property Registry: IMCPManagerRegistry read fRegistry;
  end;

var
  Settings: TMCPServerSettings;
  Registry: IMCPManagerRegistry;
  CoreManager: TMCPCoreManager;
  LoggingManager: TMCPLoggingManager;
  ToolsManager: TMCPToolsManager;
  ResourcesManager: TMCPResourcesManager;
  PromptsManager: TMCPPromptsManager;
  CompletionManager: TMCPCompletionManager;
  TransportType: TMCPTransportType;
  TransportTypeStr: RawUtf8;
  TransportConfig: TMCPTransportConfig;
  RequestProcessor: TMCPRequestProcessor;
  NoAuth: Boolean = False; // Flag to disable authentication

{ TMCPRequestProcessor }

constructor TMCPRequestProcessor.Create(ARegistry: IMCPManagerRegistry);
begin
  inherited Create;
  fRegistry := ARegistry;
end;

function TMCPRequestProcessor.HandleRequest(const RequestJson: RawUtf8;
  const SessionId: RawUtf8): RawUtf8;
var
  Request, Response: Variant;
  RequestId: Variant;
  Method: RawUtf8;
  Params: Variant;
  Manager: IMCPCapabilityManager;
  MethodResult: Variant;
begin
  Result := '';

  try
    TDocVariantData(Request).InitJson(RequestJson, JSON_FAST_FLOAT);
    RequestId := TDocVariantData(Request).Value['id'];
    Method := TDocVariantData(Request).U['method'];

    // Handle notifications (no response needed)
    if Method = 'notifications/initialized' then
    begin
      TSynLog.Add.Log(sllInfo, 'MCP Initialized notification received');
      Exit;
    end;

    if fRegistry = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        'Manager registry not initialized');
      Exit;
    end;

    Manager := fRegistry.GetManagerForMethod(Method);
    if Manager = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_METHOD_NOT_FOUND,
        FormatUtf8('Method [%] not found', [Method]));
      Exit;
    end;

    Params := TDocVariantData(Request).Value['params'];
    MethodResult := Manager.ExecuteMethod(Method, Params, SessionId);

    Response := CreateJsonRpcResponse(RequestId);
    if not VarIsEmptyOrNull(MethodResult) then
      TDocVariantData(Response).AddValue('result', MethodResult);

    Result := TDocVariantData(Response).ToJson;

  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Error processing request: %', [E.Message]);
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        StringToUtf8(E.Message));
    end;
  end;
end;

procedure InitializeLogging;
begin
  with TSynLog.Family do
  begin
    Level := LOG_VERBOSE;
    DestinationPath := Executable.ProgramFilePath;
    PerThreadLog := ptIdentifiedInOneFile;
    RotateFileCount := 5;
    RotateFileSizeKB := 10240; // 10MB
  end;
end;

procedure RegisterTools(Manager: TMCPToolsManager);
begin
  // Register built-in tools
  Manager.RegisterTool(TMCPToolEcho);
  Manager.RegisterTool(TMCPToolGetTime);

  // Build service tools (Delphi compilation and Windows commands)
  Manager.RegisterTool(TMCPToolDelphiBuild);
  Manager.RegisterTool(TMCPToolDelphiLookup);
  Manager.RegisterTool(TMCPToolDelphiIndexer);
  Manager.RegisterTool(TMCPToolWindowsExec);
  Manager.RegisterTool(TMCPToolWindowsDir);
  Manager.RegisterTool(TMCPToolWindowsExists);

  // LSP tools (delphi-lsp-server.exe subprocess, one process per database)
  Manager.RegisterTool(TMCPToolDelphiHover);
  Manager.RegisterTool(TMCPToolDelphiDefinition);
  Manager.RegisterTool(TMCPToolDelphiReferences);
  Manager.RegisterTool(TMCPToolDelphiDocSymbols);
end;

function HasSwitch(const Name: string): Boolean;
var
  I: Integer;
  S: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '--' + Name) or (S = '-' + Name) or (S = '/' + Name) then
      Exit(True);
  end;
end;

function GetSwitchValue(const Name: string): string;
var
  I: Integer;
  S, Prefix: string;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    // Check for --name=value format
    Prefix := '--' + Name + '=';
    if Copy(S, 1, Length(Prefix)) = Prefix then
    begin
      Result := Copy(S, Length(Prefix) + 1, MaxInt);
      Exit;
    end;
    // Check for --name value format
    if (S = '--' + Name) or (S = '-' + Name) or (S = '/' + Name) then
    begin
      if I < ParamCount then
        Result := ParamStr(I + 1);
      Exit;
    end;
  end;
end;

procedure ParseCommandLine;
var
  I: Integer;
  S: string;
begin
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (S = '--port') or (S = '-p') or (S = '/port') then
    begin
      Inc(I);
      if I <= ParamCount then
        Settings.Port := StrToIntDef(ParamStr(I), Settings.Port);
    end
    else if (S = '--no-auth') or (S = '-no-auth') or (S = '/no-auth') then
    begin
      // Disable authentication
      NoAuth := True;
    end
    else if (Length(S) > 0) and not CharInSet(S[1], ['-', '/']) then
      // Bare number = port
      Settings.Port := StrToIntDef(S, Settings.Port);
    Inc(I);
  end;

  // Parse transport type
  TransportTypeStr := StringToUtf8(GetSwitchValue('transport'));
  if TransportTypeStr = '' then
    TransportTypeStr := 'http';
  TransportType := TMCPTransportFactory.ParseTransportType(TransportTypeStr);

  // Parse TLS settings
  if HasSwitch('tls') then
    Settings.SSLEnabled := True;
  S := GetSwitchValue('cert');
  if S <> '' then
    Settings.SSLCertFile := StringToUtf8(S);
  S := GetSwitchValue('key');
  if S <> '' then
    Settings.SSLKeyFile := StringToUtf8(S);
  S := GetSwitchValue('key-password');
  if S <> '' then
    Settings.SSLKeyPassword := StringToUtf8(S);
  if HasSwitch('tls-self-signed') then
  begin
    Settings.SSLSelfSigned := True;
    Settings.SSLEnabled := True;
  end;
end;

type
  TConsole = record
    private
     class var FLine: integer; FCord: TCoord;
     class var FStdOut: THandle;
     class procedure SetCursorPos(Value: TCoord); static;
     class function GetCursorPos: TCoord; static;
     class procedure ClearArea(ASize: Cardinal; APosition: TCoord); static;
     class function GetInfo: TConsoleScreenBufferInfo; static;
    public
     class procedure Initialize;  static;
     class constructor create;
     class procedure ReSetCursorPos; static;
    class property CursorPos: TCoord read GetCursorPos write SetCursorPos;
  end;

class function TConsole.GetInfo: TConsoleScreenBufferInfo;
begin
  Win32Check(GetConsoleScreenBufferInfo(FStdOut, Result));
end;

class function TConsole.GetCursorPos: TCoord;
begin
  Result := GetInfo.dwCursorPosition;
end;

class procedure TConsole.Initialize;
begin
  if FLine <> -1 then Exit;
  FStdOut := GetStdHandle(STD_OUTPUT_HANDLE);
  FCord   := GetCursorPos;
  FLine   := FCord.Y;
end;

class procedure TConsole.ReSetCursorPos;
var area : TCoord; sz : DWORD;
begin
  area.x := 0;
  area.y := FLine;
  with GetInfo do sz := dwSize.x * (dwSize.y - FLine);
  ClearArea(sz, area);
  SetCursorPos(FCord);
end;

class procedure TConsole.SetCursorPos(Value: TCoord);
begin
  Win32Check(SetConsoleCursorPosition(FStdOut, Value));
end;

class procedure TConsole.ClearArea(ASize: Cardinal; APosition: TCoord);
var NumWritten: DWORD;
const SPACE = ' ';
begin
  Win32Check(FillConsoleOutputCharacter(FStdOut, SPACE, ASize, APosition, NumWritten));
  Win32Check(FillConsoleOutputAttribute(FStdOut, 0, ASize, APosition, NumWritten));
  Win32Check(SetConsoleCursorPosition(FStdOut, APosition));
end;

class constructor TConsole.create;
begin
  FLine := -1;
end;

procedure ShowConsoleMenu;
var
  Key: string;
  AuthToken: RawUtf8;
begin
  TConsole.Initialize;

  // Show menu after server starts
  repeat
    TConsole.ReSetCursorPos;
    WriteLn;
    WriteLn('=== MCP Server Console ===');
    WriteLn('[1] New Auth token    - ', ifthen(IsAuthEnabled, Utf8ToString(GetAuthToken), 'DISABLED'));
    WriteLn('[2] Toggle No Auth    - ', ifthen(NoAuth, 'auth DISABLED', 'auth required'));
    WriteLn('[3] Toggle Indexer    - ', ifthen(IsIndexerEnabled, 'enabled', 'DISABLED'));
    WriteLn('[4] Toggle Build      - ', ifthen(IsBuildToolsEnabled, 'enabled', 'DISABLED'));
    WriteLn('[5] Toggle LSP        - ', ifthen(IsLspEnabled, 'enabled', 'DISABLED'));
    WriteLn('[6] Exit cleanly      - graceful shutdown');
    WriteLn;
    Write('Select option [1-6]: ');

    ReadLn(Key);
    if Key <> '' then
     case Key.Chars[0] of
      '1': if not NoAuth then // New Auth token
            begin
              AuthToken := TAesPrng.Main.FillRandomHex(16);
              SetAuthToken(AuthToken);
              // Overwrite line 1 - cursor positioning
//              Write(#27'[1;1H');  // ANSI: move to line 1, column 1
//              Write('Authentication token: ', Utf8ToString(AuthToken), #27'[K'); // Clear to EOL
              WriteLn;
              WriteLn('Token regenerated. Press Enter to continue...');
              ReadLn;
            end
            else
            begin
              WriteLn('Auth is disabled. Enable auth first with option 2.');
              WriteLn('Press Enter to continue...');
              ReadLn;
            end;
      '2': begin // Toggle auth
            NoAuth := not NoAuth;
            if NoAuth then
            begin
              SetAuthToken('');
              TSynLog.Add.Log(sllInfo, 'Authentication DISABLED via console');
            end
            else
            begin
              AuthToken := TAesPrng.Main.FillRandomHex(16);
              SetAuthToken(AuthToken);
              TSynLog.Add.Log(sllInfo, 'Authentication ENABLED via console');
            end;
           end;
      '3': SetIndexerEnabled(not IsIndexerEnabled);
      '4': SetBuildToolsEnabled(not IsBuildToolsEnabled);
      '5': SetLspEnabled(not IsLspEnabled);
      '6': Break;  // Exit
    else
        WriteLn('Invalid option. Press Enter to continue...');
        ReadLn;
    end;
  until False;
end;


procedure RunWithTransport;
var
  IsDaemon: Boolean;
  HttpTransport: TMCPHttpTransport;
  StdioTransport: TMCPStdioTransport;
  ShutdownSuccess: Boolean;
  Protocol: string;
begin
  IsDaemon := HasSwitch('daemon') or HasSwitch('d');

  // Create transport config from settings
  TransportConfig := TMCPTransportFactory.ConfigFromSettings(TransportType, Settings);

  case TransportType of
    mttStdio:
      begin
        // Stdio mode - minimal output, just JSON
        // Signal handling and graceful shutdown is handled internally by the transport
        TSynLog.Add.Log(sllInfo, 'Starting MCP Server in stdio mode');

        StdioTransport := TMCPStdioTransport.Create(TransportConfig);
        try
          StdioTransport.ManagerRegistry := Registry;
          StdioTransport.SetRequestHandler(RequestProcessor.HandleRequest);
          StdioTransport.Start; // Blocks until EOF or SIGTERM/SIGINT
        finally
          StdioTransport.Free;
        end;
      end;

    mttHttp:
      begin
        WriteLn('mORMot2 MCP Server v1.0.0');
        WriteLn('========================');
        WriteLn('Transport: HTTP');
        WriteLn;

        if Settings.Port <> 3000 then
          WriteLn('Port: ', Settings.Port);
        // Limit to LAN
        Settings.Host := '10.168.1.0';

        if Settings.SSLEnabled then
          Protocol := 'https'
        else
          Protocol := 'http';

        HttpTransport := TMCPHttpTransport.Create(TransportConfig);
        try
          HttpTransport.ManagerRegistry := Registry;
          HttpTransport.SetRequestHandler(RequestProcessor.HandleRequest);
          HttpTransport.Start;

          WriteLn;
          WriteLn('Server listening on ', Protocol, '://', Settings.Host, ':',
            Settings.Port, Settings.Endpoint);

          if IsDaemon then
          begin
            WriteLn('Running in daemon mode. Press Ctrl+C to stop (graceful shutdown).');
            // Use ConsoleWaitForEnterKey which handles SIGTERM/SIGINT properly
            // and also responds to Enter key press
            ConsoleWaitForEnterKey;
            // Graceful shutdown with 5s timeout for pending requests
            WriteLn('Initiating graceful shutdown...');
            ShutdownSuccess := HttpTransport.GracefulShutdown(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
            if not ShutdownSuccess then
              WriteLn('Warning: Some requests may not have completed');
          end
          else
          begin
            // Show interactive console menu for HTTP mode
            ShowConsoleMenu;
            // Graceful shutdown with 5s timeout for pending requests
            WriteLn('Initiating graceful shutdown...');
            ShutdownSuccess := HttpTransport.GracefulShutdown(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
            if not ShutdownSuccess then
              WriteLn('Warning: Some requests may not have completed');
          end;
        finally
          HttpTransport.Free;
        end;

        WriteLn('Server stopped.');
      end;
  end;
end;

procedure ShowDatabases;
var
  SearchRec: TSearchRec;
  FindResult: Integer;
  DbPath: string;
  DbList: TStringList;
  i: Integer;
begin
  DbPath := ExtractFilePath(ParamStr(0)) + 'dbs';
  if not DirectoryExists(DbPath) then
  begin
    WriteLn('Delphi Symbol Databases: (none - dbs\ directory does not exist)');
    Exit;
  end;

  DbList := TStringList.Create;
  try
    FindResult := FindFirst(DbPath + '\*.db', faAnyFile, SearchRec);
    try
      while FindResult = 0 do
      begin
        if (SearchRec.Attr and faDirectory) = 0 then
          DbList.Add(ChangeFileExt(SearchRec.Name, ''));
        FindResult := FindNext(SearchRec);
      end;
    finally
      FindClose(SearchRec);
    end;

    if DbList.Count = 0 then
      WriteLn('Delphi Symbol Databases: (none found in dbs\)')
    else
    begin
      WriteLn('Delphi Symbol Databases:');
      for i := 0 to DbList.Count - 1 do
        WriteLn('  - ', DbList[i]);
    end;
  finally
    DbList.Free;
  end;
end;

procedure Run;
var
  AuthToken: RawUtf8;
begin
  // Initialize logging
  InitializeLogging;
  TSynLog.Add.Log(sllInfo, 'Starting mORMot2 MCP Server');

  // Initialize settings
  InitDefaultSettings(Settings);

  // Parse command line
  ParseCommandLine;

  // Generate authentication token if not disabled
  if not NoAuth then
  begin
    AuthToken := TAesPrng.Main.FillRandomHex(16);
    SetAuthToken(AuthToken);
    TSynLog.Add.Log(sllInfo, 'Authentication token generated: %', [AuthToken]);

    // Also display in console for HTTP mode
    {TODO not reequired with the new menu }
//    if TransportType = mttHttp then
//      WriteLn('Authentication token: ', Utf8ToString(AuthToken));
  end
  else
  begin
    SetAuthToken(''); // Clear any existing token
    TSynLog.Add.Log(sllInfo, 'Authentication DISABLED by --no-auth flag');

    // Also display in console for HTTP mode
    if TransportType = mttHttp then
      WriteLn('Authentication DISABLED by --no-auth flag');
  end;
  Writeln;
  // List available Delphi symbol databases
  ShowDatabases;
  Writeln;

  // Create registry
  Registry := TMCPManagerRegistry.Create;

  // Create and register core manager
  CoreManager := TMCPCoreManager.Create(Settings);
  Registry.RegisterManager(CoreManager);

  // Create and register logging manager
  LoggingManager := TMCPLoggingManager.Create;
  Registry.RegisterManager(LoggingManager);

  // Create and register tools manager
  ToolsManager := TMCPToolsManager.Create;
  RegisterTools(ToolsManager);
  Registry.RegisterManager(ToolsManager);

  // Create and register resources manager
  ResourcesManager := TMCPResourcesManager.Create;
  Registry.RegisterManager(ResourcesManager);

  // Create and register prompts manager
  PromptsManager := TMCPPromptsManager.Create;
  Registry.RegisterManager(PromptsManager);

  // Create and register completion manager
  CompletionManager := TMCPCompletionManager.Create;
  Registry.RegisterManager(CompletionManager);

  // Create request processor
  RequestProcessor := TMCPRequestProcessor.Create(Registry);
  try
    // Run with new transport system (supports both stdio and HTTP with SSE)
    RunWithTransport;
  finally
    RequestProcessor.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      // For stdio mode, output error as JSON-RPC error
      if TransportType = mttStdio then
        WriteLn(CreateJsonRpcError(Null, JSONRPC_INTERNAL_ERROR,
          StringToUtf8('Fatal error: ' + E.Message)))
      else
      begin
        WriteLn('Error: ', E.Message);
        TSynLog.Add.Log(sllError, 'Fatal error: %', [E.Message]);
      end;
      ExitCode := 1;
    end;
  end;
end.
