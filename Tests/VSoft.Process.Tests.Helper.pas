unit VSoft.Process.Tests.Helper;

interface

// The test exe doubles as a child process for tests that need one to do what
// a script can't (CREATE_BREAKAWAY_FROM_JOB, many children at once, report
// the type of its stdin). Started as
//   VSoft.Process.Tests.exe --vsp-helper=<mode> [args]
// it runs the mode instead of the tests. Modes (Windows only):
//   breakaway-child <secs>       starts ping (<secs> seconds) with
//                                CREATE_BREAKAWAY_FROM_JOB, prints PID=<pid>,
//                                then sleeps <secs>. Prints
//                                BREAKAWAY-FAILED=<error> and exits 3 when
//                                breakaway is refused.
//   in-job-then-breakaway <secs> starts itself in breakaway-child mode (an
//                                ordinary child, so in our job) sharing its
//                                stdout, then sleeps <secs>.
//   spawn-n <n> <secs>           starts n pings, prints PID=<pid> for each,
//                                then READY, then sleeps <secs>.
//   spawn-loop <threads> <max> <secs>
//                                <threads> threads start pings non-stop, up
//                                to <max> in all; prints SPAWNING once 20
//                                have started, then sleeps <secs>.
//   stdin-type                   prints STDIN-TYPE=<GetFileType of stdin>.
//   console-check <file>         writes "yes" to <file> when it has a
//                                console (CONOUT$ opens), "no" otherwise. A
//                                cmd test (echo x > CON || ...) can't do it:
//                                without a console cmd drops the rest of the
//                                line when the redirection fails.
//   child-info <file or -> [args] reports what this process was given as
//                                KEY=value lines, to the file or to stdout
//                                (-): priority class, affinity mask, show
//                                window, std handle types, console, job,
//                                working directory, VSP_TEST_ENV and the
//                                arguments after the target. Text values are
//                                UTF-16 code units in hex.
//   exit-code <n>                exits with the 32-bit exit code n.
//   cat                          copies stdin to stdout byte for byte.
//   detach-in-job <file> <child file>
//                                puts itself in a job that does not allow
//                                breakaway, starts child-info <child file>
//                                with ExecuteDetached and reports the result
//                                to <file>.
//   spawn-orphan <secs>          starts ping (<secs> seconds) with our std
//                                handles and no console, prints PID=<pid> and
//                                exits: the ping is left holding our stdout
//                                with no live parent.

uses
  VSoft.Process;

// True when the command line asked for a helper mode (which has then run).
function RunTestHelperMode : boolean;

// The command line that runs this exe in a helper mode.
function HelperCommandLine(const mode : string; const args : array of string) : string;

// Configures proc to run a program that copies its stdin to its stdout byte
// for byte: this exe's cat mode on Windows, /bin/cat elsewhere.
procedure SetupCatChild(const proc : IProcess);

{$IFDEF MSWINDOWS}
type
  // What a child-info (or detach-in-job) helper reported.
  IChildReport = interface
    // The value of key, '' when it was not reported.
    function Value(const key : string) : string;
    // A value the helper wrote as UTF-16 code units in hex.
    function Text(const key : string) : string;
    // A decimal value, -1 when it was not reported or is not a number.
    function Number(const key : string) : Int64;
    // Everything reported, for failure messages.
    function Raw : string;
  end;

// Configures proc to run this exe in child-info mode, reporting to target (a
// file name, or '-' for stdout). Arguments added to proc.CommandLine
// afterwards are reported as ARG1..ARGn.
procedure SetupChildInfo(const proc : IProcess; const target : string);

function ParseChildReport(const reportText : string) : IChildReport;

// The report a helper wrote to fileName, waiting up to timeoutMs for the
// file to appear. nil when it never did.
function WaitForChildReport(const fileName : string; timeoutMs : Cardinal) : IChildReport;
{$ENDIF}

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  VSoft.Process.Tests.Review.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  VSoft.Process.Tests.Review.Core;

const
  cHelperSwitch = '--vsp-helper=';

function HelperCommandLine(const mode : string; const args : array of string) : string;
var
  i : integer;
