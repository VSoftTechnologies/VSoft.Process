{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright � Vincent Parrett and contributors                    }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit VSoft.Process.Environment;

interface

// Platform-specific environment handling:
// - Windows: ToEnvironmentBlock returns Unicode environment block for CreateProcess
// - POSIX: ToEnvironArray returns null-terminated string array for execve

uses
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  //Note : this is a unicode environment block - use CREATE_UNICODE_ENVIRONMENT flag
  TEnvironmentBuilder = class(TInterfacedObject, IEnvironmentBuilder)
  private
    FChanged : boolean;
    FUserModified : boolean;
    FData : TBytes;
    FVariables : TStringList;
  protected
    function GetCount : integer;
    function HasOverrides : boolean;
    function Reset : IEnvironmentBuilder;
    function LoadCurrentEnvironmentBlock : IEnvironmentBuilder;
    function AddOrSet(const name : string; const value : string) : IEnvironmentBuilder;
    function AddOrSetValues(const list : TStrings) : IEnvironmentBuilder;
    function Remove(const name : string) : IEnvironmentBuilder;
    function TryGetValue(const name : string; out value : string) : boolean;
    function Exists(const name : string) : boolean;
    function Clear : IEnvironmentBuilder;
    function ToEnvironmentBlock : Pointer;
    function ToEnvironArray : TArray<PAnsiChar>;
    function Clone : IEnvironmentBuilder;

    constructor CreateClone(const source : TEnvironmentBuilder);
  public
    constructor Create;
    destructor Destroy;override;
    function ToString : string;override;
  end;


implementation

uses
  {$IFDEF MSWINDOWS}
  WinApi.Windows;
  {$ELSE}
  {$IFDEF LINUX}
  Posix.Dlfcn,
  {$ENDIF}
  Posix.Unistd;
  {$ENDIF}

{ TEnvironment }

procedure ValidateName(const name : string);
begin
  if (name = '') or (Pos('=', name) > 0) then
    raise EArgumentException.Create('Invalid environment variable name: "' + name + '"');
end;

function TEnvironmentBuilder.AddOrSet(const name, value: string) : IEnvironmentBuilder;
var
  idx : integer;
begin
  ValidateName(name);
  result := Self;
  idx := FVariables.IndexOfName(name);
  if idx <> -1 then
    // Not ValueFromIndex: assigning '' to it deletes the line.
    FVariables[idx] := FVariables.Names[idx] + '=' + value
  else
    FVariables.Add(name +'=' + value);
  FChanged := True;
  FUserModified := True;
end;

function TEnvironmentBuilder.HasOverrides : boolean;
begin
  result := FUserModified;
end;

function TEnvironmentBuilder.AddOrSetValues(const list: TStrings) : IEnvironmentBuilder;
var
  i : Integer;
begin
  result := Self;
  if list = nil then
    exit;
  for i := 0 to list.Count -1 do
  begin
    if Pos('=',list.Strings[i]) > 1 then
      AddOrSet(list.Names[i],list.ValueFromIndex[i]); // AddOrSet sets FUserModified
  end;
end;

function TEnvironmentBuilder.Reset : IEnvironmentBuilder;
begin
  result := Self;
  FChanged := true;
  FUserModified := False; // contents will match current process env
  FVariables.Clear;
  SetLength(FData,0);
  LoadCurrentEnvironmentBlock;
end;

function TEnvironmentBuilder.Clone: IEnvironmentBuilder;
begin
  result := TEnvironmentBuilder.CreateClone(Self);
end;

constructor TEnvironmentBuilder.Create;
begin
  inherited Create;
  FVariables := TStringList.Create;
  {$IFNDEF MSWINDOWS}
  // POSIX variable names are case sensitive (PATH and Path are different).
  FVariables.CaseSensitive := True;
  {$ENDIF}
  Reset;
end;

