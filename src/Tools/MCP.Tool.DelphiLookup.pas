/// MCP Delphi Symbol Lookup Tool
// - Searches Delphi/Pascal symbol databases using delphi-lookup.exe
unit MCP.Tool.DelphiLookup;

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
  MCP.Tool.BuildService;

const
  /// delphi-lookup.exe filename (lives next to MCPServer.exe)
  LOOKUP_EXE_NAME = 'delphi-lookup.exe';

  /// Lookup command timeout (milliseconds)
  LOOKUP_TIMEOUT_MS = 10000;

type
  /// Delphi symbol lookup tool - searches symbol databases
  TMCPToolDelphiLookup = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolDelphiLookup }

constructor TMCPToolDelphiLookup.Create;
begin
  inherited Create;
  fName := 'delphi_lookup';
  fDescription := 'Search Delphi/Pascal symbol databases using delphi-lookup.exe. ' +
    'Returns matching symbols with their defining units, file paths, and context. ' +
    'Available databases: DevEx.db, Ni6.db, DFX.db, UniDAC.db, mad.db, delphi12.db, delphi13.db. ' +
    'Use when resolving undeclared identifier errors (search identifier -> find defining unit -> add to uses clause), ' +
    'finding where a type/function/constant is defined, or searching for API usage examples. ' +
    'Try this before Grep/Glob for Delphi symbol lookups.';
end;

function TMCPToolDelphiLookup.BuildInputSchema: Variant;
var
  Properties, Prop, EnumArr, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // q - search query (required)
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Search query (symbol name, identifier, or concept)';
  TDocVariantData(Properties).AddValue('q', Prop);

  // database - specific database to search (required)
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Database to search (e.g. DevEx.db, delphi13.db)';
  TDocVariantData(Properties).AddValue('database', Prop);

  // num_results - number of results
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'integer';
  TDocVariantData(Prop).S['description'] := 'Number of results to return';
  TDocVariantData(Prop).I['default'] := 10;
  TDocVariantData(Properties).AddValue('num_results', Prop);

  // symbol - filter by symbol type
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Filter by symbol type: class, function, type, const, variable, property, enum';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('class');
  TDocVariantData(EnumArr).AddItem('function');
  TDocVariantData(EnumArr).AddItem('type');
  TDocVariantData(EnumArr).AddItem('const');
  TDocVariantData(EnumArr).AddItem('variable');
  TDocVariantData(EnumArr).AddItem('property');
  TDocVariantData(EnumArr).AddItem('enum');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('symbol', Prop);

  // framework - filter by framework
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Filter by framework: RTL, VCL, FMX';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('RTL');
  TDocVariantData(EnumArr).AddItem('VCL');
  TDocVariantData(EnumArr).AddItem('FMX');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('framework', Prop);

  // category - filter by category
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Filter by category: user, stdlib, third_party';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('user');
  TDocVariantData(EnumArr).AddItem('stdlib');
  TDocVariantData(EnumArr).AddItem('third_party');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('category', Prop);

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: q, database
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('q');
  TDocVariantData(Required).AddItem('database');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolDelphiLookup.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Query, Database, Symbol, Framework, Category: RawUtf8;
  NumResults, ExitCode: Integer;
  LookupExe, Cmd, Output, ExeDir: RawUtf8;
  ResultDoc: TDocVariantData;
begin
  ArgsDoc := _Safe(Arguments);

  Query := ArgsDoc^.U['q'];
  if Query = '' then
  begin
    Result := ToolResultText('Parameter "q" is required', True);
    Exit;
  end;

  // Resolve exe path relative to MCPServer.exe directory
  ExeDir := StringToUtf8(Executable.ProgramFilePath);
  LookupExe := ExeDir + LOOKUP_EXE_NAME;

  if not FileExists(Utf8ToString(LookupExe)) then
  begin
    Result := ToolResultText(FormatUtf8('delphi-lookup.exe not found at: %', [LookupExe]), True);
    Exit;
  end;

  // Read parameters
  Database := ArgsDoc^.U['database'];
  if Database = '' then
  begin
    Result := ToolResultText('Parameter "database" is required (e.g. DevEx.db, delphi13.db)', True);
    Exit;
  end;

  Symbol := ArgsDoc^.U['symbol'];
  Framework := ArgsDoc^.U['framework'];
  Category := ArgsDoc^.U['category'];
  NumResults := ArgsDoc^.I['num_results'];
  if NumResults <= 0 then
    NumResults := 10;

  // Build command — resolve database to dbs\ subfolder
  Cmd := FormatUtf8('"%"', [LookupExe]);
  Cmd := Cmd + FormatUtf8(' "%"', [Query]);
  Cmd := Cmd + FormatUtf8(' --num-results %', [NumResults]);
  Cmd := Cmd + FormatUtf8(' --database "dbs\%"', [Database]);
  if Symbol <> '' then
    Cmd := Cmd + FormatUtf8(' --symbol %', [Symbol]);
  if Framework <> '' then
    Cmd := Cmd + FormatUtf8(' --framework %', [Framework]);
  if Category <> '' then
    Cmd := Cmd + FormatUtf8(' --category %', [Category]);

  if not ExecuteCommand(Cmd, ExeDir, LOOKUP_TIMEOUT_MS, Output, ExitCode) then
  begin
    Result := ToolResultText('Failed to execute delphi-lookup', True);
    Exit;
  end;

  // Build result
  ResultDoc.InitFast;
  ResultDoc.B['success'] := ExitCode = 0;
  ResultDoc.U['results'] := Output;
  ResultDoc.U['query'] := Query;
  ResultDoc.U['command'] := Cmd;

  Result := ToolResultJson(Variant(ResultDoc));
end;

end.
