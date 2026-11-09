unit VSoft.Process.Tests.Process;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  // End-to-end tests that actually spawn child processes. These are slower
  // than the unit tests and require platform shells (cmd on Windows,
  // /bin/sh on POSIX).
  [TestFixture]
  TProcessExecutionTests = class
  public
    [Test]
    procedure Execute_SimpleEcho_CapturesOutput;

    [Test]
    procedure Execute_ReturnsExitCodeFromChild;

    [Test]
    procedure Execute_TimedOut_FlagSet;

    [Test]
    procedure ExecuteAsync_StatusTransitions;

    // C3 - the async monitor thread must keep Self alive even if the caller
    // drops the IProcess reference. We deliberately release our reference
    // immediately after ExecuteAsync and wait for the process to finish
    // by other means. If the worker thread's closure captures Self as a
    // raw pointer (the bug) this will use-after-free and either crash, leak,
    // or be detected by ReportMemoryLeaksOnShutdown.
    [Test]
    procedure ExecuteAsync_NoUseAfterFreeWhenCallerDropsRef;

    // C2 + H1 - Terminate() must actually terminate the process and only
    // return True once the worker thread has finished cleaning up. The old
    // implementation always returned True after a fixed 200ms regardless
    // of whether the process had really died.
    [Test]
    procedure Terminate_ActuallyKillsRunningChild;

    // H2 - reusing the same IProcess for a second ExecuteAsync should reset
    // status, errors, and exit code from the previous run.
    [Test]
    procedure ExecuteAsync_ResetsPriorRunState;

    // README example 6 - both OnStarted and OnExit must fire for an async run,
    // and OnExit must receive the child's real exit code.
    [Test]
    procedure ExecuteAsync_OnStartedAndOnExitFire;

    // README example 11 - cloning a configured IProcess produces an independent
    // copy that can be Executed on its own without disturbing the template.
    [Test]
    procedure Clone_TwoClonesExecuteIndependently;

    // README example 13 - ExecuteDetached returns True, leaves Status=Running
    // forever (the OS does not notify us), and the documented properties
    // (ExitCode / TimedOut) raise EInvalidOpException.
    [Test]
    procedure ExecuteDetached_StartsAndDocumentedPropertiesRaise;

    // W4 - On POSIX, configuring credentials must cause Execute to fail
    // fast with a clear error rather than silently running unauthenticated.
    // On Windows this test is a no-op (Assert.Pass) because Windows DOES
    // support credentials.
    [Test]
    procedure Posix_CredentialsConfigured_ExecuteReturnsFalse;
  end;

implementation

uses
  System.IOUtils,
  VSoft.Process.Tests.Common;

procedure TProcessExecutionTests.Execute_SimpleEcho_CapturesOutput;
var
  proc   : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupInlineCommand(proc, 'echo hello-world', 'echo hello-world');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'echo should exit with 0');
    Assert.Contains(output.ToString, 'hello-world', 'stdout should contain the echoed text');
  finally
    output.Free;
  end;
end;

procedure TProcessExecutionTests.Execute_ReturnsExitCodeFromChild;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(proc, 'exit 7', 'exit 7');
  proc.Execute(nil);
  Assert.AreEqual<Cardinal>(7, proc.ExitCode);
end;

procedure TProcessExecutionTests.Execute_TimedOut_FlagSet;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 500;
  proc.StartInfo.TimedOutExitCode := 12345;
  // ping is a reliable way to sleep on Windows without timeout helpers.
  TTestHelpers.SetupInlineCommand(proc, 'ping 127.0.0.1 -n 10 > nul', 'sleep 10');
  proc.Execute(nil);
  Assert.IsTrue(proc.TimedOut, 'TimedOut flag should be set');
  Assert.AreEqual<Cardinal>(12345, proc.ExitCode, 'Configured timeout exit code should be reported');
end;

procedure TProcessExecutionTests.ExecuteAsync_StatusTransitions;
var
  proc : IProcess;
  start : TDateTime;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(proc, 'ping 127.0.0.1 -n 2 > nul', 'sleep 1');
  proc.ExecuteAsync;

  start := Now;
  while (proc.Status = TProcessStatus.Running) and
        ((Now - start) * 86400 < 10) do
    Sleep(50);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status,
                  'Process should reach Exited within 10s');
end;