begin
  result := cHelperSwitch + mode;
  for i := 0 to High(args) do
    result := result + ' ' + args[i];
end;

procedure SetupCatChild(const proc : IProcess);
begin
  {$IFDEF MSWINDOWS}
  proc.StartInfo.Executable := ParamStr(0);
  proc.CommandLine.Add(HelperCommandLine('cat', []));
  {$ELSE}
  proc.StartInfo.Executable := '/bin/cat';
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
const
  CREATE_BREAKAWAY_FROM_JOB = $01000000;

type
  THelperArgv = array[0..(MaxInt div SizeOf(PWideChar)) - 1] of PWideChar;
  PHelperArgv = ^THelperArgv;

function HelperCommandLineToArgv(commandLine : PWideChar; var argCount : Integer) : PHelperArgv; stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
function HelperCreateJobObject(attributes : Pointer; name : PWideChar) : THandle; stdcall; external kernel32 name 'CreateJobObjectW';
function HelperAssignProcessToJobObject(job : THandle; process : THandle) : BOOL; stdcall; external kernel32 name 'AssignProcessToJobObject';
function HelperIsProcessInJob(process : THandle; job : THandle; out inJob : BOOL) : BOOL; stdcall; external kernel32 name 'IsProcessInJob';
function HelperGetConsoleWindow : HWND; stdcall; external kernel32 name 'GetConsoleWindow';

var
  GStarted : Integer;
  GMaxStarts : Integer;
  GSeconds : Integer;

function PingCommand(secs : integer) : string;
begin
  result := '"' + IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) + 'System32\ping.exe" -n ' +
            IntToStr(secs) + ' 127.0.0.1';
end;

// Starts commandLine. With shareStdHandles the child gets our std handles
// (inherited); otherwise it gets none at all (without STARTF_USESTDHANDLES
// Windows would hand a console child our std handles, and our stdout is the
// test's pipe).
function StartChild(const commandLine : string; flags : DWORD; shareStdHandles : boolean; out pid : Cardinal; out error : DWORD) : boolean;
var
  startup : TStartupInfo;
  info : TProcessInformation;
  command : string;
begin
  pid := 0;
  error := 0;
  ZeroMemory(@startup, SizeOf(startup));
  startup.cb := SizeOf(startup);
  startup.dwFlags := STARTF_USESTDHANDLES;
  if shareStdHandles then
  begin
    startup.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput := GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  end;
  command := commandLine;
  UniqueString(command);
  result := CreateProcess(nil, PChar(command), nil, nil, shareStdHandles, flags, nil, nil, startup, info);
  if result then
  begin
    pid := info.dwProcessId;
    CloseHandle(info.hThread);
    CloseHandle(info.hProcess);
  end
  else
    error := GetLastError;
end;

procedure Say(const text : string);
begin
  Writeln(text);
  Flush(Output);
end;

function ArgInt(index : integer; default : integer) : integer;
begin
  result := StrToIntDef(ParamStr(index), default);
end;

procedure BreakawayChild;
var
  secs : integer;
  pid : Cardinal;
  error : DWORD;
begin
  secs := ArgInt(2, 60);
  if not StartChild(PingCommand(secs), CREATE_BREAKAWAY_FROM_JOB, false, pid, error) then
  begin
    Say('BREAKAWAY-FAILED=' + IntToStr(error));
    ExitCode := 3;
    Exit;
  end;
  Say('PID=' + IntToStr(pid));
  Sleep(Cardinal(secs) * 1000);
end;

procedure InJobThenBreakaway;
var
  secs : integer;
  pid : Cardinal;
  error : DWORD;
begin
  secs := ArgInt(2, 60);
  if not StartChild('"' + ParamStr(0) + '" ' + HelperCommandLine('breakaway-child', [IntToStr(secs)]), 0, true, pid, error) then
  begin
    Say('START-FAILED=' + IntToStr(error));
    ExitCode := 3;
    Exit;
  end;
  Say('MIDDLE=' + IntToStr(pid));
  Sleep(Cardinal(secs) * 1000);
end;

procedure SpawnN;
var
  i : integer;
  count : integer;
  secs : integer;
  pid : Cardinal;
  error : DWORD;
