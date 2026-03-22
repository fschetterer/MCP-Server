/// MCP Delphi LSP Go-to-Definition Tool
// - Returns the file and line where a symbol is declared
unit MCP.Tool.DelphiDefinition;

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
  TMCPToolDelphiDefinition = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

constructor TMCPToolDelphiDefinition.Create;
begin
  inherited Create;
  fName := 'delphi_definition';
  fDescription :=
    'Find where a Delphi symbol is declared (go-to-definition), returning ' +
    'the exact file path and line number from the symbol database. ' +
    'Returns file path, line, and character of the declaration. ' +
    'Use for: tracing where a type or method is defined, navigating to the ' +
    'source of a third-party symbol, verifying the correct overload. ' +
    'database: short name (e.g. delphi12) or full Windows path to .db file. ' +
    'file: full Windows path to the source file containing the symbol reference. ' +
    'line/character: 1-based position of the symbol.';
end;

function TMCPToolDelphiDefinition.BuildInputSchema: Variant;
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

function TMCPToolDelphiDefinition.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  Args: PDocVariantData;
  Database, FilePath: RawUtf8;
  Line, Character: Int64;
  Client: TMCPLSPClient;
  Params, TextDoc, Position: Variant;
  ResultValue: Variant;
  ErrorMsg, Output, LocFile: RawUtf8;
  ResultArr: PDocVariantData;
  LocDoc, RangeDoc, StartDoc: PDocVariantData;
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

  TDocVariantData(Params).InitFast;
  TDocVariantData(Params).AddValue('textDocument', TextDoc);
  TDocVariantData(Params).AddValue('position', Position);

  Client := TMCPLSPClientStore.GetClient(Database);
  if not Client.SendRequest('textDocument/definition', Params, LSP_TIMEOUT_MS, ResultValue, ErrorMsg) then
  begin
    Result := ToolResultText(ErrorMsg, True);
    Exit;
  end;

  if VarIsEmptyOrNull(ResultValue) then
  begin
    Result := ToolResultText('No definition found');
    Exit;
  end;

  // Result is Location | Location[] — normalize to array
  ResultArr := _Safe(ResultValue);
  Output := '';
  if ResultArr^.Kind = dvArray then
  begin
    for i := 0 to ResultArr^.Count - 1 do
    begin
      LocDoc   := _Safe(ResultArr^.Values[i]);
      LocFile  := FileUriToPath(LocDoc^.U['uri']);
      RangeDoc := LocDoc^.O['range'];
      if RangeDoc <> nil then
      begin
        StartDoc := RangeDoc^.O['start'];
        if StartDoc <> nil then
          Output := Output + FormatUtf8('%  line % char %'#10,
            [LocFile, StartDoc^.I['line'] + 1, StartDoc^.I['character'] + 1])
        else
          Output := Output + LocFile + #10;
      end
      else
        Output := Output + LocFile + #10;
    end;
  end
  else
  begin
    LocDoc  := ResultArr;
    LocFile := FileUriToPath(LocDoc^.U['uri']);
    RangeDoc := LocDoc^.O['range'];
    if RangeDoc <> nil then
    begin
      StartDoc := RangeDoc^.O['start'];
      if StartDoc <> nil then
        Output := FormatUtf8('%  line % char %',
          [LocFile, StartDoc^.I['line'] + 1, StartDoc^.I['character'] + 1])
      else
        Output := LocFile;
    end
    else
      Output := LocFile;
  end;

  if Output = '' then
    Result := ToolResultText('No definition found')
  else
    Result := ToolResultText(TrimU(Output));
end;

end.
