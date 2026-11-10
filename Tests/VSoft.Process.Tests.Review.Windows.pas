unit VSoft.Process.Tests.Review.Windows;

interface

// Tests for the findings WIN-1 to WIN-5 of docs\CODE_REVIEW_2026-11-10.md
// (Windows implementation). Each test asserts the documented / expected
// behaviour, so a test that fails confirms its finding and passes once the
// library is fixed.
//
// WIN-4 needs the test exe as a child process (helper modes
// review-win-ctrlc and review-win-spawn-ctrlc): RunTestHelperMode has to
// call ReviewWindowsHelper(mode).

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  [TestFixture]
  TReviewWindowsTests = class
  public
    [Setup]
    procedure SetUp;

    // WIN-1: with InheritHostStdHandles a stderr that is not redirected goes
    // where the host's stderr goes, also when that is the host's console.
    // A failure means the child could not use the host's console handle (it
    // is started with a console of its own), so its stderr is lost.
    [Test]
    procedure WIN1_InheritHostStdHandles_ConsoleStdErr_ReachesHostConsole;

    // WIN-2: TimeoutInMSec ends the run with DeliverOnRunThread while the
    // child keeps writing to stdout and stderr. A failure means the timeout
    // never fired (the watchdog had to terminate the child).
    [Test]
    procedure WIN2_DeliverOnRunThread_Timeout_BothStreamsBusy;

    // WIN-3: after a normal exit a slow target gets everything and nothing
    // is reported, however long it takes over the last chunk. A failure
    // means Errors holds the false "Output may be truncated" message.
    [Test]
    procedure WIN3_SlowTarget_ChildExited_NoTruncationError;

    // WIN-4: a program started with ExecuteDetached does not pass "ignore
    // Ctrl+C" on to the console programs it starts. A failure means the
    // grandchild's Ctrl+C handler was never called.
    [Test]
    procedure WIN4_Detached_Default_DoesNotDisableCtrlCForItsChildren;

    // WIN-5: launches on different threads are inside CreateProcess at the
    // same time (the review's recommendation: the handle list already keeps
    // the pipe ends apart). A failure means every launch waited for the
    // previous one's CreateProcess call (GSpawnLock).
    [Test]
    procedure WIN5_ConcurrentLaunches_AreNotSerialised;
  end;

// Runs a review-win-* helper mode of the test exe. False when mode is not
// one of them.
function ReviewWindowsHelper(const mode : string) : boolean;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  VSoft.Process.WinAPI,
  VSoft.Process.Tests.Common;

const
  cHelperSwitch = '--vsp-helper=';
  cModeCtrlC = 'review-win-ctrlc';
  cModeSpawnCtrlC = 'review-win-spawn-ctrlc';
  cDelivered = 'delivered';
  cIgnored = 'ignored';

function ReviewGetConsoleWindow : HWND; stdcall; external kernel32 name 'GetConsoleWindow';

type
  // Sleeps in every HandleData call.
  TReviewSlowTarget = class(TInterfacedObject, IPipeTarget)
  private
    FSleepMs : Cardinal;
    FBytes : Int64;
    FDoneCount : integer;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  public
    constructor Create(sleepMs : Cardinal);
    property Bytes : Int64 read FBytes;
    property DoneCount : integer read FDoneCount;
  end;

  // Terminates the run when it is still going after delayMs, so a test
  // fails instead of hanging the suite.
  TReviewWatchdog = class(TThread)
  private
    FProc : IProcess;
    FDelayMs : Cardinal;
    FCancel : TEvent;
    FFired : boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const proc : IProcess; delayMs : Cardinal);
    destructor Destroy; override;
    procedure Stop;
    property Fired : boolean read FFired;
  end;

  // Runs one short child once the gate opens.
  TReviewLaunchThread = class(TThread)
  private
    FGate : TEvent;
    FStarted : boolean;
    FErrorText : string;
  protected
    procedure Execute; override;
  public
    constructor Create(gate : TEvent);
    property Started : boolean read FStarted;
    property ErrorText : string read FErrorText;
  end;

  TCreateProcessFunc = function(lpApplicationName : PWideChar; lpCommandLine : PWideChar;
                                lpProcessAttributes : PSecurityAttributes; lpThreadAttributes : PSecurityAttributes;
                                bInheritHandles : BOOL; dwCreationFlags : DWORD; lpEnvironment : Pointer;
                                lpCurrentDirectory : PWideChar; lpStartupInfo : Pointer;
                                var lpProcessInformation : TProcessInformation) : BOOL; stdcall;

