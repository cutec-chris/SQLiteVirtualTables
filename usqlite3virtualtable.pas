unit usqlite3virtualTable;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, uSqlite3Helper, sqlite3dyn, LCLProc;

type

  { TSQLiteVirtualTableCursor }

  TSQLiteVirtualTableCursor = class(TObject)
  private
    FTab: TSQLite3VTab;
  public
    constructor Create(vTab : TSQLite3VTab);virtual;
    function Search(Prepared : TSQLVirtualTablePrepared) : Boolean;virtual;abstract;
    function Column(Index : Integer;var Res : TSQLVar) : Boolean;virtual;abstract;
    function Next : Boolean;virtual;abstract;
    function Eof : Boolean;virtual;abstract;
  end;

  TSQLiteVirtualTableCursorClass = class of TSQLiteVirtualTableCursor;

  { TSQLiteVirtualTable }

  TSQLiteVirtualTable = class(TObject)
  private
    fModule : TSQLite3Module;
  protected
    function GetName : string;virtual;abstract;
  public
    function Prepare(Prepared : TSQLVirtualTablePrepared) : Boolean;virtual;abstract;
    function GenerateStructure : string;virtual;abstract;
    function CursorClass : TSQLiteVirtualTableCursorClass;virtual;abstract;
    function RegisterToSQLite(db : Pointer) : Boolean;
  end;

implementation

var
  fModule: TSQLite3Module;

{ TFSCursor }

constructor TSQLiteVirtualTableCursor.Create(vTab: TSQLite3VTab);
begin
  FTab := vTab;
end;

function vt_Create(DB: TSQLite3DB; pAux: Pointer; argc: Integer;
  const argv: PPUTF8CharArray; var ppVTab: PSQLite3VTab; var pzErr: PUTF8Char
  ): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Table: TSQLiteVirtualTable absolute pAux;
  aStruct: String;
begin
  Result := SQLITE_ERROR;
  ppVTab := sqlite3_malloc(sizeof(TSQLite3VTab));
  if ppVTab=nil then exit;
  Fillchar(ppVTab^,sizeof(ppVTab^),0);
  aStruct := Table.GenerateStructure;
  result := declare_vtab(DB,PChar(aStruct));
  ppVTab^.pInstance := Table;
end;

function vt_BestIndex(var pVTab: TSQLite3VTab; var pInfo: TSQLite3IndexInfo
  ): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Prepared: PSQLVirtualTablePrepared;
  i: Integer;
  n: Integer;
  Table: TSQLiteVirtualTable;
