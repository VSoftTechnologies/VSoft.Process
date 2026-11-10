{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright © Vincent Parrett and contributors                    }
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

// Unified POSIX implementation for Linux (epoll) and macOS (kqueue)

unit VSoft.Process.Posix;

// The record layouts, constants and system call numbers below are those of
// the targets named here. Anything else must fail to compile rather than
// misbehave at run time.
{$IF NOT (DEFINED(LINUX) OR DEFINED(MACOS))}
  {$MESSAGE FATAL 'VSoft.Process.Posix supports Linux and macOS only'}
{$IFEND}
// MACOS is also defined by the iOS compilers; an iOS app may not fork.
{$IF DEFINED(IOS)}
  {$MESSAGE FATAL 'VSoft.Process.Posix does not support iOS'}
{$IFEND}
// struct epoll_event is packed only on x86-64, and the system call numbers
// are the x86-64 ones.
{$IF DEFINED(LINUX) AND NOT DEFINED(CPUX64)}
  {$MESSAGE FATAL 'VSoft.Process.Posix supports Linux on x86-64 only'}
{$IFEND}
// x86-64 and arm64 share the layouts used here (struct kevent, timespec).
{$IF DEFINED(MACOS) AND NOT DEFINED(CPU64BITS)}
  {$MESSAGE FATAL 'VSoft.Process.Posix supports 64-bit macOS only'}
{$IFEND}

interface

uses
  System.SyncObjs,
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  {$IF DEFINED(LINUX) OR DEFINED(MACOS)}
  Posix.Base,
  Posix.SysTypes,
  Posix.SysWait,
  Posix.Unistd,
  Posix.Signal,
  Posix.Fcntl,
  Posix.Errno,
  {$IFDEF LINUX}
  Posix.Dlfcn,
  {$ENDIF}
  {$IFEND}
  VSoft.Process,
  VSoft.Process.Base;

const
  INVALID_PID = -1;
  cBufferLen = 1024 * 64;  // 64KB buffer to match Windows
  cMaxEvents = 10;
  {$IFDEF LINUX}
  cFIONREAD = $541B;
  {$ELSE}
  cFIONREAD = $4004667F;  // _IOR('f', 127, int)
  {$ENDIF}

type
  {$IFDEF LINUX}
  // struct epoll_event is __attribute__((packed)) on x86-64: 12 bytes with
  // data at offset 4. A naturally aligned record would be 16 bytes and every
  // field after `events` would be read from the wrong offset.
  TPlatformEvent = packed record
    events: Cardinal;
    data: UInt64;
  end;
  {$ENDIF}

  {$IFDEF MACOS}
  // struct kevent (64-bit macOS, x64 and arm64): 32 bytes
  TPlatformEvent = record
    ident: UInt64;
    filter: Int16;
    flags: UInt16;
    fflags: UInt32;
    data: Int64;
    udata: Pointer;
  end;
  {$ENDIF}

  {$IFDEF LINUX}
  cpu_set_t = record
    __bits: array[0..15] of UInt64; // 1024 bits
  end;
  {$ENDIF}

  // Everything the child needs between fork() and execve(), built in the
  // parent beforehand: the child may only make async-signal-safe calls (no
  // memory manager, no RTL strings), as other threads may have held locks at
  // the moment of the fork.
  TChildSetup = record
    ExecPath : TBytes;
    Argv : TArray<PAnsiChar>;
    ShellArgv : TArray<PAnsiChar>;
    Envp : TArray<PAnsiChar>;
    HasEnv : boolean;
    // The parent's environ, captured before fork (Posix.Unistd.environ uses
    // dlsym on Linux, which is not async-signal-safe).
    InheritedEnv : PPAnsiChar;
    WorkingDir : TBytes;
    HasWorkingDir : boolean;
    DevNull : TBytes;
    EmptyMask : sigset_t;
    NiceValue : Integer;
    UseProcessGroup : boolean;
    // Last descriptor of the close loop that is used only when the open
    // descriptors cannot be listed.
    MaxFd : Integer;
    {$IFDEF LINUX}
    FdDir : TBytes;
    CpuSet : cpu_set_t;
    ApplyAffinity : boolean;
    {$ENDIF}
  end;

  // IProcess comes from TProcessBase. It is not listed again here: that would
  // give the object a second IProcess, and the reference TProcess.Create
  // returns would no longer equal the one handed to OnStarted / OnExit or
  // returned by the fluent methods.
  TPosixProcess = class(TProcessBase)
  private
    FProcessId: pid_t;
    FUseProcessGroup : boolean;
    FStdOutReadFd: Integer;
    FStdErrReadFd: Integer;
    FEventFd: Integer;
    FPidFd: Integer;
    // The child's exit wakes WaitForEvents (pidfd / EVFILT_PROC). When it
    // does not, the wait loop polls for the exit.
    FExitWatched : boolean;
    // macOS: NOTE_EXIT has been received.
    FExitNotified : boolean;
    FStdInWriter : IStdInWriter;
    FReadBuffer : TBytes;
    // After a normal exit: bytes that were in each pipe when the child was
    // reaped and have not been read yet (DrainFd pays them off).
    FStdOutUnread : Int64;
    FStdErrUnread : Int64;

    procedure StopStdInWriter;
    function ResolveExecutable(out resolved : string) : boolean;
    procedure PrepareChildSetup(var setup : TChildSetup; detached : boolean);
    procedure FreeChildSetup(var setup : TChildSetup);
    procedure CreatePipe(out readFd, writeFd: Integer);
    procedure CloseFd(var fd: Integer);
    function CreateEventInstance: Integer;
    procedure WatchFd(fd: Integer);
    procedure WatchChildExit;
    procedure UnwatchChildExit;
    procedure WaitForEvents(timeoutMs : Integer);
    procedure DrainFd(var fd : Integer; isStdErr : boolean);
    function HasUnreadOutput : boolean;
    function TryReap(var status : Integer; out unknownStatus : boolean; out stopSignal : Integer) : boolean;
    procedure SignalChild(sig : Integer);
    function GetPipeBufferSize: NativeUInt;
  protected
    function ValidateStartUpBuilder : boolean; override;
    function DoCreateProcess: boolean; override;
    procedure DoWaitForCompletion(var outcome : TProcessOutcome); override;
    function DoExecuteDetached: boolean; override;
    function GetProcessId: Cardinal; override;
    function Clone: IProcess; override;
  public
    constructor Create; override;
    destructor Destroy; override;
  end;

implementation

{$IF DEFINED(LINUX) OR DEFINED(MACOS)}

{$IFDEF LINUX}
// Guards the declaration (a dropped "packed" would give 16 bytes); that the
// target really is x86-64 is checked at the top of the unit.
{$IF SizeOf(TPlatformEvent) <> 12}
  {$MESSAGE FATAL 'TPlatformEvent must be the packed 12 byte struct epoll_event of x86-64'}
{$IFEND}

const
  EPOLL_CLOEXEC = $80000;
  EPOLLIN = 1;
  EPOLLERR = 8;
  EPOLLHUP = 16;
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  O_CLOEXEC = $80000;
  O_DIRECTORY = $10000;
  F_DUPFD_CLOEXEC = 1030;
  // x86-64 syscall numbers (see the guard at the top of the unit). Called
  // through syscall() so the binary still loads on older glibc versions.
  cSysGetDents64 = 217;
  cSysPidfdOpen = 434;
  cSysCloseRange = 436;
  CLOSE_RANGE_CLOEXEC = 4;
  cWaitExited = 4;          // WEXITED
  cWaitNoWait = $01000000;  // WNOWAIT

function epoll_create1(flags: Integer): Integer; cdecl; external libc name 'epoll_create1';
function epoll_ctl(epfd: Integer; op: Integer; fd: Integer; event: Pointer): Integer; cdecl; external libc name 'epoll_ctl';
function epoll_wait(epfd: Integer; events: Pointer; maxevents: Integer; timeout: Integer): Integer; cdecl; external libc name 'epoll_wait';
// pipe2() atomically creates a pipe with O_CLOEXEC on both ends, so a fork()
// on another thread can never inherit them.
function pipe2(fds: PInteger; flags: Integer): Integer; cdecl; external libc name 'pipe2';
function syscall(number: NativeInt): NativeInt; cdecl; varargs; external libc name 'syscall';
function sched_setaffinity(pid: pid_t; cpusetsize: NativeUInt; mask: Pointer): Integer; cdecl; external libc name 'sched_setaffinity';
{$ENDIF}

