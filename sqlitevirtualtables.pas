{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit sqlitevirtualtables;

{$warn 5023 off : no warning about unused units}
interface

uses
  uSqlite3Helper, usqlite3virtualTable, LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('sqlitevirtualtables', @Register);
end.
