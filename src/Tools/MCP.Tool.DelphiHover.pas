/// MCP Delphi LSP Hover Tool
// - Returns hover declaration and docs for a symbol at a file position
unit MCP.Tool.DelphiHover;

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
  MCP.Tool.LSPClient;

type
  TMCPToolDelphiHover = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

constructor TMCPToolDelphiHover.Create;
begin
  inherited Create;
  fName := 'delphi_hover';
  fDescription :=
    'Show the declaration and documentation for a Delphi symbol at a given ' +
    'file position, using the delphi-lsp-server symbol database. ' +
    'Returns formatted markdown with the full type/method signature and ' +
    'any associated XML doc comments. ' +
    'Use for: inspecting unfamiliar APIs, verifying parameter types, reading ' +
    'inline documentation without opening the source file. ' +
    'database: short name (e.g. delphi12) or full Windows path to .db file. ' +
    'file: full Windows path to the .pas source file. ' +
    'line/character: 1-based position of the symbol.';
end;

function TMCPToolDelphiHover.BuildInputSchema: Variant;
var
  Properties, Prop, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Database name (e.g. delphi12) or full path to .db file';
  TDocVariantData(Properties).AddValue('database', Prop);

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Full Windows path to the source file';
  TDocVariantData(Properties).AddValue('file', Prop);

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'integer';
  TDocVariantData(Prop).S['description'] := 'Line number (1-based)';
  TDocVariantData(Properties).AddValue('line', Prop);

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'integer';
  TDocVariantData(Prop).S['description'] := 'Character offset (1-based)';
  TDocVariantData(Properties).AddValue('character', Prop);

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Authentication token';
  TDocVariantData(Properties).AddValue('token', Prop);

  TDocVariantData(Result).AddValue('properties', Properties);

  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('database');
  TDocVariantData(Required).AddItem('file');
  TDocVariantData(Required).AddItem('line');
  TDocVariantData(Required).AddItem('character');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolDelphiHover.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  Args: PDocVariantData;
  Database, FilePath: RawUtf8;
  Line, Character: Int64;
  Client: TMCPLSPClient;
  Params, TextDoc, Position: Variant;
  ResultValue: Variant;
  ErrorMsg: RawUtf8;
  ResultDoc, ContentsDoc: PDocVariantData;
  HoverText: RawUtf8;
begin
  Args := _Safe(Arguments);

  if not AuthenticateSession(Args^.U['token'], SessionId) then
  begin
    Result := ToolResultText('Authentication required', True);
    Exit;
  end;

  Database  := ResolveDatabasePath(Args^.U['database']);
  FilePath  := Args^.U['file'];
  Line      := Args^.I['line'];
  Character := Args^.I['character'];

  if (Database = '') or (FilePath = '') or (Line = 0) then
  begin
    Result := ToolResultText('database, file, line, and character are required', True);
    Exit;
  end;

  TDocVariantData(TextDoc).InitFast;
  TDocVariantData(TextDoc).U['uri'] := PathToFileUri(FilePath);

  TDocVariantData(Position).InitFast;
  TDocVariantData(Position).I['line']      := Line - 1;
  TDocVariantData(Position).I['character'] := Character - 1;

  TDocVariantData(Params).InitFast;
  TDocVariantData(Params).AddValue('textDocument', TextDoc);
  TDocVariantData(Params).AddValue('position', Position);

  Client := TMCPLSPClientStore.GetClient(Database);
  if not Client.SendRequest('textDocument/hover', Params, LSP_TIMEOUT_MS, ResultValue, ErrorMsg) then
  begin
    Result := ToolResultText(ErrorMsg, True);
    Exit;
  end;

  if VarIsEmptyOrNull(ResultValue) then
  begin
    Result := ToolResultText('No hover information at this position');
    Exit;
  end;

  // Extract text from MarkupContent { kind, value } or legacy string
  ResultDoc := _Safe(ResultValue);
  ContentsDoc := ResultDoc^.O['contents'];
  if ContentsDoc <> nil then
    HoverText := ContentsDoc^.U['value']
  else
    HoverText := ResultDoc^.U['contents'];

  if HoverText = '' then
    HoverText := _Safe(ResultValue)^.ToJson;

  Result := ToolResultText(HoverText);
end;

end.
