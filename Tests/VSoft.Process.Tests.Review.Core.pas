unit VSoft.Process.Tests.Review.Core;

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
  // Tests written to prove or disprove the "Core lifecycle and threading"
  // findings of docs\CODE_REVIEW_2026-11-10.md. Each test asserts the
  // documented behaviour, so a failing test means the finding is real.
  [TestFixture]
  TReviewCoreTests = class
  public
    // CORE-1 case A - an asynchronous run whose target calls
    // TThread.Synchronize, stopped with Terminate from the main thread. A
    // failure means Terminate sat out its whole 5 s wait without servicing
    // the Synchronize call and then reported False for a child it did kill.
    [Test]
    procedure CORE1A_TerminateOnMainThread_TargetSynchronizes_DoesNotStall;

    // CORE-1 case B - a synchronous Execute on the main thread whose target
    // calls TThread.Synchronize. Nothing inside the process can break that
    // deadlock, so the scenario runs in a child (the test exe in helper mode
    // review-core-sync-synchronize). A failure means the child had to be
    // killed: Execute never returned.
    [Test]
    procedure CORE1B_SyncExecuteOnMainThread_TargetSynchronizes_Returns;

    // CORE-3 - Terminate(2000) from another thread while ExecuteAsync is
    // still inside OnStarted. A failure means it returned True (documented
    // as "the run has completed") at once, with the run still in progress.
    [Test]
    procedure CORE3_TerminateFromOtherThread_DuringAsyncStart_TrueMeansCompleted;

    // CORE-4 - a Terminate that saw run 1 in progress and is held up until
    // run 2 has started (through a hooked completion event, see
    // TCore4Process). A failure means the stale request killed run 2.
    [Test]
    procedure CORE4_StaleTerminate_DoesNotKillTheNextRun;

    // CORE-5 - one stream aware target attached to stdout and stderr that
    // raises on stdout. A failure means it was still handed the stderr data
    // although a target that raised "receives no more data for that run".
    [Test]
    procedure CORE5_FaultedTarget_OnBothStreams_GetsNoMoreData;

    // CORE-5 - the same for a plain IPipeTarget (HandleData for both
    // streams) that raises on its first call. A failure means it was called
    // again for the other stream.
    [Test]
    procedure CORE5_FaultedPlainTarget_OnBothStreams_IsNotCalledAgain;

    // CORE-6 - a target whose Done raises an object that is not an
    // Exception. A failure means the raise escaped Execute and / or the run
    // never completed: Status stuck at Running, later Execute calls refused.
    [Test]
    procedure CORE6_TargetDoneRaisesNonException_RunStillCompletes;

    // CORE-6 - the targets after the one whose Done raised. A failure means
    // their Done was skipped.
    [Test]
    procedure CORE6_TargetDoneRaisesNonException_LaterTargetsStillGetDone;

    // CORE-6 - the same for the stdin source's Done. A failure means the run
    // never completed.
    [Test]
    procedure CORE6_SourceDoneRaisesNonException_RunStillCompletes;

    {$IFDEF MSWINDOWS}
    // CORE-6 - the failed launch path (AbortStart): the OS refuses the
    // program and the target's Done raises a non-Exception object. A failure
    // means the raise escaped Execute and / or the object can't be run again.
    [Test]
    procedure CORE6_FailedLaunch_TargetDoneRaisesNonException_ObjectStaysUsable;
    {$ENDIF}

    // CORE-7 - README: a detached launch ignores the timeout and JobMode. A
    // failure means ExecuteDetached was refused by the TerminateOnTimeout /
    // JobMode validation rule.
    [Test]
    procedure CORE7_Detached_IgnoresTerminateOnTimeoutAndJobMode;

    // CORE-7 - a detached launch that fails validation started nothing. A
    // failure means ExitCode / TimedOut raise as if a detached child existed,
    // instead of reading $FFFFFFFF / False as after any failed Execute*.
    [Test]
    procedure CORE7_DetachedValidationFails_ExitCodeAndTimedOutDoNotRaise;
  end;

