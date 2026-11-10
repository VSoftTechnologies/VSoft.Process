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
    // % and ! expand variables inside quotes, a " ends the quoted region,
    // CR / LF end the command and a NUL ends the command line itself (the
    // closing quotes after it are lost).
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
    {$IFDEF MSWINDOWS}
    { Ends the process tree of processId, whose handle the caller holds in
      rootHandle (PROCESS_TERMINATE and SYNCHRONIZE access; it also keeps the
      id from being reused). Every descendant is found and opened before
      anything is ended. Then jobHandle is terminated (when not 0), then the
      descendants, deepest first, then the root: the tree is walked with a
      job too, because a job does not hold a program started with
      CREATE_BREAKAWAY_FROM_JOB. Finally waits up to waitMs, in all, for
      every one of them to have gone. }
    class procedure TerminateProcessTreeAndWait(processId : Cardinal; rootHandle : THandle; jobHandle : THandle;
                                                exitCode : Cardinal; waitMs : Cardinal); static;
    {$ENDIF}
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
  , System.Diagnostics
  , WinApi.Windows
  , WinApi.TlHelp32
  , VSoft.Process.WinAPI
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

// Removes one pair of quote characters that wraps the whole value, but only
// when the value holds no other quote of that kind: in "a" b "c" the outer
// quotes are part of the data.
function StripWrapperQuotes(const value : string; const quote : Char) : string;
var
  len : integer;
begin
  len := Length(value);
  if (len >= 2) and (value[1] = quote) and (value[len] = quote) and (Pos(quote, Copy(value, 2, len - 2)) = 0) then
    result := Copy(value, 2, len - 2)
  else
    result := value;
end;

// True when CommandLineToArgvW would split or mangle the value (whitespace,
// embedded double quotes) or drop it (empty) unless it is quoted.
function NeedsWindowsQuoting(const value : string) : boolean;
var
  i : integer;
