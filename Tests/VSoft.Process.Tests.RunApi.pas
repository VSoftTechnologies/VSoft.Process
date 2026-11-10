unit VSoft.Process.Tests.RunApi;

interface

// The run API that every platform shares (VSoft.Process.Base.pas): the
// OnStarted and OnExit handlers, cancellation requested before the run or
// during the drain, how long Terminate waits, the fluent With* methods,
// attaching and detaching pipes, the default encodings and Clone.

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  [TestFixture]
  TProcessRunApiTests = class
  public
    [Setup]
    procedure SetUp;

    // OnStarted / OnExit. A handler that raises is logged and the run goes
    // on, whether the handler is called directly or queued to the main
    // thread (StartInfo.MarshallEventsToMainThread).
    [Test]
    procedure OnStartedRaises_CalledDirectly_LoggedAndRunCompletes;
    [Test]
    procedure OnExitRaises_CalledDirectly_LoggedAndRunCompletes;
    [Test]
    procedure OnStarted_Marshalled_ExecuteOnWorkerThread_FiresOnMainThread;
    [Test]
    procedure OnStartedRaises_Marshalled_LoggedAndRunCompletes;
    [Test]
    procedure OnExitRaises_Marshalled_LoggedAndRunCompletes;
    [Test]
    procedure EventProperties_ReturnWhatWasAssigned;

    // Cancellation that was requested before the run starts.
    [Test]
    procedure CancelledToken_Execute_ReturnsFalseWithReason;
    [Test]
    procedure CancelledToken_ExecuteAsync_ReturnsFalseWithReason;
    // The child has exited by itself and a program it started keeps stdout
    // open; the drain has no time limit.
    [Test]
    procedure CancellationEvent_SetDuringDrain_EndsRun;
    // After a kill the drain is bounded even when PipeDrainTimeoutMS is
    // INFINITE: a program the kill does not reach keeps stdout open.
    [Test]
    procedure Terminate_InfiniteDrainTimeout_IsBoundedAfterTheKill;
    [Test]
    procedure Terminate_WaitExpiresWhileTargetIsBlocked_ReturnsFalse;

    [Test]
    procedure StartMode_ReflectsLastExecuteKind;

    // The fluent With* methods hand the process's own builder to the
    // procedure and return the process.
    [Test]
    procedure WithStartInfo_ConfiguresBuilderAndReturnsTheProcess;
    [Test]
    procedure WithCommandLine_ConfiguresBuilderAndReturnsTheProcess;
    [Test]
    procedure WithEnvironment_ConfiguresBuilderAndReturnsTheProcess;
    [Test]
    procedure WithCredentials_ConfiguresBuilderAndReturnsTheProcess;
    [Test]
    procedure WithBuilderMethods_NilProcedure_IsIgnored;
    [Test]
    procedure FluentChain_RunsChild;

    // Attaching and detaching pipes.
    [Test]
    procedure WithStdErrPipe_Nil_Raises;
    [Test]
    procedure WithStdInPipe_Nil_RemovesSource;
    [Test]
    procedure ClearStdOutPipes_DetachesOnlyStdOut;
    [Test]
    procedure ClearStdErrPipes_DetachesOnlyStdErr;
    // A run in progress keeps the targets it started with.
    [Test]
    procedure ClearStdPipes_FromOnStarted_RunKeepsItsTargets;
    [Test]
    procedure TwoTargetsOnOneStream_BothReceiveOutput;
    [Test]
    procedure TargetRaisesNonException_LoggedAndGetsNoMoreData;

    // StartInfo.OutputEncoding / InputEncoding reach a target or source that
    // was not given an encoding of its own.
    [Test]
    procedure OutputEncoding_ReachesLineTargetOnStdErr;
    [Test]
    procedure InputEncoding_ReachesStringSource;

    [Test]
    procedure Clone_CopiesBuildersButNotPipesOrHandlers;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Unistd,
  {$ENDIF}
  System.SyncObjs,
  VSoft.CancellationToken,
  VSoft.Process.Tests.Common,
  VSoft.Process.Tests.Helper;

