unit VSoft.Process.Tests.WinLaunch;

interface

// What a child started by TWindowsProcess is actually given, as the child
// itself reports it (the child-info helper mode of the test exe): priority,
// affinity, window state, std handles, console, arguments, environment and
// working directory. Also exit codes, launch validation, handle leaks and
// two teardown paths.

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  [TestFixture]
  TWindowsLaunchTests = class
  private
    FStartedCount : integer;
    procedure CountStarted(const process : IProcess);
  public
    [Setup]
    procedure SetUp;

    // StartInfo.Priority becomes the child's priority class.
    [Test]
    procedure Priority_Execute_ReachesChild;
    [Test]
    procedure Priority_Detached_ReachesChild;

    // StartInfo.ProcessorAffinity becomes the child's affinity mask.
    [Test]
    procedure ProcessorAffinity_Execute_ReachesChild;
    [Test]
    procedure ProcessorAffinity_Detached_ReachesChild;
    // 0 (the default) leaves the mask the child inherits from this process.
    [Test]
    procedure ProcessorAffinity_Zero_ChildKeepsHostMask;
    // A mask Windows refuses is reported in Errors; the child still runs.
    [Test]
    procedure ProcessorAffinity_OutsideSystemMask_LoggedAndChildRuns;
    [Test]
    procedure ProcessorAffinity_Detached_OutsideSystemMask_Logged;

    // StartInfo.HideWindow reaches the child as STARTUPINFO.wShowWindow.
    [Test]
    procedure HideWindow_True_ChildIsToldToHide;
    [Test]
    procedure HideWindow_False_ChildIsToldToShow;
    [Test]
    procedure HideWindow_Detached_ReachesChild;

    // The type of each std handle the child gets.
    [Test]
    procedure StdOutAndStdErrRedirected_ChildSeesPipes;
    [Test]
    procedure OnlyStdOutRedirected_OtherStreamsAreNul;
    [Test]
    procedure OnlyStdErrRedirected_StdOutIsNul;
    [Test]
    procedure StdInRedirected_ChildSeesPipe;
    // Nothing redirected: no std handles are passed and the child has a
    // console of its own.
    [Test]
    procedure NothingRedirected_ChildHasItsOwnConsole;
    // StartInfo.InheritHostStdHandles for stdout (stderr and stdin are in
    // the Lifecycle tests).
    [Test]
    procedure InheritHostStdHandles_StdOutGoesToHostStdOut;
    [Test]
    procedure Default_UnredirectedStdOutDoesNotReachHostStdOut;

    // An inheritable handle of this process must not leak into a child: the
    // library passes a handle list (or inherits nothing).
    [Test]
    procedure InheritProbe_Control_InheritingChildKeepsPipeOpen;
    [Test]
    procedure HostInheritableHandle_Redirected_NotInherited;
    [Test]
    procedure HostInheritableHandle_NothingRedirected_NotInherited;
    [Test]
    procedure HostInheritableHandle_Detached_NotInherited;

    // Windows exit codes are 32 bits. 259 is STILL_ACTIVE, which
    // GetExitCodeProcess also returns for a process that is still running.
    [Test]
    procedure ExitCode_FullRange_ComesBackUnchanged;
    [Test]
    procedure ExitCode_StillActiveValue_AsyncRunLeavesRunning;

    // CreateProcessW takes UTF-16: nothing is lost on the way to the child.
    [Test]
    procedure CommandLine_UnicodeArguments_ReachChildIntact;
    [Test]
    procedure Environment_UnicodeValue_ReachesChild;
    [Test]
    procedure WorkingDirectory_UnicodePath_ChildStartsThere;
    [Test]
    procedure Executable_UnicodePath_Runs;

    // Windows allows 32767 characters for a command line.
    [Test]
    procedure CommandLine_NearMaximumLength_ReachesChild;
    [Test]
    procedure CommandLine_OverMaximumLength_LaunchFailsWithOsError;

    // ExecuteDetached.
    [Test]
    procedure Detached_WorkingDirectory_ChildStartsThere;
    [Test]
    procedure Detached_EnvironmentAndArguments_ReachChild;
    // CREATE_BREAKAWAY_FROM_JOB is refused in a job that does not allow
    // it; the launch is then made inside the job.
    [Test]
    procedure Detached_HostJobRefusesBreakaway_StillLaunches;
    [Test]
    procedure Detached_OnStartedFires;

    // Validation: Execute* returns False, the reason is in Errors and
    // LastError stays 0.
    [Test]
    procedure Executable_Empty_IsRejected;
    [Test]
    procedure Executable_WithNul_IsRejected;
    [Test]
    procedure WorkingDirectory_WithNul_IsRejected;
    [Test]
    procedure ArgumentSeparator_WithNul_IsRejected;
    [Test]
    procedure NameValueSeparator_WithNul_IsRejected;

    // No handles are left behind by launches that fail or are not waited for.
    [Test]
    procedure FailedLaunches_DoNotLeakHandles;
    [Test]
    procedure ValidationFailures_DoNotLeakHandles;
    [Test]
    procedure DetachedLaunches_DoNotLeakHandles;
    [Test]
    procedure StdInRuns_DoNotLeakHandles;

    // DeliverOnRunThread: a run abandoned at its timeout still hands the
    // target what had been read, and only then calls Done.
    [Test]
    procedure DeliverOnRunThread_AbandonedRun_DeliversBeforeDone;
    // A method another thread queued to the main thread raises while a
    // synchronous Execute there is servicing the queue: the run goes on.
    // Whether the exception is logged depends on the RTL. XE2's
    // CheckSynchronize lets it out and the library logs it; from Delphi 12
    // CheckSynchronize handles it itself and nothing reaches the library.
    [Test]
    procedure SyncExecuteOnMainThread_QueuedMethodRaises_RunCompletes;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  // The priority class constants older Delphi versions do not declare.
  VSoft.Process.WinAPI,
  VSoft.Process.Tests.Common,
  VSoft.Process.Tests.Helper;

