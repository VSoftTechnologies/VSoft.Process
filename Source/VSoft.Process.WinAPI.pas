unit VSoft.Process.WinAPI;

interface

{$IFDEF MSWINDOWS}

uses
  WinAPI.Windows;

//polyfills for api functions and types that are not in older versions of delphi.

{$IF CompilerVersion > 23.0}
  {$LEGACYIFEND ON}
{$IFEND}

{$IF CompilerVersion < 24.0}
const
  BELOW_NORMAL_PRIORITY_CLASS     = $00004000;
  {$EXTERNALSYM BELOW_NORMAL_PRIORITY_CLASS}
  ABOVE_NORMAL_PRIORITY_CLASS     = $00008000;
  {$EXTERNALSYM ABOVE_NORMAL_PRIORITY_CLASS}
{$IFEND}

// CREATE_BREAKAWAY_FROM_JOB is not declared in WinAPI.Windows on all
// supported Delphi versions. Define unconditionally as a local constant -
// the value is fixed by the Windows API. Used by ExecuteDetached so a
// detached grandchild survives the host's job (CI runners etc).
const
  VPROCESS_CREATE_BREAKAWAY_FROM_JOB = $01000000;
  {$EXTERNALSYM VPROCESS_CREATE_BREAKAWAY_FROM_JOB}

// Vista+ declarations missing from (some versions of) WinAPI.Windows. They
// are prefixed so they never clash with the RTL's own declarations in newer
// Delphi versions.
const
  VPROC_EXTENDED_STARTUPINFO_PRESENT = $00080000;
  VPROC_PROC_THREAD_ATTRIBUTE_HANDLE_LIST = $00020002;
  VPROC_PIPE_REJECT_REMOTE_CLIENTS = $00000008;
  VPROC_FILE_FLAG_FIRST_PIPE_INSTANCE = $00080000;
  VPROC_PROCESS_QUERY_LIMITED_INFORMATION = $1000;

type
  TVProcStartupInfoExW = record
    StartupInfo : TStartupInfoW;
    lpAttributeList : Pointer;
  end;

function VProcInitializeProcThreadAttributeList(lpAttributeList : Pointer; dwAttributeCount : DWORD; dwFlags : DWORD; var lpSize : NativeUInt) : BOOL; stdcall;
function VProcUpdateProcThreadAttribute(lpAttributeList : Pointer; dwFlags : DWORD; attribute : NativeUInt; lpValue : Pointer; cbSize : NativeUInt; lpPreviousValue : Pointer; lpReturnSize : Pointer) : BOOL; stdcall;
procedure VProcDeleteProcThreadAttributeList(lpAttributeList : Pointer); stdcall;
// CreateProcessW taking the startup info by pointer so a TVProcStartupInfoExW
// can be passed.
function VProcCreateProcessW(lpApplicationName : PWideChar; lpCommandLine : PWideChar;
                             lpProcessAttributes : PSecurityAttributes; lpThreadAttributes : PSecurityAttributes;
                             bInheritHandles : BOOL; dwCreationFlags : DWORD; lpEnvironment : Pointer;
                             lpCurrentDirectory : PWideChar; lpStartupInfo : Pointer;
                             var lpProcessInformation : TProcessInformation) : BOOL; stdcall;
function VProcCancelIoEx(hFile : THandle; lpOverlapped : POverlapped) : BOOL; stdcall;
function VProcCancelSynchronousIo(hThread : THandle) : BOOL; stdcall;
// ReadFile with a nullable bytes-read pointer (must be nil for overlapped I/O).
function VProcReadFile(hFile : THandle; lpBuffer : Pointer; nNumberOfBytesToRead : DWORD; lpNumberOfBytesRead : PDWORD; lpOverlapped : POverlapped) : BOOL; stdcall;
function VProcTerminateJobObject(hJob : THandle; uExitCode : UINT) : BOOL; stdcall;