type
  TCondition = function : boolean of object;

  // OnStarted / OnExit handlers that record how they were called and can be
  // told to misbehave.
  TEventRecorder = class
  private
    FRaiseInStarted : boolean;
    FRaiseInExited : boolean;
    FClearPipesInStarted : boolean;
    FStartedCalls : integer;
    FExitedCalls : integer;
    FStartedThreadId : TThreadID;
    FExitedThreadId : TThreadID;
    FStartedProcess : Pointer;
    FExitCode : Cardinal;
  public
    procedure HandleStarted(const process : IProcess);
    procedure HandleExited(const process : IProcess; exitCode : Cardinal);
    function StartedFired : boolean;
    function ExitedFired : boolean;
    property RaiseInStarted : boolean read FRaiseInStarted write FRaiseInStarted;
    property RaiseInExited : boolean read FRaiseInExited write FRaiseInExited;
    // HandleStarted detaches the process's stdout and stderr targets.
    property ClearPipesInStarted : boolean read FClearPipesInStarted write FClearPipesInStarted;
    property StartedCalls : integer read FStartedCalls;
    property ExitedCalls : integer read FExitedCalls;
    property StartedThreadId : TThreadID read FStartedThreadId;
    property ExitedThreadId : TThreadID read FExitedThreadId;
    // The IProcess the OnStarted handler was given.
    property StartedProcess : Pointer read FStartedProcess;
    property ExitCode : Cardinal read FExitCode;
  end;

  // Collects the lines a line target is given. Safe to read while a run is
  // still delivering.
  TLineRecorder = class
  private
    FLock : TCriticalSection;
    FLines : TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
    function Count : integer;
    function Line(index : integer) : string;
    function Text : string;
    function ValueAfter(const prefix : string) : string;
    // True once a line containing fragment has arrived.
    function WaitForLine(const fragment : string; timeoutMs : Cardinal) : boolean;
  end;

  IRecordingTarget = interface(IPipeTarget)
    function StartCalls : integer;
    function DataCalls : integer;
    function DoneCalls : integer;
    // Everything received, as ASCII text.
    function Text : string;
  end;

  // Records every call. With raiseNonException each HandleData ends by
  // raising an object that is not an Exception.
  TRecordingTarget = class(TInterfacedObject, IPipeTarget, IRecordingTarget)
  private
    FLock : TCriticalSection;
    FText : string;
    FStartCalls : integer;
    FDataCalls : integer;
    FDoneCalls : integer;
    FRaiseNonException : boolean;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    function StartCalls : integer;
    function DataCalls : integer;
    function DoneCalls : integer;
    function Text : string;
  public
    constructor Create(raiseNonException : boolean);
    destructor Destroy; override;
  end;

  IRecordingSource = interface(IPipeSource)
    function StartCalls : integer;
  end;

  // A stdin source with nothing to send.
  TRecordingSource = class(TInterfacedObject, IPipeSource, IRecordingSource)
  private
    FStartCalls : integer;
  protected
    procedure Start;
    function GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;
    procedure Done;
    function StartCalls : integer;
  end;

  IGateTarget = interface(IPipeTarget)
    function WaitUntilEntered(timeoutMs : Cardinal) : boolean;
    procedure Open;
  end;

  // Stays inside HandleData until it is opened.
  TGateTarget = class(TInterfacedObject, IPipeTarget, IGateTarget)
  private
    FEntered : TEvent;
    FOpened : TEvent;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
    function WaitUntilEntered(timeoutMs : Cardinal) : boolean;
    procedure Open;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  // Runs a synchronous Execute on a thread of its own, which leaves the
  // caller free to service the main thread's queue.
  TExecuteThread = class(TThread)
  private
    FProcess : IProcess;
    FExecuted : boolean;
    FCompleted : boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const process : IProcess);
    function HasCompleted : boolean;
    // What Execute returned.
    property Executed : boolean read FExecuted;
  end;

{ TEventRecorder }

procedure TEventRecorder.HandleStarted(const process : IProcess);
begin
  FStartedThreadId := TThread.CurrentThread.ThreadID;
  FStartedProcess := Pointer(process);
  if FClearPipesInStarted then
  begin
    process.ClearStdOutPipes;
    process.ClearStdErrPipes;
  end;
  TInterlocked.Increment(FStartedCalls);
  if FRaiseInStarted then
    raise Exception.Create('started-boom');
end;

procedure TEventRecorder.HandleExited(const process : IProcess; exitCode : Cardinal);
begin
  FExitedThreadId := TThread.CurrentThread.ThreadID;
  FExitCode := exitCode;
  TInterlocked.Increment(FExitedCalls);
  if FRaiseInExited then
    raise Exception.Create('exited-boom');
end;

function TEventRecorder.StartedFired : boolean;
begin
  result := FStartedCalls > 0;
end;

function TEventRecorder.ExitedFired : boolean;
begin
  result := FExitedCalls > 0;
end;

{ TLineRecorder }

constructor TLineRecorder.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TLineRecorder.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited;
end;

procedure TLineRecorder.OnLine(const line : string);
begin
  FLock.Enter;
  try
    FLines.Add(line);
  finally
    FLock.Leave;
  end;
end;

function TLineRecorder.Count : integer;
begin
  FLock.Enter;
  try
    result := FLines.Count;
  finally
    FLock.Leave;
  end;
end;

function TLineRecorder.Line(index : integer) : string;
begin
  FLock.Enter;
  try
    result := FLines[index];
  finally
    FLock.Leave;
  end;
end;

function TLineRecorder.Text : string;
begin
  FLock.Enter;
  try
    result := FLines.Text;
  finally
    FLock.Leave;
  end;
end;

function TLineRecorder.ValueAfter(const prefix : string) : string;
begin
  FLock.Enter;
  try
    result := TTestHelpers.ValueAfter(FLines, prefix);
  finally
    FLock.Leave;
  end;
end;

function TLineRecorder.WaitForLine(const fragment : string; timeoutMs : Cardinal) : boolean;
var
  deadline : Int64;
begin
  deadline := TTestHelpers.TickMs + timeoutMs;
  while (Pos(fragment, Text) = 0) and (TTestHelpers.TickMs < deadline) do
    Sleep(20);
  result := Pos(fragment, Text) > 0;
end;

{ TRecordingTarget }

constructor TRecordingTarget.Create(raiseNonException : boolean);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRaiseNonException := raiseNonException;
end;

destructor TRecordingTarget.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TRecordingTarget.Start;
begin
  TInterlocked.Increment(FStartCalls);
end;

procedure TRecordingTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  FLock.Enter;
  try
    Inc(FDataCalls);
    if dataLength > 0 then
      FText := FText + TEncoding.ASCII.GetString(data, 0, Integer(dataLength));
  finally
    FLock.Leave;
  end;
  if FRaiseNonException then
    raise TObject.Create;
end;

procedure TRecordingTarget.Done;
begin
  TInterlocked.Increment(FDoneCalls);
end;

function TRecordingTarget.StartCalls : integer;
begin
  result := FStartCalls;
end;

function TRecordingTarget.DataCalls : integer;
begin
  FLock.Enter;
  try
    result := FDataCalls;
  finally
    FLock.Leave;
  end;
end;

function TRecordingTarget.DoneCalls : integer;
begin
  result := FDoneCalls;
end;

function TRecordingTarget.Text : string;
begin
  FLock.Enter;
  try
    result := FText;
  finally
    FLock.Leave;
  end;
end;

{ TRecordingSource }