const
  cReportWaitMs = 15000;
  // "Japanese" in kanji.
  cCjk = #$65E5#$672C#$8A9E;

function LaunchGetConsoleWindow : HWND; stdcall; external kernel32 name 'GetConsoleWindow';

type
  TNullTarget = class(TInterfacedObject, IPipeTarget)
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // Takes sleepMs over every chunk and records what it was given.
  TSlowCountingTarget = class(TInterfacedObject, IPipeTarget)
  private
    FSleepMs : Cardinal;
    FBytes : Int64;
    FDoneCount : integer;
    FDataAfterDone : boolean;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  public
    constructor Create(sleepMs : Cardinal);
    property Bytes : Int64 read FBytes;
    property DoneCount : integer read FDoneCount;
    property DataAfterDone : boolean read FDataAfterDone;
  end;

  // Queues a method to the main thread that raises there.
  TQueueRaiser = class(TThread)
  private
    FDelayMs : Cardinal;
    FRaised : boolean;
    procedure RaiseOnMainThread;
  protected
    procedure Execute; override;
  public
    constructor Create(delayMs : Cardinal);
    // Set on the main thread, just before the queued method raises.
    property Raised : boolean read FRaised;
  end;

  // A pipe whose write end is inheritable. A child that inherits it keeps
  // the pipe open until it exits, so a read only sees the end of the pipe
  // once that child has gone.
  TInheritProbe = record
    ReadEnd : THandle;
    WriteEnd : THandle;
    procedure Open;
    // Closes our write end and returns how long a read took to see the end
    // of the pipe.
    function MsUntilPipeEnds : Int64;
    procedure Close;
  end;

  TRunOnce = procedure;

procedure TNullTarget.Start;
begin
end;

procedure TNullTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TNullTarget.Done;
begin
end;

constructor TSlowCountingTarget.Create(sleepMs : Cardinal);
begin
  inherited Create;
  FSleepMs := sleepMs;
end;

procedure TSlowCountingTarget.Start;
begin
  FBytes := 0;
  FDoneCount := 0;
  FDataAfterDone := False;
end;

procedure TSlowCountingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  if FDoneCount > 0 then
    FDataAfterDone := True;
  Inc(FBytes, dataLength);
  Sleep(FSleepMs);
end;

procedure TSlowCountingTarget.Done;
begin
  Inc(FDoneCount);
end;

constructor TQueueRaiser.Create(delayMs : Cardinal);
begin
  FDelayMs := delayMs;
  inherited Create(False);
end;

procedure TQueueRaiser.RaiseOnMainThread;
begin
  FRaised := True;
  raise Exception.Create('queued-boom');
end;

procedure TQueueRaiser.Execute;
begin
  Sleep(FDelayMs);
  // Not tied to this thread object, which is freed before the queue is
  // looked at again when the run under test has already ended.
  TThread.Queue(nil, RaiseOnMainThread);
end;

procedure TInheritProbe.Open;
var
  security : TSecurityAttributes;
begin
  security.nLength := SizeOf(security);
  security.lpSecurityDescriptor := nil;
  security.bInheritHandle := True;
  Win32Check(CreatePipe(ReadEnd, WriteEnd, @security, 0));
  // Only the write end is the probe.
  SetHandleInformation(ReadEnd, HANDLE_FLAG_INHERIT, 0);
end;

function TInheritProbe.MsUntilPipeEnds : Int64;
var
  started : Int64;
  buffer : Byte;
  bytesRead : DWORD;
begin
  CloseHandle(WriteEnd);
  WriteEnd := 0;
  started := TTestHelpers.TickMs;
  ReadFile(ReadEnd, buffer, 1, bytesRead, nil);
  result := TTestHelpers.TickMs - started;
end;

procedure TInheritProbe.Close;
begin
  if WriteEnd <> 0 then
    CloseHandle(WriteEnd);
  if ReadEnd <> 0 then
    CloseHandle(ReadEnd);
  WriteEnd := 0;
  ReadEnd := 0;
end;

function NewReportFile : string;
begin
  result := TTestHelpers.TempFileName('vsoft_proc_info_', '.txt');
end;

function NewChildInfoProcess(const target : string) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.TimeoutInMSec := 30000;
  SetupChildInfo(result, target);
end;

// Runs proc, a child-info helper reporting to stdout, and returns its report.
function RunForReport(const proc : IProcess) : IChildReport;
var
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.ASCII));
    try
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
    finally
      proc.ClearStdOutPipes;
    end;
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode, output.ToString + proc.Errors.Text);
    result := ParseChildReport(output.ToString);
  finally
    output.Free;
  end;
end;

// Runs proc, a child-info helper reporting to reportFile, and returns its
// report. The file is deleted.
function RunForReportFile(const proc : IProcess; const reportFile : string; detached : boolean) : IChildReport;
var
  started : boolean;
begin
  try
    if detached then
      started := proc.ExecuteDetached
    else
      started := proc.Execute;
    Assert.IsTrue(started, proc.Errors.Text);
    result := WaitForChildReport(reportFile, cReportWaitMs);
    Assert.IsTrue(result <> nil, 'the child never reported: ' + proc.Errors.Text);
  finally
    if FileExists(reportFile) then
      DeleteFile(reportFile);
  end;
end;

// The affinity masks of this process. False when it has no single mask
// (more than one processor group).
function HostAffinity(out processMask : NativeUInt; out systemMask : NativeUInt) : boolean;
var
  ownMask : DWORD_PTR;
  allMask : DWORD_PTR;
