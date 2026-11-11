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
    // Where the target is in the run's started targets. Its fault flag is
    // kept there, once per target: a target attached to both streams has a
    // slot in each but must stop receiving both when it raises.
    StartedIndex : integer;
  end;

  TProcessBase = class;

  // The stdin writer for one run. Its thread works only on this object
  // (reference counted, shared with the process), so a writer still blocked
  // in the source's GetData when the run ends can be left to finish on its
  // own without touching the next run. It keeps the process alive until then,
  // unless the run detaches it.
  IStdInWriter = interface
    // Runs on the writer thread.
    procedure Execute;
    procedure Abort;
    // True once Execute has finished.
    function WaitFor(timeoutMs : Cardinal) : boolean;
    // Why the source failed; read it once WaitFor has returned True.
    function Error : string;
    procedure SetThreadId(value : TThreadID);
    // Cuts a writer that is being left behind loose from its process, so it
    // no longer keeps the process alive. Returns the writer's reference to
    // the process for the run to release once it no longer touches it.
    function Detach : IInterface;
  end;

  TStdInWriter = class(TInterfacedObject, IStdInWriter)
  private
    FOwner : TProcessBase;
    FOwnerRef : IInterface;
    // Guards FOwner / FOwnerRef between Execute's end and Detach.
    FOwnerLock : TCriticalSection;
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
    function Detach : IInterface;
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
    // One flag per started target (TPipeTargetSlot.StartedIndex), set when
    // it raises. Only touched under FDeliveryLock once the run has started.
    FTargetFaulted : TArray<boolean>;
    FRunStdInStarted : boolean;
    FDeliveryLock : TCriticalSection;

    // Threads Terminate must never block on (0 = none), because the run can't
    // complete while they are inside a callback:
    //  FWorkerThreadId     : runs DoWaitForCompletion for the current run. 0
    //                        while ExecuteAsync is still starting the run;
    //                        FStartThreadId is the thread to avoid until then.
    //  FDeliveringThreadId : currently inside a pipe target's HandleData
    //                        (delivery is serialised, so there is at most one).
    FWorkerThreadId : TThreadID;
    FDeliveringThreadId : TThreadID;

    // FTerminateEvent is shared by every run of this object. Each run has a
    // number, and FTerminateLock makes "is it still the run I saw in
    // progress? then set the event" one step against the next run's "new
    // number, reset the event", so a Terminate that is overtaken by the end
    // of its run can't stop the run started after it.
    FRunGeneration : Integer;
    FTerminateLock : TCriticalSection;

    function StartRun(const cancellationToken : ICancellationToken; const cancellationEvent : TEvent; mode : TProcessStartMode) : boolean;
    // Waits for the child, completes the run and fires OnExit, on the calling
    // thread. raiseToCaller is passed to DoOnExited.
    procedure RunWorker(raiseToCaller : boolean);
    procedure CompleteRun(const outcome : TProcessOutcome);
    procedure AbortStart;
    procedure DeliverTo(const slots : TArray<TPipeTargetSlot>; isStdErr : boolean; const buffer : TBytes; count : NativeUInt);
    // Starts a new run generation with no terminate request pending.
    procedure ResetTerminateRequest;
    // Sets the terminate event unless a later run than the given one has
    // started; False when one has.
    function RequestTerminate(generation : Integer) : boolean;
    function CanWaitForCompletion : boolean;
    function WaitForCompletion(waitMS : Cardinal) : boolean;
    // A detached child is out there: ExitCode / TimedOut can't be read.
    function IsDetachedRun : boolean;
    // Called by a stdin writer as it finishes.
    procedure StdInWriterFinished(threadId : TThreadID);
  protected
    // The process reference handed back by a stdin writer that was detached
    // (left blocked in its source's GetData). Released by the run as its
    // very last action, so the process is never freed in the middle of it.
    FDetachedOwnerRef : IInterface;
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

    // Fire the user-supplied OnStarted / OnExit handlers. A handler queued to
    // the main thread has no caller to raise to: what it raises goes to the
    // application's exception handler, or to Errors when there is none.
    //
    // Called directly, DoOnStarted raises what the handler raised. It is then
    // for the caller to stop and complete the run before passing it on.
    procedure DoOnStarted;
    // Called directly, what the handler raised is raised from here when
    // raiseToCaller is set (a synchronous Execute, whose caller gets it) and
    // logged to Errors otherwise: the ExecuteAsync worker thread has no caller,
    // and a run being completed for an earlier exception passes that one on.
    procedure DoOnExited(exitCode : Cardinal; raiseToCaller : boolean);
    // For use in an except block, where an OnStarted / OnExit handler raised.
    procedure LogHandlerException(const eventName : string);
    procedure ReportQueuedHandlerException(const eventName : string);

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
    function ClearStdOutPipes : IProcess;
    function ClearStdErrPipes : IProcess;
    function ClearPipes : IProcess;
    function Execute(const cancellationToken : ICancellationToken = nil) : boolean;overload;
    function Execute(const cancellationEvent : TEvent) : boolean;overload;
    function ExecuteAsync(const cancellationToken : ICancellationToken = nil) : boolean;overload;
    function ExecuteAsync(const cancellationEvent : TEvent) : boolean;overload;
    function ExecuteDetached : boolean;

    function Terminate : boolean;overload;virtual;
    function Terminate(waitMS : Cardinal) : boolean;overload;virtual;
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
  System.Diagnostics,
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
  FOwnerLock := TCriticalSection.Create;