procedure TProcessExecutionTests.Terminate_ActuallyKillsRunningChild;
var
  proc : IProcess;
  start : TDateTime;
  terminated : Boolean;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TerminateExitCode := 999;
  // Long-running child: ping with 30 echoes (~30 seconds).
  TTestHelpers.SetupInlineCommand(proc, 'ping 127.0.0.1 -n 30 > nul', 'sleep 30');
  proc.ExecuteAsync;

  // Give the child a moment to actually start.
  Sleep(300);
  Assert.AreEqual(TProcessStatus.Running, proc.Status, 'Process should be running before Terminate');

  terminated := proc.Terminate;
  Assert.IsTrue(terminated, 'Terminate should return True when worker acknowledges');

  // After Terminate returns, the worker has finished. Status should reflect
  // a terminated process within a tight window (no extra polling needed).
  start := Now;
  while (proc.Status = TProcessStatus.Running) and
        ((Now - start) * 86400 < 5) do
    Sleep(10);
  Assert.AreEqual(TProcessStatus.Terminated, proc.Status,
                  'Status should be Terminated after successful Terminate');
end;

procedure TProcessExecutionTests.ExecuteAsync_ResetsPriorRunState;
var
  proc : IProcess;
  start : TDateTime;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(proc, 'exit 5', 'exit 5');

  // First run.
  proc.Execute(nil);
  Assert.AreEqual<Cardinal>(5, proc.ExitCode);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);

  // Second run via ExecuteAsync - should clear ExitCode/Status from prior run.
  proc.CommandLine.Clear;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
  proc.ExecuteAsync;

  start := Now;
  while (proc.Status = TProcessStatus.Running) and
        ((Now - start) * 86400 < 5) do
    Sleep(20);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode,
                            'ExitCode from second run should be 0, not 5 (stale)');
end;

// Helpers for ExecuteAsync_NoUseAfterFreeWhenCallerDropsRef: OnExit is
// recorded on a separate object, and a pipe target signals when it is
// destroyed, which happens when the process that owns it is freed.
type
  TDroppedRefExitCapture = class
  public
    Fired : TEvent;
    ExitCode : Cardinal;
    constructor Create;
    destructor Destroy; override;
    procedure HandleExited(const process : IProcess; exitCode : Cardinal);
  end;

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

constructor TDroppedRefExitCapture.Create;
begin
  inherited Create;
  Fired := TEvent.Create(nil, True, False, '');
  ExitCode := $FFFFFFFF;
end;

destructor TDroppedRefExitCapture.Destroy;
begin
  Fired.Free;
  inherited;
end;

procedure TDroppedRefExitCapture.HandleExited(const process : IProcess; exitCode : Cardinal);
begin
  Self.ExitCode := exitCode;
  Fired.SetEvent;
end;

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
// temporaries kept until the end of the routine) do not outlive it.
function MakeDroppedRefProcess(capture : TDroppedRefExitCapture; destroyed : TEvent) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(result, 'ping 127.0.0.1 -n 2 > nul', 'sleep 1');
  result.OnExit := capture.HandleExited;
  result.WithStdOutPipe(TLifetimeProbeTarget.Create(destroyed));
end;

procedure TProcessExecutionTests.ExecuteAsync_NoUseAfterFreeWhenCallerDropsRef;
var
  proc : IProcess;
  capture : TDroppedRefExitCapture;
  destroyed : TEvent;
begin
  capture := TDroppedRefExitCapture.Create;
  destroyed := TEvent.Create(nil, True, False, '');
  try
    proc := MakeDroppedRefProcess(capture, destroyed);
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Assert.IsTrue(proc.ProcessId <> 0, 'Should have a PID after ExecuteAsync');
    Assert.AreEqual(TProcessStatus.Running, proc.Status, 'The child must still be running when the reference is dropped');

    // Drop our reference. The worker thread must keep Self alive until it's
    // finished, then release it.
    proc := nil;

    Assert.AreEqual(wrSignaled, capture.Fired.WaitFor(10000), 'OnExit never fired after the caller dropped its reference');
    Assert.AreEqual<Cardinal>(0, capture.ExitCode, 'OnExit must report the child''s exit code');
    Assert.AreEqual(wrSignaled, destroyed.WaitFor(10000), 'The process was not freed once the run had finished');
  finally
    // Never free what a still-running worker may use.
    if destroyed.WaitFor(10000) = wrSignaled then
    begin
      destroyed.Free;
      capture.Free;
    end;
  end;
end;

// Helper for ExecuteAsync_OnStartedAndOnExitFire. The IProcess event types are
// `of object`, so anonymous procedures will not bind to them; we need real
// methods on a class.
type
  TAsyncEventCapture = class
  public
    StartedFired   : Boolean;
    StartedPID     : Cardinal;
    ExitedFired    : Boolean;
    ExitedExitCode : Cardinal;
    procedure HandleStarted(const process : IProcess);
    procedure HandleExited(const process : IProcess; exitCode : Cardinal);
  end;

procedure TAsyncEventCapture.HandleStarted(const process: IProcess);
begin
  StartedFired := True;
  StartedPID   := process.ProcessId;
end;

procedure TAsyncEventCapture.HandleExited(const process: IProcess; exitCode: Cardinal);
begin
  ExitedFired    := True;
  ExitedExitCode := exitCode;
end;

