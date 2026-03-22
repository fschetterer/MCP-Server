/// MCP Delphi Symbol Indexer Tool
// - Indexes Delphi/Pascal source code using delphi-indexer.exe
unit MCP.Tool.DelphiIndexer;

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
  /// delphi-indexer.exe filename (lives next to MCPServer.exe)
  INDEXER_EXE_NAME = 'delphi-indexer.exe';

  /// Indexer command timeout (milliseconds) - longer for indexing operations
  INDEXER_TIMEOUT_MS = 600000; // 10 minutes

type
  /// Delphi symbol indexer tool - indexes source code into searchable databases
  TMCPToolDelphiIndexer = class(TMCPToolBuildServiceBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant;
      const SessionId: RawUtf8): Variant; override;
  end;

implementation

{ TMCPToolDelphiIndexer }

constructor TMCPToolDelphiIndexer.Create;
begin
  inherited Create;
  fName := 'delphi_index';
  fDescription := 'Build search index from Delphi/Pascal source code using delphi-indexer.exe. ' +
    'Indexes Pascal source files into a SQLite database for symbol searching. ' +
    'Use delphi_lookup to search the indexed symbols. ' +
    'Parameters: folder (required), database (required), force, type, category, framework.';
end;

function TMCPToolDelphiIndexer.BuildInputSchema: Variant;
var
  Properties, Prop, EnumArr, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // folder - input folder containing Pascal files (required)
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Input folder containing Pascal files to index';
  TDocVariantData(Properties).AddValue('folder', Prop);

  // database - SQLite database file (required)
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'SQLite database file (stored in dbs\ subdirectory)';
  TDocVariantData(Properties).AddValue('database', Prop);

  // force - force full reindex
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'boolean';
  TDocVariantData(Prop).S['description'] := 'Force full reindex (ignore timestamps/hashes)';
  TDocVariantData(Prop).B['default'] := False;
  TDocVariantData(Properties).AddValue('force', Prop);

  // type - content type
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Content type to index';
  TDocVariantData(Prop).S['default'] := 'code';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('code');
  TDocVariantData(EnumArr).AddItem('help');
  TDocVariantData(EnumArr).AddItem('markdown');
  TDocVariantData(EnumArr).AddItem('comment');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('type', Prop);

  // category - source category
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Source category for indexing';
  TDocVariantData(Prop).S['default'] := 'user';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('user');
  TDocVariantData(EnumArr).AddItem('stdlib');
  TDocVariantData(EnumArr).AddItem('third_party');
  TDocVariantData(EnumArr).AddItem('official_help');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('category', Prop);

  // framework - explicit framework tag
  TDocVariantData(Prop).InitFast;
  TDocVariantData(Prop).S['type'] := 'string';
  TDocVariantData(Prop).S['description'] := 'Explicit framework tag (skips auto-detection)';
  TDocVariantData(EnumArr).InitArray([], JSON_FAST);
  TDocVariantData(EnumArr).AddItem('VCL');
  TDocVariantData(EnumArr).AddItem('FMX');
  TDocVariantData(EnumArr).AddItem('RTL');
  TDocVariantData(Prop).AddValue('enum', EnumArr);
  TDocVariantData(Properties).AddValue('framework', Prop);

  // token - authentication token (required when authentication enabled)
  if RequiresToken then
  begin
    TDocVariantData(Prop).InitFast;
    TDocVariantData(Prop).S['type'] := 'string';
    TDocVariantData(Prop).S['description'] := 'Authentication token required for this tool';
    TDocVariantData(Properties).AddValue('token', Prop);
  end;

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required: folder, database (and token when authentication enabled)
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('folder');
  TDocVariantData(Required).AddItem('database');
  if RequiresToken then
    TDocVariantData(Required).AddItem('token');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolDelphiIndexer.Execute(const Arguments: Variant;
  const SessionId: RawUtf8): Variant;
var
  ArgsDoc: PDocVariantData;
  Folder, Database, ContentType, Category, Framework: RawUtf8;
  Force: Boolean;
  IndexerExe, Cmd, Output, ExeDir, DbPath: RawUtf8;
  ExitCode: Integer;
  ResultDoc: TDocVariantData;
begin
  ArgsDoc := _Safe(Arguments);

  // Check authentication (session cache or token validation)
  if RequiresToken and not AuthenticateSession(ArgsDoc^.U['token'], SessionId) then
  begin
    Result := ToolResultText('Authentication failed: invalid or missing token. Claude Code: Please prompt user for authentication token and retry.', True);
    Exit;
  end;

  // Resolve exe path relative to MCPServer.exe directory
  ExeDir := StringToUtf8(Executable.ProgramFilePath);
  IndexerExe := ExeDir + INDEXER_EXE_NAME;

  if not FileExists(Utf8ToString(IndexerExe)) then
  begin
    Result := ToolResultText(FormatUtf8('delphi-indexer.exe not found at: %', [IndexerExe]), True);
    Exit;
  end;

  // Read parameters
  Folder := ArgsDoc^.U['folder'];
  if Folder = '' then
  begin
    Result := ToolResultText('Parameter "folder" is required (path to Pascal source files)', True);
    Exit;
  end;

  Database := ArgsDoc^.U['database'];
  if Database = '' then
  begin
    Result := ToolResultText('Parameter "database" is required (e.g. myproject.db)', True);
    Exit;
  end;

  // Validate folder path
  if not IsPathAllowed(Folder) then
  begin
    Result := ToolResultText(FormatUtf8('Folder path not allowed: %', [Folder]), True);
    Exit;
  end;

  // Build database path in dbs\ subdirectory
  DbPath := 'dbs\' + Database;

  Force := ArgsDoc^.B['force'];
  ContentType := ArgsDoc^.U['type'];
  Category := ArgsDoc^.U['category'];
  Framework := ArgsDoc^.U['framework'];

  // Set defaults
  if ContentType = '' then
    ContentType := 'code';
  if Category = '' then
    Category := 'user';

  // Build command
  Cmd := FormatUtf8('"%" "%"', [IndexerExe, Folder]);
  Cmd := Cmd + FormatUtf8(' --database "%"', [DbPath]);
  if Force then
    Cmd := Cmd + ' --force';
  if ContentType <> '' then
    Cmd := Cmd + FormatUtf8(' --type %', [ContentType]);
  if Category <> '' then
    Cmd := Cmd + FormatUtf8(' --category %', [Category]);
  if Framework <> '' then
    Cmd := Cmd + FormatUtf8(' --framework %', [Framework]);

  // Execute indexer
  if not ExecuteCommand(Cmd, ExeDir, INDEXER_TIMEOUT_MS, Output, ExitCode) then
  begin
    Result := ToolResultText('Failed to execute delphi-indexer', True);
    Exit;
  end;

  // Build result
  ResultDoc.InitFast;
  ResultDoc.B['success'] := ExitCode = 0;
  ResultDoc.I['exit_code'] := ExitCode;
  ResultDoc.U['output'] := Output;
  ResultDoc.U['folder'] := Folder;
  ResultDoc.U['database'] := Database;

  Result := ToolResultJson(Variant(ResultDoc));
end;

end.