end;

destructor TStdInWriter.Destroy;
begin
  FFinished.Free;
  FOwnerLock.Free;
  inherited;
end;

procedure TStdInWriter.Execute;
var
  ownerRef : IInterface;
begin
  try
    try
      WriteAll;
    except
      on E : Exception do
        FError := 'Stdin pipe source raised ' + E.ClassName + ' - ' + E.Message;
    end;
  finally
    // Under the lock: a detached writer's process may already be gone.
    FOwnerLock.Enter;
    try
      if FOwner <> nil then
        FOwner.StdInWriterFinished(FThreadId);
      FOwner := nil;
      ownerRef := FOwnerRef;
      FOwnerRef := nil;
    finally
      FOwnerLock.Leave;
    end;
    FSource := nil;
    FFinished.SetEvent;
    // Last: it can be the final reference to the process.
    ownerRef := nil;
  end;
end;

function TStdInWriter.Detach : IInterface;
begin
  FOwnerLock.Enter;
  try
    FOwner := nil;
    result := FOwnerRef;
    FOwnerRef := nil;
  finally
    FOwnerLock.Leave;
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
    result[i].StartedIndex := -1;
  end;
end;

// The exception being handled, as text for Errors. For use in an except block.
function CurrentExceptionText : string;
var
  raised : TObject;
begin
  raised := ExceptObject;
  if raised is Exception then
    result := raised.ClassName + ' - ' + Exception(raised).Message
  else
    result := 'a non-Exception object';
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
  FTerminateLock := TCriticalSection.Create;
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
  // A run holds its own reference to this object until it has finished with
  // it (OnExit included), so when used through IProcess this object is never
  // destroyed during a run. What follows covers a synchronous Execute still in
  // progress on another thread when the object is freed. It does NOT make use
  // without an interface reference safe: the completion event is set before
  // OnExit fires, so Destroy can return and free the object before the run's
  // tail has finished with it. Such use is unsupported (an OnStarted/OnExit
  // handler already frees a RefCount 0 object through the temporary reference
  // that handler(Self) takes). The caller must also hold a reference until
  // Execute has started: the RefCount check that takes the run's own reference
  // is not atomic against a concurrent last release.
  if (FCompletionEvent <> nil) and (FCompletionEvent.WaitFor(0) <> wrSignaled) then
  begin
    // Ask it to stop and wait until it has released everything we are about
    // to free. Every library wait inside the worker is bounded; only user
    // code (a target, a source's Done) can hold it longer, and freeing early
    // would be a use-after-free.
    FTerminateEvent.SetEvent;
    FCompletionEvent.WaitFor(INFINITE);
  end;

  FTerminateEvent.Free;
  FCompletionEvent.Free;
  FErrors.Free;
  FErrorsLock.Free;
  FDeliveryLock.Free;
  FTerminateLock.Free;
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
  valid : boolean;
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
      valid := ValidateStartUpBuilder; //this logs its own errors
      // Checked here and not in ValidateStartUpBuilder: ExecuteDetached
      // ignores the timeout and JobMode.
      if (not FStartInfoBuilder.TerminateOnTimeout) and (FStartInfoBuilder.JobMode = TProcessJobMode.KillOnRelease) then
      begin
        LogError('TerminateOnTimeout = False needs JobMode KillOnTerminate or NoJob: with KillOnRelease the child left running would be killed when the IProcess is released or run again');
        valid := false;
      end;
      if not valid then
        exit;
      // InternalStart / InternalStartAsync release the claim once the run is
      // in progress (or has failed to start).
      handedOver := true;
      if mode = TProcessStartMode.Sync then
        result := InternalStart
      else
        result := InternalStartAsync;
    finally
      // Once handed over, CompleteRun or AbortStart clears them, and after
      // that this object may already be freed (Destroy on another thread).
      if not handedOver then
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
  // detached process exited. What the handler raises goes to the caller; the
  // child is out of reach by now and stays running.
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