// Helper mode review-core-sync-synchronize of the test exe (CORE-1 case B).
// Runs a short child synchronously on the main thread with a target that
// calls TThread.Synchronize, prints what happened and sets ExitCode to 0 when
// Execute returned with the child's output delivered.
procedure RunReviewCoreSyncSynchronizeHelper;

implementation

uses
  System.TypInfo,
  VSoft.Process.Base,
  {$IFDEF MSWINDOWS}
  VSoft.Process.Windows,
  {$ELSE}
  VSoft.Process.Posix,
  {$ENDIF}
  VSoft.Process.Tests.Helper,
  VSoft.Process.Tests.Common;

const
  cSyncHelperMode = 'review-core-sync-synchronize';

type
  {$IFDEF MSWINDOWS}
  TPlatformProcess = TWindowsProcess;
  {$ELSE}
  TPlatformProcess = TPosixProcess;
  {$ENDIF}

  // Calls TThread.Synchronize for every chunk, as a target that updates a
  // VCL / FMX control would.
  TSynchronizingTarget = class(TInterfacedObject, IPipeTarget)
  private
    FEntered : Integer;
    FSyncCalls : Integer;
    procedure OnMainThread;
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    function Entered : boolean;
    property SyncCalls : Integer read FSyncCalls;
  end;

  TCore3TerminateThread = class(TThread)
  private
    FProcess : IProcess;
    FTerminateResult : boolean;
    FStatusAtReturn : TProcessStatus;
    FElapsedMs : Int64;
  protected
    procedure Execute;override;
  public
    constructor Create(const process : IProcess);
    property TerminateResult : boolean read FTerminateResult;
    property StatusAtReturn : TProcessStatus read FStatusAtReturn;
    property ElapsedMs : Int64 read FElapsedMs;
  end;

  TCore3Probe = class
  private
    FCalled : boolean;
    FTerminateResult : boolean;
    FStatusAtReturn : TProcessStatus;
    FElapsedMs : Int64;
  public
    procedure HandleStarted(const process : IProcess);
    property Called : boolean read FCalled;
    property TerminateResult : boolean read FTerminateResult;
    property StatusAtReturn : TProcessStatus read FStatusAtReturn;
    property ElapsedMs : Int64 read FElapsedMs;
  end;

  // The seam for CORE-4. Terminate decides "a run is in progress" with
  // FCompletionEvent.WaitFor(0) and only then sets the terminate event. For
  // the armed thread, the first WaitFor(0) that reports "in progress" is held
  // back after the check has been made, until the test releases it (or the
  // hold times out). That is the calling thread being preempted between the
  // check and the set.
  THookedCompletionEvent = class(TEvent)
  private
    FArmed : Integer;
    FHookThreadId : TThreadID;
    FChecked : TEvent;
    FRelease : TEvent;
  public
    constructor CreateHooked;
    destructor Destroy;override;
    function WaitFor(Timeout : Cardinal) : TWaitResult;overload;override;
    // Called by the thread that is about to call Terminate.
    procedure ArmForCurrentThread;
    function WaitForCheck(timeoutMs : Cardinal) : boolean;
    procedure ReleaseHold;
  end;

  // A process whose completion event is a THookedCompletionEvent.
  TCore4Process = class(TPlatformProcess)
  private
    FHook : THookedCompletionEvent;
  public
    constructor Create;override;
    property Hook : THookedCompletionEvent read FHook;
  end;

  TCore4TerminateThread = class(TThread)
  private
    FProcess : IProcess;
    FHook : THookedCompletionEvent;
    FTerminateResult : boolean;
  protected
    procedure Execute;override;
  public
    constructor Create(const process : IProcess; hook : THookedCompletionEvent);
    property TerminateResult : boolean read FTerminateResult;
  end;

  // Raises on every stdout chunk and counts what it is given.
  TThrowOnStdOutTarget = class(TInterfacedObject, IPipeTarget, IStreamAwarePipeTarget)
  private
    FOutCalls : Integer;
    FErrCalls : Integer;
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    property OutCalls : Integer read FOutCalls;
    property ErrCalls : Integer read FErrCalls;
  end;

  // Not stream aware: raises on its first call, whichever stream it is for.
  TThrowOnFirstCallTarget = class(TInterfacedObject, IPipeTarget)
  private
    FCalls : Integer;
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    property Calls : Integer read FCalls;
  end;

  TNonExceptionDoneTarget = class(TInterfacedObject, IPipeTarget)
  private
    FDoneCalls : Integer;
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    property DoneCalls : Integer read FDoneCalls;
  end;

  TDoneCountingTarget = class(TInterfacedObject, IPipeTarget)
  private
    FDoneCalls : Integer;
  public
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    property DoneCalls : Integer read FDoneCalls;
  end;

  // Has no data; its Done raises an object that is not an Exception.
  TNonExceptionDoneSource = class(TInterfacedObject, IPipeSource)
  public
    procedure Start;
    function GetData(var data : TBytes; out length : NativeUInt) : boolean;
    procedure Done;
  end;

  // What a run with a Done that raises a non-Exception object did.
  TCore6Result = record
    // The raise came out of the first Execute.
    Escaped : boolean;
    FirstResult : boolean;
    StatusAfter : TProcessStatus;
    // The second Execute was refused with EInvalidOpException.
    SecondRefused : boolean;
    SecondMessage : string;
  end;