const COST: array[TSQLVirtualTablePreparedCost] of double = (1E10,1E8,10,1);
begin
  Result := SQLITE_ERROR;
  Table := TSQLiteVirtualTable(pvTab.pInstance);
  if (cardinal(pInfo.nOrderBy)>MAX_SQLFIELDS) or
     (cardinal(pInfo.nConstraint)>MAX_SQLFIELDS) then begin
    debugln('nOrderBy=% nConstraint=%',[pInfo.nOrderBy,pInfo.nConstraint]);
    exit; // avoid buffer overflow
  end;
  Prepared := sqlite3_malloc(sizeof(TSQLVirtualTablePrepared));
  try
    // encode the incoming parameters into Prepared^ record
    Prepared^.WhereCount := pInfo.nConstraint;
    Prepared^.EstimatedCost := costFullScan;
    for i := 0 to pInfo.nConstraint-1 do
      with Prepared^.Where[i], pInfo.aConstraint^[i] do begin
        OmitCheck := False;
        Value.VType := ftUnknown;
        if usable then begin
          Column := iColumn;
          case op of
            SQLITE_INDEX_CONSTRAINT_EQ:    Operation := soEqualTo;
            SQLITE_INDEX_CONSTRAINT_GT:    Operation := soGreaterThan;
            SQLITE_INDEX_CONSTRAINT_LE:    Operation := soLessThanOrEqualTo;
            SQLITE_INDEX_CONSTRAINT_LT:    Operation := soLessThan;
            SQLITE_INDEX_CONSTRAINT_GE:    Operation := soGreaterThanOrEqualTo;
            SQLITE_INDEX_CONSTRAINT_MATCH: Operation := soBeginWith;
            else Column := VIRTUAL_TABLE_IGNORE_COLUMN; // unhandled operator
          end;
        end else
          Column := VIRTUAL_TABLE_IGNORE_COLUMN;
      end;
    Prepared^.OmitOrderBy := false;
    if pInfo.nOrderBy>0 then begin
      assert(sizeof(TSQLVirtualTablePreparedOrderBy)=sizeof(TSQLite3IndexOrderBy));
      Prepared^.OrderByCount := pInfo.nOrderBy;
      Move(pInfo.aOrderBy^[0],Prepared^.OrderBy[0],pInfo.nOrderBy*sizeof(Prepared^.OrderBy[0]));
    end else
      Prepared^.OrderByCount := 0;
    // perform the index query
    if not Table.Prepare(Prepared^) then
      exit;
    // update pInfo and store Prepared into pInfo.idxStr for vt_Filter()
    n := 0;
    for i := 0 to pInfo.nConstraint-1 do
    if Prepared^.Where[i].Value.VType<>ftUnknown then begin
      if i<>n then // expression needed for Search() method to be moved at [n]
        Move(Prepared^.Where[i],Prepared^.Where[n],sizeof(Prepared^.Where[i]));
      inc(n);
      pInfo.aConstraintUsage^[i].argvIndex := n;
      pInfo.aConstraintUsage^[i].omit := Prepared^.Where[i].OmitCheck;
    end;
    Prepared^.WhereCount := n; // will match argc in vt_Filter()
    if Prepared^.OmitOrderBy then
      pInfo.orderByConsumed := 1 else
      pInfo.orderByConsumed := 0;
    pInfo.estimatedCost := COST[Prepared^.EstimatedCost];
    pInfo.idxStr := pointer(Prepared);
    pInfo.needToFreeIdxStr := 1; // will do sqlite3.free(idxStr) when needed
    result := SQLITE_OK;
    {$ifdef SQLVIRTUALLOGS}
    if Table.Static is TSQLRestStorageExternal then
      TSQLRestStorageExternal(Table.Static).ComputeSQL(prepared^);
    SQLite3Log.Add.Log(sllDebug,'vt_BestIndex(%) plan=% -> cost=% rows=%',
      [sqlite3.VersionNumber,ord(Prepared^.EstimatedCost),pInfo.estimatedCost,pInfo.estimatedRows]);
    {$endif}
  finally
    if result<>SQLITE_OK then
      sqlite3_free(Prepared); // avoid memory leak on error
  end;
end;

