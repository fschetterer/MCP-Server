# Future Project: Symbol Indexer Tool

## Overview

Implement the Delphi symbol indexer as MCP tools, enabling LLMs to search Pascal/Delphi codebases for symbols, types, functions, and API usage examples.

The indexer is a local HTTP service at `http://host.docker.internal:8765` with multiple databases (DevExpress, UniDAC, Delphi RTL/VCL, etc.).

## Proposed Tools

| Tool Name | Endpoint | Purpose |
|-----------|----------|---------|
| `symbol_search` | POST /search | Full search with filters (database, symbol type, framework) |
| `symbol_search_semantic` | POST /search/semantic | Semantic search with reranking (~95% precision) |
| `symbol_reindex` | POST /reindex | Trigger database reindex |

## Input Schema: `symbol_search`

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `q` | string | yes | Search query |
| `num_results` | integer | no | Number of results (default: 10) |
| `database` | string | no | Specific database: DevEx.db, Ni6.db, DFX.db, UniDAC.db, mad.db, delphi12.db, delphi13.db |
| `symbol` | string | no | Filter by type: class, function, type, const |
| `framework` | string | no | Filter: RTL, VCL |

## Input Schema: `symbol_search_semantic`

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `q` | string | yes | Semantic search query (concepts, patterns) |
| `num_results` | integer | no | Number of results (default: 10) |

## Input Schema: `symbol_reindex`

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `database` | string | no | Specific database to reindex (all if omitted) |
| `force` | boolean | no | Force full reindex ignoring timestamps |

## Implementation

### Files to Create

1. `src/Tools/MCP.Tool.SymbolSearch.pas` - Main search tool
2. `src/Tools/MCP.Tool.SymbolSearchSemantic.pas` - Semantic search
3. `src/Tools/MCP.Tool.SymbolReindex.pas` - Reindex trigger

### Files to Modify

- `MCPServer.dpr` / `MCPServer.lpr` - Register new tools
- `MCPServer.dproj` / `MCPServer.lpi` - Add units to project

### Dependencies

- `mormot.net.client` - TSimpleHttpClient for HTTP requests

### Example Implementation Skeleton