begin
  ownMask := 0;
  allMask := 0;
  result := GetProcessAffinityMask(GetCurrentProcess, ownMask, allMask) and (ownMask <> 0);
  processMask := ownMask;
  systemMask := allMask;
end;

// The lowest bit set in mask.
function LowestCpu(mask : NativeUInt) : NativeUInt;
begin
  result := 1;
  while (result <> 0) and ((mask and result) = 0) do
    result := result shl 1;
end;

// The lowest bit that is not a processor of this machine, 0 when every bit is.
function CpuOutside(systemMask : NativeUInt) : NativeUInt;
begin
  result := 1;
  while (result <> 0) and ((systemMask and result) <> 0) do
    result := result shl 1;
end;

function ReportedAffinity(const report : IChildReport) : NativeUInt;
begin
  result := NativeUInt(StrToInt64Def('$' + report.Value('AFFINITY'), 0));
end;

// Runs print-stderr with only stderr redirected while this process's
// STD_OUTPUT_HANDLE is a temp file, and returns what reached that file.
function RunWithHostStdOutInFile(inheritHost : boolean; out stdErrText : string) : string;
var
  fileName : string;
  fileHandle : THandle;
  oldStdOut : THandle;
  proc : IProcess;
  errors : TStringBuilder;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_hostout_', '.txt');
  fileHandle := CreateFile(PChar(fileName), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  Win32Check(fileHandle <> INVALID_HANDLE_VALUE);
  errors := TStringBuilder.Create;
  try
    oldStdOut := GetStdHandle(STD_OUTPUT_HANDLE);
    SetStdHandle(STD_OUTPUT_HANDLE, fileHandle);
    try
      proc := TProcess.Create;
      proc.StartInfo.InheritHostStdHandles := inheritHost;
      proc.StartInfo.TimeoutInMSec := 30000;
      TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
      proc.WithStdErrPipe(TPipeTarget.ToStringBuilder(errors));
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
      Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
    finally
      SetStdHandle(STD_OUTPUT_HANDLE, oldStdOut);
      CloseHandle(fileHandle);
    end;
    stdErrText := errors.ToString;
    result := TEncoding.ANSI.GetString(TTestHelpers.ReadFileBytes(fileName));
  finally
    proc := nil;
    errors.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure RunFailedLaunch;
var
  proc : IProcess;
begin
  // Exists, so validation passes, but is not a program: the pipes and the
  // stdin source are set up and then torn down again.
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ScriptsDir + 'invalid-utf8.bin';
  proc.WithStdOutPipe(TNullTarget.Create);
  proc.WithStdErrPipe(TNullTarget.Create);
  proc.WithStdInPipe(TPipeSource.FromString('unused'));
  Assert.IsFalse(proc.Execute, 'the file is not a program');
end;

procedure RunValidationFailure;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ScriptsDir + 'no-such-program.exe';
  proc.WithStdOutPipe(TNullTarget.Create);
  proc.WithStdInPipe(TPipeSource.FromString('unused'));
  Assert.IsFalse(proc.Execute, 'the program does not exist');
end;

procedure RunDetachedExit;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', '');
  Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
end;

procedure RunWithStdIn;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
  proc.WithStdInPipe(TPipeSource.FromString('a line' + sLineBreak));
  proc.WithStdOutPipe(TNullTarget.Create);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
end;

procedure CheckNoHandleLeak(const what : string; runOnce : TRunOnce; count : integer);
var
  before : Cardinal;
  after : Cardinal;
  i : integer;
begin
  // The first runs create handles that live for the whole session
  // (threadpool, code page tables).
  runOnce();
  runOnce();
  before := TTestHelpers.HandleCount;
  for i := 1 to count do
    runOnce();
  after := TTestHelpers.HandleCount;
  Assert.IsTrue(after < before + 5, Format('%d %s grew the handle count from %d to %d', [count, what, before, after]));
end;

const
  cPriorities : array[0..3] of TProcessPriority = (TProcessPriority.Normal, TProcessPriority.AboveNormal,
                                                   TProcessPriority.BelowNormal, TProcessPriority.Idle);
  cPriorityClasses : array[0..3] of DWORD = (NORMAL_PRIORITY_CLASS, ABOVE_NORMAL_PRIORITY_CLASS,
                                             BELOW_NORMAL_PRIORITY_CLASS, IDLE_PRIORITY_CLASS);

{ TWindowsLaunchTests }

procedure TWindowsLaunchTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TWindowsLaunchTests.CountStarted(const process : IProcess);
begin
  Inc(FStartedCount);
end;

procedure TWindowsLaunchTests.Priority_Execute_ReachesChild;
var
  i : integer;
  proc : IProcess;
  report : IChildReport;
begin
  for i := 0 to High(cPriorities) do
  begin
    proc := NewChildInfoProcess('-');
    proc.StartInfo.Priority := cPriorities[i];
    report := RunForReport(proc);
    Assert.AreEqual<Int64>(cPriorityClasses[i], report.Number('PRIORITY'), 'priority ' + IntToStr(i) + ': ' + report.Raw);
  end;
end;

procedure TWindowsLaunchTests.Priority_Detached_ReachesChild;
var
  i : integer;
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  // BelowNormal is covered by ExecuteDetached_AppliesPriority.
  for i := 0 to High(cPriorities) do
  begin
    if cPriorities[i] = TProcessPriority.BelowNormal then
      Continue;
    reportFile := NewReportFile;
    proc := NewChildInfoProcess(reportFile);
    proc.StartInfo.Priority := cPriorities[i];
    report := RunForReportFile(proc, reportFile, true);
    Assert.AreEqual<Int64>(cPriorityClasses[i], report.Number('PRIORITY'), 'priority ' + IntToStr(i) + ': ' + report.Raw);
  end;
end;

procedure TWindowsLaunchTests.ProcessorAffinity_Execute_ReachesChild;
var
  processMask : NativeUInt;
  systemMask : NativeUInt;
  oneCpu : NativeUInt;
  proc : IProcess;
  report : IChildReport;
begin
  if not HostAffinity(processMask, systemMask) then
    Assert.Pass('NOT RUN: this process has no single affinity mask');
  oneCpu := LowestCpu(processMask);
  proc := NewChildInfoProcess('-');
  proc.StartInfo.ProcessorAffinity := oneCpu;
  report := RunForReport(proc);
  Assert.AreEqual<NativeUInt>(oneCpu, ReportedAffinity(report), report.Raw);
  Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
end;

procedure TWindowsLaunchTests.ProcessorAffinity_Detached_ReachesChild;
var
  processMask : NativeUInt;
  systemMask : NativeUInt;
  oneCpu : NativeUInt;
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  if not HostAffinity(processMask, systemMask) then
    Assert.Pass('NOT RUN: this process has no single affinity mask');
  oneCpu := LowestCpu(processMask);
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.StartInfo.ProcessorAffinity := oneCpu;
  report := RunForReportFile(proc, reportFile, true);
  Assert.AreEqual<NativeUInt>(oneCpu, ReportedAffinity(report), report.Raw);
  Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
end;

procedure TWindowsLaunchTests.ProcessorAffinity_Zero_ChildKeepsHostMask;
var
  processMask : NativeUInt;
  systemMask : NativeUInt;
  proc : IProcess;
  report : IChildReport;
begin
  if not HostAffinity(processMask, systemMask) then
    Assert.Pass('NOT RUN: this process has no single affinity mask');
  proc := NewChildInfoProcess('-');
  report := RunForReport(proc);
  Assert.AreEqual<NativeUInt>(processMask, ReportedAffinity(report), report.Raw);
end;

procedure TWindowsLaunchTests.ProcessorAffinity_OutsideSystemMask_LoggedAndChildRuns;
var
  processMask : NativeUInt;
  systemMask : NativeUInt;
  outside : NativeUInt;
  proc : IProcess;
  report : IChildReport;
begin
  if not HostAffinity(processMask, systemMask) then
    Assert.Pass('NOT RUN: this process has no single affinity mask');
  outside := CpuOutside(systemMask);
  if outside = 0 then
    Assert.Pass('NOT RUN: every bit of an affinity mask is a processor on this machine');
  proc := NewChildInfoProcess('-');
  proc.StartInfo.ProcessorAffinity := outside;
  report := RunForReport(proc);
  Assert.Contains(proc.Errors.Text, 'Failed to set processor affinity');
  Assert.AreEqual<NativeUInt>(processMask, ReportedAffinity(report), 'the child keeps the mask it inherited: ' + report.Raw);
end;

procedure TWindowsLaunchTests.ProcessorAffinity_Detached_OutsideSystemMask_Logged;
var
  processMask : NativeUInt;
  systemMask : NativeUInt;
  outside : NativeUInt;
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  if not HostAffinity(processMask, systemMask) then
    Assert.Pass('NOT RUN: this process has no single affinity mask');
  outside := CpuOutside(systemMask);
  if outside = 0 then
    Assert.Pass('NOT RUN: every bit of an affinity mask is a processor on this machine');
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.StartInfo.ProcessorAffinity := outside;
  report := RunForReportFile(proc, reportFile, true);
  Assert.Contains(proc.Errors.Text, 'Failed to set processor affinity on detached child');
  Assert.AreEqual<NativeUInt>(processMask, ReportedAffinity(report), 'the child keeps the mask it inherited: ' + report.Raw);
end;

procedure TWindowsLaunchTests.HideWindow_True_ChildIsToldToHide;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  Assert.IsTrue(proc.StartInfo.HideWindow, 'HideWindow defaults to True');
  report := RunForReport(proc);
  Assert.IsTrue((report.Number('STARTFLAGS') and STARTF_USESHOWWINDOW) <> 0, report.Raw);
  Assert.AreEqual<Int64>(SW_HIDE, report.Number('SHOWWINDOW'), report.Raw);
end;

procedure TWindowsLaunchTests.HideWindow_False_ChildIsToldToShow;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  proc.StartInfo.HideWindow := False;
  report := RunForReport(proc);
  Assert.IsTrue((report.Number('STARTFLAGS') and STARTF_USESHOWWINDOW) <> 0, report.Raw);
  Assert.AreEqual<Int64>(SW_SHOWNORMAL, report.Number('SHOWWINDOW'), report.Raw);
end;

procedure TWindowsLaunchTests.HideWindow_Detached_ReachesChild;
var
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  // Without DetachedNewConsole the child has no console, so nothing is
  // shown either way; the setting still reaches it.
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  report := RunForReportFile(proc, reportFile, true);
  Assert.AreEqual<Int64>(SW_HIDE, report.Number('SHOWWINDOW'), report.Raw);

  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.StartInfo.HideWindow := False;
  report := RunForReportFile(proc, reportFile, true);
  Assert.AreEqual<Int64>(SW_SHOWNORMAL, report.Number('SHOWWINDOW'), report.Raw);
end;

procedure TWindowsLaunchTests.StdOutAndStdErrRedirected_ChildSeesPipes;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  proc.WithStdErrPipe(TNullTarget.Create);
  report := RunForReport(proc);
  Assert.AreEqual('pipe', report.Value('STDOUT'), report.Raw);
  Assert.AreEqual('pipe', report.Value('STDERR'), report.Raw);
  Assert.AreEqual('nul', report.Value('STDIN'), report.Raw);
  Assert.IsTrue((report.Number('STARTFLAGS') and STARTF_USESTDHANDLES) <> 0, report.Raw);
end;

procedure TWindowsLaunchTests.OnlyStdOutRedirected_OtherStreamsAreNul;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  report := RunForReport(proc);
  Assert.AreEqual('pipe', report.Value('STDOUT'), report.Raw);
  Assert.AreEqual('nul', report.Value('STDERR'), report.Raw);
  Assert.AreEqual('nul', report.Value('STDIN'), report.Raw);
end;

procedure TWindowsLaunchTests.OnlyStdErrRedirected_StdOutIsNul;
var
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.WithStdErrPipe(TNullTarget.Create);
  report := RunForReportFile(proc, reportFile, false);
  Assert.AreEqual('nul', report.Value('STDOUT'), report.Raw);
  Assert.AreEqual('pipe', report.Value('STDERR'), report.Raw);
  Assert.AreEqual('nul', report.Value('STDIN'), report.Raw);
end;

procedure TWindowsLaunchTests.StdInRedirected_ChildSeesPipe;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  proc.WithStdInPipe(TPipeSource.FromString('not read'));
  report := RunForReport(proc);
  Assert.AreEqual('pipe', report.Value('STDIN'), report.Raw);
  Assert.AreEqual('pipe', report.Value('STDOUT'), report.Raw);
  Assert.AreEqual('nul', report.Value('STDERR'), report.Raw);
end;

procedure TWindowsLaunchTests.NothingRedirected_ChildHasItsOwnConsole;
var
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
  hostWindow : Int64;
begin
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  report := RunForReportFile(proc, reportFile, false);
  Assert.AreEqual('yes', report.Value('CONSOLE'), report.Raw);
  Assert.AreEqual<Int64>(0, report.Number('STARTFLAGS') and STARTF_USESTDHANDLES, 'no std handles are passed: ' + report.Raw);
  Assert.AreEqual('console', report.Value('STDOUT'), report.Raw);
  Assert.AreEqual('console', report.Value('STDERR'), report.Raw);
  Assert.AreEqual('console', report.Value('STDIN'), report.Raw);
  hostWindow := Int64(LaunchGetConsoleWindow);
  if (hostWindow <> 0) and (report.Number('CONSOLEWND') > 0) then
    Assert.AreNotEqual<Int64>(hostWindow, report.Number('CONSOLEWND'), 'the child shares this process''s console');
end;

procedure TWindowsLaunchTests.InheritHostStdHandles_StdOutGoesToHostStdOut;
var
  stdErrText : string;
begin
  Assert.Contains(RunWithHostStdOutInFile(true, stdErrText), 'this-is-stdout', 'the child''s stdout should reach the host''s stdout');
  Assert.Contains(stdErrText, 'this-is-stderr', 'stderr is still redirected');
end;

procedure TWindowsLaunchTests.Default_UnredirectedStdOutDoesNotReachHostStdOut;
var
  stdErrText : string;
begin
  Assert.AreEqual('', RunWithHostStdOutInFile(false, stdErrText), 'by default the child''s stdout is NUL');
  Assert.Contains(stdErrText, 'this-is-stderr');
end;

procedure TWindowsLaunchTests.InheritProbe_Control_InheritingChildKeepsPipeOpen;
var
  probe : TInheritProbe;
  startup : TStartupInfo;
  processInfo : TProcessInformation;
  command : string;
  elapsed : Int64;
begin
  probe.ReadEnd := 0;
  probe.WriteEnd := 0;
  probe.Open;
  try
    ZeroMemory(@startup, SizeOf(startup));
    startup.cb := SizeOf(startup);
    command := TTestHelpers.ShellExePath + ' /c ping -n 3 127.0.0.1 > nul';
    UniqueString(command);
    Win32Check(CreateProcess(nil, PChar(command), nil, nil, True, CREATE_NO_WINDOW, nil, nil, startup, processInfo));
    CloseHandle(processInfo.hThread);
    try
      elapsed := probe.MsUntilPipeEnds;
    finally
      TerminateProcess(processInfo.hProcess, 0);
      CloseHandle(processInfo.hProcess);
    end;
    Assert.IsTrue(elapsed > 1000, Format('the probe saw the end of the pipe after %d ms although a child had inherited it', [elapsed]));
  finally
    probe.Close;
  end;
end;

procedure TWindowsLaunchTests.HostInheritableHandle_Redirected_NotInherited;
var
  probe : TInheritProbe;
  proc : IProcess;
  elapsed : Int64;
begin
  probe.ReadEnd := 0;
  probe.WriteEnd := 0;
  probe.Open;
  try
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, 'ping -n 3 127.0.0.1 > nul', '');
    proc.WithStdOutPipe(TNullTarget.Create);
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    try
      elapsed := probe.MsUntilPipeEnds;
    finally
      proc.Terminate;
    end;
    Assert.IsTrue(elapsed < 1000, Format('the pipe stayed open for %d ms: the child inherited a handle it was not given', [elapsed]));
  finally
    probe.Close;
  end;