var
  GCtrlCSeen : Integer;
  GRealCreateProcess : TCreateProcessFunc;
  GHookDelayMs : Cardinal;
  GHookCalls : Integer;
  GInFlight : Integer;
  GMaxInFlight : Integer;

function StatusName(status : TProcessStatus) : string;
begin
  case status of
    TProcessStatus.Idle : result := 'Idle';
    TProcessStatus.Running : result := 'Running';
    TProcessStatus.Exited : result := 'Exited';
    TProcessStatus.Terminated : result := 'Terminated';
    TProcessStatus.TimedOut : result := 'TimedOut';
  else
    result := IntToStr(Ord(status));
  end;
end;

{ TReviewSlowTarget }

constructor TReviewSlowTarget.Create(sleepMs : Cardinal);
begin
  inherited Create;
  FSleepMs := sleepMs;
end;

procedure TReviewSlowTarget.Start;
begin
  FBytes := 0;
  FDoneCount := 0;
end;

procedure TReviewSlowTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  Sleep(FSleepMs);
  Inc(FBytes, Int64(dataLength));
end;

procedure TReviewSlowTarget.Done;
begin
  Inc(FDoneCount);
end;

{ TReviewWatchdog }

constructor TReviewWatchdog.Create(const proc : IProcess; delayMs : Cardinal);
begin
  FProc := proc;
  FDelayMs := delayMs;
  FCancel := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TReviewWatchdog.Destroy;
begin
  inherited;
  FCancel.Free;
  FProc := nil;
end;

procedure TReviewWatchdog.Execute;
begin
  if FCancel.WaitFor(FDelayMs) = wrTimeout then
  begin
    FFired := True;
    FProc.Terminate(0);
  end;
end;

procedure TReviewWatchdog.Stop;
begin
  FCancel.SetEvent;
  WaitFor;
end;

{ TReviewLaunchThread }

constructor TReviewLaunchThread.Create(gate : TEvent);
begin
  FGate := gate;
  inherited Create(False);
end;

procedure TReviewLaunchThread.Execute;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  try
    output := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.TimeoutInMSec := 30000;
      TTestHelpers.SetupInlineCommand(proc, 'echo launched', '');
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      FGate.WaitFor(10000);
      FStarted := proc.Execute;
      if not FStarted then
        FErrorText := proc.Errors.Text;
      proc := nil;
    finally
      output.Free;
    end;
  except
    on E : Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
end;

{ Helper modes }

function ReviewCtrlHandler(ctrlType : DWORD) : BOOL; stdcall;
begin
  result := ctrlType = CTRL_C_EVENT;
  if result then
    InterlockedExchange(GCtrlCSeen, 1);
end;

procedure WriteAnswer(const fileName : string; const answer : string);
var
  bytes : TBytes;
  fs : TFileStream;
begin
  bytes := TEncoding.UTF8.GetBytes(answer);
  fs := TFileStream.Create(fileName, fmCreate);
  try
    if Length(bytes) > 0 then
      fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

// review-win-ctrlc <file>: sends Ctrl+C to its own console and writes
// "delivered" to <file> when its handler was called, "ignored" when not.
procedure HelperCtrlCCheck;
var
  answer : string;
  waited : integer;
