{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright  Vincent Parrett and contributors                    }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

//Windows implementation.

unit VSoft.Process.Windows;

interface

uses
  WinApi.Windows,
  System.SyncObjs,
  System.Classes,
  System.SysUtils,
  VSoft.Process,
  VSoft.Process.Base,
  VSoft.Process.WinAPI;

type
  TWindowsProcess = class;

  PIOInfo = ^TIOInfo;
  // One redirected output stream. The threadpool IO callback reads into
  // Buffer and hands the data to Owner. The worker thread owns IO / Handle /
  // DoneEvent and is the only code that closes them.
  TIOInfo = record
    IO : PTP_IO;
    Overlapped : OVERLAPPED;
    Buffer : TBytes;
    BufferLen : DWORD;
    Handle : THandle;
    Owner : TWindowsProcess;
    IsStdErr : boolean;
    // Set by the callback (as its very last action) once no read is pending
    // and none will be queued again: EOF, an error, or Closing.
    DoneEvent : THandle;
    // Serialises Closing against the callback re-queueing a read.
    Lock : TRTLCriticalSection;
    Closing : boolean;
    // After a normal exit: bytes that were in the pipe when the child exited
    // and have not been read yet. Only reads queued after RecordUnreadOutput
    // (CountReads) pay them off; ReadCounted belongs to the read in flight.
    Unread : Int64;
    CountReads : boolean;
    ReadCounted : boolean;
  end;

  TWindowsProcess = class(TProcessBase, IProcess)
  private
    FProcessInfo : TProcessInformation;
    FJobHandle : THandle;
    // KillOnRelease when the last child could not be put in a job (Windows 7
    // nested jobs, Run-As children): a handle to the child, which keeps its
    // process id from being reused, and that id. CloseJobObject kills the
    // child's tree where closing the job would have killed the job.
    FReleaseKillProcess : THandle;
    FReleaseKillProcessId : Cardinal;

    //STDIO
    FStdOutIO : TIOInfo;
    FStdErrIO : TIOInfo;
    FStdInWriteHandle : THandle;
    FStdInWriteThread : THandle;
    FStdInWriter : IStdInWriter;

    function BuildCommandLine : string;
    // The Windows message for a launch failure, with the program in place
    // of its %1 placeholder. Never the arguments: they can hold secrets.
    function LaunchErrorText(error : DWORD) : string;
    function GetEnvironmentBlock : Pointer;
    procedure CreateOutputPipe(out readHandle : THandle; out writeHandle : THandle);
    procedure CreateInputPipe(out readHandle : THandle; out writeHandle : THandle);
    procedure InitIOInfo(info : PIOInfo; handle : THandle; isStdErr : boolean);
    procedure CloseIO(info : PIOInfo);
    procedure StopStdInWriter(waitMs : Cardinal);
    // abandoned: the child was left running (TerminateOnTimeout = False).
    procedure ReleaseRunResources(killed : boolean; abandoned : boolean);
    procedure RecordUnreadOutput(info : PIOInfo);
    function HasUnreadOutput : boolean;
    // True once every handle is signalled. False when drainMs elapses, or
    // (canStop) when Terminate / cancellation is requested, which sets stopped.
    function WaitForDrain(const handles : array of THandle; count : integer; drainMs : Cardinal; canStop : boolean; out stopped : boolean) : boolean;
    function KillChild(exitCode : Cardinal) : boolean;
    function ReadExitCode : Cardinal;
    function CreateJobObject: Boolean;
    procedure ConfigureJobObject;
    procedure CloseJobObject;
    procedure KeepForReleaseKill;
  protected
    procedure DeliverOutput(isStdErr : boolean; const buffer : TBytes; count : NativeUInt);
    // CreateProcessWithLogonW with Credentials. Virtual so a test can stand
    // in for the logon (it cannot log on to a real account).
    function LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                             const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL;virtual;

    // Sets resolved to the program to launch (see IStartInfoBuilder.Executable).
    function ResolveExecutable(out resolved : string) : boolean;
    function ValidateStartUpBuilder : boolean;override;
    function DoCreateProcess : boolean;override;
    procedure DoWaitForCompletion(var outcome : TProcessOutcome);override;
    function DoExecuteDetached : boolean;override;
    function GetProcessId : Cardinal; override;
    function Clone : IProcess;override;
  public
    constructor Create; override;
    destructor Destroy; override;
  end;

implementation

uses
  System.Diagnostics,
  VSoft.Process.Credentials,
  VSoft.Process.Utils;

//declaration in WinApi.Windows is incorrect and only in 10.2+
// PTP_IO, not PTPIO: 10.2 and 10.3 declare PTPIO = ^TTPIO, a type distinct
// from PTP_IO (10.4+ makes it an alias).
function CreateThreadpoolIo(fl: THandle; pfnio: TFNTPWin32IOCallback; pv: Pointer; pcbe: PTPCallbackEnviron): PTP_IO; stdcall;external kernel32 name 'CreateThreadpoolIo';

procedure CloseThreadpoolIo(pio: PTP_IO); stdcall;external kernel32 name 'CloseThreadpoolIo';

procedure StartThreadpoolIo(pio: PTP_IO); stdcall;external kernel32 name 'StartThreadpoolIo';

procedure CancelThreadpoolIo(pio: PTP_IO); stdcall;external kernel32 name 'CancelThreadpoolIo';

procedure WaitForThreadpoolIoCallbacks(pio: PTP_IO; fCancelPendingCallbacks: BOOL); stdcall;external kernel32 name 'WaitForThreadpoolIoCallbacks';

//not declared in WinApi
function CreateProcessWithLogonW(lpUserName : LPCWSTR; lpDomain : LPCWSTR; lpPassword: LPCWSTR; dwLogonFlags: DWORD;
                                 lpApplicationName : LPCWSTR; lpCommandLine: LPCWSTR; dwCreationFlags: DWORD;
                                 lpEnvironment: Pointer; lpCurrentDirectory: LPCWSTR;
                                 const lpStartupInfo: TStartupInfoW;
                                 var lpProcessInformation: TProcessInformation): BOOL; stdcall; external advapi32 name 'CreateProcessWithLogonW';

// Job Object API declarations
function CreateJobObjectW(lpJobAttributes: PSecurityAttributes; lpName: LPCWSTR): THandle; stdcall; external kernel32 name 'CreateJobObjectW';
function AssignProcessToJobObject(hJob: THandle; hProcess: THandle): BOOL; stdcall; external kernel32 name 'AssignProcessToJobObject';
function TerminateJobObject(hJob: THandle; uExitCode: UINT): BOOL; stdcall; external kernel32 name 'TerminateJobObject';
function SetInformationJobObject(hJob: THandle; JobObjectInfoClass: Integer; lpJobObjectInfo: Pointer; cbJobObjectInfoLength: DWORD): BOOL; stdcall; external kernel32 name 'SetInformationJobObject';
function QueryInformationJobObject(hJob: THandle; JobObjectInfoClass: Integer; lpJobObjectInfo: Pointer; cbJobObjectInfoLength: DWORD;
                                   lpReturnLength: PDWORD): BOOL; stdcall; external kernel32 name 'QueryInformationJobObject';
function IsProcessInJob(processHandle: THandle; jobHandle: THandle; out result: BOOL): BOOL; stdcall; external kernel32 name 'IsProcessInJob';

const
  JobObjectExtendedLimitInformation = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $2000;
  JOB_OBJECT_LIMIT_BREAKAWAY_OK = $800;

  LOGON_WITH_PROFILE = $00000001;
  LOGON_NETCREDENTIALS_ONLY = $00000002;

  // CreateProcessWithLogonW rejects longer command lines.
  cMaxLogonCommandLine = 1024;

