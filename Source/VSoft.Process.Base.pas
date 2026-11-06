unit VSoft.Process.Base;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VSoft.Process,
  VSoft.Process.CommandLine,
  VSoft.Process.Environment,
  VSoft.Process.Credentials,
  VSoft.Process.StartInfo,
  VSoft.CancellationToken;

type
  // Final result of a run. The platform worker fills it in while it waits;
  // TProcessBase publishes it only after every resource has been released.
  TProcessOutcome = record
    Status : TProcessStatus;
    ExitCode : Cardinal;
    TimedOut : boolean;
  end;

  TPipeTargetSlot = record
    Target : IPipeTarget;
    Faulted : boolean;
  end;

  TProcessBase = class;

  // The stdin writer for one run. Its thread works only on this object
  // (reference counted, shared with the process), so a writer still blocked
  // in the source's GetData when the run ends can be left to finish on its
  // own without touching the next run. It keeps the process alive until then.
  IStdInWriter = interface
    // Runs on the writer thread.
    procedure Execute;
    procedure Abort;
    // True once Execute has finished.
    function WaitFor(timeoutMs : Cardinal) : boolean;
    // Why the source failed; read it once WaitFor has returned True.
    function Error : string;
    procedure SetThreadId(value : TThreadID);
  end;

  TStdInWriter = class(TInterfacedObject, IStdInWriter)
  private
    FOwner : TProcessBase;
    FOwnerRef : IInterface;
    FSource : IPipeSource;
    FAbort : Integer;
    FError : string;
    FThreadId : TThreadID;
    FFinished : TEvent;
  protected
    // Writes the source's data until it has no more, the child stops reading
    // or Abort is called, then closes the pipe end (EOF for the child).
    procedure WriteAll;virtual;abstract;
    function IsAborted : boolean;
    property Source : IPipeSource read FSource;
  public
    constructor Create(owner : TProcessBase; const source : IPipeSource);
    destructor Destroy;override;
    procedure Execute;
    procedure Abort;
    function WaitFor(timeoutMs : Cardinal) : boolean;
    function Error : string;
    procedure SetThreadId(value : TThreadID);
  end;

  TProcessBase = class(TInterfacedObject, IProcess)
  private
    // events
    FOnStarted : TProcessStartedEvent;
    FOnExited : TProcessExitedEvent;

    // builders
    FEnvBuilder : IEnvironmentBuilder;
    FCmdLineBuilder : ICommandLineBuilder;
    FCredBuilder : ICredentialsBuilder;
    FStartInfoBuilder : IStartInfoBuilder;

    FErrors : TStringList;
    FErrorsLock : TCriticalSection;

    // configured pipes
    FStdOutTargets : TList<IPipeTarget>;
    FStdErrTargets : TList<IPipeTarget>;
    FStdInSource : IPipeSource;

    // per-run snapshot of the pipes. All HandleData calls go through
    // FDeliveryLock so a process's targets never run concurrently, even when
    // the platform reads stdout and stderr on different threads.
    FRunStdOut : TArray<TPipeTargetSlot>;
    FRunStdErr : TArray<TPipeTargetSlot>;
    FStartedTargets : TList<IPipeTarget>;
    FRunStdInStarted : boolean;
    FDeliveryLock : TCriticalSection;

    // Threads Terminate must never block on (0 = none), because the run can't
    // complete while they are inside a callback:
    //  FWorkerThreadId     : runs DoWaitForCompletion for the current run.
    //  FDeliveringThreadId : currently inside a pipe target's HandleData
    //                        (delivery is serialised, so there is at most one).
    FWorkerThreadId : TThreadID;
    FDeliveringThreadId : TThreadID;

    function StartRun(const cancellationToken : ICancellationToken; const cancellationEvent : TEvent; mode : TProcessStartMode) : boolean;
    procedure RunWorker;
    procedure CompleteRun(const outcome : TProcessOutcome);
    procedure AbortStart;
    procedure DeliverTo(const slots : TArray<TPipeTargetSlot>; const streamName : string; const buffer : TBytes; count : NativeUInt);
    function CanWaitForCompletion : boolean;
    // Called by a stdin writer as it finishes.
    procedure StdInWriterFinished(threadId : TThreadID);
  protected
    // stdin source for the current run (snapshot of WithStdInPipe).
    FRunStdIn : IPipeSource;
    // Full path of the program being launched, set by the platform's
    // validation (PATH search for a bare name).
    FResolvedExecutable : string;
    // The stdin writer thread of the current run while it runs (0 otherwise),
    // so Terminate called from the stdin source does not wait on itself. Set
    // by the platform before the thread starts.
    FStdInWriterThreadId : TThreadID;

    // Status fields. Written by the worker, read from any thread.
    // FExitCode / FTimedOut / FLastError are always written BEFORE FStatus,
    // and FStatus is published with SetStatusAtomic (a full barrier;
    // TProcessStatus is 4 bytes via {$MINENUMSIZE 4}), so a reader that sees
    // the final status also sees the values that go with it.
    FExitCode : Cardinal;
    FStatus : TProcessStatus;
    FTimedOut : boolean;
    FStartMode : TProcessStartMode;
    FLastError : Cardinal;
    //id of the thread that called Execute*
    FStartThreadId : TThreadID;
    // 1 while an Execute* call is between its "no run in progress" check and
    // the point where the run is in progress (FCompletionEvent reset) or its
    // start has failed, so two threads can't both start the same object.
    FRunClaim : Integer;

    // externally owned handles we can wait on
    FCancellationToken : ICancellationToken;
    FCancellationEvent : TEvent;

    //  FTerminateEvent  : set by Terminate(), observed by the worker. Manual-reset.
    //  FCompletionEvent : signalled while no run is in progress (initially
    //                     signalled), reset when a run starts and set again
    //                     only once the run has fully completed. It is the
    //                     re-run guard and what Terminate / Destroy wait on.
    FTerminateEvent    : TEvent;
    FCompletionEvent   : TEvent;

    procedure SetStatusAtomic(value : TProcessStatus);

    function InternalStart : boolean;virtual;
    function InternalStartAsync : boolean;virtual;
    // Create the child. Must leave nothing running (no reads, no threads, no
    // child) when it returns False or raises.
    function DoCreateProcess : boolean;virtual;abstract;
    // Wait for the child to finish (or kill it on terminate / cancel /
    // timeout), then drain and release every pipe, thread and handle before
    // returning. Must not deliver any more data once it returns.
    procedure DoWaitForCompletion(var outcome : TProcessOutcome);virtual;abstract;
    // Launch without redirection or monitoring.
    function DoExecuteDetached : boolean;virtual;abstract;

    // Snapshot the configured pipes for this run, apply the default
    // encodings and Start each target / source once.
    procedure StartPipeTargets;
    // Done every started target / source once. Never raises.
    procedure StopPipeTargets;
    // Inject StartInfo.InputEncoding / OutputEncoding into the attached pipe
    // targets and source when they implement IEncodingAwarePipeTarget /
    // IEncodingAwarePipeSource AND the user did NOT pass an explicit encoding.
    procedure ApplyDefaultEncodings;

    // Deliver a chunk of child output to the run's targets. Thread-safe.
    procedure ProcessStdOut(const buffer : TBytes; count : NativeUInt);
    procedure ProcessStdErr(const buffer : TBytes; count : NativeUInt);

    procedure LogError(const value : string);
    function ValidateStartUpBuilder : boolean;virtual;
    // How long to keep reading after the child has gone.
    function GetDrainTimeout(killed : boolean) : Cardinal;

    // Fire the user-supplied OnStarted / OnExit handlers. Wrapped in try/except
    // so a misbehaving handler can't crash the worker thread or leak an
    // exception out of an internal start path.
    procedure DoOnStarted;
    procedure DoOnExited(exitCode : Cardinal);

    procedure ResetStatus;virtual;
    function IsReadyForRun : boolean;
    // Raises EInvalidOpException when a run is in progress or another thread
    // is starting one.
    procedure ClaimRun;
    procedure ReleaseRunClaim;

    function ShouldRedirectStdOut : boolean;
    function ShouldRedirectStdErr : boolean;
    function ShouldRedirectStdIn  : boolean;

    function GetStartInfo : IStartInfoBuilder;
    function GetCredentials : ICredentialsBuilder;
    function GetCommandLine : ICommandLineBuilder;
    function GetEnvironment : IEnvironmentBuilder;

    function GetOnStarted   : TProcessStartedEvent;
    procedure SetOnStarted(const value : TProcessStartedEvent);
    function GetOnExited   : TProcessExitedEvent;
    procedure SetOnExited(const value : TProcessExitedEvent);

    function GetLastError : Cardinal;
    function GetStartMode : TProcessStartMode;
    function GetExitCode : Cardinal;
    function GetStatus : TProcessStatus;
    function GetTimedOut : boolean;
    function GetProcessId : Cardinal;virtual;abstract;
    function GetErrors : TStrings;
    function GetResolvedExecutable : string;
    {$IFDEF MSWINDOWS}
    function GetCompletionHandle : THandle;
    {$ENDIF}
    //fluent configuration
    function WithStartInfo(const proc : TConstProc<IStartInfoBuilder>) : IProcess;
    function WithCommandLine(const proc : TConstProc<ICommandLineBuilder>) : IProcess;
    function WithEnvironment(const proc : TConstProc<IEnvironmentBuilder>) : IProcess;
    function WithCredentials(const proc : TConstProc<ICredentialsBuilder>) : IProcess;

    function WithStdOutPipe(const pipeTarget : IPipeTarget) : IProcess;
    function WithStdErrPipe(const pipeTarget : IPipeTarget) : IProcess;
    function WithStdInPipe(const pipeSource : IPipeSource) : IProcess;
    function Execute(const cancellationToken : ICancellationToken = nil) : boolean;overload;
    function Execute(const cancellationEvent : TEvent) : boolean;overload;
    function ExecuteAsync(const cancellationToken : ICancellationToken = nil) : boolean;overload;
    function ExecuteAsync(const cancellationEvent : TEvent) : boolean;overload;
    function ExecuteDetached : boolean;

    function Terminate : boolean;virtual;
    function IsCancelled : boolean;virtual;
    // Terminate has been called or the run's cancellation token / event is set.
    function IsStopRequested : boolean;

    function Clone : IProcess;virtual;abstract;
    constructor CreateClone(const source : TProcessBase);virtual;

    property CommandLine : ICommandLineBuilder read GetCommandLine;
    property Credentials : ICredentialsBuilder read GetCredentials;
    property Environment :  IEnvironmentBuilder read GetEnvironment;
    property StartInfo : IStartInfoBuilder read GetStartInfo;
  public
    constructor Create;virtual;
    destructor Destroy;override;
  end;

