unit VSoft.Process.Tests.Lifecycle;

interface

uses
  {$IFDEF MSWINDOWS}
  // First, so System.SysUtils.DeleteFile etc. win over the Winapi versions.
  Winapi.Windows,
  {$ENDIF}
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  // End-to-end regression tests for the run lifecycle: re-use, failure
  // isolation, completion semantics, concurrency and bounded draining.
  [TestFixture]
  TProcessLifecycleTests = class
  public
    [Setup]
    procedure SetUp;

    // H12 / H14 / M8 - the same IProcess with targets on both streams run
    // three times (StringBuilder target used to AV, IO buffers leaked).
    [Test]
    procedure Rerun_WithTargetsOnBothStreams_ThreeTimes;

    // C4 - a target that raises must not kill the host or the run; the
    // other target keeps receiving everything and the error is logged.
    [Test]
    procedure ThrowingTarget_SyncExecute_KeepsDrainingAndLogs;

    [Test]
    procedure ThrowingTarget_AsyncExecute_KeepsDrainingAndLogs;

    // C1 / C5 - once Status leaves Running every line has been delivered and
    // Done has been called.
    [Test]
    procedure AsyncStatusExited_ImpliesAllOutputDelivered;

    // H2 - a long-running child spawned concurrently must not inherit a
    // short child's pipes (which would block the short child's Execute).
    [Test]
    procedure ConcurrentSpawns_DoNotInheritEachOthersPipes;

    // Two threads starting the same IProcess: the second is refused even while
    // the first is still inside its start-up (before the run is in progress).
    [Test]
    procedure ConcurrentStart_SameProcess_SecondIsRefused;

    // A stdin source that never returns from GetData must not keep the run
    // from completing once the child has exited.
    [Test]
    procedure StdInSourceNeverReturns_RunStillCompletes;

    // A synchronous Execute on another thread: releasing the last caller
    // reference while its OnExit handler runs must not destroy the process
    // until the handler has returned (the completion event is set before
    // OnExit fires; the run holds its own reference until it has finished).
    // Destroy does not wait for the handler: the run's reference defers the
    // free. Use of a plain object without an interface reference stays
    // unprotected by design.
    [Test]
    procedure SyncExecuteOnOtherThread_ReleaseDuringOnExit_FreedAfterHandler;

    // A synchronous Execute on another thread whose OnExit handler releases,
    // through TThread.Synchronize, the only reference the caller holds: the
    // process must not be destroyed on the main thread, where it would wait
    // for the run while the run waits for the main thread. The deadlock is
    // on the main thread, so a regression hangs this test rather than
    // failing it.
    [Test]
    procedure SyncExecuteOnOtherThread_OnExitSynchronizesLastRelease_NoDeadlock;

    // As above, with the handler handing the release to a thread of its own
    // and waiting for it: a regression fails on the timeout instead.
    [Test]
    procedure SyncExecuteOnOtherThread_OnExitReleasesOnAnotherThread_NoDeadlock;

    // ...nor keep the process alive once the caller has released it, or
    // JobMode KillOnRelease never runs.
    [Test]
    procedure StdInSourceNeverReturns_ProcessNotPinned;

    // M11 - one target attached to stdout and stderr receives every byte.
    [Test]
    procedure SharedTargetOnBothStreams_ReceivesEveryByte;

    // H4 - a grandchild holding stdout must not keep Execute blocked
    // beyond PipeDrainTimeoutMS.
    [Test]
    procedure GrandchildHoldsStdout_ExecuteReturnsAfterDrainTimeout;

    // Stdin writing and stdout reading at the same time with a payload much
    // larger than the pipe buffers.
    [Test]
    procedure LargeStdIn_RoundTripsWithoutDeadlock;

    // M3 - ExecuteAsync validates like Execute.
    [Test]
    procedure ExecuteAsync_InvalidExecutable_ReturnsFalseWithError;

    // M20 - Terminate from OnStarted requests termination without stalling.
    [Test]
    procedure Terminate_FromOnStarted_SyncExecute_DoesNotStall;

    [Test]
    procedure Terminate_FromOnStarted_AsyncExecute_DoesNotStall;

    // Terminate called from inside a pipe target (a threadpool thread on
    // Windows) must not wait for a run that is waiting for that callback.
    [Test]
    procedure Terminate_FromPipeTarget_DoesNotStall;

    // Same for the stdin source, which runs on the stdin writer thread.
    [Test]
    procedure Terminate_FromStdInSource_DoesNotStall;

    [Test]
    procedure SyncExecute_CancelledFromAnotherThread;

    // Terminate(0) from another thread only requests termination: it returns
    // at once, however long the run then takes to complete, and the run
    // still ends Terminated with TerminateExitCode.
    [Test]
    procedure TerminateNoWait_ReturnsAtOnce_RunEndsTerminated;

    // H13 - a long UTF-8 line read through a 4 KB buffer arrives intact.
    [Test]
    procedure Utf8LongLine_StringBuilderTarget_SmallBuffer_Intact;

    // Bytes that are not valid UTF-8 reach the targets as U+FFFD; nothing is
    // raised and nothing is logged.
    [Test]
    procedure InvalidUtf8Output_ReplacedNotRaised;

    // A target slower than PipeDrainTimeoutMS must not lose output the child
    // wrote before it exited, whatever the buffer size and whether the
    // target's cost is per call or per line. Nothing holds the pipe open.
    [Test]
    [TestCase('PerCall_4KB', '4096,400,0')]
    [TestCase('PerCall_64KB', '0,400,0')]
    [TestCase('PerLine_4KB', '4096,0,10')]
    [TestCase('PerLine_64KB', '0,0,10')]
    procedure SlowTarget_ChildExited_AllOutputDelivered(bufferSize : integer; perCallMs : integer; perLineMs : integer);

    // A slow target and a descendant that keeps stdout open (and, on Windows,
    // keeps writing to it): the run still completes, bounded by the drain
    // timeout once what was in the pipe at exit has been delivered.
    [Test]
    procedure SlowTarget_GrandchildHoldsStdout_ExecuteStillReturns;

    // M2 - the object stays usable after ExecuteDetached.
    [Test]
    procedure Detached_ThenExecute_SameObjectReusable;

    // C5 - re-run guard.
    [Test]
    procedure Execute_WhileRunning_Raises;

    [Test]
    procedure WithStdOutPipe_Nil_Raises;

    // M7 - starting the next run from OnExit works.
    [Test]
    procedure RestartFromOnExit_SecondRunCompletes;

    [Test]
    procedure ExitCode_BeforeFirstRun_IsUndefinedMarker;

    {$IFDEF MSWINDOWS}
    // M16 - arguments to a .cmd are quoted for cmd.exe and unsafe ones rejected.
    [Test]
    procedure BatchFile_MetaCharsQuoted_UnsafeRejected;

    // AddUnsafeBatchRaw: the batch file receives exactly what it receives
    // from CreateProcess(nil, '"<bat>" ' + text), byte for byte (%* and
    // %1..%9), for a batch path with and without a space.
    [Test]
    procedure BatchFile_UnsafeRaw_MatchesDirectCreateProcess;

    // ... while the batch path and every other argument are still checked.
    [Test]
    procedure BatchFile_UnsafeRaw_PathAndOtherArgumentsStillChecked;

    // A launch that passes validation but that CreateProcess rejects reports
    // the OS error in LastError and Errors, for every Execute* call.
    [Test]
    procedure LaunchFails_LastErrorIsTheOsError;

    // The launch error names the program in place of the %1 in the Windows
    // message, and never shows the arguments (they can hold secrets).
    [Test]
    procedure LaunchFails_ErrorNamesTheProgramNotItsArguments;

    // StartInfo.InheritHostStdHandles: a stream that is not redirected gets
    // this process's own std handle (here a temp file set with SetStdHandle);
    // by default it gets NUL.
    [Test]
    procedure InheritHostStdHandles_StdErrGoesToHostStdErr;
    [Test]
    procedure Default_UnredirectedStdErrIsNul;
    [Test]
    procedure InheritHostStdHandles_StdInComesFromHostStdIn;
    [Test]
    procedure Default_UnredirectedStdInIsNul;

    // ExecuteDetached gives the child no console by default; with
    // StartInfo.DetachedNewConsole it gets one of its own (hidden here).
    [Test]
    procedure Detached_Default_HasNoConsole;
    [Test]
    procedure DetachedNewConsole_ChildHasAConsole;

    // IProcess.CompletionHandle: no run in progress, so it is signalled.
    [Test]
    procedure CompletionHandle_NewProcess_IsSignalled;

    // ExecuteAsync resets it before returning; it stays reset while the
    // child runs.
    [Test]
    procedure CompletionHandle_WhileRunning_IsNotSignalled;

    // When a wait on it returns, the run has fully completed: Status has
    // left Running, ExitCode is published and all output was delivered.
    [Test]
    procedure CompletionHandle_WaitReturns_RunHasCompleted;

    // A failed validation, a failed launch and ExecuteDetached leave it
    // signalled.
    [Test]
    procedure CompletionHandle_ValidationFails_StaysSignalled;

    [Test]
    procedure CompletionHandle_LaunchFails_StaysSignalled;

    [Test]
    procedure CompletionHandle_ExecuteDetached_StaysSignalled;

    // Waited on with the caller's own event (bWaitAll = False), either one
    // wakes the wait.
    [Test]
    procedure CompletionHandle_WaitForMultipleObjects_WakesForEither;

    // A run that completed before the caller starts waiting is not missed.
    [Test]
    procedure CompletionHandle_RunCompletedBeforeWait_AlreadySignalled;

    // Re-use: the next ExecuteAsync resets it and that run sets it again.
    [Test]
    procedure CompletionHandle_SecondExecuteAsync_ResetsThenSetsAgain;

    // A target raises and logging that fails (out of memory), so an exception
    // leaves the pipe-target isolation and reaches the read callback. The
    // stream stops; that must be logged, not swallowed.
    [Test]
    procedure ReadCallbackException_StopsStreamAndIsLogged;
    {$ENDIF}

    {$IFNDEF MSWINDOWS}
    // H6 - a run without redirection must block, not spin.
    [Test]
    procedure Posix_NoRedirection_DoesNotSpin;

    // Draining after the child has exited (a program it started keeps stdout
    // open) must block, not spin.
    [Test]
    procedure Posix_DrainWhileGrandchildHoldsStdout_DoesNotSpin;

    // H8 - environment overrides must not break PATH lookup.
    [Test]
    procedure Posix_EnvOverride_BareCommandResolvedOnPath;

    // M5 - host file descriptors must not leak into the child.
    [Test]
    procedure Posix_HostFileDescriptors_NotInherited;
    {$ENDIF}

    {$IFDEF LINUX}
    // M4 - the child must not inherit SIGPIPE ignored.
    [Test]
    procedure Linux_Child_SigPipeNotIgnored;
    {$ENDIF}
  end;