procedure TProcessExecutionTests.ExecuteAsync_OnStartedAndOnExitFire;
var
  proc    : IProcess;
  capture : TAsyncEventCapture;
  start   : TDateTime;
begin
  capture := TAsyncEventCapture.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupInlineCommand(proc, 'exit 3', 'exit 3');
    proc.OnStarted := capture.HandleStarted;
    proc.OnExit    := capture.HandleExited;
    proc.ExecuteAsync;

    start := Now;
    while (proc.Status = TProcessStatus.Running) and
          ((Now - start) * 86400 < 5) do
      Sleep(20);

    Assert.AreEqual(TProcessStatus.Exited, proc.Status,
                    'Sanity: process should reach Exited');
    Assert.IsTrue(capture.StartedFired, 'OnStarted should have fired');
    Assert.IsTrue(capture.StartedPID <> 0,
                  'OnStarted should expose the child PID');
    Assert.IsTrue(capture.ExitedFired, 'OnExit should have fired');
    Assert.AreEqual<Cardinal>(3, capture.ExitedExitCode,
                              'OnExit must report the child''s real exit code');
  finally
    capture.Free;
  end;
end;

procedure TProcessExecutionTests.Clone_TwoClonesExecuteIndependently;
var
  template, cloneA, cloneB : IProcess;
begin
  template := TProcess.Create;
  template.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(template, 'exit 11', 'exit 11');

  cloneA := template.Clone;
  cloneB := template.Clone;

  // Tweak one clone so we can confirm the change does NOT leak into the other.
  cloneB.CommandLine.Clear;
  TTestHelpers.SetupInlineCommand(cloneB, 'exit 22', 'exit 22');

  cloneA.Execute(nil);
  cloneB.Execute(nil);

  Assert.AreEqual(TProcessStatus.Exited, cloneA.Status, 'cloneA should have exited');
  Assert.AreEqual(TProcessStatus.Exited, cloneB.Status, 'cloneB should have exited');
  Assert.AreEqual<Cardinal>(11, cloneA.ExitCode,
                            'cloneA must report its OWN configured exit code (11)');
  Assert.AreEqual<Cardinal>(22, cloneB.ExitCode,
                            'cloneB must report its OWN configured exit code (22), not leak from cloneA');
  // Template was never executed.
  Assert.AreEqual(TProcessStatus.Idle, template.Status,
                  'Mutating cloneB must not have triggered execution on the template');
end;

procedure TProcessExecutionTests.ExecuteDetached_StartsAndDocumentedPropertiesRaise;
var
  proc : IProcess;
  started : Boolean;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');

  started := proc.ExecuteDetached;
  Assert.IsTrue(started, 'ExecuteDetached should return True for a valid launch');

  // Status stays Running forever; we never observe the detached process exit.
  Assert.AreEqual(TProcessStatus.Running, proc.Status,
                  'Status must remain Running after ExecuteDetached');
  // On Windows we still get the immediate child PID.
  {$IFDEF MSWINDOWS}
  Assert.IsTrue(proc.ProcessId <> 0, 'ProcessId should be populated on Windows');
  {$ENDIF}

  // ExitCode and TimedOut are documented to raise on a detached process.
  Assert.WillRaise(
    procedure
    var
      sink : Cardinal;
    begin
      sink := proc.ExitCode;
      if sink = $DEADBEEF then Exit; // touch sink so it's not "unused"
    end,
    EInvalidOpException,
    'Reading ExitCode on a detached process must raise EInvalidOpException');

  Assert.WillRaise(
    procedure
    var
      sink : Boolean;
    begin
      sink := proc.TimedOut;
      if sink then Exit; // touch sink so it's not "unused"
    end,
    EInvalidOpException,
    'Reading TimedOut on a detached process must raise EInvalidOpException');
end;

procedure TProcessExecutionTests.Posix_CredentialsConfigured_ExecuteReturnsFalse;
var
  proc : IProcess;
  started : Boolean;
  joinedErrors : string;
  i : Integer;
begin
  {$IFDEF MSWINDOWS}
  Assert.Pass('Windows DOES support credentials; this guard only applies to POSIX');
  Exit;
  {$ENDIF}
  proc := TProcess.Create;
  proc.StartInfo.Executable := '/bin/sh';
  proc.CommandLine.Add('-c');
  proc.CommandLine.Add('exit 0');
  proc.Credentials.WithUser('alice').WithPassword('hunter2');

  started := proc.Execute(nil);
  Assert.IsFalse(started,
                 'POSIX must refuse to launch when credentials are configured');
  joinedErrors := '';
  for i := 0 to proc.Errors.Count - 1 do
    joinedErrors := joinedErrors + proc.Errors[i] + #10;
  Assert.IsTrue(Pos('POSIX', joinedErrors) > 0,
                'Error message should mention POSIX; got: ' + joinedErrors);
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessExecutionTests);

end.
