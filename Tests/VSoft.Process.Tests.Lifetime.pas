unit VSoft.Process.Tests.Lifetime;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  // Who survives what: StartInfo.JobMode (programs the child leaves running,
  // and Terminate's reach) and StartInfo.TerminateOnTimeout (a timeout that
  // leaves the child running).
  [TestFixture]
  TProcessLifetimeTests = class
  public
    [Setup]
    procedure SetUp;

    // JobMode - programs the child leaves running when it exits.
    [Test]
    procedure KillOnRelease_LeftoversKilledByRerunAndRelease;
    [Test]
    procedure KillOnTerminate_LeftoversSurviveRerunAndRelease;
    [Test]
    procedure NoJob_LeftoversSurviveRerunAndRelease;

    // JobMode - Terminate during a run ends the grandchildren in every mode.
    [Test]
    procedure KillOnRelease_TerminateEndsGrandchild;
    [Test]
    procedure KillOnTerminate_TerminateEndsGrandchild;
    [Test]
    procedure NoJob_TerminateEndsGrandchild;

    // TerminateOnTimeout = False.
    [Test]
    procedure TimeoutWithoutTerminate_KillOnTerminate_ChildSurvivesRerunAndRelease;
    [Test]
    procedure TimeoutWithoutTerminate_NoJob_ChildSurvivesRerunAndRelease;
    [Test]
    procedure TimeoutWithoutTerminate_Async_ChildSurvivesRelease;
    [Test]
    procedure TimeoutWithoutTerminate_DeliversEarlierOutputAndStops;
    [Test]
    procedure TimeoutWithoutTerminate_ShortChild_BehavesAsBefore;
    [Test]
    procedure TimeoutWithoutTerminate_WithKillOnRelease_IsRejected;

    // TerminateOnTimeout = True (the default).
    [Test]
    procedure TimeoutWithTerminate_KillsChildAndItsChildren;

    // Terminate / cancellation after the child has exited by itself, while a
    // program it started keeps stdout open and the drain has no time limit.
    [Test]
    procedure TerminateDuringDrain_EndsRunPromptly;
    [Test]
    procedure CancelDuringDrain_EndsRunPromptly;
    {$IFDEF MSWINDOWS}
    [Test]
    procedure KillOnTerminate_TerminateDuringDrain_EndsGrandchild;

    // Terminate ends a program the child started with
    // CREATE_BREAKAWAY_FROM_JOB, which the job doesn't hold.
    [Test]
    procedure Terminate_EndsBreakawayGrandchild;
    // ... and one started that way by a program the child started, which
    // the job kills (so it is gone before the tree can be walked through it).
    [Test]
    procedure Terminate_EndsBreakawayChildOfAnInJobGrandchild;
    // Without a job, programs started while the tree is being killed are
    // ended too. (A guard only: the single-snapshot kill before the tree
    // kill was reworked passed it too, in 25 runs with 4 and 16 threads
    // starting programs, so the walk is not repeated.)
    [Test]
    procedure NoJob_Terminate_EndsProgramsStartedDuringTheKill;
    // Once the run has completed after Terminate, what the child started has
    // gone.
    [Test]
    procedure Terminate_DescendantsGoneWhenRunCompletes;
    {$ENDIF}

    {$IFDEF MSWINDOWS}
    [Test]
    procedure WaitedRuns_DoNotLeakHandles;
    [Test]
    procedure AbandonedRuns_DoNotLeakHandles;
    {$ENDIF}
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  VSoft.Process.Tests.Helper,
  {$ENDIF}
  VSoft.CancellationToken,
  VSoft.Process.Utils,
  VSoft.Process.Tests.Common;

const
  // How long a program that should survive is watched after the event that
  // could have killed it.
  cSurviveMs = 1000;
  // How long a program that should be killed may take to go.
  cKilledMs = 5000;

type
  TLineCollector = class
  private
    FLock : TCriticalSection;
    FLines : TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
    procedure Clear;
    function ValueAfter(const prefix : string) : string;
    function Text : string;
  end;

  // Records every call so a test can see when the target was last used.
  TCallCountingTarget = class(TInterfacedObject, IPipeTarget)
  private
    FLock : TCriticalSection;
    FText : string;
    FDataCalls : integer;
    FDoneCalls : integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    function DataCalls : integer;
    function DoneCalls : integer;
    function Text : string;
  end;

