/// MCP Delphi Build Tool
// - Runs existing build scripts and returns structured error output
unit MCP.Tool.DelphiBuild;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.os,
  MCP.Tool.Base,
  MCP.Tool.BuildService,
  CodeSiteLogging;

type
  /// Delphi build tool - runs build scripts and returns structured errors
  TMCPToolDelphiBuild = class(TMCPToolBuildServiceBase)
  private
    procedure ParseCompilerOutput(const Output: RawUtf8;
      var Errors, Warnings, Hints: TDocVariantData);
    procedure OnBuildOutput(const Chunk: RawUtf8);
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolDelphiBuild }

constructor TMCPToolDelphiBuild.Create;
begin
  inherited Create;
  fName := 'delphi_build';
  fDescription := 'Compile a Delphi project by running an existing build script (.cmd). ' +
    'Returns structured errors, warnings, and hints parsed from compiler output. ' +
    'Build scripts use the naming convention ~BuildDEBUG.cmd and ~BuildRELEASE.cmd in the project directory. ' +
    'Workflow: (1) Use windows_dir with pattern ~Build*.cmd to find existing scripts in the project directory. ' +
    '(2) If no script exists, create one that calls rsvars.bat, sets version variables, then invokes MSBuild on the .dproj file. ' +
    '(3) Run the build with this tool. ' +
    '(4) On failure, read the failing source file at the reported line, fix the error, and rebuild. ' +
    'Delphi versions: athens/d12 (ProductVersion=23.0), florence/d13 (ProductVersion=37.0). ' +
    'RSVars location: C:\Program Files (x86)\Embarcadero\Studio\{ProductVersion}\bin\rsvars.bat. ' +
    'Build script template: after calling rsvars.bat and setting version variables, invoke MSBuild with console flags ''/nologo /v:q /clp:NoSummary;ErrorsOnly'' (suppress noise, errors only on console) and file logging ''/fl /flp:logfile=..\logs\MyOutput.log;verbosity=normal'' (full verbose log for diagnosis). Ensure the logs\ folder exists relative to the script. Result includes: success, exit_code, errors/warnings/hints arrays (each entry has file, line, code, severity, message), and raw_output.';
end;

function TMCPToolDelphiBuild.BuildInputSchema: Variant;
var
  Properties, Prop, EnumArr, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // script - path to build .cmd
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Path to build script (.cmd file). ' +
      'Scripts are named ~BuildDEBUG.cmd or ~BuildRELEASE.cmd in the project directory. ' +
      'Use windows_dir with pattern ~Build*.cmd to find them';
  TDocVariantData(Properties).AddValue('script', Prop);

  // config - build configuration (informational, for finding ~BuildDEBUG.cmd etc.)
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Build configuration - identifies which script to use (e.g. ~BuildDEBUG.cmd for DEBUG, ~BuildRELEASE.cmd for RELEASE)';
  TDocVariantData(Prop).S['default'] := 'DEBUG';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('DEBUG');
  TDocVariantData(EnumArr).AddItem('RELEASE');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('config', Prop);

  // platform - target platform
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Target platform';
  TDocVariantData(Prop).S['default'] := 'Win64';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('Win32');
  TDocVariantData(EnumArr).AddItem('Win64');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('platform', Prop);

  // verbosity - MSBuild verbosity
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'MSBuild verbosity level: q=quiet, m=minimal, n=normal, d=detailed, diag=diagnostic';
  TDocVariantData(Prop).S['default'] := 'n';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('q');
  TDocVariantData(EnumArr).AddItem('m');
  TDocVariantData(EnumArr).AddItem('n');
  TDocVariantData(EnumArr).AddItem('d');
  TDocVariantData(EnumArr).AddItem('diag');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('verbosity', Prop);

  // token - authentication token (required when authentication enabled)
  if RequiresToken then
  begin
    TDocVariantData(Prop).InitFast;
    TDocVariantData(Prop).S['type'] := 'string';
    TDocVariantData(Prop).S['description'] := 'Authentication token required for this tool';
    TDocVariantData(Properties).AddValue('token', Prop);
  end;

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: script (and token when authentication enabled)
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('script');
  if RequiresToken then
    TDocVariantData(Required).AddItem('token');
  TDocVariantData(Result).AddValue('required', Required);
end;

procedure TMCPToolDelphiBuild.ParseCompilerOutput(const Output: RawUtf8;
  var Errors, Warnings, Hints: TDocVariantData);
