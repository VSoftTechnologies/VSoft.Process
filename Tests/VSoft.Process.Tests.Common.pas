unit VSoft.Process.Tests.Common;

interface

// Cross-platform helpers shared by the test fixtures. Everything that differs
// between Windows (cmd.exe + .cmd fixtures) and POSIX (/bin/sh + .sh
// fixtures) lives here so the fixtures themselves compile on every target.

uses
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  TTestHelpers = record
    // Monotonic milliseconds since an arbitrary point (TStopwatch based).
    class function TickMs : Int64; static;
    // Absolute path of the platform shell used to run the fixture scripts.
    class function ShellExePath : string; static;
    // Absolute path of the Tests\scripts folder (searched upward from the exe).
    class function ScriptsDir : string; static;
    // Absolute path of a fixture script with the platform extension.
    class function ScriptPath(const scriptBaseName : string) : string; static;
    // Configure proc to run the named fixture script with args under the
    // platform shell.
    class procedure SetupShellCommand(const proc : IProcess; const scriptBaseName : string; const args : array of string); static;
    // Configure proc to run an inline shell command: `cmd /c <windowsCommand>`
    // on Windows, `/bin/sh -c <posixCommand>` elsewhere.
    class procedure SetupInlineCommand(const proc : IProcess; const windowsCommand : string; const posixCommand : string); static;
    // A unique file name in the temp directory.
    class function TempFileName(const prefix : string; const ext : string) : string; static;
    // Poll until proc leaves Running or timeoutMs elapses. Returns True if
    // the process is no longer running.
    class function WaitWhileRunning(const proc : IProcess; timeoutMs : Cardinal) : boolean; static;
    class procedure SetEnvVar(const name : string; const value : string); static;
    class procedure UnsetEnvVar(const name : string); static;
    class function ReadFileBytes(const fileName : string) : TBytes; static;
    class function CountByte(const bytes : TBytes; value : Byte) : integer; static;
    class function CountChar(const value : string; ch : Char) : integer; static;
    // The value of the first line starting with prefix (the rest of the
    // line), or '' when there is none.
    class function ValueAfter(const lines : TStrings; const prefix : string) : string; static;

    // Watching / killing other processes from a test. A watch is a process
    // handle on Windows (which also stops the id being reused) and the pid on
    // POSIX; 0 means none.
    class function WatchProcess(processId : Cardinal) : NativeUInt; static;
    // True when the watched process is still running delayMs from now.
    class function IsRunningAfter(watch : NativeUInt; delayMs : Cardinal) : boolean; static;
    // True when the watched process has ended within timeoutMs.
    class function HasEndedWithin(watch : NativeUInt; timeoutMs : Cardinal) : boolean; static;
    // Kills the watched process if it is still running and releases the watch.
    class procedure KillWatched(watch : NativeUInt); static;
    // POSIX: "pid ppid pgid state command" from ps, for failure messages.
    // Empty on Windows.
    class function DescribeProcess(processId : Cardinal) : string; static;
    {$IFDEF MSWINDOWS}
    // Builds a `cmd /c` tail: ""<script>" "<arg1>" ..." with embedded quotes
    // doubled per cmd.exe's parsing rules.
    class function BuildSingleCommand(const scriptPath : string; const args : array of string) : string; static;
    // The id of a process whose parent is parentId and whose exe is exeName
    // (0 when there is none).
    class function FindChildProcess(parentId : Cardinal; const exeName : string) : Cardinal; static;
    // Number of handles this process has open.
    class function HandleCount : Cardinal; static;
    {$ENDIF}
  end;

implementation

uses
  System.Diagnostics,
  System.IOUtils,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.TlHelp32;
  {$ELSE}
  Posix.Stdlib,
  Posix.Signal,
  Posix.SysTypes,
  Posix.Unistd;
  {$ENDIF}

{$IFDEF MSWINDOWS}
function GetProcessHandleCount(hProcess : THandle; var pdwHandleCount : DWORD) : BOOL; stdcall; external kernel32 name 'GetProcessHandleCount';
{$ENDIF}

var
  GClock : TStopwatch;
  GScriptsDir : string;

class function TTestHelpers.TickMs : Int64;
begin
  result := GClock.ElapsedMilliseconds;
end;

class function TTestHelpers.ShellExePath : string;
begin
  {$IFDEF MSWINDOWS}
  result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) + 'System32\cmd.exe';
  {$ELSE}
  result := '/bin/sh';
  {$ENDIF}
end;

class function TTestHelpers.ScriptsDir : string;
var
  dir : string;
  candidate : string;
  prev : string;
  probe : string;