constructor TEnvironmentBuilder.CreateClone(const source: TEnvironmentBuilder);
begin
  Create;
  FVariables.Assign(source.FVariables);
  FChanged := true;
  // Mirror the source's "user has overridden" state so the platform impl
  // can keep its inherit-parent-env optimisation when cloning an unchanged
  // builder.
  FUserModified := source.FUserModified;
end;

destructor TEnvironmentBuilder.Destroy;
begin
  FVariables.Free;
  inherited;
end;

function TEnvironmentBuilder.GetCount: integer;
begin
  result := FVariables.Count;
end;

{$IFDEF MSWINDOWS}
// bIgnoreCase must be exactly 0 or 1 (LongBool True is -1 and is rejected).
function CompareStringOrdinal(lpString1 : PWideChar; cchCount1 : Integer; lpString2 : PWideChar; cchCount2 : Integer; bIgnoreCase : Integer) : Integer; stdcall; external kernel32 name 'CompareStringOrdinal';

// Name part of a NAME=VALUE entry. Drive-cwd entries like "=C:=C:\dir" start
// with '=' which is part of the name.
function EnvName(const entry : string) : string;
var
  idx : integer;
begin
  idx := Pos('=', Copy(entry, 2, MaxInt));
  if idx = 0 then
    result := entry
  else
    result := Copy(entry, 1, idx);
end;

function CompareEnvEntries(list : TStringList; index1, index2 : integer) : integer;
var
  name1, name2 : string;
begin
  // CreateProcess requires the block sorted case-insensitively by name in
  // Unicode ordinal order, without regard to locale.
  name1 := EnvName(list[index1]);
  name2 := EnvName(list[index2]);
  result := CompareStringOrdinal(PWideChar(name1), Length(name1), PWideChar(name2), Length(name2), 1);
  if result = 0 then // failed - fall back to an ASCII case-insensitive compare
    result := CompareText(name1, name2)
  else
    result := result - 2; // CSTR_LESS_THAN / CSTR_EQUAL / CSTR_GREATER_THAN -> -1 / 0 / 1
end;
{$ENDIF}

function TEnvironmentBuilder.ToEnvironmentBlock: Pointer;
var
  len : integer;
  bytes : TBytes;
  byteCount : integer;
  count : integer;
  i: Integer;
  sorted : TStringList;
begin
  //avoid regenerating the block if we already have it and it's not changed.
  if not FChanged  then
  begin
    if Length(FData) > 0 then
      Exit(@FData[0]);
  end;
  SetLength(FData,0);

  len := 4096;
  SetLength(FData,len);

  count := 0;
  sorted := TStringList.Create;
  try
    sorted.Assign(FVariables);
    {$IFDEF MSWINDOWS}
    sorted.CustomSort(CompareEnvEntries);
    {$ENDIF}
    for i := 0 to sorted.Count - 1 do
    begin
      bytes := TEncoding.Unicode.GetBytes(sorted.Strings[i]);
      byteCount := Length(bytes);
      //incease the length of the buffer as needed.
      while (count + byteCount + 2) > len do
      begin
        Inc(len,2048);
        SetLength(FData,len);
      end;
      if byteCount > 0 then
        Move(bytes[0],FData[count],byteCount);
      Inc(count,byteCount);
      FData[count] := 0;
      Inc(count);
      FData[count] := 0;
      Inc(count);
    end;
  finally
    sorted.Free;
  end;
  //an empty block is an empty string followed by the terminator
  if count = 0 then
  begin
    FData[0] := 0;
    FData[1] := 0;
    count := 2;
  end;
  //ensure space for trailing double nil
  if count + 2 > len then
  begin
    Inc(len,2);
    SetLength(FData,len);
  end;
  //terminates the block
  FData[count] := 0;
  FData[count+1] := 0;
  result := @FData[0];
  FChanged := false;
end;