procedure TRecordingSource.Start;
begin
  TInterlocked.Increment(FStartCalls);
end;

function TRecordingSource.GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;
begin
  data := nil;
  dataLength := 0;
  result := False;
end;

procedure TRecordingSource.Done;
begin
end;

function TRecordingSource.StartCalls : integer;
begin
  result := FStartCalls;
end;

{ TGateTarget }

constructor TGateTarget.Create;
begin
  inherited Create;
  FEntered := TEvent.Create(nil, True, False, '');
  FOpened := TEvent.Create(nil, True, False, '');
end;

destructor TGateTarget.Destroy;
begin
  FEntered.Free;
  FOpened.Free;
  inherited;
end;

procedure TGateTarget.Start;
begin
end;

procedure TGateTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
  FEntered.SetEvent;
  // Bounded, so a test that fails cannot hold the run for ever.
  FOpened.WaitFor(60000);
end;

procedure TGateTarget.Done;
begin
end;

function TGateTarget.WaitUntilEntered(timeoutMs : Cardinal) : boolean;
begin
  result := FEntered.WaitFor(timeoutMs) = wrSignaled;
end;

procedure TGateTarget.Open;
begin
  FOpened.SetEvent;
end;

{ TExecuteThread }

constructor TExecuteThread.Create(const process : IProcess);
begin
  FProcess := process;
  inherited Create(False);
end;

procedure TExecuteThread.Execute;
begin
  try
    FExecuted := FProcess.Execute;
  finally
    FProcess := nil;
    FCompleted := True;
  end;
end;

function TExecuteThread.HasCompleted : boolean;
begin
  result := FCompleted;
end;

// Services the main thread's queue (where marshalled event handlers arrive)
// until condition holds or timeoutMs has passed.
function PumpUntil(condition : TCondition; timeoutMs : Cardinal) : boolean;
var
  deadline : Int64;
begin
  deadline := TTestHelpers.TickMs + timeoutMs;
  while (not condition()) and (TTestHelpers.TickMs < deadline) do
    CheckSynchronize(20);
  result := condition();
end;

// A process set up to run the exit-with fixture.
function NewExitProcess(exitCode : integer) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupShellCommand(result, 'exit-with', [IntToStr(exitCode)]);
end;

// Writes bytes to a new temp file and returns its name; the caller deletes it.
function WriteTempFile(const bytes : TBytes) : string;
var
  stream : TFileStream;
begin
  result := TTestHelpers.TempFileName('vsoft_proc_runapi_', '.bin');
  stream := TFileStream.Create(result, fmCreate);
  try
    stream.WriteBuffer(bytes[0], Length(bytes));
  finally
    stream.Free;
  end;
end;

// A watch on the program the spawn-background-and-exit fixture left running
// with the child's stdout: found under the child on Windows, announced as
// PID=<n> elsewhere. 0 when it is not there.
function WatchBackgroundProgram(const proc : IProcess; const lines : TLineRecorder) : NativeUInt;
var
  pid : Cardinal;
begin
  {$IFDEF MSWINDOWS}
  pid := TTestHelpers.FindChildProcess(proc.ProcessId, 'ping.exe');
  {$ELSE}
  pid := Cardinal(StrToIntDef(lines.ValueAfter('PID='), 0));
  {$ENDIF}
  result := TTestHelpers.WatchProcess(pid);
end;

{ TProcessRunApiTests }

procedure TProcessRunApiTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TProcessRunApiTests.OnStartedRaises_CalledDirectly_LoggedAndRunCompletes;
var
  proc : IProcess;
  recorder : TEventRecorder;
begin
  recorder := TEventRecorder.Create;
  try
    recorder.RaiseInStarted := True;
    proc := NewExitProcess(5);
    proc.OnStarted := recorder.HandleStarted;
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual<Integer>(1, recorder.StartedCalls, 'OnStarted should be called once');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'the run should go on after the handler raised');
    Assert.AreEqual<Cardinal>(5, proc.ExitCode, 'the child should have run to its end');
    Assert.Contains(proc.Errors.Text, 'OnStarted handler raised');
    Assert.Contains(proc.Errors.Text, 'started-boom');
  finally
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.OnExitRaises_CalledDirectly_LoggedAndRunCompletes;
var
  proc : IProcess;
  recorder : TEventRecorder;
begin
  recorder := TEventRecorder.Create;
  try
    recorder.RaiseInExited := True;
    proc := NewExitProcess(5);
    proc.OnExit := recorder.HandleExited;
    Assert.IsTrue(proc.Execute, 'Execute should not pass the handler''s exception on: ' + proc.Errors.Text);
    Assert.AreEqual<Integer>(1, recorder.ExitedCalls, 'OnExit should be called once');
    Assert.AreEqual<Cardinal>(5, recorder.ExitCode, 'OnExit should be given the child''s exit code');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(5, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'OnExit handler raised');
    Assert.Contains(proc.Errors.Text, 'exited-boom');
  finally
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.OnStarted_Marshalled_ExecuteOnWorkerThread_FiresOnMainThread;
var
  proc : IProcess;
  recorder : TEventRecorder;
  runner : TExecuteThread;
begin
  recorder := TEventRecorder.Create;
  runner := nil;
  try
    proc := NewExitProcess(0);
    proc.StartInfo.MarshallEventsToMainThread := True;
    proc.OnStarted := recorder.HandleStarted;
    runner := TExecuteThread.Create(proc);
    // The handler is queued to this thread, which has to service its queue.
    Assert.IsTrue(PumpUntil(runner.HasCompleted, 30000), 'Execute did not return');
    Assert.IsTrue(PumpUntil(recorder.StartedFired, 15000), 'OnStarted was never called');
    Assert.IsTrue(runner.Executed, proc.Errors.Text);
    Assert.AreEqual<Integer>(1, recorder.StartedCalls, 'OnStarted should be called once');
    Assert.AreEqual<TThreadID>(MainThreadID, recorder.StartedThreadId, 'OnStarted should be called on the main thread');
    Assert.IsTrue(recorder.StartedProcess = Pointer(proc), 'the handler should be given the process it belongs to');
  finally
    if runner <> nil then
    begin
      runner.WaitFor;
      runner.Free;
    end;
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.OnStartedRaises_Marshalled_LoggedAndRunCompletes;
var
  proc : IProcess;
  recorder : TEventRecorder;
  runner : TExecuteThread;