// The errors are read after the call that fills them in.
procedure CheckStarted(started : boolean; const proc : IProcess; const what : string);
begin
  Assert.IsTrue(started, what + ': ' + proc.Errors.Text);
end;

function IsOnMainThread : boolean;
begin
  result := CurrentThreadId = MainThreadID;
end;

{ TSynchronizingTarget }

procedure TSynchronizingTarget.Start;
begin
end;

procedure TSynchronizingTarget.OnMainThread;
begin
  Inc(FSyncCalls);
end;

procedure TSynchronizingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  TInterlocked.Exchange(FEntered, 1);
  TThread.Synchronize(nil, OnMainThread);
end;

procedure TSynchronizingTarget.Done;
begin
end;

function TSynchronizingTarget.Entered : boolean;
begin
  result := TInterlocked.CompareExchange(FEntered, 0, 0) <> 0;
end;

{ TCore3TerminateThread }

constructor TCore3TerminateThread.Create(const process : IProcess);
begin
  FProcess := process;
  inherited Create(false);
end;

procedure TCore3TerminateThread.Execute;
var
  started : Int64;
begin
  try
    started := TTestHelpers.TickMs;
    FTerminateResult := FProcess.Terminate(2000);
    FStatusAtReturn := FProcess.Status;
    FElapsedMs := TTestHelpers.TickMs - started;
  finally
    FProcess := nil;
  end;
end;

{ TCore3Probe }

procedure TCore3Probe.HandleStarted(const process : IProcess);
var
  thread : TCore3TerminateThread;
begin
  FCalled := true;
  thread := TCore3TerminateThread.Create(process);
  try
    thread.WaitFor;
    FTerminateResult := thread.TerminateResult;
    FStatusAtReturn := thread.StatusAtReturn;
    FElapsedMs := thread.ElapsedMs;
  finally
    thread.Free;
  end;
end;

{ THookedCompletionEvent }

constructor THookedCompletionEvent.CreateHooked;
begin
  // As TProcessBase creates it: manual reset, signalled (no run in progress).
  inherited Create(nil, true, true, '');
  FChecked := TEvent.Create(nil, true, false, '');
  FRelease := TEvent.Create(nil, true, false, '');
end;

destructor THookedCompletionEvent.Destroy;
begin
  FChecked.Free;
  FRelease.Free;
  inherited;
end;

procedure THookedCompletionEvent.ArmForCurrentThread;
begin
  FHookThreadId := CurrentThreadId;
  TInterlocked.Exchange(FArmed, 1);
end;