implementation

uses
  {$IFNDEF MSWINDOWS}
  Posix.Base,
  Posix.Unistd,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  VSoft.Process.Tests.Helper,
  {$ENDIF}
  VSoft.CancellationToken,
  VSoft.Process.Tests.Common;

type
  TLines = class
  private
    FLock : TCriticalSection;
    FLines : TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
    function Count : integer;
    function Text : string;
  end;

  // Raises from HandleData once it has seen any data.
  TThrowingTarget = class(TInterfacedObject, IPipeTarget)
  public
    Calls : integer;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // A pipe target that records when it is released. The process keeps its
  // targets until it is destroyed, so with no other reference its release
  // marks the destruction of the process.
  TLifetimeTarget = class(TInterfacedObject, IPipeTarget)
  private
    FReleased : PInteger;
  public
    constructor Create(released : PInteger);
    destructor Destroy; override;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // An OnExit handler that signals it has been entered, holds the thread for
  // HoldMs and then records that it returned, and whether the process had
  // been destroyed by then (TargetReleased, set by a TLifetimeTarget).
  TExitHoldProbe = class
  public
    Entered : TEvent;
    HoldMs : Cardinal;
    Returned : integer;
    TargetReleased : integer;
    ReleasedBeforeReturn : integer;
    constructor Create;
    destructor Destroy; override;
    procedure HandleExit(const process : IProcess; exitCode : Cardinal);
  end;

  // An OnExit handler that releases Holder, the only reference the test
  // keeps to the process, on another thread and waits for that release:
  // through TThread.Synchronize (the main thread), or on a thread of its own.
  TLastReleaseProbe = class
  public
    Holder : IProcess;
    UseSynchronize : boolean;
    // Set by a TLifetimeTarget when the process is destroyed.
    Released : integer;
    // Set by the runner once Execute has returned.
    Done : TEvent;
    Dropped : TEvent;
    constructor Create;
    destructor Destroy; override;
    procedure HandleExit(const process : IProcess; exitCode : Cardinal);
  end;

  // A stdin source whose GetData blocks until Release is called.
  TBlockingPipeSource = class(TInterfacedObject, IPipeSource)
  private
    FReleased : TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    function GetData(var data : TBytes; out length : NativeUInt) : boolean;
    procedure Done;
    procedure Release;
  end;

  // A stdout target that ignores its data and sets an event when it is
  // destroyed. A process holds its targets until it is destroyed itself, so
  // the event tells a test when the process has really been freed.
  TLifetimeProbeTarget = class(TInterfacedObject, IPipeTarget)
  private
    FDestroyed : TEvent;
  public
    constructor Create(destroyed : TEvent);
    destructor Destroy; override;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // A cancellation token whose first IsCancelled call blocks until Open is
  // called, which holds the Execute* call that checks it inside its start-up.
  TGateToken = class(TInterfacedObject, ICancellationToken)
  private
    FEntered : TEvent;
    FGate : TEvent;
    FNeverSet : TEvent;
    FCalls : integer;
  public
    constructor Create;
    destructor Destroy; override;
    {$IFDEF MSWINDOWS}
    function GetHandle : THandle;
    {$ELSE}
    function GetEvent : TEvent;
    {$ENDIF}
    function IsCancelled : boolean;
    function WaitFor(timeout : Cardinal) : TWaitResult;
    function WaitEntered(timeoutMs : Cardinal) : boolean;
    procedure Open;
  end;

  // Counts lines and Done calls so a test can check completion ordering.
  TCountingTarget = class(TInterfacedObject, IPipeTarget)
  public
    LineCount : integer;
    DoneCount : integer;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // Counts LF bytes, sleeping in every call to simulate a slow consumer:
  // SleepMs per call plus PerLineMs per line in the call.
  TSlowTarget = class(TInterfacedObject, IPipeTarget)
  public
    SleepMs : Cardinal;
    PerLineMs : Cardinal;
    LineFeeds : integer;
    Calls : integer;
    DoneCount : integer;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // Done takes DelayMs, so a run using it is slow to complete.
  TSlowDoneTarget = class(TInterfacedObject, IPipeTarget)
  public
    DelayMs : Cardinal;
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  TEventProbe = class
  public
    StartedCount : integer;
    ExitCount : integer;
    RestartResult : boolean;
    procedure TerminateOnStarted(const process : IProcess);
    procedure RestartOnFirstExit(const process : IProcess; exitCode : Cardinal);
  end;

  {$IFDEF MSWINDOWS}
  // Sets Exited from OnExit, which fires only after the run has completed.
  TExitSignal = class
  private
    FExited : TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure HandleExit(const process : IProcess; exitCode : Cardinal);
    property Exited : TEvent read FExited;
  end;

  // Raises from HandleData after arranging for the next memory allocation on
  // its thread to fail, so the process's attempt to log the failure raises
  // EOutOfMemory from inside its own exception handler.
  TOutOfMemoryOnLogTarget = class(TInterfacedObject, IPipeTarget)
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;
  {$ENDIF}

{ TLines }

constructor TLines.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TLines.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited;
end;

procedure TLines.OnLine(const line : string);
begin
  FLock.Enter;
  try
    FLines.Add(line);
  finally
    FLock.Leave;
  end;
end;

function TLines.Count : integer;
begin
  FLock.Enter;
  try
    result := FLines.Count;
  finally
    FLock.Leave;
  end;
end;

function TLines.Text : string;
begin
  FLock.Enter;
  try
    result := FLines.Text;
  finally
    FLock.Leave;
  end;
end;

{ TBlockingPipeSource }

constructor TBlockingPipeSource.Create;
begin
  inherited Create;
  FReleased := TEvent.Create(nil, true, false, '');
end;

destructor TBlockingPipeSource.Destroy;
begin
  FReleased.Free;
  inherited;
end;

procedure TBlockingPipeSource.Start;
begin
end;

function TBlockingPipeSource.GetData(var data : TBytes; out length : NativeUInt) : boolean;
begin
  FReleased.WaitFor(INFINITE);
  length := 0;
  result := false;
end;

procedure TBlockingPipeSource.Done;
begin
end;

procedure TBlockingPipeSource.Release;
begin
  FReleased.SetEvent;
end;

{ TGateToken }

constructor TGateToken.Create;
begin
  inherited Create;
  FEntered := TEvent.Create(nil, true, false, '');
  FGate := TEvent.Create(nil, true, false, '');
  FNeverSet := TEvent.Create(nil, true, false, '');
end;

destructor TGateToken.Destroy;
begin
  FNeverSet.Free;
  FGate.Free;
  FEntered.Free;
  inherited;
end;

{$IFDEF MSWINDOWS}
function TGateToken.GetHandle : THandle;
begin
  result := FNeverSet.Handle;
end;
{$ELSE}
function TGateToken.GetEvent : TEvent;
begin
  result := FNeverSet;
end;
{$ENDIF}

function TGateToken.IsCancelled : boolean;
begin
  if TInterlocked.Increment(FCalls) = 1 then
  begin
    FEntered.SetEvent;
    FGate.WaitFor(INFINITE);
  end;
  result := false;
end;

function TGateToken.WaitFor(timeout : Cardinal) : TWaitResult;
begin
  result := FNeverSet.WaitFor(timeout);
end;

function TGateToken.WaitEntered(timeoutMs : Cardinal) : boolean;
begin
  result := FEntered.WaitFor(timeoutMs) = wrSignaled;
end;

procedure TGateToken.Open;
begin
  FGate.SetEvent;
end;

{ TThrowingTarget }

procedure TThrowingTarget.Start;
begin
end;

procedure TThrowingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  Inc(Calls);
  raise Exception.Create('target failure for test');
end;

procedure TThrowingTarget.Done;
begin
end;

{ TCountingTarget }

procedure TCountingTarget.Start;
begin
  LineCount := 0;
  DoneCount := 0;
end;

procedure TCountingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
var
  i : NativeUInt;
begin
  if dataLength = 0 then
    exit;
  for i := 0 to dataLength - 1 do
    if data[i] = 10 then
      Inc(LineCount);
end;

procedure TCountingTarget.Done;
begin
  Inc(DoneCount);
end;

{ TSlowTarget }

procedure TSlowTarget.Start;
begin
  LineFeeds := 0;
  Calls := 0;
end;

procedure TSlowTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
var
  i : NativeUInt;
  lines : Cardinal;
begin
  Inc(Calls);
  lines := 0;
  if dataLength > 0 then
    for i := 0 to dataLength - 1 do
      if data[i] = 10 then
        Inc(lines);
  Inc(LineFeeds, lines);
  Sleep(SleepMs + lines * PerLineMs);
end;

procedure TSlowTarget.Done;
begin
  Inc(DoneCount);
end;

{ TSlowDoneTarget }

procedure TSlowDoneTarget.Start;
begin
end;

procedure TSlowDoneTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TSlowDoneTarget.Done;
begin
  Sleep(DelayMs);
end;

{ TEventProbe }

procedure TEventProbe.TerminateOnStarted(const process : IProcess);
begin
  Inc(StartedCount);
  process.Terminate;
end;

procedure TEventProbe.RestartOnFirstExit(const process : IProcess; exitCode : Cardinal);
begin
  Inc(ExitCount);
  if ExitCount = 1 then
    RestartResult := process.ExecuteAsync;
end;

{$IFDEF MSWINDOWS}
{ TExitSignal }

constructor TExitSignal.Create;
begin
  inherited Create;
  FExited := TEvent.Create(nil, true, false, '');
end;

destructor TExitSignal.Destroy;
begin
  FExited.Free;
  inherited;
end;

procedure TExitSignal.HandleExit(const process : IProcess; exitCode : Cardinal);
begin
  FExited.SetEvent;
end;
{$ENDIF}

{ TProcessLifecycleTests }

procedure TProcessLifecycleTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TProcessLifecycleTests.Rerun_WithTargetsOnBothStreams_ThreeTimes;
var
  proc : IProcess;
  outSB : TStringBuilder;
  errLines : TLines;
  outFile : string;
  run : integer;