{ TLineCollector }

constructor TLineCollector.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TLineCollector.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited;
end;

procedure TLineCollector.OnLine(const line : string);
begin
  FLock.Enter;
  try
    FLines.Add(line);
  finally
    FLock.Leave;
  end;
end;

procedure TLineCollector.Clear;
begin
  FLock.Enter;
  try
    FLines.Clear;
  finally
    FLock.Leave;
  end;
end;

function TLineCollector.ValueAfter(const prefix : string) : string;
begin
  FLock.Enter;
  try
    result := TTestHelpers.ValueAfter(FLines, prefix);
  finally
    FLock.Leave;
  end;
end;

function TLineCollector.Text : string;
begin
  FLock.Enter;
  try
    result := FLines.Text;
  finally
    FLock.Leave;
  end;
end;

{ TCallCountingTarget }

constructor TCallCountingTarget.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TCallCountingTarget.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TCallCountingTarget.Start;
begin
end;

procedure TCallCountingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  FLock.Enter;
  try
    Inc(FDataCalls);
    FText := FText + TEncoding.ASCII.GetString(data, 0, dataLength);
  finally
    FLock.Leave;
  end;
end;

procedure TCallCountingTarget.Done;
begin
  FLock.Enter;
  try
    Inc(FDoneCalls);
  finally
    FLock.Leave;
  end;
end;

function TCallCountingTarget.DataCalls : integer;
begin
  FLock.Enter;
  try
    result := FDataCalls;
  finally
    FLock.Leave;
  end;
end;

function TCallCountingTarget.DoneCalls : integer;
begin
  FLock.Enter;
  try
    result := FDoneCalls;
  finally
    FLock.Leave;
  end;
end;

function TCallCountingTarget.Text : string;
begin
  FLock.Enter;
  try
    result := FText;
  finally
    FLock.Leave;
  end;
end;

{ helpers }

// spawn-background-and-exit: the child starts a program in the background
// and exits straight away. On Windows the run is not redirected and the
// background ping.exe is found as a child of the child. On POSIX its PID is
// read from stdout; the background program inherits stdout and keeps the
// pipe open, so the drain is kept short.
function NewLeftoverProcess(mode : TProcessJobMode; const collector : TLineCollector) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.JobMode := mode;
  result.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(result, 'spawn-background-and-exit', ['30']);
  {$IFNDEF MSWINDOWS}
  result.StartInfo.PipeDrainTimeoutMS := 300;
  result.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine));
  {$ENDIF}
end;

// Runs the leftover spawner once and returns a watch on what it left running.
function RunLeftoverSpawner(const proc : IProcess; const collector : TLineCollector) : NativeUInt;
var
  pid : Cardinal;
begin
  collector.Clear;
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  {$IFDEF MSWINDOWS}
  pid := TTestHelpers.FindChildProcess(proc.ProcessId, 'ping.exe');
  {$ELSE}
  pid := StrToIntDef(collector.ValueAfter('PID='), 0);
  {$ENDIF}
  Assert.IsTrue(pid <> 0, 'the program the child started in the background was not found');
  result := TTestHelpers.WatchProcess(pid);
  Assert.IsTrue(result <> 0, 'could not open the program the child started in the background');
end;

procedure CheckLeftovers(mode : TProcessJobMode; leftoversSurvive : boolean);
var
  proc : IProcess;
  collector : TLineCollector;
  first : NativeUInt;
  second : NativeUInt;
begin
  first := 0;
  second := 0;
  collector := TLineCollector.Create;
  try
    proc := NewLeftoverProcess(mode, collector);
    first := RunLeftoverSpawner(proc, collector);
    // A second run on the same IProcess.
    second := RunLeftoverSpawner(proc, collector);
    if leftoversSurvive then
      Assert.IsTrue(TTestHelpers.IsRunningAfter(first, cSurviveMs), 'the second run killed what the first run left running')
    else
      Assert.IsTrue(TTestHelpers.HasEndedWithin(first, cKilledMs), 'the second run did not kill what the first run left running');
    proc := nil;
    if leftoversSurvive then
      Assert.IsTrue(TTestHelpers.IsRunningAfter(second, cSurviveMs), 'releasing the IProcess killed what the run left running')
    else
      Assert.IsTrue(TTestHelpers.HasEndedWithin(second, cKilledMs), 'releasing the IProcess did not kill what the run left running');
  finally
    proc := nil;
    TTestHelpers.KillWatched(first);
    TTestHelpers.KillWatched(second);
    collector.Free;
  end;