begin
  GCtrlCSeen := 0;
  if not SetConsoleCtrlHandler(@ReviewCtrlHandler, True) then
    answer := 'error: SetConsoleCtrlHandler ' + IntToStr(Winapi.Windows.GetLastError)
  else if not GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) then
    answer := 'error: GenerateConsoleCtrlEvent ' + IntToStr(Winapi.Windows.GetLastError)
  else
  begin
    waited := 0;
    while (GCtrlCSeen = 0) and (waited < 3000) do
    begin
      Sleep(20);
      Inc(waited, 20);
    end;
    if GCtrlCSeen <> 0 then
      answer := cDelivered
    else
      answer := cIgnored;
  end;
  WriteAnswer(ParamStr(2), answer);
end;

// review-win-spawn-ctrlc <file>: runs review-win-ctrlc <file> as an ordinary
// child (Execute, so it has a console of its own) and waits for it.
procedure HelperSpawnCtrlCCheck;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := ParamStr(0);
  proc.StartInfo.TimeoutInMSec := 15000;
  proc.CommandLine.Add(cHelperSwitch + cModeCtrlC + ' "' + ParamStr(2) + '"', TQuoted.qtNone);
  if not proc.Execute then
    WriteAnswer(ParamStr(2), 'error: the helper could not start its child: ' + Trim(proc.Errors.Text));
end;

function ReviewWindowsHelper(const mode : string) : boolean;
begin
  result := True;
  if mode = cModeCtrlC then
    HelperCtrlCCheck
  else if mode = cModeSpawnCtrlC then
    HelperSpawnCtrlCCheck
  else
    result := False;
end;

{ WIN-1 support }

function HasConsole : boolean;
var
  console : THandle;
begin
  console := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  result := console <> INVALID_HANDLE_VALUE;
  if result then
    CloseHandle(console);
end;

// Gives this process a (hidden) console when it has none. allocated is set
// when the caller has to FreeConsole afterwards.
function EnsureConsole(out allocated : boolean) : boolean;
var
  savedIn : THandle;
  savedOut : THandle;
  savedErr : THandle;
  window : HWND;
begin
  allocated := False;
  if HasConsole then
    Exit(True);
  savedIn := GetStdHandle(STD_INPUT_HANDLE);
  savedOut := GetStdHandle(STD_OUTPUT_HANDLE);
  savedErr := GetStdHandle(STD_ERROR_HANDLE);
  if AllocConsole then
  begin
    allocated := True;
    window := ReviewGetConsoleWindow;
    if window <> 0 then
      ShowWindow(window, SW_HIDE);
    // AllocConsole may replace the std handles the runner was started with.
    SetStdHandle(STD_INPUT_HANDLE, savedIn);
    SetStdHandle(STD_OUTPUT_HANDLE, savedOut);
    SetStdHandle(STD_ERROR_HANDLE, savedErr);
  end;
  result := HasConsole;
end;

// A screen buffer of this process's console that is not the one on show: a
// console handle like CONOUT$, but what is written to it can be read back
// and never appears in the runner's own output.
function CreateScreenBuffer : THandle;
begin
  result := CreateConsoleScreenBuffer(GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
                                      CONSOLE_TEXTMODE_BUFFER, nil);
end;

function ReadScreenStart(buffer : THandle) : string;
var
  chars : array[0..1999] of WideChar;
  got : DWORD;
  origin : TCoord;
begin
  result := '';
  origin.X := 0;
  origin.Y := 0;
  got := 0;
  if ReadConsoleOutputCharacterW(buffer, @chars[0], Length(chars), origin, got) then
    SetString(result, PWideChar(@chars[0]), got);
end;

// Runs `cmd /c <command>` attached to this process's console (no creation
// flags) with stdErr as its stderr. False when it could not be run.
function RunCmdSharingConsole(const command : string; stdErr : THandle) : boolean;
var
  startup : TStartupInfoW;
  info : TProcessInformation;
  security : TSecurityAttributes;
  commandLine : string;
  nulHandle : THandle;
  errCopy : THandle;