begin
  result := value = '';
  for i := 1 to Length(value) do
    if (value[i] = ' ') or (value[i] = #9) or (value[i] = '"') then
      Exit(True);
end;

class function TStringUtils.DoubleQuoteString(const value: string; const checkString: boolean): string;
begin
  // A value the caller wrapped in one plain pair of quotes is taken as
  // already quoted, for back-compat - some callers wrap their values in
  // quotes manually and expect DoubleQuoteString to be a no-op. Quotes that
  // are part of the data ("a" b "c") are kept and escaped.
  result := StripWrapperQuotes(value, '"');

  // Auto mode: only quote when CommandLineToArgvW would otherwise split
  // or mangle the value (whitespace, embedded quotes) or drop it (empty).
  if checkString and (not NeedsWindowsQuoting(result)) then
    Exit;

  // Always escape when wrapping: a value ending in a backslash would
  // otherwise escape the closing quote.
  result := EscapeForWindowsCommandLine(result);
end;

class function TStringUtils.IsBatchFile(const fileName : string) : boolean;
var
  len : integer;
  ext : string;
begin
  // Windows ignores trailing dots and spaces in a file name, so 'run.cmd. '
  // opens run.cmd and CreateProcess runs it through cmd.exe.
  len := Length(fileName);
  while (len > 0) and ((fileName[len] = '.') or (fileName[len] = ' ')) do
    Dec(len);
  ext := LowerCase(ExtractFileExt(Copy(fileName, 1, len)));
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
      '%', '!', '"', #13, #10, #0 :
        Exit(True);
    end;
end;

class function TStringUtils.QuoteString(const value: string; const checkString: boolean): string;
begin
  result := StripWrapperQuotes(value, '''');
  if checkString and (not NeedsWindowsQuoting(result)) then
    Exit;
  result := '''' + result + '''';
  // Single quotes do not group for CommandLineToArgvW: when the text holds a
  // space, tab or ", pass the single-quoted text to the child as ONE
  // argument, escaped like any double-quoted value.
  if NeedsWindowsQuoting(result) then
    result := EscapeForWindowsCommandLine(result);
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

type
  // One process of a tree being ended.
  TTreeMember = record
    ProcessId : DWORD;
    // 0 for a process we may not end: it is only followed, to reach the
    // processes it started.
    Handle : THandle;
    Created : Int64;
  end;

class function TSystemUtils.CanTerminateTree(processId : Cardinal) : boolean;
begin
  result := (processId <> 0) and (processId <> cSystemProcessId) and
            (processId <> GetCurrentProcessId);
end;

function ReadCreationTime(hProcess : THandle) : Int64;
var
  createdAt, exitedAt, kernelTime, userTime : TFileTime;
begin
  result := 0;
  if GetProcessTimes(hProcess, createdAt, exitedAt, kernelTime, userTime) then
    result := Int64(createdAt.dwHighDateTime) shl 32 or createdAt.dwLowDateTime;
end;

function OpenForKill(processId : DWORD; out creationTime : Int64) : THandle;
var
  hQuery : THandle;
begin
  creationTime := 0;
  result := OpenProcess(PROCESS_TERMINATE or SYNCHRONIZE or cProcessQueryLimitedInformation, False, processId);
  if result <> 0 then
  begin
    creationTime := ReadCreationTime(result);
    Exit;
  end;
  // Pre-Vista or restricted: terminate rights without the creation time.
  result := OpenProcess(PROCESS_TERMINATE or SYNCHRONIZE, False, processId);
  if result = 0 then
    result := OpenProcess(PROCESS_TERMINATE, False, processId);
  if result <> 0 then
    Exit;
  // A process we may not terminate: query rights alone, so its creation
  // time can still vouch for it as the parent of processes we can kill.
  hQuery := OpenProcess(cProcessQueryLimitedInformation, False, processId);
  if hQuery <> 0 then
  begin
    creationTime := ReadCreationTime(hQuery);
    CloseHandle(hQuery);
  end;
end;

{ Finds and opens the live descendants of the root, a parent always before
  its children.

  The parent/child map comes from a single Toolhelp snapshot. Parent ids in
  the snapshot are stale once a parent exits and Windows recycles pids
  quickly, so a process is only treated as a child when it was created after
  its supposed parent (a recycled pid always belongs to a newer process).
  The handles kept open stop the ids found from being reused until the tree
  has been ended. False when no snapshot could be taken. }
function CollectDescendants(rootId : DWORD; rootCreated : Int64; members : TList<TTreeMember>) : boolean;
var
  hSnapshot : THandle;
  children : TObjectDictionary<DWORD, TList<DWORD>>;
  visited : TDictionary<DWORD, Boolean>;
  processInfo : PROCESSENTRY32;
  res : boolean;
  childList : TList<DWORD>;
  index : integer;
  i : integer;
  parentId : DWORD;
  parentCreated : Int64;
  childId : DWORD;
  childHandle : THandle;
  childCreated : Int64;
  member : TTreeMember;
begin
  hSnapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if hSnapshot = INVALID_HANDLE_VALUE then
    Exit(false);
  result := true;
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

    visited.AddOrSetValue(rootId, True);
    // -1 is the root, then each process found, in the order found.
    index := -1;
    while index < members.Count do
    begin
      if index < 0 then
      begin
        parentId := rootId;
        parentCreated := rootCreated;
      end
      else
      begin
        parentId := members[index].ProcessId;
        parentCreated := members[index].Created;
      end;
      Inc(index);
      if not children.TryGetValue(parentId, childList) then
        Continue;
      for i := 0 to childList.Count - 1 do
      begin
        childId := childList[i];
        if visited.ContainsKey(childId) or (not TSystemUtils.CanTerminateTree(childId)) then
          Continue;
        childHandle := OpenForKill(childId, childCreated);
        // A child we may not terminate is only followed when both creation
        // times are known, so a recycled parent id is never followed: leave
        // it and its descendants alone otherwise.
        if (childHandle = 0) and ((childCreated = 0) or (parentCreated = 0)) then
          Continue;
        // Recycled parent id: this process was never a descendant.
        if (parentCreated <> 0) and (childCreated <> 0) and (childCreated < parentCreated) then
        begin
          if childHandle <> 0 then
            CloseHandle(childHandle);
          Continue;
        end;
        visited.AddOrSetValue(childId, True);
        member.ProcessId := childId;
        member.Handle := childHandle;
        member.Created := childCreated;
        members.Add(member);
      end;
    end;
  finally
    visited.Free;
    children.Free;
  end;
end;

// The descendants deepest first (members lists a parent before its
// children), then the root.
procedure EndTree(rootHandle : THandle; members : TList<TTreeMember>; exitCode : Cardinal);
var
  i : integer;
begin
  for i := members.Count - 1 downto 0 do
    if members[i].Handle <> 0 then
      TerminateProcess(members[i].Handle, exitCode);
  TerminateProcess(rootHandle, exitCode);
end;

procedure CloseMembers(members : TList<TTreeMember>);
var
  i : integer;
begin
  for i := 0 to members.Count - 1 do
    if members[i].Handle <> 0 then
      CloseHandle(members[i].Handle);
  members.Clear;
end;

{ Kills the process and its descendants, deepest first. }
class function TSystemUtils.TerminateProcessTree(parentProcessId: Cardinal; termExitCode: Cardinal; rootHandle : THandle): Cardinal;
var
  ownHandle : THandle;
  rootCreated : Int64;
  members : TList<TTreeMember>;
begin
  result := termExitCode;
  if not CanTerminateTree(parentProcessId) then
    Exit;

  rootCreated := 0;
  ownHandle := 0;
  if rootHandle <> 0 then
    rootCreated := ReadCreationTime(rootHandle)
  else
  begin
    ownHandle := OpenForKill(parentProcessId, rootCreated);
    if ownHandle = 0 then
      Exit;
    rootHandle := ownHandle;
  end;
  members := TList<TTreeMember>.Create;
  try
    // Without a snapshot only the root is killed.
    CollectDescendants(parentProcessId, rootCreated, members);
    EndTree(rootHandle, members, termExitCode);
  finally
    CloseMembers(members);
    members.Free;
    if ownHandle <> 0 then
      CloseHandle(ownHandle);
  end;
end;

class procedure TSystemUtils.TerminateProcessTreeAndWait(processId : Cardinal; rootHandle : THandle; jobHandle : THandle;
                                                         exitCode : Cardinal; waitMs : Cardinal);
var
  members : TList<TTreeMember>;
  clock : TStopwatch;
  elapsed : Int64;
  i : integer;
begin
  members := TList<TTreeMember>.Create;
  try
    // Found and opened before anything is ended: once a process has gone,
    // nothing in the snapshot links what it started to the tree.
    if CanTerminateTree(processId) then
      CollectDescendants(processId, ReadCreationTime(rootHandle), members);
    if jobHandle <> 0 then
      VProcTerminateJobObject(jobHandle, exitCode);
    EndTree(rootHandle, members, exitCode);
    if waitMs > 0 then
    begin
      clock := TStopwatch.StartNew;
      WaitForSingleObject(rootHandle, waitMs);
      for i := 0 to members.Count - 1 do
      begin
        if members[i].Handle = 0 then
          Continue;
        elapsed := clock.ElapsedMilliseconds;
        if elapsed >= waitMs then
          Break;
        WaitForSingleObject(members[i].Handle, DWORD(waitMs - elapsed));
      end;
    end;
  finally
    CloseMembers(members);
    members.Free;
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