begin
  if GScriptsDir <> '' then
    Exit(GScriptsDir);
  {$IFDEF MSWINDOWS}
  probe := 'echo-args.cmd';
  {$ELSE}
  probe := 'echo-args.sh';
  {$ENDIF}
  // The IDE build puts the exe at Tests\<Platform>\<Cfg>\ (or Tests\ for the
  // XE2 layout), so walk upward until a sibling 'scripts' folder appears.
  // ParamStr(0) is relative on macOS when started as ./name.
  dir := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  while dir <> '' do
  begin
    candidate := IncludeTrailingPathDelimiter(dir + 'scripts');
    if DirectoryExists(candidate) and FileExists(candidate + probe) then
    begin
      GScriptsDir := candidate;
      Exit(GScriptsDir);
    end;
    prev := dir;
    dir := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(dir)));
    if dir = prev then
      Break;
  end;
  raise Exception.Create('Test scripts directory not found near ' + ParamStr(0));
end;

class function TTestHelpers.ScriptPath(const scriptBaseName : string) : string;
begin
  {$IFDEF MSWINDOWS}
  result := ScriptsDir + scriptBaseName + '.cmd';
  {$ELSE}
  result := ScriptsDir + scriptBaseName + '.sh';
  {$ENDIF}
end;

class procedure TTestHelpers.SetupShellCommand(const proc : IProcess; const scriptBaseName : string; const args : array of string);
{$IFNDEF MSWINDOWS}
var
  i : integer;
{$ENDIF}
begin
  proc.StartInfo.Executable := ShellExePath;
  {$IFDEF MSWINDOWS}
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add(BuildSingleCommand(ScriptPath(scriptBaseName), args), TQuoted.qtNone);
  {$ELSE}
  // Each Add is a discrete argv slot, so no quoting is needed.
  proc.CommandLine.Add(ScriptPath(scriptBaseName));
  for i := 0 to High(args) do
    proc.CommandLine.Add(args[i]);
  {$ENDIF}
end;

class procedure TTestHelpers.SetupInlineCommand(const proc : IProcess; const windowsCommand : string; const posixCommand : string);
begin
  proc.StartInfo.Executable := ShellExePath;
  {$IFDEF MSWINDOWS}
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add(windowsCommand, TQuoted.qtNone);
  {$ELSE}
  proc.CommandLine.Add('-c');
  proc.CommandLine.Add(posixCommand);
  {$ENDIF}
end;

class function TTestHelpers.TempFileName(const prefix : string; const ext : string) : string;
var
  guid : TGUID;
begin
  CreateGUID(guid);
  result := TPath.Combine(TPath.GetTempPath, prefix + StringReplace(Copy(GUIDToString(guid), 2, 36), '-', '', [rfReplaceAll]) + ext);
end;

class function TTestHelpers.WaitWhileRunning(const proc : IProcess; timeoutMs : Cardinal) : boolean;
var
  deadline : Int64;
begin
  deadline := TickMs + timeoutMs;
  while (proc.Status = TProcessStatus.Running) and (TickMs < deadline) do
    Sleep(10);
  result := proc.Status <> TProcessStatus.Running;
end;

class procedure TTestHelpers.SetEnvVar(const name : string; const value : string);
begin
  {$IFDEF MSWINDOWS}
  SetEnvironmentVariable(PChar(name), PChar(value));
  {$ELSE}
  setenv(PAnsiChar(UTF8Encode(name)), PAnsiChar(UTF8Encode(value)), 1);
  {$ENDIF}
end;

class procedure TTestHelpers.UnsetEnvVar(const name : string);
begin
  {$IFDEF MSWINDOWS}
  SetEnvironmentVariable(PChar(name), nil);
  {$ELSE}
  unsetenv(PAnsiChar(UTF8Encode(name)));
  {$ENDIF}
end;

class function TTestHelpers.ReadFileBytes(const fileName : string) : TBytes;
var
  fs : TFileStream;