begin
  result := False;
  security.nLength := SizeOf(security);
  security.lpSecurityDescriptor := nil;
  security.bInheritHandle := True;
  nulHandle := CreateFileW('NUL', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, @security, OPEN_EXISTING, 0, 0);
  if nulHandle = INVALID_HANDLE_VALUE then
    Exit;
  try
    if not DuplicateHandle(GetCurrentProcess, stdErr, GetCurrentProcess, @errCopy, 0, True, DUPLICATE_SAME_ACCESS) then
      Exit;
    try
      ZeroMemory(@startup, SizeOf(startup));
      startup.cb := SizeOf(startup);
      startup.dwFlags := STARTF_USESTDHANDLES;
      startup.hStdInput := nulHandle;
      startup.hStdOutput := nulHandle;
      startup.hStdError := errCopy;
      commandLine := '"' + TTestHelpers.ShellExePath + '" /c ' + command;
      UniqueString(commandLine);
      if not CreateProcessW(PChar(TTestHelpers.ShellExePath), PChar(commandLine), nil, nil, True, 0, nil, nil, startup, info) then
        Exit;
      try
        result := WaitForSingleObject(info.hProcess, 20000) = WAIT_OBJECT_0;
        if not result then
        begin
          TerminateProcess(info.hProcess, 1);
          WaitForSingleObject(info.hProcess, 5000);
        end;
      finally
        CloseHandle(info.hThread);
        CloseHandle(info.hProcess);
      end;
    finally
      CloseHandle(errCopy);
    end;
  finally
    CloseHandle(nulHandle);
  end;
end;

{ WIN-4 support }

function ReadAnswer(const fileName : string) : string;
var
  lines : TStringList;
begin
  result := '';
  lines := TStringList.Create;
  try
    try
      lines.LoadFromFile(fileName);
      result := Trim(lines.Text);
    except
      on EFOpenError do
        result := '';
    end;
  finally
    lines.Free;
  end;
end;

// Starts the test exe in its review-win-spawn-ctrlc mode, detached or with
// Execute, and returns what the console child of that helper reported.
function RunCtrlCChain(detached : boolean) : string;
var
  proc : IProcess;
  marker : string;
  deadline : Int64;
  watch : NativeUInt;
  started : boolean;
begin
  result := '';
  watch := 0;
  marker := TTestHelpers.TempFileName('vsoft_proc_review_ctrlc_', '.txt');
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := ParamStr(0);
    proc.CommandLine.Add(cHelperSwitch + cModeSpawnCtrlC + ' "' + marker + '"', TQuoted.qtNone);
    if detached then
    begin
      started := proc.ExecuteDetached;
      if started then
        watch := TTestHelpers.WatchProcess(proc.ProcessId);
    end
    else
    begin
      proc.StartInfo.TimeoutInMSec := 30000;
      started := proc.Execute;
      if started and (proc.Status = TProcessStatus.Exited) and (proc.ExitCode = 2) and (not FileExists(marker)) then
        Assert.Fail('the test exe does not know the helper mode ' + cModeSpawnCtrlC +
                    ': RunTestHelperMode has to call ReviewWindowsHelper(mode)');
    end;
    Assert.IsTrue(started, proc.Errors.Text);
    deadline := TTestHelpers.TickMs + 25000;
    while (result = '') and (TTestHelpers.TickMs < deadline) do
    begin
      if FileExists(marker) then
        result := ReadAnswer(marker);
      if result = '' then
      begin
        // The detached helper has gone without an answer: no point waiting.
        if (watch <> 0) and TTestHelpers.HasEndedWithin(watch, 0) then
        begin
          Sleep(100);
          if FileExists(marker) then
            result := ReadAnswer(marker);
          Break;
        end;
        Sleep(50);
      end;
    end;
  finally
    TTestHelpers.KillWatched(watch);
    if FileExists(marker) then
      DeleteFile(marker);
  end;
end;

{ WIN-5 support }

function SlowCreateProcess(lpApplicationName : PWideChar; lpCommandLine : PWideChar;
                           lpProcessAttributes : PSecurityAttributes; lpThreadAttributes : PSecurityAttributes;
                           bInheritHandles : BOOL; dwCreationFlags : DWORD; lpEnvironment : Pointer;
                           lpCurrentDirectory : PWideChar; lpStartupInfo : Pointer;
                           var lpProcessInformation : TProcessInformation) : BOOL; stdcall;