{$IFDEF MACOS}
{$IF SizeOf(TPlatformEvent) <> 32}
  {$MESSAGE FATAL 'TPlatformEvent must be the 32 byte struct kevent of 64-bit macOS'}
{$IFEND}

const
  EVFILT_READ = -1;
  EVFILT_PROC = -5;
  EV_ADD = $0001;
  EV_ENABLE = $0004;
  EV_ONESHOT = $0010;
  NOTE_EXIT = $80000000;
  F_DUPFD_CLOEXEC = 67;
  cWaitExited = 4;      // WEXITED
  cWaitNoWait = $20;    // WNOWAIT
  cProcPidListFds = 1;  // PROC_PIDLISTFDS

type
  TKTimeSpec = record
    tv_sec: Int64;
    tv_nsec: Int64;
  end;

  // struct proc_fdinfo (sys/proc_info.h)
  TProcFdInfo = record
    proc_fd : Integer;
    proc_fdtype : Cardinal;
  end;

function kqueue: Integer; cdecl; external libc name 'kqueue';
function kevent(kq: Integer; changelist: Pointer; nchanges: Integer; eventlist: Pointer; nevents: Integer; timeout: Pointer): Integer; cdecl; external libc name 'kevent';
// libproc.h. Both are plain system call wrappers: no allocation, no locks.
function proc_pidinfo(pid: Integer; flavor: Integer; arg: UInt64; buffer: Pointer; bufferSize: Integer): Integer; cdecl; external libc name 'proc_pidinfo';
function proc_listpgrppids(pgrpId: pid_t; buffer: Pointer; bufferSize: Integer): Integer; cdecl; external libc name 'proc_listpgrppids';
{$ENDIF}

const
  POLLOUT = $0004;
  PRIO_PROCESS = 0;
  cWaitIdPid = 1; // P_PID

type
  TPollFd = record
    fd : Integer;
    events : Int16;
    revents : Int16;
  end;

function execve(const path: PAnsiChar; const argv: PPAnsiChar; const envp: PPAnsiChar): Integer; cdecl; external libc name 'execve';
function setpriority(which: Integer; who: Integer; prio: Integer): Integer; cdecl; external libc name 'setpriority';
// varargs: Apple arm64 passes variadic arguments on the stack.
function ioctl(fd: Integer; request: NativeUInt): Integer; cdecl; varargs; external libc name 'ioctl';
{$IFDEF LINUX}
function poll(fds: Pointer; nfds: NativeUInt; timeout: Integer): Integer; cdecl; external libc name 'poll';
{$ELSE}
function poll(fds: Pointer; nfds: Cardinal; timeout: Integer): Integer; cdecl; external libc name 'poll';
{$ENDIF}
function waitid(idType: Integer; id: Cardinal; info: Pointer; options: Integer): Integer; cdecl; external libc name 'waitid';

// Concurrent launches need no lock. The parent's ends of every running
// child's pipes are open in the host for the whole run, so any later fork
// copies them whatever was locked while they were created. What keeps them
// (and every other descriptor of the host) out of the new program is the
// child itself: RunChild marks or closes everything from 3 up before execve.

// Child-process initialization failure reporting. The child writes one of
// these records into the error self-pipe before _exit() so the parent can
// distinguish dup2 / chdir / execve failures from a child that ran and
// returned 255 of its own accord. On successful execve the write end is
// auto-closed by FD_CLOEXEC, signalling success to the parent (read() == 0).
const
  cChildErrDup2Stdout = 1;
  cChildErrDup2Stderr = 2;
  cChildErrDup2Stdin  = 3;
  cChildErrChdir      = 4;
  cChildErrExec       = 5;

type
  TChildErrorReport = packed record
    Step: Byte;
    Padding: array[0..2] of Byte;
    ErrnoValue: Integer;
  end;

function ChildErrStepName(step: Byte): string;
begin
  case step of
    cChildErrDup2Stdout: result := 'dup2(stdout)';
    cChildErrDup2Stderr: result := 'dup2(stderr)';
    cChildErrDup2Stdin:  result := 'dup2(stdin)';
    cChildErrChdir:      result := 'chdir';
    cChildErrExec:       result := 'execve';
  else
    result := 'unknown step ' + IntToStr(step);
  end;
end;

procedure WriteChildErrorAndExit(errFd: Integer; step: Byte; savedErrno: Integer);
var
  report: TChildErrorReport;
begin
  FillChar(report, SizeOf(report), 0);
  report.Step := step;
  report.ErrnoValue := savedErrno;
  // Best effort. If write fails the parent simply sees exit 255 with no detail.
  if errFd <> -1 then
    __write(errFd, @report, SizeOf(report));
  _exit(255);
end;

{$IFDEF LINUX}
type
  // Reads a directory with getdents64 itself: opendir / readdir allocate, so
  // they cannot be used between fork and exec.
  TDirReader = record
    Fd : Integer;
    Count : NativeInt;
    Offset : NativeInt;
    Failed : boolean;
    Buffer : array[0..2047] of Byte;
  end;

// The next entry whose name is a decimal number (a pid in /proc, a
// descriptor in /proc/self/fd). False at the end of the directory, and with
// reader.Failed set when it could not be read. Async-signal-safe.
function NextNumericEntry(var reader : TDirReader; out value : Integer) : boolean;
var
  name : PByte;
  recordLength : Word;
  number : Int64;
begin
  value := 0;
  while true do
  begin
    if reader.Offset >= reader.Count then
    begin
      reader.Count := syscall(cSysGetDents64, NativeInt(reader.Fd), NativeInt(@reader.Buffer[0]), NativeInt(SizeOf(reader.Buffer)));
      reader.Offset := 0;
      if reader.Count <= 0 then
      begin
        reader.Failed := reader.Count < 0;
        Exit(false);
      end;
    end;
    // struct linux_dirent64: d_ino (8 bytes), d_off (8), d_reclen (2),
    // d_type (1), d_name.
    recordLength := PWord(@reader.Buffer[reader.Offset + 16])^;
    name := @reader.Buffer[reader.Offset + 19];
    if recordLength = 0 then
    begin
      reader.Failed := true;
      Exit(false);
    end;
    Inc(reader.Offset, recordLength);
    if (name^ < Ord('0')) or (name^ > Ord('9')) then
      continue;
    number := 0;
    while (name^ >= Ord('0')) and (name^ <= Ord('9')) and (number <= MaxInt) do
    begin
      number := number * 10 + (name^ - Ord('0'));
      Inc(name);
    end;
    if (name^ = 0) and (number <= MaxInt) then
    begin
      value := Integer(number);
      Exit(true);
    end;
  end;
end;
{$ENDIF}

// Child side, when close_range is not available: closes every descriptor
// from 3 up except keepFd by listing the ones that are open, so the cost
// does not depend on RLIMIT_NOFILE and no descriptor number is out of reach.
// False when they could not be listed. Async-signal-safe.
function CloseOpenFds(const setup : TChildSetup; keepFd : Integer) : boolean;
{$IFDEF LINUX}
var
  reader : TDirReader;
  fd : Integer;
begin
  reader.Fd := open(MarshaledAString(@setup.FdDir[0]), O_RDONLY or O_DIRECTORY or O_CLOEXEC);
  if reader.Fd < 0 then
    Exit(false);
  reader.Count := 0;
  reader.Offset := 0;
  reader.Failed := false;
  while NextNumericEntry(reader, fd) do
    if (fd >= 3) and (fd <> keepFd) and (fd <> reader.Fd) then
      __close(fd);
  __close(reader.Fd);
  result := not reader.Failed;
end;
{$ELSE}
var
  fds : array[0..255] of TProcFdInfo;
  byteCount : Integer;
  count : Integer;
  closed : Integer;
  i : Integer;
begin
  result := false;
  repeat
    byteCount := proc_pidinfo(getpid, cProcPidListFds, 0, @fds[0], SizeOf(fds));
    if byteCount <= 0 then
      Exit;
    count := byteCount div SizeOf(TProcFdInfo);
    closed := 0;
    for i := 0 to count - 1 do
      if (fds[i].proc_fd >= 3) and (fds[i].proc_fd <> keepFd) then
      begin
        __close(fds[i].proc_fd);
        Inc(closed);
      end;
    // A full buffer may not be the whole list (it is in ascending order):
    // list again until there is nothing left to close.
  until (count < Length(fds)) or (closed = 0);
  result := true;