begin
  recorder := TEventRecorder.Create;
  runner := nil;
  try
    recorder.RaiseInStarted := True;
    proc := NewExitProcess(0);
    proc.StartInfo.MarshallEventsToMainThread := True;
    proc.OnStarted := recorder.HandleStarted;
    runner := TExecuteThread.Create(proc);
    Assert.IsTrue(PumpUntil(runner.HasCompleted, 30000), 'Execute did not return');
    Assert.IsTrue(PumpUntil(recorder.StartedFired, 15000), 'OnStarted was never called');
    Assert.IsTrue(runner.Executed, proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'OnStarted handler raised');
    Assert.Contains(proc.Errors.Text, 'started-boom');
  finally
    if runner <> nil then
    begin
      runner.WaitFor;
      runner.Free;
    end;
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.OnExitRaises_Marshalled_LoggedAndRunCompletes;
var
  proc : IProcess;
  recorder : TEventRecorder;
begin
  recorder := TEventRecorder.Create;
  try
    recorder.RaiseInExited := True;
    proc := NewExitProcess(3);
    proc.StartInfo.MarshallEventsToMainThread := True;
    proc.OnExit := recorder.HandleExited;
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    // Queued by the run's worker thread to this one.
    Assert.IsTrue(PumpUntil(recorder.ExitedFired, 30000), 'OnExit was never called');
    Assert.AreEqual<TThreadID>(MainThreadID, recorder.ExitedThreadId, 'OnExit should be called on the main thread');
    Assert.AreEqual<Cardinal>(3, recorder.ExitCode, 'OnExit should be given the child''s exit code');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.Contains(proc.Errors.Text, 'OnExit handler raised');
    Assert.Contains(proc.Errors.Text, 'exited-boom');
  finally
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.EventProperties_ReturnWhatWasAssigned;
var
  proc : IProcess;
  recorder : TEventRecorder;
  started : TProcessStartedEvent;
  exited : TProcessExitedEvent;
begin
  recorder := TEventRecorder.Create;
  try
    proc := TProcess.Create;
    started := proc.OnStarted;
    exited := proc.OnExit;
    Assert.IsFalse(Assigned(started), 'OnStarted should not be assigned by default');
    Assert.IsFalse(Assigned(exited), 'OnExit should not be assigned by default');

    proc.OnStarted := recorder.HandleStarted;
    proc.OnExit := recorder.HandleExited;
    started := proc.OnStarted;
    exited := proc.OnExit;
    Assert.IsTrue((TMethod(started).Data = Pointer(recorder)) and (TMethod(started).Code = @TEventRecorder.HandleStarted),
                  'OnStarted should return the handler that was assigned');
    Assert.IsTrue((TMethod(exited).Data = Pointer(recorder)) and (TMethod(exited).Code = @TEventRecorder.HandleExited),
                  'OnExit should return the handler that was assigned');

    proc.OnStarted := nil;
    proc.OnExit := nil;
    started := proc.OnStarted;
    exited := proc.OnExit;
    Assert.IsFalse(Assigned(started), 'assigning nil should clear OnStarted');
    Assert.IsFalse(Assigned(exited), 'assigning nil should clear OnExit');
  finally
    proc := nil;
    recorder.Free;
  end;
end;

procedure CheckCancelledTokenIsRefused(async : boolean);
var
  proc : IProcess;
  target : IRecordingTarget;
  cts : ICancellationTokenSource;
  executed : boolean;
begin
  target := TRecordingTarget.Create(False);
  cts := TCancellationTokenSourceFactory.Create;
  cts.Cancel;
  proc := NewExitProcess(0);
  proc.WithStdOutPipe(target);
  if async then
    executed := proc.ExecuteAsync(cts.Token)
  else
    executed := proc.Execute(cts.Token);
  Assert.IsFalse(executed, 'a run was started with a token that was already cancelled');
  Assert.Contains(proc.Errors.Text, 'Cancellation token is cancelled');
  Assert.AreEqual(TProcessStatus.Idle, proc.Status, 'nothing ran');
  Assert.AreEqual<Cardinal>(0, proc.LastError, 'a refused run is not an operating system error');
  Assert.AreEqual<Integer>(0, target.StartCalls, 'the target was started although nothing ran');
  // The refusal leaves the process usable.
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
  Assert.AreEqual<Integer>(1, target.StartCalls, 'the next run should use the target');
  proc.ClearPipes;
end;

procedure TProcessRunApiTests.CancelledToken_Execute_ReturnsFalseWithReason;
begin
  CheckCancelledTokenIsRefused(False);
end;

procedure TProcessRunApiTests.CancelledToken_ExecuteAsync_ReturnsFalseWithReason;
begin
  CheckCancelledTokenIsRefused(True);
end;

procedure TProcessRunApiTests.CancellationEvent_SetDuringDrain_EndsRun;
var
  proc : IProcess;
  lines : TLineRecorder;
  cancel : TEvent;
  watch : NativeUInt;