begin
  outSB := TStringBuilder.Create;
  errLines := TLines.Create;
  outFile := TTestHelpers.TempFileName('vsoft_rerun_', '.txt');
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 20000;
    TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(outSB));
    proc.WithStdOutPipe(TPipeTarget.ToFile(outFile, False));
    proc.WithStdErrPipe(TPipeTarget.ToLineMethod(errLines.OnLine));
    for run := 1 to 3 do
    begin
      Assert.IsTrue(proc.Execute, 'run ' + IntToStr(run) + ' should start');
      Assert.AreEqual(TProcessStatus.Exited, proc.Status);
      Assert.AreEqual(1, TTestHelpers.CountChar(outSB.ToString, #10),
                      'The StringBuilder target is cleared and refilled every run');
      Assert.Contains(outSB.ToString, 'this-is-stdout');
      Assert.AreEqual(run, errLines.Count, 'One stderr line per run');
      // The file target is rewritten every run, so it holds the output once.
      Assert.AreEqual('this-is-stdout' + sLineBreak, TEncoding.Default.GetString(TTestHelpers.ReadFileBytes(outFile)), False,
                      'The file target must hold this run''s output only');
    end;
    proc := nil;
  finally
    if FileExists(outFile) then
      DeleteFile(outFile);
    errLines.Free;
    outSB.Free;
  end;
end;

procedure TProcessLifecycleTests.ThrowingTarget_SyncExecute_KeepsDrainingAndLogs;
const
  cLines = 2000;
var
  proc : IProcess;
  thrower : TThrowingTarget;
  throwerIntf : IPipeTarget;
  lines : TLines;
begin
  lines := TLines.Create;
  try
    thrower := TThrowingTarget.Create;
    throwerIntf := thrower;
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLines)]);
    proc.WithStdOutPipe(throwerIntf);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    Assert.IsTrue(proc.Execute);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'The child must run to completion');
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.AreEqual(1, thrower.Calls, 'A faulted target receives no more data');
    Assert.AreEqual(cLines, lines.Count, 'The healthy target must still get every line');
    Assert.Contains(proc.Errors.Text, 'target failure for test');
  finally
    lines.Free;
  end;
end;

procedure TProcessLifecycleTests.ThrowingTarget_AsyncExecute_KeepsDrainingAndLogs;
const
  cLines = 2000;
var
  proc : IProcess;
  lines : TLines;
begin
  lines := TLines.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLines)]);
    proc.WithStdOutPipe(TThrowingTarget.Create);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    Assert.IsTrue(proc.ExecuteAsync);
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 30000));
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual(cLines, lines.Count);
    Assert.Contains(proc.Errors.Text, 'target failure for test');
  finally
    lines.Free;
  end;
end;

procedure TProcessLifecycleTests.AsyncStatusExited_ImpliesAllOutputDelivered;
const
  cLines = 2000;
var
  proc : IProcess;
  counter : TCountingTarget;
  counterIntf : IPipeTarget;
  deadline : Int64;
begin
  counter := TCountingTarget.Create;
  counterIntf := counter;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLines)]);
  proc.WithStdOutPipe(counterIntf);
  Assert.IsTrue(proc.ExecuteAsync);
  deadline := TTestHelpers.TickMs + 30000;
  while (proc.Status = TProcessStatus.Running) and (TTestHelpers.TickMs < deadline) do
    Sleep(1);
  Assert.AreNotEqual(TProcessStatus.Running, proc.Status, 'The run did not complete within 30 seconds');
  // No extra waiting: the moment Status changes the run is complete.
  Assert.AreEqual(cLines, counter.LineCount, 'All output must be delivered before Status leaves Running');
  Assert.AreEqual(1, counter.DoneCount, 'Done must have been called before Status leaves Running');
end;

procedure TProcessLifecycleTests.ConcurrentSpawns_DoNotInheritEachOthersPipes;
const
  cShortThreads = 4;
  cShortRuns = 6;
  cSleepers = 6;
var
  sleepers : array[0..cSleepers - 1] of IProcess;
  sleeperThread : TThread;
  shortThreads : array[0..cShortThreads - 1] of TThread;
  maxShortMs : Int64;
  lock : TCriticalSection;
  i : integer;
  failure : string;
begin
  lock := TCriticalSection.Create;
  try
    maxShortMs := 0;
    failure := '';
    // Keep spawning long-running children (with redirected output) while the
    // short runs are in flight, so their CreateProcess calls overlap.
    sleeperThread := TThread.CreateAnonymousThread(
      procedure
      var
        n : integer;
      begin
        for n := 0 to cSleepers - 1 do
        begin
          sleepers[n] := TProcess.Create;
          sleepers[n].StartInfo.TimeoutInMSec := 20000;
          TTestHelpers.SetupShellCommand(sleepers[n], 'sleep', ['5']);
          if n mod 2 = 0 then
            sleepers[n].WithStdOutPipe(TPipeTarget.ToDelegate(
              procedure(const data : TBytes; dataLength : NativeUInt)
              begin
              end));
          sleepers[n].ExecuteAsync;
          Sleep(40);
        end;
      end);
    sleeperThread.FreeOnTerminate := False;
    sleeperThread.Start;

    for i := 0 to cShortThreads - 1 do
    begin
      shortThreads[i] := TThread.CreateAnonymousThread(
        procedure
        var
          n : integer;
          proc : IProcess;
          output : TStringBuilder;
          started : Int64;
          elapsed : Int64;
        begin
          output := TStringBuilder.Create;
          try
            for n := 1 to cShortRuns do
            begin
              proc := TProcess.Create;
              proc.StartInfo.TimeoutInMSec := 20000;
              TTestHelpers.SetupShellCommand(proc, 'echo-args', ['x']);
              proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
              started := TTestHelpers.TickMs;
              proc.Execute;
              elapsed := TTestHelpers.TickMs - started;
              lock.Enter;
              try
                if elapsed > maxShortMs then
                  maxShortMs := elapsed;
                if Pos('arg1=[x]', output.ToString) = 0 then
                  failure := 'short run produced no output: ' + output.ToString;
              finally
                lock.Leave;
              end;
              proc := nil;
            end;
          finally
            output.Free;
          end;
        end);
      shortThreads[i].FreeOnTerminate := False;
      shortThreads[i].Start;
    end;

    for i := 0 to cShortThreads - 1 do
    begin
      shortThreads[i].WaitFor;
      shortThreads[i].Free;
    end;
    sleeperThread.WaitFor;
    sleeperThread.Free;
    for i := 0 to cSleepers - 1 do
      if sleepers[i] <> nil then
      begin
        sleepers[i].Terminate;
        sleepers[i] := nil;
      end;

    Assert.AreEqual('', failure);
    // A short run that inherited (or whose pipe was inherited by) a 5 second
    // sleeper would take ~5s. Normal runs take well under a second.
    Assert.IsTrue(maxShortMs < 3000, 'Slowest short run took ' + IntToStr(maxShortMs) + 'ms - a sleeper held its pipe');
  finally
    lock.Free;
  end;
end;

procedure TProcessLifecycleTests.ConcurrentStart_SameProcess_SecondIsRefused;
var
  proc : IProcess;
  token : TGateToken;
  tokenRef : ICancellationToken;
  starter : TThread;
  firstStarted : boolean;
  refused : boolean;
begin
  token := TGateToken.Create;
  tokenRef := token;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'ping -n 3 127.0.0.1', 'sleep 2');
  firstStarted := false;
  refused := false;
  starter := TThread.CreateAnonymousThread(
    procedure
    begin
      firstStarted := proc.ExecuteAsync(tokenRef);
    end);
  starter.FreeOnTerminate := false;
  starter.Start;
  try
    Assert.IsTrue(token.WaitEntered(10000), 'the first ExecuteAsync did not get as far as checking its token');
    // The first call is held inside its start-up.
    try
      proc.ExecuteAsync;
    except
      on E : EInvalidOpException do
        refused := true;
    end;
    // When it wasn't refused, let that run finish before the first one goes
    // on, so the two never share the object at the same time.
    if not refused then
      TTestHelpers.WaitWhileRunning(proc, 15000);
  finally
    token.Open;
    starter.WaitFor;
    starter.Free;
  end;
  Assert.IsTrue(refused, 'a second ExecuteAsync was allowed while the first was starting');
  Assert.IsTrue(firstStarted, proc.Errors.Text);
  Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the first run did not complete');
end;

procedure TProcessLifecycleTests.StdInSourceNeverReturns_RunStillCompletes;
var
  proc : IProcess;
  source : TBlockingPipeSource;
  sourceRef : IPipeSource;
begin
  source := TBlockingPipeSource.Create;
  sourceRef := source;
  try
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
    proc.WithStdInPipe(sourceRef);
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 8000), 'the run did not complete while the stdin source was blocked in GetData');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'did not return from GetData');
  finally
    // Lets the writer thread finish (and the run, if it is still waiting).
    source.Release;
    proc := nil;
  end;
end;

{ TExitHoldProbe }

constructor TExitHoldProbe.Create;
begin
  inherited Create;
  Entered := TEvent.Create(nil, true, false, '');
end;

destructor TExitHoldProbe.Destroy;
begin
  Entered.Free;
  inherited;
end;

procedure TExitHoldProbe.HandleExit(const process : IProcess; exitCode : Cardinal);
begin
  Entered.SetEvent;
  Sleep(HoldMs);
  TInterlocked.Exchange(ReleasedBeforeReturn, TInterlocked.CompareExchange(TargetReleased, 0, 0));
  TInterlocked.Exchange(Returned, 1);
end;

{ TLifetimeTarget }

constructor TLifetimeTarget.Create(released : PInteger);
begin
  inherited Create;
  FReleased := released;
end;

destructor TLifetimeTarget.Destroy;
begin
  TInterlocked.Exchange(FReleased^, 1);
  inherited;
end;

procedure TLifetimeTarget.Start;
begin
end;

procedure TLifetimeTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TLifetimeTarget.Done;
begin
end;

// In a routine of its own so the IProcess that WithStdOutPipe returns is
// released here, not held by the caller until it returns.
procedure AttachLifetimeTarget(const proc : IProcess; released : PInteger);
var
  target : IPipeTarget;
begin
  target := TLifetimeTarget.Create(released);
  proc.WithStdOutPipe(target);
end;

procedure TProcessLifecycleTests.SyncExecuteOnOtherThread_ReleaseDuringOnExit_FreedAfterHandler;
var
  proc : IProcess;
  rawProc : Pointer;
  probe : TExitHoldProbe;
  runner : TThread;
begin
  probe := TExitHoldProbe.Create;
  try
    probe.HoldMs := 1500;
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
    AttachLifetimeTarget(proc, @probe.TargetReleased);
    proc.OnExit := probe.HandleExit;
    // The runner calls through a raw pointer, so this test's reference is the
    // only one the caller holds: releasing it while Execute is still on the
    // runner's stack.
    rawProc := Pointer(proc);
    runner := TThread.CreateAnonymousThread(
      procedure
      begin
        IProcess(rawProc).Execute;
      end);
    runner.FreeOnTerminate := false;
    runner.Start;
    try
      Assert.AreEqual(wrSignaled, probe.Entered.WaitFor(15000), 'OnExit was never fired');
      // The run has completed (the completion event is set before OnExit).
      proc := nil;
    finally
      runner.WaitFor;
      runner.Free;
    end;
    Assert.AreEqual(1, probe.Returned, 'OnExit never returned');
    Assert.AreEqual(0, probe.ReleasedBeforeReturn,
                    'the process was destroyed while its OnExit handler was still running');
    Assert.AreEqual(1, probe.TargetReleased, 'the process was never destroyed');
  finally
    probe.Free;
  end;
