/// MCP Windows Dir Tool
// - List directory contents on Windows natively
unit MCP.Tool.WindowsDir;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  MCP.Tool.Base,
  MCP.Tool.BuildService;

type
  /// Windows dir tool - lists directory contents
  TMCPToolWindowsDir = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolWindowsDir }

constructor TMCPToolWindowsDir.Create;
begin
  inherited Create;
  fName := 'windows_dir';
  fDescription := 'List directory contents on Windows. Path must be under allowed roots: ' +
    'D:\My Projects, D:\ECL, D:\VCL. ' +
    'Returns JSON with files array and count. ' +
    'Use pattern to filter results (e.g. *.pas for Pascal sources, ~Build*.cmd for build scripts, *.dproj for Delphi projects)';
end;

function TMCPToolWindowsDir.BuildInputSchema: Variant;
var
  Properties, Prop, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // path - directory path
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Directory path to list';
  TDocVariantData(Properties).AddValue('path', Prop);

  // pattern - filter pattern
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Filter pattern (e.g., *.pas, *.dproj)';
  TDocVariantData(Prop).S['default'] := '*';
  TDocVariantData(Properties).AddValue('pattern', Prop);

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: path
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('path');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolWindowsDir.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Path, Pattern, Output, Line: RawUtf8;
  ExitCode: Integer;
  ResultDoc: TDocVariantData;
  Files: TDocVariantData;
  Lines: TRawUtf8DynArray;
  i: Integer;
  Cmd: RawUtf8;
begin
  ArgsDoc := _Safe(Arguments);

  Path := ArgsDoc^.U['path'];
  if Path = '' then
  begin
    Result := ToolResultText('Parameter "path" is required', True);
    Exit;
  end;

  if not IsPathAllowed(Path) then
  begin
    Result := ToolResultText(FormatUtf8('Path not allowed: %', [Path]), True);
    Exit;
  end;

  Pattern := ArgsDoc^.U['pattern'];
  if Pattern = '' then
    Pattern := '*';

  // Build dir command
  Cmd := FormatUtf8('dir /b "%\%"', [Path, Pattern]);

  // Execute command
  if not ExecuteCommand(Cmd, '', CMD_TIMEOUT_MS, Output, ExitCode) then
  begin
    Result := ToolResultText('Failed to list directory', True);
    Exit;
  end;

  // Parse output into file list
  Files.InitArray([], JSON_FAST);
  if Output <> '' then
  begin
    Lines := nil;
    CSVToRawUtf8DynArray(Pointer(Output), Lines, #10);
    for i := 0 to High(Lines) do
    begin
      Line := Trim(Lines[i]);
      if Line <> '' then
        Files.AddItem(Line);
    end;
  end;

  // Build result
  ResultDoc.InitFast;
  ResultDoc.B['success'] := ExitCode = 0;
  ResultDoc.U['path'] := Path;
  ResultDoc.U['pattern'] := Pattern;
  ResultDoc.AddValue('files', Variant(Files));
  ResultDoc.I['count'] := Files.Count;

  Result := ToolResultJson(Variant(ResultDoc));
end;

end.
