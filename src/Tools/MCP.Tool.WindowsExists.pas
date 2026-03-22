/// MCP Windows Exists Tool
// - Check if file or directory exists on Windows natively
unit MCP.Tool.WindowsExists;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.os,
  MCP.Tool.Base,
  MCP.Tool.BuildService;

type
  /// Windows exists tool - checks if path exists
  TMCPToolWindowsExists = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolWindowsExists }

constructor TMCPToolWindowsExists.Create;
begin
  inherited Create;
  fName := 'windows_exists';
  fDescription := 'Check if a file or directory exists on Windows. ' +
    'Returns JSON with path, exists, is_file, and is_directory fields. ' +
    'No path restriction - can check any accessible path';
end;

function TMCPToolWindowsExists.BuildInputSchema: Variant;
var
  Properties, Prop, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // path - path to check
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Path to check for existence';
  TDocVariantData(Properties).AddValue('path', Prop);

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: path
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('path');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolWindowsExists.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Path: RawUtf8;
  PathStr: TFileName;
  Exists, IsFile, IsDir: Boolean;
  ResultDoc: TDocVariantData;
begin
  ArgsDoc := _Safe(Arguments);

  Path := ArgsDoc^.U['path'];
  if Path = '' then
  begin
    Result := ToolResultText('Parameter "path" is required', True);
    Exit;
  end;

  // Convert to TFileName for file system calls
  PathStr := Utf8ToString(Path);

  // Check existence using native file system
  Exists := FileExists(PathStr) or DirectoryExists(PathStr);
  IsFile := FileExists(PathStr);
  IsDir := DirectoryExists(PathStr);

  // Build result
  ResultDoc.InitFast;
  ResultDoc.U['path'] := Path;
  ResultDoc.B['exists'] := Exists;
  ResultDoc.B['is_file'] := IsFile;
  ResultDoc.B['is_directory'] := IsDir;

  Result := ToolResultJson(Variant(ResultDoc));
end;

end.