end;

procedure TWindowsLaunchTests.HostInheritableHandle_NothingRedirected_NotInherited;
var
  probe : TInheritProbe;
  proc : IProcess;
  elapsed : Int64;
begin
  probe.ReadEnd := 0;
  probe.WriteEnd := 0;
  probe.Open;
  try
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, 'ping -n 3 127.0.0.1 > nul', '');
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    try
      elapsed := probe.MsUntilPipeEnds;
    finally
      proc.Terminate;
    end;
    Assert.IsTrue(elapsed < 1000, Format('the pipe stayed open for %d ms: the child inherited a handle it was not given', [elapsed]));
  finally
    probe.Close;
  end;
end;

procedure TWindowsLaunchTests.HostInheritableHandle_Detached_NotInherited;
var
  probe : TInheritProbe;
  proc : IProcess;
  watch : NativeUInt;
  elapsed : Int64;
begin
  probe.ReadEnd := 0;
  probe.WriteEnd := 0;
  watch := 0;
  probe.Open;
  try
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, 'ping -n 3 127.0.0.1 > nul', '');
    Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
    watch := TTestHelpers.WatchProcess(proc.ProcessId);
    elapsed := probe.MsUntilPipeEnds;
    Assert.IsTrue(elapsed < 1000, Format('the pipe stayed open for %d ms: the detached child inherited a handle', [elapsed]));
  finally
    TTestHelpers.KillWatched(watch);
    probe.Close;
  end;