var
  current : Integer;
  seen : Integer;
begin
  InterlockedIncrement(GHookCalls);
  current := InterlockedIncrement(GInFlight);
  repeat
    seen := GMaxInFlight;
  until (current <= seen) or (InterlockedCompareExchange(GMaxInFlight, current, seen) = seen);
  Sleep(GHookDelayMs);
  result := GRealCreateProcess(lpApplicationName, lpCommandLine, lpProcessAttributes, lpThreadAttributes, bInheritHandles,
                               dwCreationFlags, lpEnvironment, lpCurrentDirectory, lpStartupInfo, lpProcessInformation);
  InterlockedDecrement(GInFlight);
end;

// The import table slot behind the library's VProcCreateProcessW (an
// external function is a "jmp [slot]" thunk), nil when it is not that shape.
function CreateProcessImportSlot : PPointer;
var
  thunk : PByte;
begin
  result := nil;
  thunk := PByte(@VProcCreateProcessW);
  if (thunk^ <> $FF) or (PByte(NativeUInt(thunk) + 1)^ <> $25) then
    Exit;
  {$IFDEF CPUX86}
  result := PPointer(NativeUInt(PCardinal(NativeUInt(thunk) + 2)^));
  {$ENDIF}
  {$IFDEF CPUX64}
  result := PPointer(NativeInt(thunk) + 6 + PInteger(NativeUInt(thunk) + 2)^);
  {$ENDIF}
end;

function SwapImportSlot(slot : PPointer; newTarget : Pointer) : Pointer;
var
  oldProtect : DWORD;
begin
  if not VirtualProtect(slot, SizeOf(Pointer), PAGE_EXECUTE_READWRITE, oldProtect) then
    RaiseLastOSError;
  result := slot^;
  slot^ := newTarget;
  VirtualProtect(slot, SizeOf(Pointer), oldProtect, oldProtect);
end;

{ TReviewWindowsTests }

procedure TReviewWindowsTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TReviewWindowsTests.WIN1_InheritHostStdHandles_ConsoleStdErr_ReachesHostConsole;
var
  allocated : boolean;
  controlBuffer : THandle;
  hostBuffer : THandle;
  oldStdErr : THandle;
  proc : IProcess;
  output : TStringBuilder;
  screen : string;
  executed : boolean;
begin
  if not EnsureConsole(allocated) then
    Assert.Pass('NOT RUN: this process has no console and could not allocate one');
  controlBuffer := INVALID_HANDLE_VALUE;
  hostBuffer := INVALID_HANDLE_VALUE;
  output := TStringBuilder.Create;
  try
    controlBuffer := CreateScreenBuffer;
    hostBuffer := CreateScreenBuffer;
    if (controlBuffer = INVALID_HANDLE_VALUE) or (hostBuffer = INVALID_HANDLE_VALUE) then
      Assert.Pass('NOT RUN: could not create a console screen buffer');

    // The same handle works for a child that shares this console; when it
    // does not, this machine cannot show the fault either way.
    if (not RunCmdSharingConsole('echo VSP_CONTROL 1>&2', controlBuffer)) or (Pos('VSP_CONTROL', ReadScreenStart(controlBuffer)) = 0) then
      Assert.Pass('NOT RUN: a child sharing this console could not write to the console handle either');

    oldStdErr := GetStdHandle(STD_ERROR_HANDLE);
    SetStdHandle(STD_ERROR_HANDLE, hostBuffer);
    try
      proc := TProcess.Create;
      proc.StartInfo.InheritHostStdHandles := True;
      proc.StartInfo.TimeoutInMSec := 20000;
      TTestHelpers.SetupInlineCommand(proc, 'echo VSP_STDOUT& echo VSP_MARKER 1>&2', '');
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      executed := proc.Execute;
    finally
      SetStdHandle(STD_ERROR_HANDLE, oldStdErr);
    end;
    Assert.IsTrue(executed, proc.Errors.Text);
    Assert.IsTrue(proc.Status = TProcessStatus.Exited, 'status ' + StatusName(proc.Status) + ' ' + proc.Errors.Text);
    Assert.Contains(output.ToString, 'VSP_STDOUT', 'stdout is still redirected');
    screen := Trim(ReadScreenStart(hostBuffer));
    Assert.IsTrue(Pos('VSP_MARKER', screen) > 0,
                  'the child''s stderr did not reach the host''s console: the console shows "' + screen + '", child exit code ' +
                  IntToStr(proc.ExitCode) + ', Errors "' + Trim(proc.Errors.Text) + '"');
  finally
    proc := nil;
    output.Free;
    if controlBuffer <> INVALID_HANDLE_VALUE then
      CloseHandle(controlBuffer);
    if hostBuffer <> INVALID_HANDLE_VALUE then
      CloseHandle(hostBuffer);
    if allocated then
      FreeConsole;
  end;