function THookedCompletionEvent.WaitFor(Timeout : Cardinal) : TWaitResult;
const
  cHoldMs = 15000;
begin
  result := inherited WaitFor(Timeout);
  if (Timeout = 0) and (result <> wrSignaled) and (CurrentThreadId = FHookThreadId) and
     (TInterlocked.CompareExchange(FArmed, 0, 1) = 1) then
  begin
    FChecked.SetEvent;
    FRelease.WaitFor(cHoldMs);
  end;
end;

function THookedCompletionEvent.WaitForCheck(timeoutMs : Cardinal) : boolean;
begin
  result := FChecked.WaitFor(timeoutMs) = wrSignaled;
end;

procedure THookedCompletionEvent.ReleaseHold;
begin
  FRelease.SetEvent;
end;

{ TCore4Process }

constructor TCore4Process.Create;
begin
  inherited;
  FCompletionEvent.Free;
  FHook := THookedCompletionEvent.CreateHooked;
  FCompletionEvent := FHook;
end;

{ TCore4TerminateThread }

constructor TCore4TerminateThread.Create(const process : IProcess; hook : THookedCompletionEvent);
begin
  FProcess := process;
  FHook := hook;
  inherited Create(false);
end;

procedure TCore4TerminateThread.Execute;
begin
  try
    FHook.ArmForCurrentThread;
    FTerminateResult := FProcess.Terminate(0);
  finally
    FProcess := nil;
  end;
end;

{ TThrowOnStdOutTarget }

procedure TThrowOnStdOutTarget.Start;
begin
end;

procedure TThrowOnStdOutTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  HandleStreamData(false, data, dataLength);
end;

procedure TThrowOnStdOutTarget.HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
begin
  if isStdErr then
    Inc(FErrCalls)
  else
  begin
    Inc(FOutCalls);
    raise Exception.Create('boom');
  end;
end;

procedure TThrowOnStdOutTarget.Done;
begin
end;

{ TThrowOnFirstCallTarget }

procedure TThrowOnFirstCallTarget.Start;
begin
end;

procedure TThrowOnFirstCallTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  Inc(FCalls);
  if FCalls = 1 then
    raise Exception.Create('boom');
end;

procedure TThrowOnFirstCallTarget.Done;
begin
end;

{ TNonExceptionDoneTarget }

procedure TNonExceptionDoneTarget.Start;
begin
end;

procedure TNonExceptionDoneTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TNonExceptionDoneTarget.Done;
begin
  Inc(FDoneCalls);
  raise TObject.Create;
end;

{ TDoneCountingTarget }

procedure TDoneCountingTarget.Start;
begin
end;

procedure TDoneCountingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TDoneCountingTarget.Done;
begin
  Inc(FDoneCalls);
end;

{ TNonExceptionDoneSource }

procedure TNonExceptionDoneSource.Start;
begin
end;

function TNonExceptionDoneSource.GetData(var data : TBytes; out length : NativeUInt) : boolean;
begin
  length := 0;
  result := false;
end;

procedure TNonExceptionDoneSource.Done;
begin
  raise TObject.Create;
end;

// Runs proc twice and records what happened, without letting a raise out.
function RunTwice(const proc : IProcess) : TCore6Result;
begin
  result.Escaped := false;
  result.FirstResult := false;
  result.SecondRefused := false;
  result.SecondMessage := '';
  try
    result.FirstResult := proc.Execute;
  except
    result.Escaped := true;
  end;
  result.StatusAfter := proc.Status;
  try
    proc.Execute;
  except
    on E : EInvalidOpException do
    begin
      result.SecondRefused := true;
      result.SecondMessage := E.Message;
    end;
    else
      ;
  end;
end;

function DescribeCore6(const outcome : TCore6Result) : string;
begin
  result := ' (Status afterwards = ' + GetEnumName(TypeInfo(TProcessStatus), Ord(outcome.StatusAfter));
  if outcome.SecondRefused then
    result := result + ', a second Execute was refused: ' + outcome.SecondMessage + ')'
  else
    result := result + ', a second Execute was accepted)';