// Native id of the calling thread (no TThread object is created for
// threadpool / foreign threads).
function CurrentThreadId : TThreadID;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows;
  {$ELSE}
  Posix.Pthread;
  {$ENDIF}

function CurrentThreadId : TThreadID;
begin
  {$IFDEF MSWINDOWS}
  result := Winapi.Windows.GetCurrentThreadId;
  {$ELSE}
  result := TThreadID(pthread_self);
  {$ENDIF}
end;

{ TStdInWriter }

constructor TStdInWriter.Create(owner : TProcessBase; const source : IPipeSource);
begin
  inherited Create;
  FOwner := owner;
  FOwnerRef := owner;
  FSource := source;
  FFinished := TEvent.Create(nil, true, false, '');
end;

destructor TStdInWriter.Destroy;
begin
  FFinished.Free;
  inherited;
end;

procedure TStdInWriter.Execute;
begin
  try
    try
      WriteAll;
    except
      on E : Exception do
        FError := 'Stdin pipe source raised ' + E.ClassName + ' - ' + E.Message;
    end;
  finally
    FOwner.StdInWriterFinished(FThreadId);
    FOwner := nil;
    FSource := nil;
    FFinished.SetEvent;
    // Last: it can be the final reference to the process.
    FOwnerRef := nil;
  end;