end;

// spawn-background-and-exit with stdout redirected and no drain time limit:
// the child exits at once and the program it started keeps stdout open, so
// the run stays in the drain until it is stopped. Returns once the run is
// draining, with a watch on that program in watch.
function StartDrainingRun(mode : TProcessJobMode; const collector : TLineCollector; const token : ICancellationToken; out watch : NativeUInt) : IProcess;
var
  deadline : Int64;
  pid : Cardinal;
begin
  watch := 0;
  result := TProcess.Create;
  result.StartInfo.JobMode := mode;
  result.StartInfo.TimeoutInMSec := 60000;
  result.StartInfo.PipeDrainTimeoutMS := INFINITE;
  TTestHelpers.SetupShellCommand(result, 'spawn-background-and-exit', ['30']);
  result.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine));
  Assert.IsTrue(result.ExecuteAsync(token), result.Errors.Text);
  deadline := TTestHelpers.TickMs + 15000;
  while (Pos('parent-done', collector.Text) = 0) and (TTestHelpers.TickMs < deadline) do
    Sleep(50);
  Assert.IsTrue(Pos('parent-done', collector.Text) > 0, 'the child did not run');
  {$IFDEF MSWINDOWS}
  pid := TTestHelpers.FindChildProcess(result.ProcessId, 'ping.exe');
  {$ELSE}
  pid := StrToIntDef(collector.ValueAfter('PID='), 0);
  {$ENDIF}
  watch := TTestHelpers.WatchProcess(pid);
  Assert.IsTrue(watch <> 0, 'the program the child started in the background was not found');
  // Long enough for the child to exit and the run to reach the drain.
  Sleep(500);
  Assert.AreEqual(TProcessStatus.Running, result.Status, 'the run should still be draining');
end;

// spawn-and-wait: the child starts a long-running grandchild, prints its PID
// and waits. Terminate must end the grandchild too.
procedure CheckTerminateEndsGrandchild(mode : TProcessJobMode);
var
  proc : IProcess;
  collector : TLineCollector;
  pid : Cardinal;
  watch : NativeUInt;
  deadline : Int64;
  before : string;
  ended : boolean;
begin
  watch := 0;
  collector := TLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.JobMode := mode;
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupShellCommand(proc, 'spawn-and-wait', ['60']);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
    // With stdin redirected the POSIX child always gets its own process
    // group, whether or not the runner was started from a terminal.
    proc.WithStdInPipe(TPipeSource.FromString(''));
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    deadline := TTestHelpers.TickMs + 15000;
    while (collector.ValueAfter('PID=') = '') and (TTestHelpers.TickMs < deadline) do
      Sleep(50);
    pid := StrToIntDef(collector.ValueAfter('PID='), 0);
    Assert.IsTrue(pid <> 0, 'the grandchild did not report its PID: ' + collector.Text);
    watch := TTestHelpers.WatchProcess(pid);
    Assert.IsTrue(watch <> 0, 'could not open the grandchild');
    before := TTestHelpers.DescribeProcess(proc.ProcessId) + ' / ' + TTestHelpers.DescribeProcess(pid);
    Assert.IsTrue(proc.Terminate, 'Terminate');
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
    ended := TTestHelpers.HasEndedWithin(watch, cKilledMs);
    Assert.IsTrue(ended, 'Terminate did not end the grandchild. Before (child / grandchild): ' + before +
                         '; grandchild after: ' + TTestHelpers.DescribeProcess(pid));
  finally
    proc := nil;
    TTestHelpers.KillWatched(watch);
    collector.Free;
  end;
end;

// Kills a child the test left running, with everything it started.
procedure KillTree(pid : Cardinal; watch : NativeUInt);
begin
  if pid <> 0 then
    TSystemUtils.TerminateProcessTree(pid, 1);
  TTestHelpers.KillWatched(watch);
end;