type
  // Job object extended limit information structure
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION = record
    BasicLimitInformation: record
      PerProcessUserTimeLimit: Int64;
      PerJobUserTimeLimit: Int64;
      LimitFlags: DWORD;
      MinimumWorkingSetSize: NativeUInt;
      MaximumWorkingSetSize: NativeUInt;
      ActiveProcessLimit: DWORD;
      Affinity: NativeUInt;
      PriorityClass: DWORD;
      SchedulingClass: DWORD;
    end;
    IoInfo: record
      ReadOperationCount: Int64;
      WriteOperationCount: Int64;
      OtherOperationCount: Int64;
      ReadTransferCount: Int64;
      WriteTransferCount: Int64;
      OtherTransferCount: Int64;
    end;
    ProcessMemoryLimit: NativeUInt;
    JobMemoryLimit: NativeUInt;
    PeakProcessMemoryUsed: NativeUInt;
    PeakJobMemoryUsed: NativeUInt;
  end;

const
  // Default named-pipe buffer / threadpool read buffer. Overridable per
  // process via StartInfo.PipeBufferSize (0 = use this default).
  cBufferLen = 1024 * 64;
  // How long to wait for reads / the stdin writer to come back once they
  // have been cancelled.
  cCancelWaitMS = 1000;
  // Transient read failures (too many outstanding I/Os system-wide) are
  // retried this many times, 5ms apart.
  cMaxReadRetries = 20;

var
  // Held from "make the child's pipe ends inheritable" until they are
  // closed after CreateProcess, so a spawn on another thread can never
  // inherit them (which would keep our pipes open until that unrelated
  // child exits).
  GSpawnLock : TCriticalSection;

// Returns the configured pipe buffer size or cBufferLen when 0.
function ResolvePipeBufferSize(const startInfo : IStartInfoBuilder) : Cardinal;
begin
  result := startInfo.PipeBufferSize;
  if result = 0 then
    result := cBufferLen;
end;

function PriorityClass(priority : TProcessPriority) : DWORD;
begin
  case priority of
    TProcessPriority.AboveNormal : result := ABOVE_NORMAL_PRIORITY_CLASS;
    TProcessPriority.BelowNormal : result := BELOW_NORMAL_PRIORITY_CLASS;
    TProcessPriority.Idle : result := IDLE_PRIORITY_CLASS;
  else
    result := NORMAL_PRIORITY_CLASS;
  end;
end;

procedure SafeCloseHandle(var handle: THandle);
var
  old: THandle;
begin
  // Atomically swap the handle to 0 so we only ever close it once, even when
  // two threads race (writer thread + worker both close FStdInWriteHandle).
  // Closing a recycled handle value would close an unrelated kernel object.
  // Type-cast expressions are rvalues in XE2 and cannot be passed as `var`
  // parameters; dereference a typed pointer to expose `handle`'s storage as
  // the right-sized lvalue for TInterlocked.Exchange.
  {$IFDEF CPU64BITS}
  old := THandle(TInterlocked.Exchange(PInt64(@handle)^, Int64(0)));
  {$ELSE}
  old := THandle(TInterlocked.Exchange(PInteger(@handle)^, 0));
  {$ENDIF}
  if (old <> 0) and (old <> INVALID_HANDLE_VALUE) then
    CloseHandle(old);
end;

// Starts the next overlapped read. Returns False when no read is pending
// (EOF, error or the stream is being closed) - the caller then signals
// DoneEvent.
function QueueAsyncPipeRead(info : PIOInfo) : boolean;
var
  error : DWORD;
  attempt : integer;
  retry : boolean;
begin
  attempt := 0;
  repeat
    EnterCriticalSection(info.Lock);
    try
      if info.Closing then
        Exit(false);
      FillChar(info.Overlapped, SizeOf(info.Overlapped), 0);
      info.ReadCounted := info.CountReads;
      StartThreadpoolIo(info.IO);
      // Completes synchronously or pending - either way the completion is
      // delivered to IoCompletionCallback.
      if VProcReadFile(info.Handle, @info.Buffer[0], info.BufferLen, nil, @info.Overlapped) then
        Exit(true);
      error := GetLastError;
      if error = ERROR_IO_PENDING then
        Exit(true);
      CancelThreadpoolIo(info.IO);
      retry := ((error = ERROR_NOT_ENOUGH_MEMORY) or (error = ERROR_INVALID_USER_BUFFER) or (error = ERROR_NOT_ENOUGH_QUOTA)) and
               (attempt < cMaxReadRetries);
    finally
      LeaveCriticalSection(info.Lock);
    end;
    // Outside the lock, so CloseIO is not held up by the back-off.
    if retry then
    begin
      Inc(attempt);
      Sleep(5);
    end;
  until not retry;
  if (error <> ERROR_BROKEN_PIPE) and (error <> ERROR_HANDLE_EOF) and (error <> ERROR_OPERATION_ABORTED) then
    info.Owner.LogError('Pipe read failed: ' + SysErrorMessage(error));
  result := false;
end;

//called when the overlapped read completes
procedure IoCompletionCallback(instance : PTP_CALLBACK_INSTANCE; context : Pointer; overlapped : Pointer; ioResult : ULONG; numBytesRead : ULONG_PTR; io : PTP_IO);stdcall;
var
  info : PIOInfo;
  readMore : boolean;
  streamName : string;
begin
  info := PIOInfo(context);
  readMore := false;
  try
    if numBytesRead > 0 then
    begin
      EnterCriticalSection(info.Lock);
      if info.ReadCounted then
        Dec(info.Unread, Int64(numBytesRead));
      LeaveCriticalSection(info.Lock);
      info.Owner.DeliverOutput(info.IsStdErr, info.Buffer, numBytesRead);
    end;
    if ioResult = NO_ERROR then
      readMore := QueueAsyncPipeRead(info)
    else if (ioResult <> ERROR_BROKEN_PIPE) and (ioResult <> ERROR_HANDLE_EOF) and (ioResult <> ERROR_OPERATION_ABORTED) then
      info.Owner.LogError('Pipe read failed: ' + SysErrorMessage(ioResult));
  except
    // Target exceptions are already isolated by DeliverOutput; anything else
    // stops this stream rather than taking down a threadpool thread, and is
    // logged so the lost output is explained.
    on E : Exception do
    begin
      readMore := false;
      if info.IsStdErr then
        streamName := 'stderr'
      else
        streamName := 'stdout';
      try
        info.Owner.LogError(streamName + ' reading stopped: ' + E.ClassName + ' - ' + E.Message);
      except
        // Logging itself failed (out of memory): the stream still stops.
        on Exception do
          readMore := false;
      end;
    end;
    else
      readMore := false;
  end;
  if not readMore then
    SetEvent(info.DoneEvent);
end;

type
  TWindowsStdInWriter = class(TStdInWriter)
  private
    FHandle : THandle;
  protected
    procedure WriteAll;override;
  public
    constructor Create(owner : TProcessBase; const source : IPipeSource; handle : THandle);
    destructor Destroy;override;
  end;

constructor TWindowsStdInWriter.Create(owner : TProcessBase; const source : IPipeSource; handle : THandle);
begin
  inherited Create(owner, source);
  FHandle := handle;
end;

destructor TWindowsStdInWriter.Destroy;
begin
  // Only still open when the thread never ran.
  SafeCloseHandle(FHandle);
  inherited;
end;

procedure TWindowsStdInWriter.WriteAll;
var
  data: TBytes;
  dataLen: NativeUInt;
  hasMore: Boolean;
  written: DWORD;
  offset: NativeUInt;
  interactiveSrc: IInteractivePipeSource;