end;

procedure TStdInWriter.Abort;
begin
  TInterlocked.Exchange(FAbort, 1);
end;

function TStdInWriter.IsAborted : boolean;
begin
  result := FAbort <> 0;
end;

function TStdInWriter.WaitFor(timeoutMs : Cardinal) : boolean;
begin
  result := FFinished.WaitFor(timeoutMs) = wrSignaled;
end;

function TStdInWriter.Error : string;
begin
  result := FError;
end;

procedure TStdInWriter.SetThreadId(value : TThreadID);
begin
  FThreadId := value;
end;

function SnapshotTargets(const list : TList<IPipeTarget>) : TArray<TPipeTargetSlot>;
var
  i : integer;
begin
  SetLength(result, list.Count);
  for i := 0 to list.Count - 1 do
  begin
    result[i].Target := list[i];
    result[i].Faulted := false;
  end;
end;

{ TProcessBase }

constructor TProcessBase.Create;
begin
  inherited Create;
  FCmdLineBuilder := TArgumentsBuilder.Create;
  FCredBuilder := TCredentialsBuilder.Create;
  FEnvBuilder := TEnvironmentBuilder.Create;
  FStartInfoBuilder := TStartInfoBuilder.Create;
  FTerminateEvent := TEvent.Create(nil, true, false, '');
  FCompletionEvent := TEvent.Create(nil, true, true, '');
  FErrors := TStringList.Create;
  FErrorsLock := TCriticalSection.Create;
  FDeliveryLock := TCriticalSection.Create;
  FExitCode := $FFFFFFFF;
  SetStatusAtomic(TProcessStatus.Idle);
  FTimedOut := false;
  FStartMode := TProcessStartMode.Sync;

  FStdOutTargets := TList<IPipeTarget>.Create;
  FStdErrTargets := TList<IPipeTarget>.Create;
  FStartedTargets := TList<IPipeTarget>.Create;
