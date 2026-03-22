/// MCP Delphi LSP Find References Tool
// - Returns all locations that reference a symbol
unit MCP.Tool.DelphiReferences;

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
  TMCPToolDelphiReferences = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

constructor TMCPToolDelphiReferences.Create;
begin
  inherited Create;
  fName := 'delphi_references';
  fDescription :=
    'Find all references to a Delphi symbol across the indexed codebase. ' +
    'Returns a list of file:line:char locations where the symbol is used. ' +
    'Use for: impact analysis before renaming, finding all callers of a method, ' +
    'understanding which units depend on a type. ' +
    'database: short name (e.g. delphi12) or full Windows path to .db file. ' +
    'file: full Windows path to the source file containing the symbol. ' +
    'line/character: 1-based position of the symbol to find references for.';
end;

function TMCPToolDelphiReferences.BuildInputSchema: Variant;
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

function TMCPToolDelphiReferences.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  Args: PDocVariantData;
  Database, FilePath: RawUtf8;
  Line, Character: Int64;
  Client: TMCPLSPClient;
  Params, TextDoc, Position, Context: Variant;
  ResultValue: Variant;
  ErrorMsg, Output, LocFile: RawUtf8;
  ResultArr, LocDoc, RangeDoc, StartDoc: PDocVariantData;
  i: Integer;
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

  TDocVariantData(Context).InitFast;
  TDocVariantData(Context).B['includeDeclaration'] := True;

  TDocVariantData(Params).InitFast;
  TDocVariantData(Params).AddValue('textDocument', TextDoc);
  TDocVariantData(Params).AddValue('position', Position);
  TDocVariantData(Params).AddValue('context', Context);

  Client := TMCPLSPClientStore.GetClient(Database);
  if not Client.SendRequest('textDocument/references', Params, LSP_TIMEOUT_MS, ResultValue, ErrorMsg) then
  begin
    Result := ToolResultText(ErrorMsg, True);
    Exit;
  end;

  if VarIsEmptyOrNull(ResultValue) then
  begin
    Result := ToolResultText('No references found');
    Exit;
  end;

  ResultArr := _Safe(ResultValue);
  if (ResultArr^.Kind <> dvArray) or (ResultArr^.Count = 0) then
  begin
    Result := ToolResultText('No references found');
    Exit;
  end;

  Output := FormatUtf8('Found % reference(s):'#10, [ResultArr^.Count]);
  for i := 0 to ResultArr^.Count - 1 do
  begin
    LocDoc   := _Safe(ResultArr^.Values[i]);
    LocFile  := FileUriToPath(LocDoc^.U['uri']);
    RangeDoc := LocDoc^.O['range'];
    if RangeDoc <> nil then
    begin
      StartDoc := RangeDoc^.O['start'];
      if StartDoc <> nil then
        Output := Output + FormatUtf8('  %:%:%'#10,
          [LocFile, StartDoc^.I['line'] + 1, StartDoc^.I['character'] + 1])
      else
        Output := Output + '  ' + LocFile + #10;
    end
    else
      Output := Output + '  ' + LocFile + #10;
  end;

  Result := ToolResultText(TrimU(Output));
end;

end.