end;

// Releases a process a CORE-6 test may have left "in progress" for good. The
// destructor of such an object waits for the completion event forever, so on
// Windows the event is signalled here first (test cleanup only). POSIX has no
// handle to it: the stuck object is leaked rather than hanging the suite.
procedure ReleaseAfterCore6(var proc : IProcess; stuck : boolean);
begin
  {$IFDEF MSWINDOWS}
  if WaitForSingleObject(proc.CompletionHandle, 0) <> WAIT_OBJECT_0 then
    SetEvent(proc.CompletionHandle);
  proc := nil;
  {$ELSE}
  if stuck then
    Pointer(proc) := nil
  else
    proc := nil;
  {$ENDIF}
end;

procedure RunReviewCoreSyncSynchronizeHelper;
var
  proc : IProcess;
  target : TSynchronizingTarget;
  targetRef : IPipeTarget;
  started : boolean;
begin
  ExitCode := 3;
  target := TSynchronizingTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 5000;
  TTestHelpers.SetupInlineCommand(proc, 'echo started', 'echo started');
  proc.WithStdOutPipe(targetRef);
  // Hangs here for good when the finding is real; the test kills this process.
  started := proc.Execute;
  Writeln('EXECUTE=' + BoolToStr(started, true) + ' STATUS=' + IntToStr(Ord(proc.Status)) +
          ' SYNCCALLS=' + IntToStr(target.SyncCalls));
  Flush(Output);
  if started and (proc.Status = TProcessStatus.Exited) and (target.SyncCalls > 0) then
    ExitCode := 0;
end;

{ TReviewCoreTests }

procedure TReviewCoreTests.CORE1A_TerminateOnMainThread_TargetSynchronizes_DoesNotStall;
var
  proc : IProcess;
  target : TSynchronizingTarget;
  targetRef : IPipeTarget;
  deadline : Int64;
  started : Int64;
  elapsed : Int64;
  entered : boolean;
  terminated : boolean;
  completed : boolean;
begin
  if not IsOnMainThread then
    Assert.Pass('Skipped: the test is not running on the main thread');
  target := TSynchronizingTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupInlineCommand(proc, 'echo started & ping 127.0.0.1 -n 30 > nul', 'echo started; sleep 30');
  proc.WithStdOutPipe(targetRef);
  CheckStarted(proc.ExecuteAsync, proc, 'ExecuteAsync');
  terminated := false;
  elapsed := -1;
  try
    // No CheckSynchronize here: the callback has to be left blocked in
    // Synchronize, as it is while a UI thread handles a button click.
    deadline := TTestHelpers.TickMs + 15000;
    while (not target.Entered) and (TTestHelpers.TickMs < deadline) do
      Sleep(10);
    entered := target.Entered;
    if entered then
    begin
      Sleep(200);
      started := TTestHelpers.TickMs;
      terminated := proc.Terminate;
      elapsed := TTestHelpers.TickMs - started;
    end;
  finally
    // Whatever happened, let the run finish: the callback needs the main
    // thread to service its Synchronize before the run can complete.
    proc.Terminate(0);
    deadline := TTestHelpers.TickMs + 30000;
    while (proc.Status = TProcessStatus.Running) and (TTestHelpers.TickMs < deadline) do
      CheckSynchronize(10);
    completed := proc.Status <> TProcessStatus.Running;
  end;
  Assert.IsTrue(entered, 'The target never received any output');
  Assert.IsTrue(completed, 'The run did not complete within 30 s of the main thread servicing Synchronize');
  Assert.IsTrue(terminated, 'Terminate returned False after ' + IntToStr(elapsed) + 'ms although the child was killed');
  Assert.IsTrue(elapsed < 3000, 'Terminate took ' + IntToStr(elapsed) + 'ms');
end;

procedure TReviewCoreTests.CORE1B_SyncExecuteOnMainThread_TargetSynchronizes_Returns;
const
  cDeadlineMs = 20000;