end;

procedure TWindowsLaunchTests.ExitCode_FullRange_ComesBackUnchanged;
const
  cCodes : array[0..4] of Cardinal = (259, $C0000005, $80000000, $FFFFFFFE, $FFFFFFFF);
var
  i : integer;
  proc : IProcess;
begin
  for i := 0 to High(cCodes) do
  begin
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.Executable := ParamStr(0);
    proc.CommandLine.Add(HelperCommandLine('exit-code', [IntToStr(Int64(cCodes[i]))]), TQuoted.qtNone);
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'exit code ' + IntToStr(Int64(cCodes[i])));
    Assert.AreEqual<Cardinal>(cCodes[i], proc.ExitCode);
    Assert.IsFalse(proc.TimedOut);
  end;
end;

procedure TWindowsLaunchTests.ExitCode_StillActiveValue_AsyncRunLeavesRunning;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := ParamStr(0);
  proc.CommandLine.Add(HelperCommandLine('exit-code', ['259']), TQuoted.qtNone);
  Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
  Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'a child that exited with 259 was taken to be still running');
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.AreEqual<Cardinal>(259, proc.ExitCode);
end;

procedure TWindowsLaunchTests.CommandLine_UnicodeArguments_ReachChildIntact;
var
  proc : IProcess;
  report : IChildReport;
  surrogatePair : string;
  combining : string;
  hebrew : string;
