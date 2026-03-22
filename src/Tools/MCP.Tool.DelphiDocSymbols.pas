/// MCP Delphi LSP Document Symbols Tool
// - Lists all symbols declared in a source file
unit MCP.Tool.DelphiDocSymbols;

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
  TMCPToolDelphiDocSymbols = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

constructor TMCPToolDelphiDocSymbols.Create;
begin
  inherited Create;
  fName := 'delphi_document_symbols';
  fDescription :=
    'List all symbols declared in a Delphi source file with their kinds and ' +
    'line numbers, using the delphi-lsp-server symbol database. ' +
    'Returns a structured outline: classes, methods, properties, fields, ' +
    'functions, types, constants, and variables. ' +
    'Use for: getting a quick overview of a file''s structure, finding where ' +
    'a specific method is defined within a unit, understanding class hierarchy. ' +
    'database: short name (e.g. delphi12) or full Windows path to .db file. ' +
    'file: full Windows path to the .pas source file to outline.';
end;

function TMCPToolDelphiDocSymbols.BuildInputSchema: Variant;
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
  TDocVariantData(Prop).S['description'] := 'Full Windows path to the source file to outline';
  TDocVariantData(Properties).AddValue('file', Prop);

  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Authentication token';
  TDocVariantData(Properties).AddValue('token', Prop);

  TDocVariantData(Result).AddValue('properties', Properties);

  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('database');
  TDocVariantData(Required).AddItem('file');
  TDocVariantData(Result).AddValue('required', Required);
end;

procedure FormatSymbols(Arr: PDocVariantData; Indent: Integer; var Output: RawUtf8);
var
  i: Integer;
  SymDoc, RangeDoc, SelDoc, StartDoc: PDocVariantData;
  Name, Kind, Pad: RawUtf8;
  KindNum: Int64;
  ChildrenVar: Variant;
  Children: PDocVariantData;
  Line: Int64;
begin
  if (Arr = nil) or (Arr^.Kind <> dvArray) then
    Exit;
  Pad := '';
  for i := 1 to Indent do
    Pad := Pad + '  ';
  for i := 0 to Arr^.Count - 1 do
  begin
    SymDoc  := _Safe(Arr^.Values[i]);
    Name    := SymDoc^.U['name'];
    KindNum := SymDoc^.I['kind'];
    Kind    := LspSymbolKindName(KindNum);

    // DocumentSymbol uses selectionRange; SymbolInformation uses location.range
    SelDoc := SymDoc^.O['selectionRange'];
    if SelDoc <> nil then
    begin
      StartDoc := SelDoc^.O['start'];
      if StartDoc <> nil then
        Line := StartDoc^.I['line'] + 1
      else
        Line := 0;
    end
    else
    begin
      RangeDoc := SymDoc^.O['range'];
      if RangeDoc <> nil then
      begin
        StartDoc := RangeDoc^.O['start'];
        if StartDoc <> nil then
          Line := StartDoc^.I['line'] + 1
        else
          Line := 0;
      end
      else
        Line := 0;
    end;

    if Line > 0 then
      Output := Output + FormatUtf8('%[%] % (line %)'#10, [Pad, Kind, Name, Line])
    else
      Output := Output + FormatUtf8('%[%] %'#10, [Pad, Kind, Name]);

    // Recurse into children (DocumentSymbol only)
    ChildrenVar := SymDoc^.Value['children'];
    if not VarIsEmptyOrNull(ChildrenVar) then
    begin
      Children := _Safe(ChildrenVar);
      FormatSymbols(Children, Indent + 1, Output);
    end;
  end;
end;

function TMCPToolDelphiDocSymbols.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  Args: PDocVariantData;
  Database, FilePath: RawUtf8;
  Client: TMCPLSPClient;
  Params, TextDoc: Variant;
  ResultValue: Variant;
  ErrorMsg, Output: RawUtf8;
  ResultArr: PDocVariantData;
begin
  Args := _Safe(Arguments);

  if not AuthenticateSession(Args^.U['token'], SessionId) then
  begin
    Result := ToolResultText('Authentication required', True);
    Exit;
  end;

  Database := ResolveDatabasePath(Args^.U['database']);
  FilePath := Args^.U['file'];

  if (Database = '') or (FilePath = '') then
  begin
    Result := ToolResultText('database and file are required', True);
    Exit;
  end;

  TDocVariantData(TextDoc).InitFast;
  TDocVariantData(TextDoc).U['uri'] := PathToFileUri(FilePath);

  TDocVariantData(Params).InitFast;
  TDocVariantData(Params).AddValue('textDocument', TextDoc);

  Client := TMCPLSPClientStore.GetClient(Database);
  if not Client.SendRequest('textDocument/documentSymbol', Params, LSP_TIMEOUT_MS, ResultValue, ErrorMsg) then
  begin
    Result := ToolResultText(ErrorMsg, True);
    Exit;
  end;

  if VarIsEmptyOrNull(ResultValue) then
  begin
    Result := ToolResultText('No symbols found');
    Exit;
  end;

  ResultArr := _Safe(ResultValue);
  if (ResultArr^.Kind <> dvArray) or (ResultArr^.Count = 0) then
  begin
    Result := ToolResultText('No symbols found');
    Exit;
  end;

  Output := FormatUtf8('Symbols in %:'#10, [FilePath]);
  FormatSymbols(ResultArr, 0, Output);

  Result := ToolResultText(TrimU(Output));
end;

end.