end;

{ TLastReleaseProbe }

constructor TLastReleaseProbe.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, true, false, '');
  Dropped := TEvent.Create(nil, true, false, '');
end;

destructor TLastReleaseProbe.Destroy;
begin
  Done.Free;
  Dropped.Free;
  inherited;
end;

procedure TLastReleaseProbe.HandleExit(const process : IProcess; exitCode : Cardinal);
begin
  if UseSynchronize then
    TThread.Synchronize(nil,
      procedure
      begin
        Holder := nil;
      end)
  else
  begin
    TThread.CreateAnonymousThread(
      procedure
      begin
        Holder := nil;
        Dropped.SetEvent;
      end).Start;
    Dropped.WaitFor(INFINITE);
  end;
end;

// Runs a synchronous Execute on another thread whose OnExit handler releases
// the only reference the caller holds on a third thread (the main thread
// with Synchronize). On a deadlock the runner and the probe are left behind
// rather than hang the suite.
procedure RunLastReleaseFromOnExit(useSynchronize : boolean);
var
  probe : TLastReleaseProbe;
  proc : IProcess;
  rawProc : Pointer;
  runner : TThread;
  deadline : UInt64;
begin
  probe := TLastReleaseProbe.Create;
  probe.UseSynchronize := useSynchronize;
  // Through a local: a function result assigned to a field goes through a
  // hidden temporary that would hold a second reference until this returns.
  proc := TProcess.Create;
  probe.Holder := proc;
  proc := nil;
  TTestHelpers.SetupInlineCommand(probe.Holder, 'exit 0', 'exit 0');
  AttachLifetimeTarget(probe.Holder, @probe.Released);
  probe.Holder.OnExit := probe.HandleExit;
  rawProc := Pointer(probe.Holder);
  runner := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        IProcess(rawProc).Execute;
      finally
        probe.Done.SetEvent;
      end;
    end);
  runner.FreeOnTerminate := false;
  runner.Start;
  // Serves the handler's Synchronize while waiting.
  deadline := TThread.GetTickCount64 + 15000;
  while (probe.Done.WaitFor(0) <> wrSignaled) and (TThread.GetTickCount64 < deadline) do
    CheckSynchronize(10);
  Assert.AreEqual(wrSignaled, probe.Done.WaitFor(0),
                  'deadlock: Execute did not return after OnExit released the last reference');
  runner.WaitFor;
  runner.Free;
  try
    Assert.IsTrue(probe.Holder = nil, 'OnExit did not release the reference');
    Assert.AreEqual(1, probe.Released, 'the process was never destroyed');
  finally
    probe.Free;
  end;
end;

procedure TProcessLifecycleTests.SyncExecuteOnOtherThread_OnExitSynchronizesLastRelease_NoDeadlock;
begin
  RunLastReleaseFromOnExit(true);
end;

procedure TProcessLifecycleTests.SyncExecuteOnOtherThread_OnExitReleasesOnAnotherThread_NoDeadlock;
begin
  RunLastReleaseFromOnExit(false);
end;

{ TLifetimeProbeTarget }

constructor TLifetimeProbeTarget.Create(destroyed : TEvent);
begin
  inherited Create;
  FDestroyed := destroyed;
end;

destructor TLifetimeProbeTarget.Destroy;
begin
  FDestroyed.SetEvent;
  inherited;
end;

procedure TLifetimeProbeTarget.Start;
begin
end;

procedure TLifetimeProbeTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TLifetimeProbeTarget.Done;
begin
end;

// Configured here so the IProcess results of the With* calls (hidden
// temporaries the compiler keeps until the end of the routine) are released
// before the test drops its own reference.
function MakeNeverReturningStdInProcess(const source : IPipeSource; destroyed : TEvent) : IProcess;
begin
  result := TProcess.Create;
  TTestHelpers.SetupInlineCommand(result, 'exit 0', 'exit 0');
  result.WithStdInPipe(source);
  result.WithStdOutPipe(TLifetimeProbeTarget.Create(destroyed));
end;

procedure TProcessLifecycleTests.StdInSourceNeverReturns_ProcessNotPinned;
var
  proc : IProcess;
  source : TBlockingPipeSource;
  sourceRef : IPipeSource;
  destroyed : TEvent;
begin
  destroyed := TEvent.Create(nil, true, false, '');
  source := TBlockingPipeSource.Create;
  sourceRef := source;
  try
    proc := MakeNeverReturningStdInProcess(sourceRef, destroyed);
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.Contains(proc.Errors.Text, 'did not return from GetData', 'the writer must have been left behind for this test');
    proc := nil;
    Assert.AreEqual(wrSignaled, destroyed.WaitFor(2000),
                    'the process was not destroyed: the abandoned stdin writer still holds it');
  finally
    // Lets the writer thread finish; only then can a pinned process go.
    source.Release;
    proc := nil;
    destroyed.WaitFor(5000);
    destroyed.Free;
  end;
end;

procedure TProcessLifecycleTests.SharedTargetOnBothStreams_ReceivesEveryByte;
const
  cLines = '1500';
var
  proc : IProcess;
  outStream, errStream, shared : TMemoryStream;
  sharedTarget : IPipeTarget;
begin
  outStream := TMemoryStream.Create;
  errStream := TMemoryStream.Create;
  shared := TMemoryStream.Create;
  try
    // Reference run with one stream per pipe.
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-both', [cLines]);
    proc.WithStdOutPipe(TPipeTarget.ToStream(outStream));
    proc.WithStdErrPipe(TPipeTarget.ToStream(errStream));
    Assert.IsTrue(proc.Execute);

    // Same output through ONE target attached to both pipes.
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-both', [cLines]);
    sharedTarget := TPipeTarget.ToStream(shared);
    proc.WithStdOutPipe(sharedTarget);
    proc.WithStdErrPipe(sharedTarget);
    Assert.IsTrue(proc.Execute);
    proc := nil;

    Assert.AreEqual<Int64>(outStream.Size + errStream.Size, shared.Size,
                           'A target shared by both pipes must receive every byte exactly once');
  finally
    shared.Free;
    errStream.Free;
    outStream.Free;
  end;
end;

procedure TProcessLifecycleTests.GrandchildHoldsStdout_ExecuteReturnsAfterDrainTimeout;
var
  proc : IProcess;
  lines : TLines;
  started : Int64;
  elapsed : Int64;
begin
  lines := TLines.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.PipeDrainTimeoutMS := 500;
    TTestHelpers.SetupShellCommand(proc, 'spawn-background-and-exit', ['10']);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Execute);
    elapsed := TTestHelpers.TickMs - started;
    Assert.IsTrue(elapsed < 5000, 'Execute took ' + IntToStr(elapsed) + 'ms - it waited for the grandchild');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(lines.Text, 'parent-done');
    Assert.Contains(proc.Errors.Text, 'truncated');
    // Releasing the process closes its job, which ends the grandchild on Windows.
    proc := nil;
  finally
    lines.Free;
  end;
end;

procedure TProcessLifecycleTests.LargeStdIn_RoundTripsWithoutDeadlock;
const
  cLineCount = 20000;
var
  proc : IProcess;
  input : TStringBuilder;
  payload : TBytes;
  output : TMemoryStream;
  i : integer;
  newline : string;
begin
  {$IFDEF MSWINDOWS}
  newline := #13#10;
  {$ELSE}
  newline := #10;
  {$ENDIF}
  input := TStringBuilder.Create;
  output := TMemoryStream.Create;
  try
    for i := 1 to cLineCount do
      input.Append('line ').Append(i).Append(': 0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz').Append(newline);
    payload := TEncoding.ASCII.GetBytes(input.ToString);
    Assert.IsTrue(Length(payload) > 1024 * 1024, 'payload should be well over the pipe buffer size');

    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
    proc.WithStdInPipe(TPipeSource.FromBytes(payload));
    proc.WithStdOutPipe(TPipeTarget.ToStream(output));
    Assert.IsTrue(proc.Execute);
    Assert.IsFalse(proc.TimedOut, 'Writing stdin while reading stdout must not deadlock');
    Assert.AreEqual<Int64>(Length(payload), output.Size, 'Every stdin byte should be echoed back');
  finally
    output.Free;
    input.Free;
  end;
end;

procedure TProcessLifecycleTests.ExecuteAsync_InvalidExecutable_ReturnsFalseWithError;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  {$IFDEF MSWINDOWS}
  proc.StartInfo.Executable := 'C:\vsoft\definitely\not\here.exe';
  {$ELSE}
  proc.StartInfo.Executable := '/vsoft/definitely/not/here';
  {$ENDIF}
  Assert.IsFalse(proc.ExecuteAsync);
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
  Assert.Contains(proc.Errors.Text, 'does not exist');
end;

procedure TProcessLifecycleTests.Terminate_FromOnStarted_SyncExecute_DoesNotStall;
var
  proc : IProcess;
  probe : TEventProbe;
  started : Int64;
  elapsed : Int64;
begin
  probe := TEventProbe.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.TerminateExitCode := 4242;
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
    proc.OnStarted := probe.TerminateOnStarted;
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Execute);
    elapsed := TTestHelpers.TickMs - started;
    Assert.AreEqual(1, probe.StartedCount);
    Assert.IsTrue(elapsed < 4000, 'Execute took ' + IntToStr(elapsed) + 'ms');
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
    Assert.AreEqual<Cardinal>(4242, proc.ExitCode);
  finally
    probe.Free;
  end;
end;

procedure TProcessLifecycleTests.Terminate_FromOnStarted_AsyncExecute_DoesNotStall;
var
  proc : IProcess;
  probe : TEventProbe;
  started : Int64;
  elapsed : Int64;
begin
  probe := TEventProbe.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
    proc.OnStarted := probe.TerminateOnStarted;
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.ExecuteAsync);
    elapsed := TTestHelpers.TickMs - started;
    Assert.IsTrue(elapsed < 2000, 'ExecuteAsync took ' + IntToStr(elapsed) + 'ms - Terminate waited on itself');
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 10000));
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
  finally
    probe.Free;
  end;
end;