begin
  watch := 0;
  lines := TLineRecorder.Create;
  cancel := TEvent.Create(nil, True, False, '');
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    proc.StartInfo.PipeDrainTimeoutMS := INFINITE;
    TTestHelpers.SetupShellCommand(proc, 'spawn-background-and-exit', ['30']);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    Assert.IsTrue(proc.ExecuteAsync(cancel), proc.Errors.Text);
    Assert.IsTrue(lines.WaitForLine('parent-done', 15000), 'the child did not run: ' + lines.Text);
    watch := WatchBackgroundProgram(proc, lines);
    Assert.IsTrue(watch <> 0, 'the program the child started in the background was not found');
    // Long enough for the child to exit and the run to reach the drain.
    Sleep(500);
    Assert.AreEqual(TProcessStatus.Running, proc.Status, 'the run should still be draining');

    cancel.SetEvent;
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 10000), 'setting the cancellation event did not end the drain');
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'the child had already exited by itself');
    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(proc.Errors.Text, 'truncated');
  finally
    // Ends the drain if the event did not, so the run can complete.
    TTestHelpers.KillWatched(watch);
    if proc <> nil then
    begin
      if proc.Status = TProcessStatus.Running then
        proc.Terminate;
      proc.ClearPipes;
      proc := nil;
    end;
    cancel.Free;
    lines.Free;
  end;
end;

procedure TProcessRunApiTests.Terminate_InfiniteDrainTimeout_IsBoundedAfterTheKill;
var
  proc : IProcess;
  lines : TLineRecorder;
  watch : NativeUInt;
  completed : boolean;
begin
  {$IFNDEF MSWINDOWS}
  if not (FileExists('/usr/bin/setsid') or FileExists('/bin/setsid')) then
    Assert.Pass('NOT RUN: needs setsid to start a program outside the child''s process group');
  {$ENDIF}
  watch := 0;
  lines := TLineRecorder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    proc.StartInfo.PipeDrainTimeoutMS := INFINITE;
    // Without a job the kill only reaches what the tree walk finds.
    proc.StartInfo.JobMode := TProcessJobMode.NoJob;
    // The child starts a program that keeps stdout and that the kill does
    // not reach, then waits to be killed. On Windows that program has no
    // live parent (the helper that starts it exits), so nothing links it to
    // the child; elsewhere it is in a session of its own, and the stop
    // signals go to the child's process group.
    TTestHelpers.SetupInlineCommand(proc,
      '""' + ParamStr(0) + '" ' + HelperCommandLine('spawn-orphan', ['30']) + ' & echo parent-ready & ping 127.0.0.1 -n 60 > nul"',
      'setsid sleep 30 & echo "PID=$!"; echo parent-ready; sleep 60');
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.IsTrue(lines.WaitForLine('parent-ready', 15000), 'the child did not run: ' + lines.Text);
    watch := TTestHelpers.WatchProcess(Cardinal(StrToIntDef(lines.ValueAfter('PID='), 0)));
    Assert.IsTrue(watch <> 0, 'the program that keeps stdout was not started: ' + lines.Text);

    completed := proc.Terminate(15000);
    Assert.IsTrue(completed, 'the run did not complete: after a kill an INFINITE drain timeout should be treated as the default');
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status, proc.Errors.Text);
    Assert.IsTrue(TTestHelpers.IsRunningAfter(watch, 0),
                  'the program that keeps stdout did not outlive the kill, so the drain was never put to the test');
    Assert.Contains(proc.Errors.Text, 'Output may be truncated');
  finally
    // Closes the pipe if the run is still waiting for it.
    TTestHelpers.KillWatched(watch);
    if proc <> nil then
    begin
      if proc.Status = TProcessStatus.Running then
        proc.Terminate;
      proc.ClearPipes;
      proc := nil;
    end;
    lines.Free;
  end;
end;

procedure TProcessRunApiTests.Terminate_WaitExpiresWhileTargetIsBlocked_ReturnsFalse;
const
  cWaitMs = 300;
var
  proc : IProcess;
  gate : IGateTarget;
  started : Int64;
  waited : Int64;
  completedInTime : boolean;
begin
  gate := TGateTarget.Create;
  proc := TProcess.Create;
  try
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupShellCommand(proc, 'print-then-sleep', ['30']);
    proc.WithStdOutPipe(gate);
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.IsTrue(gate.WaitUntilEntered(15000), 'the target was never given the child''s output');

    started := TTestHelpers.TickMs;
    completedInTime := proc.Terminate(cWaitMs);
    waited := TTestHelpers.TickMs - started;
    Assert.IsFalse(completedInTime, 'Terminate reported a completed run while the run''s target was still inside HandleData');
    Assert.IsTrue(waited >= cWaitMs - 100, Format('Terminate(%d) gave up after %d ms', [cWaitMs, waited]));
    Assert.AreEqual(TProcessStatus.Running, proc.Status, 'the run cannot complete before its target returns');

    // A wait shorter than one of the slices the main thread waits in.
    started := TTestHelpers.TickMs;
    completedInTime := proc.Terminate(5);
    waited := TTestHelpers.TickMs - started;
    Assert.IsFalse(completedInTime, 'Terminate(5) reported a completed run while the run''s target was still inside HandleData');
    Assert.IsTrue(waited < 5000, Format('Terminate(5) took %d ms', [waited]));

    gate.Open;
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the run did not complete once its target had returned');
    Assert.AreEqual(TProcessStatus.Terminated, proc.Status, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(EXIT_TERMINATED, proc.ExitCode);
  finally
    gate.Open;
    if proc.Status = TProcessStatus.Running then
      proc.Terminate;
    proc.ClearPipes;
  end;
end;

procedure TProcessRunApiTests.StartMode_ReflectsLastExecuteKind;
var
  proc : IProcess;
begin
  proc := NewExitProcess(0);
  Assert.AreEqual(TProcessStartMode.Sync, proc.StartMode, 'before any run');

  Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
  Assert.AreEqual(TProcessStartMode.Async, proc.StartMode, 'after ExecuteAsync');
  Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 30000), 'the asynchronous run did not complete');

  Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
  Assert.AreEqual(TProcessStartMode.Detached, proc.StartMode, 'after ExecuteDetached');

  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual(TProcessStartMode.Sync, proc.StartMode, 'after Execute');
