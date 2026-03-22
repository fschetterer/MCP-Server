/// MCP Tools Manager
// - Manages tool registration and execution
unit MCP.Manager.Tools;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types,
  MCP.Tool.Base,
  MCP.Tool.BuildService,
  MCP.Events;

type
  /// Tools capability manager for MCP protocol
  TMCPToolsManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fLock: TRTLCriticalSection;
    fTools: array of IMCPTool;
    function FindTool(const Name: RawUtf8): IMCPTool;
  public
    constructor Create;
    destructor Destroy; override;
    /// Register a tool
    // - SuppressNotification: skip tools/list_changed event (for batch operations)
    procedure RegisterTool(const Tool: IMCPTool;
      SuppressNotification: Boolean = False); overload;
    /// Register a tool by class
    procedure RegisterTool(ToolClass: TMCPToolClass); overload;
    /// Unregister a tool by name
    // - SuppressNotification: skip tools/list_changed event (for batch operations)
    function UnregisterTool(const ToolName: RawUtf8;
      SuppressNotification: Boolean = False): Boolean;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant;
      const SessionId: RawUtf8): Variant;
    /// List all registered tools
    function ListTools: Variant;
    /// Call a specific tool
    function CallTool(const Params: Variant; const SessionId: RawUtf8): Variant;
  end;

implementation

{ TMCPToolsManager }

constructor TMCPToolsManager.Create;
begin
  inherited Create;
  InitializeCriticalSection(fLock);
  SetLength(fTools, 0);
end;

destructor TMCPToolsManager.Destroy;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fTools, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
  DeleteCriticalSection(fLock);
  inherited;
end;

procedure TMCPToolsManager.RegisterTool(const Tool: IMCPTool;
  SuppressNotification: Boolean);
var
  i: PtrInt;
begin
  EnterCriticalSection(fLock);
  try
    // Check if already registered
    for i := 0 to High(fTools) do
      if IdemPropNameU(fTools[i].GetName, Tool.GetName) then
        Exit;

    // Add to list
    SetLength(fTools, Length(fTools) + 1);
    fTools[High(fTools)] := Tool;
  finally
    LeaveCriticalSection(fLock);
  end;

  TSynLog.Add.Log(sllInfo, 'Registered tool: %', [Tool.GetName]);

  // Emit tools/list_changed notification (unless suppressed for batch operations)
  if not SuppressNotification then
    MCPEventBus.Publish(MCP_EVENT_TOOLS_LIST_CHANGED, _ObjFast([]));
end;

procedure TMCPToolsManager.RegisterTool(ToolClass: TMCPToolClass);
var
  Tool: TMCPToolBase;
begin
  Tool := ToolClass.Create;
  RegisterTool(Tool);
end;

function TMCPToolsManager.UnregisterTool(const ToolName: RawUtf8;
  SuppressNotification: Boolean): Boolean;
var
  i, j: PtrInt;
begin
  Result := False;
  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fTools) do
      if IdemPropNameU(fTools[i].GetName, ToolName) then
      begin
        // Shift elements using interface assignment (preserves refcounts).
        // Move() does raw byte copy which corrupts interface refcounts.
        for j := i to High(fTools) - 1 do
          fTools[j] := fTools[j + 1];
        fTools[High(fTools)] := nil;
        SetLength(fTools, Length(fTools) - 1);
        Result := True;
        Break;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;

  if Result then
  begin
    TSynLog.Add.Log(sllInfo, 'Unregistered tool: %', [ToolName]);

    // Emit tools/list_changed notification (unless suppressed for batch operations)
    if not SuppressNotification then
      MCPEventBus.Publish(MCP_EVENT_TOOLS_LIST_CHANGED, _ObjFast([]));
  end;
end;

function TMCPToolsManager.FindTool(const Name: RawUtf8): IMCPTool;
var
  i: PtrInt;
begin
  Result := nil;
  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fTools) do
      if IdemPropNameU(fTools[i].GetName, Name) then
      begin
        Result := fTools[i];
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPToolsManager.GetCapabilityName: RawUtf8;
begin
  Result := 'tools';
end;

function TMCPToolsManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'tools/list') or
            IdemPropNameU(Method, 'tools/call');
end;

function TMCPToolsManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant; const SessionId: RawUtf8): Variant;
begin
  if IdemPropNameU(Method, 'tools/list') then
    Result := ListTools
  else if IdemPropNameU(Method, 'tools/call') then
    Result := CallTool(Params, SessionId)
  else
    raise Exception.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPToolsManager.ListTools: Variant;
var
  Tools, ToolInfo: Variant;
  i: PtrInt;
  ToolName: RawUtf8;
  IncludeTool: Boolean;
begin
  TSynLog.Add.Log(sllInfo, 'MCP tools/list called');

  TDocVariantData(Result).InitFast;
  TDocVariantData(Tools).InitArray([], JSON_FAST);

  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fTools) do
    begin
      ToolName := fTools[i].GetName;
      IncludeTool := True;

      // Filter based on tool enable/disable settings
      // Check for indexer tools (delphi_index, delphi_lookup)
      if PosEx('index', ToolName) > 0 then
        IncludeTool := IsIndexerEnabled
      // Check for build tools (delphi_build, windows_exec, windows_dir, windows_exists)
      else if (PosEx('build', ToolName) > 0) or (PosEx('exec', ToolName) > 0) or
              (PosEx('dir', ToolName) > 0) or (PosEx('exists', ToolName) > 0) then
        IncludeTool := IsBuildToolsEnabled
      // Check for LSP tools (delphi_hover, delphi_definition, delphi_references, delphi_document_symbols)
      else if (PosEx('hover', ToolName) > 0) or (PosEx('definition', ToolName) > 0) or
              (PosEx('references', ToolName) > 0) or (PosEx('document_symbols', ToolName) > 0) then
        IncludeTool := IsLspEnabled;

      if IncludeTool then
      begin
        TDocVariantData(ToolInfo).InitFast;
        TDocVariantData(ToolInfo).U['name'] := ToolName;
        TDocVariantData(ToolInfo).U['description'] := fTools[i].GetDescription;
        TDocVariantData(ToolInfo).AddValue('inputSchema', fTools[i].GetInputSchema);
        TDocVariantData(Tools).AddItem(ToolInfo);
      end;
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  TDocVariantData(Result).AddValue('tools', Tools);
end;

function TMCPToolsManager.CallTool(const Params: Variant;
  const SessionId: RawUtf8): Variant;
var
  ParamsDoc: PDocVariantData;
  ToolName: RawUtf8;
  Tool: IMCPTool;
  Arguments: Variant;
begin
  // Safe access to params
  ParamsDoc := _Safe(Params);

  // Extract tool name
  ToolName := ParamsDoc^.U['name'];
  if ToolName = '' then
    raise Exception.Create('[name] property not found');

  TSynLog.Add.Log(sllInfo, 'MCP tools/call: %', [ToolName]);

  // Find tool
  Tool := FindTool(ToolName);
  if Tool = nil then
    raise Exception.CreateFmt('Tool not found: %s', [ToolName]);

  // Extract arguments
  Arguments := ParamsDoc^.Value['arguments'];

  // Execute tool
  try
    Result := Tool.Execute(Arguments, SessionId);
  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Tool % error: %', [ToolName, E.Message]);
      Result := ToolResultText(StringToUtf8(E.Message), True);
    end;
  end;
end;

end.