begin
  try
    if not Supports(Source, IInteractivePipeSource, interactiveSrc) then
      interactiveSrc := nil;
    repeat
      dataLen := 0;
      if IsAborted then
        hasMore := False
      else
        hasMore := Source.GetData(data, dataLen);
      if dataLen > NativeUInt(Length(data)) then
        dataLen := Length(data);
      if dataLen > 0 then
      begin
        offset := 0;
        while offset < dataLen do
        begin
          // Fails once the child has closed stdin / exited, or when the
          // worker cancels a write blocked on a pipe nobody reads.
          if IsAborted or
             (not WriteFile(FHandle, data[offset], DWORD(dataLen - offset), written, nil)) then
          begin
            hasMore := False;
            Break;
          end;
          Inc(offset, written);
        end;
      end
      else if hasMore then
      begin
        // Nothing ready yet: wait for the producer instead of spinning.
        if interactiveSrc <> nil then
          interactiveSrc.WaitForData(1000)
        else
          Sleep(10);
      end;
    until not hasMore;
  finally
    interactiveSrc := nil;
    // EOF for the child.
    SafeCloseHandle(FHandle);
  end;
end;

// Thread procedure for writing stdin data. parameter carries the reference
// to the writer that was added for this thread; writer takes it over.
function WriteStdInThreadProc(parameter: Pointer): Integer;
var
  writer : IStdInWriter;
begin
  result := 0;
  Pointer(writer) := parameter;
  writer.Execute;
end;

// Builds a unique named-pipe name. Replaces the XE2-incompatible
// `TGUID.NewGuid.ToString.Substring.Replace` helper chain with the classic
// CreateGUID + GUIDToString + Copy + StringReplace forms.
function MakeUniquePipeName: string;
var
  guid: TGUID;
  guidStr: string;
begin
  CreateGUID(guid);
  guidStr := GUIDToString(guid); // e.g. '{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}'
  // Skip the leading '{' and take the 36 chars before the trailing '}'.
  result := '\\.\pipe\' + StringReplace(Copy(guidStr, 2, 36), '-', '', [rfReplaceAll]);
end;