```pascal
unit MCP.Tool.SymbolSearch;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.net.client,
  MCP.Tool.Base;

type
  TMCPToolSymbolSearch = class(TMCPToolBase)
  private
    fIndexerUrl: RawUtf8;
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

constructor TMCPToolSymbolSearch.Create;
begin
  inherited Create;
  fName := 'symbol_search';
  fDescription := 'Search Delphi/Pascal codebases for symbols, types, functions, or API usage';
  fIndexerUrl := 'http://host.docker.internal:8765';
end;

function TMCPToolSymbolSearch.BuildInputSchema: Variant;
var
  Properties, QProp, NumProp, DbProp, SymProp, FwProp, DbEnum, SymEnum, FwEnum, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  TDocVariantData(Properties).InitFast;

  // q - required
  TDocVariantData(QProp).InitFast;
  TDocVariantData(QProp).S['type'] := 'string';
  TDocVariantData(QProp).S['description'] := 'Search query (symbol name, type, or keyword)';
  TDocVariantData(Properties).AddValue('q', QProp);

  // num_results - optional
  TDocVariantData(NumProp).InitFast;
  TDocVariantData(NumProp).S['type'] := 'integer';
  TDocVariantData(NumProp).S['description'] := 'Number of results to return';
  TDocVariantData(NumProp).I['default'] := 10;
  TDocVariantData(Properties).AddValue('num_results', NumProp);

  // database - optional enum
  TDocVariantData(DbProp).InitFast;
  TDocVariantData(DbProp).S['type'] := 'string';
  TDocVariantData(DbProp).S['description'] := 'Specific database to search';
  TDocVariantData(DbEnum).InitArray([], JSON_FAST);
  TDocVariantData(DbEnum).AddItem('DevEx.db');
  TDocVariantData(DbEnum).AddItem('Ni6.db');
  TDocVariantData(DbEnum).AddItem('DFX.db');
  TDocVariantData(DbEnum).AddItem('UniDAC.db');
  TDocVariantData(DbEnum).AddItem('mad.db');
  TDocVariantData(DbEnum).AddItem('delphi12.db');
  TDocVariantData(DbEnum).AddItem('delphi13.db');
  TDocVariantData(DbProp).AddValue('enum', DbEnum);
  TDocVariantData(Properties).AddValue('database', DbProp);

  // symbol - optional enum
  TDocVariantData(SymProp).InitFast;
  TDocVariantData(SymProp).S['type'] := 'string';
  TDocVariantData(SymProp).S['description'] := 'Filter by symbol type';
  TDocVariantData(SymEnum).InitArray([], JSON_FAST);
  TDocVariantData(SymEnum).AddItem('class');
  TDocVariantData(SymEnum).AddItem('function');
  TDocVariantData(SymEnum).AddItem('type');
  TDocVariantData(SymEnum).AddItem('const');
  TDocVariantData(SymProp).AddValue('enum', SymEnum);
  TDocVariantData(Properties).AddValue('symbol', SymProp);

  // framework - optional enum
  TDocVariantData(FwProp).InitFast;
  TDocVariantData(FwProp).S['type'] := 'string';
  TDocVariantData(FwProp).S['description'] := 'Filter by framework';
  TDocVariantData(FwEnum).InitArray([], JSON_FAST);
  TDocVariantData(FwEnum).AddItem('RTL');
  TDocVariantData(FwEnum).AddItem('VCL');
  TDocVariantData(FwProp).AddValue('enum', FwEnum);
  TDocVariantData(Properties).AddValue('framework', FwProp);

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('q');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolSymbolSearch.Execute(const Arguments: Variant): Variant;
var
  ArgsDoc: PDocVariantData;
  Query, Database, Symbol, Framework: RawUtf8;
  NumResults: Integer;
  RequestBody, ResponseBody: RawUtf8;
  Client: TSimpleHttpClient;
  Request: Variant;
  StatusCode: Integer;
begin
  ArgsDoc := _Safe(Arguments);
  Query := ArgsDoc^.U['q'];
  if Query = '' then
  begin
    Result := ToolResultText('Missing required parameter: q', True);
    Exit;
  end;

  NumResults := ArgsDoc^.I['num_results'];
  if NumResults <= 0 then
    NumResults := 10;
  Database := ArgsDoc^.U['database'];
  Symbol := ArgsDoc^.U['symbol'];
  Framework := ArgsDoc^.U['framework'];

  // Build request JSON
  TDocVariantData(Request).InitFast;
  TDocVariantData(Request).U['q'] := Query;
  TDocVariantData(Request).I['num_results'] := NumResults;
  if Database <> '' then
    TDocVariantData(Request).U['database'] := Database;
  if Symbol <> '' then
    TDocVariantData(Request).U['symbol'] := Symbol;
  if Framework <> '' then
    TDocVariantData(Request).U['framework'] := Framework;
  RequestBody := TDocVariantData(Request).ToJson;

  // Make HTTP request
  Client := TSimpleHttpClient.Create;
  try
    Client.TimeOutSec := 10;
    StatusCode := Client.Request('POST', fIndexerUrl + '/search', RequestBody,
      'Content-Type: application/json', ResponseBody);
    if StatusCode = 200 then
      Result := ToolResultText(ResponseBody)
    else
      Result := ToolResultText(FormatUtf8('Indexer error: % %', [StatusCode, ResponseBody]), True);
  finally
    Client.Free;
  end;
end;

end.
```

## Configuration Considerations

- Base URL should be configurable (environment variable or settings)
- Timeout should be adjustable for slow searches
- Consider caching database list from indexer

## Use Cases

1. Resolving "Undeclared identifier" compilation errors
2. Finding where a function/type/constant is defined
3. Searching for API usage examples
4. Looking up Pascal symbols by name or concept