type
  // Calls Terminate from its first GetData, then reports "no data yet" until
  // the writer is stopped.
  TTerminatingSource = class(TInterfacedObject, IPipeSource)
  public
    Process : IProcess;
    TerminateMs : Int64;
    TerminateResult : boolean;
    procedure Start;
    function GetData(var data : TBytes; out length : NativeUInt) : boolean;
    procedure Done;
  end;

procedure TTerminatingSource.Start;
begin
end;

function TTerminatingSource.GetData(var data : TBytes; out length : NativeUInt) : boolean;
var
  started : Int64;
begin
  length := 0;
  if Process <> nil then
  begin
    started := TTestHelpers.TickMs;
    TerminateResult := Process.Terminate;
    TerminateMs := TTestHelpers.TickMs - started;
    // Break the process -> source -> process reference cycle.
    Process := nil;
  end
  else
    Sleep(10);
  result := True;
end;

procedure TTerminatingSource.Done;
begin
end;

procedure TProcessLifecycleTests.Terminate_FromPipeTarget_DoesNotStall;
var
  proc : IProcess;
  procRef : IProcess;
  terminateMs : Int64;
  terminateResult : boolean;
  called : boolean;
  started : Int64;
  elapsed : Int64;
begin
  terminateMs := -1;
  terminateResult := false;
  called := false;
  proc := TProcess.Create;
  procRef := proc;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'echo started & ping 127.0.0.1 -n 10 > nul', 'echo started; sleep 10');
  proc.WithStdOutPipe(TPipeTarget.ToDelegate(
    procedure(const data : TBytes; dataLength : NativeUInt)
    var
      callStarted : Int64;
    begin
      if called then
        Exit;
      called := true;
      callStarted := TTestHelpers.TickMs;
      terminateResult := procRef.Terminate;
      terminateMs := TTestHelpers.TickMs - callStarted;
    end));
  try
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Execute);
    elapsed := TTestHelpers.TickMs - started;
  finally
    // The closure holds procRef: release it to break the reference cycle.
    procRef := nil;
  end;
  Assert.IsTrue(called, 'The target never received any output');
  Assert.IsTrue(terminateResult, 'Terminate from a callback reports the request as accepted');
  Assert.IsTrue(terminateMs < 1000, 'Terminate inside HandleData took ' + IntToStr(terminateMs) + 'ms - it waited on itself');
  Assert.IsTrue(elapsed < 5000, 'Execute took ' + IntToStr(elapsed) + 'ms');
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
end;

procedure TProcessLifecycleTests.Terminate_FromStdInSource_DoesNotStall;
var
  proc : IProcess;
  source : TTerminatingSource;
  sourceIntf : IPipeSource;
  started : Int64;
  elapsed : Int64;
begin
  source := TTerminatingSource.Create;
  sourceIntf := source;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  proc.WithStdInPipe(sourceIntf);
  source.Process := proc;
  started := TTestHelpers.TickMs;
  Assert.IsTrue(proc.Execute);
  elapsed := TTestHelpers.TickMs - started;
  source.Process := nil;
  Assert.IsTrue(source.TerminateResult, 'Terminate from the stdin source reports the request as accepted');
  Assert.IsTrue(source.TerminateMs < 1000, 'Terminate inside GetData took ' + IntToStr(source.TerminateMs) + 'ms - it waited on itself');
  Assert.IsTrue(elapsed < 5000, 'Execute took ' + IntToStr(elapsed) + 'ms');
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
end;

procedure TProcessLifecycleTests.SyncExecute_CancelledFromAnotherThread;
var
  proc : IProcess;
  cts : ICancellationTokenSource;
  canceller : TThread;
  started : Int64;
  elapsed : Int64;
begin
  cts := TCancellationTokenSourceFactory.Create;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  proc.StartInfo.TerminateExitCode := 777;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  canceller := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(500);
      cts.Cancel;
    end);
  canceller.FreeOnTerminate := False;
  canceller.Start;
  try
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Execute(cts.Token));
    elapsed := TTestHelpers.TickMs - started;
  finally
    canceller.WaitFor;
    canceller.Free;
  end;
  Assert.IsTrue(elapsed < 5000, 'Cancellation took ' + IntToStr(elapsed) + 'ms');
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
  Assert.AreEqual<Cardinal>(777, proc.ExitCode);
end;

procedure TProcessLifecycleTests.TerminateNoWait_ReturnsAtOnce_RunEndsTerminated;
var
  proc : IProcess;
  target : TSlowDoneTarget;
  started : Int64;
  elapsed : Int64;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  proc.StartInfo.TerminateExitCode := 4242;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['30']);
  // The run takes a second to complete after the kill, so a Terminate that
  // waited for it could not return in time.
  target := TSlowDoneTarget.Create;
  target.DelayMs := 1000;
  proc.WithStdOutPipe(target);
  Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
  Sleep(200);
  Assert.AreEqual(TProcessStatus.Running, proc.Status, 'the child should still be running');

  started := TTestHelpers.TickMs;
  Assert.IsTrue(proc.Terminate(0), 'Terminate(0) with a run in progress');
  elapsed := TTestHelpers.TickMs - started;
  Assert.IsTrue(elapsed < 200, 'Terminate(0) took ' + IntToStr(elapsed) + 'ms');

  Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the run did not complete');
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
  Assert.AreEqual<Cardinal>(4242, proc.ExitCode);
  Assert.IsFalse(proc.Terminate(0), 'no run in progress any more');
end;

procedure TProcessLifecycleTests.Utf8LongLine_StringBuilderTarget_SmallBuffer_Intact;
const
  cChars = 3000;
var
  proc : IProcess;
  output : TStringBuilder;
  expected : string;
  text : string;
  fileName : string;
begin
  // The leading 'x' puts every 2-byte character at an odd offset, so reads
  // of 4096 bytes always end in the middle of one.
  expected := 'x' + StringOfChar(#$00E9, cChars);
  fileName := '';
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.PipeBufferSize := 4096;
    {$IFDEF MSWINDOWS}
    // The child prints the exact UTF-8 bytes from a file: chcp 65001 on the
    // same cmd /c line does not change the code page of that line's echo.
    fileName := TTestHelpers.SetupPrintUtf8(proc, expected);
    {$ELSE}
    TTestHelpers.SetupInlineCommand(proc, '', 'printf ''' + expected + '\n''');
    {$ENDIF}
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    Assert.IsTrue(proc.Execute);
    text := output.ToString;
    Assert.IsTrue(Pos(#$FFFD, text) = 0, 'A character split across reads was replaced with U+FFFD');
    Assert.Contains(text, expected);
  finally
    output.Free;
    if fileName <> '' then
      DeleteFile(fileName);
  end;
end;

procedure TProcessLifecycleTests.InvalidUtf8Output_ReplacedNotRaised;
var
  proc : IProcess;
  lines : TLines;
  output : TStringBuilder;
begin
  lines := TLines.Create;
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-invalid-utf8', []);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine, TEncoding.UTF8));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.AreEqual('', proc.Errors.Text, 'invalid bytes must not raise in a target');
    Assert.AreEqual(2, lines.Count);
    Assert.AreEqual('ab' + #$FFFD + 'cd' + sLineBreak + 'next' + sLineBreak, lines.Text);

    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual('', proc.Errors.Text, 'invalid bytes must not raise in a target');
    Assert.AreEqual('ab' + #$FFFD + 'cd'#13#10'next'#13#10, output.ToString);
  finally
    output.Free;
    lines.Free;
  end;
end;

procedure TProcessLifecycleTests.SlowTarget_ChildExited_AllOutputDelivered(bufferSize : integer; perCallMs : integer; perLineMs : integer);
const
  cLines = 300;
var
  proc : IProcess;
  target : TSlowTarget;
  targetRef : IPipeTarget;
  started : Int64;
  elapsed : Int64;
begin
  // ~21 KB of output: the child has written everything and exited long
  // before the target has caught up, and the target needs far longer than
  // the 200 ms drain timeout for what is left.
  target := TSlowTarget.Create;
  target.SleepMs := perCallMs;
  target.PerLineMs := perLineMs;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  proc.StartInfo.PipeBufferSize := bufferSize;
  proc.StartInfo.PipeDrainTimeoutMS := 200;
  TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLines)]);
  proc.WithStdOutPipe(targetRef);
  started := TTestHelpers.TickMs;
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  elapsed := TTestHelpers.TickMs - started;
  Assert.AreEqual<Cardinal>(0, proc.ExitCode);
  Assert.AreEqual(1, target.DoneCount);
  Assert.AreEqual(cLines, target.LineFeeds,
    Format('lines delivered %d of %d in %d reads, %d ms; errors: %s',
           [target.LineFeeds, cLines, target.Calls, elapsed, proc.Errors.Text]));
end;

procedure TProcessLifecycleTests.SlowTarget_GrandchildHoldsStdout_ExecuteStillReturns;
var
  proc : IProcess;
  target : TSlowTarget;
  targetRef : IPipeTarget;
  started : Int64;
  elapsed : Int64;
begin
  // The grandchild keeps the pipe open for 10 s (on Windows ping also writes
  // a line every second), and every call into the target takes 1 s.
  target := TSlowTarget.Create;
  target.SleepMs := 1000;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  proc.StartInfo.PipeDrainTimeoutMS := 500;
  TTestHelpers.SetupShellCommand(proc, 'spawn-background-and-exit', ['10']);
  proc.WithStdOutPipe(targetRef);
  started := TTestHelpers.TickMs;
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  elapsed := TTestHelpers.TickMs - started;
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.IsTrue(elapsed < 7000, 'Execute took ' + IntToStr(elapsed) + 'ms - it waited for the grandchild');
  Assert.IsTrue(target.LineFeeds >= 1, 'parent-done was not delivered');
  Assert.Contains(proc.Errors.Text, 'truncated');
  proc := nil;
end;

procedure TProcessLifecycleTests.Detached_ThenExecute_SameObjectReusable;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  Assert.IsTrue(proc.ExecuteDetached);
  Assert.IsTrue(proc.Execute, 'Execute after ExecuteDetached must be allowed');
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode);
end;

procedure TProcessLifecycleTests.Execute_WhileRunning_Raises;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  Assert.IsTrue(proc.ExecuteAsync);
  try
    Assert.WillRaise(
      procedure
      begin
        proc.Execute;
      end,
      EInvalidOpException);
  finally
    proc.Terminate;
  end;
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
end;

procedure TProcessLifecycleTests.WithStdOutPipe_Nil_Raises;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  Assert.WillRaise(
    procedure
    begin
      proc.WithStdOutPipe(nil);
    end,
    EArgumentNilException);
end;

procedure TProcessLifecycleTests.RestartFromOnExit_SecondRunCompletes;
var
  proc : IProcess;
  probe : TEventProbe;
  deadline : Int64;
begin
  probe := TEventProbe.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 20000;
    TTestHelpers.SetupShellCommand(proc, 'exit-with', ['3']);
    proc.OnExit := probe.RestartOnFirstExit;
    Assert.IsTrue(proc.ExecuteAsync);
    deadline := TTestHelpers.TickMs + 15000;
    while (probe.ExitCount < 2) and (TTestHelpers.TickMs < deadline) do
      Sleep(10);
    Assert.IsTrue(probe.RestartResult, 'ExecuteAsync from OnExit must start the next run');
    Assert.AreEqual(2, probe.ExitCount, 'The second run must complete');
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 5000));
    Assert.AreEqual<Cardinal>(3, proc.ExitCode);
    proc.OnExit := nil;
  finally
    probe.Free;
  end;