function TProcessBase.IsDetachedRun : boolean;
begin
  // A detached launch that was refused or failed leaves Status at Idle and
  // reads like any other failed Execute*.
  result := (FStartMode = TProcessStartMode.Detached) and (FStatus = TProcessStatus.Running);
end;

function TProcessBase.GetExitCode: Cardinal;
begin
  if IsDetachedRun then
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
  if IsDetachedRun then
    raise EInvalidOpException.Create('Cannot read TimedOut on a detached process');
  result := FTimedOut;
end;

function TProcessBase.InternalStart: boolean;
var
  keepAlive : IInterface;
  selfRef : IInterface;
begin
  result := false;
  // The run's own reference, as an asynchronous run's worker holds one: the
  // caller may release the last of theirs while the run is still using this
  // object (from OnExit, or from another thread), and the object must then
  // be freed here, on this thread, once the run has finished with it, never
  // in the middle of it or on a thread that has to wait for this one.
  // Released when this method returns, after everything else. Only taken
  // when the object is already reference counted: one used without an
  // interface reference would be freed by its release.
  if RefCount > 0 then
    selfRef := Self;
  FStartThreadId := CurrentThreadId;
  // The calling thread is the worker for a synchronous run.
  FWorkerThreadId := FStartThreadId;
  ResetTerminateRequest;
  FCompletionEvent.ResetEvent;
  // From here the completion event marks the run as in progress.
  ReleaseRunClaim;
  try
    StartPipeTargets;
    result := DoCreateProcess;
  finally
    if not result then
    begin
      // Taken before AbortStart publishes the end of the run; released when
      // this method returns.
      keepAlive := FDetachedOwnerRef;
      FDetachedOwnerRef := nil;
      AbortStart;
    end;
  end;
  if not result then
    exit;
  SetStatusAtomic(TProcessStatus.Running);
  try
    DoOnStarted;
  except
    // The caller gets what the handler raised, and no run may be left in
    // progress behind it: stop the child and complete the run first. What
    // OnExit raises now is logged, the first exception being the one to pass
    // on.
    FTerminateEvent.SetEvent;
    RunWorker(false);
    raise;
  end;
  RunWorker(true);
end;

function TProcessBase.InternalStartAsync: boolean;
var
  selfRef : IProcess;
  worker : TThread;
  keepAlive : IInterface;
begin
  result := false;
  FStartThreadId := CurrentThreadId;
  FWorkerThreadId := 0;
  ResetTerminateRequest;
  FCompletionEvent.ResetEvent;
  // From here the completion event marks the run as in progress.
  ReleaseRunClaim;
  try
    StartPipeTargets;
    result := DoCreateProcess;
  finally
    if not result then
    begin
      // Taken before AbortStart publishes the end of the run; released when
      // this method returns.
      keepAlive := FDetachedOwnerRef;
      FDetachedOwnerRef := nil;
      AbortStart;
    end;
  end;
  if not result then
    exit;
  SetStatusAtomic(TProcessStatus.Running);
  // The closure holds an IProcess reference so the worker keeps Self alive
  // even if the caller drops theirs while the child is still running.
  selfRef := Self;
  try
    // Fired on the calling thread before ExecuteAsync returns.
    DoOnStarted;
    worker := TThread.CreateAnonymousThread(
      procedure
      begin
        try
          // The worker thread has no caller for an OnExit handler to raise to.
          RunWorker(false);
        finally
          selfRef := nil;
        end;
      end);
  except
    // OnStarted raised, or there is no monitor thread. The caller gets the
    // exception, and no run may be left in progress behind it: stop the child
    // and complete the run on this thread. selfRef is kept until RunWorker
    // has returned, so an OnExit handler that drops the caller's last
    // reference cannot free this object under it.
    FTerminateEvent.SetEvent;
    FWorkerThreadId := CurrentThreadId;
    RunWorker(false);
    selfRef := nil;
    raise;
  end;
  FWorkerThreadId := worker.ThreadID;
  worker.Start;
end;

procedure TProcessBase.RunWorker(raiseToCaller : boolean);
var
  outcome : TProcessOutcome;
  keepAlive : IInterface;