begin
  count := ArgInt(2, 10);
  secs := ArgInt(3, 60);
  for i := 1 to count do
  begin
    if StartChild(PingCommand(secs), 0, false, pid, error) then
      Say('PID=' + IntToStr(pid))
    else
      Say('START-FAILED=' + IntToStr(error));
  end;
  Say('READY');
  Sleep(Cardinal(secs) * 1000);
end;

procedure SpawnOrphan;
var
  pid : Cardinal;
  error : DWORD;
begin
  // No console (DETACHED_PROCESS): the ping must not end with the console
  // we were given.
  if StartChild(PingCommand(ArgInt(2, 30)), DETACHED_PROCESS, true, pid, error) then
    Say('PID=' + IntToStr(pid))
  else
  begin
    Say('START-FAILED=' + IntToStr(error));
    ExitCode := 3;
  end;
end;

function SpawnLoopThread(parameter : Pointer) : Integer;
var
  pid : Cardinal;
  error : DWORD;
begin
  result := 0;
  while InterlockedIncrement(GStarted) <= GMaxStarts do
    StartChild(PingCommand(GSeconds), 0, false, pid, error);
end;

procedure SpawnLoop;
var
  threads : integer;
  i : integer;
  threadId : TThreadID;
begin
  threads := ArgInt(2, 4);
  GMaxStarts := ArgInt(3, 200);
  GSeconds := ArgInt(4, 30);
  GStarted := 0;
  for i := 1 to threads do
    CloseHandle(BeginThread(nil, 0, @SpawnLoopThread, nil, 0, threadId));
  while GStarted < 20 do
    Sleep(5);
  Say('SPAWNING');
  Sleep(Cardinal(GSeconds) * 1000);
end;

procedure StdInType;
begin
  Say('STDIN-TYPE=' + IntToStr(GetFileType(GetStdHandle(STD_INPUT_HANDLE))));
end;

procedure ConsoleCheck;
var
  console : THandle;
  answer : RawByteString;
  fs : TFileStream;
begin
  console := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if console <> INVALID_HANDLE_VALUE then
  begin
    answer := 'yes';
    CloseHandle(console);
  end
  else
    answer := 'no';
  fs := TFileStream.Create(ParamStr(2), fmCreate);
  try
    fs.WriteBuffer(answer[1], Length(answer));
  finally
    fs.Free;
  end;
end;

function HexOfText(const value : string) : string;
var
  i : integer;
begin
  result := '';
  for i := 1 to Length(value) do
    result := result + IntToHex(Ord(value[i]), 4);
end;

function TextOfHex(const hex : string) : string;
var
  i : integer;
begin
  SetLength(result, Length(hex) div 4);
  for i := 1 to Length(result) do
    result[i] := Char(StrToInt('$' + Copy(hex, (i - 1) * 4 + 1, 4)));
end;

type
  TChildReport = class(TInterfacedObject, IChildReport)
  private
    FLines : TStringList;
  protected
    function Value(const key : string) : string;
    function Text(const key : string) : string;
    function Number(const key : string) : Int64;
    function Raw : string;
  public
    constructor Create(const reportText : string);
    destructor Destroy; override;
  end;

constructor TChildReport.Create(const reportText : string);
begin
  inherited Create;
  FLines := TStringList.Create;
  FLines.Text := reportText;
end;

destructor TChildReport.Destroy;
begin
  FLines.Free;
  inherited;
end;

function TChildReport.Value(const key : string) : string;
begin
  result := FLines.Values[key];
end;

function TChildReport.Text(const key : string) : string;
begin
  result := TextOfHex(Value(key));
end;

function TChildReport.Number(const key : string) : Int64;
begin
  result := StrToInt64Def(Value(key), -1);
end;

function TChildReport.Raw : string;
begin
  result := FLines.Text;
end;

procedure SetupChildInfo(const proc : IProcess; const target : string);
begin
  proc.StartInfo.Executable := ParamStr(0);
  proc.CommandLine.Add(cHelperSwitch + 'child-info');
  proc.CommandLine.Add(target);
end;