end;

procedure TProcessLifecycleTests.ExitCode_BeforeFirstRun_IsUndefinedMarker;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  Assert.AreEqual<Cardinal>($FFFFFFFF, proc.ExitCode);
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
end;

{$IFDEF MSWINDOWS}
procedure TProcessLifecycleTests.BatchFile_MetaCharsQuoted_UnsafeRejected;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    // Run the .cmd directly (CreateProcess hands it to cmd.exe). Without
    // quoting, cmd splits a,b / c;d / e=f into separate arguments.
    proc := TProcess.Create;
    proc.StartInfo.Executable := TTestHelpers.ScriptPath('echo-args');
    proc.StartInfo.TimeoutInMSec := 20000;
    proc.CommandLine.Add('a,b', TQuoted.qtNone);
    proc.CommandLine.Add('c;d', TQuoted.qtNone);
    proc.CommandLine.Add('e=f', TQuoted.qtNone);
    proc.CommandLine.Add('g h', TQuoted.qtNone);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.Contains(output.ToString, 'arg1=[a,b]',
                    'exit=' + IntToStr(proc.ExitCode) + ' status=' + IntToStr(Ord(proc.Status)) + ' errors=' + proc.Errors.Text);
    Assert.Contains(output.ToString, 'arg2=[c;d]');
    Assert.Contains(output.ToString, 'arg3=[e=f]');
    Assert.Contains(output.ToString, 'arg4=[g h]');
    Assert.Contains(output.ToString, 'total=4');

    proc := TProcess.Create;
    proc.StartInfo.Executable := TTestHelpers.ScriptPath('echo-args');
    proc.CommandLine.Add('%PATH%');
    Assert.IsFalse(proc.Execute, 'Variable expansion cannot be prevented, so the launch must be refused');
    Assert.Contains(proc.Errors.Text, 'cannot be passed safely');
  finally
    output.Free;
  end;
end;

// A batch file that writes %* and %1..%9, as received, to out.txt next to
// itself. The values are taken with "set" before delayed expansion is on and
// written with !var!, so & ( ) ! in them reach the file untouched.
procedure WriteRecordArgsBatch(const fileName : string);
var
  text : string;
  i : integer;
  bytes : TBytes;
  fs : TFileStream;
begin
  text := '@echo off'#13#10 + 'set "all=%*"'#13#10;
  for i := 1 to 9 do
    text := text + 'set "a' + IntToStr(i) + '=%' + IntToStr(i) + '"'#13#10;
  text := text + 'setlocal EnableDelayedExpansion'#13#10 + '> "%~dp0out.txt" ('#13#10 + '  echo(*=[!all!]'#13#10;
  for i := 1 to 9 do
    text := text + '  echo(' + IntToStr(i) + '=[!a' + IntToStr(i) + '!]'#13#10;
  text := text + ')'#13#10;
  bytes := TEncoding.ANSI.GetBytes(text);
  fs := TFileStream.Create(fileName, fmCreate);
  try
    fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

// What the record-args batch wrote, after deleting it for the next run.
function TakeRecordedArgs(const outFile : string) : TBytes;
begin
  SetLength(result, 0);
  if FileExists(outFile) then
  begin
    result := TTestHelpers.ReadFileBytes(outFile);
    DeleteFile(outFile);
  end;
end;

// The reference: the batch file run the way FinalBuilder runs one, with no
// application name and the parameters appended as one string.
function RunBatchDirectly(const batPath : string; const raw : string) : TBytes;
var
  startup : TStartupInfo;
  info : TProcessInformation;
  command : string;
begin
  ZeroMemory(@startup, SizeOf(startup));
  startup.cb := SizeOf(startup);
  startup.dwFlags := STARTF_USESHOWWINDOW;
  startup.wShowWindow := SW_HIDE;
  command := '"' + batPath + '" ' + raw;
  UniqueString(command);
  Win32Check(CreateProcess(nil, PChar(command), nil, nil, False, CREATE_NEW_CONSOLE or CREATE_UNICODE_ENVIRONMENT,
                           nil, nil, startup, info));
  try
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(info.hProcess, 20000), 'the batch file did not finish');
  finally
    CloseHandle(info.hThread);
    CloseHandle(info.hProcess);
  end;
  result := TakeRecordedArgs(ExtractFilePath(batPath) + 'out.txt');
end;

procedure TProcessLifecycleTests.BatchFile_UnsafeRaw_MatchesDirectCreateProcess;
const
  cInputs : array[0..8] of string = ('a b c', '"x y" z', '%PATH%', '!x!', 'a&b', 'a^b', '(a)', '"unclosed', '""');

  procedure CheckFolder(const folder : string; const batName : string);
  var
    batPath : string;
    i : integer;
    expected : TBytes;
    actual : TBytes;
    proc : IProcess;
  begin
    ForceDirectories(folder);
    batPath := IncludeTrailingPathDelimiter(folder) + batName;
    try
      WriteRecordArgsBatch(batPath);
      for i := 0 to High(cInputs) do
      begin
        expected := RunBatchDirectly(batPath, cInputs[i]);
        Assert.IsTrue(Length(expected) > 0, 'the reference run recorded nothing for [' + cInputs[i] + ']');

        proc := TProcess.Create;
        proc.StartInfo.Executable := batPath;
        proc.StartInfo.TimeoutInMSec := 20000;
        proc.CommandLine.AddUnsafeBatchRaw(cInputs[i]);
        Assert.IsTrue(proc.Execute, '[' + cInputs[i] + ']: ' + proc.Errors.Text);
        actual := TakeRecordedArgs(IncludeTrailingPathDelimiter(folder) + 'out.txt');
        Assert.AreEqual(TEncoding.ANSI.GetString(expected), TEncoding.ANSI.GetString(actual),
                        'what ' + batName + ' received for [' + cInputs[i] + ']');
        Assert.IsTrue((Length(expected) = Length(actual)) and CompareMem(@expected[0], @actual[0], Length(expected)),
                      'byte for byte, for [' + cInputs[i] + ']');
      end;
    finally
      proc := nil;
      if FileExists(batPath) then
        DeleteFile(batPath);
      if FileExists(IncludeTrailingPathDelimiter(folder) + 'out.txt') then
        DeleteFile(IncludeTrailingPathDelimiter(folder) + 'out.txt');
      RemoveDir(folder);
    end;
  end;

begin
  CheckFolder(TTestHelpers.TempFileName('vsoft_proc_bat_', ''), 'recordargs.bat');
  CheckFolder(TTestHelpers.TempFileName('vsoft proc bat ', ''), 'record args.cmd');
end;

procedure TProcessLifecycleTests.BatchFile_UnsafeRaw_PathAndOtherArgumentsStillChecked;
var
  proc : IProcess;
  folder : string;
  batPath : string;
begin
  // Another argument is still validated.
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ScriptPath('echo-args');
  proc.CommandLine.AddUnsafeBatchRaw('"%TEMP%" a&b');
  proc.CommandLine.Add('%PATH%');
  Assert.IsFalse(proc.Execute, 'the ordinary argument holds %');
  Assert.Contains(proc.Errors.Text, 'Argument 2 cannot be passed safely');

  // The batch file's own path is still checked.
  folder := TTestHelpers.TempFileName('vproc-%TEMP%-', '');
  ForceDirectories(folder);
  batPath := IncludeTrailingPathDelimiter(folder) + 'recordargs.cmd';
  try
    WriteRecordArgsBatch(batPath);
    proc := TProcess.Create;
    proc.StartInfo.Executable := batPath;
    proc.CommandLine.AddUnsafeBatchRaw('a b');
    Assert.IsFalse(proc.Execute, 'the batch path holds %');
    Assert.Contains(proc.Errors.Text, 'contains % or !');

    // Detected by the name Windows opens, too.
    proc := TProcess.Create;
    proc.StartInfo.Executable := batPath + '.';
    proc.CommandLine.AddUnsafeBatchRaw('a b');
    Assert.IsFalse(proc.Execute, 'the batch path (with a trailing dot) holds %');
    Assert.Contains(proc.Errors.Text, 'contains % or !');
  finally
    proc := nil;
    if FileExists(batPath) then
      DeleteFile(batPath);
    RemoveDir(folder);
  end;
end;

procedure TProcessLifecycleTests.LaunchFails_LastErrorIsTheOsError;
var
  proc : IProcess;
  expectedMessage : string;
begin
  // The file exists, so validation passes, but it is not a program. The
  // message names it in place of the %1 placeholder.
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ScriptsDir + 'invalid-utf8.bin';
  expectedMessage := StringReplace(SysErrorMessage(ERROR_BAD_EXE_FORMAT), '%1', proc.StartInfo.Executable, [rfReplaceAll]);

  Assert.IsFalse(proc.Execute, 'Execute');
  Assert.AreEqual<Cardinal>(ERROR_BAD_EXE_FORMAT, proc.LastError, 'Execute: ' + proc.Errors.Text);
  Assert.Contains(proc.Errors.Text, expectedMessage, 'Execute');

  Assert.IsFalse(proc.ExecuteAsync, 'ExecuteAsync');
  Assert.AreEqual<Cardinal>(ERROR_BAD_EXE_FORMAT, proc.LastError, 'ExecuteAsync: ' + proc.Errors.Text);
  Assert.Contains(proc.Errors.Text, expectedMessage, 'ExecuteAsync');

  Assert.IsFalse(proc.ExecuteDetached, 'ExecuteDetached');
  Assert.AreEqual<Cardinal>(ERROR_BAD_EXE_FORMAT, proc.LastError, 'ExecuteDetached: ' + proc.Errors.Text);
  Assert.Contains(proc.Errors.Text, expectedMessage, 'ExecuteDetached');
end;

procedure TProcessLifecycleTests.LaunchFails_ErrorNamesTheProgramNotItsArguments;
const
  cSecret = 'hunter2-not-for-logs';