end;

procedure TProcessBase.SetStatusAtomic(value: TProcessStatus);
begin
  TInterlocked.Exchange(PInteger(@FStatus)^, Integer(value));
end;

constructor TProcessBase.CreateClone(const source: TProcessBase);
begin
  Create;
  FCmdLineBuilder   := source.GetCommandLine.Clone;
  FCredBuilder      := source.GetCredentials.Clone;
  FEnvBuilder       := source.GetEnvironment.Clone;
  FStartInfoBuilder := source.GetStartInfo.Clone;
end;

destructor TProcessBase.Destroy;
begin
  if (FCompletionEvent <> nil) and (FCompletionEvent.WaitFor(0) <> wrSignaled) then
  begin
    // A run is still active (only possible for a synchronous Execute on
    // another thread). Ask it to stop and wait until it has released
    // everything we are about to free. Every wait inside the worker is
    // bounded, so this terminates.
    FTerminateEvent.SetEvent;
    FCompletionEvent.WaitFor(INFINITE);
  end;

  FTerminateEvent.Free;
  FCompletionEvent.Free;
  FErrors.Free;
  FErrorsLock.Free;
  FDeliveryLock.Free;
  FStdOutTargets.Free;
  FStdErrTargets.Free;
  FStartedTargets.Free;

  inherited;
end;

function TProcessBase.IsReadyForRun : boolean;
begin
  result := FCompletionEvent.WaitFor(0) = wrSignaled;
end;

procedure TProcessBase.ClaimRun;
begin
  if TInterlocked.CompareExchange(FRunClaim, 1, 0) <> 0 then
    raise EInvalidOpException.Create('Process is already running');
  if not IsReadyForRun then
  begin
    ReleaseRunClaim;
    raise EInvalidOpException.Create('Process is already running');
  end;
end;

procedure TProcessBase.ReleaseRunClaim;
begin
  TInterlocked.Exchange(FRunClaim, 0);
end;

function TProcessBase.StartRun(const cancellationToken : ICancellationToken; const cancellationEvent : TEvent; mode : TProcessStartMode) : boolean;
var
  handedOver : boolean;
begin
  ClaimRun;
  handedOver := false;
  result := false;
  try
    ResetStatus;
    FStartMode := mode;
    FCancellationToken := cancellationToken;
    FCancellationEvent := cancellationEvent;
    try
      if (FCancellationToken <> nil) and FCancellationToken.IsCancelled then
      begin
        LogError('Cancellation token is cancelled');
        exit;
      end;
      if (FCancellationEvent <> nil) and (FCancellationEvent.WaitFor(0) = wrSignaled) then
      begin
        LogError('Cancellation event is signalled');
        exit;
      end;
      if not ValidateStartUpBuilder then //this logs its own errors
        exit;
      // InternalStart / InternalStartAsync release the claim once the run is
      // in progress (or has failed to start).
      handedOver := true;
      if mode = TProcessStartMode.Sync then
        result := InternalStart
      else
        result := InternalStartAsync;
    finally
      // A run that started owns the references until CompleteRun clears them.
      if not result then
      begin
        FCancellationToken := nil;
        FCancellationEvent := nil;
      end;
    end;
  finally
    if not handedOver then
      ReleaseRunClaim;
  end;
end;

function TProcessBase.Execute(const cancellationEvent: TEvent): boolean;
begin
  result := StartRun(nil, cancellationEvent, TProcessStartMode.Sync);
end;

function TProcessBase.Execute(const cancellationToken: ICancellationToken): boolean;
begin
  result := StartRun(cancellationToken, nil, TProcessStartMode.Sync);
end;

function TProcessBase.ExecuteAsync(const cancellationToken: ICancellationToken): boolean;
begin
  result := StartRun(cancellationToken, nil, TProcessStartMode.Async);
end;

function TProcessBase.ExecuteAsync(const cancellationEvent: TEvent): boolean;
begin
  result := StartRun(nil, cancellationEvent, TProcessStartMode.Async);
end;

function TProcessBase.ExecuteDetached: boolean;
begin
  // A detached launch never marks a run as in progress, so the claim is
  // held for the whole call.
  ClaimRun;
  try
    result := false;
    ResetStatus;
    FStartMode := TProcessStartMode.Detached;
    if not ValidateStartUpBuilder then
      exit;
    result := DoExecuteDetached;
    if result then
      SetStatusAtomic(TProcessStatus.Running);
  finally
    ReleaseRunClaim;
  end;
  // OnStarted fires for detached too. OnExit cannot - the OS never tells us a
  // detached process exited.
  if result then
    DoOnStarted;