function TEnvironmentBuilder.LoadCurrentEnvironmentBlock : IEnvironmentBuilder;
{$IFDEF MSWINDOWS}
var
  PEnvBlock : PChar;
  pTmp : PChar;
  sTmp : string;
begin
  result := Self;
  FVariables.Clear;
  FChanged := True;
  SetLength(FData,0);
  PEnvBlock := GetEnvironmentStrings;
  try
    pTmp := PEnvBlock;
    while pTmp^ <> #0 do
    begin
      stmp := string(pTmp);
      pTmp := pTmp + Length(sTmp) + 1;
      if (Trim(sTmp) <> '') and (Trim(stmp) <> '=::=::\') then
        FVariables.Add(stmp);
    end;    // while
  finally
    FreeEnvironmentStrings(PEnvBlock);
  end;
end;
{$ELSE}
var
  envPtr: PPAnsiChar;
  utf8Bytes: TBytes;
  envStr: string;
  len: Integer;
begin
  result := Self;
  FVariables.Clear;
  FChanged := True;
  SetLength(FData,0);

  envPtr := PPAnsiChar(environ);
  while envPtr^ <> nil do
  begin
    len := 0;
    while envPtr^[len] <> #0 do
      Inc(len);
    SetLength(utf8Bytes, len);
    if len > 0 then
      Move(envPtr^^, utf8Bytes[0], len);
    envStr := TEncoding.UTF8.GetString(utf8Bytes);
    if Trim(envStr) <> '' then
      FVariables.Add(envStr);
    Inc(envPtr);
  end;
end;
{$ENDIF}

function TEnvironmentBuilder.Remove(const name: string) : IEnvironmentBuilder;
var
  idx : integer;
begin
  result := Self;
  idx := FVariables.IndexOfName(name);
  if idx <> -1 then
  begin
    FVariables.Delete(idx);
    FChanged := true;
    FUserModified := True;
  end;
end;

function TEnvironmentBuilder.Clear : IEnvironmentBuilder;
begin
  result := Self;
  FVariables.Clear;
  FChanged := true;
  FUserModified := True;
end;

function TEnvironmentBuilder.TryGetValue(const name : string; out value : string) : boolean;
var
  idx : integer;
begin
  idx := FVariables.IndexOfName(name);
  result := idx <> -1;
  if result then
    value := FVariables.ValueFromIndex[idx]
  else
    value := '';
end;

function TEnvironmentBuilder.Exists(const name : string) : boolean;
begin
  // An empty name would match Windows drive entries such as "=C:=C:\dir".
  result := (name <> '') and (FVariables.IndexOfName(name) <> -1);
end;

function TEnvironmentBuilder.ToString: string;
begin
  result := FVariables.Text;
end;

function TEnvironmentBuilder.ToEnvironArray: TArray<PAnsiChar>;
var
  i, j: Integer;
  utf8Bytes: TBytes;
  len: Integer;
begin
  SetLength(result, FVariables.Count + 1);
  // Pre-nil every slot so that on an exception in the loop below we can
  // free only the ones we actually allocated, without reading garbage.
  for i := 0 to High(result) do
    result[i] := nil;

  try
    for i := 0 to FVariables.Count - 1 do
    begin
      utf8Bytes := TEncoding.UTF8.GetBytes(FVariables.Strings[i]);
      len := Length(utf8Bytes);
      GetMem(result[i], len + 1);
      if len > 0 then
        Move(utf8Bytes[0], result[i]^, len);
      PAnsiChar(result[i])[len] := #0;  // NULL-terminate the string
    end;
  except
    // H11: if GetMem / GetBytes raises mid-loop, free the entries we did
    // manage to allocate so we don't leak them, then re-raise.
    for j := 0 to High(result) do
      if result[j] <> nil then
      begin
        FreeMem(result[j]);
        result[j] := nil;
      end;
    SetLength(result, 0);
    raise;
  end;

  // NULL-terminate the array
  result[FVariables.Count] := nil;
end;

end.