var
  proc : IProcess;
  exeName : string;
  textFile : TStringList;

  procedure CheckErrors(const call : string);
  var
    errors : string;
  begin
    errors := proc.Errors.Text;
    // The code depends on the Windows version (216, "This version of %1 is
    // not compatible ...", on Windows 11); its message has a %1 either way.
    Assert.AreNotEqual<Cardinal>(0, proc.LastError, call + ': ' + errors);
    Assert.Contains(errors, exeName, call + ': the error must name the program');
    Assert.AreEqual(0, Pos('%1', errors), call + ': the %1 placeholder must be replaced: ' + errors);
    Assert.AreEqual(0, Pos(cSecret, errors), call + ': the arguments must not be in the error: ' + errors);
  end;

begin
  // A text file renamed to .exe: validation passes and CreateProcess refuses
  // it with an error whose message has a %1 placeholder.
  exeName := TTestHelpers.TempFileName('vsoft_proc_notexe_', '.exe');
  textFile := TStringList.Create;
  try
    textFile.Add('This is a text file, not a program.');
    textFile.SaveToFile(exeName);
  finally
    textFile.Free;
  end;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := exeName;
    proc.CommandLine.Add('--password', cSecret);

    Assert.IsFalse(proc.Execute, 'Execute');
    CheckErrors('Execute');
    Assert.IsFalse(proc.ExecuteAsync, 'ExecuteAsync');
    CheckErrors('ExecuteAsync');
    Assert.IsFalse(proc.ExecuteDetached, 'ExecuteDetached');
    CheckErrors('ExecuteDetached');
  finally
    proc := nil;
    if FileExists(exeName) then
      DeleteFile(exeName);
  end;
end;

// Runs print-stderr with only stdout redirected while this process's
// STD_ERROR_HANDLE is a temp file (stdout is left alone: the test logger
// writes to it), and returns what reached the file.
function RunWithHostStdErrInFile(inheritHost : boolean; out stdOutText : string) : string;
var
  fileName : string;
  fileHandle : THandle;
  oldStdErr : THandle;
  proc : IProcess;
  output : TStringBuilder;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_hosterr_', '.txt');
  fileHandle := CreateFile(PChar(fileName), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  Win32Check(fileHandle <> INVALID_HANDLE_VALUE);
  output := TStringBuilder.Create;
  try
    oldStdErr := GetStdHandle(STD_ERROR_HANDLE);
    SetStdHandle(STD_ERROR_HANDLE, fileHandle);
    try
      proc := TProcess.Create;
      proc.StartInfo.InheritHostStdHandles := inheritHost;
      TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
      Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
    finally
      SetStdHandle(STD_ERROR_HANDLE, oldStdErr);
      CloseHandle(fileHandle);
    end;
    stdOutText := output.ToString;
    result := TEncoding.ANSI.GetString(TTestHelpers.ReadFileBytes(fileName));
  finally
    output.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

// Runs echo-stdin with only stdout redirected while this process's
// STD_INPUT_HANDLE is a temp file holding a line, and returns what the child
// echoed.
function RunWithHostStdInFromFile(inheritHost : boolean) : string;
var
  fileName : string;
  fileHandle : THandle;
  oldStdIn : THandle;
  proc : IProcess;
  output : TStringBuilder;
  lines : TStringList;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_hostin_', '.txt');
  lines := TStringList.Create;
  try
    lines.Add('line-from-host-stdin');
    lines.SaveToFile(fileName);
  finally
    lines.Free;
  end;
  output := TStringBuilder.Create;
  try
    fileHandle := CreateFile(PChar(fileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    Win32Check(fileHandle <> INVALID_HANDLE_VALUE);
    oldStdIn := GetStdHandle(STD_INPUT_HANDLE);
    SetStdHandle(STD_INPUT_HANDLE, fileHandle);
    try
      proc := TProcess.Create;
      proc.StartInfo.InheritHostStdHandles := inheritHost;
      proc.StartInfo.TimeoutInMSec := 20000;
      TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    finally
      SetStdHandle(STD_INPUT_HANDLE, oldStdIn);
      CloseHandle(fileHandle);
    end;
    result := output.ToString;
  finally
    output.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TProcessLifecycleTests.InheritHostStdHandles_StdErrGoesToHostStdErr;
var
  stdOutText : string;
begin
  Assert.Contains(RunWithHostStdErrInFile(true, stdOutText), 'this-is-stderr', 'the child''s stderr should reach the host''s stderr');
  Assert.Contains(stdOutText, 'this-is-stdout', 'stdout is still redirected');
end;

procedure TProcessLifecycleTests.Default_UnredirectedStdErrIsNul;
var
  stdOutText : string;
begin
  Assert.AreEqual('', RunWithHostStdErrInFile(false, stdOutText), 'by default the child''s stderr is NUL');
  Assert.Contains(stdOutText, 'this-is-stdout');
end;

procedure TProcessLifecycleTests.InheritHostStdHandles_StdInComesFromHostStdIn;
begin
  Assert.Contains(RunWithHostStdInFromFile(true), 'line-from-host-stdin', 'the child should read the host''s stdin');
end;

procedure TProcessLifecycleTests.Default_UnredirectedStdInIsNul;
begin
  Assert.AreEqual('', Trim(RunWithHostStdInFromFile(false)), 'by default the child''s stdin is NUL');
end;

// The text of a file another process may still be writing ('' until then).
function ReadMarkerFile(const fileName : string) : string;
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

// Starts the test exe detached, in its console-check helper mode, which
// writes "yes" to a marker file when it has a console and "no" otherwise,
// and returns what it wrote. (cmd's "echo x > CON || echo no" can't report
// "no": without a console cmd drops the rest of the line when the
// redirection fails.)
function RunDetachedConsoleProbe(newConsole : boolean) : string;
var
  proc : IProcess;
  marker : string;
  deadline : Int64;
begin
  result := '';
  marker := TTestHelpers.TempFileName('vsoft_proc_console_', '.txt');
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := ParamStr(0);
    // HideWindow stays True (the default): the console is never shown.
    proc.StartInfo.DetachedNewConsole := newConsole;
    proc.CommandLine.Add(HelperCommandLine('console-check', ['"' + marker + '"']), TQuoted.qtNone);
    Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
    deadline := TTestHelpers.TickMs + 15000;
    while (result = '') and (TTestHelpers.TickMs < deadline) do
    begin
      Sleep(50);
      if FileExists(marker) then
        result := ReadMarkerFile(marker);
    end;
  finally
    if FileExists(marker) then
      DeleteFile(marker);
  end;
end;

procedure TProcessLifecycleTests.Detached_Default_HasNoConsole;
begin
  Assert.AreEqual('no', RunDetachedConsoleProbe(false), 'by default a detached child has no console');
end;

procedure TProcessLifecycleTests.DetachedNewConsole_ChildHasAConsole;
begin
  Assert.AreEqual('yes', RunDetachedConsoleProbe(true), 'with DetachedNewConsole the detached child has a console');
end;

procedure TProcessLifecycleTests.CompletionHandle_NewProcess_IsSignalled;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  Assert.AreNotEqual<THandle>(0, proc.CompletionHandle);
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0));
end;

procedure TProcessLifecycleTests.CompletionHandle_WhileRunning_IsNotSignalled;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
  try
    Assert.AreEqual(TProcessStatus.Running, proc.Status);
    Assert.AreEqual<Cardinal>(WAIT_TIMEOUT, WaitForSingleObject(proc.CompletionHandle, 0),
                              'ExecuteAsync must reset the handle before it returns');
    Assert.AreEqual<Cardinal>(WAIT_TIMEOUT, WaitForSingleObject(proc.CompletionHandle, 300),
                              'The handle must stay reset while the child runs');
    Assert.AreEqual(TProcessStatus.Running, proc.Status);
  finally
    proc.Terminate;
  end;
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status);
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0),
                            'The handle must be set once the terminated run has completed');
end;

procedure TProcessLifecycleTests.CompletionHandle_WaitReturns_RunHasCompleted;
const
  cLines = 500;
  cExitCode = 7;
var
  proc : IProcess;
  counter : TCountingTarget;
  counterIntf : IPipeTarget;
  errLines : TLines;
begin
  errLines := TLines.Create;
  try
    counter := TCountingTarget.Create;
    counterIntf := counter;
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    // print-both, then a non-zero exit code so ExitCode shows the result was
    // published ($FFFFFFFF until then).
    TTestHelpers.SetupInlineCommand(proc,
      'call "' + TTestHelpers.ScriptPath('print-both') + '" ' + IntToStr(cLines) + ' & exit ' + IntToStr(cExitCode), '');
    proc.WithStdOutPipe(counterIntf);
    proc.WithStdErrPipe(TPipeTarget.ToLineMethod(errLines.OnLine));
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 30000));
    // No extra waiting: the run is complete the moment the handle is set.
    Assert.AreNotEqual<TProcessStatus>(TProcessStatus.Running, proc.Status);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(cExitCode, proc.ExitCode);
    Assert.AreEqual(cLines, counter.LineCount, 'All stdout must be delivered before the handle is set');
    Assert.AreEqual(1, counter.DoneCount, 'Done must be called before the handle is set');
    Assert.AreEqual(cLines, errLines.Count, 'All stderr must be delivered before the handle is set');
    proc := nil;
  finally
    errLines.Free;
  end;
end;

procedure TProcessLifecycleTests.CompletionHandle_ValidationFails_StaysSignalled;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'C:\vsoft\definitely\not\here.exe';
  Assert.IsFalse(proc.ExecuteAsync);
  Assert.Contains(proc.Errors.Text, 'does not exist');
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0), 'after ExecuteAsync');
  Assert.IsFalse(proc.Execute);
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0), 'after Execute');
end;

procedure TProcessLifecycleTests.CompletionHandle_LaunchFails_StaysSignalled;
var
  proc : IProcess;
  counter : TCountingTarget;
  counterIntf : IPipeTarget;
begin
  // The file exists, so validation passes, but it is not a program, so
  // CreateProcess fails after the run was marked as in progress.
  counter := TCountingTarget.Create;
  counterIntf := counter;
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ScriptsDir + 'invalid-utf8.bin';
  proc.WithStdOutPipe(counterIntf);
  Assert.IsFalse(proc.ExecuteAsync, 'A file that is not a program must not start');
  // Targets are only started once validation has passed; Done comes from
  // the failed launch being abandoned.
  Assert.AreEqual(1, counter.DoneCount, 'The launch should have got past validation: ' + proc.Errors.Text);
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0));
end;

procedure TProcessLifecycleTests.CompletionHandle_ExecuteDetached_StaysSignalled;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
  // Status stays Running for a detached launch, but no run is in progress.
  Assert.AreEqual(TProcessStatus.Running, proc.Status);
  Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0));
end;

