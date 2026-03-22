/// MCP Windows Exec Tool
// - Execute Windows commands natively
unit MCP.Tool.WindowsExec;

{$I mormot.defines.inc}

interface

uses
  sysutils, strutils, IOUtils, classes,
  mormot.core.base,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.os,
  MCP.Tool.Base,
  MCP.Tool.BuildService,
  CodeSiteLogging;

type
  /// Windows exec tool - executes commands in sandboxed paths
  TMCPToolWindowsExec = class(TMCPToolBuildServiceBase)
  private
    procedure OnCommandOutput(const Chunk: RawUtf8);
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolWindowsExec }

procedure TMCPToolWindowsExec.OnCommandOutput(const Chunk: RawUtf8);
begin
  CodeSite.Send(Utf8ToString(Chunk));
end;

constructor TMCPToolWindowsExec.Create;
begin
  inherited Create;
  fName := 'windows_exec';
  fDescription := 'Execute a Windows command. Working directory and log_file must be under allowed paths: ' +
    'D:\My Projects, D:\ECL, D:\VCL. ' +
    'Optional log_file parameter redirects output to file. ' +
    'On success with log_file: returns success/exit_code/log_file only. ' +
    'On failure with log_file: also returns last 10 lines in output_tail. ' +
    'Use for git operations, file manipulation, running scripts, and general command-line tasks on Windows';
end;

function TMCPToolWindowsExec.BuildInputSchema: Variant;
var
  Properties, Prop, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // cmd - command to execute
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Windows command to execute';
  TDocVariantData(Properties).AddValue('cmd', Prop);

  // cwd - working directory
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Working directory (must be under allowed roots)';
  TDocVariantData(Properties).AddValue('cwd', Prop);

  // timeout - execution timeout
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'integer';
  TDocVariantData(Prop).S['description'] := 'Timeout in seconds (max 600)';
  TDocVariantData(Prop).I['default'] := 60;
  TDocVariantData(Properties).AddValue('timeout', Prop);

  // log_file - optional file to write output
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Optional file path to write command output. On success, output is only written to file. On failure, last 10 lines are also returned in response.';
  TDocVariantData(Properties).AddValue('log_file', Prop);

  // token - authentication token (required when authentication enabled)
  if RequiresToken then
  begin
    TDocVariantData(Prop).InitFast;
    TDocVariantData(Prop).S['type'] := 'string';
    TDocVariantData(Prop).S['description'] := 'Authentication token required for this tool';
    TDocVariantData(Properties).AddValue('token', Prop);
  end;

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: cmd (and token when authentication enabled)
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('cmd');
  if RequiresToken then
    TDocVariantData(Required).AddItem('token');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolWindowsExec.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Cmd, Cwd, Output, LogFile: RawUtf8;
  Tail : TArray<string>;
  Timeout, ExitCode: Integer;
  ResultDoc: TDocVariantData;
const CRLF = #13#10; nTail = 10;
begin
  ArgsDoc := _Safe(Arguments);

  // Check authentication (session cache or token validation)
  if RequiresToken and not AuthenticateSession(ArgsDoc^.U['token'], SessionId) then
  begin
    Result := ToolResultText('Authentication failed: invalid or missing token. Claude Code: Please prompt user for authentication token and retry.', True);
    Exit;
  end;

  Cmd := ArgsDoc^.U['cmd'];
  if Cmd = '' then
  begin
    Result := ToolResultText('Parameter "cmd" is required', True);
    Exit;
  end;

  Cwd := ArgsDoc^.U['cwd'];
  if (Cwd <> '') and not IsPathAllowed(Cwd) then
  begin
    Result := ToolResultText(FormatUtf8('Working directory not allowed: %', [Cwd]), True);
    Exit;
  end;

  LogFile := ArgsDoc^.U['log_file'];
  if (LogFile <> '') and not IsPathAllowed(LogFile) then
  begin
    Result := ToolResultText(FormatUtf8('Log file path not allowed: %', [LogFile]), True);
    Exit;
  end;

  Timeout := ArgsDoc^.I['timeout'];
  if Timeout <= 0 then
    Timeout := 60;
  if Timeout > 600 then
    Timeout := 600;

  // Execute command
  CodeSite.EnterMethod('windows_exec: ' + Utf8ToString(Cmd));
  try
    if LogFile = '' then
      fOnOutput := OnCommandOutput;  // writes chunks live to Codesite
    try
      if not ExecuteCommand(Cmd, Cwd, Timeout * 1000, Output, ExitCode) then
      begin
        Result := ToolResultText('Failed to execute command', True);
        Exit;
      end;
    finally
      fOnOutput := nil;
    end;
    if (Cwd <> '') then CodeSite.Send('Cwd: "%s"', [Cwd]);
    if LogFile <> '' then begin
      // CodeSite already sent a stream of chunks if no Logfile
      Tail := string(Output).split([CRLF], TStringSplitOptions.ExcludeEmpty);
      var lTail := Length(Tail);
      if lTail > nTail then begin
        var iTail := lTail - nTail;
        Tail  := Copy(Tail, iTail, nTail);
      end;
      for var L in Tail do CodeSite.Send(L);
      CodeSite.Send('Log_File: "%s"', [LogFile]);
    end;
  finally
    var b := (ExitCode = 0);
    var s := 'Success';
    if not b then s:= 'Failed';
    CodeSite.ExitMethod(Format('windows_exec: %s(%d)', [s, ExitCode]));
  end;


    // Build result
    ResultDoc.InitFast;
    ResultDoc.B['success'] := ExitCode = 0;
    ResultDoc.I['exit_code'] := ExitCode;

    if LogFile <> '' then
    begin
      // Write output to log file
      if not FileFromString(Output, LogFile, True) then
      begin
        Result := ToolResultText(FormatUtf8('Failed to write log file: %', [LogFile]), True);
        Exit;
      end;
      ResultDoc.U['log_file'] := LogFile;

      // On failure, include last n lines
      if ExitCode <> 0 then
        ResultDoc.U['output_tail'] := RawUtf8(string.Join(CRLF, Tail));
    end
    else
    begin
      // Existing behavior - return full output
      ResultDoc.U['output'] := Output;
      ResultDoc.U['command'] := Cmd;
      if Cwd <> '' then
        ResultDoc.U['cwd'] := Cwd;
    end;

    Result := ToolResultJson(Variant(ResultDoc));

end;

end.