end;
{$ENDIF}

// The child side of fork(). Async-signal-safe calls only; never returns.
procedure RunChild(const setup : TChildSetup; stdinFd, stdoutFd, stderrFd, errFd : Integer; detached : boolean);
var
  fd : Integer;
  failed : boolean;

  function SetStdHandle(source, target : Integer) : boolean;
  var
    nullFd : Integer;
  begin
    result := true;
    if source >= 0 then
      result := dup2(source, target) = target
    else if detached or (fcntl(target, F_GETFD) = -1) then
    begin
      // Detached children get /dev/null; attached children inherit our
      // stdio, unless it is closed - a closed 0..2 would be handed to the
      // next file the child opens.
      nullFd := open(MarshaledAString(@setup.DevNull[0]), O_RDWR);
      if (nullFd >= 0) and (nullFd <> target) then
      begin
        dup2(nullFd, target);
        __close(nullFd);
      end;
    end;
  end;

begin
  if setup.UseProcessGroup then
    setpgid(0, 0);

  // Signal dispositions set to SIG_IGN (the host ignores SIGPIPE) and the
  // signal mask survive execve; give the child the defaults.
  sigprocmask(SIG_SETMASK, @setup.EmptyMask, nil);
  signal(SIGPIPE, TSignalHandler(SIG_DFL));
  signal(SIGXFSZ, TSignalHandler(SIG_DFL));

  {$IFDEF LINUX}
  if setup.ApplyAffinity then
    sched_setaffinity(0, SizeOf(cpu_set_t), @setup.CpuSet);
  {$ENDIF}
  if setup.NiceValue <> 0 then
    setpriority(PRIO_PROCESS, 0, setup.NiceValue);

  if not SetStdHandle(stdinFd, STDIN_FILENO) then
    WriteChildErrorAndExit(errFd, cChildErrDup2Stdin, errno);
  if not SetStdHandle(stdoutFd, STDOUT_FILENO) then
    WriteChildErrorAndExit(errFd, cChildErrDup2Stdout, errno);
  if not SetStdHandle(stderrFd, STDERR_FILENO) then
    WriteChildErrorAndExit(errFd, cChildErrDup2Stderr, errno);

  // Nothing else of ours may leak into the child: the host's own fds are
  // frequently not CLOEXEC (TFileStream, sockets). errFd is CLOEXEC already
  // and must stay open until exec. This step is also what keeps the pipes of
  // other runs out of this child.
  {$IFDEF LINUX}
  failed := syscall(cSysCloseRange, NativeInt(3), NativeInt($FFFFFFFF), NativeInt(CLOSE_RANGE_CLOEXEC)) <> 0;
  {$ELSE}
  failed := true;
  {$ENDIF}
  // No close_range (macOS, Linux before 5.11, seccomp profiles): close the
  // descriptors that are open; only when they cannot be listed, every
  // number up to the limit.
  if failed and (not CloseOpenFds(setup, errFd)) then
    for fd := 3 to setup.MaxFd do
      if fd <> errFd then
        __close(fd);

  if setup.HasWorkingDir then
  begin
    if __chdir(MarshaledAString(@setup.WorkingDir[0])) <> 0 then
      WriteChildErrorAndExit(errFd, cChildErrChdir, errno);
  end;

  if setup.HasEnv then
    execve(PAnsiChar(@setup.ExecPath[0]), PPAnsiChar(@setup.Argv[0]), PPAnsiChar(@setup.Envp[0]))
  else
    execve(PAnsiChar(@setup.ExecPath[0]), PPAnsiChar(@setup.Argv[0]), setup.InheritedEnv);
  // A script without a #! line: run it with /bin/sh like execvp does.
  if errno = ENOEXEC then
  begin
    if setup.HasEnv then
      execve(setup.ShellArgv[0], PPAnsiChar(@setup.ShellArgv[0]), PPAnsiChar(@setup.Envp[0]))
    else
      execve(setup.ShellArgv[0], PPAnsiChar(@setup.ShellArgv[0]), setup.InheritedEnv);
  end;
  WriteChildErrorAndExit(errFd, cChildErrExec, errno);
end;

function Utf8Z(const s : string) : TBytes;
var
  raw : TBytes;
begin
  raw := TEncoding.UTF8.GetBytes(s);
  SetLength(result, Length(raw) + 1);
  if Length(raw) > 0 then
    Move(raw[0], result[0], Length(raw));
  result[High(result)] := 0;
end;

function AllocZ(const s : string) : PAnsiChar;
var
  bytes : TBytes;
begin
  bytes := Utf8Z(s);
  GetMem(result, Length(bytes));
  Move(bytes[0], result^, Length(bytes));
end;

procedure FreeZArray(var items : TArray<PAnsiChar>);
var
  i : integer;
begin
  for i := 0 to High(items) do
    if items[i] <> nil then
      FreeMem(items[i]);
  SetLength(items, 0);
end;

function ReadRetry(fd : Integer; buffer : Pointer; count : NativeUInt) : ssize_t;
begin
  repeat
    result := __read(fd, buffer, count);
  until (result >= 0) or (errno <> EINTR);
end;

function UnreadBytes(fd : Integer) : Int64;
var
  available : Integer;
begin
  result := 0;
  available := 0;
  if (fd <> -1) and (ioctl(fd, cFIONREAD, @available) = 0) then
    result := available;
end;

function WaitPidRetry(pid : pid_t; status : PInteger; options : Integer) : pid_t;
begin
  repeat
    result := waitpid(pid, status, options);
  until (result <> -1) or (errno <> EINTR);
end;

// True once the child has exited, without reaping it: as a zombie it keeps
// its pid, and with that the id of the process group it leads, from being
// given to anything else.
function HasExited(pid : pid_t) : boolean;
var
  // siginfo_t: 128 bytes on Linux, 104 on macOS.
  info : array[0..15] of UInt64;
  waitResult : Integer;
begin
  repeat
    FillChar(info, SizeOf(info), 0);
    waitResult := waitid(cWaitIdPid, Cardinal(pid), @info[0], cWaitExited or cWaitNoWait or WNOHANG);
  until (waitResult <> -1) or (errno <> EINTR);
  // Still running: 0 with si_signo and si_pid left at 0 (both are within the
  // first 24 bytes on either platform). ECHILD: reaped elsewhere, which
  // TryReap reports.
  if waitResult = 0 then
    result := (info[0] <> 0) or (info[1] <> 0) or (info[2] <> 0)
  else
    result := errno = ECHILD;
end;

// True when a process other than its leader is still running in the process
// group, or when that cannot be told.
function GroupHasOtherMembers(groupId : pid_t) : boolean;
{$IFDEF LINUX}
var
  reader : TDirReader;
  path : TBytes;
  stat : array[0..511] of Byte;
  pid : Integer;
  statFd : Integer;
  count : NativeInt;
  i : NativeInt;
  state : Byte;
  memberGroup : Int64;
begin
  result := true;
  path := Utf8Z('/proc');
  reader.Fd := open(MarshaledAString(@path[0]), O_RDONLY or O_DIRECTORY or O_CLOEXEC);
  if reader.Fd < 0 then
    Exit;
  try
    reader.Count := 0;
    reader.Offset := 0;
    reader.Failed := false;
    while NextNumericEntry(reader, pid) do
    begin
      if pid = groupId then
        continue;
      path := Utf8Z('/proc/' + IntToStr(pid) + '/stat');
      statFd := open(MarshaledAString(@path[0]), O_RDONLY or O_CLOEXEC);
      if statFd < 0 then
        continue; // gone since it was listed
      count := ReadRetry(statFd, @stat[0], SizeOf(stat));
      __close(statFd);
      // "pid (comm) state ppid pgrp ...": comm may hold spaces and brackets,
      // so start from the last ')'.
      i := count - 1;
      while (i >= 0) and (stat[i] <> Ord(')')) do
        Dec(i);
      if (i < 0) or (i + 4 >= count) then
        continue;
      state := stat[i + 2];
      Inc(i, 4);
      while (i < count) and (stat[i] <> Ord(' ')) do
        Inc(i);
      Inc(i);
      memberGroup := 0;
      while (i < count) and (stat[i] >= Ord('0')) and (stat[i] <= Ord('9')) do
      begin
        memberGroup := memberGroup * 10 + (stat[i] - Ord('0'));
        Inc(i);
      end;
      // A zombie member only waits for its parent; no signal reaches it.
      if (memberGroup = groupId) and (state <> Ord('Z')) and (state <> Ord('X')) then
        Exit;
    end;
    result := reader.Failed;
  finally
    __close(reader.Fd);
  end;