begin
  // The caller (InternalStart, or the asynchronous worker) holds a reference
  // to this object until this method has returned, so OnExit can release
  // every other reference without this object being freed under it.
  outcome.Status := TProcessStatus.Terminated;
  outcome.ExitCode := FStartInfoBuilder.TerminateExitCode;
  outcome.TimedOut := false;
  try
    try
      try
        DoWaitForCompletion(outcome);
      except
        on E : Exception do
          LogError('Error while waiting for the process: ' + E.ClassName + ' - ' + E.Message);
      end;
    finally
      StopPipeTargets;
      // A reference a left-behind stdin writer handed back: taken before the
      // run is published (the next run may detach its own writer) and
      // released as the very last action, once nothing here touches this
      // object.
      keepAlive := FDetachedOwnerRef;
      FDetachedOwnerRef := nil;
      CompleteRun(outcome);
    end;
    DoOnExited(outcome.ExitCode, raiseToCaller);
  finally
    keepAlive := nil;
  end;
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
  // Last: from here Destroy on another thread may free an object used
  // without an interface reference.
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
          ReportQueuedHandlerException('OnStarted');
        end;
      end);
    Exit;
  end;
  handler(Self);
end;

procedure TProcessBase.LogHandlerException(const eventName : string);
begin
  LogError(eventName + ' handler raised: ' + CurrentExceptionText);
end;

procedure TProcessBase.ReportQueuedHandlerException(const eventName : string);
begin
  // On the main thread, where a VCL / FMX application installs its handler.
  // Later RTL versions do the same in CheckSynchronize, but drop the
  // exception when there is no handler; earlier ones raise it from there.
  if Assigned(ApplicationHandleException) then
    ApplicationHandleException(Self)
  else
    LogHandlerException(eventName);
end;

procedure TProcessBase.DoOnExited(exitCode : Cardinal; raiseToCaller : boolean);
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
          ReportQueuedHandlerException('OnExit');
        end;
      end);
    Exit;
  end;
  try
    handler(Self, exitCode);
  except
    if raiseToCaller then
      raise;
    LogHandlerException('OnExit');
  end;
end;

procedure TProcessBase.DeliverTo(const slots : TArray<TPipeTargetSlot>; isStdErr : boolean; const buffer : TBytes; count : NativeUInt);
var
  i : integer;
  streamAware : IStreamAwarePipeTarget;
  streamName : string;
begin
  if isStdErr then
    streamName := 'stderr'
  else
    streamName := 'stdout';
  for i := 0 to High(slots) do
  begin
    if FTargetFaulted[slots[i].StartedIndex] then
      continue;
    try
      // A target attached to both streams keeps each stream's partial line
      // apart when it is told which one this is.
      if Supports(slots[i].Target, IStreamAwarePipeTarget, streamAware) then
        streamAware.HandleStreamData(isStdErr, buffer, count)
      else
        slots[i].Target.HandleData(buffer, count);
    except
      on E : Exception do
      begin
        FTargetFaulted[slots[i].StartedIndex] := true;
        LogError(streamName + ' pipe target raised ' + E.ClassName + ' - ' + E.Message + ' (it receives no more data this run)');
      end;
      else
      begin
        FTargetFaulted[slots[i].StartedIndex] := true;
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
    DeliverTo(FRunStdErr, True, buffer, count);
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
    DeliverTo(FRunStdOut, False, buffer, count);
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
    startedIndex : integer;
  begin
    for i := 0 to High(slots) do
    begin
      // A target attached to both streams is started (and later Done) once.
      startedIndex := FStartedTargets.IndexOf(slots[i].Target);
      if startedIndex < 0 then
      begin
        slots[i].Target.Start;
        startedIndex := FStartedTargets.Add(slots[i].Target);
      end;
      slots[i].StartedIndex := startedIndex;
    end;
  end;

begin
  FStartedTargets.Clear;
  FRunStdOut := SnapshotTargets(FStdOutTargets);
  FRunStdErr := SnapshotTargets(FStdErrTargets);
  // Emptied first so that every flag starts out False.
  SetLength(FTargetFaulted, 0);
  SetLength(FTargetFaulted, Length(FRunStdOut) + Length(FRunStdErr));
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
      else
        LogError('Pipe target Done raised a non-Exception object');
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
      else
        LogError('Stdin pipe source Done raised a non-Exception object');
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
  workerId : TThreadID;