function NewTimeoutProcess(mode : TProcessJobMode; terminateOnTimeout : boolean) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.JobMode := mode;
  result.StartInfo.TerminateOnTimeout := terminateOnTimeout;
  result.StartInfo.TimeoutInMSec := 500;
  // What FinalBuilder reports for a program still running: STILL_ACTIVE.
  result.StartInfo.TimedOutExitCode := 259;
  TTestHelpers.SetupShellCommand(result, 'sleep', ['30']);
end;

// Runs proc (which times out after 500 ms) and checks the run reports the
// timeout without having killed the child. Returns the child's PID.
function RunAndCheckLeftRunning(const proc : IProcess; async : boolean; out watch : NativeUInt) : Cardinal;
var
  started : Int64;
  elapsed : Int64;
begin
  started := TTestHelpers.TickMs;
  if async then
  begin
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the run did not complete');
  end
  else
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
  elapsed := TTestHelpers.TickMs - started;
  result := proc.ProcessId;
  watch := TTestHelpers.WatchProcess(result);
  Assert.IsTrue(elapsed < 5000, 'the run took ' + IntToStr(elapsed) + 'ms - it waited for the child');
  Assert.IsTrue(proc.TimedOut, 'TimedOut');
  Assert.AreEqual(TProcessStatus.TimedOut, proc.Status);
  Assert.AreEqual<Cardinal>(259, proc.ExitCode, 'ExitCode should be TimedOutExitCode');
  Assert.IsTrue(TTestHelpers.IsRunningAfter(watch, 0), 'the child should still be running when the run completes');
end;

procedure CheckTimeoutLeavesChildRunning(mode : TProcessJobMode);
var
  proc : IProcess;
  firstPid : Cardinal;
  secondPid : Cardinal;
  first : NativeUInt;
  second : NativeUInt;
begin
  firstPid := 0;
  secondPid := 0;
  first := 0;
  second := 0;
  try
    proc := NewTimeoutProcess(mode, false);
    firstPid := RunAndCheckLeftRunning(proc, false, first);
    // A second run on the same IProcess.
    secondPid := RunAndCheckLeftRunning(proc, false, second);
    Assert.IsTrue(TTestHelpers.IsRunningAfter(first, cSurviveMs), 'the second run killed the child the first run left running');
    proc := nil;
    Assert.IsTrue(TTestHelpers.IsRunningAfter(first, cSurviveMs), 'releasing the IProcess killed the first child');
    Assert.IsTrue(TTestHelpers.IsRunningAfter(second, 0), 'releasing the IProcess killed the second child');
  finally
    proc := nil;
    KillTree(firstPid, first);
    KillTree(secondPid, second);
  end;
end;

{ TProcessLifetimeTests }

procedure TProcessLifetimeTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TProcessLifetimeTests.KillOnRelease_LeftoversKilledByRerunAndRelease;
begin
  {$IFDEF MSWINDOWS}
  CheckLeftovers(TProcessJobMode.KillOnRelease, false);
  {$ELSE}
  // POSIX has no job object: leftovers survive in every mode.
  CheckLeftovers(TProcessJobMode.KillOnRelease, true);
  {$ENDIF}
end;

procedure TProcessLifetimeTests.KillOnTerminate_LeftoversSurviveRerunAndRelease;
begin
  CheckLeftovers(TProcessJobMode.KillOnTerminate, true);
end;

procedure TProcessLifetimeTests.NoJob_LeftoversSurviveRerunAndRelease;
begin
  CheckLeftovers(TProcessJobMode.NoJob, true);
end;

procedure TProcessLifetimeTests.KillOnRelease_TerminateEndsGrandchild;
begin
  CheckTerminateEndsGrandchild(TProcessJobMode.KillOnRelease);
end;

procedure TProcessLifetimeTests.KillOnTerminate_TerminateEndsGrandchild;
begin
  CheckTerminateEndsGrandchild(TProcessJobMode.KillOnTerminate);
end;

procedure TProcessLifetimeTests.NoJob_TerminateEndsGrandchild;
begin
  CheckTerminateEndsGrandchild(TProcessJobMode.NoJob);
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_KillOnTerminate_ChildSurvivesRerunAndRelease;
begin
  CheckTimeoutLeavesChildRunning(TProcessJobMode.KillOnTerminate);
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_NoJob_ChildSurvivesRerunAndRelease;
begin
  CheckTimeoutLeavesChildRunning(TProcessJobMode.NoJob);
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_Async_ChildSurvivesRelease;
var
  proc : IProcess;
  pid : Cardinal;
  watch : NativeUInt;