var
  Lines: TRawUtf8DynArray;
  Line, Rest, Key: RawUtf8;
  i, P1, P2, PBracket: Integer;
  Entry: TDocVariantData;
  Severity, FileName, LineNum, Code, Msg: RawUtf8;
  Seen: TRawUtf8DynArray;
  SeenCount: Integer;
  IsDup: Boolean;

  procedure AddEntry;
  var j : integer;
  begin
    // Deduplicate: MSBuild reports each diagnostic twice (inline + summary)
    Key := FileName + ':' + LineNum + ':' + Code;
    IsDup := False;
    for j := 0 to SeenCount - 1 do
      if Seen[j] = Key then
      begin
        IsDup := True;
        Break;
      end;
    if IsDup then Exit;
    if SeenCount >= Length(Seen) then
      SetLength(Seen, SeenCount + 64);
    Seen[SeenCount] := Key;
    Inc(SeenCount);

    Entry.InitFast;
    Entry.U['file'] := FileName;
    Entry.I['line'] := Utf8ToInteger(LineNum);
    Entry.U['code'] := Code;
    Entry.U['severity'] := Severity;
    Entry.U['message'] := Msg;
    if Severity = 'error' then
      Errors.AddItem(Variant(Entry))
    else if Severity = 'warning' then
      Warnings.AddItem(Variant(Entry))
    else
      Hints.AddItem(Variant(Entry));
  end;

