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
    // The host environment is copied in one piece (NUL terminated entries)
    // when the builder is created or Reset, and only split into FVariables
    // when something asks for the variables: most builders are never
    // touched. False while FVariables has not been filled from FHostBlock.
    FLoaded : boolean;
    {$IFDEF MSWINDOWS}
    FHostBlock : string;
    {$ELSE}
    FHostBlock : TBytes;
    // Host entries that are not valid UTF-8, exactly as found in environ.
    // FVariables holds a lossy decode of such an entry and, in Objects, its
    // index here + 1, so the child still gets the original bytes unless the
    // variable is set again.
    FRawEntries : TArray<TBytes>;
    {$ENDIF}
    procedure EnsureLoaded;
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

// Compares two names the way Windows does: case-insensitively, in Unicode
// ordinal order, without regard to locale.
function CompareNames(const name1 : string; const name2 : string) : integer;
begin
  result := CompareStringOrdinal(PWideChar(name1), Length(name1), PWideChar(name2), Length(name2), 1);
  if result = 0 then // failed - fall back to an ASCII case-insensitive compare
    result := CompareText(name1, name2)
  else
    result := result - 2; // CSTR_LESS_THAN / CSTR_EQUAL / CSTR_GREATER_THAN -> -1 / 0 / 1
end;

function CompareEnvEntries(list : TStringList; index1, index2 : integer) : integer;
begin
  // CreateProcess requires the block sorted case-insensitively by name in
  // Unicode ordinal order, without regard to locale.
  result := CompareNames(EnvName(list[index1]), EnvName(list[index2]));
end;
{$ELSE}
// Decodes one environ entry as UTF-8. Every byte that is not part of a
// well-formed sequence becomes U+FFFD and clears lossless: the text can then
// not be encoded back to the bytes it came from.
function DecodeEnvironEntry(const bytes : TBytes; out lossless : boolean) : string;
var
  i : integer;
  k : integer;
  extra : integer;
  count : integer;
  codePoint : Cardinal;
  minimum : Cardinal;
  valid : boolean;
begin
  lossless := true;
  // Never more UTF-16 code units than bytes.
  SetLength(result, Length(bytes));
  count := 0;
  i := 0;
  while i < Length(bytes) do
  begin
    codePoint := bytes[i];
    minimum := 0;
    extra := 0;
    valid := true;
    if codePoint >= $80 then
    begin
      if (codePoint and $E0) = $C0 then
      begin
        extra := 1;
        minimum := $80;
        codePoint := codePoint and $1F;
      end
      else if (codePoint and $F0) = $E0 then
      begin
        extra := 2;
        minimum := $800;
        codePoint := codePoint and $0F;
      end
      else if (codePoint and $F8) = $F0 then
      begin
        extra := 3;
        minimum := $10000;
        codePoint := codePoint and $07;
      end
      else
        valid := false;
    end;
    valid := valid and (i + extra < Length(bytes));
    k := 1;
    while valid and (k <= extra) do
    begin
      valid := (bytes[i + k] and $C0) = $80;
      codePoint := (codePoint shl 6) or (bytes[i + k] and $3F);
      Inc(k);
    end;
    // Overlong forms, surrogates and values past U+10FFFF are not UTF-8.
    valid := valid and (codePoint >= minimum) and (codePoint <= $10FFFF) and
             ((codePoint < $D800) or (codePoint > $DFFF));
    if not valid then
    begin
      lossless := false;
      codePoint := $FFFD;
      extra := 0;
    end;
    if codePoint >= $10000 then
    begin
      Dec(codePoint, $10000);
      Inc(count);
      result[count] := Char($D800 or (codePoint shr 10));
      Inc(count);
      result[count] := Char($DC00 or (codePoint and $3FF));
    end
    else
    begin
      Inc(count);
      result[count] := Char(codePoint);
    end;
    Inc(i, extra + 1);
  end;
  SetLength(result, count);
end;
{$ENDIF}