begin
  pid := 0;
  watch := 0;
  try
    proc := NewTimeoutProcess(TProcessJobMode.KillOnTerminate, false);
    pid := RunAndCheckLeftRunning(proc, true, watch);
    proc := nil;
    Assert.IsTrue(TTestHelpers.IsRunningAfter(watch, cSurviveMs), 'releasing the IProcess killed the child');
  finally
    proc := nil;
    KillTree(pid, watch);
  end;
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_DeliversEarlierOutputAndStops;
var
  proc : IProcess;
  target : TCallCountingTarget;
  targetIntf : IPipeTarget;
  pid : Cardinal;
  watch : NativeUInt;
  callsAtCompletion : integer;
  deadline : Int64;
begin
  pid := 0;
  watch := 0;
  target := TCallCountingTarget.Create;
  targetIntf := target;
  try
    proc := TProcess.Create;
    proc.StartInfo.JobMode := TProcessJobMode.KillOnTerminate;
    proc.StartInfo.TerminateOnTimeout := false;
    proc.StartInfo.TimeoutInMSec := 1500;
    TTestHelpers.SetupShellCommand(proc, 'print-then-sleep', ['30']);
    proc.WithStdOutPipe(targetIntf);
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    pid := proc.ProcessId;
    watch := TTestHelpers.WatchProcess(pid);
    Assert.IsTrue(proc.TimedOut, 'TimedOut');
    Assert.Contains(target.Text, 'before-timeout', 'output written before the timeout must be delivered');
    Assert.AreEqual(1, target.DoneCalls, 'Done must have been called when the run completes');
    callsAtCompletion := target.DataCalls;
    // The child is still running; nothing may reach the target any more.
    deadline := TTestHelpers.TickMs + 500;
    while TTestHelpers.TickMs < deadline do
      Sleep(20);
    Assert.AreEqual(callsAtCompletion, target.DataCalls, 'a target was called after the run completed');
    Assert.AreEqual(1, target.DoneCalls);
    Assert.IsTrue(TTestHelpers.IsRunningAfter(watch, 0), 'the child should still be running');
  finally
    proc := nil;
    KillTree(pid, watch);
  end;
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_ShortChild_BehavesAsBefore;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.JobMode := TProcessJobMode.KillOnTerminate;
  proc.StartInfo.TerminateOnTimeout := false;
  proc.StartInfo.TimeoutInMSec := 20000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['7']);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.AreEqual<Cardinal>(7, proc.ExitCode);
  Assert.IsFalse(proc.TimedOut);
end;

procedure TProcessLifetimeTests.TimeoutWithoutTerminate_WithKillOnRelease_IsRejected;
var
  proc : IProcess;
begin
  proc := NewTimeoutProcess(TProcessJobMode.KillOnRelease, false);
  Assert.IsFalse(proc.Execute, 'the combination must be refused');
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
  Assert.AreEqual<Cardinal>(0, proc.ProcessId, 'nothing may be launched');
  Assert.Contains(proc.Errors.Text, 'TerminateOnTimeout');
end;

procedure TProcessLifetimeTests.TimeoutWithTerminate_KillsChildAndItsChildren;
var
  proc : IProcess;
  child : NativeUInt;
  {$IFDEF MSWINDOWS}
  grandchild : NativeUInt;
  pingPid : Cardinal;
  deadline : Int64;
  {$ENDIF}