var
  proc : IProcess;
  output : TStringBuilder;
  text : string;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := ParamStr(0);
    proc.CommandLine.Add(HelperCommandLine(cSyncHelperMode, []), TQuoted.qtNone);
    // Kills the helper (and what it started) when it has not finished.
    proc.StartInfo.TimeoutInMSec := cDeadlineMs;
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    CheckStarted(proc.Execute, proc, 'Execute');
    text := Trim(output.ToString);
    Assert.AreEqual(0, Pos('Unknown helper mode', text),
                    'Helper mode ' + cSyncHelperMode + ' is not registered in RunTestHelperMode');
    Assert.IsFalse(proc.TimedOut, 'A synchronous Execute on the main thread with a target that calls TThread.Synchronize had not returned after ' +
                                  IntToStr(cDeadlineMs) + 'ms (the helper process was killed). Helper output: [' + text + ']');
    Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'Helper output: [' + text + ']');
  finally
    proc := nil;
    output.Free;
  end;
end;

procedure TReviewCoreTests.CORE3_TerminateFromOtherThread_DuringAsyncStart_TrueMeansCompleted;
var
  proc : IProcess;
  probe : TCore3Probe;
  ended : boolean;
begin
  probe := TCore3Probe.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
    proc.OnStarted := probe.HandleStarted;
    CheckStarted(proc.ExecuteAsync, proc, 'ExecuteAsync');
    // The request made from the handler stands, so the run ends by itself.
    ended := TTestHelpers.WaitWhileRunning(proc, 15000);
    if not ended then
      proc.Terminate;
    Assert.IsTrue(probe.Called, 'OnStarted was not called');
    Assert.IsTrue(ended, 'The run did not end after Terminate');
    Assert.IsFalse(probe.TerminateResult and (probe.StatusAtReturn in [TProcessStatus.Idle, TProcessStatus.Running]),
                   'Terminate(2000) from another thread returned True after ' + IntToStr(probe.ElapsedMs) +
                   'ms while the run was still in progress (Status = ' + IntToStr(Ord(probe.StatusAtReturn)) +
                   '): True must mean the run has completed');
  finally
    proc := nil;
    probe.Free;
  end;
end;

procedure TReviewCoreTests.CORE4_StaleTerminate_DoesNotKillTheNextRun;
const
  cRunExitCode = 7;
var
  procObj : TCore4Process;
  proc : IProcess;
  hook : THookedCompletionEvent;
  thread : TCore4TerminateThread;
  seamReached : boolean;
  firstEnded : boolean;
  firstStatus : TProcessStatus;
  secondStarted : boolean;
  secondEnded : boolean;
begin
  procObj := TCore4Process.Create;
  proc := procObj;
  hook := procObj.Hook;
  proc.StartInfo.TimeoutInMSec := 30000;
  // Each run lasts about two seconds and ends with its own exit code.
  TTestHelpers.SetupInlineCommand(proc, 'ping 127.0.0.1 -n 3 > nul & exit 7', 'sleep 2; exit 7');
  secondStarted := false;
  firstStatus := TProcessStatus.Idle;
  CheckStarted(proc.ExecuteAsync, proc, 'ExecuteAsync');
  thread := TCore4TerminateThread.Create(proc, hook);
  try
    try
      // The other thread has seen run 1 in progress and is now held between
      // that check and setting the terminate event.
      seamReached := hook.WaitForCheck(10000);
      // Run 1 ends on its own.
      firstEnded := TTestHelpers.WaitWhileRunning(proc, 15000);
      if firstEnded then
      begin
        firstStatus := proc.Status;
        secondStarted := proc.ExecuteAsync;
      end;
    finally
      // Run 2 is in progress: let the stale Terminate carry on.
      hook.ReleaseHold;
      thread.WaitFor;
    end;
    secondEnded := TTestHelpers.WaitWhileRunning(proc, 15000);
    if not secondEnded then
      proc.Terminate;
    Assert.IsTrue(seamReached, 'Test seam not reached: Terminate no longer checks the completion event with WaitFor(0) on the calling thread, so this test proves nothing and needs reworking');
    Assert.IsTrue(firstEnded, 'Run 1 did not end');
    Assert.AreEqual(TProcessStatus.Exited, firstStatus, 'Run 1 was meant to end on its own');
    Assert.IsTrue(secondStarted, 'Run 2 did not start: ' + proc.Errors.Text);
    Assert.IsTrue(secondEnded, 'Run 2 did not end');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'Run 2 was ended by a Terminate that was aimed at run 1');
    Assert.AreEqual<Cardinal>(cRunExitCode, proc.ExitCode);
  finally
    thread.Free;
    proc := nil;
  end;