function OpenNulDevice : THandle;
begin
  result := CreateFileW('NUL', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

// Renders one argument for a .bat / .cmd target. cmd.exe re-parses the
// command line, so any part containing cmd metacharacters is wrapped in
// quotes (quotes stop cmd interpreting & | < > ^ etc). Arguments containing
// characters that are unsafe even inside quotes were rejected at validation.
function RenderBatchArgument(const arg : IArgument) : string;
var
  name : string;
  value : string;
begin
  name := arg.Name;
  value := TStringUtils.StripQuotes(arg.Value);
  if not (TStringUtils.ContainsCmdMetaChars(name) or TStringUtils.ContainsCmdMetaChars(value)) then
    Exit(arg.ToString);
  if value = '' then
    Exit('"' + TStringUtils.StripQuotes(name) + '"');
  if TStringUtils.ContainsCmdMetaChars(name) then
    name := '"' + TStringUtils.StripQuotes(name) + '"';
  if name <> '' then
    result := name + arg.NameValueSeparator
  else
    result := '';
  result := result + '"' + value + '"';
end;

// True when this process is in a job that lets its children break away
// (JOB_OBJECT_LIMIT_BREAKAWAY_OK), so CREATE_BREAKAWAY_FROM_JOB will work.
function HostJobAllowsBreakaway : boolean;
var
  inJob : BOOL;
  info : JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
begin
  if (not IsProcessInJob(GetCurrentProcess, 0, inJob)) or (not inJob) then
    Exit(false);
  ZeroMemory(@info, SizeOf(info));
  // A nil job handle queries the job of the calling process.
  result := QueryInformationJobObject(0, JobObjectExtendedLimitInformation, @info, SizeOf(info), nil) and
            ((info.BasicLimitInformation.LimitFlags and JOB_OBJECT_LIMIT_BREAKAWAY_OK) <> 0);
end;

{ TWindowsProcess }

function TWindowsProcess.Clone: IProcess;
begin
  result := TWindowsProcess.CreateClone(self);
end;

constructor TWindowsProcess.Create;
begin
  inherited;
  FillChar(FProcessInfo, SizeOf(TProcessInformation), 0);
  FJobHandle := 0;
  InitializeCriticalSection(FStdOutIO.Lock);
  InitializeCriticalSection(FStdErrIO.Lock);
end;

destructor TWindowsProcess.Destroy;
begin
  // inherited Destroy waits for any active run to complete, so nothing is
  // touching the IO records or the job any more. With JobMode KillOnRelease
  // closing the job kills anything the last run left behind
  // (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE).
  inherited;
  CloseJobObject;
  DeleteCriticalSection(FStdOutIO.Lock);
  DeleteCriticalSection(FStdErrIO.Lock);
end;

procedure TWindowsProcess.DeliverOutput(isStdErr : boolean; const buffer : TBytes; count : NativeUInt);
begin
  if isStdErr then
    ProcessStdErr(buffer, count)
  else
    ProcessStdOut(buffer, count);
end;

procedure TWindowsProcess.CreateOutputPipe(out readHandle, writeHandle: THandle);
var
  pipeName : string;
  error : Cardinal;
  bufSize : Cardinal;
begin
  // Anonymous pipes don't support overlapped I/O, so a uniquely named pipe
  // is used. FIRST_PIPE_INSTANCE fails if the name already exists (no
  // squatting) and remote clients are refused. Both ends are created
  // non-inheritable; the child's end is made inheritable only under
  // GSpawnLock.
  pipeName := MakeUniquePipeName;
  bufSize := ResolvePipeBufferSize(StartInfo);
  readHandle := CreateNamedPipe(PChar(pipeName),
                                PIPE_ACCESS_INBOUND or FILE_FLAG_OVERLAPPED or VPROC_FILE_FLAG_FIRST_PIPE_INSTANCE,
                                PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or VPROC_PIPE_REJECT_REMOTE_CLIENTS,
                                1, bufSize, bufSize, 0, nil);
  if (readHandle = INVALID_HANDLE_VALUE) then
  begin
    error := Winapi.Windows.GetLastError;
    readHandle := 0;
    writeHandle := 0;
    raise EOSError.Create('Failed to create named pipe ' + pipeName + ': ' + SysErrorMessage(error));
  end;

  //this is the end the child writes to.
  writeHandle := CreateFileW(PChar(pipeName), GENERIC_WRITE, 0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if (writeHandle = INVALID_HANDLE_VALUE) then
  begin
    error := Winapi.Windows.GetLastError;
    writeHandle := 0;
    SafeCloseHandle(readHandle);
    raise EOSError.Create('Failed to open write handle to pipe: ' + SysErrorMessage(error));
  end;
end;

procedure TWindowsProcess.CreateInputPipe(out readHandle, writeHandle: THandle);
begin
  // The parent writes synchronously from the writer thread, so a plain
  // anonymous pipe is used and the child gets an ordinary synchronous handle.
  if not CreatePipe(readHandle, writeHandle, nil, ResolvePipeBufferSize(StartInfo)) then
  begin
    readHandle := 0;
    writeHandle := 0;
    RaiseLastOSError;
  end;
end;

procedure TWindowsProcess.InitIOInfo(info: PIOInfo; handle: THandle; isStdErr : boolean);
var
  error : Cardinal;
  bufSize : Cardinal;
begin
  info.Handle := handle;
  info.Owner := Self;
  info.IsStdErr := isStdErr;
  info.Closing := false;
  info.Unread := 0;
  info.CountReads := false;
  info.ReadCounted := false;
  info.IO := nil;
  bufSize := ResolvePipeBufferSize(StartInfo);
  SetLength(info.Buffer, bufSize);
  info.BufferLen := bufSize;
  FillChar(info.Overlapped, SizeOf(info.Overlapped), 0);
  info.DoneEvent := CreateEvent(nil, True, False, nil);
  if info.DoneEvent = 0 then
    RaiseLastOSError;
  info.IO := CreateThreadpoolIo(handle, @IoCompletionCallback, info, nil);
  if info.IO = nil then
  begin
    error := Winapi.Windows.GetLastError();
    SafeCloseHandle(info.DoneEvent);
    raise EOSError.Create('CreateThreadpoolIo failed: ' + SysErrorMessage(error));
  end;
end;

procedure TWindowsProcess.CloseIO(info : PIOInfo);
begin
  if info.IO <> nil then
  begin
    // No new read may start from here on; cancel the one in flight (if a
    // descendant still holds the pipe open it would otherwise never end).
    EnterCriticalSection(info.Lock);
    info.Closing := true;
    LeaveCriticalSection(info.Lock);
    VProcCancelIoEx(info.Handle, nil);
    WaitForThreadpoolIoCallbacks(info.IO, False);
    CloseThreadpoolIo(info.IO);
    info.IO := nil;
  end;
  SafeCloseHandle(info.Handle);
  SafeCloseHandle(info.DoneEvent);
  info.Owner := nil;
end;

procedure TWindowsProcess.StopStdInWriter(waitMs : Cardinal);
var
  clock : TStopwatch;
  finished : boolean;
begin
  if FStdInWriteThread = 0 then
    Exit;
  finished := WaitForSingleObject(FStdInWriteThread, waitMs) <> WAIT_TIMEOUT;
  if not finished then
  begin
    FStdInWriter.Abort;
    // A WriteFile blocked on a pipe that a descendant holds (and never reads)
    // only returns when cancelled. Repeat in case the writer was between
    // calls when the first cancel was issued.
    clock := TStopwatch.StartNew;
    repeat
      VProcCancelSynchronousIo(FStdInWriteThread);
      finished := WaitForSingleObject(FStdInWriteThread, 100) <> WAIT_TIMEOUT;
    until finished or (clock.ElapsedMilliseconds >= cCancelWaitMS);
  end;
  if finished then
  begin
    if FStdInWriter.Error <> '' then
      LogError(FStdInWriter.Error);
  end
  else
  begin
    // Blocked in the source's GetData, which can't be cancelled. The writer
    // holds everything it uses and finishes whenever GetData returns; it is
    // detached so it no longer keeps this process (and its job) alive.
    FDetachedOwnerRef := FStdInWriter.Detach;
    LogError('The stdin pipe source did not return from GetData within ' + IntToStr(cCancelWaitMS) +
             'ms of being stopped; its writer thread was left to finish on its own');
  end;
  CloseHandle(FStdInWriteThread);
  FStdInWriteThread := 0;
  FStdInWriterThreadId := 0;
  FStdInWriter := nil;
end;

function TWindowsProcess.BuildCommandLine : string;
var
  i : integer;
  tail : string;
begin
  // argv[0] is a quoted copy of the executable path (Windows paths cannot
  // contain quotes). lpApplicationName is passed separately so CreateProcess
  // never applies its search-with-truncation parsing to the path.
  result := '"' + FResolvedExecutable + '"';
  if TStringUtils.IsBatchFile(FResolvedExecutable) then
  begin
    if CommandLine.Count > 0 then
    begin
      tail := '';
      for i := 0 to CommandLine.Count - 1 do
      begin
        if i > 0 then
          tail := tail + CommandLine.DefaultArgumentSeparator;
        tail := tail + RenderBatchArgument(CommandLine.Arguments[i]);
      end;
      result := result + ' ' + tail;
    end;
    // CreateProcess runs a batch file as `cmd.exe /c <command line>`, and
    // cmd strips the first and last quote of a /c command that contains
    // more than one quoted part. One extra pair makes that strip harmless.
    result := '"' + result + '"';
  end
  else if CommandLine.Count > 0 then
    result := result + ' ' + CommandLine.ToString;
  UniqueString(result); //CreateProcess can modify this value.
end;

function TWindowsProcess.LaunchErrorText(error : DWORD) : string;
begin
  result := StringReplace(SysErrorMessage(error), '%1', FResolvedExecutable, [rfReplaceAll]);
end;

function TWindowsProcess.GetEnvironmentBlock : Pointer;
begin
  // Only build a custom block when the caller has changed the environment;
  // otherwise pass nil and let the child inherit ours.
  if Environment.HasOverrides then
    result := Environment.ToEnvironmentBlock
  else
    result := nil;
end;

function TWindowsProcess.LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                                         const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL;
var
  userName : string;
  domain : string;
  password : string;
  logonFlags : DWORD;
  error : DWORD;
begin
  userName := Credentials.UserName;
  domain := Credentials.Domain;
  // A nil domain requires a UPN (user@domain); '.' is the local account database.
  if (domain = '') and (Pos('@', userName) = 0) then
    domain := '.';
  logonFlags := 0;
  if Credentials.LoadUserProfile then
    logonFlags := logonFlags or LOGON_WITH_PROFILE;
  if Credentials.NetCredentialsOnly then
    logonFlags := logonFlags or LOGON_NETCREDENTIALS_ONLY;
  // A copy of our own (the builder hands one out), wiped as soon as the
  // logon has used it; the Windows error is kept across the wipe.
  password := Credentials.Password;
  try
    if domain = '' then
      result := CreateProcessWithLogonW(PChar(userName), nil, PChar(password), logonFlags, PChar(FResolvedExecutable), PChar(command),
                                        creationFlags, pEnvironment, pWorkingDir, startupInfo, processInfo)
    else
      result := CreateProcessWithLogonW(PChar(userName), PChar(domain), PChar(password), logonFlags, PChar(FResolvedExecutable), PChar(command),
                                        creationFlags, pEnvironment, pWorkingDir, startupInfo, processInfo);
    error := GetLastError;
  finally
    ScrubString(password);
  end;
  SetLastError(error);
end;

function IsBareProgramName(const exe : string) : boolean;
begin
  result := (Pos('\', exe) = 0) and (Pos('/', exe) = 0) and (Pos(':', exe) = 0);
end;

function IsAbsoluteFolder(const dir : string) : boolean;
begin
  result := ((Length(dir) >= 3) and (dir[2] = ':') and ((dir[3] = '\') or (dir[3] = '/'))) or
            (Copy(dir, 1, 2) = '\\');
end;

function TWindowsProcess.ResolveExecutable(out resolved : string) : boolean;
var
  exe : string;
  pathValue : string;
  sepPos : integer;
  dir : string;
  candidate : string;
begin
  resolved := '';
  exe := StartInfo.Executable;
  if exe = '' then
    Exit(false);
  if not IsBareProgramName(exe) then
  begin
    resolved := ExpandFileName(exe);
    Exit(FileExists(resolved));
  end;

  // Unlike CreateProcess: only this process's PATH is searched (not the
  // current directory, this program's folder or the system folders by
  // themselves), and only .exe is tried for a name without an extension.
  // The PATH given to the child in Environment is never used for the lookup,
  // so the child can be given a constrained PATH (or none).
  if ExtractFileExt(exe) = '' then
    exe := exe + '.exe';
  pathValue := GetEnvironmentVariable('PATH');
  while pathValue <> '' do
  begin
    sepPos := Pos(';', pathValue);
    if sepPos = 0 then
      sepPos := Length(pathValue) + 1;
    dir := Trim(StringReplace(Copy(pathValue, 1, sepPos - 1), '"', '', [rfReplaceAll]));
    Delete(pathValue, 1, sepPos);
    // Relative entries (".", "bin") would search the current directory.
    if not IsAbsoluteFolder(dir) then
      Continue;
    candidate := IncludeTrailingPathDelimiter(dir) + exe;
    if FileExists(candidate) then
    begin
      // Windows ignores trailing dots and spaces in a name ('run.cmd.' opens
      // run.cmd). GetFullPathName removes them as CreateProcess will, so the
      // file is judged (batch file or not) by the name it is opened by.
      resolved := ExpandFileName(candidate);
      Exit(true);
    end;
  end;
  result := false;
end;

function TWindowsProcess.ValidateStartUpBuilder : boolean;
var
  i : integer;
  arg : IArgument;
begin
  result := inherited ValidateStartUpBuilder;
  if (StartInfo.Executable <> '') and (not ResolveExecutable(FResolvedExecutable)) then
  begin
    if IsBareProgramName(StartInfo.Executable) then
      LogError('Executable "' + StartInfo.Executable + '" was not found on the PATH')
    else
      LogError('Executable does not exist: ' + StartInfo.Executable);
    FResolvedExecutable := '';
    result := false;
  end;
  if TStringUtils.IsBatchFile(FResolvedExecutable) then
  begin
    // The path is part of the command line cmd.exe parses, and %VAR% (and
    // !VAR! with delayed expansion) is expanded even inside quotes.
    if TStringUtils.ContainsCmdUnsafeChars(FResolvedExecutable) then
    begin
      LogError('The batch file path cannot be passed safely to cmd.exe: it contains % or ! (' + FResolvedExecutable + ')');
      result := false;
    end;
    for i := 0 to CommandLine.Count - 1 do
    begin
      arg := CommandLine.Arguments[i];
      if TStringUtils.ContainsCmdUnsafeChars(TStringUtils.StripQuotes(arg.Name)) or
         TStringUtils.ContainsCmdUnsafeChars(TStringUtils.StripQuotes(arg.Value)) or
         TStringUtils.ContainsCmdUnsafeChars(arg.NameValueSeparator) then
      begin
        LogError('Argument ' + IntToStr(i + 1) + ' cannot be passed safely to a batch file (cmd.exe): it contains one of % ! " CR LF');
        result := false;
      end;
    end;
  end;
  if (Credentials.UserName <> '') and (Length(BuildCommandLine) > cMaxLogonCommandLine) then
  begin
    LogError('The command line is too long to run with credentials (CreateProcessWithLogonW allows ' + IntToStr(cMaxLogonCommandLine) + ' characters)');
    result := false;
  end;
end;

function TWindowsProcess.DoCreateProcess: boolean;
var
  redirectOut : boolean;
  redirectErr : boolean;
  redirectIn : boolean;
  anyRedirect : boolean;
  outRead : THandle;
  errRead : THandle;
  childOut : THandle;
  childErr : THandle;
  childIn : THandle;
  nulHandle : THandle;
  inheritList : array[0..3] of THandle;
  inheritCount : integer;
  startupInfoEx : TVProcStartupInfoExW;
  attrList : Pointer;
  attrSize : NativeUInt;
  command : string;
  workingDir : string;
  pWorkingDir : PChar;
  pEnvironment : Pointer;
  creationFlags : DWORD;
  success : BOOL;
  error : DWORD;
  created : boolean;
  threadId : TThreadID;
  writer : IStdInWriter;
  pipeEnd : THandle;

  procedure AddInheritable(handle : THandle);
  var
    i : integer;
  begin
    for i := 0 to inheritCount - 1 do
      if inheritList[i] = handle then
        Exit;
    // A std handle the child cannot inherit would be invalid in the child.
    if not SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) then
      RaiseLastOSError;
    inheritList[inheritCount] := handle;
    Inc(inheritCount);
  end;

  function ChildHandle(handle : THandle) : THandle;
  begin
    if handle <> 0 then
      result := handle
    else
      result := nulHandle;
  end;

begin
  result := false;
  created := false;
  outRead := 0;
  errRead := 0;
  childOut := 0;
  childErr := 0;
  childIn := 0;
  nulHandle := 0;
  attrList := nil;
  error := 0;
  FStdInWriteHandle := 0;
  FStdInWriteThread := 0;
  FStdInWriter := nil;
  ZeroMemory(@FProcessInfo, SizeOf(FProcessInfo));
  // With KillOnRelease anything the previous run left in its job goes now.
  CloseJobObject;

  redirectOut := ShouldRedirectStdOut;
  redirectErr := ShouldRedirectStdErr;
  redirectIn  := ShouldRedirectStdIn;
  anyRedirect := redirectOut or redirectErr or redirectIn;

  try
    if redirectOut then
      CreateOutputPipe(outRead, childOut);
    if redirectErr then
      CreateOutputPipe(errRead, childErr);
    if redirectIn then
      CreateInputPipe(childIn, FStdInWriteHandle);
    // Streams that are not redirected get NUL rather than an invalid handle
    // (INVALID_HANDLE_VALUE is the current-process pseudo handle).
    if anyRedirect and not (redirectOut and redirectErr and redirectIn) then
      nulHandle := OpenNulDevice;

    ZeroMemory(@startupInfoEx, SizeOf(startupInfoEx));
    startupInfoEx.StartupInfo.cb := SizeOf(TStartupInfoW);
    startupInfoEx.StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
    if StartInfo.HideWindow then
      startupInfoEx.StartupInfo.wShowWindow := SW_HIDE
    else
      startupInfoEx.StartupInfo.wShowWindow := SW_SHOWNORMAL;
    if anyRedirect then
    begin
      startupInfoEx.StartupInfo.dwFlags := startupInfoEx.StartupInfo.dwFlags or STARTF_USESTDHANDLES;
      startupInfoEx.StartupInfo.hStdInput := ChildHandle(childIn);
      startupInfoEx.StartupInfo.hStdOutput := ChildHandle(childOut);
      startupInfoEx.StartupInfo.hStdError := ChildHandle(childErr);
    end;

    command := BuildCommandLine;
    workingDir := StartInfo.WorkingDirectory;
    // CreateProcess rejects an empty (but non-nil) lpCurrentDirectory.
    if workingDir <> '' then
      pWorkingDir := PChar(workingDir)
    else
      pWorkingDir := nil;
    pEnvironment := GetEnvironmentBlock;
    // Suspended so the job is assigned before the child can create children.
    creationFlags := CREATE_NEW_CONSOLE or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED or PriorityClass(StartInfo.Priority);
    // Before Windows 8 a process already in a job cannot be put in a second
    // one, so our job would fail; leave the host's job when it allows that.
    // Only KillOnRelease needs a job of its own to kill the child; KillOnTerminate
    // keeps dying with the host's job as before.
    // Not for CreateProcessWithLogonW, which rejects the flag.
    if (StartInfo.JobMode = TProcessJobMode.KillOnRelease) and (Credentials.UserName = '') and (not TOSVersion.Check(6, 2)) and
       HostJobAllowsBreakaway then
      creationFlags := creationFlags or VPROCESS_CREATE_BREAKAWAY_FROM_JOB;

    if Credentials.UserName <> '' then
    begin
      // The Secondary Logon service is not the child's real parent: it
      // duplicates the three STARTUPINFO handles from this process into the
      // child, and the child inherits nothing else from us. So the child's
      // ends stay non-inheritable and GSpawnLock is not taken: a logon (a
      // user profile to load) can take seconds, and every other launch in
      // this process would wait for it.
      try
        success := LaunchWithLogon(command, creationFlags, pEnvironment, pWorkingDir, startupInfoEx.StartupInfo, FProcessInfo);
        if not success then
          error := Winapi.Windows.GetLastError;
      finally
        SafeCloseHandle(childOut);
        SafeCloseHandle(childErr);
        SafeCloseHandle(childIn);
        SafeCloseHandle(nulHandle);
      end;
    end
    else
    begin
      GSpawnLock.Enter;
      try
        inheritCount := 0;
        if anyRedirect then
        begin
          AddInheritable(startupInfoEx.StartupInfo.hStdInput);
          AddInheritable(startupInfoEx.StartupInfo.hStdOutput);
          AddInheritable(startupInfoEx.StartupInfo.hStdError);
        end;

        if inheritCount > 0 then
        begin
          // Inherit exactly the child's three std handles and nothing else.
          attrSize := 0;
          VProcInitializeProcThreadAttributeList(nil, 1, 0, attrSize);
          GetMem(attrList, attrSize);
          if not VProcInitializeProcThreadAttributeList(attrList, 1, 0, attrSize) then
          begin
            // Read before FreeMem, which may change it.
            error := Winapi.Windows.GetLastError;
            FreeMem(attrList);
            attrList := nil;
            RaiseLastOSError(error);
          end;
          if not VProcUpdateProcThreadAttribute(attrList, 0, VPROC_PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @inheritList[0],
                                                NativeUInt(inheritCount) * SizeOf(THandle), nil, nil) then
            RaiseLastOSError;
          startupInfoEx.StartupInfo.cb := SizeOf(TVProcStartupInfoExW);
          startupInfoEx.lpAttributeList := attrList;
          success := VProcCreateProcessW(PChar(FResolvedExecutable), PChar(command), nil, nil, True,
                                         creationFlags or VPROC_EXTENDED_STARTUPINFO_PRESENT, pEnvironment, pWorkingDir,
                                         @startupInfoEx, FProcessInfo);
        end
        else
          success := VProcCreateProcessW(PChar(FResolvedExecutable), PChar(command), nil, nil, False,
                                         creationFlags, pEnvironment, pWorkingDir, @startupInfoEx, FProcessInfo);
        if not success then
          error := Winapi.Windows.GetLastError;
      finally
        // The child has its own copies now. Closing ours inside the lock means
        // no other spawn can ever see them inheritable.
        SafeCloseHandle(childOut);
        SafeCloseHandle(childErr);
        SafeCloseHandle(childIn);
        SafeCloseHandle(nulHandle);
        if attrList <> nil then
        begin
          VProcDeleteProcThreadAttributeList(attrList);
          FreeMem(attrList);
        end;
        GSpawnLock.Leave;
      end;
    end;

    if not success then
    begin
      FLastError := error;
      LogError(LaunchErrorText(error));
      Exit;
    end;
    created := true;

    // Create and configure job object for process tree management. If the
    // child can't be assigned (Win7 nested jobs, Run-As children) the job is
    // dropped so termination falls back to the process tree, and so does
    // KillOnRelease.
    if (StartInfo.JobMode <> TProcessJobMode.NoJob) and CreateJobObject then
    begin
      ConfigureJobObject;
      if not AssignProcessToJobObject(FJobHandle, FProcessInfo.hProcess) then
      begin
        error := Winapi.Windows.GetLastError;
        CloseJobObject;
        if StartInfo.JobMode = TProcessJobMode.KillOnRelease then
        begin
          KeepForReleaseKill;
          LogError('Failed to assign process to job object (' + SysErrorMessage(error) + '); terminate will use the process tree ' +
                   'instead, and KillOnRelease will kill the process tree when the IProcess is released or run again');
        end
        else
          LogError('Failed to assign process to job object (' + SysErrorMessage(error) + '); terminate will use the process tree instead');
      end;
    end
    else if StartInfo.JobMode = TProcessJobMode.KillOnRelease then
      // No job at all: the fallback still kills the tree at release.
      KeepForReleaseKill;

    if StartInfo.ProcessorAffinity <> 0 then
    begin
      if not SetProcessAffinityMask(FProcessInfo.hProcess, StartInfo.ProcessorAffinity) then
        LogError('Failed to set processor affinity: ' + SysErrorMessage(Winapi.Windows.GetLastError));
    end;

    // Each read end is handed over (and our copy zeroed) before InitIOInfo
    // runs: InitIOInfo stores it in the IO info first, so if it then fails
    // the handle is closed once, by CloseIO, not again as outRead / errRead.
    // Its first read is queued at once, so from then on the done event is
    // set or a read is pending.
    if redirectOut then
    begin
      pipeEnd := outRead;
      outRead := 0;
      InitIOInfo(@FStdOutIO, pipeEnd, false);
      if not QueueAsyncPipeRead(@FStdOutIO) then
        SetEvent(FStdOutIO.DoneEvent);
    end;
    if redirectErr then
    begin
      pipeEnd := errRead;
      errRead := 0;
      InitIOInfo(@FStdErrIO, pipeEnd, true);
      if not QueueAsyncPipeRead(@FStdErrIO) then
        SetEvent(FStdErrIO.DoneEvent);
    end;
    if redirectIn then
    begin
      writer := TWindowsStdInWriter.Create(Self, FRunStdIn, FStdInWriteHandle);
      FStdInWriteHandle := 0;
      // The thread's own reference, taken over by WriteStdInThreadProc.
      writer._AddRef;
      FStdInWriteThread := BeginThread(nil, 0, @WriteStdInThreadProc, Pointer(writer), CREATE_SUSPENDED, threadId);
      if FStdInWriteThread = 0 then
      begin
        error := Winapi.Windows.GetLastError;
        writer._Release;
        RaiseLastOSError(error);
      end;
      // Known before the thread runs, so Terminate called from inside the
      // stdin source never waits on itself.
      writer.SetThreadId(threadId);
      FStdInWriterThreadId := threadId;
      FStdInWriter := writer;
      if ResumeThread(FStdInWriteThread) = $FFFFFFFF then
      begin
        error := Winapi.Windows.GetLastError;
        // The thread never ran, so it never took over its reference and
        // nothing waits on it: end it and drop the reference here.
        TerminateThread(FStdInWriteThread, 0);
        WaitForSingleObject(FStdInWriteThread, cCancelWaitMS);
        CloseHandle(FStdInWriteThread);
        FStdInWriteThread := 0;
        FStdInWriterThreadId := 0;
        FStdInWriter := nil;
        writer._Release;
        RaiseLastOSError(error);
      end;
    end;

    if ResumeThread(FProcessInfo.hThread) = $FFFFFFFF then
      RaiseLastOSError;
    SafeCloseHandle(FProcessInfo.hThread);
    result := true;
  finally
    if not result then
    begin
      if created then
      begin
        TerminateProcess(FProcessInfo.hProcess, StartInfo.TerminateExitCode);
        WaitForSingleObject(FProcessInfo.hProcess, cCancelWaitMS);
      end;
      CloseIO(@FStdOutIO);
      CloseIO(@FStdErrIO);
      StopStdInWriter(cCancelWaitMS);
      SafeCloseHandle(FStdInWriteHandle);
      SafeCloseHandle(outRead);
      SafeCloseHandle(errRead);
      SafeCloseHandle(FProcessInfo.hThread);
      SafeCloseHandle(FProcessInfo.hProcess);
      CloseJobObject;
    end;
  end;
end;

function TWindowsProcess.ReadExitCode : Cardinal;
var
  error : DWORD;
begin
  // The Windows error code is not reported as the exit code: a caller could
  // not tell the two apart.
  if not GetExitCodeProcess(FProcessInfo.hProcess, result) then
  begin
    error := Winapi.Windows.GetLastError;
    FLastError := error;
    LogError('Could not read the exit code (' + SysErrorMessage(error) + '); reporting TerminateExitCode ' +
             IntToStr(StartInfo.TerminateExitCode) + ' instead');
    result := StartInfo.TerminateExitCode;
  end;
end;

function TWindowsProcess.KillChild(exitCode : Cardinal) : boolean;
begin
  // Exited on its own between the wait returning and now: nothing to kill
  // (and its real exit code should be reported).
  if WaitForSingleObject(FProcessInfo.hProcess, 0) = WAIT_OBJECT_0 then
    Exit(false);
  result := true;
  if FJobHandle <> 0 then
    TerminateJobObject(FJobHandle, exitCode)
  else
    TSystemUtils.TerminateProcessTree(FProcessInfo.dwProcessId, exitCode, FProcessInfo.hProcess);
  // The child itself, whatever happened above.
  TerminateProcess(FProcessInfo.hProcess, exitCode);
  WaitForSingleObject(FProcessInfo.hProcess, 5000);
end;

procedure TWindowsProcess.ReleaseRunResources(killed : boolean; abandoned : boolean);
var
  waitHandles : array[0..1] of THandle;
  count : integer;
  drainMs : Cardinal;
  stopped : boolean;
  interactiveSrc : IInteractivePipeSource;
begin
  // The child is gone: an interactive source can't usefully take more input.
  if (FStdInWriteThread <> 0) and Supports(FRunStdIn, IInteractivePipeSource, interactiveSrc) then
    interactiveSrc.Close;
  interactiveSrc := nil;

  // Let the reads run to EOF, bounded by the drain timeout: a descendant that
  // inherited a pipe keeps it open after the child exits. The stdin writer
  // keeps going meanwhile and is stopped afterwards.
  count := 0;
  if FStdOutIO.IO <> nil then
  begin
    waitHandles[count] := FStdOutIO.DoneEvent;
    Inc(count);
  end;
  if FStdErrIO.IO <> nil then
  begin
    waitHandles[count] := FStdErrIO.DoneEvent;
    Inc(count);
  end;
  // A child left running keeps its pipes open: output already read has
  // been delivered, and nothing more is read.
  if (count > 0) and (not abandoned) then
  begin
    drainMs := GetDrainTimeout(killed);
    // After a normal exit, what the child wrote is delivered however slow
    // the targets are. After a kill the drain stays bounded.
    if not killed then
    begin
      RecordUnreadOutput(@FStdOutIO);
      RecordUnreadOutput(@FStdErrIO);
    end;
    // After a kill, Terminate / cancellation / the timeout already caused it
    // and the drain is bounded. After a normal exit they end the drain.
    if not WaitForDrain(waitHandles, count, drainMs, not killed, stopped) then
    begin
      if stopped then
      begin
        LogError('Output may be truncated: Terminate / cancellation was requested while stdout/stderr were still open after the process exited (probably held by a child process it started); the remaining I/O was cancelled');
        // Terminate kills the job: what the child started is still in it,
        // holding the pipes. Without a job the exited child's process id
        // can't safely be used to find its children.
        if FJobHandle <> 0 then
          TerminateJobObject(FJobHandle, StartInfo.TerminateExitCode);
      end
      else
        LogError('Output may be truncated: stdout/stderr were still open ' + IntToStr(drainMs) +
                 'ms after the process exited and the output it left in the pipes had been read (probably held by a child process it started); the remaining I/O was cancelled');
    end;
  end;

  // Cancels whatever is still pending, then waits for the callbacks. Closing
  // the read ends means a child left running gets a broken pipe if it
  // writes again. The stdin writer is stopped (cancelled if it is blocked in
  // a write), and left behind if its source never returns from GetData.
  CloseIO(@FStdOutIO);
  CloseIO(@FStdErrIO);
  StopStdInWriter(0);
  SafeCloseHandle(FStdInWriteHandle);
  SafeCloseHandle(FProcessInfo.hThread);
  SafeCloseHandle(FProcessInfo.hProcess);
end;

procedure TWindowsProcess.RecordUnreadOutput(info : PIOInfo);
var
  available : DWORD;
begin
  if info.IO = nil then
    Exit;
  // Under the lock no read can be queued, so the count and the reads that
  // pay it off line up. A read already in flight leaves nothing in the pipe.
  EnterCriticalSection(info.Lock);
  try
    if not PeekNamedPipe(info.Handle, nil, 0, nil, @available, nil) then
      available := 0;
    info.Unread := available;
    info.CountReads := true;
  finally
    LeaveCriticalSection(info.Lock);
  end;
end;

function TWindowsProcess.HasUnreadOutput : boolean;

  function StillOwed(info : PIOInfo) : boolean;
  begin
    // A stream that has finished (EOF, error) owes nothing more.
    if (info.IO = nil) or (WaitForSingleObject(info.DoneEvent, 0) = WAIT_OBJECT_0) then
      Exit(false);
    EnterCriticalSection(info.Lock);
    try
      result := info.Unread > 0;
    finally
      LeaveCriticalSection(info.Lock);
    end;
  end;

begin
  result := StillOwed(@FStdOutIO) or StillOwed(@FStdErrIO);
end;

// Waits for all the handles (EOF on the pipes, the stdin writer finished).
// The drainMs clock only starts once the output that was in the pipes when
// the child exited has been read; it then limits the wait for output that a
// descendant holding the pipes may still write. False on timeout.
function TWindowsProcess.WaitForDrain(const handles : array of THandle; count : integer; drainMs : Cardinal; canStop : boolean; out stopped : boolean) : boolean;
const
  cSliceMs = 50;
var
  clock : TStopwatch;
  deadline : Int64;
  waitMs : Int64;
begin
  // Waits in slices: the deadline only starts once the child's own output
  // has been delivered, and a stop request must be noticed.
  stopped := false;
  clock := TStopwatch.StartNew;
  deadline := -1;
  while true do
  begin
    if (deadline < 0) and (drainMs <> INFINITE) and (not HasUnreadOutput) then
      deadline := clock.ElapsedMilliseconds + drainMs;
    waitMs := cSliceMs;
    if (deadline >= 0) and (deadline - clock.ElapsedMilliseconds < waitMs) then
      waitMs := deadline - clock.ElapsedMilliseconds;
    if waitMs < 0 then
      waitMs := 0;
    if WaitForMultipleObjects(count, @handles[0], True, DWORD(waitMs)) <> WAIT_TIMEOUT then
      Exit(true);
    if canStop and IsStopRequested then
    begin
      stopped := true;
      Exit(false);
    end;
    if (deadline >= 0) and (clock.ElapsedMilliseconds >= deadline) then
      Exit(false);
  end;
end;

procedure TWindowsProcess.DoWaitForCompletion(var outcome : TProcessOutcome);
const
  // Wait sources: process handle, FTerminateEvent, optional FCancellationEvent,
  // optional FCancellationToken.
  cMaxWaitHandles = 4;
var
  timeOutDuration: Cardinal;
  waitRes: Cardinal;
  objHandles: array [0..cMaxWaitHandles - 1] of THandle;
  handleCount: integer;
  killed : boolean;
  abandoned : boolean;
  resolved : boolean;
  error : DWORD;
begin
  killed := false;
  abandoned := false;
  resolved := false;
  try
    if StartInfo.TimeoutInMSec <> 0 then
      timeOutDuration := StartInfo.TimeoutInMSec
    else
      timeOutDuration := INFINITE;

    handleCount := 0;
    objHandles[handleCount] := FProcessInfo.hProcess;
    Inc(handleCount);
    objHandles[handleCount] := FTerminateEvent.Handle;
    Inc(handleCount);
    if FCancellationEvent <> nil then
    begin
      objHandles[handleCount] := FCancellationEvent.Handle;
      Inc(handleCount);
    end;
    if FCancellationToken <> nil then
    begin
      objHandles[handleCount] := FCancellationToken.Handle;
      Inc(handleCount);
    end;

    waitRes := WaitForMultipleObjects(handleCount, @objHandles, False, timeOutDuration);
    case waitRes of
      WAIT_OBJECT_0: // Process has exited
        begin
          outcome.Status := TProcessStatus.Exited;
          outcome.ExitCode := ReadExitCode;
        end;
      WAIT_OBJECT_0 + 1 .. WAIT_OBJECT_0 + 3: // terminate / cancellation
        begin
          killed := KillChild(StartInfo.TerminateExitCode);
          if killed then
          begin
            outcome.Status := TProcessStatus.Terminated;
            outcome.ExitCode := StartInfo.TerminateExitCode;
          end
          else
          begin
            outcome.Status := TProcessStatus.Exited;
            outcome.ExitCode := ReadExitCode;
          end;
        end;
      WAIT_TIMEOUT:
        begin
          outcome.TimedOut := true;
          if StartInfo.TerminateOnTimeout then
            killed := KillChild(StartInfo.TimedOutExitCode)
          else
            abandoned := WaitForSingleObject(FProcessInfo.hProcess, 0) <> WAIT_OBJECT_0;
          if killed or abandoned then
          begin
            outcome.Status := TProcessStatus.TimedOut;
            outcome.ExitCode := StartInfo.TimedOutExitCode;
          end
          else
          begin
            // Exited on its own right at the timeout boundary - still
            // flagged TimedOut, but Status reflects reality.
            outcome.Status := TProcessStatus.Exited;
            outcome.ExitCode := ReadExitCode;
          end;
        end;
    else // WAIT_FAILED etc - we can no longer monitor the child, so stop it.
      begin
        // Read before IntToStr, which allocates and may change it.
        error := Winapi.Windows.GetLastError;
        LogError('Unexpected wait result ' + IntToStr(waitRes) + ': ' + SysErrorMessage(error));
        killed := KillChild(StartInfo.TerminateExitCode);
        outcome.Status := TProcessStatus.Terminated;
        outcome.ExitCode := StartInfo.TerminateExitCode;
      end;
    end;
    resolved := true;
  finally
    if not resolved then
      killed := KillChild(StartInfo.TerminateExitCode);
    ReleaseRunResources(killed, abandoned);
  end;
end;

function TWindowsProcess.DoExecuteDetached: boolean;
var
  startupInfo: TStartupInfoW;
  processInfo: TProcessInformation;
  creationFlags: DWORD;
  pEnvironment: Pointer;
  command: string;
  workingDir: string;
  pWorkingDir: PChar;
  error : DWORD;
begin
  ZeroMemory(@processInfo, SizeOf(processInfo));
  ZeroMemory(@startupInfo, SizeOf(startupInfo));
  ZeroMemory(@FProcessInfo, SizeOf(FProcessInfo));
  startupInfo.cb := SizeOf(startupInfo);
  startupInfo.dwFlags := STARTF_USESHOWWINDOW;
  if StartInfo.HideWindow then
    startupInfo.wShowWindow := SW_HIDE
  else
    startupInfo.wShowWindow := SW_SHOWNORMAL;

  command := BuildCommandLine;
  workingDir := StartInfo.WorkingDirectory;
  if workingDir <> '' then
    pWorkingDir := PChar(workingDir)
  else
    pWorkingDir := nil;
  pEnvironment := GetEnvironmentBlock;

  if Credentials.UserName <> '' then
  begin
    // CreateProcessWithLogonW does not accept DETACHED_PROCESS or
    // CREATE_BREAKAWAY_FROM_JOB; its children are not in our job anyway.
    creationFlags := CREATE_NEW_CONSOLE or CREATE_NEW_PROCESS_GROUP or CREATE_UNICODE_ENVIRONMENT or PriorityClass(StartInfo.Priority);
    result := LaunchWithLogon(command, creationFlags, pEnvironment, pWorkingDir, startupInfo, processInfo);
  end
  else
  begin
    // DETACHED_PROCESS: no inherited console.
    // CREATE_NEW_PROCESS_GROUP: child won't see our Ctrl+C / Ctrl+Break.
    // CREATE_BREAKAWAY_FROM_JOB: survive the host's job (CI runners). It
    //   makes CreateProcess fail with ERROR_ACCESS_DENIED when the host's
    //   job does not allow breakaway, so retry inside the job in that case.
    creationFlags := DETACHED_PROCESS or CREATE_NEW_PROCESS_GROUP or CREATE_UNICODE_ENVIRONMENT or PriorityClass(StartInfo.Priority);
    result := CreateProcessW(PChar(FResolvedExecutable), PChar(command), nil, nil, FALSE,
                             creationFlags or VPROCESS_CREATE_BREAKAWAY_FROM_JOB,
                             pEnvironment, pWorkingDir, startupInfo, processInfo);
    if (not result) and (Winapi.Windows.GetLastError = ERROR_ACCESS_DENIED) then
    begin
      UniqueString(command);
      result := CreateProcessW(PChar(FResolvedExecutable), PChar(command), nil, nil, FALSE, creationFlags,
                               pEnvironment, pWorkingDir, startupInfo, processInfo);
    end;
  end;

  if result then
  begin
    // Apply processor affinity before we lose our last process handle.
    if StartInfo.ProcessorAffinity <> 0 then
    begin
      if not SetProcessAffinityMask(processInfo.hProcess, StartInfo.ProcessorAffinity) then
        LogError('Failed to set processor affinity on detached child: ' + SysErrorMessage(Winapi.Windows.GetLastError));
    end;
    // Keep the process id for reference but drop the handles: we don't wait
    // for or control a detached process.
    FProcessInfo.dwProcessId := processInfo.dwProcessId;
    FProcessInfo.dwThreadId := processInfo.dwThreadId;
    CloseHandle(processInfo.hThread);
    CloseHandle(processInfo.hProcess);
  end
  else
  begin
    error := Winapi.Windows.GetLastError;
    FLastError := error;
    LogError(LaunchErrorText(error));
  end;
end;

function TWindowsProcess.GetProcessId : Cardinal;
begin
  result := FProcessInfo.dwProcessId;
end;

function TWindowsProcess.CreateJobObject: Boolean;
begin
  FJobHandle := CreateJobObjectW(nil, nil);
  if FJobHandle = 0 then
  begin
    LogError('Failed to create job object: ' + SysErrorMessage(Winapi.Windows.GetLastError));
    result := False;
  end
  else
    result := True;
end;

procedure TWindowsProcess.ConfigureJobObject;
var
  jobInfo: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
begin
  if FJobHandle = 0 then
    Exit;
  ZeroMemory(@jobInfo, SizeOf(jobInfo));
  // KILL_ON_JOB_CLOSE (KillOnRelease only): closing the job handle kills
  // everything in it. BREAKAWAY_OK: lets a child launch its own detached
  // processes.
  jobInfo.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_BREAKAWAY_OK;
  if StartInfo.JobMode = TProcessJobMode.KillOnRelease then
    jobInfo.BasicLimitInformation.LimitFlags := jobInfo.BasicLimitInformation.LimitFlags or JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if not SetInformationJobObject(FJobHandle, JobObjectExtendedLimitInformation, @jobInfo, SizeOf(jobInfo)) then
    LogError('Failed to configure job object: ' + SysErrorMessage(Winapi.Windows.GetLastError));
end;

procedure TWindowsProcess.CloseJobObject;
begin
  SafeCloseHandle(FJobHandle);
  if FReleaseKillProcess <> 0 then
  begin
    // KillOnRelease without a job: what the job would have killed is the
    // child's tree. The handle we hold keeps its id from being reused.
    TSystemUtils.TerminateProcessTree(FReleaseKillProcessId, StartInfo.TerminateExitCode, FReleaseKillProcess);
    SafeCloseHandle(FReleaseKillProcess);
    FReleaseKillProcessId := 0;
  end;
end;

procedure TWindowsProcess.KeepForReleaseKill;
begin
  if DuplicateHandle(GetCurrentProcess, FProcessInfo.hProcess, GetCurrentProcess, @FReleaseKillProcess, 0, False,
                     DUPLICATE_SAME_ACCESS) then
    FReleaseKillProcessId := FProcessInfo.dwProcessId
  else
  begin
    FReleaseKillProcess := 0;
    LogError('KillOnRelease cannot fall back to the process tree: ' + SysErrorMessage(Winapi.Windows.GetLastError));
  end;
end;

initialization
  // Library code (pipe targets, string decoding) runs on threadpool threads
  // and the stdin writer. The memory manager only locks when IsMultiThread
  // is set, which otherwise only happens when a TThread is created.
  IsMultiThread := True;
  GSpawnLock := TCriticalSection.Create;

finalization
  GSpawnLock.Free;

end.