end;

function TProcessBase.GetCommandLine: ICommandLineBuilder;
begin
  result := FCmdLineBuilder;
end;

{$IFDEF MSWINDOWS}
function TProcessBase.GetCompletionHandle : THandle;
begin
  result := FCompletionEvent.Handle;
end;
{$ENDIF}

function TProcessBase.GetCredentials: ICredentialsBuilder;
begin
  result := FCredBuilder;
end;

function TProcessBase.GetDrainTimeout(killed : boolean) : Cardinal;
begin
  result := FStartInfoBuilder.PipeDrainTimeoutMS;
  if killed and (result = INFINITE) then
    result := DEFAULT_PIPE_DRAIN_TIMEOUT_MS;
end;

function TProcessBase.GetEnvironment: IEnvironmentBuilder;
begin
  result := FEnvBuilder;
end;

function TProcessBase.GetErrors: TStrings;
begin
  result := FErrors;
end;

function TProcessBase.GetResolvedExecutable : string;
begin
  result := FResolvedExecutable;
end;

function TProcessBase.GetExitCode: Cardinal;
begin
  if FStartMode = TProcessStartMode.Detached then
    raise EInvalidOpException.Create('Cannot get exit code from detached process');
  result := FExitCode;
end;

function TProcessBase.GetLastError: Cardinal;
begin
  result := FLastError;
end;

function TProcessBase.GetOnExited: TProcessExitedEvent;
begin
  result := FOnExited;
end;

function TProcessBase.GetOnStarted: TProcessStartedEvent;
begin
  result := FOnStarted;
end;

function TProcessBase.GetStartInfo: IStartInfoBuilder;
begin
  result := FStartInfoBuilder;
end;

function TProcessBase.GetStartMode: TProcessStartMode;
begin
  result := FStartMode;
end;

function TProcessBase.GetStatus: TProcessStatus;
begin
  result := FStatus;
end;

function TProcessBase.GetTimedOut: boolean;
begin
  if FStartMode = TProcessStartMode.Detached then
    raise EInvalidOpException.Create('Cannot read TimedOut on a detached process');
  result := FTimedOut;
end;

function TProcessBase.InternalStart: boolean;
begin
  result := false;
  FStartThreadId := CurrentThreadId;
  // The calling thread is the worker for a synchronous run.
  FWorkerThreadId := FStartThreadId;
  FTerminateEvent.ResetEvent;
  FCompletionEvent.ResetEvent;
  // From here the completion event marks the run as in progress.
  ReleaseRunClaim;
  try
    StartPipeTargets;
    result := DoCreateProcess;
  finally
    if not result then
      AbortStart;
  end;
  if not result then
    exit;
  SetStatusAtomic(TProcessStatus.Running);
  DoOnStarted;
  RunWorker;
end;

function TProcessBase.InternalStartAsync: boolean;
var
  selfRef : IProcess;
  worker : TThread;
begin
  result := false;
  FStartThreadId := CurrentThreadId;
  FWorkerThreadId := 0;
  FTerminateEvent.ResetEvent;
  FCompletionEvent.ResetEvent;
  // From here the completion event marks the run as in progress.
  ReleaseRunClaim;
  try
    StartPipeTargets;
    result := DoCreateProcess;
  finally
    if not result then
      AbortStart;
  end;
  if not result then
    exit;
  SetStatusAtomic(TProcessStatus.Running);
  // Fired on the calling thread before ExecuteAsync returns.
  DoOnStarted;
  // The closure holds an IProcess reference so the worker keeps Self alive
  // even if the caller drops theirs while the child is still running.
  selfRef := Self;
  try
    worker := TThread.CreateAnonymousThread(
      procedure
      begin
        try
          RunWorker;
        finally
          selfRef := nil;
        end;
      end);
  except
    // No monitor thread: stop the child and clean up on this thread.
    selfRef := nil;
    FTerminateEvent.SetEvent;
    FWorkerThreadId := CurrentThreadId;
    RunWorker;
    raise;
  end;
  FWorkerThreadId := worker.ThreadID;
  worker.Start;
end;

procedure TProcessBase.RunWorker;
var
  outcome : TProcessOutcome;