function vt_Disconnect(pVTab: PSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  sqlite3_free(pVTab);
  result := SQLITE_OK;
end;

function vt_Destroy(pVTab: PSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  result := SQLITE_OK;
  vt_Disconnect(pVTab); // release memory
end;

function vt_Open(var pVTab: TSQLite3VTab; var ppCursor: PSQLite3VTabCursor
  ): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var
  Table: TSQLiteVirtualTable;
begin
  Table := TSQLiteVirtualTable(pvTab.pInstance);
  ppCursor := sqlite3_malloc(sizeof(TSQLite3VTabCursor));
  if ppCursor=nil then begin
    result := SQLITE_NOMEM;
    exit;
  end;
  ppCursor^.pInstance := Table.CursorClass.Create(pVTab);
  Result := SQLITE_OK;
end;

function vt_Close(pVtabCursor: PSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  TSQLiteVirtualTableCursor(pVtabCursor^.pInstance).Free;
  sqlite3_free(pVtabCursor);
  result := SQLITE_OK;
end;

function vt_Filter(var pVtabCursor: TSQLite3VTabCursor; idxNum: Integer;
  const idxStr: PAnsiChar; argc: Integer; var argv: TSQLite3ValueArray
  ): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Prepared: PSQLVirtualTablePrepared absolute idxStr; // idxNum is not used
    i: integer;
begin
  result := SQLITE_ERROR;
  if Prepared^.WhereCount<>argc then begin
    debugln('vt_Filter WhereCount=% argc=%',[Prepared^.WhereCount,argc]);
    exit; // invalid prepared array (should not happen)
  end;
  for i := 0 to argc-1 do
    SQlite3ValueToSQLVar(argv[i],Prepared^.Where[i].Value);
  if TSQLiteVirtualTableCursor(pVtabCursor.pInstance).Search(Prepared^) then
    result := SQLITE_OK else
  debugln('vt_Filter Search()',[]);
end;

function vt_Next(var pVtabCursor: TSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  if TSQLiteVirtualTableCursor(pVtabCursor.pInstance).Next then
    result := SQLITE_OK else
    result := SQLITE_ERROR;
end;

function vt_Eof(var pVtabCursor: TSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  if not TSQLiteVirtualTableCursor(pVtabCursor.pInstance).Eof then
    result := 0 else
    result := 1; // reached actual EOF
end;

function vt_Column(var pVtabCursor: TSQLite3VTabCursor;
  sContext: TSQLite3FunctionContext; N: Integer): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Res: TSQLVar;
begin
  Res.VType := ftUnknown;
  if (N>=0) and TSQLiteVirtualTableCursor(pVtabCursor.pInstance).Column(N,Res) and
     SQLVarToSQlite3Context(Res,sContext) then
    result := SQLITE_OK else begin
    debugln('vt_Column(%) Res=%',[N,ord(Res.VType)]);
    result := SQLITE_ERROR;
  end;
end;

procedure vt_ModuleDestroy(aMod : Pointer); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
end;

function vt_Rowid(var pVtabCursor: TSQLite3VTabCursor; var pRowid: Int64
  ): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Res: TSQLVar;
begin
  result := SQLITE_ERROR;
  with TSQLiteVirtualTableCursor(pVtabCursor.pInstance) do
  if Column(-1,Res) then begin
    case Res.VType of
    ftInt64:    pRowID := Res.VInt64;
    ftDouble:   pRowID := trunc(Res.VDouble);
    ftCurrency: pRowID := trunc(Res.VCurrency);
    ftUTF8:     pRowID := GetInt64(Res.VText);
    else begin
      debugln('vt_Rowid Res=%',[ord(Res.VType)]);
      exit;
    end;
    end;
    result := SQLITE_OK;
  end else
    debugln('vt_Rowid Column',[]);
end;

{ TSQLiteVirtualTable }

function TSQLiteVirtualTable.RegisterToSQLite(db: Pointer): Boolean;
begin
  FillChar(fModule,sizeof(fModule),0);
  fModule.iVersion := 1;
  fModule.xCreate := @vt_Create;
  fModule.xConnect := @vt_Create;
  fModule.xBestIndex := @vt_BestIndex;
  fModule.xDisconnect := @vt_Disconnect;
  fModule.xDestroy := @vt_Destroy;
  fModule.xOpen := @vt_Open;
  fModule.xClose := @vt_Close;
  fModule.xFilter := @vt_Filter;
  fModule.xNext := @vt_Next;
  fModule.xEof := @vt_Eof;
  fModule.xColumn := @vt_Column;
  fModule.xRowid := @vt_Rowid;
  {
  if vtWrite in Features then begin
    fModule.xUpdate := vt_Update;
    if vtTransaction in Features then begin
      fModule.xBegin := vt_Begin;
      fModule.xSync := vt_Sync;
      fModule.xCommit := vt_Commit;
      fModule.xRollback := vt_RollBack;
    end;
    if vtSavePoint in Features then begin
      fModule.iVersion := 2;
      fModule.xSavePoint := vt_SavePoint;
      fModule.xRelease := vt_Release;
      fModule.xRollBackTo := vt_RollBackTo;
    end;
    fModule.xRename := vt_Rename;
  end;
  }
  Result := LoadSQLiteFuncs;
  Result := Result and (create_module_v2(TSQLite3DB(db),PChar(GetName),fModule,Self,@vt_ModuleDestroy) = sqlite_ok);
end;

end.