begin
  child := 0;
  {$IFDEF MSWINDOWS}
  grandchild := 0;
  {$ENDIF}
  try
    proc := NewTimeoutProcess(TProcessJobMode.KillOnRelease, true);
    proc.StartInfo.TimeoutInMSec := 2000;
    proc.StartInfo.TimedOutExitCode := 4321;
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    child := TTestHelpers.WatchProcess(proc.ProcessId);
    {$IFDEF MSWINDOWS}
    // cmd's ping.exe is the child's child.
    pingPid := 0;
    deadline := TTestHelpers.TickMs + 1500;
    while (pingPid = 0) and (TTestHelpers.TickMs < deadline) do
    begin
      pingPid := TTestHelpers.FindChildProcess(proc.ProcessId, 'ping.exe');
      if pingPid = 0 then
        Sleep(20);
    end;
    Assert.IsTrue(pingPid <> 0, 'the child''s ping.exe was not found');
    grandchild := TTestHelpers.WatchProcess(pingPid);
    {$ENDIF}
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the run did not complete');
    Assert.IsTrue(proc.TimedOut, 'TimedOut');
    Assert.AreEqual(TProcessStatus.TimedOut, proc.Status);
    Assert.AreEqual<Cardinal>(4321, proc.ExitCode);
    Assert.IsTrue(TTestHelpers.HasEndedWithin(child, cKilledMs), 'the timeout did not kill the child');
    {$IFDEF MSWINDOWS}
    Assert.IsTrue(TTestHelpers.HasEndedWithin(grandchild, cKilledMs), 'the timeout did not kill the child''s children');
    {$ENDIF}
  finally
    proc := nil;
    TTestHelpers.KillWatched(child);
    {$IFDEF MSWINDOWS}
    TTestHelpers.KillWatched(grandchild);
    {$ENDIF}
  end;
end;

procedure TProcessLifetimeTests.TerminateDuringDrain_EndsRunPromptly;
var
  proc : IProcess;
  collector : TLineCollector;
  watch : NativeUInt;
  started : Int64;
  elapsed : Int64;
begin
  watch := 0;
  collector := TLineCollector.Create;
  try
    proc := StartDrainingRun(TProcessJobMode.KillOnRelease, collector, nil, watch);
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Terminate, 'Terminate did not complete the run');
    elapsed := TTestHelpers.TickMs - started;
    Assert.IsTrue(elapsed < 3000, 'Terminate took ' + IntToStr(elapsed) + 'ms');
    // The child had already exited by itself.
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'truncated');
  finally
    // Ends the drain if Terminate didn't, so releasing proc doesn't wait.
    TTestHelpers.KillWatched(watch);
    proc := nil;
    collector.Free;
  end;
end;

procedure TProcessLifetimeTests.CancelDuringDrain_EndsRunPromptly;
var
  proc : IProcess;
  collector : TLineCollector;
  watch : NativeUInt;
  cts : ICancellationTokenSource;
begin
  watch := 0;
  collector := TLineCollector.Create;
  try
    cts := TCancellationTokenSourceFactory.Create;
    proc := StartDrainingRun(TProcessJobMode.KillOnRelease, collector, cts.Token, watch);
    cts.Cancel;
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 3000), 'cancellation did not end the run');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'truncated');
  finally
    TTestHelpers.KillWatched(watch);
    proc := nil;
    collector.Free;
  end;
end;

{$IFDEF MSWINDOWS}
procedure TProcessLifetimeTests.KillOnTerminate_TerminateDuringDrain_EndsGrandchild;
var
  proc : IProcess;
  collector : TLineCollector;
  watch : NativeUInt;
begin
  watch := 0;
  collector := TLineCollector.Create;
  try
    // KillOnTerminate: releasing the IProcess would leave it running, so only
    // Terminate can have ended it.
    proc := StartDrainingRun(TProcessJobMode.KillOnTerminate, collector, nil, watch);
    Assert.IsTrue(proc.Terminate, 'Terminate did not complete the run');
    Assert.IsTrue(TTestHelpers.HasEndedWithin(watch, cKilledMs), 'Terminate did not end the program holding stdout');
  finally
    TTestHelpers.KillWatched(watch);
    proc := nil;
    collector.Free;
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure RunExitZero(redirect : boolean);
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
  if redirect then
    proc.WithStdOutPipe(TPipeTarget.ToDelegate(
      procedure(const data : TBytes; dataLength : NativeUInt)
      begin
      end));
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode);
end;

procedure RunAbandoned;
var
  proc : IProcess;
  pid : Cardinal;
  watch : NativeUInt;
begin
  pid := 0;
  watch := 0;
  try
    proc := NewTimeoutProcess(TProcessJobMode.KillOnTerminate, false);
    proc.WithStdOutPipe(TPipeTarget.ToDelegate(
      procedure(const data : TBytes; dataLength : NativeUInt)
      begin
      end));
    pid := RunAndCheckLeftRunning(proc, false, watch);
  finally
    proc := nil;
    KillTree(pid, watch);
  end;