procedure TProcessLifecycleTests.CompletionHandle_WaitForMultipleObjects_WakesForEither;
var
  proc : IProcess;
  other : TEvent;
  setter : TThread;
  handles : array[0..1] of THandle;
begin
  other := TEvent.Create(nil, true, false, '');
  setter := nil;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    // About 3 seconds, so the child is still running when the other event
    // is set.
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['4']);
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    handles[0] := proc.CompletionHandle;
    handles[1] := other.Handle;
    Assert.AreEqual<Cardinal>(WAIT_TIMEOUT, WaitForMultipleObjects(2, @handles[0], False, 0));

    // The other event is set from another thread while this one waits.
    setter := TThread.CreateAnonymousThread(
      procedure
      begin
        Sleep(200);
        other.SetEvent;
      end);
    setter.FreeOnTerminate := False;
    setter.Start;
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0 + 1, WaitForMultipleObjects(2, @handles[0], False, 5000),
                              'The other event must wake the wait while the child runs');
    Assert.AreEqual(TProcessStatus.Running, proc.Status);

    // With the other event reset, only the run's completion can wake it.
    other.ResetEvent;
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForMultipleObjects(2, @handles[0], False, 30000),
                              'Completion must wake the wait');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
  finally
    if setter <> nil then
    begin
      setter.WaitFor;
      setter.Free;
    end;
    other.Free;
  end;
end;

procedure TProcessLifecycleTests.CompletionHandle_RunCompletedBeforeWait_AlreadySignalled;
var
  proc : IProcess;
  signal : TExitSignal;
  other : TEvent;
  handles : array[0..1] of THandle;
begin
  signal := TExitSignal.Create;
  other := TEvent.Create(nil, true, false, '');
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'exit-with', ['5']);
    proc.OnExit := signal.HandleExit;
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    // OnExit fires after the handle is set, so the run has completed before
    // the waits below start.
    Assert.IsTrue(signal.Exited.WaitFor(30000) = wrSignaled, 'OnExit did not fire');
    handles[0] := proc.CompletionHandle;
    handles[1] := other.Handle;
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForMultipleObjects(2, @handles[0], False, 0),
                              'A wait started after completion must return at once');
    // Manual reset: a satisfied wait does not consume the signal.
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(proc.CompletionHandle, 0));
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(5, proc.ExitCode);
  finally
    if proc <> nil then
      proc.OnExit := nil;
    other.Free;
    signal.Free;
  end;
end;

procedure TProcessLifecycleTests.CompletionHandle_SecondExecuteAsync_ResetsThenSetsAgain;
var
  proc : IProcess;
  handle : THandle;
  run : integer;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['3']);
  handle := proc.CompletionHandle;
  for run := 1 to 2 do
  begin
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(handle, 0),
                              'run ' + IntToStr(run) + ': signalled before the run');
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(WAIT_TIMEOUT, WaitForSingleObject(handle, 0),
                              'run ' + IntToStr(run) + ': ExecuteAsync must reset the handle');
    Assert.AreEqual<Cardinal>(WAIT_OBJECT_0, WaitForSingleObject(handle, 30000),
                              'run ' + IntToStr(run) + ': the handle must be set when the run completes');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.AreEqual<THandle>(handle, proc.CompletionHandle, 'The same handle is used for every run');
  end;
end;

// A memory manager that passes everything to the real one, except that the
// first allocation made on thread GFailAllocThreadId fails (once).
var
  GRealMemoryManager : TMemoryManagerEx;
  GFailAllocThreadId : Cardinal;

function TakeFailure : boolean;
begin
  result := (GFailAllocThreadId <> 0) and (GFailAllocThreadId = GetCurrentThreadId);
  if result then
    GFailAllocThreadId := 0;
end;

function FailingGetMem(size : NativeInt) : Pointer;
begin
  if TakeFailure then
    result := nil
  else
    result := GRealMemoryManager.GetMem(size);
end;

function FailingAllocMem(size : NativeInt) : Pointer;
begin
  if TakeFailure then
    result := nil
  else
    result := GRealMemoryManager.AllocMem(size);
end;

function FailingReallocMem(p : Pointer; size : NativeInt) : Pointer;
begin
  if TakeFailure then
    result := nil
  else
    result := GRealMemoryManager.ReallocMem(p, size);
end;

{ TOutOfMemoryOnLogTarget }

procedure TOutOfMemoryOnLogTarget.Start;
begin
end;

procedure TOutOfMemoryOnLogTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
var
  error : Exception;
begin
  error := Exception.Create('target failure for test');
  GFailAllocThreadId := GetCurrentThreadId;
  raise error;
end;

procedure TOutOfMemoryOnLogTarget.Done;
begin
end;

procedure TProcessLifecycleTests.ReadCallbackException_StopsStreamAndIsLogged;
var
  proc : IProcess;
  failing : TMemoryManagerEx;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'echo hello', 'echo hello');
  proc.WithStdOutPipe(TOutOfMemoryOnLogTarget.Create);
  GFailAllocThreadId := 0;
  GetMemoryManager(GRealMemoryManager);
  failing := GRealMemoryManager;
  failing.GetMem := FailingGetMem;
  failing.AllocMem := FailingAllocMem;
  failing.ReallocMem := FailingReallocMem;
  SetMemoryManager(failing);
  try
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
  finally
    SetMemoryManager(GRealMemoryManager);
    GFailAllocThreadId := 0;
  end;
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.Contains(proc.Errors.Text, 'stdout reading stopped', 'the exception that stopped stdout must be logged');
  Assert.Contains(proc.Errors.Text, 'EOutOfMemory');
end;
{$ENDIF}

{$IFNDEF MSWINDOWS}
type
  TTimeVal = record
    tv_sec : NativeInt;
    tv_usec : NativeInt;
  end;
  TRUsage = record
    ru_utime : TTimeVal;
    ru_stime : TTimeVal;
    ru_rest : array[0..13] of NativeInt;
  end;

function getrusage(who : Integer; usage : Pointer) : Integer; cdecl; external libc name 'getrusage';

function ProcessCpuMs : Int64;
var
  usage : TRUsage;
begin
  FillChar(usage, SizeOf(usage), 0);
  getrusage(0, @usage); // RUSAGE_SELF
  result := (Int64(usage.ru_utime.tv_sec) + usage.ru_stime.tv_sec) * 1000 +
            (Int64(usage.ru_utime.tv_usec) + usage.ru_stime.tv_usec) div 1000;
end;

procedure TProcessLifecycleTests.Posix_NoRedirection_DoesNotSpin;
var
  proc : IProcess;
  cpuBefore : Int64;
  cpuUsed : Int64;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 20000;
  TTestHelpers.SetupInlineCommand(proc, '', 'sleep 2');
  cpuBefore := ProcessCpuMs;
  Assert.IsTrue(proc.Execute);
  cpuUsed := ProcessCpuMs - cpuBefore;
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.IsTrue(cpuUsed < 500, 'Waiting 2s for the child used ' + IntToStr(cpuUsed) + 'ms of CPU');
end;

procedure TProcessLifecycleTests.Posix_DrainWhileGrandchildHoldsStdout_DoesNotSpin;
var
  proc : IProcess;
  lines : TLines;
  output : TStringList;
  watch : NativeUInt;
  cpuBefore : Int64;
  cpuUsed : Int64;
begin
  watch := 0;
  lines := TLines.Create;
  output := TStringList.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    proc.StartInfo.PipeDrainTimeoutMS := 1500;
    TTestHelpers.SetupShellCommand(proc, 'spawn-background-and-exit', ['10']);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    cpuBefore := ProcessCpuMs;
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    cpuUsed := ProcessCpuMs - cpuBefore;
    output.Text := lines.Text;
    watch := TTestHelpers.WatchProcess(StrToIntDef(TTestHelpers.ValueAfter(output, 'PID='), 0));
    Assert.Contains(proc.Errors.Text, 'truncated');
    Assert.IsTrue(cpuUsed < 500, 'Draining for 1.5s used ' + IntToStr(cpuUsed) + 'ms of CPU');
  finally
    TTestHelpers.KillWatched(watch);
    output.Free;
    lines.Free;
  end;
end;

procedure TProcessLifecycleTests.Posix_EnvOverride_BareCommandResolvedOnPath;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := 'sh';
    proc.CommandLine.Add('-c');
    proc.CommandLine.Add('printf "%s\n" "$VSOFT_ENV_OVERRIDE"');
    proc.Environment.AddOrSet('VSOFT_ENV_OVERRIDE', 'resolved-on-path');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.Contains(output.ToString, 'resolved-on-path');
  finally
    output.Free;
  end;
end;

procedure TProcessLifecycleTests.Posix_HostFileDescriptors_NotInherited;
var
  proc : IProcess;
  output : TStringBuilder;
  streams : array[0..4] of TFileStream;
  fileName : string;
  i : integer;
  listing : TStringList;
  line : string;
begin
  fileName := TTestHelpers.TempFileName('vsoft_fdleak_', '.txt');
  output := TStringBuilder.Create;
  listing := TStringList.Create;
  try
    for i := 0 to High(streams) do
      streams[i] := TFileStream.Create(fileName, fmCreate or fmShareDenyNone);
    try
      proc := TProcess.Create;
      // One fd number per line. The shell's own fds are 0..2 (plus the one
      // ls uses for the directory), so higher numbers would be ours.
      TTestHelpers.SetupInlineCommand(proc, '', 'ls /dev/fd');
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      listing.Text := output.ToString;
      for i := 0 to High(streams) do
      begin
        line := IntToStr(streams[i].Handle);
        Assert.IsTrue(listing.IndexOf(line) < 0, 'Host fd ' + line + ' is open in the child');
      end;
    finally
      for i := 0 to High(streams) do
        streams[i].Free;
    end;
  finally
    listing.Free;
    output.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;
{$ENDIF}

{$IFDEF LINUX}
procedure TProcessLifecycleTests.Linux_Child_SigPipeNotIgnored;
var
  proc : IProcess;
  output : TStringBuilder;
  text : string;
  maskText : string;
  idx : integer;
  mask : Int64;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    TTestHelpers.SetupInlineCommand(proc, '', 'grep SigIgn /proc/self/status');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    text := output.ToString;
    idx := Pos(':', text);
    Assert.IsTrue(idx > 0, 'unexpected output: ' + text);
    maskText := Trim(Copy(text, idx + 1, MaxInt));
    mask := StrToInt64('$' + maskText);
    // SIGPIPE is signal 13 -> bit 12.
    Assert.IsTrue((mask and (Int64(1) shl 12)) = 0, 'SIGPIPE is ignored in the child (SigIgn ' + maskText + ')');
  finally
    output.Free;
  end;
end;
{$ENDIF}

initialization
  TDUnitX.RegisterTestFixture(TProcessLifecycleTests);

end.