end;

procedure TReviewCoreTests.CORE5_FaultedTarget_OnBothStreams_GetsNoMoreData;
var
  proc : IProcess;
  target : TThrowOnStdOutTarget;
  targetRef : IPipeTarget;
begin
  target := TThrowOnStdOutTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'echo out & ping 127.0.0.1 -n 2 > nul & echo err 1>&2',
                                  'echo out; sleep 1; echo err 1>&2');
  proc.WithStdOutPipe(targetRef);
  proc.WithStdErrPipe(targetRef);
  CheckStarted(proc.Execute, proc, 'Execute');
  Assert.AreEqual(1, target.OutCalls, 'stdout calls');
  Assert.AreEqual(0, target.ErrCalls, 'A target that raised must get no more data this run, but it was given stderr. Errors: ' + proc.Errors.Text);
end;

procedure TReviewCoreTests.CORE5_FaultedPlainTarget_OnBothStreams_IsNotCalledAgain;
var
  proc : IProcess;
  target : TThrowOnFirstCallTarget;
  targetRef : IPipeTarget;
begin
  target := TThrowOnFirstCallTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'echo out & ping 127.0.0.1 -n 2 > nul & echo err 1>&2',
                                  'echo out; sleep 1; echo err 1>&2');
  proc.WithStdOutPipe(targetRef);
  proc.WithStdErrPipe(targetRef);
  CheckStarted(proc.Execute, proc, 'Execute');
  Assert.AreEqual(1, target.Calls, 'A target that raised must get no more data this run, but it was called again for the other stream. Errors: ' + proc.Errors.Text);
end;

procedure TReviewCoreTests.CORE6_TargetDoneRaisesNonException_RunStillCompletes;
var
  proc : IProcess;
  target : TNonExceptionDoneTarget;
  targetRef : IPipeTarget;
  outcome : TCore6Result;
begin
  target := TNonExceptionDoneTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  proc.WithStdOutPipe(targetRef);
  outcome := RunTwice(proc);
  ReleaseAfterCore6(proc, outcome.SecondRefused);
  Assert.IsFalse(outcome.Escaped, 'The object raised by the target''s Done came out of Execute' + DescribeCore6(outcome));
  Assert.AreNotEqual(TProcessStatus.Running, outcome.StatusAfter, 'Status is still Running after Execute has returned');
  Assert.IsFalse(outcome.SecondRefused, 'A second Execute was refused: ' + outcome.SecondMessage);
  Assert.IsTrue(outcome.FirstResult, 'Execute');
end;

procedure TReviewCoreTests.CORE6_TargetDoneRaisesNonException_LaterTargetsStillGetDone;
var
  proc : IProcess;
  raising : TNonExceptionDoneTarget;
  raisingRef : IPipeTarget;
  counting : TDoneCountingTarget;
  countingRef : IPipeTarget;
  escaped : boolean;
  stuck : boolean;
begin
  raising := TNonExceptionDoneTarget.Create;
  raisingRef := raising;
  counting := TDoneCountingTarget.Create;
  countingRef := counting;
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  proc.WithStdOutPipe(raisingRef);
  proc.WithStdOutPipe(countingRef);
  escaped := false;
  try
    proc.Execute;
  except
    escaped := true;
  end;
  stuck := escaped and (proc.Status = TProcessStatus.Running);
  ReleaseAfterCore6(proc, stuck);
  Assert.AreEqual(1, raising.DoneCalls, 'Done of the raising target');
  Assert.AreEqual(1, counting.DoneCalls, 'Done of the target attached after the one whose Done raised');