begin
  outcome.Status := TProcessStatus.Terminated;
  outcome.ExitCode := FStartInfoBuilder.TerminateExitCode;
  outcome.TimedOut := false;
  try
    try
      DoWaitForCompletion(outcome);
    except
      on E : Exception do
        LogError('Error while waiting for the process: ' + E.ClassName + ' - ' + E.Message);
    end;
  finally
    StopPipeTargets;
    CompleteRun(outcome);
  end;
  DoOnExited(outcome.ExitCode);
end;

procedure TProcessBase.CompleteRun(const outcome : TProcessOutcome);
begin
  FExitCode := outcome.ExitCode;
  FTimedOut := outcome.TimedOut;
  // Release the cancellation references before the run is published so an
  // OnExit handler (or a poller) that starts the next run keeps its own.
  FCancellationToken := nil;
  FCancellationEvent := nil;
  FWorkerThreadId := 0;
  SetStatusAtomic(outcome.Status);
  FCompletionEvent.SetEvent;
end;

procedure TProcessBase.AbortStart;
begin
  StopPipeTargets;
  FCancellationToken := nil;
  FCancellationEvent := nil;
  FWorkerThreadId := 0;
  FCompletionEvent.SetEvent;
end;

function TProcessBase.IsCancelled: boolean;
begin
  if FCancellationToken <> nil then
    result := FCancellationToken.IsCancelled
  else if FCancellationEvent <> nil then
    result := FCancellationEvent.WaitFor(0) = TWaitResult.wrSignaled
  else
    result := false;
end;

function TProcessBase.IsStopRequested : boolean;
begin
  result := IsCancelled or (FTerminateEvent.WaitFor(0) = TWaitResult.wrSignaled);
end;

procedure TProcessBase.LogError(const value: string);
begin
  FErrorsLock.Enter;
  try
    FErrors.Add(value);
  finally
    FErrorsLock.Leave;
  end;
end;

procedure TProcessBase.DoOnStarted;
var
  handler : TProcessStartedEvent;
  selfRef : IProcess;