function ParseChildReport(const reportText : string) : IChildReport;
begin
  result := TChildReport.Create(reportText);
end;

function WaitForChildReport(const fileName : string; timeoutMs : Cardinal) : IChildReport;
var
  clock : TStopwatch;
  lines : TStringList;
  attempt : integer;
begin
  result := nil;
  clock := TStopwatch.StartNew;
  while (not FileExists(fileName)) and (clock.ElapsedMilliseconds < timeoutMs) do
    Sleep(25);
  if not FileExists(fileName) then
    Exit;
  lines := TStringList.Create;
  try
    // A virus scanner may still have the new file open.
    for attempt := 1 to 20 do
    begin
      try
        lines.LoadFromFile(fileName, TEncoding.ASCII);
        Break;
      except
        on EFOpenError do
          Sleep(25);
      end;
    end;
    result := TChildReport.Create(lines.Text);
  finally
    lines.Free;
  end;
end;

// To a file through a temporary name, so a reader never sees half a report;
// '-' is stdout.
procedure WriteReport(lines : TStringList; const target : string);
var
  i : integer;
begin
  if target = '-' then
  begin
    for i := 0 to lines.Count - 1 do
      Writeln(lines[i]);
    Flush(Output);
    Exit;
  end;
  lines.SaveToFile(target + '.tmp', TEncoding.ASCII);
  if not RenameFile(target + '.tmp', target) then
    ExitCode := 4;
end;

function StdKind(stdHandle : DWORD) : string;
var
  handle : THandle;
  mode : DWORD;
begin
  handle := GetStdHandle(stdHandle);
  if (handle = 0) or (handle = INVALID_HANDLE_VALUE) then
    Exit('none');
  case GetFileType(handle) of
    FILE_TYPE_PIPE : result := 'pipe';
    FILE_TYPE_DISK : result := 'disk';
    FILE_TYPE_CHAR :
      begin
        // NUL is a character device too, but not a console.
        if GetConsoleMode(handle, mode) then
          result := 'console'
        else
          result := 'nul';
      end;
  else
    result := 'other';
  end;
end;

procedure ChildInfo;
var
  lines : TStringList;
  startup : TStartupInfo;
  processMask : DWORD_PTR;
  systemMask : DWORD_PTR;
  inJob : BOOL;
  console : THandle;
  argv : PHelperArgv;
  argCount : Integer;
  i : integer;
begin
  lines := TStringList.Create;
  try
    lines.Add('PRIORITY=' + IntToStr(GetPriorityClass(GetCurrentProcess)));
    if GetProcessAffinityMask(GetCurrentProcess, processMask, systemMask) then
      lines.Add('AFFINITY=' + IntToHex(Int64(processMask), 1));
    ZeroMemory(@startup, SizeOf(startup));
    startup.cb := SizeOf(startup);
    GetStartupInfo(startup);
    lines.Add('SHOWWINDOW=' + IntToStr(startup.wShowWindow));
    lines.Add('STARTFLAGS=' + IntToStr(startup.dwFlags));
    lines.Add('STDIN=' + StdKind(STD_INPUT_HANDLE));
    lines.Add('STDOUT=' + StdKind(STD_OUTPUT_HANDLE));
    lines.Add('STDERR=' + StdKind(STD_ERROR_HANDLE));
    console := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    if console <> INVALID_HANDLE_VALUE then
    begin
      lines.Add('CONSOLE=yes');
      CloseHandle(console);
    end
    else
      lines.Add('CONSOLE=no');
    lines.Add('CONSOLEWND=' + IntToStr(Int64(HelperGetConsoleWindow)));
    if HelperIsProcessInJob(GetCurrentProcess, 0, inJob) and inJob then
      lines.Add('INJOB=yes')
    else
      lines.Add('INJOB=no');
    lines.Add('CWD=' + HexOfText(GetCurrentDir));
    lines.Add('ENV=' + HexOfText(GetEnvironmentVariable('VSP_TEST_ENV')));
    // As CommandLineToArgvW splits it, which is what the library quotes for.
    // 0 is the exe, 1 the helper switch, 2 the report target.
    argCount := 0;
    argv := HelperCommandLineToArgv(GetCommandLineW, argCount);
    if argv <> nil then
    begin
      if argCount > 3 then
        lines.Add('ARGC=' + IntToStr(argCount - 3))
      else
        lines.Add('ARGC=0');
      for i := 3 to argCount - 1 do
        lines.Add('ARG' + IntToStr(i - 2) + '=' + HexOfText(argv^[i]));
      LocalFree(HLOCAL(argv));
    end;
    WriteReport(lines, ParamStr(2));
  finally
    lines.Free;
  end;