begin
  fs := TFileStream.Create(fileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(result, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

class function TTestHelpers.CountByte(const bytes : TBytes; value : Byte) : integer;
var
  i : integer;
begin
  result := 0;
  for i := 0 to High(bytes) do
    if bytes[i] = value then
      Inc(result);
end;

class function TTestHelpers.CountChar(const value : string; ch : Char) : integer;
var
  i : integer;
begin
  result := 0;
  for i := 1 to Length(value) do
    if value[i] = ch then
      Inc(result);
end;

class function TTestHelpers.ValueAfter(const lines : TStrings; const prefix : string) : string;
var
  i : integer;
begin
  result := '';
  for i := 0 to lines.Count - 1 do
    if Copy(lines[i], 1, Length(prefix)) = prefix then
      Exit(Trim(Copy(lines[i], Length(prefix) + 1, MaxInt)));
end;

{$IFDEF MSWINDOWS}
class function TTestHelpers.WatchProcess(processId : Cardinal) : NativeUInt;
begin
  result := 0;
  if processId <> 0 then
    result := OpenProcess(SYNCHRONIZE or PROCESS_TERMINATE, False, processId);
end;

class function TTestHelpers.IsRunningAfter(watch : NativeUInt; delayMs : Cardinal) : boolean;
begin
  result := (watch <> 0) and (WaitForSingleObject(watch, delayMs) = WAIT_TIMEOUT);
end;

class function TTestHelpers.HasEndedWithin(watch : NativeUInt; timeoutMs : Cardinal) : boolean;
begin
  result := (watch = 0) or (WaitForSingleObject(watch, timeoutMs) = WAIT_OBJECT_0);
end;

class procedure TTestHelpers.KillWatched(watch : NativeUInt);
begin
  if watch = 0 then
    Exit;
  if WaitForSingleObject(watch, 0) = WAIT_TIMEOUT then
  begin
    TerminateProcess(watch, 1);
    WaitForSingleObject(watch, 5000);
  end;
  CloseHandle(watch);
end;

class function TTestHelpers.FindChildProcess(parentId : Cardinal; const exeName : string) : Cardinal;
var
  snapshot : THandle;
  entry : TProcessEntry32;
  more : boolean;
begin
  result := 0;
  snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    entry.dwSize := SizeOf(entry);
    more := Process32First(snapshot, entry);
    while more do
    begin
      if (entry.th32ParentProcessID = parentId) and SameText(PChar(@entry.szExeFile[0]), exeName) then
        Exit(entry.th32ProcessID);
      more := Process32Next(snapshot, entry);
    end;
  finally
    CloseHandle(snapshot);
  end;
end;

class function TTestHelpers.HandleCount : Cardinal;
var
  count : DWORD;
begin
  if not GetProcessHandleCount(GetCurrentProcess, count) then
    RaiseLastOSError;
  result := count;
end;
{$ELSE}
class function TTestHelpers.WatchProcess(processId : Cardinal) : NativeUInt;
begin
  result := processId;
end;

class function TTestHelpers.IsRunningAfter(watch : NativeUInt; delayMs : Cardinal) : boolean;
begin
  if watch = 0 then
    Exit(false);
  Sleep(delayMs);
  result := kill(pid_t(watch), 0) = 0;
end;

class function TTestHelpers.HasEndedWithin(watch : NativeUInt; timeoutMs : Cardinal) : boolean;
var
  deadline : Int64;
begin
  if watch = 0 then
    Exit(true);
  deadline := TickMs + timeoutMs;
  repeat
    if kill(pid_t(watch), 0) <> 0 then
      Exit(true);
    Sleep(20);
  until TickMs >= deadline;
  result := false;
end;

class procedure TTestHelpers.KillWatched(watch : NativeUInt);
begin
  if watch <> 0 then
    kill(pid_t(watch), SIGKILL);
end;
{$ENDIF}

class function TTestHelpers.DescribeProcess(processId : Cardinal) : string;
{$IFNDEF MSWINDOWS}
var
  proc : IProcess;
  output : TStringBuilder;
{$ENDIF}
begin
  result := '';
  {$IFNDEF MSWINDOWS}
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := '/bin/ps';
    proc.CommandLine.Add('-o');
    proc.CommandLine.Add('pid=,ppid=,pgid=,stat=,comm=');
    proc.CommandLine.Add('-p');
    proc.CommandLine.Add(IntToStr(processId));
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    proc.Execute;
    result := Trim(output.ToString);
    if result = '' then
      result := '(no such process)';
  finally
    output.Free;
  end;
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
class function TTestHelpers.BuildSingleCommand(const scriptPath : string; const args : array of string) : string;
var
  i : integer;
  inner : string;
begin
  // When cmd.exe sees /c followed by a tail starting with `"` it strips the
  // first and last quote, so the whole tail is wrapped in one extra pair.
  inner := '"' + scriptPath + '"';
  for i := 0 to High(args) do
    inner := inner + ' "' + StringReplace(args[i], '"', '""', [rfReplaceAll]) + '"';
  result := '"' + inner + '"';
end;
{$ENDIF}

initialization
  GClock := TStopwatch.StartNew;

end.
