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

// True when the command line asked for a helper mode (which has then run).
function RunTestHelperMode : boolean;

// The command line that runs this exe in a helper mode.
function HelperCommandLine(const mode : string; const args : array of string) : string;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils;

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

{$IFDEF MSWINDOWS}
const
  CREATE_BREAKAWAY_FROM_JOB = $01000000;

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
{$ENDIF}

function RunTestHelperMode : boolean;
var
  mode : string;
begin
  result := Copy(ParamStr(1), 1, Length(cHelperSwitch)) = cHelperSwitch;
  if not result then
    Exit;
  mode := Copy(ParamStr(1), Length(cHelperSwitch) + 1, MaxInt);
  {$IFDEF MSWINDOWS}
  if mode = 'breakaway-child' then
    BreakawayChild
  else if mode = 'in-job-then-breakaway' then
    InJobThenBreakaway
  else if mode = 'spawn-n' then
    SpawnN
  else if mode = 'spawn-loop' then
    SpawnLoop
  else if mode = 'stdin-type' then
    StdInType
  else
  {$ENDIF}
  begin
    Writeln('Unknown helper mode: ' + mode);
    ExitCode := 2;
  end;
end;

end.
