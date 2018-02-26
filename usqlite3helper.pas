// - this unit is a partiall part of the freeware Synopse mORMot framework,
// licensed under a MPL/GPL/LGPL tri-license; version 1.18
unit uSqlite3Helper;

{$mode objfpc}{$H+}
{$ifdef BSD}
  {$linklib c}
  {$linklib pthread}
{$endif}

{$packrecords C}

interface

uses
  Classes, SysUtils, dynlibs, sqlite3dyn, ctypes;

const
  /// maximum number of fields in a database Table
  MAX_SQLFIELDS = 256;
  /// maximum number of Tables in a Database Model
  // - this constant is used internaly to optimize memory usage in the
  // generated asm code
  // - you should not change it to a value lower than expected in an existing
  // database (e.g. as expected by TSQLAccessRights or such)
  MAX_SQLTABLES = 256;

  SQLITE_INDEX_CONSTRAINT_LIKE     = 65;//  /* 3.10.0 and later */
  SQLITE_INDEX_CONSTRAINT_GLOB     = 66;//  /* 3.10.0 and later */
  SQLITE_INDEX_CONSTRAINT_REGEXP   = 67;//  /* 3.10.0 and later */
  SQLITE_INDEX_CONSTRAINT_NE       = 68;//  /* 3.21.0 and later */
  SQLITE_INDEX_CONSTRAINT_ISNOT    = 69;//  /* 3.21.0 and later */
  SQLITE_INDEX_CONSTRAINT_ISNOTNULL= 70;//  /* 3.21.0 and later */
  SQLITE_INDEX_CONSTRAINT_ISNULL   = 71;//  /* 3.21.0 and later */
  SQLITE_INDEX_CONSTRAINT_IS       = 72;//  /* 3.21.0 and later */
  SQLITE_INDEX_SCAN_UNIQUE         =  1;//  /* Scan visits at most 1 row */



type
  TSQLite3DB = type PtrUInt;
  PSQLite3Module = ^TSQLite3Module;
  PSQLite3VTab = ^TSQLite3VTab;
  PUTF8Char = type PAnsiChar;
  PPUTF8Char = ^PUTF8Char;
  /// a Row/Col array of PUTF8Char, for containing sqlite3_get_table() result
  TPUtf8CharArray = array[0..MaxInt div SizeOf(PUTF8Char)-1] of PUTF8Char;
  PPUtf8CharArray = ^TPUtf8CharArray;
  PSQLite3VTabCursor = ^TSQLite3VTabCursor;

  /// handled field/parameter/column types for abstract database access
  // - this will map JSON-compatible low-level database-level access types, not
  // high-level Delphi types as TSQLFieldType defined in mORMot.pas
  // - it does not map either all potential types as defined in DB.pas (which
  // are there for compatibility with old RDBMS, and are not abstract enough)
  // - those types can be mapped to standard SQLite3 generic types, i.e.
  // NULL, INTEGER, REAL, TEXT, BLOB (with the addition of a ftCurrency and
  // ftDate type, for better support of most DB engines)
  // see @http://www.sqlite.org/datatype3.html
  // - the only string type handled here uses UTF-8 encoding (implemented
  // using our RawUTF8 type), for cross-Delphi true Unicode process
  TSQLDBFieldType =
    (ftUnknown, ftNull, ftInt64, ftDouble, ftCurrency, ftDate, ftUTF8, ftBlob);

  /// set of field/parameter/column types for abstract database access
  TSQLDBFieldTypes = set of TSQLDBFieldType;

  /// array of field/parameter/column types for abstract database access
  TSQLDBFieldTypeDynArray = array of TSQLDBFieldType;

  /// array of field/parameter/column types for abstract database access
  // - this array as a fixed size, ready to handle up to MAX_SQLFIELDS items
  TSQLDBFieldTypeArray = array[0..MAX_SQLFIELDS-1] of TSQLDBFieldType;

  /// how TSQLVar may be processed
  // - by default, ftDate will use seconds resolution unless svoDateWithMS is set
  TSQLVarOption = (svoDateWithMS);

  /// defines how TSQLVar may be processed
  TSQLVarOptions = set of TSQLVarOption;

  /// memory structure used for database values by reference storage
  // - used mainly by SynDB, mORMot, mORMotDB and mORMotSQLite3 units
  // - defines only TSQLDBFieldType data types (similar to those handled by
  // SQLite3, with the addition of ftCurrency and ftDate)
  // - cleaner/lighter dedicated type than TValue or variant/TVarData, strong
  // enough to be marshalled as JSON content
  // - variable-length data (e.g. UTF-8 text or binary BLOB) are never stored
  // within this record, but VText/VBlob will point to an external (temporary)
  // memory buffer
  // - date/time is stored as ISO-8601 text (with milliseconds if svoDateWithMS
  // option is set and the database supports it), and currency as double or BCD
  // in most databases
  TSQLVar = record
    /// how this value should be processed
    Options: TSQLVarOptions;
    /// the type of the value stored
    case VType: TSQLDBFieldType of
    ftInt64: (
      VInt64: Int64);
    ftDouble: (
      VDouble: double);
    ftDate: (
      VDateTime: TDateTime);
    ftCurrency: (
      VCurrency: Currency);
    ftUTF8: (
      VText: PUTF8Char);
    ftBlob: (
      VBlob: pointer;
      VBlobLen: Integer)
  end;
  /// SQL Query comparison operators
  // - used e.g. by CompareOperator() functions in SynTable.pas or vt_BestIndex()
  // in mORMotSQLite3.pas
  TCompareOperator = (
     soEqualTo,
     soNotEqualTo,
     soLessThan,
     soLessThanOrEqualTo,
     soGreaterThan,
     soGreaterThanOrEqualTo,
     soBeginWith,
     soContains,
     soSoundsLikeEnglish,
     soSoundsLikeFrench,
     soSoundsLikeSpanish,
     soLike,
     soGlob);
  /// a WHERE constraint as set by the TSQLVirtualTable.Prepare() method
  TSQLVirtualTablePreparedConstraint = packed record
    /// Column on left-hand side of constraint
    // - The first column of the virtual table is column 0
    // - The RowID of the virtual table is column -1
    // - Hidden columns are counted when determining the column index
    // - if this field contains VIRTUAL_TABLE_IGNORE_COLUMN (-2), TSQLVirtualTable.
    // Prepare() should ignore this entry
    Column: integer;
    /// The associated expression
    // - TSQLVirtualTable.Prepare() must set Value.VType to not svtUnknown
    // (e.g. to svtNull), if an expression is expected at vt_BestIndex() call
    // - TSQLVirtualTableCursor.Search() will receive an expression value,
    // to be retrieved e.g. via sqlite3_value_*() functions
    Value: TSQLVar;
    /// Constraint operator
    // - MATCH keyword is parsed into soBeginWith, and should be handled as
    // soBeginWith, soContains or soSoundsLike* according to the effective
    // expression text value ('text*', '%text'...)
    Operation: TCompareOperator;
    /// If true, the constraint is assumed to be fully handled
    // by the virtual table and is not checked again by SQLite
    // - By default (OmitCheck=false), the SQLite core double checks all
    // constraints on each row of the virtual table that it receives
    // - TSQLVirtualTable.Prepare() can set this property to true
    OmitCheck: boolean;
  end;
  PSQLVirtualTablePreparedConstraint = ^TSQLVirtualTablePreparedConstraint;

  /// an ORDER BY clause as set by the TSQLVirtualTable.Prepare() method
  // - warning: this structure should match exactly TSQLite3IndexOrderBy as
  // defined in SynSQLite3
  TSQLVirtualTablePreparedOrderBy = record
    /// Column number
    // - The first column of the virtual table is column 0
    // - The RowID of the virtual table is column -1
    // - Hidden columns are counted when determining the column index.
    Column: Integer;
    /// True for DESCending order, false for ASCending order.
    Desc: boolean;
  end;

  /// abstract planning execution of a query, as set by TSQLVirtualTable.Prepare
  TSQLVirtualTablePreparedCost = (
    costFullScan, costScanWhere, costSecondaryIndex, costPrimaryIndex);

  /// the WHERE and ORDER BY statements as set by TSQLVirtualTable.Prepare
  // - Where[] and OrderBy[] are fixed sized arrays, for fast and easy code

  { TSQLVirtualTablePrepared }

  TSQLVirtualTablePrepared = {$ifndef ISDELPHI2010}object{$else}record{$endif}
  public
    /// number of WHERE statement parameters in Where[] array
    WhereCount: integer;
    /// numver of ORDER BY statement parameters in OrderBy[]
    OrderByCount: integer;
    /// if true, the ORDER BY statement is assumed to be fully handled
    // by the virtual table and is not checked again by SQLite
    // - By default (OmitOrderBy=false), the SQLite core sort all rows of the
    // virtual table that it receives according in order
    OmitOrderBy: boolean;
    ///  Estimated cost of using this prepared index
    // - SQLite uses this value to make a choice between several calls to
    // the TSQLVirtualTable.Prepare() method with several expressions
    EstimatedCost: TSQLVirtualTablePreparedCost;
    ///  Estimated number of rows of using this prepared index
    // - does make sense only if EstimatedCost=costFullScan
    // - SQLite uses this value to make a choice between several calls to
    // the TSQLVirtualTable.Prepare() method with several expressions
    // - is used only starting with SQLite 3.8.2
    EstimatedRows: Int64;
    /// WHERE statement parameters, in TSQLVirtualTableCursor.Search() order
    Where: array[0..MAX_SQLFIELDS-1] of TSQLVirtualTablePreparedConstraint;
    /// ORDER BY statement parameters
    OrderBy: array[0..MAX_SQLFIELDS-1] of TSQLVirtualTablePreparedOrderBy;
    /// returns TRUE if there is only one ID=? statement in this search
    function IsWhereIDEquals(CalledFromPrepare: Boolean): boolean;
       {$ifdef HASINLINE}inline;{$endif}
    /// returns TRUE if there is only one FieldName=? statement in this search
    function IsWhereOneFieldEquals: boolean;
       {$ifdef HASINLINE}inline;{$endif}
  end;

  PSQLVirtualTablePrepared = ^TSQLVirtualTablePrepared;