end;

procedure TProcessLifetimeTests.WaitedRuns_DoNotLeakHandles;
var
  before : Cardinal;
  after : Cardinal;
  i : integer;
begin
  // The first runs create handles that live for the whole session (threadpool,
  // code page tables, ...).
  RunExitZero(false);
  RunExitZero(true);
  before := TTestHelpers.HandleCount;
  for i := 1 to 10 do
  begin
    RunExitZero(false);
    RunExitZero(true);
  end;
  after := TTestHelpers.HandleCount;
  Assert.IsTrue(after < before + 5, Format('20 runs grew the handle count from %d to %d', [before, after]));
end;

procedure TProcessLifetimeTests.AbandonedRuns_DoNotLeakHandles;
var
  before : Cardinal;
  after : Cardinal;
  i : integer;
begin
  RunAbandoned;
  before := TTestHelpers.HandleCount;
  for i := 1 to 5 do
    RunAbandoned;
  after := TTestHelpers.HandleCount;
  Assert.IsTrue(after < before + 5, Format('5 runs that timed out without killing grew the handle count from %d to %d', [before, after]));
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
// Starts the test exe in a helper mode (VSoft.Process.Tests.Helper), with its
// stdout lines going to collector.
function StartHelper(const mode : string; const args : array of string; jobMode : TProcessJobMode;
                     collector : TLineCollector) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.Executable := ParamStr(0);
  result.StartInfo.JobMode := jobMode;
  result.StartInfo.TimeoutInMSec := 120000;
  result.CommandLine.Add(HelperCommandLine(mode, args), TQuoted.qtNone);
  result.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
  Assert.IsTrue(result.ExecuteAsync, result.Errors.Text);
end;

// Waits for a line starting with one of prefixes; returns the prefix seen.
function WaitForLine(collector : TLineCollector; const prefixes : array of string; timeoutMs : Cardinal) : string;
var
  deadline : Int64;
  i : integer;