end;

procedure TProcessRunApiTests.WithStartInfo_ConfiguresBuilderAndReturnsTheProcess;
var
  proc : IProcess;
  returned : IProcess;
begin
  proc := TProcess.Create;
  returned := proc.WithStartInfo(
    procedure(const startInfo : IStartInfoBuilder)
    begin
      startInfo.TimeoutInMSec := 4321;
    end);
  Assert.IsTrue(returned = proc, 'WithStartInfo should return the process it was called on');
  Assert.AreEqual<Cardinal>(4321, proc.StartInfo.TimeoutInMSec, 'the procedure should be given this process''s StartInfo');
end;

procedure TProcessRunApiTests.WithCommandLine_ConfiguresBuilderAndReturnsTheProcess;
var
  proc : IProcess;
  returned : IProcess;
begin
  proc := TProcess.Create;
  returned := proc.WithCommandLine(
    procedure(const commandLine : ICommandLineBuilder)
    begin
      commandLine.Add('--name', 'value');
    end);
  Assert.IsTrue(returned = proc, 'WithCommandLine should return the process it was called on');
  Assert.AreEqual<Integer>(1, proc.CommandLine.Count, 'the procedure should be given this process''s CommandLine');
  Assert.AreEqual('--name', proc.CommandLine.Arguments[0].Name);
  Assert.AreEqual('value', proc.CommandLine.Arguments[0].Value);
end;

procedure TProcessRunApiTests.WithEnvironment_ConfiguresBuilderAndReturnsTheProcess;
var
  proc : IProcess;
  returned : IProcess;
  value : string;
begin
  proc := TProcess.Create;
  returned := proc.WithEnvironment(
    procedure(const environment : IEnvironmentBuilder)
    begin
      environment.AddOrSet('VSP_FLUENT_TEST', 'yes');
    end);
  Assert.IsTrue(returned = proc, 'WithEnvironment should return the process it was called on');
  Assert.IsTrue(proc.Environment.TryGetValue('VSP_FLUENT_TEST', value), 'the procedure should be given this process''s Environment');
  Assert.AreEqual('yes', value);
end;

procedure TProcessRunApiTests.WithCredentials_ConfiguresBuilderAndReturnsTheProcess;
var
  proc : IProcess;
  returned : IProcess;
begin
  // Only the builder is looked at: nothing is launched.
  proc := TProcess.Create;
  returned := proc.WithCredentials(
    procedure(const credentials : ICredentialsBuilder)
    begin
      credentials.UserName := 'nobody@nowhere.example';
    end);
  Assert.IsTrue(returned = proc, 'WithCredentials should return the process it was called on');
  Assert.AreEqual('nobody@nowhere.example', proc.Credentials.UserName, 'the procedure should be given this process''s Credentials');
end;

procedure TProcessRunApiTests.WithBuilderMethods_NilProcedure_IsIgnored;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  Assert.IsTrue(proc.WithStartInfo(nil) = proc, 'WithStartInfo(nil) should return the process');
  Assert.IsTrue(proc.WithCommandLine(nil) = proc, 'WithCommandLine(nil) should return the process');
  Assert.IsTrue(proc.WithEnvironment(nil) = proc, 'WithEnvironment(nil) should return the process');
  Assert.IsTrue(proc.WithCredentials(nil) = proc, 'WithCredentials(nil) should return the process');
  Assert.AreEqual('', proc.StartInfo.Executable);
  Assert.AreEqual<Integer>(0, proc.CommandLine.Count);
  Assert.IsFalse(proc.Environment.HasOverrides, 'the environment should be untouched');
  Assert.AreEqual('', proc.Credentials.UserName);
end;

procedure TProcessRunApiTests.FluentChain_RunsChild;
var
  proc : IProcess;
  lines : TLineRecorder;
  executed : boolean;