end;
{$ELSE}
var
  pids : array[0..63] of Integer;
  count : Integer;
  i : Integer;
begin
  FillChar(pids, SizeOf(pids), 0);
  count := proc_listpgrppids(groupId, @pids[0], SizeOf(pids));
  if count < 0 then
    Exit(true);
  if count > Length(pids) then
    count := Length(pids);
  for i := 0 to count - 1 do
    if (pids[i] > 0) and (pids[i] <> groupId) then
      Exit(true);
  result := false;
end;
{$ENDIF}

// A child left running (TerminateOnTimeout = False) is reaped by a thread of
// its own once it exits, so it does not stay a zombie.
procedure ReapWhenExited(pid : pid_t);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      status : Integer;
    begin
      WaitPidRetry(pid, @status, 0);
    end).Start;
end;

procedure SetNonBlocking(fd : Integer);
var
  flags : Integer;
begin
  flags := fcntl(fd, F_GETFL);
  if flags <> -1 then
    fcntl(fd, F_SETFL, flags or O_NONBLOCK);
end;

// Reads the child-error self-pipe until EOF (exec succeeded) or a report.
function ReadChildError(fd : Integer; out report : TChildErrorReport) : NativeUInt;
var
  bytesRead : ssize_t;
begin
  FillChar(report, SizeOf(report), 0);
  result := 0;
  repeat
    bytesRead := ReadRetry(fd, PByte(@report) + result, SizeOf(report) - result);
    if bytesRead > 0 then
      Inc(result, bytesRead);
  until (bytesRead <= 0) or (result >= SizeOf(report));
end;

{ TPosixProcess }

type
  TPosixStdInWriter = class(TStdInWriter)
  private
    FFd : Integer;
  protected
    procedure WriteAll;override;
  public
    constructor Create(owner : TProcessBase; const source : IPipeSource; fd : Integer);
    destructor Destroy;override;
  end;

constructor TPosixStdInWriter.Create(owner : TProcessBase; const source : IPipeSource; fd : Integer);
begin
  inherited Create(owner, source);
  FFd := fd;
end;

destructor TPosixStdInWriter.Destroy;
begin
  // Only still open when the thread never ran.
  if FFd <> -1 then
    __close(FFd);
  inherited;
end;

procedure TPosixStdInWriter.WriteAll;
var
  data: TBytes;
  dataLen: NativeUInt;
  hasMore: Boolean;
  written: ssize_t;
  offset: NativeUInt;
  interactiveSrc: IInteractivePipeSource;
  pollFd : TPollFd;
  error : Integer;
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
      offset := 0;
      while (offset < dataLen) and (not IsAborted) do
      begin
        written := __write(FFd, @data[offset], dataLen - offset);
        if written > 0 then
          Inc(offset, written)
        else
        begin
          error := errno;
          if (written < 0) and (error = EINTR) then
            continue;
          if (written < 0) and ((error = EAGAIN) or (error = EWOULDBLOCK)) then
          begin
            // Pipe full: wait (briefly, so an abort is noticed) for room.
            pollFd.fd := FFd;
            pollFd.events := POLLOUT;
            pollFd.revents := 0;
            poll(@pollFd, 1, 100);
            continue;
          end;
          // EPIPE: the child closed stdin or exited.
          hasMore := False;
          Break;
        end;
      end;
      if (dataLen = 0) and hasMore then
      begin
        // Nothing ready yet: wait for the producer instead of spinning.
        if interactiveSrc <> nil then
          interactiveSrc.WaitForData(1000)
        else
          Sleep(10);
      end;
    until (not hasMore) or IsAborted;
  finally
    interactiveSrc := nil;
    // EOF for the child.
    __close(FFd);
    FFd := -1;
  end;
end;

constructor TPosixProcess.Create;
begin
  inherited;
  FProcessId := INVALID_PID;
  FStdOutReadFd := -1;
  FStdErrReadFd := -1;
  FEventFd := -1;
  FPidFd := -1;
end;

destructor TPosixProcess.Destroy;
begin
  // inherited waits for any active run, which releases every fd and thread.
  inherited;
  CloseFd(FEventFd);
  CloseFd(FPidFd);
  CloseFd(FStdOutReadFd);
  CloseFd(FStdErrReadFd);
end;

function TPosixProcess.Clone: IProcess;
begin
  result := TPosixProcess.CreateClone(Self);
end;

procedure TPosixProcess.CreatePipe(out readFd, writeFd: Integer);
var
  pipeArray: array[0..1] of Integer;
  pipeResult: Integer;
  i : integer;
  moved : Integer;