procedure ValidateName(const name : string);
begin
  // A #0 would end the entry early in the environment block and start
  // another variable.
  if (name = '') or (Pos('=', name) > 0) or (Pos(#0, name) > 0) then
    raise EArgumentException.Create('Invalid environment variable name: "' + StringReplace(name, #0, '\0', [rfReplaceAll]) + '"');
end;

procedure ValidateValue(const name : string; const value : string);
begin
  if Pos(#0, value) > 0 then
    raise EArgumentException.Create('Invalid value for environment variable "' + name + '": it contains a NUL character');
end;

// Index of the variable called name, or -1. An empty name (or one holding
// '=') is never a variable, so drive entries such as "=C:=C:\dir" are not
// matched. Windows matches names ordinally, ignoring case, as it sorts them;
// TStringList.IndexOfName would use a locale-aware comparison.
function IndexOfVariable(const list : TStringList; const name : string) : integer;
{$IFDEF MSWINDOWS}
var
  i : integer;
  entry : string;
{$ENDIF}
begin
  result := -1;
  if (name = '') or (Pos('=', name) > 0) then
    exit;
  {$IFDEF MSWINDOWS}
  for i := 0 to list.Count - 1 do
  begin
    entry := list[i];
    // An entry without '=' has no name, as with IndexOfName.
    if (Pos('=', Copy(entry, 2, MaxInt)) > 0) and (CompareNames(EnvName(entry), name) = 0) then
      Exit(i);
  end;
  {$ELSE}
  result := list.IndexOfName(name);
  {$ENDIF}
end;

function TEnvironmentBuilder.AddOrSet(const name, value: string) : IEnvironmentBuilder;
var
  idx : integer;
begin
  ValidateName(name);
  ValidateValue(name, value);
  result := Self;
  EnsureLoaded;
  idx := IndexOfVariable(FVariables, name);
  if idx <> -1 then
  begin
    // Not ValueFromIndex: assigning '' to it deletes the line.
    FVariables[idx] := FVariables.Names[idx] + '=' + value;
    FVariables.Objects[idx] := nil;
  end
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
  // Check every entry first, so a bad one leaves the builder unchanged.
  for i := 0 to list.Count -1 do
  begin
    if Pos('=',list.Strings[i]) > 1 then
    begin
      ValidateName(list.Names[i]);
      ValidateValue(list.Names[i], list.ValueFromIndex[i]);
    end;
  end;
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
  // Not Create: that would copy the host environment only to discard it.
  inherited Create;
  FVariables := TStringList.Create;
  {$IFNDEF MSWINDOWS}
  FVariables.CaseSensitive := True;
  {$ENDIF}
  FLoaded := source.FLoaded;
  if FLoaded then
  begin
    FVariables.Assign(source.FVariables);
    {$IFNDEF MSWINDOWS}
    FRawEntries := Copy(source.FRawEntries);
    {$ENDIF}
  end
  else
    // Shared, never changed: the clone splits the same copy when it needs to.
    FHostBlock := source.FHostBlock;
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
  EnsureLoaded;
  result := FVariables.Count;
end;

function TEnvironmentBuilder.ToEnvironmentBlock: Pointer;
var
  len : integer;
  bytes : TBytes;
  byteCount : integer;
  count : integer;
  i: Integer;
  sorted : TStringList;
begin
  EnsureLoaded;
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
begin
  result := Self;
  FVariables.Clear;
  FChanged := True;
  FLoaded := False;
  SetLength(FData,0);
  FHostBlock := '';
  PEnvBlock := GetEnvironmentStrings;
  if PEnvBlock = nil then
    exit;
  try
    pTmp := PEnvBlock;
    while pTmp^ <> #0 do
      pTmp := pTmp + StrLen(pTmp) + 1;
    SetString(FHostBlock, PEnvBlock, pTmp - PEnvBlock);
  finally
    FreeEnvironmentStrings(PEnvBlock);
  end;
end;
{$ELSE}
var
  envPtr: PPAnsiChar;
  len: Integer;
  total: Integer;
begin
  result := Self;
  FVariables.Clear;
  SetLength(FRawEntries, 0);
  FChanged := True;
  FLoaded := False;
  SetLength(FData,0);

  total := 0;
  envPtr := PPAnsiChar(environ);
  while (envPtr <> nil) and (envPtr^ <> nil) do
  begin
    len := 0;
    while envPtr^[len] <> #0 do
      Inc(len);
    Inc(total, len + 1);
    Inc(envPtr);
  end;
  FHostBlock := nil;
  SetLength(FHostBlock, total);
  total := 0;
  envPtr := PPAnsiChar(environ);
  while (envPtr <> nil) and (envPtr^ <> nil) do
  begin
    len := 0;
    while envPtr^[len] <> #0 do
      Inc(len);
    // The environment may have grown since it was measured.
    if total + len + 1 > Length(FHostBlock) then
      Break;
    Move(envPtr^^, FHostBlock[total], len + 1);
    Inc(total, len + 1);
    Inc(envPtr);
  end;
  SetLength(FHostBlock, total);
end;
{$ENDIF}

procedure TEnvironmentBuilder.EnsureLoaded;
{$IFDEF MSWINDOWS}
var
  pTmp : PChar;
  pEnd : PChar;
  sTmp : string;
begin
  if FLoaded then
    exit;
  FLoaded := True;
  // Not @FHostBlock[1]: that would copy a block shared with a clone.
  pTmp := PChar(Pointer(FHostBlock));
  pEnd := pTmp + Length(FHostBlock);
  while pTmp < pEnd do
  begin
    stmp := string(pTmp);
    pTmp := pTmp + Length(sTmp) + 1;
    if (Trim(sTmp) <> '') and (Trim(stmp) <> '=::=::\') then
      FVariables.Add(stmp);
  end;    // while
  FHostBlock := '';
end;
{$ELSE}
var
  utf8Bytes: TBytes;
  envStr: string;
  position: Integer;
  len: Integer;
  lossless: boolean;
begin
  if FLoaded then
    exit;
  FLoaded := True;
  position := 0;
  while position < Length(FHostBlock) do
  begin
    len := 0;
    while FHostBlock[position + len] <> 0 do
      Inc(len);
    SetLength(utf8Bytes, len);
    if len > 0 then
      Move(FHostBlock[position], utf8Bytes[0], len);
    Inc(position, len + 1);
    // Not TEncoding.UTF8.GetString: it raises on a value that is not valid
    // UTF-8, and environment values are arbitrary bytes.
    envStr := DecodeEnvironEntry(utf8Bytes, lossless);
    if Trim(envStr) <> '' then
    begin
      if lossless then
        FVariables.Add(envStr)
      else
      begin
        SetLength(FRawEntries, Length(FRawEntries) + 1);
        FRawEntries[High(FRawEntries)] := utf8Bytes;
        FVariables.AddObject(envStr, TObject(NativeInt(Length(FRawEntries))));
      end;
    end;
  end;
  FHostBlock := nil;
end;
{$ENDIF}

function TEnvironmentBuilder.Remove(const name: string) : IEnvironmentBuilder;
var
  idx : integer;
begin
  result := Self;
  EnsureLoaded;
  idx := IndexOfVariable(FVariables, name);
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
  // Nothing of the host environment is wanted any more.
  FLoaded := True;
  SetLength(FHostBlock, 0);
  FChanged := true;
  FUserModified := True;
end;

function TEnvironmentBuilder.TryGetValue(const name : string; out value : string) : boolean;
var
  idx : integer;
begin
  EnsureLoaded;
  idx := IndexOfVariable(FVariables, name);
  result := idx <> -1;
  if result then
    value := FVariables.ValueFromIndex[idx]
  else
    value := '';
end;

function TEnvironmentBuilder.Exists(const name : string) : boolean;
begin
  EnsureLoaded;
  // IndexOfVariable never matches an empty name, so Windows drive entries
  // such as "=C:=C:\dir" are not found.
  result := IndexOfVariable(FVariables, name) <> -1;
end;

function TEnvironmentBuilder.ToString: string;
begin
  EnsureLoaded;
  result := FVariables.Text;
end;

function TEnvironmentBuilder.ToEnvironArray: TArray<PAnsiChar>;
var
  i, j: Integer;
  utf8Bytes: TBytes;
  len: Integer;
  {$IFNDEF MSWINDOWS}
  rawIndex: NativeInt;
  {$ENDIF}
begin
  EnsureLoaded;
  SetLength(result, FVariables.Count + 1);
  // Pre-nil every slot so that on an exception in the loop below we can
  // free only the ones we actually allocated, without reading garbage.
  for i := 0 to High(result) do
    result[i] := nil;

  try
    for i := 0 to FVariables.Count - 1 do
    begin
      {$IFNDEF MSWINDOWS}
      rawIndex := NativeInt(FVariables.Objects[i]);
      if rawIndex > 0 then
        utf8Bytes := FRawEntries[rawIndex - 1]
      else
      {$ENDIF}
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