begin
  handler := FOnStarted;
  if not Assigned(handler) then
    Exit;
  if FStartInfoBuilder.MarshallEventsToMainThread and (CurrentThreadId <> MainThreadID) then
  begin
    // The queued closure holds a reference so Self outlives the queue.
    selfRef := Self;
    TThread.Queue(nil,
      procedure
      begin
        try
          handler(selfRef);
        except
          on E: Exception do
            LogError('OnStarted handler raised: ' + E.ClassName + ' - ' + E.Message);
        end;
      end);
    Exit;
  end;
  try
    handler(Self);
  except
    on E: Exception do
      LogError('OnStarted handler raised: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

procedure TProcessBase.DoOnExited(exitCode : Cardinal);
var
  handler : TProcessExitedEvent;
  selfRef : IProcess;
begin
  handler := FOnExited;
  if not Assigned(handler) then
    Exit;
  if FStartInfoBuilder.MarshallEventsToMainThread and (CurrentThreadId <> MainThreadID) then
  begin
    selfRef := Self;
    TThread.Queue(nil,
      procedure
      begin
        try
          handler(selfRef, exitCode);
        except
          on E: Exception do
            LogError('OnExit handler raised: ' + E.ClassName + ' - ' + E.Message);
        end;
      end);
    Exit;
  end;
  try
    handler(Self, exitCode);
  except
    on E: Exception do
      LogError('OnExit handler raised: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

procedure TProcessBase.DeliverTo(const slots : TArray<TPipeTargetSlot>; const streamName : string; const buffer : TBytes; count : NativeUInt);
var
  i : integer;
  streamAware : IStreamAwarePipeTarget;
begin
  for i := 0 to High(slots) do
  begin
    if slots[i].Faulted then
      continue;
    try
      // A target attached to both streams keeps each stream's partial line
      // apart when it is told which one this is.
      if Supports(slots[i].Target, IStreamAwarePipeTarget, streamAware) then
        streamAware.HandleStreamData(streamName = 'stderr', buffer, count)
      else
        slots[i].Target.HandleData(buffer, count);
    except
      on E : Exception do
      begin
        slots[i].Faulted := true;
        LogError(streamName + ' pipe target raised ' + E.ClassName + ' - ' + E.Message + ' (it receives no more data this run)');
      end;
      else
      begin
        slots[i].Faulted := true;
        LogError(streamName + ' pipe target raised a non-Exception object (it receives no more data this run)');
      end;
    end;
  end;
end;

procedure TProcessBase.ProcessStdErr(const buffer: TBytes; count: NativeUInt);
begin
  FDeliveryLock.Enter;
  try
    FDeliveringThreadId := CurrentThreadId;
    DeliverTo(FRunStdErr, 'stderr', buffer, count);
  finally
    FDeliveringThreadId := 0;
    FDeliveryLock.Leave;
  end;
end;

procedure TProcessBase.ProcessStdOut(const buffer: TBytes; count: NativeUInt);
begin
  FDeliveryLock.Enter;
  try
    FDeliveringThreadId := CurrentThreadId;
    DeliverTo(FRunStdOut, 'stdout', buffer, count);
  finally
    FDeliveringThreadId := 0;
    FDeliveryLock.Leave;
  end;
end;

procedure TProcessBase.ResetStatus;
begin
  FResolvedExecutable := '';
  FExitCode := $FFFFFFFF;
  FTimedOut := false;
  FLastError := 0;
  SetStatusAtomic(TProcessStatus.Idle);
  FErrorsLock.Enter;
  try
    FErrors.Clear;
  finally
    FErrorsLock.Leave;
  end;
end;

procedure TProcessBase.SetOnExited(const value: TProcessExitedEvent);
begin
  FOnExited := value;
end;

procedure TProcessBase.SetOnStarted(const value: TProcessStartedEvent);
begin
  FOnStarted := value;
end;

function TProcessBase.ShouldRedirectStdErr: boolean;
begin
  result := Length(FRunStdErr) > 0;
end;

function TProcessBase.ShouldRedirectStdIn: boolean;
begin
  result := FRunStdIn <> nil;
end;

function TProcessBase.ShouldRedirectStdOut: boolean;
begin
  result := Length(FRunStdOut) > 0;
end;

procedure TProcessBase.StartPipeTargets;

  procedure StartTargets(const slots : TArray<TPipeTargetSlot>);
  var
    i : integer;
  begin
    for i := 0 to High(slots) do
    begin
      // A target attached to both streams is started (and later Done) once.
      if FStartedTargets.IndexOf(slots[i].Target) < 0 then
      begin
        slots[i].Target.Start;
        FStartedTargets.Add(slots[i].Target);
      end;
    end;
  end;

begin
  FStartedTargets.Clear;
  FRunStdOut := SnapshotTargets(FStdOutTargets);
  FRunStdErr := SnapshotTargets(FStdErrTargets);
  FRunStdIn := FStdInSource;
  FRunStdInStarted := false;
  ApplyDefaultEncodings;
  StartTargets(FRunStdOut);
  StartTargets(FRunStdErr);
  if FRunStdIn <> nil then
  begin
    FRunStdIn.Start;
    FRunStdInStarted := true;
  end;
end;

procedure TProcessBase.ApplyDefaultEncodings;
var
  i : integer;
  outputEnc : TEncoding;
  inputEnc : TEncoding;
  targetEnc : IEncodingAwarePipeTarget;
  sourceEnc : IEncodingAwarePipeSource;
begin
  outputEnc := FStartInfoBuilder.OutputEncoding;
  if outputEnc <> nil then
  begin
    for i := 0 to High(FRunStdOut) do
      if Supports(FRunStdOut[i].Target, IEncodingAwarePipeTarget, targetEnc) then
        targetEnc.SetDefaultEncoding(outputEnc);
    for i := 0 to High(FRunStdErr) do
      if Supports(FRunStdErr[i].Target, IEncodingAwarePipeTarget, targetEnc) then
        targetEnc.SetDefaultEncoding(outputEnc);
  end;

  inputEnc := FStartInfoBuilder.InputEncoding;
  if (inputEnc <> nil) and (FRunStdIn <> nil) then
    if Supports(FRunStdIn, IEncodingAwarePipeSource, sourceEnc) then
      sourceEnc.SetDefaultEncoding(inputEnc);
end;

procedure TProcessBase.StopPipeTargets;
var
  i : integer;
begin
  for i := 0 to FStartedTargets.Count - 1 do
  begin
    try
      FStartedTargets[i].Done;
    except
      on E : Exception do
        LogError('Pipe target Done raised ' + E.ClassName + ' - ' + E.Message);
    end;
  end;
  FStartedTargets.Clear;
  if FRunStdInStarted then
  begin
    FRunStdInStarted := false;
    try
      FRunStdIn.Done;
    except
      on E : Exception do
        LogError('Stdin pipe source Done raised ' + E.ClassName + ' - ' + E.Message);
    end;
  end;
  SetLength(FRunStdOut, 0);
  SetLength(FRunStdErr, 0);
  FRunStdIn := nil;
end;

procedure TProcessBase.StdInWriterFinished(threadId : TThreadID);
begin
  // Only while it is still this writer's id: a writer an earlier run left
  // behind must not clear the current run's.
  {$IFDEF MSWINDOWS}
  TInterlocked.CompareExchange(Integer(FStdInWriterThreadId), 0, Integer(threadId));
  {$ELSE}
  TInterlocked.CompareExchange(Int64(FStdInWriterThreadId), 0, Int64(threadId));
  {$ENDIF}
end;

function TProcessBase.CanWaitForCompletion : boolean;
var
  currentId : TThreadID;
begin
  // Never wait on ourselves: from the thread that runs the worker (sync
  // Execute, or an event handler on the async worker), from a pipe target or
  // stdin source callback, or before the async worker exists (OnStarted).
  // The id fields are read without a lock: a thread can only ever find its
  // own id in them if it stored it there itself, and the ids are never 0.
  currentId := CurrentThreadId;
  result := (FWorkerThreadId <> 0) and
            (currentId <> FWorkerThreadId) and
            (currentId <> FDeliveringThreadId) and
            (currentId <> FStdInWriterThreadId);
end;

function TProcessBase.Terminate: boolean;
const
  cTerminateAckTimeoutMS = 5000;
begin
  if (FStartMode = TProcessStartMode.Detached) or IsReadyForRun then
    Exit(false);
  FTerminateEvent.SetEvent;
  if not CanWaitForCompletion then
    Exit(true);
  result := FCompletionEvent.WaitFor(cTerminateAckTimeoutMS) = wrSignaled;
end;

function TProcessBase.ValidateStartUpBuilder: boolean;
begin
  result := true;
  if FStartInfoBuilder.Executable = '' then
  begin
    LogError('Executable property not set');
    result := false;
  end;
  if (FStartInfoBuilder.WorkingDirectory <> '') and (not DirectoryExists(FStartInfoBuilder.WorkingDirectory)) then
  begin
    LogError('WorkingDirectory does not exist');
    result := false;
  end;
  if (not FStartInfoBuilder.TerminateOnTimeout) and (FStartInfoBuilder.JobMode = TProcessJobMode.KillOnRelease) then
  begin
    LogError('TerminateOnTimeout = False needs JobMode KillOnTerminate or NoJob: with KillOnRelease the child left running would be killed when the IProcess is released or run again');
    result := false;
  end;
  {$IFDEF MSWINDOWS}
  // Only run credential validation when the caller actually configured
  // credentials - an unconfigured CredentialsBuilder is the default case
  // and must remain a no-op.
  if (FCredBuilder.UserName <> '') or
     (FCredBuilder.Domain <> '') or
     (FCredBuilder.Password <> '') then
  begin
    if not FCredBuilder.Validate(LogError) then
      result := false;
  end;
  {$ELSE}
  // POSIX has no equivalent to CreateProcessWithLogonW. Refuse to silently
  // run the child as the current user when the caller has configured
  // credentials - that would be misleading and is almost certainly a bug.
  if (FCredBuilder.UserName <> '') or
     (FCredBuilder.Domain <> '') or
     (FCredBuilder.Password <> '') then
  begin
    LogError('Credentials are not supported on POSIX platforms');
    result := false;
  end;
  {$ENDIF}
end;

function TProcessBase.WithCommandLine(const proc: TConstProc<ICommandLineBuilder>): IProcess;
begin
  if Assigned(proc) then
    proc(FCmdLineBuilder);
  result := Self;
end;

function TProcessBase.WithCredentials(const proc: TConstProc<ICredentialsBuilder>): IProcess;
begin
  if Assigned(proc) then
    proc(FCredBuilder);
  result := Self;
end;

function TProcessBase.WithEnvironment(const proc: TConstProc<IEnvironmentBuilder>): IProcess;
begin
  if Assigned(proc) then
    proc(FEnvBuilder);
  result := Self;
end;

function TProcessBase.WithStartInfo(const proc: TConstProc<IStartInfoBuilder>): IProcess;
begin
  if Assigned(proc) then
    proc(FStartInfoBuilder);
  result := Self;
end;

function TProcessBase.WithStdErrPipe(const pipeTarget: IPipeTarget): IProcess;
begin
  if pipeTarget = nil then
    raise EArgumentNilException.Create('pipeTarget');
  FStdErrTargets.Add(pipeTarget);
  result := Self;
end;

function TProcessBase.WithStdInPipe(const pipeSource: IPipeSource): IProcess;
begin
  FStdInSource := pipeSource;
  result := self;
end;

function TProcessBase.WithStdOutPipe(const pipeTarget: IPipeTarget): IProcess;
begin
  if pipeTarget = nil then
    raise EArgumentNilException.Create('pipeTarget');
  FStdOutTargets.Add(pipeTarget);
  result := Self;
end;

end.