begin
  readFd := -1;
  writeFd := -1;
  {$IFDEF LINUX}
  pipeResult := pipe2(@pipeArray[0], O_CLOEXEC);
  {$ELSE}
  pipeResult := pipe(@pipeArray[0]);
  if pipeResult = 0 then
  begin
    fcntl(pipeArray[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipeArray[1], F_SETFD, FD_CLOEXEC);
  end;
  {$ENDIF}
  if pipeResult <> 0 then
    raise EOSError.Create('Failed to create pipe: ' + SysErrorMessage(errno));
  // When the host runs with stdin/stdout/stderr closed the kernel hands out
  // 0..2 for new fds. The child dup2()s its pipe ends onto 0..2, which must
  // not collide with the ends themselves, so keep them at 3 and above.
  for i := 0 to 1 do
    if pipeArray[i] < 3 then
    begin
      moved := fcntl(pipeArray[i], F_DUPFD_CLOEXEC, 3);
      if moved >= 0 then
      begin
        __close(pipeArray[i]);
        pipeArray[i] := moved;
      end;
    end;
  readFd := pipeArray[0];
  writeFd := pipeArray[1];
end;

procedure TPosixProcess.CloseFd(var fd: Integer);
var
  old: Integer;
begin
  // Atomic swap-to-sentinel-then-close: closing an fd number twice would
  // close whatever the kernel has since reassigned to it.
  old := TInterlocked.Exchange(fd, -1);
  if old <> -1 then
    __close(old);
end;

function TPosixProcess.GetPipeBufferSize: NativeUInt;
begin
  if StartInfo.PipeBufferSize = 0 then
    result := cBufferLen
  else
    result := StartInfo.PipeBufferSize;
end;

function TPosixProcess.ResolveExecutable(out resolved : string) : boolean;
var
  exe : string;
  pathValue : string;
  dirs : TStringList;
  i : integer;
  candidate : string;

  function IsRunnable(const fileName : string) : boolean;
  var
    nameBytes : TBytes;
  begin
    nameBytes := Utf8Z(fileName);
    result := FileExists(fileName) and (access(MarshaledAString(@nameBytes[0]), X_OK) = 0);
  end;

begin
  resolved := '';
  exe := StartInfo.Executable;
  if exe = '' then
    Exit(false);
  if Pos('/', exe) > 0 then
  begin
    // Relative paths are relative to our current directory (as on Windows),
    // not to WorkingDirectory - resolve now, before the child's chdir.
    if exe[1] <> '/' then
      exe := IncludeTrailingPathDelimiter(GetCurrentDir) + exe;
    resolved := exe;
    Exit(IsRunnable(exe));
  end;

  // Bare name: search this process's PATH (/usr/bin:/bin when it has none,
  // like execvp). The PATH given to the child in Environment is never used
  // for the lookup, so the child can be given a constrained PATH (or none).
  pathValue := GetEnvironmentVariable('PATH');
  if pathValue = '' then
    pathValue := '/usr/bin:/bin';
  dirs := TStringList.Create;
  try
    dirs.Delimiter := ':';
    dirs.StrictDelimiter := True;
    dirs.DelimitedText := pathValue;
    for i := 0 to dirs.Count - 1 do
    begin
      // Empty / relative entries would search the current directory.
      if (dirs[i] = '') or (dirs[i][1] <> '/') then
        continue;
      candidate := IncludeTrailingPathDelimiter(dirs[i]) + exe;
      if IsRunnable(candidate) then
      begin
        resolved := candidate;
        Exit(true);
      end;
    end;
  finally
    dirs.Free;
  end;
  result := false;
end;

function TPosixProcess.ValidateStartUpBuilder : boolean;
begin
  result := inherited ValidateStartUpBuilder;
  FResolvedExecutable := '';
  if (StartInfo.Executable <> '') and (not ResolveExecutable(FResolvedExecutable)) then
  begin
    if Pos('/', StartInfo.Executable) > 0 then
      LogError('Executable does not exist or is not executable: ' + StartInfo.Executable)
    else
      LogError('Executable "' + StartInfo.Executable + '" was not found on the PATH');
    FResolvedExecutable := '';
    result := false;
  end;
end;

procedure TPosixProcess.PrepareChildSetup(var setup : TChildSetup; detached : boolean);
var
  pieces : TStringList;
  i : integer;
  arg : IArgument;
  maxFd : LongInt;
  {$IFDEF LINUX}
  cpuIndex : integer;
  {$ENDIF}
begin
  setup.ExecPath := Utf8Z(FResolvedExecutable);

  pieces := TStringList.Create;
  try
    // argv[0] is ArgvZero (busybox-style multi-call binaries) or the
    // executable as the caller wrote it.
    if StartInfo.ArgvZero <> '' then
      pieces.Add(StartInfo.ArgvZero)
    else
      pieces.Add(StartInfo.Executable);
    // argv slots are not shell-parsed, so values are passed verbatim (no
    // quoting). NameValueSeparator = ' ' gives two slots, anything else one.
    for i := 0 to CommandLine.Count - 1 do
    begin
      arg := CommandLine.Arguments[i];
      if arg.Name = '' then
        pieces.Add(arg.Value) // Add('', '') is an explicit empty argument
      else if arg.Value = '' then
        pieces.Add(arg.Name)
      else if arg.NameValueSeparator = ' ' then
      begin
        pieces.Add(arg.Name);
        pieces.Add(arg.Value);
      end
      else
        pieces.Add(arg.Name + arg.NameValueSeparator + arg.Value);
    end;

    SetLength(setup.Argv, pieces.Count + 1);
    for i := 0 to pieces.Count - 1 do
      setup.Argv[i] := AllocZ(pieces[i]);
    setup.Argv[pieces.Count] := nil;

    // /bin/sh <path> <args...> for scripts without a #! line.
    SetLength(setup.ShellArgv, pieces.Count + 2);
    setup.ShellArgv[0] := AllocZ('/bin/sh');
    setup.ShellArgv[1] := AllocZ(FResolvedExecutable);
    for i := 1 to pieces.Count - 1 do
      setup.ShellArgv[i + 1] := AllocZ(pieces[i]);
    setup.ShellArgv[pieces.Count + 1] := nil;
  finally
    pieces.Free;
  end;

  setup.HasEnv := Environment.HasOverrides;
  if setup.HasEnv then
    setup.Envp := Environment.ToEnvironArray
  else
    SetLength(setup.Envp, 0);
  setup.InheritedEnv := PPAnsiChar(environ);

  setup.HasWorkingDir := StartInfo.WorkingDirectory <> '';
  if setup.HasWorkingDir then
    setup.WorkingDir := Utf8Z(StartInfo.WorkingDirectory);
  setup.DevNull := Utf8Z('/dev/null');
  sigemptyset(setup.EmptyMask);

  case StartInfo.Priority of
    TProcessPriority.Idle : setup.NiceValue := 19;
    TProcessPriority.BelowNormal : setup.NiceValue := 10;
    TProcessPriority.AboveNormal : setup.NiceValue := -10; // needs CAP_SYS_NICE / root
  else
    setup.NiceValue := 0;
  end;

  // A child that shares our controlling terminal must stay in our
  // (foreground) process group, otherwise reading the tty stops it with
  // SIGTTIN and Ctrl+C no longer reaches it. Without the group, terminate
  // signals only the child itself rather than its whole tree.
  setup.UseProcessGroup := (not detached) and (ShouldRedirectStdIn or (isatty(STDIN_FILENO) = 0));

  maxFd := sysconf(_SC_OPEN_MAX);
  if (maxFd <= 0) or (maxFd > 65536) then
    maxFd := 65536;
  setup.MaxFd := maxFd - 1;

  {$IFDEF LINUX}
  setup.FdDir := Utf8Z('/proc/self/fd');
  setup.ApplyAffinity := StartInfo.ProcessorAffinity <> 0;
  FillChar(setup.CpuSet, SizeOf(cpu_set_t), 0);
  if setup.ApplyAffinity then
    for cpuIndex := 0 to (SizeOf(NativeUInt) * 8) - 1 do
      if (StartInfo.ProcessorAffinity and (NativeUInt(1) shl cpuIndex)) <> 0 then
        setup.CpuSet.__bits[cpuIndex div 64] := setup.CpuSet.__bits[cpuIndex div 64] or (UInt64(1) shl (cpuIndex mod 64));
  {$ENDIF}
end;

procedure TPosixProcess.FreeChildSetup(var setup : TChildSetup);
begin
  FreeZArray(setup.Argv);
  FreeZArray(setup.ShellArgv);
  FreeZArray(setup.Envp);
end;

function TPosixProcess.CreateEventInstance: Integer;
begin
  {$IFDEF LINUX}
  result := epoll_create1(EPOLL_CLOEXEC);
  {$ENDIF}
  {$IFDEF MACOS}
  result := kqueue;
  if result >= 0 then
    fcntl(result, F_SETFD, FD_CLOEXEC);
  {$ENDIF}
  if result = -1 then
    LogError('Failed to create event instance (falling back to polling): ' + SysErrorMessage(errno));
end;

procedure TPosixProcess.WatchFd(fd: Integer);
var
  event: TPlatformEvent;
begin
  if FEventFd = -1 then
    Exit;
  FillChar(event, SizeOf(event), 0);
  {$IFDEF LINUX}
  event.events := EPOLLIN or EPOLLERR or EPOLLHUP;
  event.data := UInt64(fd);
  if epoll_ctl(FEventFd, EPOLL_CTL_ADD, fd, @event) = -1 then
    LogError('Failed to add fd ' + IntToStr(fd) + ' to epoll: ' + SysErrorMessage(errno));
  {$ENDIF}
  {$IFDEF MACOS}
  event.ident := UInt64(fd);
  event.filter := EVFILT_READ;
  event.flags := EV_ADD or EV_ENABLE;
  if kevent(FEventFd, @event, 1, nil, 0, nil) = -1 then
    LogError('Failed to add fd ' + IntToStr(fd) + ' to kqueue: ' + SysErrorMessage(errno));
  {$ENDIF}
end;

procedure TPosixProcess.WatchChildExit;
{$IFDEF MACOS}
var
  event: TPlatformEvent;
{$ENDIF}
begin
  // Wake the wait loop the moment the child exits. When this isn't
  // available (Linux < 5.3, seccomp profiles) the loop polls for the exit.
  FExitWatched := false;
  FExitNotified := false;
  if FEventFd = -1 then
    Exit;
  {$IFDEF LINUX}
  FPidFd := Integer(syscall(cSysPidfdOpen, NativeInt(FProcessId), NativeInt(0)));
  if FPidFd >= 0 then
  begin
    fcntl(FPidFd, F_SETFD, FD_CLOEXEC);
    WatchFd(FPidFd);
    FExitWatched := true;
  end
  else
    FPidFd := -1;
  {$ENDIF}
  {$IFDEF MACOS}
  FillChar(event, SizeOf(event), 0);
  event.ident := UInt64(FProcessId);
  event.filter := EVFILT_PROC;
  event.flags := EV_ADD or EV_ONESHOT;
  event.fflags := NOTE_EXIT;
  // ESRCH just means it has already exited; waitpid will tell us.
  FExitWatched := kevent(FEventFd, @event, 1, nil, 0, nil) = 0;
  {$ENDIF}
end;

procedure TPosixProcess.UnwatchChildExit;
{$IFDEF LINUX}
var
  event: TPlatformEvent;
{$ENDIF}
begin
  // Once the child has been reaped its pidfd stays readable, which would wake
  // every epoll_wait at once (a busy loop while the pipes are still drained).
  // EVFILT_PROC is one-shot, so macOS has nothing to remove.
  {$IFDEF LINUX}
  if FPidFd = -1 then
    Exit;
  if FEventFd <> -1 then
  begin
    FillChar(event, SizeOf(event), 0);
    epoll_ctl(FEventFd, EPOLL_CTL_DEL, FPidFd, @event);
  end;
  CloseFd(FPidFd);
  {$ENDIF}
end;

procedure TPosixProcess.DrainFd(var fd : Integer; isStdErr : boolean);
var
  chunk : integer;
  bytesRead : ssize_t;
  error : Integer;
begin
  // Read until the pipe is empty (EAGAIN) or at EOF. A hang-up is only the
  // end of the stream once read() returns 0: data written just before the
  // writer exited is still in the pipe. At most 16 reads per wake keeps
  // stdout and stderr interleaving fairly.
  for chunk := 1 to 16 do
  begin
    if fd = -1 then
      Exit;
    bytesRead := __read(fd, @FReadBuffer[0], Length(FReadBuffer));
    if bytesRead > 0 then
    begin
      if isStdErr then
      begin
        Dec(FStdErrUnread, bytesRead);
        ProcessStdErr(FReadBuffer, bytesRead);
      end
      else
      begin
        Dec(FStdOutUnread, bytesRead);
        ProcessStdOut(FReadBuffer, bytesRead);
      end;
    end
    else if bytesRead = 0 then
    begin
      CloseFd(fd);
      Exit;
    end
    else
    begin
      error := errno;
      if error = EINTR then
        continue;
      if (error <> EAGAIN) and (error <> EWOULDBLOCK) then
        CloseFd(fd);
      Exit;
    end;
  end;
end;

function TPosixProcess.HasUnreadOutput : boolean;
begin
  result := ((FStdOutReadFd <> -1) and (FStdOutUnread > 0)) or
            ((FStdErrReadFd <> -1) and (FStdErrUnread > 0));
end;

procedure TPosixProcess.WaitForEvents(timeoutMs : Integer);
var
  events: array[0..cMaxEvents-1] of TPlatformEvent;
  eventCount: Integer;
  i: Integer;
  fd: Integer;
  {$IFDEF MACOS}
  timeSpec: TKTimeSpec;
  {$ENDIF}
begin
  if FEventFd = -1 then
  begin
    // No event instance: poll the pipes on a time slice.
    if timeoutMs > 0 then
      Sleep(timeoutMs);
    if FStdOutReadFd <> -1 then
      DrainFd(FStdOutReadFd, false);
    if FStdErrReadFd <> -1 then
      DrainFd(FStdErrReadFd, true);
    Exit;
  end;
  {$IFDEF LINUX}
  eventCount := epoll_wait(FEventFd, @events[0], cMaxEvents, timeoutMs);
  {$ENDIF}
  {$IFDEF MACOS}
  timeSpec.tv_sec := timeoutMs div 1000;
  timeSpec.tv_nsec := Int64(timeoutMs mod 1000) * 1000000;
  eventCount := kevent(FEventFd, nil, 0, @events[0], cMaxEvents, @timeSpec);
  {$ENDIF}
  // -1 / EINTR is simply "no events"; the caller re-evaluates and calls again.
  for i := 0 to eventCount - 1 do
  begin
    {$IFDEF LINUX}
    fd := Integer(events[i].data);
    {$ENDIF}
    {$IFDEF MACOS}
    if events[i].filter <> EVFILT_READ then
    begin
      // Child exit - picked up by TryReap. The event is one-shot, and it
      // may be posted before the child can be reaped.
      FExitNotified := true;
      continue;
    end;
    fd := Integer(events[i].ident);
    {$ENDIF}
    if (fd = FStdOutReadFd) and (fd <> -1) then
      DrainFd(FStdOutReadFd, false)
    else if (fd = FStdErrReadFd) and (fd <> -1) then
      DrainFd(FStdErrReadFd, true);
  end;
end;

function TPosixProcess.TryReap(var status : Integer; out unknownStatus : boolean; out stopSignal : Integer) : boolean;
var
  waitResult : pid_t;
begin
  unknownStatus := false;
  stopSignal := 0;
  // WUNTRACED: a stopped child would otherwise look like one that is still
  // running, for as long as nothing continues it.
  waitResult := WaitPidRetry(FProcessId, @status, WNOHANG or WUNTRACED);
  if waitResult = FProcessId then
  begin
    if WIFSTOPPED(status) then
    begin
      stopSignal := WSTOPSIG(status);
      Exit(false);
    end;
    Exit(true);
  end;
  if waitResult = -1 then
  begin
    // ECHILD: reaped by someone else (or SIGCHLD is SIG_IGN in the host).
    unknownStatus := true;
    Exit(true);
  end;
  result := false;
end;

procedure TPosixProcess.SignalChild(sig : Integer);
begin
  // Only ever called while the child is unreaped (a child that has exited is
  // kept as a zombie until its group has been signalled), so its pid (and
  // process group id) cannot have been recycled. Never 0 or -1: those would
  // signal our own group / every process.
  if FProcessId <= 1 then
    Exit;
  if FUseProcessGroup and (kill(-FProcessId, sig) = 0) then
    Exit;
  kill(FProcessId, sig);
end;

function TPosixProcess.DoCreateProcess: boolean;
var
  setup : TChildSetup;
  setupBuilt : boolean;
  childPid: pid_t;
  outRead, outWrite : Integer;
  errRead, errWrite : Integer;
  inRead, inWrite : Integer;
  errPipeRead, errPipeWrite : Integer;
  report : TChildErrorReport;
  status : Integer;
  redirectOut, redirectErr, redirectIn : boolean;
  writer : IStdInWriter;
  writerThread : TThread;
  fileSource : IFileStdInPipeSource;
begin
  result := False;
  FProcessId := INVALID_PID;
  FStdOutReadFd := -1;
  FStdErrReadFd := -1;
  FEventFd := -1;
  FPidFd := -1;
  FStdInWriter := nil;
  outRead := -1;
  outWrite := -1;
  errRead := -1;
  errWrite := -1;
  inRead := -1;
  inWrite := -1;
  errPipeRead := -1;
  errPipeWrite := -1;
  setupBuilt := false;
  redirectOut := ShouldRedirectStdOut;
  redirectErr := ShouldRedirectStdErr;
  redirectIn := ShouldRedirectStdIn;
  try
    try
      if redirectOut then
        CreatePipe(outRead, outWrite);
      if redirectErr then
        CreatePipe(errRead, errWrite);
      if redirectIn then
      begin
        // TPipeSource.FileAsStdIn: the child's fd 0 is the file itself, a
        // CLOEXEC copy (at 3 or above, as for the pipe ends) of the fd the
        // source opened, closed like inRead once the child has its own.
        if Supports(FRunStdIn, IFileStdInPipeSource, fileSource) then
        begin
          inRead := fcntl(Integer(fileSource.FileHandle), F_DUPFD_CLOEXEC, 3);
          if inRead < 0 then
            raise EOSError.Create('Failed to duplicate the stdin file: ' + SysErrorMessage(errno));
        end
        else
          CreatePipe(inRead, inWrite);
      end;
      // Child-error self-pipe: CLOEXEC, so a successful execve closes the
      // write end and the parent's read sees EOF.
      CreatePipe(errPipeRead, errPipeWrite);
      PrepareChildSetup(setup, false);
      setupBuilt := true;

      childPid := fork();
      if childPid = 0 then
        RunChild(setup, inRead, outWrite, errWrite, errPipeWrite, false);
      if childPid = -1 then
      begin
        FLastError := errno;
        LogError('Failed to fork process: ' + SysErrorMessage(FLastError));
        Exit;
      end;
      FProcessId := childPid;
      FUseProcessGroup := setup.UseProcessGroup;
      // Also from the parent, so the group exists before we could signal it.
      if FUseProcessGroup then
        setpgid(childPid, childPid);
    finally
      // The child has its own copies of its pipe ends.
      CloseFd(outWrite);
      CloseFd(errWrite);
      CloseFd(inRead);
      CloseFd(errPipeWrite);
      if setupBuilt then
        FreeChildSetup(setup);
    end;

    // read() returns 0 iff execve succeeded; otherwise the child reports
    // which step failed.
    if ReadChildError(errPipeRead, report) > 0 then
    begin
      FLastError := report.ErrnoValue;
      LogError('Child process initialisation failed at ' + ChildErrStepName(report.Step) + ': ' +
               SysErrorMessage(report.ErrnoValue));
      // Reap the doomed child so we don't leave a zombie.
      WaitPidRetry(FProcessId, @status, 0);
      FProcessId := INVALID_PID;
      Exit;
    end;
    CloseFd(errPipeRead);

    FEventFd := CreateEventInstance;
    WatchChildExit;
    SetLength(FReadBuffer, GetPipeBufferSize);
    if redirectOut then
    begin
      FStdOutReadFd := outRead;
      outRead := -1;
      SetNonBlocking(FStdOutReadFd);
      WatchFd(FStdOutReadFd);
    end;
    if redirectErr then
    begin
      FStdErrReadFd := errRead;
      errRead := -1;
      SetNonBlocking(FStdErrReadFd);
      WatchFd(FStdErrReadFd);
    end;
    // A stdin that is a file (FileAsStdIn) needs no writer.
    if redirectIn and (fileSource = nil) then
    begin
      // Non-blocking so the writer can give up when the run ends even if a
      // descendant holds the pipe and never reads.
      SetNonBlocking(inWrite);
      writer := TPosixStdInWriter.Create(Self, FRunStdIn, inWrite);
      inWrite := -1;
      writerThread := TThread.CreateAnonymousThread(
        procedure
        begin
          writer.Execute;
        end);
      // Known before the thread runs, so Terminate called from inside the
      // stdin source never waits on itself. The thread frees itself; only the
      // writer is kept.
      writer.SetThreadId(writerThread.ThreadID);
      FStdInWriterThreadId := writerThread.ThreadID;
      FStdInWriter := writer;
      writerThread.Start;
    end;
    result := True;
  finally
    if not result then
    begin
      if FProcessId <> INVALID_PID then
      begin
        SignalChild(SIGKILL);
        WaitPidRetry(FProcessId, @status, 0);
        FProcessId := INVALID_PID;
      end;
      StopStdInWriter;
      CloseFd(outRead);
      CloseFd(errRead);
      CloseFd(inWrite);
      CloseFd(errPipeRead);
      CloseFd(FStdOutReadFd);
      CloseFd(FStdErrReadFd);
      CloseFd(FPidFd);
      CloseFd(FEventFd);
    end;
  end;
end;

procedure TPosixProcess.StopStdInWriter;
const
  cStopWaitMs = 1000;
var
  interactiveSrc : IInteractivePipeSource;
begin
  if FStdInWriter = nil then
    Exit;
  // The child is gone: an interactive source can't usefully take more input.
  if Supports(FRunStdIn, IInteractivePipeSource, interactiveSrc) then
    interactiveSrc.Close;
  interactiveSrc := nil;
  FStdInWriter.Abort;
  if FStdInWriter.WaitFor(cStopWaitMs) then
  begin
    if FStdInWriter.Error <> '' then
      LogError(FStdInWriter.Error);
  end
  else
  begin
    // Blocked in the source's GetData. The writer holds everything it uses
    // and finishes whenever GetData returns; it is detached so it no longer
    // keeps this process alive.
    FDetachedOwnerRef := FStdInWriter.Detach;
    LogError('The stdin pipe source did not return from GetData within ' + IntToStr(cStopWaitMs) +
             'ms of being stopped; its writer thread was left to finish on its own');
  end;
  FStdInWriter := nil;
  FStdInWriterThreadId := 0;
end;

procedure TPosixProcess.DoWaitForCompletion(var outcome : TProcessOutcome);
const
  cSliceMs = 100;        // longest single wait - bounds cancel / terminate latency
  cTermGraceMs = 500;    // SIGTERM -> SIGKILL
  cKillGiveUpMs = 5000;  // SIGKILL -> stop waiting (process stuck in the kernel)
  cGroupPollMaxMs = 50;  // longest wait between two looks at the group of a child that has exited
type
  TKillReason = (krNone, krTimeout, krTerminate);
var
  clock : TStopwatch;
  status : Integer;
  reaped : boolean;
  unknownStatus : boolean;
  reason : TKillReason;
  abandoned : boolean;
  gaveUp : boolean;
  unreadRecorded : boolean;
  sigKillSent : boolean;
  killAt : Int64;
  giveUpAt : Int64;
  drainUntil : Int64;
  timeoutMs : Int64;
  drainMs : Cardinal;
  nowMs : Int64;
  waitMs : Int64;
  stopSignal : Integer;
  ttyStopped : boolean;
  leaderExited : boolean;
  groupPollMs : Int64;
  exitPollMs : Int64;
  pipesWereOpen : boolean;
begin
  status := 0;
  reaped := false;
  unknownStatus := false;
  stopSignal := 0;
  ttyStopped := false;
  leaderExited := false;
  groupPollMs := 1;
  exitPollMs := 1;
  reason := krNone;
  abandoned := false;
  gaveUp := false;
  unreadRecorded := false;
  FStdOutUnread := 0;
  FStdErrUnread := 0;
  sigKillSent := false;
  killAt := -1;
  giveUpAt := -1;
  drainUntil := -1;
  drainMs := 0;
  timeoutMs := StartInfo.TimeoutInMSec;
  clock := TStopwatch.StartNew;
  try
    // Running -> (Killing) -> Draining. Each pass waits at most one slice so
    // cancellation and Terminate are noticed promptly; with a pidfd /
    // EVFILT_PROC the child's exit wakes the wait immediately.
    while true do
    begin
      if reaped and (FStdOutReadFd = -1) and (FStdErrReadFd = -1) then
        Break;
      nowMs := clock.ElapsedMilliseconds;
      waitMs := cSliceMs;
      if (reason = krNone) and (timeoutMs <> 0) and (timeoutMs - nowMs < waitMs) then
        waitMs := timeoutMs - nowMs;
      if (killAt >= 0) and (not sigKillSent) and (killAt - nowMs < waitMs) then
        waitMs := killAt - nowMs;
      if (drainUntil >= 0) and (drainUntil - nowMs < waitMs) then
        waitMs := drainUntil - nowMs;
      if not reaped then
      begin
        // Nothing wakes the wait for these, so they are polled: the rest of
        // the group of a child that has exited, and the exit itself when
        // there is no exit watch.
        if leaderExited then
        begin
          if groupPollMs < waitMs then
            waitMs := groupPollMs;
        end
        else if (not FExitWatched) and (exitPollMs < waitMs) then
          waitMs := exitPollMs;
      end;
      if waitMs < 0 then
        waitMs := 0;
      pipesWereOpen := (FStdOutReadFd <> -1) or (FStdErrReadFd <> -1);
      WaitForEvents(Integer(waitMs));
      nowMs := clock.ElapsedMilliseconds;

      // Without an exit watch the exit is looked for after 1, 2, 4 ... ms,
      // up to the full slice: a short-lived child is not kept waiting for a
      // whole slice and a long-lived one costs a handful of wake-ups. The
      // steps start again when the exit is known to be close.
      if FExitNotified then
      begin
        // macOS posts the one-shot NOTE_EXIT before the child can be reaped.
        FExitNotified := false;
        FExitWatched := false;
        exitPollMs := 1;
      end
      else if pipesWereOpen and (FStdOutReadFd = -1) and (FStdErrReadFd = -1) then
        // A process closes its descriptors just before it can be reaped.
        exitPollMs := 1
      else if exitPollMs < cSliceMs then
        exitPollMs := exitPollMs * 2;

      if not reaped then
      begin
        if FUseProcessGroup and (reason <> krNone) and (not sigKillSent) then
        begin
          // Between SIGTERM and SIGKILL the child is not reaped when it
          // exits: its group may hold members that ignore or outlive
          // SIGTERM, and only an unreaped leader keeps the group id from
          // being reused before they get their SIGKILL.
          if not leaderExited then
          begin
            leaderExited := HasExited(FProcessId);
            // Its pidfd stays readable from now on.
            if leaderExited then
              UnwatchChildExit;
          end;
          // SIGKILL once the grace period is over - or at once when nobody
          // else is left in the group, so that the usual Terminate does not
          // wait for it.
          if leaderExited then
          begin
            if (nowMs >= killAt) or (not GroupHasOtherMembers(FProcessId)) then
            begin
              SignalChild(SIGKILL);
              sigKillSent := true;
              giveUpAt := nowMs + cKillGiveUpMs;
              reaped := TryReap(status, unknownStatus, stopSignal);
            end
            else if groupPollMs < cGroupPollMaxMs then
              groupPollMs := groupPollMs * 2;
          end;
        end
        else
        begin
          reaped := TryReap(status, unknownStatus, stopSignal);
          if reaped then
            UnwatchChildExit
          // Only in a group of its own: in our group we were stopped with it,
          // and the shell continues the whole job.
          else if FUseProcessGroup and ((stopSignal = SIGTTIN) or (stopSignal = SIGTTOU)) then
            ttyStopped := true;
        end;
      end;

      if not reaped then
      begin
        if reason = krNone then
        begin
          if (timeoutMs <> 0) and (nowMs >= timeoutMs) then
          begin
            reason := krTimeout;
            outcome.TimedOut := true;
            if not StartInfo.TerminateOnTimeout then
            begin
              // Leave the child (and its process group) running.
              abandoned := true;
              Break;
            end;
          end
          else if IsStopRequested then
            reason := krTerminate
          else if ttyStopped then
          begin
            // In its own (background) process group the child may not use
            // the controlling terminal: the kernel stops it, and nothing
            // would ever continue it.
            LogError('The process was stopped because it tried to use the terminal (SIGTTIN / SIGTTOU): its stdin is redirected, ' +
                     'so it runs in a background process group. It cannot continue and was terminated');
            reason := krTerminate;
          end;
          if reason <> krNone then
          begin
            SignalChild(SIGTERM);
            // A stopped process only acts on SIGTERM once it is continued.
            if ttyStopped then
              SignalChild(SIGCONT);
            killAt := nowMs + cTermGraceMs;
          end;
        end
        else if (not sigKillSent) and (nowMs >= killAt) then
        begin
          SignalChild(SIGKILL);
          sigKillSent := true;
          giveUpAt := nowMs + cKillGiveUpMs;
        end
        else if sigKillSent and (nowMs >= giveUpAt) then
        begin
          LogError('The process did not exit after SIGKILL; no longer waiting for it');
          gaveUp := true;
          Break;
        end;
      end;

      if reaped and (not unreadRecorded) then
      begin
        // After a normal exit, what the child left in the pipes is read
        // however slow the targets are. After a kill the drain stays bounded.
        if reason = krNone then
        begin
          FStdOutUnread := UnreadBytes(FStdOutReadFd);
          FStdErrUnread := UnreadBytes(FStdErrReadFd);
        end;
        unreadRecorded := true;
      end;
      if reaped and (drainUntil < 0) and (not HasUnreadOutput) then
      begin
        // Then keep reading only for so long: a descendant may hold the pipe
        // open indefinitely.
        drainMs := GetDrainTimeout(reason <> krNone);
        if drainMs = INFINITE then
          drainUntil := High(Int64)
        else
          drainUntil := nowMs + drainMs;
      end;
      if reaped and (reason = krNone) and ((FStdOutReadFd <> -1) or (FStdErrReadFd <> -1)) and IsStopRequested then
      begin
        // The child exited by itself and Terminate / cancellation came while
        // its output was still being read: stop reading. The reaped child's
        // pid (and so its process group) is not signalled.
        LogError('Output may be truncated: Terminate / cancellation was requested while stdout/stderr were still open after the process exited (probably held by a child process it started); the remaining output was not read');
        Break;
      end;
      if reaped and ((FStdOutReadFd <> -1) or (FStdErrReadFd <> -1)) and (drainUntil >= 0) and (nowMs >= drainUntil) then
      begin
        LogError('Output may be truncated: stdout/stderr were still open ' + IntToStr(drainMs) +
                 'ms after the process exited and the output it left in the pipes had been read (probably held by a child process it started)');
        Break;
      end;
    end;
  finally
    if (not reaped) and (not abandoned) and (not gaveUp) then
    begin
      // Only reached via an exception: don't leave the child behind.
      if reason = krNone then
        reason := krTerminate;
      SignalChild(SIGKILL);
      WaitPidRetry(FProcessId, @status, 0);
    end;
    case reason of
      krTimeout :
        begin
          outcome.Status := TProcessStatus.TimedOut;
          outcome.ExitCode := StartInfo.TimedOutExitCode;
        end;
      krTerminate :
        begin
          outcome.Status := TProcessStatus.Terminated;
          outcome.ExitCode := StartInfo.TerminateExitCode;
        end;
    else
      if unknownStatus then
      begin
        LogError('The exit status of the process is not available (it was reaped elsewhere)');
        outcome.Status := TProcessStatus.Exited;
        outcome.ExitCode := $FFFFFFFF;
      end
      else if WIFEXITED(status) then
      begin
        outcome.Status := TProcessStatus.Exited;
        outcome.ExitCode := WEXITSTATUS(status);
      end
      else if WIFSIGNALED(status) then
      begin
        outcome.Status := TProcessStatus.Terminated;
        outcome.ExitCode := 128 + WTERMSIG(status);
      end
      else
      begin
        outcome.Status := TProcessStatus.Exited;
        outcome.ExitCode := 1;
      end;
    end;
    if abandoned then
    begin
      // What the child wrote before the timeout, then no more: closing the
      // read ends means it gets SIGPIPE / EPIPE if it writes again.
      DrainFd(FStdOutReadFd, false);
      DrainFd(FStdErrReadFd, true);
    end;
    StopStdInWriter;
    CloseFd(FStdOutReadFd);
    CloseFd(FStdErrReadFd);
    CloseFd(FPidFd);
    CloseFd(FEventFd);
    // Not reaped yet: reap it whenever it does exit, so it doesn't stay a
    // zombie.
    if abandoned or gaveUp then
      ReapWhenExited(FProcessId);
  end;
end;

function TPosixProcess.DoExecuteDetached: boolean;
var
  setup : TChildSetup;
  childPid: pid_t;
  grandchildPid: pid_t;
  errPipeRead, errPipeWrite: Integer;
  report : TChildErrorReport;
  status: Integer;
  firstChildExited: Boolean;
  setupBuilt : boolean;
begin
  result := False;
  FProcessId := INVALID_PID;
  errPipeRead := -1;
  errPipeWrite := -1;
  setupBuilt := false;
  try
    CreatePipe(errPipeRead, errPipeWrite);
    try
      PrepareChildSetup(setup, true);
      setupBuilt := true;
      childPid := fork();
      if childPid = 0 then
      begin
        // First child: new session (no controlling terminal), then the
        // grandchild - which init adopts once we _exit - is the real process.
        if setsid() = -1 then
          _exit(255);
        grandchildPid := fork();
        if grandchildPid = -1 then
          _exit(255);
        if grandchildPid <> 0 then
          _exit(0);
        RunChild(setup, -1, -1, -1, errPipeWrite, true);
      end;
      if childPid = -1 then
      begin
        FLastError := errno;
        LogError('Failed to fork process: ' + SysErrorMessage(FLastError));
        CloseFd(errPipeRead);
        Exit;
      end;
    except
      CloseFd(errPipeRead);
      raise;
    end;
  finally
    CloseFd(errPipeWrite);
    if setupBuilt then
      FreeChildSetup(setup);
  end;

  // Reap the first child (it exits right after forking the grandchild).
  firstChildExited := WaitPidRetry(childPid, @status, 0) = childPid;

  // EOF means the grandchild's execve succeeded (CLOEXEC closed the pipe).
  if ReadChildError(errPipeRead, report) > 0 then
  begin
    CloseFd(errPipeRead);
    FLastError := report.ErrnoValue;
    LogError('Detached child initialisation failed at ' + ChildErrStepName(report.Step) + ': ' +
             SysErrorMessage(report.ErrnoValue));
    Exit;
  end;
  CloseFd(errPipeRead);

  if firstChildExited and WIFEXITED(status) and (WEXITSTATUS(status) <> 0) then
  begin
    LogError('Detached child first-stage failed (setsid or fork): exit code ' + IntToStr(WEXITSTATUS(status)));
    Exit;
  end;

  // The grandchild's PID is not known across the double fork.
  FProcessId := INVALID_PID;
  result := True;
end;

function TPosixProcess.GetProcessId: Cardinal;
begin
  if FProcessId <> INVALID_PID then
    result := FProcessId
  else
    result := 0;
end;

initialization
  // This library writes to child pipes, so EPIPE from write() is the
  // contract we want: a SIGPIPE would kill the host. Set once for the whole
  // process (children get SIG_DFL back before exec).
  signal(SIGPIPE, TSignalHandler(SIG_IGN));

{$IFEND}

end.