begin
  // U+1F600 as a surrogate pair, e + combining acute accent with a space
  // (so the argument is quoted), and right-to-left text.
  surrogatePair := 'smile-' + #$D83D#$DE00;
  combining := 'e' + #$0301 + ' x';
  hebrew := #$05E9#$05DC#$05D5#$05DD;
  proc := NewChildInfoProcess('-');
  proc.CommandLine.Add(cCjk);
  proc.CommandLine.Add(surrogatePair);
  proc.CommandLine.Add(combining);
  proc.CommandLine.Add(hebrew);
  report := RunForReport(proc);
  Assert.AreEqual<Int64>(4, report.Number('ARGC'), report.Raw);
  Assert.IsTrue(report.Text('ARG1') = cCjk, 'CJK: ' + report.Value('ARG1'));
  Assert.IsTrue(report.Text('ARG2') = surrogatePair, 'surrogate pair: ' + report.Value('ARG2'));
  Assert.IsTrue(report.Text('ARG3') = combining, 'combining mark: ' + report.Value('ARG3'));
  Assert.IsTrue(report.Text('ARG4') = hebrew, 'right-to-left: ' + report.Value('ARG4'));
end;

procedure TWindowsLaunchTests.Environment_UnicodeValue_ReachesChild;
var
  proc : IProcess;
  report : IChildReport;
  value : string;
begin
  value := cCjk + ' ' + #$D83D#$DE00;
  proc := NewChildInfoProcess('-');
  proc.Environment.AddOrSet('VSP_TEST_ENV', value);
  report := RunForReport(proc);
  Assert.IsTrue(report.Text('ENV') = value, report.Value('ENV'));
end;

procedure TWindowsLaunchTests.WorkingDirectory_UnicodePath_ChildStartsThere;
var
  folder : string;
  proc : IProcess;
  report : IChildReport;
begin
  folder := TTestHelpers.TempFileName('vsoft_proc_' + cCjk + '_', '');
  Assert.IsTrue(ForceDirectories(folder), folder);
  try
    proc := NewChildInfoProcess('-');
    proc.StartInfo.WorkingDirectory := folder;
    report := RunForReport(proc);
    Assert.IsTrue(SameText(folder, report.Text('CWD')), report.Value('CWD'));
  finally
    proc := nil;
    RemoveDir(folder);
  end;
end;

procedure TWindowsLaunchTests.Executable_UnicodePath_Runs;
var
  folder : string;
  exeCopy : string;
  proc : IProcess;
  report : IChildReport;
begin
  folder := TTestHelpers.TempFileName('vsoft_proc_' + cCjk + '_', '');
  exeCopy := IncludeTrailingPathDelimiter(folder) + 'helper ' + cCjk + '.exe';
  Assert.IsTrue(ForceDirectories(folder), folder);
  try
    if not CopyFile(PChar(ParamStr(0)), PChar(exeCopy), True) then
      Assert.Fail('could not copy the test exe: ' + SysErrorMessage(GetLastError));
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.Executable := exeCopy;
    proc.CommandLine.Add(HelperCommandLine('child-info', []));
    proc.CommandLine.Add('-');
    proc.CommandLine.Add('ran');
    report := RunForReport(proc);
    Assert.AreEqual('ran', report.Text('ARG1'), report.Raw);
    Assert.IsTrue(SameText(exeCopy, proc.ResolvedExecutable), proc.ResolvedExecutable);
  finally
    proc := nil;
    DeleteFile(exeCopy);
    RemoveDir(folder);
  end;
end;

procedure TWindowsLaunchTests.CommandLine_NearMaximumLength_ReachesChild;
var
  proc : IProcess;
  report : IChildReport;
  payload : string;
