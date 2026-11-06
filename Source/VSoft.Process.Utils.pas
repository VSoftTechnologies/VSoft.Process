{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright © Vincent Parrett and contributors                    }
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

unit VSoft.Process.Utils;

interface

// Shared utility types. TStringUtils is platform-agnostic; TSystemUtils
// has an IFDEF'd Windows / POSIX implementation in this same unit so the
// public API is unified and consumers (and Delphi .dpk files) don't need
// platform-conditional uses clauses.

type
  TStringUtils = record
    class function StripQuotes(const value : string) : string;static;
    class function QuoteString(const value: string; const checkString: boolean = True): string;static;
    class function DoubleQuoteString(const value: string; const checkString: boolean = True): string;static;

    // Escape `value` per Windows CommandLineToArgvW rules and wrap it in
    // double quotes. Required when `value` may contain embedded `"` or
    // trailing backslashes - simple concatenation would corrupt the
    // argument as parsed by the receiving process.
    class function EscapeForWindowsCommandLine(const value : string) : string; static;

    // True for .bat / .cmd files, which Windows runs through cmd.exe.
    class function IsBatchFile(const fileName : string) : boolean; static;
    // True when cmd.exe would treat part of value as syntax (redirection,
    // command separators, grouping, escapes) or split it into several args.
    class function ContainsCmdMetaChars(const value : string) : boolean; static;
    // True when value cannot be passed to cmd.exe safely at all, even quoted:
    // % and ! expand variables inside quotes, a " ends the quoted region and
    // CR / LF end the command.
    class function ContainsCmdUnsafeChars(const value : string) : boolean; static;
  end;

  TSystemUtils = record
    { Terminates the process identified by parentProcessId and all of its
      descendants. Returns the supplied termExitCode. Does nothing for process
      ids that are never valid tree roots (see CanTerminateTree). On Windows,
      a rootHandle with PROCESS_TERMINATE access (the caller keeps ownership)
      is used for the root instead of opening parentProcessId, for a root
      whose security descriptor denies us OpenProcess. }
    class function TerminateProcessTree(parentProcessId: Cardinal; termExitCode: Cardinal; rootHandle : THandle = 0): Cardinal; static;
    { False for ids that must never be tree-killed: 0, the System process,
      init (1) on POSIX, ids that are negative as a pid_t, and the current
      process. }
    class function CanTerminateTree(processId : Cardinal) : boolean; static;
  end;

implementation

uses
  System.SysUtils
  {$IFDEF MSWINDOWS}
  , System.Generics.Collections
  , WinApi.Windows
  , WinApi.TlHelp32
  {$ENDIF}
  {$IF DEFINED(LINUX) OR DEFINED(MACOS)}
  , Posix.Unistd
  , Posix.Signal
  , Posix.SysWait
  {$IFEND}
  ;

class function TStringUtils.EscapeForWindowsCommandLine(const value : string) : string;
//
// Reference: https://learn.microsoft.com/en-us/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way
//
// Rules (as parsed by CommandLineToArgvW / MSVCRT-style parsers):
//   * 2N  backslashes + "  -> N backslashes + literal " (closes/opens quoted region)
//   * 2N+1 backslashes + "  -> N backslashes + literal " (treated as escaped)
//   * N backslashes not followed by " -> N literal backslashes
//   * Inside a quoted region, "" is also accepted as a literal " by MSVCRT,
//     but the backslash-escape form below works for both MSVCRT and the
//     newer CommandLineToArgvW behaviour.
//
var
  buf : string;
  i, len, backslashCount : integer;