end;

procedure ExitWithCode;
begin
  ExitProcess(Cardinal(StrToInt64Def(ParamStr(2), 0)));
end;

procedure Cat;
var
  input : THandle;
  output : THandle;
  buffer : array[0..65535] of Byte;
  bytesRead : DWORD;
  bytesWritten : DWORD;
  offset : DWORD;
begin
  input := GetStdHandle(STD_INPUT_HANDLE);
  output := GetStdHandle(STD_OUTPUT_HANDLE);
  while ReadFile(input, buffer, SizeOf(buffer), bytesRead, nil) and (bytesRead > 0) do
  begin
    offset := 0;
    while offset < bytesRead do
    begin
      if not WriteFile(output, buffer[offset], bytesRead - offset, bytesWritten, nil) then
        Exit;
      Inc(offset, bytesWritten);
    end;
  end;
end;

procedure DetachInJob;
var
  lines : TStringList;
  job : THandle;
  proc : IProcess;
  pid : Cardinal;
  error : DWORD;
begin
  lines := TStringList.Create;
  try
    // A job with no limit flags does not allow breakaway.
    job := HelperCreateJobObject(nil, nil);
    if (job = 0) or (not HelperAssignProcessToJobObject(job, GetCurrentProcess)) then
      lines.Add('JOB-FAILED=' + IntToStr(GetLastError))
    else
    begin
      // What the library's first attempt does. It has to be refused here for
      // the retry inside the job to be what launched the child.
      if StartChild(PingCommand(1), CREATE_BREAKAWAY_FROM_JOB, false, pid, error) then
        lines.Add('CONTROL=0')
      else
        lines.Add('CONTROL=' + IntToStr(error));
      proc := TProcess.Create;
      SetupChildInfo(proc, ParamStr(3));
      if proc.ExecuteDetached then
        lines.Add('LAUNCHED=yes')
      else
        lines.Add('LAUNCHED=no');
      lines.Add('LASTERROR=' + IntToStr(proc.LastError));
      lines.Add('ERRORS=' + HexOfText(Trim(proc.Errors.Text)));
    end;
    WriteReport(lines, ParamStr(2));
  finally
    lines.Free;
  end;
end;
{$ENDIF}

function RunTestHelperMode : boolean;
var
  mode : string;
begin
  result := Copy(ParamStr(1), 1, Length(cHelperSwitch)) = cHelperSwitch;
  if not result then
    Exit;
  mode := Copy(ParamStr(1), Length(cHelperSwitch) + 1, MaxInt);
  if mode = 'review-core-sync-synchronize' then
    RunReviewCoreSyncSynchronizeHelper
  else
  {$IFDEF MSWINDOWS}
  if ReviewWindowsHelper(mode) then
    Exit
  else if mode = 'breakaway-child' then
    BreakawayChild
  else if mode = 'in-job-then-breakaway' then
    InJobThenBreakaway
  else if mode = 'spawn-n' then
    SpawnN
  else if mode = 'spawn-orphan' then
    SpawnOrphan
  else if mode = 'spawn-loop' then
    SpawnLoop
  else if mode = 'stdin-type' then
    StdInType
  else if mode = 'console-check' then
    ConsoleCheck
  else if mode = 'child-info' then
    ChildInfo
  else if mode = 'exit-code' then
    ExitWithCode
  else if mode = 'cat' then
    Cat
  else if mode = 'detach-in-job' then
    DetachInJob
  else
  {$ENDIF}
  begin
    Writeln('Unknown helper mode: ' + mode);
    ExitCode := 2;
  end;
end;

end.