begin
  // Never wait on ourselves: from the thread that runs the worker (sync
  // Execute, or an event handler on the async worker), from a pipe target or
  // stdin source callback, or from the thread inside ExecuteAsync before the
  // async worker exists (OnStarted). Any other thread can wait, also while
  // ExecuteAsync is still starting the run.
  // The id fields are read without a lock: a thread can only ever find its
  // own id in them if it stored it there itself, and the ids are never 0.
  currentId := CurrentThreadId;
  workerId := FWorkerThreadId;
  if workerId = 0 then
    workerId := FStartThreadId;
  result := (currentId <> workerId) and
            (currentId <> FDeliveringThreadId) and
            (currentId <> FStdInWriterThreadId);
end;

function TProcessBase.WaitForCompletion(waitMS : Cardinal) : boolean;
const
  cSliceMS = 10;
var
  clock : TStopwatch;
  elapsed : Int64;
  slice : Cardinal;
begin
  if CurrentThreadId <> MainThreadID then
    Exit(FCompletionEvent.WaitFor(waitMS) = wrSignaled);
  // The main thread has to keep servicing TThread.Synchronize while it
  // waits, as TThread.WaitFor does: the run can't complete while one of its
  // pipe targets is blocked in a Synchronize call.
  clock := TStopwatch.StartNew;
  repeat
    CheckSynchronize;
    slice := cSliceMS;
    if waitMS <> INFINITE then
    begin
      elapsed := clock.ElapsedMilliseconds;
      if elapsed >= waitMS then
        slice := 0
      else if waitMS - elapsed < cSliceMS then
        slice := Cardinal(waitMS - elapsed);
    end;
    result := FCompletionEvent.WaitFor(slice) = wrSignaled;
  until result or (slice = 0);
end;

procedure TProcessBase.ResetTerminateRequest;
begin
  FTerminateLock.Enter;
  try
    TInterlocked.Increment(FRunGeneration);
    FTerminateEvent.ResetEvent;
  finally
    FTerminateLock.Leave;
  end;
end;

function TProcessBase.RequestTerminate(generation : Integer) : boolean;
begin
  FTerminateLock.Enter;
  try
    result := FRunGeneration = generation;
    if result then
      FTerminateEvent.SetEvent;
  finally
    FTerminateLock.Leave;
  end;
end;

function TProcessBase.Terminate: boolean;
const
  cTerminateAckTimeoutMS = 5000;
begin
  result := Terminate(cTerminateAckTimeoutMS);
end;

function TProcessBase.Terminate(waitMS : Cardinal) : boolean;
var
  generation : Integer;
begin
  // Read before the check, so that it is never the number of a run started
  // after the one the check sees in progress.
  generation := FRunGeneration;
  if (FStartMode = TProcessStartMode.Detached) or IsReadyForRun then
    Exit(false);
  // False: that run has completed since and another one has started, which
  // this call was not aimed at.
  if not RequestTerminate(generation) then
    Exit(false);
  // 0 only requests: the thread running the run kills and waits.
  if (waitMS = 0) or (not CanWaitForCompletion) then
    Exit(true);
  result := WaitForCompletion(waitMS);
end;

function TProcessBase.ValidateStartUpBuilder: boolean;
var
  password : string;
  hasPassword : boolean;
begin
  // The builder hands out a copy of the password: wipe it once looked at.
  password := FCredBuilder.Password;
  hasPassword := password <> '';
  ScrubString(password);
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
  {$IFDEF MSWINDOWS}
  // Only run credential validation when the caller actually configured
  // credentials - an unconfigured CredentialsBuilder is the default case
  // and must remain a no-op.
  if (FCredBuilder.UserName <> '') or
     (FCredBuilder.Domain <> '') or
     hasPassword then
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
     hasPassword then
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

// In the three Clear methods result is assigned first: a target being
// released may hold the last other reference to this object (a delegate that
// captured the IProcess).
function TProcessBase.ClearStdOutPipes : IProcess;
begin
  result := Self;
  FStdOutTargets.Clear;
end;

function TProcessBase.ClearStdErrPipes : IProcess;
begin
  result := Self;
  FStdErrTargets.Clear;
end;

function TProcessBase.ClearPipes : IProcess;
begin
  result := Self;
  FStdOutTargets.Clear;
  FStdErrTargets.Clear;
  FStdInSource := nil;
end;

function TProcessBase.WithStdOutPipe(const pipeTarget: IPipeTarget): IProcess;
begin
  if pipeTarget = nil then
    raise EArgumentNilException.Create('pipeTarget');
  FStdOutTargets.Add(pipeTarget);
  result := Self;
end;

end.