end;

procedure TReviewCoreTests.CORE6_SourceDoneRaisesNonException_RunStillCompletes;
var
  proc : IProcess;
  outcome : TCore6Result;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  proc.WithStdInPipe(TNonExceptionDoneSource.Create);
  outcome := RunTwice(proc);
  ReleaseAfterCore6(proc, outcome.SecondRefused);
  Assert.IsFalse(outcome.Escaped, 'The object raised by the stdin source''s Done came out of Execute' + DescribeCore6(outcome));
  Assert.AreNotEqual(TProcessStatus.Running, outcome.StatusAfter, 'Status is still Running after Execute has returned');
  Assert.IsFalse(outcome.SecondRefused, 'A second Execute was refused: ' + outcome.SecondMessage);
  Assert.IsTrue(outcome.FirstResult, 'Execute');
end;

{$IFDEF MSWINDOWS}
procedure TReviewCoreTests.CORE6_FailedLaunch_TargetDoneRaisesNonException_ObjectStaysUsable;
var
  proc : IProcess;
  target : TNonExceptionDoneTarget;
  targetRef : IPipeTarget;
  outcome : TCore6Result;
begin
  target := TNonExceptionDoneTarget.Create;
  targetRef := target;
  proc := TProcess.Create;
  // The file exists, so validation passes, but it is not a program.
  proc.StartInfo.Executable := TTestHelpers.ScriptsDir + 'invalid-utf8.bin';
  proc.WithStdOutPipe(targetRef);
  outcome := RunTwice(proc);
  ReleaseAfterCore6(proc, outcome.SecondRefused);
  Assert.IsTrue(target.DoneCalls > 0, 'Done was never called, so the test did not reach the failed launch path');
  Assert.IsFalse(outcome.Escaped, 'The object raised by the target''s Done came out of the failed Execute' + DescribeCore6(outcome));
  Assert.IsFalse(outcome.SecondRefused, 'A second Execute was refused: ' + outcome.SecondMessage);
  Assert.IsFalse(outcome.FirstResult, 'Execute of a file that is not a program');
end;
{$ENDIF}

procedure TReviewCoreTests.CORE7_Detached_IgnoresTerminateOnTimeoutAndJobMode;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  // JobMode stays KillOnRelease (the default).
  proc.StartInfo.TerminateOnTimeout := false;
  CheckStarted(proc.ExecuteDetached, proc, 'ExecuteDetached was refused');
end;

procedure TReviewCoreTests.CORE7_DetachedValidationFails_ExitCodeAndTimedOutDoNotRaise;
var
  proc : IProcess;
  exitCode : Cardinal;
  timedOut : boolean;
  raised : string;
begin
  // No executable: validation fails and nothing is launched.
  proc := TProcess.Create;
  Assert.IsFalse(proc.ExecuteDetached, 'ExecuteDetached without an executable');
  Assert.AreEqual(TProcessStatus.Idle, proc.Status);
  raised := '';
  exitCode := 0;
  timedOut := true;
  try
    exitCode := proc.ExitCode;
  except
    on E : Exception do
      raised := 'ExitCode raised ' + E.ClassName + ' - ' + E.Message;
  end;
  try
    timedOut := proc.TimedOut;
  except
    on E : Exception do
    begin
      if raised <> '' then
        raised := raised + '; ';
      raised := raised + 'TimedOut raised ' + E.ClassName + ' - ' + E.Message;
    end;
  end;
  Assert.AreEqual('', raised, 'After a detached launch that failed validation');
  Assert.AreEqual<Cardinal>($FFFFFFFF, exitCode);
  Assert.IsFalse(timedOut);
end;

initialization
  TDUnitX.RegisterTestFixture(TReviewCoreTests);

end.