begin
  deadline := TTestHelpers.TickMs + timeoutMs;
  repeat
    for i := 0 to High(prefixes) do
      if Pos(#10 + prefixes[i], #10 + collector.Text) > 0 then
        Exit(prefixes[i]);
    Sleep(20);
  until TTestHelpers.TickMs >= deadline;
  result := '';
end;

procedure CheckTerminateEndsBreakaway(const mode : string);
var
  proc : IProcess;
  collector : TLineCollector;
  pid : Cardinal;
  watch : NativeUInt;
  seen : string;
begin
  watch := 0;
  collector := TLineCollector.Create;
  try
    proc := StartHelper(mode, ['60'], TProcessJobMode.KillOnRelease, collector);
    seen := WaitForLine(collector, ['PID=', 'BREAKAWAY-FAILED=', 'START-FAILED='], 15000);
    if seen = 'BREAKAWAY-FAILED=' then
      Assert.Pass('NOT RUN: the host''s job does not allow CREATE_BREAKAWAY_FROM_JOB (' + collector.Text + ')');
    pid := StrToIntDef(collector.ValueAfter('PID='), 0);
    Assert.IsTrue(pid <> 0, 'the helper did not report the program it started: ' + collector.Text);
    watch := TTestHelpers.WatchProcess(pid);
    Assert.IsTrue(watch <> 0, 'could not open the program the helper started');

    Assert.IsTrue(proc.Terminate, 'Terminate');
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
    Assert.IsTrue(TTestHelpers.HasEndedWithin(watch, cKilledMs),
                  'Terminate did not end the program started with CREATE_BREAKAWAY_FROM_JOB');
  finally
    if proc <> nil then
      proc.Terminate;
    proc := nil;
    TTestHelpers.KillWatched(watch);
    collector.Free;
  end;
end;

procedure TProcessLifetimeTests.Terminate_EndsBreakawayGrandchild;
begin
  CheckTerminateEndsBreakaway('breakaway-child');
end;

procedure TProcessLifetimeTests.Terminate_EndsBreakawayChildOfAnInJobGrandchild;
begin
  CheckTerminateEndsBreakaway('in-job-then-breakaway');
end;

procedure TProcessLifetimeTests.NoJob_Terminate_EndsProgramsStartedDuringTheKill;
var
  proc : IProcess;
  collector : TLineCollector;
  helperPid : Cardinal;
  helperCreated : Int64;
  helperWatch : NativeUInt;
  survivors : TArray<Cardinal>;
  deadline : Int64;
  before : integer;
begin
  helperWatch := 0;
  helperPid := 0;
  helperCreated := 0;
  collector := TLineCollector.Create;
  try
    // 8 threads starting pings (20 s each) non-stop, 600 at most.
    proc := StartHelper('spawn-loop', ['8', '600', '20'], TProcessJobMode.NoJob, collector);
    Assert.AreEqual('SPAWNING', WaitForLine(collector, ['SPAWNING'], 15000), 'the helper did not start: ' + collector.Text);
    helperPid := proc.ProcessId;
    // Held so its id is not reused once it has gone.
    helperWatch := TTestHelpers.WatchProcess(helperPid);
    helperCreated := TTestHelpers.ProcessCreationTime(helperPid);
    Assert.IsTrue((helperWatch <> 0) and (helperCreated <> 0), 'could not open the helper');
    before := Length(TTestHelpers.DescendantsOf(helperPid, helperCreated));
    Assert.IsTrue(before > 0, 'the programs the helper started were not found');

    Assert.IsTrue(proc.Terminate, 'Terminate');
    // What was killed may take a moment to go; anything left after that was
    // never killed.
    deadline := TTestHelpers.TickMs + 2000;
    repeat
      survivors := TTestHelpers.DescendantsOf(helperPid, helperCreated);
      if Length(survivors) = 0 then
        Break;
      Sleep(50);
    until TTestHelpers.TickMs >= deadline;
    Assert.AreEqual<integer>(0, Length(survivors), IntToStr(Length(survivors)) +
                    ' programs started by the child were still running 2 s after Terminate (' + IntToStr(before) + ' before it)');
  finally
    if proc <> nil then
      proc.Terminate;
    proc := nil;
    if helperPid <> 0 then
    begin
      TTestHelpers.KillDescendants(helperPid, helperCreated);
      Sleep(200);
      TTestHelpers.KillDescendants(helperPid, helperCreated);
    end;
    TTestHelpers.KillWatched(helperWatch);
    collector.Free;
  end;
end;

procedure TProcessLifetimeTests.Terminate_DescendantsGoneWhenRunCompletes;
var
  proc : IProcess;
  collector : TLineCollector;
  lines : TStringList;
  watches : TArray<NativeUInt>;
  i : integer;
  pid : Cardinal;
  running : integer;
begin
  collector := TLineCollector.Create;
  lines := TStringList.Create;
  try
    proc := StartHelper('spawn-n', ['20', '60'], TProcessJobMode.KillOnRelease, collector);
    Assert.AreEqual('READY', WaitForLine(collector, ['READY'], 30000), 'the helper did not start: ' + collector.Text);
    lines.Text := collector.Text;
    for i := 0 to lines.Count - 1 do
      if Copy(lines[i], 1, 4) = 'PID=' then
      begin
        pid := StrToIntDef(Copy(lines[i], 5, MaxInt), 0);
        if pid <> 0 then
        begin
          SetLength(watches, Length(watches) + 1);
          watches[High(watches)] := TTestHelpers.WatchProcess(pid);
        end;
      end;
    Assert.AreEqual<integer>(20, Length(watches), collector.Text);

    // Returns once the run has completed, as Execute would.
    Assert.IsTrue(proc.Terminate, 'Terminate');
    running := 0;
    for i := 0 to High(watches) do
      if (watches[i] <> 0) and (WaitForSingleObject(watches[i], 0) = WAIT_TIMEOUT) then
        Inc(running);
    Assert.AreEqual(0, running, IntToStr(running) + ' of the programs the child started were still running when the run completed');
  finally
    if proc <> nil then
      proc.Terminate;
    proc := nil;
    for i := 0 to High(watches) do
      TTestHelpers.KillWatched(watches[i]);
    lines.Free;
    collector.Free;
  end;
end;
{$ENDIF}

initialization
  TDUnitX.RegisterTestFixture(TProcessLifetimeTests);

end.