//  TSQLVirtualTableCursor = class;

  /// class-reference type (metaclass) of a cursor on an abstract Virtual Table
//  TSQLVirtualTableCursorClass = class of TSQLVirtualTableCursor;

  /// the possible features of a Virtual Table
  // - vtWrite is to be set if the table is not Read/Only
  // - vtTransaction if handles vttBegin, vttSync, vttCommit, vttRollBack
  // - vtSavePoint if handles vttSavePoint, vttRelease, vttRollBackTo
  // - vtWhereIDPrepared if the ID=? WHERE statement will be handled in
  // TSQLVirtualTableCursor.Search()
  TSQLVirtualTableFeature = (vtWrite, vtTransaction, vtSavePoint,
    vtWhereIDPrepared);


  TSQLite3IndexConstraint = record
    /// Column on left-hand side of constraint
    // - The first column of the virtual table is column 0
    // - The ROWID of the virtual table is column -1
    // - Hidden columns are counted when determining the column index.
    iColumn: integer;
    /// Constraint operator
    // - OP is =, <, <=, >, or >= using one of the SQLITE_INDEX_CONSTRAINT_* values
    op: byte;
    /// True if this constraint is usable
    // - The aConstraint[] array contains information about all constraints that
    // apply to the virtual table. But some of the constraints might not be usable
    // because of the way tables are ordered in a join. The xBestIndex method
    // must therefore only consider constraints that have a usable flag which is
    // true, and just ignore contraints with usable set to false
    usable: bytebool;
    /// Used internally - xBestIndex() should ignore this field
    iTermOffset: integer;
  end;

  /// internal store a SQLite3 Function Context Object
  // - The context in which an SQL function executes is stored in an sqlite3.context
  // object, which is mapped to this TSQLite3FunctionContext type
  // - A pointer to an sqlite3.context object is always first parameter to
  // application-defined SQL functions, i.e. a TSQLFunctionFunc prototype
  TSQLite3FunctionContext = type Pointer;

  TSQLite3Value = type Pointer;
  /// internaly store any array of  SQLite3 value
  TSQLite3ValueArray = array[0..63] of TSQLite3Value;

  /// internaly store a SQLite3 Backup process handle
  TSQLite3Backup = type PtrUInt;

  /// type for a custom destructor for the text or BLOB content
  // - set to @sqlite3InternalFree if a Value must be released via Freemem()
  // - set to @sqlite3InternalFreeObject if a Value must be released via
  // TObject(p).Free
  TSQLDestroyPtr = procedure(p: pointer); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// SQLite3 collation (i.e. sort and comparaison) function prototype
  // - this function MUST use s1Len and s2Len parameters during the comparaison:
  // s1 and s2 are not zero-terminated
  // - used by sqlite3.create_collation low-level function
  TSQLCollateFunc = function(CollateParam: pointer; s1Len: integer; s1: pointer;
    s2Len: integer; s2: pointer) : integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// SQLite3 user function or aggregate callback prototype
  // - argc is the number of supplied parameters, which are available in argv[]
  // (you can call ErrorWrongNumberOfArgs(Context) in case of unexpected number)
  // - use sqlite3.value_*(argv[*]) functions to retrieve a parameter value
  // - then set the result using sqlite3.result_*(Context,*) functions
  TSQLFunctionFunc = procedure(Context: TSQLite3FunctionContext;
    argc: integer; var argv: TSQLite3ValueArray); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// SQLite3 user final aggregate callback prototype
  TSQLFunctionFinal = procedure(Context: TSQLite3FunctionContext); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// SQLite3 callback prototype to handle SQLITE_BUSY errors
  // - The first argument to the busy handler is a copy of the user pointer which
  // is the third argument to sqlite3.busy_handler().
  // - The second argument to the busy handler callback is the number of times
  // that the busy handler has been invoked for this locking event.
  // - If the busy callback returns 0, then no additional attempts are made to
  // access the database and SQLITE_BUSY or SQLITE_IOERR_BLOCKED is returned.
  // - If the callback returns non-zero, then another attempt is made to open
  // the database for reading and the cycle repeats.
  TSQLBusyHandler = function(user: pointer; count: integer): integer;
     {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  PFTSMatchInfo = ^TFTSMatchInfo;
  /// map the matchinfo function returned BLOB value
  // - i.e. the default 'pcx' layout, for both FTS3 and FTS4
  // - see http://www.sqlite.org/fts3.html#matchinfo
  // - used for the FTS3/FTS4 ranking of results by TSQLRest.FTSMatch method
  // and the internal RANK() function as proposed in
  // http://www.sqlite.org/fts3.html#appendix_a
  TFTSMatchInfo = packed record
    nPhrase: integer;
    nCol: integer;
    hits: array[1..9] of record
      this_row: integer;
      all_rows: integer;
      docs_with_hits: integer;
    end;
end;
  PSQLite3IndexConstraintArray = ^TSQLite3IndexConstraintArray;
  TSQLite3IndexConstraintArray = array[0..MaxInt div SizeOf(TSQLite3IndexConstraint)-1] of TSQLite3IndexConstraint;

  /// ORDER BY clause, one item per column
  TSQLite3IndexOrderBy = record
    /// Column number
    // - The first column of the virtual table is column 0
    // - The ROWID of the virtual table is column -1
    // - Hidden columns are counted when determining the column index.
    iColumn: integer;
    /// True for DESC.  False for ASC.
    desc: bytebool;
  end;
  PSQLite3IndexOrderByArray = ^TSQLite3IndexOrderByArray;
  TSQLite3IndexOrderByArray = array[0..MaxInt div SizeOf(TSQLite3IndexOrderBy)-1] of TSQLite3IndexOrderBy;

  /// define what information is to be passed to xFilter() for a given WHERE
  // clause constraint of the form "column OP expr"
  TSQLite3IndexConstraintUsage = record
    /// If argvIndex>0 then the right-hand side of the corresponding
    // aConstraint[] is evaluated and becomes the argvIndex-th entry in argv
    // - Exactly one entry should be set to 1, another to 2, another to 3, and
    // so forth up to as many or as few as the xBestIndex() method wants.
    // - The EXPR of the corresponding constraints will then be passed in as
    // the argv[] parameters to xFilter()
    // - For example, if the aConstraint[3].argvIndex is set to 1, then when
    // xFilter() is called, the argv[0] passed to xFilter will have the EXPR
    // value of the aConstraint[3] constraint.
    argvIndex: Integer;
    /// If omit is true, then the constraint is assumed to be fully handled
    // by the virtual table and is not checked again by SQLite
    // - By default, the SQLite core double checks all constraints on each
    // row of the virtual table that it receives. If such a check is redundant,
    // xBestFilter() method can suppress that double-check by setting this field
    omit: bytebool;
  end;
  PSQLite3IndexConstraintUsageArray = ^TSQLite3IndexConstraintUsageArray;
  TSQLite3IndexConstraintUsageArray = array[0..MaxInt div SizeOf(TSQLite3IndexConstraintUsage) - 1] of TSQLite3IndexConstraintUsage;

  TSQLite3IndexInfo = record
    /// input: Number of entries in aConstraint array
    nConstraint: integer;
    /// input: List of WHERE clause constraints of the form "column OP expr"
    aConstraint: PSQLite3IndexConstraintArray;
    /// input: Number of terms in the aOrderBy array
    nOrderBy: integer;
    /// input: List of ORDER BY clause, one per column
    aOrderBy: PSQLite3IndexOrderByArray;
    /// output: filled by xBestIndex() method with information about what
    // parameters to pass to xFilter() method
    // - has the same number of items than the aConstraint[] array
    // - should set the aConstraintUsage[].argvIndex to have the corresponding
    // argument in xFilter() argc/argv[] expression list
    aConstraintUsage: PSQLite3IndexConstraintUsageArray;
    /// output: Number used to identify the index
    idxNum: integer;
    /// output: String, possibly obtained from sqlite3.malloc()
    // - may contain any variable-length data or class/record content, as
    // necessary
    idxStr: PAnsiChar;
    /// output: Free idxStr using sqlite3.free() if true (=1)
    needToFreeIdxStr: integer;
    /// output: True (=1) if output is already ordered
    // - i.e. if the virtual table will output rows in the order specified
    // by the ORDER BY clause
    // - if False (=0), will indicate to the SQLite core that it will need to
    // do a separate sorting pass over the data after it comes out
    // of the virtual table
    orderByConsumed: integer;
    /// output: Estimated cost of using this index
    // - Should be set to the estimated number of disk access operations
    // required to execute this query against the virtual table
    // - The SQLite core will often call xBestIndex() multiple times with
    // different constraints, obtain multiple cost estimates, then choose the
    // query plan that gives the lowest estimate
    estimatedCost: Double;
    /// output: Estimated number of rows returned  (since 3.8.2)
    // - may be set to an estimate of the number of rows returned by the
    // proposed query plan. If this value is not explicitly set, the default
    // estimate of 25 rows is used
    estimatedRows: Int64;
    /// output: Mask of SQLITE_INDEX_SCAN_* flags  (since 3.9.0)
    // - may be set to SQLITE_INDEX_SCAN_UNIQUE to indicate that the virtual
    // table will return only zero or one rows given the input constraints.
    // Additional bits of the idxFlags field might be understood in later
    // versions of SQLite
    idxFlags: Integer;
    /// input: Mask of columns used by statement   (since 3.10.0)
    // - indicates which fields of the virtual table are actually used by the
    // statement being prepared. If the lowest bit of colUsed is set, that means
    // that the first column is used. The second lowest bit corresponds to the
    // second column. And so forth. If the most significant bit of colUsed is
    // set, that means that one or more columns other than the first 63 columns
    // are used.
    // - If column usage information is needed by the xFilter method, then the
    // required bits must be encoded into either the idxNum or idxStr output fields
    colUsed: UInt64;
  end;
  /// Virtual Table Instance Object
  // - Every virtual table module implementation uses a subclass of this object
  // to describe a particular instance of the virtual table.
  // - Each subclass will be tailored to the specific needs of the module
  // implementation. The purpose of this superclass is to define certain fields
  // that are common to all module implementations. This structure therefore
  // contains a pInstance field, which will be used to store a class instance
  // handling the virtual table as a pure Delphi class: the TSQLVirtualTableModule
  // class will use it internaly
  TSQLite3VTab = record
    /// The module for this virtual table
    pModule: PSQLite3Module;
    /// no longer used
    nRef: integer;
    /// Error message from sqlite3.mprintf()
    // - Virtual tables methods can set an error message by assigning a string
    // obtained from sqlite3.mprintf() to zErrMsg.
    // - The method should take care that any prior string is freed by a call
    // to sqlite3.free() prior to assigning a new string to zErrMsg.
    // - After the error message is delivered up to the client application,
    // the string will be automatically freed by sqlite3.free() and the zErrMsg
    // field will be zeroed.
    zErrMsg: PUTF8Char;
    /// this will be used to store a Delphi class instance handling the Virtual Table
    pInstance: TObject;
  end;

  /// Virtual Table Cursor Object
  // - Every virtual table module implementation uses a subclass of the following
  // structure to describe cursors that point into the virtual table and are
  // used to loop through the virtual table.
  // - Cursors are created using the xOpen method of the module and are destroyed
  // by the xClose method. Cursors are used by the xFilter, xNext, xEof, xColumn,
  // and xRowid methods of the module.
  // - Each module implementation will define the content of a cursor structure
  // to suit its own needs.
  // - This superclass exists in order to define fields of the cursor that are
  // common to all implementationsThis structure therefore contains a pInstance
  // field, which will be used to store a class instance handling the virtual
  // table as a pure Delphi class: the TSQLVirtualTableModule class will use
  // it internaly
  TSQLite3VTabCursor = record
    /// Virtual table of this cursor
    pVtab: PSQLite3VTab;
    /// this will be used to store a Delphi class instance handling the cursor
    pInstance: TObject;
  end;

  TSQLite3Module = record
    /// defines the particular edition of the module table structure
    // - Currently, handled iVersion is 2, but in future releases of SQLite the
    // module structure definition might be extended with additional methods and
    // in that case the iVersion value will be increased
    iVersion: integer;
    /// called to create a new instance of a virtual table in response to a
    // CREATE VIRTUAL TABLE statement
    // - The job of this method is to construct the new virtual table object (an
    // PSQLite3VTab object) and return a pointer to it in ppVTab
    // - The DB parameter is a pointer to the SQLite database connection that is
    // executing the CREATE VIRTUAL TABLE statement
    // - The pAux argument is the copy of the client data pointer that was the
    // fourth argument to the sqlite3.create_module_v2() call that registered
    // the virtual table module
    // - The argv parameter is an array of argc pointers to null terminated strings
    // - The first string, argv[0], is the name of the module being invoked. The
    // module name is the name provided as the second argument to sqlite3.create_module()
    // and as the argument to the USING clause of the CREATE VIRTUAL TABLE
    // statement that is running.
    // - The second, argv[1], is the name of the database in which the new virtual
    // table is being created. The database name is "main" for the primary
    // database, or "temp" for TEMP database, or the name given at the end of
    // the ATTACH statement for attached databases.
    // - The third element of the array, argv[2], is the name of the new virtual
    // table, as specified following the TABLE keyword in the CREATE VIRTUAL
    // TABLE statement
    // - If present, the fourth and subsequent strings in the argv[] array report
    // the arguments to the module name in the CREATE VIRTUAL TABLE statement
    // - As part of the task of creating a new PSQLite3VTab structure, this method
    // must invoke sqlite3.declare_vtab() to tell the SQLite core about the
    // columns and datatypes in the virtual table
    xCreate: function(DB: TSQLite3DB; pAux: Pointer;
      argc: Integer; const argv: PPUTF8CharArray;
      var ppVTab: PSQLite3VTab; var pzErr: PUTF8Char): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// xConnect is called to establish a new connection to an existing virtual table,
    // whereas xCreate is called to create a new virtual table from scratch
    // - It has the same parameters and constructs a new PSQLite3VTab structure
    // - xCreate and xConnect methods are only different when the virtual table
    // has some kind of backing store that must be initialized the first time the
    // virtual table is created. The xCreate method creates and initializes the
    // backing store. The xConnect method just connects to an existing backing store.
    xConnect: function(DB: TSQLite3DB; pAux: Pointer;
      argc: Integer; const argv: PPUTF8CharArray;
      var ppVTab: PSQLite3VTab; var pzErr: PUTF8Char): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Used to determine the best way to access the virtual table
    // - The pInfo parameter is used for input and output parameters
    // - The SQLite core calls the xBestIndex() method when it is compiling a query
    // that involves a virtual table. In other words, SQLite calls this method when
    // it is running sqlite3.prepare() or the equivalent.
    // - By calling this method, the SQLite core is saying to the virtual table
    // that it needs to access some subset of the rows in the virtual table and
    // it wants to know the most efficient way to do that access. The xBestIndex
    // method replies with information that the SQLite core can then use to
    // conduct an efficient search of the virtual table, via the xFilter() method.
    // - While compiling a single SQL query, the SQLite core might call xBestIndex
    // multiple times with different settings in pInfo. The SQLite
    // core will then select the combination that appears to give the best performance.
    // - The information in the pInfo structure is ephemeral and may be overwritten
    // or deallocated as soon as the xBestIndex() method returns. If the
    // xBestIndex() method needs to remember any part of the pInfo structure,
    // it should make a copy. Care must be taken to store the copy in a place
    // where it will be deallocated, such as in the idxStr field with
    // needToFreeIdxStr set to 1.
    xBestIndex: function(var pVTab: TSQLite3VTab; var pInfo: TSQLite3IndexInfo): Integer;
      {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Releases a connection to a virtual table
    // - Only the pVTab object is destroyed. The virtual table is not destroyed and
    // any backing store associated with the virtual table persists. This method
    // undoes the work of xConnect.
    xDisconnect: function(pVTab: PSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Releases a connection to a virtual table, just like the xDisconnect method,
    // and it also destroys the underlying table implementation.
    // - This method undoes the work of xCreate
    // - The xDisconnect method is called whenever a database connection that uses
    // a virtual table is closed. The xDestroy method is only called when a
    // DROP TABLE statement is executed against the virtual table.
    xDestroy: function(pVTab: PSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Creates a new cursor used for accessing (read and/or writing) a virtual table
    // - A successful invocation of this method will allocate the memory for the
    // TPSQLite3VTabCursor (or a subclass), initialize the new object, and
    // make ppCursor point to the new object. The successful call then returns SQLITE_OK.
    // - For every successful call to this method, the SQLite core will later
    // invoke the xClose method to destroy the allocated cursor.
    // - The xOpen method need not initialize the pVtab field of the ppCursor structure.
    // The SQLite core will take care of that chore automatically.
    // - A virtual table implementation must be able to support an arbitrary number
    // of simultaneously open cursors.
    // - When initially opened, the cursor is in an undefined state. The SQLite core
    // will invoke the xFilter method on the cursor prior to any attempt to
    // position or read from the cursor.
    xOpen: function(var pVTab: TSQLite3VTab; var ppCursor: PSQLite3VTabCursor): Integer;
      {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Closes a cursor previously opened by xOpen
    // - The SQLite core will always call xClose once for each cursor opened using xOpen.
    // - This method must release all resources allocated by the corresponding xOpen call.
    // - The routine will not be called again even if it returns an error. The
    // SQLite core will not use the pVtabCursor again after it has been closed.
    xClose: function(pVtabCursor: PSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Begins a search of a virtual table
    // - The first argument is a cursor opened by xOpen.
    // - The next two arguments define a particular search index previously chosen
    // by xBestIndex(). The specific meanings of idxNum and idxStr are unimportant
    // as long as xFilter() and xBestIndex() agree on what that meaning is.
    // - The xBestIndex() function may have requested the values of certain
    // expressions using the aConstraintUsage[].argvIndex values of its pInfo
    // structure. Those values are passed to xFilter() using the argc and argv
    // parameters.
    // - If the virtual table contains one or more rows that match the search criteria,
    // then the cursor must be left point at the first row. Subsequent calls to
    // xEof must return false (zero). If there are no rows match, then the cursor
    // must be left in a state that will cause the xEof to return true (non-zero).
    // The SQLite engine will use the xColumn and xRowid methods to access that row content.
    // The xNext method will be used to advance to the next row.
    // - This method must return SQLITE_OK if successful, or an sqlite error code
    // if an error occurs.
    xFilter: function(var pVtabCursor: TSQLite3VTabCursor; idxNum: Integer; const idxStr: PAnsiChar;
      argc: Integer; var argv: TSQLite3ValueArray): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Advances a virtual table cursor to the next row of a result set initiated by xFilter
    // - If the cursor is already pointing at the last row when this routine is called,
    // then the cursor no longer points to valid data and a subsequent call to the
    // xEof method must return true (non-zero).
    // - If the cursor is successfully advanced to another row of content, then
    // subsequent calls to xEof must return false (zero).
    // - This method must return SQLITE_OK if successful, or an sqlite error code
    // if an error occurs.
    xNext: function(var pVtabCursor: TSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Checks if cursor reached end of rows
    // - Must return false (zero) if the specified cursor currently points to a
    // valid row of data, or true (non-zero) otherwise
    xEof: function(var pVtabCursor: TSQLite3VTabCursor): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// The SQLite core invokes this method in order to find the value for the
    // N-th column of the current row
    // - N is zero-based so the first column is numbered 0.
    // - The xColumn method may return its result back to SQLite using one of the
    // standard sqlite3.result_*() functions with the specified sContext
    // - If the xColumn method implementation calls none of the sqlite3.result_*()
    // functions, then the value of the column defaults to an SQL NULL.
    // - The xColumn method must return SQLITE_OK on success.
    // - To raise an error, the xColumn method should use one of the result_text()
    // methods to set the error message text, then return an appropriate error code.
    xColumn: function(var pVtabCursor: TSQLite3VTabCursor; sContext: TSQLite3FunctionContext;
      N: Integer): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Should fill pRowid with the rowid of row that the virtual table cursor
    // pVtabCursor is currently pointing at
    xRowid: function(var pVtabCursor: TSQLite3VTabCursor; var pRowid: Int64): Integer;
      {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Makes a change to a virtual table content (insert/delete/update)
    // - The nArg parameter specifies the number of entries in the ppArg[] array
    // - The value of nArg will be 1 for a pure delete operation or N+2 for an
    // insert or replace or update where N is the number of columns in the table
    // (including any hidden columns)
    // - The ppArg[0] parameter is the rowid of a row in the virtual table to be deleted.
    // If ppArg[0] is an SQL NULL, then no deletion occurs
    // - The ppArg[1] parameter is the rowid of a new row to be inserted into the
    // virtual table. If ppArg[1] is an SQL NULL, then the implementation must
    // choose a rowid for the newly inserted row. Subsequent ppArg[] entries
    // contain values of the columns of the virtual table, in the order that
    // the columns were declared. The number of columns will match the table
    // declaration that the xConnect or xCreate method made using the
    // sqlite3.declare_vtab() call. All hidden columns are included.
    // - When doing an insert without a rowid (nArg>1, ppArg[1] is an SQL NULL),
    // the implementation must set pRowid to the rowid of the newly inserted row;
    // this will become the value returned by the sqlite3.last_insert_rowid()
    // function. Setting this value in all the other cases is a harmless no-op;
    // the SQLite engine ignores the pRowid return value if nArg=1 or ppArg[1]
    // is not an SQL NULL.
    // - Each call to xUpdate() will fall into one of cases shown below. Note
    // that references to ppArg[i] mean the SQL value held within the ppArg[i]
    // object, not the ppArg[i] object itself:
    // $ nArg = 1
    // The single row with rowid equal to ppArg[0] is deleted. No insert occurs.
    // $ nArg > 1
    // $ ppArg[0] = NULL
    // A new row is inserted with a rowid ppArg[1] and column values in ppArg[2]
    // and following. If ppArg[1] is an SQL NULL, the a new unique rowid is
    // generated automatically.
    // $ nArg > 1
    // $ ppArg[0] <> NULL
    // $ ppArg[0] = ppArg[1]
    // The row with rowid ppArg[0] is updated with new values in ppArg[2] and
    // following parameters.
    // $ nArg > 1
    // $ ppArg[0] <> NULL
    // $ ppArg[0] <> ppArg[1]
    // The row with rowid ppArg[0] is updated with rowid ppArg[1] and new values
    // in ppArg[2] and following parameters. This will occur when an SQL statement
    // updates a rowid, as in the statement:
    // $ UPDATE table SET rowid=rowid+1 WHERE ...;
    // - The xUpdate() method must return SQLITE_OK if and only if it is successful.
    // If a failure occurs, the xUpdate() must return an appropriate error code.
    // On a failure, the pVTab.zErrMsg element may optionally be replaced with
    // a custom error message text.
    // - If the xUpdate() method violates some constraint of the virtual table
    // (including, but not limited to, attempting to store a value of the
    // wrong datatype, attempting to store a value that is too large or too small,
    // or attempting to change a read-only value) then the xUpdate() must fail
    // with an appropriate error code.
    // - There might be one or more TSQLite3VTabCursor objects open and in use on
    // the virtual table instance and perhaps even on the row of the virtual
    // table when the xUpdate() method is invoked. The implementation of xUpdate()
    // must be prepared for attempts to delete or modify rows of the table out
    // from other existing cursors. If the virtual table cannot accommodate such
    // changes, the xUpdate() method must return an error code.
    xUpdate: function(var pVTab: TSQLite3VTab;
      nArg: Integer; var ppArg: TSQLite3ValueArray;
      var pRowid: Int64): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Begins a transaction on a virtual table
    // - This method is always followed by one call to either the xCommit or
    // xRollback method.
    // - Virtual table transactions do not nest, so the xBegin method will not be
    // invoked more than once on a single virtual table without an intervening
    // call to either xCommit or xRollback. For nested transactions, use
    // xSavepoint, xRelease and xRollBackTo methods.
    // - Multiple calls to other methods can and likely will occur in between the
    // xBegin and the corresponding xCommit or xRollback.
    xBegin: function(var pVTab: TSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Signals the start of a two-phase commit on a virtual table
    // - This method is only invoked after call to the xBegin method and prior
    // to an xCommit or xRollback.
    // - In order to implement two-phase commit, the xSync method on all virtual
    // tables is invoked prior to invoking the xCommit method on any virtual table.
    // - If any of the xSync methods fail, the entire transaction is rolled back.
    xSync: function(var pVTab: TSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Causes a virtual table transaction to commit
    xCommit: function(var pVTab: TSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Causes a virtual table transaction to rollback
    xRollback: function(var pVTab: TSQLite3VTab): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Called during sqlite3.prepare() to give the virtual table implementation
    // an opportunity to overload SQL functions
    // - When a function uses a column from a virtual table as its first argument,
    // this method is called to see if the virtual table would like to overload
    // the function. The first three parameters are inputs: the virtual table,
    // the number of arguments to the function, and the name of the function.
    // If no overloading is desired, this method returns 0. To overload the
    // function, this method writes the new function implementation into pxFunc
    // and writes user data into ppArg and returns 1.
    // - Note that infix functions (LIKE, GLOB, REGEXP, and MATCH) reverse the
    // order of their arguments. So "like(A,B)" is equivalent to "B like A".
    // For the form "B like A" the B term is considered the first argument to the
    // function. But for "like(A,B)" the A term is considered the first argument.
    // - The function pointer returned by this routine must be valid for the
    // lifetime of the pVTab object given in the first parameter.
    xFindFunction: function(var pVTab: TSQLite3VTab; nArg: Integer; const zName: PAnsiChar;
      var pxFunc: TSQLFunctionFunc; var ppArg: Pointer): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Provides notification that the virtual table implementation that the
    // virtual table will be given a new name
    // - If this method returns SQLITE_OK then SQLite renames the table.
    // - If this method returns an error code then the renaming is prevented.
    xRename: function(var pVTab: TSQLite3VTab; const zNew: PAnsiChar): Integer;
       {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Starts a new transaction with the virtual table
    // - SAVEPOINTs are a method of creating transactions, similar to BEGIN and
    // COMMIT, except that the SAVEPOINT and RELEASE commands are named and
    // may be nested. See @http://www.sqlite.org/lang_savepoint.html
    // - iSavepoint parameter indicates the unique name of the SAVEPOINT
    xSavepoint: function(var pVTab: TSQLite3VTab; iSavepoint: integer): Integer;
       {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Merges a transaction into its parent transaction, so that the specified
    // transaction and its parent become the same transaction
    // - Causes all savepoints back to and including the most recent savepoint
    // with a matching identifier to be removed from the transaction stack
    // - Some people view RELEASE as the equivalent of COMMIT for a SAVEPOINT.
    // This is an acceptable point of view as long as one remembers that the
    // changes committed by an inner transaction might later be undone by a
    // rollback in an outer transaction.
    // - iSavepoint parameter indicates the unique name of the SAVEPOINT
    xRelease: function(var pVTab: TSQLite3VTab; iSavepoint: integer): Integer;
       {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
    /// Reverts the state of the virtual table content back to what it was just
    // after the corresponding SAVEPOINT
    // - iSavepoint parameter indicates the unique name of the SAVEPOINT
    xRollbackTo: function(var pVTab: TSQLite3VTab; iSavepoint: integer): Integer;
       {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
end;

  /// Used to register a new virtual table module name
  // - The module name is registered on the database connection specified by the
  // first DB parameter.
  // - The name of the module is given by the second parameter.
  // - The third parameter is a pointer to the implementation of the virtual table
  // module.
  // - The fourth parameter is an arbitrary client data pointer that is passed
  // through into the xCreate and xConnect methods of the virtual table module
  // when a new virtual table is be being created or reinitialized.
  // - The fifth parameter can be used to specify a custom destructor for the
  // pClientData buffer. SQLite will invoke the destructor function (if it is
  // not nil) when SQLite no longer needs the pClientData pointer. The
  // destructor will also be invoked if call to sqlite3.create_module_v2() fails.
  Tcreate_module_v2 = function(DB: TSQLite3DB; const zName: PAnsiChar;
    var p: TSQLite3Module; pClientData: Pointer; xDestroy: TSQLDestroyPtr): Integer;
    {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// Declare the Schema of a virtual table
  // - The xCreate() and xConnect() methods of a virtual table module call this
  // interface to declare the format (the names and datatypes of the columns) of
  // the virtual tables they implement. The string can be deallocated and/or reused
  // as soon as the sqlite3.declare_vtab() routine returns.
  // - If a column datatype contains the special keyword "HIDDEN" (in any
  // combination of upper and lower case letters) then that keyword it is omitted
  // from the column datatype name and the column is marked as a hidden column
  // internally. A hidden column differs from a normal column in three respects:
  // 1. Hidden columns are not listed in the dataset returned by "PRAGMA table_info",
  // 2. Hidden columns are not included in the expansion of a "*" expression in
  // the result set of a SELECT, and 3. Hidden columns are not included in the
  // implicit column-list used by an INSERT statement that lacks an explicit
  // column-list.
  Tdeclare_vtab = function(DB: TSQLite3DB; const zSQL: PAnsiChar): Integer;
{$ifndef SQLITE3_FASTCALL}cdecl;{$endif}

  /// used to store bit set for all available Tables in a Database Model
  TSQLFieldTables = set of 0..MAX_SQLTABLES-1;

  /// a set of potential actions to be executed from the server
  // - reSQL will indicate the right to execute any POST SQL statement (not only
  // SELECT statements)
  // - reSQLSelectWithoutTable will allow executing a SELECT statement with
  // arbitrary content via GET/LOCK (simple SELECT .. FROM aTable will be checked
  // against TSQLAccessRights.GET[] per-table right
  // - reService will indicate the right to execute the interface-based JSON-RPC
  // service implementation
  // - reUrlEncodedSQL will indicate the right to execute a SQL query encoded
  // at the URI level, for a GET (to be used e.g. with XMLHTTPRequest, which
  // forced SentData='' by definition), encoded as sql=.... inline parameter
  // - reUrlEncodedDelete will indicate the right to delete items using a
  // WHERE clause for DELETE verb at /root/TableName?WhereClause
  // - reOneSessionPerUser will force that only one session may be created
  // for one user, even if connection comes from the same IP: in this case,
  // you may have to set the SessionTimeOut to a small value, in case the
  // session is not closed gracefully
  // - by default, read/write access to the TSQLAuthUser table is disallowed,
  // for obvious security reasons: but you can define reUserCanChangeOwnPassword
  // so that the current logged user will be able to change its own password
  // - order of this set does matter, since it will be stored as a byte value
  // e.g. by TSQLAccessRights.ToString: ensure that new items will always be
  // appended to the list, not inserted within
  TSQLAllowRemoteExecute = set of (
    reSQL, reService, reUrlEncodedSQL, reUrlEncodedDelete, reOneSessionPerUser,
    reSQLSelectWithoutTable, reUserCanChangeOwnPassword);

  /// used to defined the CRUD associated SQL statement of a command
  // - used e.g. by TSQLRecord.GetJSONValues methods and SimpleFieldsBits[] array
  // (in this case, soDelete is never used, since deletion is global for all fields)
  // - also used for cache content notification
  TSQLOccasion = (
    soSelect,
    soInsert,
    soUpdate,
    soDelete);

  /// used to defined a set of CRUD associated SQL statement of a command
  TSQLOccasions = set of TSQLOccasion;

  /// used to store bit set for all available fields in a Table
  // - with current MAX_SQLFIELDS value, 64 bits uses 8 bytes of memory
  // - see also IsZero() and IsEqual() functions
  // - you can also use ALL_FIELDS as defined in mORMot.pas
  TSQLFieldBits = set of 0..MAX_SQLFIELDS-1;

  /// the kind of SQlite3 (virtual) table
  // - TSQLRecordFTS3/4/5 will be associated with vFTS3/vFTS4/vFTS5 values,
  // TSQLRecordRTree with vRTree, any native SQlite3 table as vSQLite3, and
  // a TSQLRecordVirtualTable*ID with rCustomForcedID/rCustomAutoID
  // - a plain TSQLRecord class can be defined as rCustomForcedID (e.g. for
  // TSQLRecordMany) after registration for an external DB via a call to
  // VirtualTableExternalRegister() from mORMotDB unit
  TSQLRecordVirtualKind = (
    rSQLite3, rFTS3, rFTS4, rFTS5, rRTree, rCustomForcedID, rCustomAutoID);

  /// the possible Server-side instance implementation patterns for
  // interface-based services
  // - each interface-based service will be implemented by a corresponding
  // class instance on the server: this parameter is used to define how
  // class instances are created and managed
  // - on the Client-side, each instance will be handled depending on the
  // server side implementation (i.e. with sicClientDriven behavior if necessary)
  // - sicSingle: one object instance is created per call - this is the
  // most expensive way of implementing the service, but is safe for simple
  // workflows (like a one-type call); this is the default setting for
  // TSQLRestServer.ServiceRegister method
  // - sicShared: one object instance is used for all incoming calls and is
  // not recycled subsequent to the calls - the implementation should be
  // thread-safe on the server side
  // - sicClientDriven: one object instance will be created in synchronization
  // with the client-side lifetime of the corresponding interface: when the
  // interface will be released on client, it will be released on the server
  // side - a numerical identifier will be transmitted for all JSON requests
  // - sicPerSession, sicPerUser and sicPerGroup modes will maintain one
  // object instance per running session / user / group (only working if
  // RESTful authentication is enabled) - since it may be shared among users or
  // groups, the sicPerUser and sicPerGroup implementation should be thread-safe
  // - sicPerThread will maintain one object instance per calling thread - it
  // may be useful instead of sicShared mode if the service process expects
  // some per-heavy thread initialization, for instance
  TServiceInstanceImplementation = (
    sicSingle, sicShared, sicClientDriven, sicPerSession, sicPerUser, sicPerGroup,
    sicPerThread);
  /// set of Server-side instance implementation patterns for
  // interface-based services
  TServiceInstanceImplementations = set of TServiceInstanceImplementation;

const
  /// if a TSQLVirtualTablePreparedConstraint.Column is to be ignored
  VIRTUAL_TABLE_IGNORE_COLUMN = -2;
  /// if a TSQLVirtualTablePreparedConstraint.Column points to the RowID
  VIRTUAL_TABLE_ROWID_COLUMN = -1;

  /// if the TSQLRecordVirtual table kind is a FTS virtual table
  IS_FTS = [rFTS3, rFTS4, rFTS5];

  /// if the TSQLRecordVirtual table kind is not an embedded type
  // - can be set for a TSQLRecord after a VirtualTableExternalRegister call
  IS_CUSTOM_VIRTUAL = [rCustomForcedID, rCustomAutoID];

  /// if the TSQLRecordVirtual table kind expects the ID to be set on INSERT
  INSERT_WITH_ID = [rFTS3, rFTS4, rFTS5, rRTree, rCustomForcedID];

  /// Supervisor Table access right, i.e. alllmighty over all fields
  ALL_ACCESS_RIGHTS = [0..MAX_SQLTABLES-1];

  /// special TSQLFieldBits value containing all field bits set to 1
  ALL_FIELDS: TSQLFieldBits = [0..MAX_SQLFIELDS-1];

  // contains TSQLAuthUser.ComputeHashedPassword('synopse')
  DEFAULT_HASH_SYNOPSE = '67aeea294e1cb515236fd7829c55ec820ef888e8e221814d24d83b3dc4d825dd';

  /// the Server-side instance implementation patterns without any ID
  SERVICE_IMPLEMENTATION_NOID = [sicSingle,sicShared];

  /// typical TJSONSerializerSQLRecordOptions values for AJAX clients
//  JSONSERIALIZEROPTIONS_AJAX = [jwoAsJsonNotAsString,jwoID_str];

  /// DestroyPtr set to SQLITE_STATIC if data is constant and will never change
  // - SQLite assumes that the text or BLOB result is in constant space and
  // does not copy the content of the parameter nor call a destructor on the
  // content when it has finished using that result
  SQLITE_STATIC = pointer(0);

  /// DestroyPtr set to SQLITE_TRANSIENT for SQLite3 to make a private copy of
  // the data into space obtained from from sqlite3.malloc() before it returns
  // - this is the default behavior in our framework
  // - note that we discovered that under Win64, sqlite3.result_text() expects
  // SQLITE_TRANSIENT_VIRTUALTABLE=pointer(integer(-1)) and not pointer(-1)
  SQLITE_TRANSIENT = pointer(-1);

  /// DestroyPtr set to SQLITE_TRANSIENT_VIRTUALTABLE for setting results to
  // SQlite3 virtual tables columns
  // - due to a bug of the SQlite3 engine under Win64
  SQLITE_TRANSIENT_VIRTUALTABLE = pointer(integer(-1));


var
  create_module_v2 : Tcreate_module_v2 = nil;
  declare_vtab : Tdeclare_vtab = nil;
  {$DEFINE D}
  {$if FPC_FULLVERSION<26500}
  {$IFDEF S}procedure{$ELSE}var{$ENDIF}sqlite3_result_int{$IFDEF D}: procedure{$ENDIF}(ctx: psqlite3_context; V: cint); cdecl;{$IFDEF S}external Sqlite3Lib;{$ENDIF}
  {$IFDEF S}procedure{$ELSE}var{$ENDIF}sqlite3_result_int64{$IFDEF D}: procedure{$ENDIF}(ctx: psqlite3_context; V: sqlite3_int64); cdecl;{$IFDEF S}external Sqlite3Lib;{$ENDIF}
  {$endif}

function GetInt64(P: PUTF8Char): Int64;
procedure SQlite3ValueToSQLVar(Value: TSQLite3Value; var Res: TSQLVar);
function SQLVarToSQlite3Context(const Res: TSQLVar; Context: TSQLite3FunctionContext): boolean;

function LoadSQLiteFuncs : Boolean;

implementation

function LoadSQLiteFuncs: Boolean;
begin
  InitialiseSQLite;
  create_module_v2:=Tcreate_module_v2(GetProcedureAddress(SQLiteLibraryHandle,'sqlite3_create_module_v2'));
  declare_vtab:=Tdeclare_vtab(GetProcedureAddress(SQLiteLibraryHandle,'sqlite3_declare_vtab'));
  {$if FPC_FULLVERSION<26500}
  //Bug in Fpc 2.6.4 has no result_int64 support
  pointer(sqlite3_result_int):=GetProcedureAddress(SQLiteLibraryHandle,'sqlite3_result_int');
  pointer(sqlite3_result_int64):=GetProcedureAddress(SQLiteLibraryHandle,'sqlite3_result_int64');
  {$endif}
  Result := Assigned(create_module_v2);
end;

{ TSQLVirtualTablePrepared }

function TSQLVirtualTablePrepared.IsWhereIDEquals(CalledFromPrepare: Boolean): boolean;
begin
  result := (WhereCount=1) and (Where[0].Column=VIRTUAL_TABLE_ROWID_COLUMN) and
     (CalledFromPrepare or (Where[0].Value.VType=ftInt64)) and
     (Where[0].Operation=soEqualTo);
end;

function TSQLVirtualTablePrepared.IsWhereOneFieldEquals: boolean;
begin
  result := (WhereCount=1) and (Where[0].Column>=0) and
     (Where[0].Operation=soEqualTo);
end;

function GetInteger(P: PUTF8Char): PtrInt;
var c: PtrUInt;
    minus: boolean;
begin
  if P=nil then begin
    result := 0;
    exit;
  end;
  if P^ in [#1..' '] then repeat inc(P) until not(P^ in [#1..' ']);
  if P^='-' then begin
    minus := true;
    repeat inc(P) until P^<>' ';
  end else begin
    minus := false;
    if P^='+' then
      repeat inc(P) until P^<>' ';
  end;
  c := byte(P^)-48;
  if c>9 then
    result := 0 else begin
    result := c;
    inc(P);
    repeat
      c := byte(P^)-48;
      if c>9 then
        break else
        result := result*10+PtrInt(c);
      inc(P);
    until false;
    if minus then
      result := -result;
  end;
end;
{$ifdef CPU64}
procedure SetInt64(P: PUTF8Char; var result: Int64);
begin // PtrInt is already int64 -> call PtrInt version
  result := GetInteger(P);
end;
{$else}
procedure SetInt64(P: PUTF8Char; var result: Int64);
var c: cardinal;
    minus: boolean;
begin
  result := 0;
  if P=nil then
    exit;
  if P^ in [#1..' '] then repeat inc(P) until not(P^ in [#1..' ']);
  if P^='-' then begin
    minus := true;
    repeat inc(P) until P^<>' ';
  end else begin
    minus := false;
    if P^='+' then
      repeat inc(P) until P^<>' ';
  end;
  c := byte(P^)-48;
  if c>9 then
    exit;
  Int64Rec(result).Lo := c;
  inc(P);
  repeat // fast 32 bit loop
    c := byte(P^)-48;
    if c>9 then
      break else
      Int64Rec(result).Lo := Int64Rec(result).Lo*10+c;
    inc(P);
    if Int64Rec(result).Lo>=high(cardinal)div 10 then begin
      repeat // 64 bit loop
        c := byte(P^)-48;
        if c>9 then
          break;
        result := result shl 3+result+result; // fast result := result*10
        inc(result,c);
        inc(P);
      until false;
      break;
    end;
  until false;
  if minus then
    result := -result;
end;
{$endif}
{$ifdef CPU64}
function GetInt64(P: PUTF8Char): Int64;
begin // PtrInt is already int64 -> call previous version
  result := GetInteger(P);
end;
{$else}
function GetInt64(P: PUTF8Char): Int64;
begin
  SetInt64(P,result);
end;
{$endif}
procedure SQlite3ValueToSQLVar(Value: TSQLite3Value; var Res: TSQLVar);
var ValueType: Integer;
begin
  Res.Options := [];
  ValueType := sqlite3_value_type(Value);
  case ValueType of
  SQLITE_NULL:
    Res.VType := ftNull;
  SQLITE_INTEGER: begin
    Res.VType := ftInt64;
    Res.VInt64 := sqlite3_value_int64(Value);
  end;
  SQLITE_FLOAT: begin
    Res.VType := ftDouble;
    Res.VDouble := sqlite3_value_double(Value);
  end;
  SQLITE_TEXT:  begin
    Res.VType := ftUTF8;
    Res.VText := sqlite3_value_text(Value);
  end;
  SQLITE_BLOB: begin
    Res.VType := ftBlob;
    Res.VBlobLen := sqlite3_value_bytes(Value);
    Res.VBlob := sqlite3_value_blob(Value);
  end;
  else begin
    {$ifdef WITHLOG}
    SynSQLite3Log.DebuggerNotify(sllWarning,'SQlite3ValueToSQLVar(%)',[ValueType]);
    {$endif}
    Res.VType := ftUnknown;
  end;
  end;
end;
const
  /// fast lookup table for converting any decimal number from
  // 0 to 99 into their ASCII equivalence
  // - our enhanced SysUtils.pas (normal and LVCL) contains the same array
  TwoDigitLookup: packed array[0..99] of array[1..2] of AnsiChar =
    ('00','01','02','03','04','05','06','07','08','09',
     '10','11','12','13','14','15','16','17','18','19',
     '20','21','22','23','24','25','26','27','28','29',
     '30','31','32','33','34','35','36','37','38','39',
     '40','41','42','43','44','45','46','47','48','49',
     '50','51','52','53','54','55','56','57','58','59',
     '60','61','62','63','64','65','66','67','68','69',
     '70','71','72','73','74','75','76','77','78','79',
     '80','81','82','83','84','85','86','87','88','89',
     '90','91','92','93','94','95','96','97','98','99');
var
  /// fast lookup table for converting any decimal number from
  // 0 to 99 into their ASCII equivalence
  TwoDigitLookupW: packed array[0..99] of word absolute TwoDigitLookup;
procedure YearToPChar(Y: cardinal; P: PUTF8Char);
var d100: cardinal;
begin
  if Y<=9999 then begin
    d100 := Y div 100;
    PWordArray(P)^[0] := TwoDigitLookupW[d100];
    PWordArray(P)^[1] := TwoDigitLookupW[Y-(d100*100)];
  end else
    PCardinal(P)^ := $39393939; // '9999'
end;
procedure TimeToIso8601PChar(P: PUTF8Char; Expanded: boolean; H,M,S,MS: cardinal;
  FirstChar: AnsiChar; WithMS: boolean); overload;
// use Thhmmss[.sss] format
begin
  if FirstChar<>#0 then begin
    P^ := FirstChar;
    inc(P);
  end;
  PWord(P)^ := TwoDigitLookupW[H];
  inc(P,2);
  if Expanded then begin
    P^ := ':';
    inc(P);
  end;
  PWord(P)^ := TwoDigitLookupW[M];
  inc(P,2);
  if Expanded then begin
    P^ := ':';
    inc(P);
  end;
  PWord(P)^ := TwoDigitLookupW[S];
  if WithMS then begin
    inc(P,2);
    YearToPChar(MS,P);
    P^ := '.'; // override first digit
  end;
end;
procedure DateToIso8601PChar(P: PUTF8Char; Expanded: boolean; Y,M,D: cardinal); overload;
// use 'YYYYMMDD' format if not Expanded, 'YYYY-MM-DD' format if Expanded
begin
{$ifdef PUREPASCAL}
  PWord(P  )^ := TwoDigitLookupW[Y div 100];
  PWord(P+2)^ := TwoDigitLookupW[Y mod 100];
{$else}
  YearToPChar(Y,P);
{$endif}
  inc(P,4);
  if Expanded then begin
    P^ := '-';
    inc(P);
  end;
  PWord(P)^ := TwoDigitLookupW[M];
  inc(P,2);
  if Expanded then begin
    P^ := '-';
    inc(P);
  end;
  PWord(P)^ := TwoDigitLookupW[D];
end;
procedure TimeToIso8601PChar(Time: TDateTime; P: PUTF8Char; Expanded: boolean;
  FirstChar: AnsiChar; WithMS: boolean);
var H,M,S,MS: word;
begin
  DecodeTime(Time,H,M,S,MS);
  TimeToIso8601PChar(P,Expanded,H,M,S,MS,FirstChar,WithMS);
end;
procedure DateToIso8601PChar(Date: TDateTime; P: PUTF8Char; Expanded: boolean);
// use YYYYMMDD / YYYY-MM-DD date format
var Y,M,D: word;
begin
  DecodeDate(Date,Y,M,D);
  DateToIso8601PChar(P,Expanded,Y,M,D);
end;procedure DateTimeToIso8601ExpandedPChar(const Value: TDateTime; Dest: PUTF8Char;
  FirstChar: AnsiChar='T'; WithMS: boolean=false);
begin
  if Value<>0 then begin
    if trunc(Value)<>0 then begin
      DateToIso8601PChar(Value,Dest,true);
      inc(Dest,10);
    end;
    if frac(Value)<>0 then begin
      TimeToIso8601PChar(Value,Dest,true,FirstChar,WithMS);
      inc(Dest,9+4*integer(WithMS));
    end;
  end;
  Dest^ := #0;
end;
const
  NULCHAR: AnsiChar = #0;
function SQLVarToSQlite3Context(const Res: TSQLVar; Context: TSQLite3FunctionContext): boolean;
var tmp: array[0..31] of AnsiChar;
begin
  case Res.VType of
    ftNull:
      sqlite3_result_null(@Context);
    ftInt64:
      sqlite3_result_int64(Context,Res.VInt64);
    ftDouble:
      sqlite3_result_double(Context,Res.VDouble);
    ftCurrency:
      sqlite3_result_double(Context,Res.VCurrency);
    ftDate: begin
      DateTimeToIso8601ExpandedPChar(Res.VDateTime,tmp,'T',svoDateWithMS in Res.Options);
      sqlite3_result_text(Context,tmp,-1,sqlite3_destructor_type(SQLITE_TRANSIENT));
    end;
    // WARNING! use pointer(integer(-1)) instead of SQLITE_TRANSIENT=pointer(-1)
    // due to a bug in Sqlite3 current implementation of virtual tables in Win64
    ftUTF8:
      if Res.VText=nil then
       sqlite3_result_text(Context,@NULCHAR,0,sqlite3_destructor_type(SQLITE_STATIC)) else
       sqlite3_result_text(Context,Res.VText,-1,sqlite3_destructor_type(SQLITE_TRANSIENT));
    ftBlob:
      sqlite3_result_blob(Context,Res.VBlob,Res.VBlobLen,sqlite3_destructor_type(SQLITE_TRANSIENT));
    else begin
      sqlite3_result_null(Context);
      {$ifdef WITHLOG}
      SynSQLite3Log.DebuggerNotify(sllWarning,'SQLVarToSQlite3Context(%)',[ord(Res.VType)]);
      {$endif}
      result := false; // not handled type (will set null value)
      exit;
    end;
  end;
  result := true;
end;

end.