end;

// Runs a child that writes to stdout and stderr without pause, with a 1 s
// timeout and a target on each stream that takes 5 ms per call.
function RunBusyOnBothStreams(deliverOnRunThread : boolean; out elapsedMs : Int64; out watchdogFired : boolean) : TProcessStatus;
var
  proc : IProcess;
  outTarget : IPipeTarget;
  errTarget : IPipeTarget;
  watchdog : TReviewWatchdog;
  started : Int64;
  executed : boolean;
begin
  outTarget := TReviewSlowTarget.Create(5);
  errTarget := TReviewSlowTarget.Create(5);
  proc := TProcess.Create;
  proc.StartInfo.DeliverOnRunThread := deliverOnRunThread;
  proc.StartInfo.TimeoutInMSec := 1000;
  TTestHelpers.SetupInlineCommand(proc, 'for /l %i in () do @(echo out & echo err 1>&2)', '');
  proc.WithStdOutPipe(outTarget);
  proc.WithStdErrPipe(errTarget);
  watchdog := TReviewWatchdog.Create(proc, 12000);
  try
    started := TTestHelpers.TickMs;
    executed := proc.Execute;
    elapsedMs := TTestHelpers.TickMs - started;
  finally
    watchdog.Stop;
    watchdogFired := watchdog.Fired;
    watchdog.Free;
  end;
  Assert.IsTrue(executed, proc.Errors.Text);
  result := proc.Status;
end;

procedure TReviewWindowsTests.WIN2_DeliverOnRunThread_Timeout_BothStreamsBusy;
var
  status : TProcessStatus;
  elapsedMs : Int64;
  watchdogFired : boolean;
begin
  // The same run with threadpool delivery, to show the child and the
  // targets are not what keeps the timeout from firing.
  status := RunBusyOnBothStreams(false, elapsedMs, watchdogFired);
  Assert.IsTrue((status = TProcessStatus.TimedOut) and (not watchdogFired),
                'control (threadpool delivery): status ' + StatusName(status) + ' after ' + IntToStr(elapsedMs) + 'ms');

  status := RunBusyOnBothStreams(true, elapsedMs, watchdogFired);
  Assert.IsTrue((status = TProcessStatus.TimedOut) and (not watchdogFired),
                'the 1000ms timeout did not fire with DeliverOnRunThread: status ' + StatusName(status) + ' after ' +
                IntToStr(elapsedMs) + 'ms (the watchdog terminates the run after 12000ms)');
  Assert.IsTrue(elapsedMs < 8000, 'the 1000ms timeout took ' + IntToStr(elapsedMs) + 'ms');
end;

procedure TReviewWindowsTests.WIN3_SlowTarget_ChildExited_NoTruncationError;
var
  proc : IProcess;
  target : TReviewSlowTarget;
  targetRef : IPipeTarget;