begin
  len := Length(value);
  buf := '"';
  i := 1;
  while i <= len do
  begin
    backslashCount := 0;
    while (i <= len) and (value[i] = '\') do
    begin
      Inc(backslashCount);
      Inc(i);
    end;
    if i > len then
    begin
      // End of string. We're about to write the closing quote, so any
      // trailing backslashes must be doubled so the closer is not eaten.
      buf := buf + StringOfChar('\', backslashCount * 2);
      Break;
    end
    else if value[i] = '"' then
    begin
      // Embedded quote. 2*N+1 backslashes precede it.
      buf := buf + StringOfChar('\', backslashCount * 2 + 1) + '"';
      Inc(i);
    end
    else
    begin
      // Backslashes not followed by a quote keep their literal count.
      buf := buf + StringOfChar('\', backslashCount) + value[i];
      Inc(i);
    end;
  end;
  buf := buf + '"';
  result := buf;
end;

class function TStringUtils.DoubleQuoteString(const value: string; const checkString: boolean): string;
var
  needsQuotes : boolean;
  i : integer;
begin
  // Matched leading/trailing quotes are stripped first for back-compat -
  // some callers wrap their values in quotes manually and expect
  // DoubleQuoteString to be a no-op.
  result := StripQuotes(value);

  if checkString then
  begin
    // Auto mode: only quote when CommandLineToArgvW would otherwise split
    // or mangle the value (whitespace, embedded quotes) or drop it (empty).
    needsQuotes := result = '';
    for i := 1 to Length(result) do
      if (result[i] = ' ') or (result[i] = #9) or (result[i] = '"') then
      begin
        needsQuotes := True;
        Break;
      end;
    if not needsQuotes then
      Exit;
  end;

  // Always escape when wrapping: a value ending in a backslash would
  // otherwise escape the closing quote.
  result := EscapeForWindowsCommandLine(result);
end;

class function TStringUtils.IsBatchFile(const fileName : string) : boolean;
var
  ext : string;
begin
  ext := LowerCase(ExtractFileExt(fileName));
  result := (ext = '.bat') or (ext = '.cmd');
end;

class function TStringUtils.ContainsCmdMetaChars(const value : string) : boolean;
var
  i : integer;
begin
  result := False;
  for i := 1 to Length(value) do
    case value[i] of
      ' ', #9, '&', '|', '<', '>', '^', '(', ')', ',', ';', '=' :
        Exit(True);
    end;
end;

class function TStringUtils.ContainsCmdUnsafeChars(const value : string) : boolean;
var
  i : integer;
begin
  result := False;
  for i := 1 to Length(value) do
    case value[i] of
      '%', '!', '"', #13, #10 :
        Exit(True);
    end;
end;

class function TStringUtils.QuoteString(const value: string; const checkString: boolean): string;
begin
  result := StripQuotes(value);
  if checkString then
  begin
    if (pos(' ', result) > 0) then
      result := '''' + result + '''';
  end
  else
    result := '''' + result + '''';
end;

class function TStringUtils.StripQuotes(const value : string) : string;
var
  len: integer;
begin
  result := value;
  len := Length(Value);
  if len >= 2 then
  begin
    if (Value[1] = Value[len]) then
    begin
      if (Value[1] = '"') or (Value[1] = '''') then
        Result := Copy(value, 2, len - 2);
    end;
  end;
end;

{ TSystemUtils }

{$IFDEF MSWINDOWS}
const
  cProcessQueryLimitedInformation = $1000;
  cSystemProcessId = 4;

class function TSystemUtils.CanTerminateTree(processId : Cardinal) : boolean;
begin
  result := (processId <> 0) and (processId <> cSystemProcessId) and
            (processId <> GetCurrentProcessId);
end;

{ Kills the process and its descendants, deepest first.

  The parent/child map comes from a single Toolhelp snapshot. Parent ids in
  the snapshot are stale once a parent exits and Windows recycles pids
  quickly, so a process is only treated as a child when it was created after
  its supposed parent (a recycled pid always belongs to a newer process).
  A visited set protects against cycles that pid reuse can create. }
class function TSystemUtils.TerminateProcessTree(parentProcessId: Cardinal; termExitCode: Cardinal; rootHandle : THandle): Cardinal;
var
  hSnapshot: THandle;
  children: TObjectDictionary<DWORD, TList<DWORD>>;
  visited : TDictionary<DWORD, Boolean>;
  processInfo: PROCESSENTRY32;
  res: boolean;
  childList: TList<DWORD>;

  function OpenForKill(processId : DWORD; out creationTime : Int64) : THandle;
  var
    createdAt, exitedAt, kernelTime, userTime : TFileTime;
  begin
    creationTime := 0;
    result := OpenProcess(PROCESS_TERMINATE or cProcessQueryLimitedInformation, False, processId);
    if result = 0 then
      // Pre-Vista or restricted: terminate rights alone (no creation time).
      result := OpenProcess(PROCESS_TERMINATE, False, processId)
    else if GetProcessTimes(result, createdAt, exitedAt, kernelTime, userTime) then
      creationTime := Int64(createdAt.dwHighDateTime) shl 32 or createdAt.dwLowDateTime;
  end;

  procedure TerminateRecursive(processId: DWORD; hProcess : THandle; creationTime : Int64);
  var
    localChildren: TList<DWORD>;
    i: Integer;
    childHandle : THandle;
    childCreated : Int64;
  begin
    visited.AddOrSetValue(processId, True);
    if children.TryGetValue(processId, localChildren) then
    begin
      for i := 0 to localChildren.Count - 1 do
      begin
        if visited.ContainsKey(localChildren[i]) or (not CanTerminateTree(localChildren[i])) then
          continue;
        childHandle := OpenForKill(localChildren[i], childCreated);
        if childHandle = 0 then
          continue;
        try
          // Recycled parent id: this process was never our descendant.
          if (creationTime <> 0) and (childCreated <> 0) and (childCreated < creationTime) then
            continue;
          TerminateRecursive(localChildren[i], childHandle, childCreated);
        finally
          CloseHandle(childHandle);
        end;
      end;
    end;
    if hProcess <> 0 then
      TerminateProcess(hProcess, termExitCode);
  end;

var
  ownHandle : THandle;
  rootCreated : Int64;
  createdAt, exitedAt, kernelTime, userTime : TFileTime;
begin
  result := termExitCode;
  if not CanTerminateTree(parentProcessId) then
    Exit;

  rootCreated := 0;
  ownHandle := 0;
  if rootHandle <> 0 then
  begin
    if GetProcessTimes(rootHandle, createdAt, exitedAt, kernelTime, userTime) then
      rootCreated := Int64(createdAt.dwHighDateTime) shl 32 or createdAt.dwLowDateTime;
  end
  else
  begin
    ownHandle := OpenForKill(parentProcessId, rootCreated);
    if ownHandle = 0 then
      Exit;
    rootHandle := ownHandle;
  end;
  try
    hSnapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if hSnapshot = INVALID_HANDLE_VALUE then
    begin
      // No snapshot: we can only kill the root.
      TerminateProcess(rootHandle, termExitCode);
      Exit;
    end;

    children := TObjectDictionary<DWORD, TList<DWORD>>.Create([doOwnsValues]);
    visited := TDictionary<DWORD, Boolean>.Create;
    try
      try
        processInfo.dwSize := SizeOf(PROCESSENTRY32);
        res := Process32First(hSnapshot, processInfo);
        while res do
        begin
          if processInfo.th32ProcessID <> processInfo.th32ParentProcessID then
          begin
            if not children.TryGetValue(processInfo.th32ParentProcessID, childList) then
            begin
              childList := TList<DWORD>.Create;
              children.Add(processInfo.th32ParentProcessID, childList);
            end;
            childList.Add(processInfo.th32ProcessID);
          end;
          res := Process32Next(hSnapshot, processInfo);
        end;
      finally
        CloseHandle(hSnapshot);
      end;

      TerminateRecursive(parentProcessId, rootHandle, rootCreated);
    finally
      visited.Free;
      children.Free;
    end;
  finally
    if ownHandle <> 0 then
      CloseHandle(ownHandle);
  end;
end;
{$ENDIF}

{$IF DEFINED(LINUX) OR DEFINED(MACOS)}
class function TSystemUtils.CanTerminateTree(processId : Cardinal) : boolean;
begin
  // kill(-0, ...) targets our own process group and kill(-1, ...) every
  // process we may signal, so pid 0 / 1 and values that are negative as a
  // pid_t are refused, as is our own pid.
  result := (Integer(processId) > 1) and (Integer(processId) <> getpid);
end;

class function TSystemUtils.TerminateProcessTree(parentProcessId: Cardinal; termExitCode: Cardinal; rootHandle : THandle): Cardinal;
var
  pid : Integer;
  i : integer;
begin
  result := termExitCode;
  if not CanTerminateTree(parentProcessId) then
    Exit;
  pid := Integer(parentProcessId);

  // Signal the process group when pid leads one, otherwise just the process.
  if kill(-pid, SIGTERM) <> 0 then
  begin
    kill(pid, SIGTERM);
    for i := 1 to 25 do
    begin
      if kill(pid, 0) <> 0 then
        Exit;
      Sleep(20);
    end;
    kill(pid, SIGKILL);
    Exit;
  end;
  for i := 1 to 25 do
  begin
    if kill(-pid, 0) <> 0 then
      Exit;
    Sleep(20);
  end;
  kill(-pid, SIGKILL);
  // The caller owns reaping: a waitpid here could steal the exit status of a
  // child another component is waiting for.
end;
{$IFEND}

end.