{$IF CompilerVersion < 32.0} //10.2
type
  _TP_IO = record
  end;
  {$EXTERNALSYM _TP_IO}
  TP_IO = _TP_IO;
  {$EXTERNALSYM TP_IO}
  PTP_IO = ^_TP_IO;
  {$EXTERNALSYM PTP_IO}
  TTPIO = TP_IO;
  PTPIO = PTP_IO;


  TFNTPWin32IOCallback = TFarProc;
  TFNTPCleanupGroupCancelCallback = TFarProc;
  TFNPTPSimpleCallback = TFarProc;
  TFNTPTimerCallback = TFarProc;

  _TP_POOL = record
  end;
  {$EXTERNALSYM _TP_POOL}
  TP_POOL = _TP_POOL;
  {$EXTERNALSYM TP_POOL}
  TTPPool = _TP_POOL;
  PTPPool = ^TTPPool;

  _TP_CLEANUP_GROUP = record
  end;
  {$EXTERNALSYM _TP_CLEANUP_GROUP}
  TP_CLEANUP_GROUP = _TP_CLEANUP_GROUP;
  {$EXTERNALSYM TP_CLEANUP_GROUP}
  PTP_CLEANUP_GROUP = ^_TP_CLEANUP_GROUP;
  {$EXTERNALSYM PTP_CLEANUP_GROUP}
  TTPCleanupGroup = _TP_CLEANUP_GROUP;
  PTPCleanupGroup = ^TTPCleanupGroup;

  TP_VERSION = DWORD;
  {$EXTERNALSYM TP_VERSION}

  _TP_CALLBACK_PRIORITY = (
    TP_CALLBACK_PRIORITY_HIGH,
    TP_CALLBACK_PRIORITY_NORMAL,
    TP_CALLBACK_PRIORITY_LOW,
    TP_CALLBACK_PRIORITY_INVALID,
    TP_CALLBACK_PRIORITY_COUNT = TP_CALLBACK_PRIORITY_INVALID
  );
  {$EXTERNALSYM _TP_CALLBACK_PRIORITY}
  TP_CALLBACK_PRIORITY = _TP_CALLBACK_PRIORITY;
  {$EXTERNALSYM TP_CALLBACK_PRIORITY}
  TTPCallbackPriority = _TP_CALLBACK_PRIORITY;


  _TP_CALLBACK_ENVIRON_V3 = record
    Version: DWORD;
    Pool: PTPPool;
    CleanupGroup: PTPCleanupGroup;
    CleanupGroupCancelCallback: TFNTPCleanupGroupCancelCallback;
    RaceDll: Pointer;
    ActivationContext: Pointer;
    FinalizationCallback: TFNPTPSimpleCallback;
    Flags: DWORD;
    CallbackPriority: TTPCallbackPriority;
    Size: DWORD;
  end;
  {$EXTERNALSYM _TP_CALLBACK_ENVIRON_V3}
  TP_CALLBACK_ENVIRON_V3 = _TP_CALLBACK_ENVIRON_V3;
  {$EXTERNALSYM TP_CALLBACK_ENVIRON_V3}
  TP_CALLBACK_ENVIRON = TP_CALLBACK_ENVIRON_V3;
  {$EXTERNALSYM TP_CALLBACK_ENVIRON}
  PTP_CALLBACK_ENVIRON = ^TP_CALLBACK_ENVIRON_V3;
  {$EXTERNALSYM PTP_CALLBACK_ENVIRON}
  TTPCallbackEnviron = TP_CALLBACK_ENVIRON_V3;
  PTPCallbackEnviron = ^TTPCallbackEnviron;


  _TP_CALLBACK_INSTANCE = record
  end;
  {$EXTERNALSYM _TP_CALLBACK_INSTANCE}
  TP_CALLBACK_INSTANCE = _TP_CALLBACK_INSTANCE;
  {$EXTERNALSYM TP_CALLBACK_INSTANCE}
  PTP_CALLBACK_INSTANCE = ^_TP_CALLBACK_INSTANCE;
  {$EXTERNALSYM PTP_CALLBACK_INSTANCE}
  TTPCallbackInstance = _TP_CALLBACK_INSTANCE;
  PTPCallbackInstance = ^TTPCallbackInstance;



{$IFEND}

{$IF CompilerVersion < 33.0} //10.3

type
  _TP_TIMER = record
  end;
  {$EXTERNALSYM _TP_TIMER}
  TP_TIMER = _TP_TIMER;
  {$EXTERNALSYM TP_TIMER}
  PTP_TIMER = ^_TP_TIMER;
  {$EXTERNALSYM PTP_TIMER}
  TTPTimer = TP_TIMER;
  PTPTimer = PTP_TIMER;

{$IFEND}

{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
function VProcInitializeProcThreadAttributeList; external kernel32 name 'InitializeProcThreadAttributeList';
function VProcUpdateProcThreadAttribute; external kernel32 name 'UpdateProcThreadAttribute';
procedure VProcDeleteProcThreadAttributeList; external kernel32 name 'DeleteProcThreadAttributeList';
function VProcCreateProcessW; external kernel32 name 'CreateProcessW';
function VProcCancelIoEx; external kernel32 name 'CancelIoEx';
function VProcCancelSynchronousIo; external kernel32 name 'CancelSynchronousIo';
function VProcReadFile; external kernel32 name 'ReadFile';
function VProcTerminateJobObject; external kernel32 name 'TerminateJobObject';
{$ENDIF}

end.