begin
  target := TReviewSlowTarget.Create(800);
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 20000;
  proc.StartInfo.PipeDrainTimeoutMS := 200;
  TTestHelpers.SetupInlineCommand(proc, 'echo hello', '');
  proc.WithStdOutPipe(targetRef);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.IsTrue(proc.Status = TProcessStatus.Exited, 'status ' + StatusName(proc.Status) + ' ' + proc.Errors.Text);
  Assert.AreEqual<Int64>(7, target.Bytes, 'hello + CRLF is delivered');
  Assert.AreEqual(1, target.DoneCount);
  Assert.AreEqual('', Trim(proc.Errors.Text), 'nothing held the pipe open and nothing was lost, so nothing may be reported');
end;

procedure TReviewWindowsTests.WIN4_Detached_Default_DoesNotDisableCtrlCForItsChildren;
var
  answer : string;
  hostIgnoredCtrlC : boolean;
begin
  hostIgnoredCtrlC := False;
  try
    // The same chain started with Execute: the console child inherits this
    // process's own setting, which has to be "not ignored" for the detached
    // launch to make a difference.
    answer := RunCtrlCChain(false);
    if answer = cIgnored then
    begin
      hostIgnoredCtrlC := True;
      SetConsoleCtrlHandler(nil, False);
      answer := RunCtrlCChain(false);
    end;
    Assert.AreEqual(cDelivered, answer, 'control (Execute -> helper -> console child)');

    answer := RunCtrlCChain(true);
    Assert.AreEqual(cDelivered, answer,
                    'Ctrl+C in the console of a program started by an ExecuteDetached child (ExecuteDetached -> helper -> console child)');
  finally
    if hostIgnoredCtrlC then
      SetConsoleCtrlHandler(nil, True);
  end;
end;

procedure TReviewWindowsTests.WIN5_ConcurrentLaunches_AreNotSerialised;
const
  cThreads = 4;
  cDelayMs = 500;
var
  slot : PPointer;
  gate : TEvent;
  threads : array[0..cThreads - 1] of TReviewLaunchThread;
  i : integer;
  started : Int64;
  elapsedMs : Int64;
  failures : string;
begin
  slot := CreateProcessImportSlot;
  if slot = nil then
    Assert.Pass('NOT RUN: the import thunk of VProcCreateProcessW is not a jmp through the import table here');
  for i := 0 to cThreads - 1 do
    threads[i] := nil;
  GHookDelayMs := cDelayMs;
  GHookCalls := 0;
  GInFlight := 0;
  GMaxInFlight := 0;
  failures := '';
  gate := TEvent.Create(nil, True, False, '');
  try
    // Every CreateProcess call of the library takes cDelayMs longer, as it
    // does with a virus scanner or an image on a network share.
    @GRealCreateProcess := SwapImportSlot(slot, @SlowCreateProcess);
    try
      for i := 0 to cThreads - 1 do
        threads[i] := TReviewLaunchThread.Create(gate);
      Sleep(200);
      started := TTestHelpers.TickMs;
      gate.SetEvent;
      for i := 0 to cThreads - 1 do
        threads[i].WaitFor;
      elapsedMs := TTestHelpers.TickMs - started;
    finally
      gate.SetEvent;
      for i := 0 to cThreads - 1 do
        if threads[i] <> nil then
          threads[i].WaitFor;
      SwapImportSlot(slot, @GRealCreateProcess);
    end;
    for i := 0 to cThreads - 1 do
      if not threads[i].Started then
        failures := failures + threads[i].ErrorText + ' ';
    Assert.AreEqual('', failures, 'every launch succeeds');
    if GHookCalls <> cThreads then
      Assert.Pass('NOT RUN: the slow CreateProcess was called ' + IntToStr(GHookCalls) + ' times for ' + IntToStr(cThreads) + ' launches');
    Assert.IsTrue(GMaxInFlight >= 2,
                  IntToStr(cThreads) + ' launches on ' + IntToStr(cThreads) + ' threads were never inside CreateProcess together: at most ' +
                  IntToStr(GMaxInFlight) + ' at a time, ' + IntToStr(elapsedMs) + 'ms in all with ' + IntToStr(cDelayMs) +
                  'ms per CreateProcess');
  finally
    for i := 0 to cThreads - 1 do
      threads[i].Free;
    gate.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TReviewWindowsTests);
{$ENDIF}

end.