begin
  lines := TLineRecorder.Create;
  try
    proc := TProcess.Create;
    executed := proc.WithStartInfo(
        procedure(const startInfo : IStartInfoBuilder)
        begin
          startInfo.Executable := TTestHelpers.ShellExePath;
          startInfo.TimeoutInMSec := 60000;
        end)
      .WithCommandLine(
        procedure(const commandLine : ICommandLineBuilder)
        begin
          {$IFDEF MSWINDOWS}
          commandLine.Add('/c');
          commandLine.Add(TTestHelpers.BuildSingleCommand(TTestHelpers.ScriptPath('print-env'), ['VSP_FLUENT_TEST']), TQuoted.qtNone);
          {$ELSE}
          commandLine.Add(TTestHelpers.ScriptPath('print-env'));
          commandLine.Add('VSP_FLUENT_TEST');
          {$ENDIF}
        end)
      .WithEnvironment(
        procedure(const environment : IEnvironmentBuilder)
        begin
          environment.AddOrSet('VSP_FLUENT_TEST', 'fluent-value');
        end)
      .WithStdOutPipe(TPipeTarget.ToLineMethod(lines.OnLine))
      .Execute;
    proc.ClearPipes;
    Assert.IsTrue(executed, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(0, proc.ExitCode, proc.Errors.Text);
    Assert.AreEqual('fluent-value', lines.ValueAfter('VSP_FLUENT_TEST='), 'the child should see what the chain configured: ' + lines.Text);
  finally
    proc := nil;
    lines.Free;
  end;
end;

procedure TProcessRunApiTests.WithStdErrPipe_Nil_Raises;
var
  proc : IProcess;
  raised : boolean;
begin
  proc := TProcess.Create;
  raised := False;
  try
    proc.WithStdErrPipe(nil);
  except
    on E : EArgumentNilException do
      raised := True;
  end;
  Assert.IsTrue(raised, 'WithStdErrPipe(nil) should raise EArgumentNilException');
end;

procedure TProcessRunApiTests.WithStdInPipe_Nil_RemovesSource;
var
  proc : IProcess;
  source : IRecordingSource;
begin
  source := TRecordingSource.Create;
  proc := NewExitProcess(0);
  Assert.IsTrue(proc.WithStdInPipe(source) = proc, 'WithStdInPipe should return the process it was called on');
  // The control: an attached source is started by a run.
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Integer>(1, source.StartCalls, 'the attached source should be started by the run');

  proc.WithStdInPipe(nil);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Integer>(1, source.StartCalls, 'the removed source was used again');
end;

procedure TProcessRunApiTests.ClearStdOutPipes_DetachesOnlyStdOut;
var
  proc : IProcess;
  outTarget : IRecordingTarget;
  errTarget : IRecordingTarget;
begin
  outTarget := TRecordingTarget.Create(False);
  errTarget := TRecordingTarget.Create(False);
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
  proc.WithStdOutPipe(outTarget).WithStdErrPipe(errTarget);
  Assert.IsTrue(proc.ClearStdOutPipes = proc, 'ClearStdOutPipes should return the process it was called on');
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Integer>(0, outTarget.StartCalls, 'the detached stdout target was used');
  Assert.AreEqual('', outTarget.Text);
  Assert.Contains(errTarget.Text, 'this-is-stderr', 'the stderr target should still be attached');
  Assert.AreEqual<Integer>(1, errTarget.DoneCalls);
  proc.ClearPipes;
end;

procedure TProcessRunApiTests.ClearStdErrPipes_DetachesOnlyStdErr;
var
  proc : IProcess;
  outTarget : IRecordingTarget;
  errTarget : IRecordingTarget;
begin
  outTarget := TRecordingTarget.Create(False);
  errTarget := TRecordingTarget.Create(False);
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
  proc.WithStdOutPipe(outTarget).WithStdErrPipe(errTarget);
  Assert.IsTrue(proc.ClearStdErrPipes = proc, 'ClearStdErrPipes should return the process it was called on');
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Integer>(0, errTarget.StartCalls, 'the detached stderr target was used');
  Assert.AreEqual('', errTarget.Text);
  Assert.Contains(outTarget.Text, 'this-is-stdout', 'the stdout target should still be attached');
  Assert.AreEqual<Integer>(1, outTarget.DoneCalls);
  proc.ClearPipes;
end;

procedure TProcessRunApiTests.ClearStdPipes_FromOnStarted_RunKeepsItsTargets;
var
  proc : IProcess;
  recorder : TEventRecorder;
  outTarget : IRecordingTarget;
  errTarget : IRecordingTarget;
begin
  recorder := TEventRecorder.Create;
  try
    recorder.ClearPipesInStarted := True;
    outTarget := TRecordingTarget.Create(False);
    errTarget := TRecordingTarget.Create(False);
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
    proc.WithStdOutPipe(outTarget).WithStdErrPipe(errTarget);
    proc.OnStarted := recorder.HandleStarted;
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual<Integer>(1, recorder.StartedCalls, 'the handler that detaches the targets did not run');
    Assert.Contains(outTarget.Text, 'this-is-stdout', 'the run in progress should keep its stdout target');
    Assert.Contains(errTarget.Text, 'this-is-stderr', 'the run in progress should keep its stderr target');
    Assert.AreEqual<Integer>(1, outTarget.DoneCalls, 'the stdout target should get its Done');
    Assert.AreEqual<Integer>(1, errTarget.DoneCalls, 'the stderr target should get its Done');

    // They are detached for the run after it.
    proc.OnStarted := nil;
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual<Integer>(1, outTarget.StartCalls, 'the next run used the detached stdout target');
    Assert.AreEqual<Integer>(1, errTarget.StartCalls, 'the next run used the detached stderr target');
  finally
    proc := nil;
    recorder.Free;
  end;
end;

procedure TProcessRunApiTests.TwoTargetsOnOneStream_BothReceiveOutput;
var
  proc : IProcess;
  outFirst : IRecordingTarget;
  outSecond : IRecordingTarget;
  errFirst : IRecordingTarget;
  errSecond : IRecordingTarget;
begin
  outFirst := TRecordingTarget.Create(False);
  outSecond := TRecordingTarget.Create(False);
  errFirst := TRecordingTarget.Create(False);
  errSecond := TRecordingTarget.Create(False);
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
  proc.WithStdOutPipe(outFirst).WithStdOutPipe(outSecond).WithStdErrPipe(errFirst).WithStdErrPipe(errSecond);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  proc.ClearPipes;
  Assert.Contains(outFirst.Text, 'this-is-stdout');
  Assert.AreEqual(outFirst.Text, outSecond.Text, 'both stdout targets should be given the same output');
  Assert.Contains(errFirst.Text, 'this-is-stderr');
  Assert.AreEqual(errFirst.Text, errSecond.Text, 'both stderr targets should be given the same output');
  Assert.AreEqual<Integer>(0, Pos('this-is-stderr', outFirst.Text), 'stderr output reached a stdout target');
  Assert.AreEqual<Integer>(0, Pos('this-is-stdout', errFirst.Text), 'stdout output reached a stderr target');
  Assert.AreEqual<Integer>(1, outSecond.DoneCalls);
  Assert.AreEqual<Integer>(1, errSecond.DoneCalls);
end;

procedure TProcessRunApiTests.TargetRaisesNonException_LoggedAndGetsNoMoreData;
const
  cLineCount = 400;
var
  proc : IProcess;
  faulty : IRecordingTarget;
  healthy : IRecordingTarget;
begin
  faulty := TRecordingTarget.Create(True);
  healthy := TRecordingTarget.Create(False);
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  // About 29 KB through a 4 KB buffer: several reads.
  proc.StartInfo.PipeBufferSize := 4096;
  TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
  proc.WithStdOutPipe(faulty).WithStdOutPipe(healthy);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  proc.ClearPipes;
  Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'the child should run to its end');
  Assert.IsTrue(healthy.DataCalls > 1, 'the output should arrive in several reads, or the next check proves nothing');
  Assert.AreEqual<Integer>(1, faulty.DataCalls, 'a target that raised was given more data');
  Assert.AreEqual<Integer>(cLineCount, TTestHelpers.CountChar(healthy.Text, #10), 'the other target should be given every line');
  Assert.AreEqual<Integer>(1, faulty.DoneCalls, 'a target that raised still gets its Done');
  Assert.Contains(proc.Errors.Text, 'stdout pipe target raised a non-Exception object');
end;

procedure TProcessRunApiTests.OutputEncoding_ReachesLineTargetOnStdErr;
var
  proc : IProcess;
  lines : TLineRecorder;
  fileName : string;
  sample : string;
begin
  // caf, e acute, space, a CJK character.
  sample := 'caf' + #$00E9 + ' ' + #$4E2D;
  fileName := WriteTempFile(TEncoding.Unicode.GetBytes(sample + #10));
  lines := TLineRecorder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    proc.StartInfo.OutputEncoding := TEncoding.Unicode;
    // The child copies the file to its stderr byte for byte.
    TTestHelpers.SetupInlineCommand(proc, 'type "' + fileName + '" 1>&2', 'cat "' + fileName + '" 1>&2');
    proc.WithStdErrPipe(TPipeTarget.ToLineMethod(lines.OnLine));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    proc.ClearPipes;
    Assert.AreEqual<Cardinal>(0, proc.ExitCode, proc.Errors.Text);
    Assert.AreEqual<Integer>(1, lines.Count, 'one line expected: ' + lines.Text);
    Assert.AreEqual(sample, lines.Line(0), False, 'the line should be decoded with StartInfo.OutputEncoding');
  finally
    proc := nil;
    lines.Free;
    System.SysUtils.DeleteFile(fileName);
  end;
end;

procedure TProcessRunApiTests.InputEncoding_ReachesStringSource;
var
  proc : IProcess;
  captured : TBytesStream;
  sample : string;
  expected : TBytes;
  received : TBytes;
begin
  sample := 'caf' + #$00E9 + ' ' + #$4E2D;
  expected := TEncoding.Unicode.GetBytes(sample);
  captured := TBytesStream.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    proc.StartInfo.InputEncoding := TEncoding.Unicode;
    SetupCatChild(proc);
    proc.WithStdInPipe(TPipeSource.FromString(sample));
    proc.WithStdOutPipe(TPipeTarget.ToStream(captured));
    try
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
    finally
      proc.ClearPipes;
    end;
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    received := Copy(captured.Bytes, 0, captured.Size);
    Assert.IsTrue(TTestHelpers.SameBytes(expected, received),
                  Format('the child read %d bytes, not the %d bytes of the text in StartInfo.InputEncoding', [Length(received), Length(expected)]));
  finally
    proc := nil;
    captured.Free;
  end;
end;

procedure TProcessRunApiTests.Clone_CopiesBuildersButNotPipesOrHandlers;
var
  proc : IProcess;
  clone : IProcess;
  recorder : TEventRecorder;
  target : IRecordingTarget;
  source : IRecordingSource;
  started : TProcessStartedEvent;
  exited : TProcessExitedEvent;
  value : string;
begin
  recorder := TEventRecorder.Create;
  try
    target := TRecordingTarget.Create(False);
    source := TRecordingSource.Create;
    proc := NewExitProcess(7);
    proc.StartInfo.TimeoutInMSec := 54321;
    proc.Environment.AddOrSet('VSP_CLONE_TEST', 'cloned');
    proc.WithStdOutPipe(target).WithStdErrPipe(target).WithStdInPipe(source);
    proc.OnStarted := recorder.HandleStarted;
    proc.OnExit := recorder.HandleExited;

    clone := proc.Clone;
    Assert.IsFalse(clone = proc, 'Clone should return a new process');
    Assert.AreEqual(proc.StartInfo.Executable, clone.StartInfo.Executable);
    Assert.AreEqual<Cardinal>(54321, clone.StartInfo.TimeoutInMSec);
    Assert.AreEqual(proc.CommandLine.ToString, clone.CommandLine.ToString);
    Assert.IsTrue(clone.Environment.TryGetValue('VSP_CLONE_TEST', value), 'the clone should have the environment variable');
    Assert.AreEqual('cloned', value);
    started := clone.OnStarted;
    exited := clone.OnExit;
    Assert.IsFalse(Assigned(started), 'a clone should not take the OnStarted handler');
    Assert.IsFalse(Assigned(exited), 'a clone should not take the OnExit handler');

    Assert.IsTrue(clone.Execute, clone.Errors.Text);
    Assert.AreEqual<Cardinal>(7, clone.ExitCode, 'the clone should run what the original was set up to run');
    Assert.AreEqual<Integer>(0, target.StartCalls, 'a clone should not take the pipe targets');
    Assert.AreEqual<Integer>(0, source.StartCalls, 'a clone should not take the stdin source');
    Assert.AreEqual<Integer>(0, recorder.StartedCalls + recorder.ExitedCalls, 'a clone should not call the original''s handlers');
    Assert.AreEqual(TProcessStatus.Idle, proc.Status, 'running the clone should leave the original alone');
  finally
    clone := nil;
    proc := nil;
    recorder.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessRunApiTests);

end.