begin
  // With the exe path and the helper arguments the line is a few hundred
  // characters longer: comfortably under 32767.
  payload := StringOfChar('a', 29999) + 'z';
  proc := NewChildInfoProcess('-');
  proc.CommandLine.Add(payload);
  report := RunForReport(proc);
  Assert.AreEqual<Integer>(30000, Length(report.Text('ARG1')), 'length');
  Assert.IsTrue(report.Text('ARG1') = payload, 'the argument arrived changed');
end;

procedure TWindowsLaunchTests.CommandLine_OverMaximumLength_LaunchFailsWithOsError;
var
  proc : IProcess;
  report : IChildReport;
begin
  proc := NewChildInfoProcess('-');
  proc.CommandLine.Add(StringOfChar('a', 40000));
  Assert.IsFalse(proc.Execute, 'a command line over 32767 characters cannot be launched');
  Assert.AreNotEqual<Cardinal>(0, proc.LastError, proc.Errors.Text);
  Assert.IsTrue(Trim(proc.Errors.Text) <> '', 'the failure is reported in Errors');
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);

  // The object is still usable.
  proc.CommandLine.Clear;
  SetupChildInfo(proc, '-');
  report := RunForReport(proc);
  Assert.AreEqual<Int64>(0, report.Number('ARGC'), report.Raw);
  Assert.AreEqual<Cardinal>(0, proc.LastError, 'LastError is reset by the next run');
end;

procedure TWindowsLaunchTests.Detached_WorkingDirectory_ChildStartsThere;
var
  folder : string;
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  folder := TTestHelpers.TempFileName('vsoft_proc_cwd_', '');
  Assert.IsTrue(ForceDirectories(folder), folder);
  try
    reportFile := NewReportFile;
    proc := NewChildInfoProcess(reportFile);
    proc.StartInfo.WorkingDirectory := folder;
    report := RunForReportFile(proc, reportFile, true);
    Assert.IsTrue(SameText(folder, report.Text('CWD')), report.Text('CWD'));
  finally
    proc := nil;
    RemoveDir(folder);
  end;
end;

procedure TWindowsLaunchTests.Detached_EnvironmentAndArguments_ReachChild;
var
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.Environment.AddOrSet('VSP_TEST_ENV', 'detached value');
  proc.CommandLine.Add('one');
  proc.CommandLine.Add('two words');
  report := RunForReportFile(proc, reportFile, true);
  Assert.AreEqual('detached value', report.Text('ENV'), report.Raw);
  Assert.AreEqual<Int64>(2, report.Number('ARGC'), report.Raw);
  Assert.AreEqual('one', report.Text('ARG1'), report.Raw);
  Assert.AreEqual('two words', report.Text('ARG2'), report.Raw);
  Assert.AreEqual('none', report.Value('STDOUT'), 'a detached child gets no std handles: ' + report.Raw);
  Assert.AreEqual('no', report.Value('CONSOLE'), report.Raw);
end;

procedure TWindowsLaunchTests.Detached_HostJobRefusesBreakaway_StillLaunches;
var
  hostFile : string;
  childFile : string;
  proc : IProcess;
  hostReport : IChildReport;
  childReport : IChildReport;
begin
  hostFile := TTestHelpers.TempFileName('vsoft_proc_jobhost_', '.txt');
  childFile := TTestHelpers.TempFileName('vsoft_proc_jobchild_', '.txt');
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.Executable := ParamStr(0);
    proc.CommandLine.Add(HelperCommandLine('detach-in-job', []));
    proc.CommandLine.Add(hostFile);
    proc.CommandLine.Add(childFile);
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    hostReport := WaitForChildReport(hostFile, cReportWaitMs);
    Assert.IsTrue(hostReport <> nil, 'the helper never reported');
    if hostReport.Value('JOB-FAILED') <> '' then
      Assert.Pass('NOT RUN: the helper could not put itself in a job, error ' + hostReport.Value('JOB-FAILED'));
    if hostReport.Number('CONTROL') <> ERROR_ACCESS_DENIED then
      Assert.Pass('NOT RUN: a job without BREAKAWAY_OK did not refuse CREATE_BREAKAWAY_FROM_JOB here (' + hostReport.Value('CONTROL') + ')');
    Assert.AreEqual('yes', hostReport.Value('LAUNCHED'), hostReport.Text('ERRORS'));
    Assert.AreEqual<Int64>(0, hostReport.Number('LASTERROR'), hostReport.Raw);
    Assert.AreEqual('', hostReport.Text('ERRORS'), 'the retry is not an error');
    // proc (and with it the job the library made for the helper) is still
    // held here, so the child has not been killed with that job.
    childReport := WaitForChildReport(childFile, cReportWaitMs);
    Assert.IsTrue(childReport <> nil, 'the detached child never ran');
    Assert.AreEqual('yes', childReport.Value('INJOB'), childReport.Raw);
  finally
    proc := nil;
    if FileExists(hostFile) then
      DeleteFile(hostFile);
    if FileExists(childFile) then
      DeleteFile(childFile);
  end;
end;

procedure TWindowsLaunchTests.Detached_OnStartedFires;
var
  proc : IProcess;
  report : IChildReport;
  reportFile : string;
begin
  FStartedCount := 0;
  reportFile := NewReportFile;
  proc := NewChildInfoProcess(reportFile);
  proc.OnStarted := CountStarted;
  report := RunForReportFile(proc, reportFile, true);
  Assert.AreEqual<Integer>(1, FStartedCount, 'OnStarted fires once for a detached launch');
  Assert.AreEqual(TProcessStatus.Running, proc.Status, 'a detached run stays Running');
  Assert.IsFalse(proc.Terminate, 'a detached run cannot be terminated');
end;