begin
  // Parses two output formats:
  //   dcc64:   [dcc64 Error] file(line): code message
  //   MSBuild: file(line): Fatal error|Error|Warning|Hint warning code: message [project]
  Errors.InitArray([], JSON_FAST);
  Warnings.InitArray([], JSON_FAST);
  Hints.InitArray([], JSON_FAST);
  SeenCount := 0;

  CSVToRawUtf8DynArray(Pointer(Output), Lines, #10);
  for i := 0 to High(Lines) do
  begin
    Line := Trim(Lines[i]);
    Severity := '';

    // --- Format 1: [dcc64 Fatal Error|Error|Warning|Hint] file(line): code message ---
    if (PosEx('[dcc64 Fatal Error]', Line) > 0) or
       (PosEx('[dcc64 Error]', Line) > 0) then
      Severity := 'error'
    else if PosEx('[dcc64 Warning]', Line) > 0 then
      Severity := 'warning'
    else if PosEx('[dcc64 Hint]', Line) > 0 then
      Severity := 'hint';

    if Severity <> '' then
    begin
      P1 := PosEx(']', Line);
      if P1 = 0 then Continue;
      Line := Trim(Copy(Line, P1 + 1, MaxInt));

      P1 := PosEx('(', Line);
      P2 := PosEx(')', Line);
      if (P1 = 0) or (P2 = 0) then Continue;

      FileName := Trim(Copy(Line, 1, P1 - 1));
      LineNum := Copy(Line, P1 + 1, P2 - P1 - 1);
      Line := Trim(Copy(Line, P2 + 1, MaxInt));

      if (Length(Line) > 0) and (Line[1] = ':') then
        Line := Trim(Copy(Line, 2, MaxInt));

      P1 := PosEx(' ', Line);
      if P1 > 0 then
      begin
        Code := Copy(Line, 1, P1 - 1);
        Msg := Trim(Copy(Line, P1 + 1, MaxInt));
      end
      else
      begin
        Code := Line;
        Msg := '';
      end;

      AddEntry;
      Continue;
    end;

    // --- Format 2: file(line): severity code: message [project] ---
    // MSBuild wraps dcc64 output as: file(line): Warning warning H2219: message [project]
    P1 := PosEx('(', Line);
    P2 := PosEx(')', Line);
    if (P1 = 0) or (P2 = 0) or (P1 >= P2) then Continue;

    // Line number must be numeric
    LineNum := Copy(Line, P1 + 1, P2 - P1 - 1);
    if Utf8ToInteger(LineNum, -1) < 0 then Continue;

    Rest := Trim(Copy(Line, P2 + 1, MaxInt));
    if (Length(Rest) = 0) or (Rest[1] <> ':') then Continue;
    Rest := Trim(Copy(Rest, 2, MaxInt));

    // Detect severity from MSBuild format
    if (PosEx('Fatal error ', Rest) = 1) or (PosEx('Error ', Rest) = 1) then
      Severity := 'error'
    else if PosEx('Warning warning ', Rest) = 1 then
      Severity := 'warning'
    else if PosEx('Hint warning ', Rest) = 1 then
      Severity := 'hint'
    else if PosEx('Warning ', Rest) = 1 then
      Severity := 'warning'
    else if PosEx('Hint ', Rest) = 1 then
      Severity := 'hint'
    else
      Continue;

    FileName := Trim(Copy(Line, 1, P1 - 1));

    // Skip severity prefix to get "code: message [project]"
    P1 := PosEx(' ', Rest);
    if P1 = 0 then Continue;
    Rest := Trim(Copy(Rest, P1 + 1, MaxInt));
    // If "Warning warning" or "Hint warning", skip the second word too
    if (PosEx('warning ', Rest) = 1) then
      Rest := Trim(Copy(Rest, 9, MaxInt));

    // Extract code (before ':')
    P1 := PosEx(':', Rest);
    if P1 = 0 then Continue;
    Code := Trim(Copy(Rest, 1, P1 - 1));
    Rest := Trim(Copy(Rest, P1 + 1, MaxInt));

    // Strip trailing [project] if present
    PBracket := PosEx(' [', Rest);
    if PBracket > 0 then
      Msg := Trim(Copy(Rest, 1, PBracket - 1))
    else
      Msg := Rest;

    AddEntry;
  end;
end;

procedure TMCPToolDelphiBuild.OnBuildOutput(const Chunk: RawUtf8);
begin
  CodeSite.Send(Utf8ToString(Chunk));
end;

function TMCPToolDelphiBuild.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Script, Cmd, Output, ScriptDir: RawUtf8;
  ExitCode: Integer;
  ResultDoc: TDocVariantData;
  Errors, Warnings, Hints: TDocVariantData;
begin
  ArgsDoc := _Safe(Arguments);

  // Check authentication (session cache or token validation)
  if RequiresToken and not AuthenticateSession(ArgsDoc^.U['token'], SessionId) then
  begin
    Result := ToolResultText('Authentication failed: invalid or missing token. Claude Code: Please prompt user for authentication token and retry.', True);
    Exit;
  end;

  Script := ArgsDoc^.U['script'];
  if Script = '' then
  begin
    Result := ToolResultText('Parameter "script" is required. ' +
      'Provide the path to an existing build script (.cmd).', True);
    Exit;
  end;

  if not IsPathAllowed(Script) then
  begin
    Result := ToolResultText(FormatUtf8('Script path not allowed: %', [Script]), True);
    Exit;
  end;

  // Check script exists
  if not FileExists(Utf8ToString(Script)) then
  begin
    Result := ToolResultText(FormatUtf8('Build script not found: %. ' +
      'Create the script first, then retry.', [Script]), True);
    Exit;
  end;

  ScriptDir := StringToUtf8(ExtractFilePath(Utf8ToString(Script)));
  Cmd := FormatUtf8('"%"', [Script]);

  // Execute build with CodeSite streaming
  CodeSite.EnterMethod('delphi_build: ' + Utf8ToString(Script));
  try
    fOnOutput := OnBuildOutput;
    try
      if not ExecuteCommand(Cmd, ScriptDir, BUILD_TIMEOUT_MS, Output, ExitCode) then
      begin
        Result := ToolResultText('Failed to execute build script', True);
        Exit;
      end;
    finally
      fOnOutput := nil;
    end;
  finally
    CodeSite.ExitMethod('delphi_build');
  end;

  // Parse compiler output
  ParseCompilerOutput(Output, Errors, Warnings, Hints);

  // Build result with summary in header
  ResultDoc.InitFast;
  ResultDoc.B['success'] := ExitCode = 0;
  ResultDoc.I['exit_code'] := ExitCode;
  ResultDoc.AddValue('errors', Variant(Errors));
  ResultDoc.AddValue('warnings', Variant(Warnings));
  ResultDoc.AddValue('hints', Variant(Hints));
  ResultDoc.I['error_count'] := Errors.Count;
  ResultDoc.I['warning_count'] := Warnings.Count;
  ResultDoc.I['hint_count'] := Hints.Count;
  ResultDoc.U['raw_output'] := Output;

  // Log summary to CodeSite
  if ExitCode = 0 then
    CodeSite.Send(Format('Build SUCCEEDED: %d error(s), %d warning(s), %d hint(s)',
      [Errors.Count, Warnings.Count, Hints.Count]))
  else
    CodeSite.SendError(Format('Build FAILED: %d error(s), %d warning(s), %d hint(s)',
      [Errors.Count, Warnings.Count, Hints.Count]));

  Result := ToolResultJson(Variant(ResultDoc));
end;

end.