procedure TWindowsLaunchTests.Executable_Empty_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  Assert.IsFalse(proc.Execute, 'Execute');
  Assert.Contains(proc.Errors.Text, 'Executable property not set', 'Execute');
  Assert.IsFalse(proc.ExecuteAsync, 'ExecuteAsync');
  Assert.Contains(proc.Errors.Text, 'Executable property not set', 'ExecuteAsync');
  Assert.IsFalse(proc.ExecuteDetached, 'ExecuteDetached');
  Assert.Contains(proc.Errors.Text, 'Executable property not set', 'ExecuteDetached');
  Assert.AreEqual<Cardinal>(0, proc.LastError, 'a validation failure is not an OS error');
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
  Assert.AreEqual('', proc.ResolvedExecutable);
end;

procedure TWindowsLaunchTests.Executable_WithNul_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ShellExePath + #0 + '.txt';
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit 0', TQuoted.qtNone);
  Assert.IsFalse(proc.Execute, 'a NUL would cut the path short');
  Assert.Contains(proc.Errors.Text, 'The executable path contains a NUL character');
  Assert.AreEqual<Cardinal>(0, proc.LastError);
end;

procedure TWindowsLaunchTests.WorkingDirectory_WithNul_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', '');
  proc.StartInfo.WorkingDirectory := GetEnvironmentVariable('SystemRoot') + #0 + 'x';
  Assert.IsFalse(proc.Execute, 'a NUL would cut the path short');
  Assert.Contains(proc.Errors.Text, 'The working directory contains a NUL character');
  Assert.AreEqual<Cardinal>(0, proc.LastError);
end;

procedure TWindowsLaunchTests.ArgumentSeparator_WithNul_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', '');
  proc.CommandLine.DefaultArgumentSeparator := ' ' + #0;
  Assert.IsFalse(proc.Execute, 'a NUL would cut the command line short');
  Assert.Contains(proc.Errors.Text, 'The argument separator contains a NUL character');
  Assert.AreEqual<Cardinal>(0, proc.LastError);
end;

procedure TWindowsLaunchTests.NameValueSeparator_WithNul_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', '');
  proc.CommandLine.Add('-n', 'v');
  proc.CommandLine.Arguments[proc.CommandLine.Count - 1].NameValueSeparator := '=' + #0;
  Assert.IsFalse(proc.Execute, 'a NUL would cut the command line short');
  Assert.Contains(proc.Errors.Text, 'cannot be passed on a command line: it contains a NUL character');
  Assert.AreEqual<Cardinal>(0, proc.LastError);
end;

procedure TWindowsLaunchTests.FailedLaunches_DoNotLeakHandles;
begin
  CheckNoHandleLeak('launches that failed', RunFailedLaunch, 20);
end;

procedure TWindowsLaunchTests.ValidationFailures_DoNotLeakHandles;
begin
  CheckNoHandleLeak('launches refused by validation', RunValidationFailure, 20);
end;

procedure TWindowsLaunchTests.DetachedLaunches_DoNotLeakHandles;
begin
  CheckNoHandleLeak('detached launches', RunDetachedExit, 20);
end;

procedure TWindowsLaunchTests.StdInRuns_DoNotLeakHandles;
begin
  CheckNoHandleLeak('runs with a stdin source', RunWithStdIn, 10);
end;

procedure TWindowsLaunchTests.DeliverOnRunThread_AbandonedRun_DeliversBeforeDone;
var
  target : TSlowCountingTarget;
  targetRef : IPipeTarget;
  proc : IProcess;
begin
  target := TSlowCountingTarget.Create(20);
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.DeliverOnRunThread := True;
  proc.StartInfo.JobMode := TProcessJobMode.NoJob;
  proc.StartInfo.TerminateOnTimeout := False;
  proc.StartInfo.TimeoutInMSec := 500;
  // Writes without pause, so at the timeout a read is on its way to the
  // target. Once the library closes its end of the pipe every echo fails
  // and the loop ends by itself within seconds.
  TTestHelpers.SetupInlineCommand(proc, 'for /L %i in (1,1,200000) do @echo line %i of output for the pipe', '');
  proc.WithStdOutPipe(targetRef);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual(TProcessStatus.TimedOut, proc.Status, proc.Errors.Text);
  Assert.IsTrue(proc.TimedOut);
  Assert.IsTrue(target.Bytes > 0, 'what was read before the timeout is delivered');
  Assert.AreEqual<Integer>(1, target.DoneCount, 'Done is called once');
  Assert.IsFalse(target.DataAfterDone, 'nothing is delivered after Done');
end;

procedure TWindowsLaunchTests.SyncExecuteOnMainThread_QueuedMethodRaises_RunCompletes;
var
  proc : IProcess;
  raiser : TQueueRaiser;
  executed : boolean;
  ranDuringRun : boolean;
  errors : string;
begin
  if GetCurrentThreadId <> MainThreadID then
    Assert.Pass('NOT RUN: the test is not running on the main thread');
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'ping -n 3 127.0.0.1 > nul', '');
  raiser := TQueueRaiser.Create(300);
  try
    executed := proc.Execute;
    ranDuringRun := raiser.Raised;
  finally
    raiser.WaitFor;
    raiser.Free;
    // Had the run ended before the method was queued, it must not be left
    // for a later test to trip over.
    try
      CheckSynchronize;
    except
    end;
  end;
  Assert.IsTrue(executed, proc.Errors.Text);
  Assert.IsTrue(ranDuringRun, 'the run did not service the main thread''s queue');
  Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'the child ran to its end');
  errors := Trim(proc.Errors.Text);
  Assert.IsTrue((errors = '') or (Pos('queued-boom', errors) > 0), 'only the queued method''s exception may be logged: ' + errors);
end;

initialization
  TDUnitX.RegisterTestFixture(TWindowsLaunchTests);
{$ENDIF}

end.
