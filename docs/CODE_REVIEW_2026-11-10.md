# VSoft.Process code review - 2026-11-10

Branch `fb9-support` at commit `43b5b47`. No source file was changed by this review.

## How the review was done

Five reviewers each read one area of `Source\` in full, line by line: the Windows implementation, the POSIX implementation, the core lifecycle and threading, the pipe targets and sources, and the supporting units (command line, environment, utils, start info, credentials). The findings were then merged, de-duplicated and spot-checked against the source.

Evidence level differs by finding and is stated in each one under "Confidence":

- Most findings come from reading the code path only. The library's test suite was not run as part of this review.
- WIN-1, WIN-2, WIN-3, WIN-4 and WIN-6 were also reproduced at run time with small scratch programs compiled from `Source\` outside the repo. SUP-1 was reproduced with a stand-alone `CreateProcessW` experiment that builds the same command line the library would.
- Nothing POSIX was executed. Windows 7 specific paths were read but not exercised.
- The lead re-read the source for WIN-1, POSIX-1, PIPE-1, PIPE-2, SUP-1 and CORE-3 to CORE-7 and agrees with them. The remaining findings are as reported by the area reviewer.

## Summary

36 findings: 0 Critical, 2 High, 8 Medium, 26 Low. No deadlock inside the library's own locking, no handle or fd leak on an error path, and no lost-output bug was found. The one real leak (PIPE-10) is a reference cycle through a user closure. The problems are concentrated in the recently added features and in edge cases of the documented contract.

Each finding below has an explanation, a proposed test and a fix direction. IDs are prefixed by area: WIN, POSIX, CORE, PIPE, SUP.

### High

| ID | Finding |
|----|---------|
| SUP-1 | A NUL (#0) in an argument defeats the batch-file protection (command injection through cmd.exe), and silently drops later arguments for any program |
| WIN-1 | `InheritHostStdHandles` does not work when the host's std handle is a console: the child always gets a new console, so the host console handle is unusable |

### Medium

| ID | Finding |
|----|---------|
| WIN-2 | `DeliverOnRunThread`: the run timeout never fires while both stdout and stderr stay busy |
| CORE-1 | Waits on the main thread never service `TThread.Synchronize`: `Terminate` stalls 5 s and returns False; a synchronous `Execute` hangs |
| POSIX-1 | Tree kill never sends SIGKILL to the group once the direct child has died from SIGTERM |
| PIPE-1 | Line target reads one past the end of its buffer at the 1 MB forced line break (`ERangeError` under `{$R+}`) |
| PIPE-2 | `ToAll`: a child whose `Start` raises leaves the earlier children started (file left open and locked) |
| PIPE-3 | Default decoding is the ANSI code page, but console children on Windows write in the OEM code page |
| SUP-2 | POSIX: one environment entry that is not valid UTF-8 makes `TProcess.Create` raise |
| SUP-3 | `AddUnsafeBatchRaw('')` passes an empty argument (`""`) instead of nothing |

### Low

| ID | Finding |
|----|---------|
| WIN-3 | False "Output may be truncated" error with a slow target |
| WIN-4 | `ExecuteDetached` disables Ctrl+C in the detached child's tree |
| WIN-5 | `GSpawnLock` serialises every launch but protects nothing (excessive locking) |
| WIN-6 | `SafeCloseHandle` swaps only the low 32 bits on Win64 with XE2 to XE7 (latent) |
| POSIX-2 | Child with redirected stdin is put in a background process group even when the host owns a terminal |
| POSIX-3 | Up to 65,533 `close()` calls per spawn; fds at 65536 or above are never closed |
| POSIX-4 | Exit only noticed on the next 100 ms slice when the exit wake-up is missing or early |
| POSIX-5 | `GSpawnLock` does not do what its comment says (excessive locking) |
| POSIX-6 | x86-64-only assumptions are not enforced at compile time |
| CORE-3 | `Terminate(waitMS > 0)` from another thread during `ExecuteAsync`'s start window returns True without waiting |
| CORE-4 | A `Terminate` aimed at one run can kill the next run |
| CORE-5 | A faulted target attached to both streams keeps receiving the other stream |
| CORE-6 | A target or source whose `Done` raises a non-Exception object leaves the run permanently "in progress" |
| CORE-7 | `ExecuteDetached` is refused by a validation rule the README says is ignored; `ExitCode` raises after a refused detached launch |
| PIPE-4 | README says a raising target inside `ToAll` stops the group; the code keeps siblings running |
| PIPE-5 | A line target whose callback raised is called again from `Done` with a corrupted line |
| PIPE-6 | A byte order mark is kept as U+FEFF in the first line |
| PIPE-7 | Split-character guard misses GB18030 on Windows and non-UTF-8 multi-byte code pages on POSIX |
| PIPE-8 | `ToStringBuilder` with a DBCS code page calls `IsDBCSLeadByteEx` once per byte |
| PIPE-9 | `FromFile` / `FileAsStdIn` open with `fmShareDenyWrite` |
| PIPE-10 | A delegate that captures the `IProcess` forms a reference cycle that cannot be broken (leaks the process and its job handle) |
| SUP-4 | Batch target: a quoted value ending in a backslash arrives with the backslash doubled |
| SUP-5 | A name ending in a backslash directly followed by a quoted value corrupts both |
| SUP-6 | `DOMAIN\user` in `UserName` with no `Domain` is logged on against the local machine |
| SUP-7 | README describes the password scrub differently from the code |
| SUP-8 | Every `TProcess.Create` and `Clone` copies the whole host environment |

Two findings were reported independently by two reviewers and appear once: the `DeliverOnRunThread` timeout (kept as WIN-2, which has the run-time evidence) and the closure reference cycle (kept as PIPE-10). CORE-2 and CORE-8 are therefore absent from the numbering.

### Open questions the reviewers could not settle

- Whether `CreateProcessWithLogonW` accepts `LoadUserProfile` together with `NetCredentialsOnly`.
- Whether `password := Credentials.Password` goes through a compiler temporary that would defeat `ScrubString`.
- POSIX `StopStdInWriter` calls `Close` on an interactive stdin source at the end of every run; nobody checked whether Windows and a re-run behave the same way.

---

## Windows implementation

### WIN-1. InheritHostStdHandles does not work when the host's std handle is a console

- Severity: High
- Category: bug / docs mismatch
- Confidence: Confirmed by reading the code path and at run time (Windows 11 26300)
- Location: `Source\VSoft.Process.Windows.pas:1019-1044` (`HostStdHandle`), `:1092-1100`, `:1133` (`CREATE_NEW_CONSOLE` is unconditional); README lines 802-806
- Explanation:
  `StartInfo.InheritHostStdHandles` gives a stream that is not redirected a duplicate of the host's own std handle (`HostStdHandle` -> `DuplicateHandle(GetStdHandle(...))`). The README says what that means: "With only stdout captured, the child's stderr goes wherever the host's stderr goes: the host's console, or the file or pipe a CI agent redirected it to. The child reads the host's stdin."

  The child, however, is always created with a console of its own:

  ```pascal
  creationFlags := CREATE_NEW_CONSOLE or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED or PriorityClass(StartInfo.Priority);
  ```

  A console handle only works in a process that is attached to that console. A child attached to a new console cannot use a handle to the host's console: every write (and read) on it fails. So in the most common case for this option - a console program run from a terminal, with stdout captured and stderr left alone - the child's stderr goes nowhere, and the child sees write errors. Nothing is logged to `Errors`. The same applies to the host's console stdin, and to the credentials path (the logon child also gets a new console).

  Run-time proof (`conprobe.dpr`): a host with a real console (AllocConsole, std handles set to `CONOUT$` / `CONIN$`) runs `cmd.exe /c echo MARKER 1>&2` with a stdout target and `InheritHostStdHandles := True`, then reads its own console screen buffer with `ReadConsoleOutputCharacterW`:

  ```
  HideWindow=False Execute=True status=2 exit=1 errors=[]
  HideWindow=True  Execute=True status=2 exit=1 errors=[]
  direct CreateProcess, flags 0 (shares console) : exit=0   -> marker on the host console
  direct CreateProcess, CREATE_NEW_CONSOLE       : exit=1   -> marker missing
  direct CreateProcess, CREATE_NO_WINDOW         : exit=1   -> marker missing
  ```

  The library runs exit with code 1 (cmd's `echo` failed) and the marker never reaches the host console. The control launches show the cause is the new console, not the handle duplication or the handle list.

  It works when the host's handle is a file or a pipe (CI), which is the only case the tests cover: `InheritHostStdHandles_StdErrGoesToHostStdErr` / `InheritHostStdHandles_StdInComesFromHostStdIn` (`Tests\VSoft.Process.Tests.Lifecycle.pas:2529`, `:2545`) and `NetOnlyLogon_InheritHostStdHandles_StdErrGoesToHostStdErr` set the std handle to a temp file with `SetStdHandle`. No test uses a console handle.
- Proposed test: needs a host with a real console, so use the helper exe (`--vsp-helper=<mode>`, `Tests\VSoft.Process.Tests.Helper.pas`). New helper mode `inherit-console`:

  ```pascal
  // helper: exit code 0 = the child's stderr reached this console
  procedure RunInheritConsole;
  var
    hOut : THandle;
    proc : IProcess;
    sink : TStringBuilder;
    buf : array[0..3999] of WideChar;
    got : DWORD;
    origin : TCoord;
    screen : string;
  begin
    FreeConsole;
    AllocConsole;
    ShowWindow(GetConsoleWindow, SW_HIDE);
    hOut := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    SetStdHandle(STD_ERROR_HANDLE, hOut);
    sink := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.Executable := 'C:\Windows\System32\cmd.exe';
      proc.StartInfo.InheritHostStdHandles := True;
      proc.CommandLine.Add('/c');
      proc.CommandLine.Add('echo VSP_MARKER 1>&2', TQuoted.qtNone);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(sink));
      proc.Execute;
      origin.X := 0;
      origin.Y := 0;
      got := 0;
      ReadConsoleOutputCharacterW(hOut, @buf[0], 4000, origin, got);
      SetString(screen, PWideChar(@buf[0]), got);
      if (proc.ExitCode = 0) and (Pos('VSP_MARKER', screen) > 0) then
        ExitCode := 0
      else
        ExitCode := 1;
    finally
      sink.Free;
    end;
  end;
  ```

  Test `InheritHostStdHandles_ConsoleHost_StdErrReachesHostConsole`: run the test exe with `--vsp-helper=inherit-console` (NoJob, hidden) and assert its exit code is 0. It returns 1 today.
- Suggested fix direction: when a host handle that is given to the child is a console handle (`GetConsoleMode` succeeds on it), the child has to share the host's console, so leave out `CREATE_NEW_CONSOLE` for that launch (and decide what that means for Ctrl+C: the child is then in the host's console group). If sharing the console is not wanted, treat a console handle like the Windows 7 pseudo-handle case (NUL plus a message in `Errors`) and correct the README.

### WIN-2. DeliverOnRunThread: the timeout never fires while both stdout and stderr keep producing output

- Severity: Medium
- Category: bug
- Confidence: Confirmed by reading the code path and at run time
- Location: `Source\VSoft.Process.Windows.pas:1585-1598` (`DoWaitForCompletion`)
- Explanation:
  With `StartInfo.DeliverOnRunThread` the run's thread waits on the process handle, the terminate / cancellation handles and, last, the two `DataReady` events, and delivers a read each time one of those is signalled:

  ```pascal
  repeat
    if timeOutDuration = INFINITE then
      waitMs := INFINITE
    else if clock.ElapsedMilliseconds >= timeOutDuration then
      waitMs := 0
    else
      waitMs := timeOutDuration - Cardinal(clock.ElapsedMilliseconds);
    waitRes := WaitForMultipleObjects(handleCount, @objHandles, False, waitMs);
    handedOver := (waitRes >= WAIT_OBJECT_0 + Cardinal(readyFirst)) and (waitRes < WAIT_OBJECT_0 + Cardinal(handleCount));
    if handedOver then
      DispatchHandedOver;
  until not handedOver;
  ```

  Once the timeout has elapsed the wait is made with 0 ms, but `WaitForMultipleObjects` only returns `WAIT_TIMEOUT` when no handle is signalled. If a `DataReady` event is set at that moment the loop delivers and goes round again. The timeout is only noticed on an iteration where neither stream has a read waiting.

  With one busy stream that happens almost at once (after `CompleteRead` queues the next read, the run thread gets back to the wait before the threadpool callback has set `DataReady`). With two busy streams it never happens: while `DispatchHandedOver` is delivering stderr, the read it just queued for stdout completes and sets its event, and the other way round, so one of the two events is always set when the wait is reached. Any target that takes a millisecond or more is enough.

  User-visible consequence: a child that writes continuously to both stdout and stderr (a chatty build, a tool that logs to both) with `DeliverOnRunThread` and `TimeoutInMSec` set is never timed out. `Execute` only returns when the child exits by itself or `Terminate` / cancellation is used (those still work: their handles come before the `DataReady` events).

  Run-time proof (`verify.dpr`): child `cmd /c for /l %i in () do @(echo out & echo err 1>&2)`, `TimeoutInMSec = 1000`, a target on each stream that sleeps per call, and a watchdog thread that calls `Terminate(0)` after about 15 s:

  ```
  threadpool delivery, sleep 20 ms : elapsed 1125 ms,  Status TimedOut
  DeliverOnRunThread,  sleep 20 ms : elapsed 18783 ms, Status Terminated (the watchdog ended it; the timeout never fired)
  DeliverOnRunThread,  sleep  1 ms : elapsed 18709 ms, Status Terminated (same)
  DeliverOnRunThread,  sleep  0 ms : elapsed 1019 ms,  Status TimedOut
  DeliverOnRunThread, stdout only, sleep 20 ms : elapsed 1112 ms, Status TimedOut
  ```

  Existing coverage: `DeliverOnRunThread_TimeoutAndTerminate` (`Tests\VSoft.Process.Tests.Lifecycle.pas:1940`) uses `print-then-sleep`, a child that is silent when the timeout comes, and only stdout. It does not catch this.
- Proposed test: `DeliverOnRunThread_Timeout_FiresWhileBothStreamsAreBusy` in `TProcessLifecycleTests`:

  ```pascal
  var
    proc : IProcess;
    outTarget, errTarget : TSlowTarget;
    outRef, errRef : IPipeTarget;
    started : Int64;
  begin
    outTarget := TSlowTarget.Create;
    outRef := outTarget;
    outTarget.SleepMs := 5;
    errTarget := TSlowTarget.Create;
    errRef := errTarget;
    errTarget.SleepMs := 5;
    proc := TProcess.Create;
    proc.StartInfo.DeliverOnRunThread := True;
    proc.StartInfo.TimeoutInMSec := 1000;
    TTestHelpers.SetupInlineCommand(proc, 'for /l %i in () do @(echo out & echo err 1>&2)', '');
    proc.WithStdOutPipe(outRef);
    proc.WithStdErrPipe(errRef);
    // so a regression fails instead of hanging the suite
    TThread.CreateAnonymousThread(
      procedure
      begin
        Sleep(10000);
        proc.Terminate(0);
      end).Start;
    started := TTestHelpers.TickMs;
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.TimedOut, proc.Status, 'the timeout did not fire');
    Assert.IsTrue(TTestHelpers.TickMs - started < 6000);
  end;
  ```

  (For XE2 the watchdog should be a small TThread descendant rather than an inline anonymous method.) Today the status is `Terminated` after 10 s.
- Suggested fix direction: check the clock before treating a `DataReady` wake-up as "wait on": once the timeout has elapsed, poll only the first `readyFirst` handles with 0 ms and, when none is signalled, take the `WAIT_TIMEOUT` branch.

### WIN-3. A slow target gets a false "Output may be truncated" error: the drain clock starts before the last chunk has been delivered

- Severity: Low
- Category: bug / docs mismatch
- Confidence: Confirmed by reading the code path and at run time
- Location: `Source\VSoft.Process.Windows.pas:364-386` (`IoCompletionCallback` pays off `Unread` before delivery), `:1465-1482` (`HasUnreadOutput`), `:1510-1511` and `:1532-1533` (`WaitForDrain`), `:1429-1430` (the message); README line 196; `docs\WINDOWS_IMPLEMENTATION.md` line 60
- Explanation:
  After a normal exit `RecordUnreadOutput` records how many bytes the child left in each pipe (`Unread`), and `WaitForDrain` only starts the `PipeDrainTimeoutMS` clock once `HasUnreadOutput` is False. The README promises: "after a normal exit, everything the child left in the pipes is delivered before the `PipeDrainTimeoutMS` clock starts, however long the targets take over it".

  But `Unread` is paid off when a read completes, before its data is handed to the targets:

  ```pascal
  if numBytesRead > 0 then
  begin
    EnterCriticalSection(info.Lock);
    if info.ReadCounted then
      Dec(info.Unread, Int64(numBytesRead));
    LeaveCriticalSection(info.Lock);
  end;
  ...
    CompleteRead(info, ioResult, numBytesRead);   // delivers, then queues the next read
  ```

  So the clock starts while the callback is still inside the target's `HandleData` with the last chunk (and it starts immediately when the only data outstanding is a chunk that was already in flight when the child exited, which is never counted). If that one delivery takes longer than `PipeDrainTimeoutMS`, `WaitForDrain` returns False with `stopped = False` and logs:

  `Output may be truncated: stdout/stderr were still open Nms after the process exited and the output it left in the pipes had been read (probably held by a child process it started); the remaining I/O was cancelled`

  Nothing is actually lost (`CloseIO` waits for the callback, which finishes its delivery, and the pipe is empty), but `Errors` now holds a message saying output may be missing and blaming a child process that does not exist. A caller that treats a non-empty `Errors` as a failed or suspect run is misled. With the default 2000 ms it needs a target that takes over 2 s for one chunk; with a short `PipeDrainTimeoutMS` it is easy to hit.

  Run-time proof (`verify.dpr`): `cmd /c echo hello`, `PipeDrainTimeoutMS = 200`, a stdout target that sleeps 800 ms: Status `Exited`, exit code 0, all 7 bytes delivered, and `Errors` holds the truncation message.

  The `DeliverOnRunThread` path is not affected (the run thread delivers inside the drain loop and sees the done event before it checks the deadline).

  Existing coverage: `SlowTarget_ChildExited_AllOutputDelivered` (`Tests\VSoft.Process.Tests.Lifecycle.pas:2043`, 200 ms drain, 400 ms per call) runs exactly this scenario but only asserts the line count; it puts `proc.Errors.Text` in the failure message without asserting on it.
- Proposed test: add to `SlowTarget_ChildExited_AllOutputDelivered` (or a new `SlowTarget_ChildExited_NoTruncationError`):

  ```pascal
  Assert.AreEqual('', Trim(proc.Errors.Text), 'nothing held the pipe open, so nothing may be reported as truncated');
  ```

  The `PerCall_4KB` and `PerCall_64KB` cases fail on it today.
- Suggested fix direction: pay off `Unread` in `CompleteRead` after `DeliverOutput` has returned (or keep a "delivering" flag per stream that `HasUnreadOutput` also checks), so the clock really starts after delivery as the README says.

### WIN-4. ExecuteDetached disables Ctrl+C in the detached child and in everything it starts

- Severity: Low
- Category: API misuse
- Confidence: Confirmed by reading the code path and at run time
- Location: `Source\VSoft.Process.Windows.pas:1698` (comment) and `:1702-1709` (`DoExecuteDetached`)
- Explanation:
  The default detached launch uses `DETACHED_PROCESS or CREATE_NEW_PROCESS_GROUP`. The comment gives the reason: "CREATE_NEW_PROCESS_GROUP: child won't see our Ctrl+C / Ctrl+Break". A child created with `DETACHED_PROCESS` has no console at all, so it can never receive the host's console control events; the flag protects against nothing. Its one real effect is the documented side effect of `CREATE_NEW_PROCESS_GROUP`: Windows calls `SetConsoleCtrlHandler(NULL, TRUE)` on behalf of the new process, which makes it ignore Ctrl+C, and that setting is inherited by every process it creates.

  Consequence: a program started with `ExecuteDetached` that later runs console programs (a launcher, an agent, an IDE, a terminal) passes "ignore Ctrl+C" down to them. In those consoles Ctrl+C no longer reaches the programs' handlers, unless a program re-enables it itself with `SetConsoleCtrlHandler(nil, False)`.

  Run-time proof (`ctrlc.dpr`; the host first clears its own ignore flag, a child with a console registers a handler, calls `GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)` and reports whether the handler ran):

  ```
  Execute -> child                                     : ctrl-c delivered
  ExecuteDetached + DetachedNewConsole -> child        : ctrl-c delivered
  Execute -> helper -> grandchild with a console       : ctrl-c delivered
  ExecuteDetached -> helper -> grandchild with console : ctrl-c IGNORED
  ```

  The `DetachedNewConsole` and credentials launches are not affected: Windows ignores `CREATE_NEW_PROCESS_GROUP` when it is combined with `CREATE_NEW_CONSOLE` (so there the flag does nothing at all).

  Existing coverage: none (`Detached_Default_HasNoConsole` and `DetachedNewConsole_ChildHasAConsole` check the console only).
- Proposed test: `Detached_Default_DoesNotDisableCtrlCForItsChildren`. Helper mode `ctrlc-check <file>`: `SetConsoleCtrlHandler(@Handler, True)`, `GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)`, wait up to 1 s for the handler to set a flag, write `delivered` or `ignored` to the file. Helper mode `spawn-ctrlc-check <file>`: runs the first mode through a plain `IProcess.Execute` (the child gets its own console). The test calls `SetConsoleCtrlHandler(nil, False)` (the test host may itself have been started with Ctrl+C ignored, which would hide the fault), runs the test exe with `--vsp-helper=spawn-ctrlc-check <file>` through `ExecuteDetached`, waits for the file and asserts it says `delivered`. It says `ignored` today.
- Suggested fix direction: drop `CREATE_NEW_PROCESS_GROUP` from the detached flags (neither console mode needs it), or document the Ctrl+C side effect if the process group is wanted for another reason.

### WIN-5. GSpawnLock serialises every launch in the host but protects nothing

- Severity: Low
- Category: locking / performance
- Confidence: Confirmed by reading every launch path; the cost needs a measurement to quantify
- Location: `Source\VSoft.Process.Windows.pas:233-238` (declaration and comment), `:1164-1215` (the only use); `docs\WINDOWS_IMPLEMENTATION.md` line 25
- Explanation:
  The lock is held from "make the child's std handles inheritable" until they are closed after `CreateProcess`, "so a spawn on another thread can never inherit them". Inside the library that cannot happen even without the lock. These are all the places the library creates a process:

  - `DoCreateProcess` with std handles: `bInheritHandles = True` with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (line 1188-1195). The child inherits exactly the handles in its own list, never another thread's.
  - `DoCreateProcess` with no std handles (line 1198) and both `CreateProcessW` calls in `DoExecuteDetached` (lines 1707, 1713): `bInheritHandles = False`.
  - `LaunchWithLogon`: the Secondary Logon service creates the process; nothing is inherited from the host (and it already runs outside the lock).

  The only code that could inherit the handles while they are inheritable is code outside the library calling `CreateProcess(..., bInheritHandles = True)` without a handle list, and that code does not take `GSpawnLock`, so the lock does not help there either.

  What the lock does do is make every `Execute` / `ExecuteAsync` in the process wait for every other one's `CreateProcess` call. `CreateProcess` commonly takes tens of milliseconds and much longer with antivirus scanning or an image on a network share, so a host that starts many children from several threads (a build tool) launches them one at a time. Commit f0a3061 moved the credentials launch out of the lock for exactly this reason.

  Existing coverage: `ConcurrentSpawns_DoNotInheritEachOthersPipes` (`Tests\VSoft.Process.Tests.Lifecycle.pas:904`) proves the property that matters and should keep passing without the lock, because the handle list provides it. `LogonLaunch_DoesNotBlockOtherLaunches` covers the logon path only.
- Proposed test: this is not a fault a test fails on; the proof is the list above. To measure it, time N (say 16) threads each running 20 short children with the lock and with it removed, and keep `ConcurrentSpawns_DoNotInheritEachOthersPipes` as the safety net. A deterministic check that plain launches do not block each other would need a seam like the one `LaunchWithLogon` has (a protected virtual around `VProcCreateProcessW` that a test can make slow), then the same shape as `LogonLaunch_DoesNotBlockOtherLaunches`.
- Suggested fix direction: remove the lock from the Windows launch path (keep the handle list, which is what gives the guarantee), or keep it only if a launch path without a handle list is ever added.

### WIN-6. SafeCloseHandle exchanges only the low 32 bits of a handle on Win64 with XE2 to XE7

- Severity: Low
- Category: bug (latent)
- Confidence: Confirmed (the define was checked with XE2's dcc64); no failure is expected in practice
- Location: `Source\VSoft.Process.Windows.pas:269-273`
- Explanation:

  ```pascal
  {$IFDEF CPU64BITS}
  old := THandle(TInterlocked.Exchange(PInt64(@handle)^, Int64(0)));
  {$ELSE}
  old := THandle(TInterlocked.Exchange(PInteger(@handle)^, 0));
  {$ENDIF}
  ```

  `CPU64BITS` was only added in XE8. A scratch program compiled with XE2's `dcc64` (compiler version 23.0) prints `CPU64BITS NOT defined`, `CPUX64 defined`, `SizeOf(THandle)=8`. So for Win64 on XE2 to XE7 the `{$ELSE}` branch is compiled: a 32-bit exchange on an 8-byte handle. Only the low half is swapped to 0 and the old value is read back through a sign-extending `Integer` cast.

  It happens to work because Windows keeps kernel handle values within 32 bits, and no variable passed to `SafeCloseHandle` in this unit ever holds `INVALID_HANDLE_VALUE` (for that value the variable would be left as `$FFFFFFFF00000000` instead of 0). It is still not what the code says it does, on a compiler the library supports.

  Existing coverage: none can show it (the behaviour is correct for real handle values).
- Proposed test: not provable through behaviour. A compile-time guard is the practical check, for example in the unit: `{$IF SizeOf(THandle) = 8}` selecting the Int64 branch, which is then correct on every compiler and on ARM64EC (where `CPUX64` is not defined).
- Suggested fix direction: select the branch with `{$IF SizeOf(THandle) = 8}` (or `{$IFDEF WIN64}`) instead of `CPU64BITS`.

#### Checked and found correct

Handles and inheritance
- Every error path of `DoCreateProcess`: pipe ends, NUL handle, host std handle copies, the `FileAsStdIn` duplicate, the attribute list (deleted and freed, last error read before `FreeMem`), process and thread handles, the job, the stdin writer and its thread handle are all released, exactly once (the read ends are handed to `InitIOInfo` before it can raise).
- All handles the library creates are non-inheritable (pipes, NUL, events, job, thread, process, the duplicated host handles); only the child's own std handles are made inheritable, de-duplicated before they go in the handle list (a duplicate entry would make `CreateProcess` fail).
- `TVProcStartupInfoExW`, `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` and the `VProc*` imports have the right layout and parameter widths for Win32 and Win64 (112 / 144 bytes for the job structure; `cb` is only set to the extended size together with `EXTENDED_STARTUPINFO_PRESENT`).
- `ReleaseRunResources` closes everything after a normal exit, a kill and an abandoned run; `CloseJobObject` runs at the next start, after a failed start and in `Destroy` (after `inherited`, which has waited for the run).

Output reading
- `QueueAsyncPipeRead` / `CloseIO`: the `Closing` flag and the read are under the same lock, so `CancelIoEx` always sees a read that was started; `CancelThreadpoolIo` is called on every synchronous failure; a synchronous success is still completed through the callback; a zero-byte read is not taken for EOF; `DoneEvent` is set last. This relies on `WaitForThreadpoolIoCallbacks` also waiting for I/O that was started and then cancelled, which is how Windows behaves.
- `Unread` accounting in `RecordUnreadOutput` (apart from finding 3): the lock makes the peek and the counted reads line up, including a write larger than the read buffer.
- `DeliverOnRunThread`: no lost wake-up (`ResetEvent` before the next read is queued), one buffer in flight, pending data delivered by `CloseIO`, done events only set on the run thread, no busy loop in `WaitForDrain` (apart from finding 2).

Waiting, kill and exit codes
- The wait handle order (process, terminate, cancellation, then `DataReady`) and the `WAIT_OBJECT_0 + 1 .. + 3` case cannot be reached by a `DataReady` index.
- The exit code is only read after the process handle is signalled, so 259 (`STILL_ACTIVE`) is never misread; `GetExitCodeProcess` failure is reported, not returned as a code.
- `CREATE_SUSPENDED` on both the plain and the logon launch, so the job is assigned before the child can start anything; assignment failure falls back to the tree kill and, with `KillOnRelease`, to the kept process handle.
- Process id reuse: the tree walk checks creation times, keeps every member open until the kill and the wait are over, and the root is always addressed through a handle.
- Every `GetLastError` in `TWindowsProcess` methods is `Winapi.Windows.GetLastError` or `RaiseLastOSError`; the one bare call (line 300) is in a standalone function. No value is read after an allocating call.

Stdin
- The writer cannot deadlock the run: output is read asynchronously, a blocked `WriteFile` is cancelled with `CancelSynchronousIo`, a source stuck in `GetData` is detached after 1 s, and the write end is closed exactly once (by the writer, or by its destructor when the thread never ran).

Launch details
- Credentials: non-inheritable handles reach the child through the Secondary Logon service (covered by `TProcessLogonTests`); the password copy is scrubbed; `LaunchWithLogon` restores the Win32 error after the scrub. Note only: `SetLastError` is followed by the implicit finalisation of three local strings; FastMM does not touch the last error for those, so this is fragile rather than wrong.
- Batch files: the outer quote pair, the per-argument quoting and the `% ! " CR LF` refusal (path, name, value, separator) leave no route for cmd.exe syntax in a checked argument.
- `DoExecuteDetached`: no handles inherited, breakaway with the ACCESS_DENIED retry, error code kept in `LastError`.
- `VSoft.Process.WinAPI.pas`: the polyfill types match the SDK for the declarations that are used; the compiler-version guards are right for XE2 through 10.3.

Not verified
- Windows 7 specific paths (console pseudo-handles, `CREATE_BREAKAWAY_FROM_JOB` when the host job allows it, non-nested jobs) were read but could not be exercised on this machine.
- A foreign `CreateProcess(bInheritHandles = True)` elsewhere in the host can still inherit the child's std handles during the short time they are inheritable. That is inherent in the handle-list approach and is not something the library can close.

---

## POSIX implementation

### POSIX-1. Tree kill never escalates to SIGKILL for the group once the direct child has died from SIGTERM

- Severity: Medium
- Category: bug / docs mismatch
- Confidence: Confirmed by reading the code path (not run)
- Location: `Source\VSoft.Process.Posix.pas` 1285-1327 (`DoWaitForCompletion`), 1016-1025 (`SignalChild`); contract in `README.md` lines 26, 460, 795-796 and `docs\POSIX_IMPLEMENTATION.md` line 37
- Explanation: On Terminate / cancellation / timeout the wait loop sends SIGTERM to the child's process group and arms a 500 ms deadline for SIGKILL. Both signals are only ever sent from inside the `if not reaped then` block:

  ```pascal
  if not reaped then
  begin
    reaped := TryReap(status, unknownStatus);
    ...
  end;

  if not reaped then
  begin
    if reason = krNone then
    begin
      ...
      if reason <> krNone then
      begin
        SignalChild(SIGTERM);
        killAt := nowMs + cTermGraceMs;
      end;
    end
    else if (not sigKillSent) and (nowMs >= killAt) then
    begin
      SignalChild(SIGKILL);
  ```

  The guard is deliberate (after the group leader has been reaped its pid, and so the group id, may be recycled, so `kill(-pid)` is no longer safe). The consequence is that SIGKILL is only sent if the direct child itself is still alive 500 ms after SIGTERM. The normal case is the opposite: the direct child (a shell, a build driver) has the default SIGTERM action and dies within a millisecond. Sequence:
  1. Stop requested: `SignalChild(SIGTERM)` goes to the whole group, `killAt = now + 500`.
  2. The direct child dies; the pidfd / `EVFILT_PROC` wakes the loop; `TryReap` returns True.
  3. From now on `not reaped` is False, so the `SignalChild(SIGKILL)` branch can never run.
  4. Any group member that ignores or handles SIGTERM (a daemon with `trap '' TERM`, a JVM/node process doing a slow graceful shutdown, anything started with SIGTERM ignored - ignored dispositions survive `execve`) keeps running indefinitely. If it holds stdout/stderr the run additionally sits in the post-kill drain for `PipeDrainTimeoutMS` (2 s default) and logs "Output may be truncated".

  User-visible consequence: `Terminate` returns True and `Status = Terminated`, but part of the tree is still alive. README says "POSIX signals the child's process group" and the platform table says "`SIGTERM` to the child's process group, `SIGKILL` 500 ms later", and README 460 tells users to redirect stdin "when the whole tree must stop". On Windows the same call kills everything in the job, so this is also a silent cross-platform difference.

  Existing coverage: `Terminate_KillsGrandchildProcessTree` (Tests\VSoft.Process.Tests.ProcessE2E.pas 1268) and the Lifetime tests use `spawn-and-wait.sh`, whose grandchild is a plain `sleep` that dies from the SIGTERM. No test has a descendant that ignores SIGTERM (grep for `trap` in Tests finds nothing).
- Proposed test: new fixture `Tests\scripts\spawn-term-ignoring.sh`:

  ```sh
  #!/bin/sh
  # Grandchild ignores SIGTERM (the ignored disposition survives exec).
  (trap '' TERM; exec sleep "${1:-30}") &
  echo "PID=$!"
  sleep 60
  ```

  DUnitX test (POSIX only), modelled on `Terminate_KillsGrandchildProcessTree`:

  ```pascal
  {$IFNDEF MSWINDOWS}
  procedure TProcessE2ETests.Posix_Terminate_KillsDescendantThatIgnoresSigTerm;
  var
    proc : IProcess;
    collector : TPidLineCollector;
    grandPid : Cardinal;
    deadline : Int64;
    alive : boolean;
  begin
    collector := TPidLineCollector.Create;
    grandPid := 0;
    try
      proc := TProcess.Create;
      proc.StartInfo.PipeDrainTimeoutMS := 300;
      TTestHelpers.SetupShellCommand(proc, 'spawn-term-ignoring', ['30']);
      proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
      // stdin redirected: the child always gets its own process group
      proc.WithStdInPipe(TPipeSource.FromString(''));
      Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)), proc.Errors.Text);
      grandPid := WaitForPidLine(collector, 5000); // same polling loop as the existing test
      Assert.IsTrue(grandPid <> 0, 'no PID= line');
      Assert.IsTrue(proc.Terminate, 'Terminate');
      alive := true;
      deadline := TTestHelpers.TickMs + 3000;
      while alive and (TTestHelpers.TickMs < deadline) do
      begin
        alive := kill(pid_t(grandPid), 0) = 0;
        if alive then
          Sleep(50);
      end;
      Assert.IsFalse(alive, 'a group member that ignores SIGTERM survived Terminate');
    finally
      if grandPid <> 0 then
        kill(pid_t(grandPid), SIGKILL); // do not leave it behind when the test fails
      collector.Free;
    end;
  end;
  {$ENDIF}
  ```

  Fails today: the grandchild is alive for the full 30 s. The same test with `StartInfo.TimeoutInMSec := 500` and a synchronous `Execute` proves the timeout path.
- Suggested fix direction: when a kill is in progress (`reason <> krNone`) and the group is in use, do not reap the leader the moment it exits. Detect the exit without reaping (`waitid(P_PID, pid, WEXITED or WNOHANG or WNOWAIT)`, or simply the pidfd / NOTE_EXIT wake-up), send `kill(-pid, SIGKILL)` while the zombie leader still pins the pid and group id, and only then `waitpid`. Whether the group SIGKILL is sent at once or after the remaining grace period is a policy choice; either is safe as long as it happens before the reap.

### POSIX-2. A child with redirected stdin is moved to a background process group even when the host owns a terminal

- Severity: Low (design trade-off with a failure mode that is not documented)
- Category: bug / docs mismatch
- Confidence: Likely (the code path is confirmed; the terminal behaviour is standard POSIX job control but was not run)
- Location: `Source\VSoft.Process.Posix.pas` 785-789 (`PrepareChildSetup`), 315-316 (`RunChild`), 999-1014 (`TryReap`)
- Explanation:

  ```pascal
  setup.UseProcessGroup := (not detached) and (ShouldRedirectStdIn or (isatty(STDIN_FILENO) = 0));
  ```

  The comment above this line correctly notes that a child sharing the terminal must stay in the host's foreground group. That is only applied when stdin is NOT redirected. As soon as any stdin source is attached (README actively recommends `TPipeSource.FromString('')` to get the tree kill), the child calls `setpgid(0, 0)` and becomes a background process group of the host's terminal session, while its stdout/stderr may still be the terminal and `/dev/tty` is still its controlling terminal. Three consequences when the host is a console tool run from an interactive shell:
  1. A child that opens `/dev/tty` to prompt (ssh / git asking for a passphrase, sudo, gpg pinentry-tty) gets SIGTTIN and is stopped. `TryReap` uses `waitpid(pid, WNOHANG)` without `WUNTRACED`, so the stop is invisible: with `TimeoutInMSec = 0` `Execute` never returns, and nothing is logged. (With a timeout the SIGTERM stays pending on the stopped process and only the SIGKILL 500 ms later ends it.)
  2. With `stty tostop` set, the same happens on the first write to an unredirected stdout/stderr (SIGTTOU).
  3. Ctrl+C is delivered to the foreground group only, so it kills the host but not the child. Nothing then stops the child: there is no job object on POSIX, so the tree outlives the host. On Windows the default `KillOnRelease` job ends the tree when the host dies, so a user porting a CLI tool sees orphaned compilers/builds only on Linux/macOS.

  README 808 documents the unredirected case ("the child stays in the host's process group so it can read the terminal and receives Ctrl+C") but not the converse.
- Proposed test: not provable in the normal runner (it needs a controlling terminal). Best practical approach is a manual / pty-harness test: run a small host under `script -qc` (Linux) that executes `sh -c 'read x < /dev/tty'` with `WithStdInPipe(TPipeSource.FromString(''))` and `TimeoutInMSec := 0` from a watchdog thread; assert that `Execute` returns or that `Errors` reports the stop within 3 s. Today the child shows state `T` in `ps -o stat=` and `Execute` blocks. For (3): start the host under a pty, send `\x03`, and assert the grandchild pid no longer exists.
- Suggested fix direction: add `WUNTRACED` to the reap and treat a stopped child as an error that is logged (and optionally continued / killed) rather than waiting silently; document the Ctrl+C / host-death behaviour next to the "redirect stdin for the tree kill" advice, and consider an opt-in `prctl(PR_SET_PDEATHSIG, SIGKILL)` on Linux (a plain syscall, safe between fork and exec) for "die with the host".

### POSIX-3. Closing inherited fds: up to 65,533 `close()` calls per spawn, and fds at 65536 or above are never closed

- Severity: Low
- Category: performance / docs mismatch
- Confidence: Confirmed by reading (the cost per spawn needs runtime measurement)
- Location: `Source\VSoft.Process.Posix.pas` 341-349 (`RunChild`), 791-794 (`PrepareChildSetup`)
- Explanation:

  ```pascal
  maxFd := sysconf(_SC_OPEN_MAX);
  if (maxFd <= 0) or (maxFd > 65536) then
    maxFd := 65536;
  setup.MaxFd := maxFd - 1;
  ...
  if failed then
    for fd := 3 to setup.MaxFd do
      if fd <> errFd then
        __close(fd);
  ```

  `close_range(CLOSE_RANGE_CLOEXEC)` covers Linux 5.11 and later. Everywhere else (every macOS spawn, Linux before 5.11 such as Ubuntu 20.04's 5.4 kernel, and containers whose seccomp profile rejects `close_range`) the child loops over every possible fd number. The loop bound is the soft RLIMIT_NOFILE, which is 1,048,576 or more by default in Docker/systemd services and often raised on macOS build machines, so it hits the 65536 cap: 65,533 system calls between fork and exec for every launch, during which the parent is blocked in `ReadChildError` (so `ExecuteAsync` blocks its caller for that long too). Because of the cap, a host that really has descriptors numbered 65536 or above (large servers do) leaks them into the child, which contradicts README 808 "every file descriptor of the host other than its stdio is closed"; a leaked pipe or socket end is exactly what keeps a peer from seeing EOF. The limit is also read as "current soft limit", so descriptors opened before the host lowered its limit are missed as well.

  Existing coverage: `Posix_HostFileDescriptors_NotInherited` checks five low-numbered `TFileStream` handles only.
- Proposed test: (a) leak: in the test, raise RLIMIT_NOFILE if needed, `fcntl(fd, F_DUPFD, 70000)` a temp-file descriptor (no CLOEXEC), run `ls /dev/fd` through `SetupInlineCommand` with a `ToStringBuilder` target and assert the listing does not contain the high number; skip the test when the dup fails with EINVAL/EMFILE (limit cannot be raised). Fails today on macOS and on Linux kernels before 5.11. (b) cost: with the soft limit raised to 65536 or more, time 20 synchronous runs of `/bin/sh -c "exit 0"` and compare with the same loop at `ulimit -n 256`; report the per-spawn difference.
- Suggested fix direction: bound the loop by the highest descriptor actually open rather than the limit: enumerate `/dev/fd` (macOS) or `/proc/self/fd` (Linux) in the parent, under the spawn lock, before `fork` and pass the maximum (plus the new pipe ends) in `TChildSetup`; keep the sysconf loop only as the fallback when enumeration fails.

### POSIX-4. Exit is only noticed on the next 100 ms slice when the exit wake-up is missing or early

- Severity: Low
- Category: performance
- Confidence: Needs runtime verification (the code path is confirmed; how often the race is lost depends on the kernel)
- Location: `Source\VSoft.Process.Posix.pas` 849-878 (`WatchChildExit`), 952-997 (`WaitForEvents`), 1268-1290 (`DoWaitForCompletion`)
- Explanation: The loop reaps with `waitpid(WNOHANG)` once per pass and otherwise sleeps in `epoll_wait` / `kevent` for up to `cSliceMs = 100`. A dying process closes its descriptors before it becomes reapable, so the usual order of events is: pipe EOF wakes the loop, `DrainFd` closes the read ends, `TryReap` returns "still running" a few microseconds too early, and the next wait has nothing left to wake it except the child-exit watch. That works on Linux 5.3+ (the pidfd stays readable). It does not in three cases:
  1. Linux without `pidfd_open` (kernel before 5.3, or a seccomp profile that returns ENOSYS/EPERM): `FPidFd = -1`, the loop sleeps the full slice.
  2. `CreateEventInstance` failed: `WaitForEvents` always `Sleep(timeoutMs)` first.
  3. macOS: `EVFILT_PROC` is registered `EV_ONESHOT` and `WaitForEvents` discards the event (`continue; // child exit - picked up by TryReap`). XNU posts NOTE_EXIT from `proc_exit` before the process is a waitable zombie, so the `TryReap` that follows can still return 0; the one-shot event is gone and the next wake-up is the 100 ms timeout.

  Consequence: a run of a short-lived program takes up to 100 ms longer than the program did. For callers that launch many small tools (git plumbing, compilers per file) that is the dominant cost. It is latency only; no output or status is lost.

  Existing coverage: `Posix_NoRedirection_DoesNotSpin` and `Posix_DrainWhileGrandchildHoldsStdout_DoesNotSpin` measure CPU, not latency.
- Proposed test: `Posix_ShortLivedChild_CompletesPromptly`: run `/bin/sh -c "exit 0"` 50 times synchronously with a `ToStringBuilder` stdout target, record each elapsed time with `TStopwatch`, sort, and assert the median is below 30 ms. Expected to fail on macOS if (3) holds and on Linux when run under `docker run --security-opt seccomp=<profile without pidfd_open>`; expected to pass on a current Linux kernel. If it passes on macOS arm64 the macOS half of this finding can be dropped.
- Suggested fix direction: treat "NOTE_EXIT received" or "all redirected pipes at EOF" as an exit hint: after it, if `TryReap` still says running, wait in short steps (1, 2, 5, 10 ms) for a bounded time instead of a full slice (or, on NOTE_EXIT, do a blocking `waitpid`, since the exit is already committed).

### POSIX-5. `GSpawnLock` does not do what its comment says and is effectively redundant

- Severity: Low
- Category: locking
- Confidence: Confirmed by reading
- Location: `Source\VSoft.Process.Posix.pas` 236-240 (declaration), 1063-1115 (`DoCreateProcess`), 1442-1478 (`DoExecuteDetached`); `docs\POSIX_IMPLEMENTATION.md` line 13
- Explanation: The lock is "held from pipe creation until the parent has closed the child's pipe ends, so our own concurrent spawns never inherit each other's pipes". It cannot achieve that: the parent-side ends of run A (`outRead`, `errRead`, `inWrite`, `errPipeRead`, later the epoll/kqueue fd and pidfd) stay open in the host for the whole run, so a `fork` for run B at any later time copies them regardless of the lock. What actually keeps them out of B's program is `RunChild` itself, which marks or closes every descriptor at 3 and above before `execve` (lines 341-349), plus the CLOEXEC flag on each of them. That step also covers the macOS `pipe` + `fcntl` window the comment mentions, because a library-forked child closes the not-yet-CLOEXEC ends too; the window only matters for forks made by other code in the host, which do not take this lock. So the lock adds no protection, while it serialises every launch in the process across `PrepareChildSetup` (argv / environment marshalling), `fork` and, for detached launches, pipe creation. It is not a correctness bug.
- Proposed test: none needed to prove a fault. To show that removing it is safe: 8 threads each run 50 iterations of `cat` with a 1 MB `TPipeSource.FromBytes` stdin and a stdout collector; every run must end with `Exited`, exit code 0 and 1 MB echoed within a timeout (a leaked stdin write end would make `cat` hang waiting for EOF). This passes today and must still pass with the lock removed, on Linux and macOS.
- Suggested fix direction: either remove the lock (and correct the comment and the doc paragraph), or keep it only around the macOS `pipe` + `fcntl` pair and state that the close step in `RunChild` is what provides the guarantee.

### POSIX-6. x86-64-only assumptions are not enforced at compile time

- Severity: Low
- Category: API misuse (portability guard)
- Confidence: Confirmed by reading; no currently documented target is affected
- Location: `Source\VSoft.Process.Posix.pas` 64-72, 165-168 (`TPlatformEvent` and its size check), 179-183 (syscall numbers), 38 and 163 (`{$IF DEFINED(LINUX) OR DEFINED(MACOS)}`)
- Explanation: `struct epoll_event` is packed (12 bytes, `data` at offset 4) only on x86-64; on every other Linux architecture it is naturally aligned (16 bytes, `data` at offset 8). The unit hard-codes the packed layout and its guard `{$IF SizeOf(TPlatformEvent) <> 12}` checks the record against itself, not against the target, so it passes on any CPU. If the unit is ever compiled for a non-x86-64 Linux target, `WaitForEvents` reads the fd from the wrong offset, never matches `FStdOutReadFd` / `FStdErrReadFd`, never drains the pipes, and the child blocks on a full pipe: a hang with no diagnostic. The comments say "x86-64 (the only Linux target Delphi supports)", which is true today, but nothing stops the build. Similarly `MACOS` is also defined by the iOS compilers, so the unit and the factory in `VSoft.Process.pas` 779/791 select `TPosixProcess` there, where `fork` is not permitted (the launch fails at run time rather than at compile time). Android does not define `LINUX` (the RTL tests `Defined(LINUX) or Defined(ANDROID)` separately), so it correctly gets no implementation.
- Proposed test: compile-time only. Add the guard and confirm with a compile-only build that Linux64, OSX64 and OSXARM64 still build.
- Suggested fix direction: add `{$IF DEFINED(LINUX) AND NOT DEFINED(CPUX64)} {$MESSAGE ERROR ...} {$IFEND}` next to the size check, and exclude `IOS` where `MACOS` is tested if iOS is not a supported target.

#### Checked and found correct

- Between fork and exec (`RunChild`, `WriteChildErrorAndExit`, the first-stage child in `DoExecuteDetached`): only direct libc/syscall wrappers are called (`setpgid`, `sigprocmask`, `signal`, `sched_setaffinity`, `setpriority`, `dup2`, `fcntl`, `open`, `close`, `syscall`, `chdir`, `execve`, `write`, `_exit`, `setsid`, `fork`); no managed types, strings, memory manager or exceptions. `setup` is passed by reference, `environ` (dlsym on Linux) is captured in the parent, and RTL `errno` is a plain `__error()^` / `__errno_location()^` read. `fork`, not `vfork` or `posix_spawn`, is used.
- Exec-failure reporting pipe: CLOEXEC, 8-byte atomic write, EINTR-safe read, EOF means success; the failed child is reaped; exit code 255 is not confused with a child that returns 255. The detached double fork reaps the first child and still reports grandchild exec failures.
- fd lifetimes on every path of `DoCreateProcess`, `DoWaitForCompletion` and `DoExecuteDetached` (pipe creation failure part-way, fork failure, exec failure, exceptions after fork): every descriptor is closed exactly once via `CloseFd` (exchange-to-minus-one), including the pidfd and the epoll/kqueue fd. Pipe ends that land on 0..2 are moved to 3 or above before `dup2`.
- CLOEXEC: `pipe2(O_CLOEXEC)` on Linux, `F_DUPFD_CLOEXEC`, `epoll_create1(EPOLL_CLOEXEC)`, kqueue + `FD_CLOEXEC`, pidfd; the `FileAsStdIn` copy is CLOEXEC and at 3 or above, and shares the file offset only with a stream that nothing else reads.
- Declarations and constants against the Delphi 13 RTL and the platform headers: `fcntl`, `open`, `ioctl`, `syscall` are `varargs` (required on Apple arm64); `poll` nfds width per platform; 32-byte `kevent`; `timespec` as two 64-bit fields; `O_CLOEXEC`, `EPOLL_*`, `F_DUPFD_CLOEXEC` (1030 / 67), `FIONREAD` (`$541B` / `$4004667F`), `EVFILT_READ`, `EVFILT_PROC`, `NOTE_EXIT`, `EV_ONESHOT`, syscall numbers 434 / 436, `CLOSE_RANGE_CLOEXEC`; `WNOHANG` and the `WIFEXITED` / `WEXITSTATUS` / `WIFSIGNALED` / `WTERMSIG` helpers; `pid_t` is 32-bit on both platforms.
- EINTR: handled in `ReadRetry`, `WaitPidRetry`, `DrainFd`, the stdin writer's `write` and `poll`, and `epoll_wait` / `kevent` (treated as no events).
- SIGPIPE and partial writes: SIGPIPE is ignored host-wide at unit initialisation and restored to default in the child; the writer loops on short writes, waits in `poll(POLLOUT, 100 ms)` on EAGAIN so an abort is noticed, stops on EPIPE and always closes the write end (EOF for the child). `O_NONBLOCK` is set on the host's ends only, which are separate open file descriptions from the child's.
- Reaping and pid reuse: every signal is sent only while the child is unreaped; there is no double `waitpid`; an abandoned (`TerminateOnTimeout = False`) or stuck child is handed to `ReapWhenExited`; ECHILD is reported as an unknown status, not success. `Terminate` from another thread only sets an event, so no other thread ever calls `kill`. `kill(-pid)` cannot hit the host's own group (the id is the child's pid), and falls back to `kill(pid)` when the group does not exist.
- Exit status: normal exit gives `WEXITSTATUS`; a signal we did not send gives `Terminated` with 128 + signal; our own kills give `TerminateExitCode` / `TimedOutExitCode`, as README states.
- Deadlocks and races: stdout and stderr are multiplexed on one thread with non-blocking reads (at most 16 reads per wake per stream); the stdin writer is independent, so a child that fills stdout while reading stdin cannot deadlock the host; `StopStdInWriter` waits a bounded 1 s and holds no lock. The unread-byte accounting (`FIONREAD` at reap) is consistent with pipe FIFO order, so a slow target does not lose the child's own output and a descendant holding the pipe cannot extend the drain past `PipeDrainTimeoutMS`.
- No busy loop after the reap: the pidfd is removed from the epoll set and closed (`UnwatchChildExit`), EOF closes the read ends, and the existing CPU tests cover both cases.
- Memory: argv, the `/bin/sh` fallback argv and envp are allocated with `GetMem` and freed with `FreeMem` in the parent on every normal path (`Environment.ToEnvironArray` uses the same allocator); UTF-8 marshalling adds the terminator correctly.
- Behaviour that differs from Windows but is documented: unredirected streams are inherited, `JobMode` / `HideWindow` / `DetachedNewConsole` / `InheritHostStdHandles` / `DeliverOnRunThread` are ignored, the detached pid is not available, the timeout is not applied during the post-exit drain (same as Windows), `ProcessId` keeps the last pid after the run (same as Windows).

---

## Core lifecycle and threading

### CORE-1. Waits on the main thread never service TThread.Synchronize: Terminate stalls 5 s and returns False, a synchronous Execute hangs for good
- Severity: Medium
- Category: deadlock / docs mismatch
- Confidence: Confirmed by reading the code path (the timings need a run to confirm)
- Location: Source\VSoft.Process.Base.pas:1130-1139 (Terminate), Source\VSoft.Process.Windows.pas:659-670 (CloseIO), 1593 (run wait), README.md:182-202
- Explanation: On Windows pipe targets are called on threadpool threads by default, also for a synchronous `Execute`. The natural way for a VCL/FMX target to touch the UI is `TThread.Synchronize` inside the line delegate (README line 182 recommends Synchronize for event handlers; nothing warns about targets). No wait in the library pumps `CheckSynchronize`:

  ```delphi
  // Base.pas 1136-1138
  if (waitMS = 0) or (not CanWaitForCompletion) then
    Exit(true);
  result := FCompletionEvent.WaitFor(waitMS) = wrSignaled;
  ```

  Case A - async run, `Terminate` from the main thread (a Cancel button):
  1. Threadpool thread T is inside `HandleData`, blocked in `TThread.Synchronize` waiting for the main thread.
  2. Main thread calls `proc.Terminate`. `CanWaitForCompletion` is True (main is not the worker / delivering thread), so it blocks in `FCompletionEvent.WaitFor(5000)`.
  3. The worker kills the child, the drain times out (DoneEvent is never set because T is stuck), then `CloseIO` calls `WaitForThreadpoolIoCallbacks(info.IO, False)` which waits for T.
  4. T waits for main, main waits for the worker, the worker waits for T. Only the 5000 ms bound breaks it: the UI is frozen 5 s, `Terminate` returns False although the child was killed, and the run completes only after main gets back to its message loop.

  Case B - synchronous `Execute` on the main thread with such a target: the main thread sits in `WaitForMultipleObjects(..., INFINITE)` (Windows.pas 1593) and later in `CloseIO`'s `WaitForThreadpoolIoCallbacks`. T is in `Synchronize`. There is no bound here: the application hangs permanently on the first chunk of output. A timeout does not help, since the kill path also ends in `CloseIO`.

  The RTL's own `TThread.WaitFor` handles this by calling `CheckSynchronize` while it waits when on the main thread.
- Existing tests: not covered. The Synchronize tests in Lifecycle.pas (`SyncExecuteOnOtherThread_OnExitSynchronizesLastRelease_NoDeadlock`) cover OnExit on a background thread with the main thread pumping `CheckSynchronize`, not a target and not `Terminate`.
- Proposed test (runs on the main thread, as the DUnitX console runner does):

  ```delphi
  procedure TProcessLifecycleTests.Terminate_OnMainThread_TargetSynchronizes_DoesNotStall;
  var
    proc : IProcess;
    started : Int64;
    elapsed : Int64;
    terminated : boolean;
  begin
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupInlineCommand(proc, 'echo started & ping 127.0.0.1 -n 30 > nul', 'echo started; sleep 30');
    proc.WithStdOutPipe(TPipeTarget.ToDelegate(
      procedure(const data : TBytes; dataLength : NativeUInt)
      begin
        TThread.Synchronize(nil, procedure begin end);
      end));
    Assert.IsTrue(proc.ExecuteAsync, proc.Errors.Text);
    Sleep(500); // the callback is now blocked in Synchronize
    started := TTestHelpers.TickMs;
    terminated := proc.Terminate;
    elapsed := TTestHelpers.TickMs - started;
    // let the run finish whatever happened, so the test does not leak it
    while proc.Status = TProcessStatus.Running do
      CheckSynchronize(10);
    Assert.IsTrue(terminated, 'Terminate returned False although the child was killed');
    Assert.IsTrue(elapsed < 3000, 'Terminate took ' + IntToStr(elapsed) + 'ms');
  end;
  ```
  Fails today with `terminated = False` after about 5000 ms. Case B cannot be a normal test (it hangs); run it on a watchdog thread or just document it.
- Suggested fix direction: when the caller is the main thread, wait in slices and call `CheckSynchronize` between them (in `Terminate`, and ideally in the Windows run wait / `CloseIO` wait for a main-thread synchronous `Execute`), or at minimum document that a target must use `TThread.Queue`, never `Synchronize`, and point main-thread callers at `DeliverOnRunThread`.

### CORE-3. Terminate(waitMS > 0) from another thread during ExecuteAsync's start window returns True at once without waiting
- Severity: Low
- Category: race / docs mismatch
- Confidence: Confirmed by reading the code path
- Location: Source\VSoft.Process.Base.pas:711-716, 758 (InternalStartAsync), 1107-1121 (CanWaitForCompletion), 1130-1139
- Explanation: README (line 644) and the interface comment say `Terminate` returns True "when the run has fully completed", and that only OnStarted / callbacks / the sync Execute thread get the request-only behaviour. `InternalStartAsync` sets `FWorkerThreadId := 0` and resets `FCompletionEvent` at lines 712-714, and only stores the worker's id at line 758, after `StartPipeTargets`, `DoCreateProcess` (seconds for a launch with credentials and a profile load) and the user's OnStarted handler. `CanWaitForCompletion` starts with `(FWorkerThreadId <> 0)`, a test meant for "I am the OnStarted handler" that is true for every thread in that window.
  1. Thread A: `ExecuteAsync` is at line 719 (`DoCreateProcess`) or 734 (`DoOnStarted`).
  2. Thread B: `proc.Terminate`. `IsReadyForRun` is False, the terminate event is set, `CanWaitForCompletion` is False, `Exit(true)`.
  3. Thread B acts on True (README example: `if proc.Terminate then Writeln(proc.ExitCode)`) and reads `Status = Idle/Running`, `ExitCode = $FFFFFFFF`; the child is still alive until the worker starts and kills it.
  A synchronous `Execute` does not have the hole (`FWorkerThreadId` is set before the completion event is reset).
- Existing tests: `Terminate_FromOnStarted_AsyncExecute_DoesNotStall` covers the handler's own call only.
- Proposed test: an OnStarted handler (it runs on thread A inside `ExecuteAsync`) starts a thread B that does `FResult := process.Terminate(2000); FStatusAtReturn := process.Status;`, and the handler waits for B (`B.WaitFor`). Assert `not (FResult and (FStatusAtReturn in [TProcessStatus.Idle, TProcessStatus.Running]))`, ie True must mean completed. Today B returns True immediately with `Running`. With a fix B blocks its 2000 ms and returns False (the run can't complete while A is in the handler), which satisfies the assertion.
- Suggested fix direction: record the starting thread separately (`FStartThreadId` already exists and is otherwise unused) and make "cannot wait" mean `currentId = FStartThreadId` while no worker exists, rather than "no worker exists".

### CORE-4. A Terminate aimed at one run can kill the next run (check-then-set on the terminate event)
- Severity: Low
- Category: race
- Confidence: Confirmed by reading the code path; needs a seam to reproduce
- Location: Source\VSoft.Process.Base.pas:1132-1134 (Terminate), 680-681 and 713-714 (start), 797-808 (CompleteRun)
- Explanation: `Terminate` checks `IsReadyForRun` and then sets `FTerminateEvent` as two separate steps. The event is shared by all runs of the object and is reset when a run starts.
  1. Thread B (`Terminate`): `IsReadyForRun` returns False - run 1 is in progress. B is preempted before line 1134.
  2. Worker: run 1 completes (`CompleteRun` sets the completion event).
  3. Thread A, or the OnExit handler (README: "a handler may start the next run"; test `RestartFromOnExit_SecondRunCompletes`): starts run 2, lines 680-681 reset both events.
  4. Thread B: `FTerminateEvent.SetEvent`. Run 2 is killed with `Terminated` / `TerminateExitCode` although nobody asked for that, and B then waits on run 2's completion.
  The window is small, but restart-from-OnExit loops (watchdogs, retry loops) are exactly where a stale stop request arrives late. `Destroy` (line 451) has the same shape but only for the unsupported no-interface use.
- Existing tests: none.
- Proposed test: not deterministic without a hook. Best practical approach is a test seam (a protected virtual called between the check and the set, overridden in a test subclass of `TWindowsProcess` to block until run 2 has started), then assert run 2 ends `Exited` with the child's own code. A stress loop (short child, restart from OnExit, another thread calling `Terminate(0)` continuously, counting `Terminated` runs that were started after the last Terminate returned) is the fallback.
- Suggested fix direction: give each run a generation number; `Terminate` captures it with the check and the worker ignores a terminate request stamped with an older generation (or guard check + set + start-reset with one small lock).

### CORE-5. A faulted target attached to both streams keeps receiving the other stream
- Severity: Low
- Category: bug / docs mismatch
- Confidence: Confirmed by reading the code path
- Location: Source\VSoft.Process.Base.pas:26-29, 382-392 (SnapshotTargets), 909-943 (DeliverTo), 1028-1029
- Explanation: README line 192 and the `IPipeTarget` comment promise that a target that raises "receives no more data for that run". The `Faulted` flag lives in the per-stream slot arrays `FRunStdOut` / `FRunStdErr`, which are snapshotted separately, so the same target object has two independent flags:

  ```delphi
  FRunStdOut := SnapshotTargets(FStdOutTargets);
  FRunStdErr := SnapshotTargets(FStdErrTargets);
  ...
  slots[i].Faulted := true;   // only the slot of the stream being delivered
  ```

  A target attached with both `WithStdOutPipe` and `WithStdErrPipe` (explicitly supported, started and Done once) that raises on a stdout chunk is marked faulted for stdout only and is still called for every stderr chunk, in whatever broken state the exception left it; if it raises again a second, differently worded error is logged.
- Existing tests: `ThrowingTarget_SyncExecute_KeepsDrainingAndLogs` / `..._AsyncExecute_...` attach the thrower to stdout only; the shared-target tests do not raise. Not covered.
- Proposed test:

  ```delphi
  // TThrowOnStdOutTarget implements IPipeTarget + IStreamAwarePipeTarget:
  //   HandleStreamData(False, ...) -> Inc(OutCalls); raise Exception.Create('boom');
  //   HandleStreamData(True, ...)  -> Inc(ErrCalls);
  procedure TProcessLifecycleTests.ThrowingTarget_OnBothStreams_GetsNoMoreDataFromEither;
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
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual(1, target.OutCalls);
    Assert.AreEqual(0, target.ErrCalls, 'a faulted target must get no more data this run');
  end;
  ```
  Fails today with `ErrCalls = 1`.
- Suggested fix direction: keep one fault flag per started target (for example alongside `FStartedTargets`, with each slot holding its index) instead of one per stream slot; or correct the README if per-stream isolation is intended.

### CORE-6. A pipe target / source whose Done raises a non-Exception object leaves the run permanently "in progress"
- Severity: Low
- Category: bug
- Confidence: Confirmed by reading the code path
- Location: Source\VSoft.Process.Base.pas:1067-1094 (StopPipeTargets), 773-794 (RunWorker), 810-819 (AbortStart)
- Explanation: `StopPipeTargets` is commented "Never raises", but both handlers are `on E : Exception do` only. `DeliverTo` (lines 930-941) does handle the `else` case, so the gap is specific to Done. If a target's `Done` raises anything not derived from `Exception`:
  1. `RunWorker`'s `finally` block (782-789) is left at `StopPipeTargets`; `CompleteRun(outcome)` is skipped.
  2. `FCompletionEvent` is never set and `FStatus` stays `Running`. Every later `Execute*` raises "Process is already running", `Terminate` returns True/False without effect, `CompletionHandle` waiters never wake.
  3. The remaining targets' and the stdin source's `Done` are skipped too, and on an async run the object escapes the worker thread's procedure.
  `AbortStart` has the same hole on a failed launch.
- Existing tests: none (the throwing targets raise `Exception` from `HandleData`).
- Proposed test: a target whose `Done` does `raise TObject.Create;`, sync `Execute` of a short child inside `try ... except end`, then assert `proc.Status <> TProcessStatus.Running` and that a second `proc.Execute` does not raise `EInvalidOpException`. Both fail today.
- Suggested fix direction: add the `else` branch (as in `DeliverTo`) to both handlers in `StopPipeTargets`, and/or make `CompleteRun` / the completion event unconditional with a nested try/finally.

### CORE-7. ExecuteDetached is refused by a validation rule the README says does not apply to it, and a refused detached launch leaves ExitCode / TimedOut raising
- Severity: Low
- Category: docs mismatch / bug
- Confidence: Confirmed by reading the code path
- Location: Source\VSoft.Process.Base.pas:555-576 (ExecuteDetached), 1161-1165 (ValidateStartUpBuilder), 617-622, 654-659
- Explanation: README line 126: for `ExecuteDetached` "the configured pipes, `JobMode` and timeout are ignored". `ExecuteDetached` calls the shared `ValidateStartUpBuilder`, which fails when `TerminateOnTimeout = False` and `JobMode = KillOnRelease` (the default job mode). A template configured with `TerminateOnTimeout := False` that is then launched detached returns False with "TerminateOnTimeout = False needs JobMode KillOnTerminate or NoJob...", about two settings a detached launch never uses.
  Separately, `FStartMode := TProcessStartMode.Detached` is assigned before validation (line 563), so after any failed `ExecuteDetached` (nothing launched, `Status = Idle`) `proc.ExitCode` and `proc.TimedOut` raise `EInvalidOpException` ("Cannot get exit code from detached process") instead of returning `$FFFFFFFF` / False as README line 130 describes for a failed `Execute*`.
- Existing tests: `TimeoutWithoutTerminate_WithKillOnRelease_IsRejected` (Lifetime.pas:614) covers `Execute` only; `Detached_ThenExecute_SameObjectReusable` covers the success path.
- Proposed test:

  ```delphi
  procedure TProcessLifecycleTests.Detached_IgnoresTerminateOnTimeoutAndJobMode;
  var
    proc : IProcess;
  begin
    proc := TProcess.Create;
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['1']);
    proc.StartInfo.TerminateOnTimeout := False; // JobMode stays KillOnRelease
    Assert.IsTrue(proc.ExecuteDetached, proc.Errors.Text);
  end;

  procedure TProcessLifecycleTests.Detached_ValidationFails_ExitCodeDoesNotRaise;
  var
    proc : IProcess;
  begin
    proc := TProcess.Create; // no executable
    Assert.IsFalse(proc.ExecuteDetached);
    Assert.AreEqual<Cardinal>($FFFFFFFF, proc.ExitCode);
  end;
  ```
- Suggested fix direction: skip the TerminateOnTimeout / JobMode rule for a detached launch (pass the mode to validation), and only set `FStartMode := Detached` once the launch has succeeded.

#### Checked and found correct

- Double start: `ClaimRun` (CAS on `FRunClaim` + completion-event check) correctly refuses a second `Execute*` from another thread at every point of the start sequence, including during `ExecuteDetached`; the claim is released on every path (pre-cancelled token/event, validation failure, raise from `StartPipeTargets` / `DoCreateProcess`). Covered by `ConcurrentStart_SameProcess_SecondIsRefused` and `Execute_WhileRunning_Raises`.
- Publication order: `FExitCode` / `FTimedOut` are written before `FStatus` (interlocked), `FStatus` before `FCompletionEvent`, and all of it only after `DoWaitForCompletion` has drained and `StopPipeTargets` has called every `Done`. The exit code is never visible before the output is delivered; OnExit fires after.
- Lifetime of an async run: the worker closure's `selfRef` and the sync run's `selfRef` keep the object alive through OnExit; `keepAlive` for a detached stdin writer's reference is released last. If the final release happens on the worker thread, `Destroy` finds the completion event already set and does not wait on itself. No cycle through the anonymous thread (the closure nils `selfRef`, the thread is FreeOnTerminate).
- Re-run from OnExit (sync and async): cancellation references are cleared and `FWorkerThreadId` zeroed before the completion event is set, and nothing in `RunWorker` / `StartRun` touches fields after the point where the next run (or `Destroy`) may take over.
- Terminate from OnStarted, from a pipe target (threadpool or run thread with `DeliverOnRunThread`), from a stdin source and from `Start` / `Done` never waits on itself: `FWorkerThreadId`, `FDeliveringThreadId` and `FStdInWriterThreadId` cover each case, and the unlocked reads are sound (a thread can only match an id it stored itself). `FDeliveryLock` is released before any wait, so a callback calling back into the process cannot deadlock on it.
- `TStdInWriter`: `FOwnerLock` correctly serialises `Execute`'s tail against `Detach`; the owner reference is dropped after `FFinished` is set; a left-behind writer cannot clear a later run's `FStdInWriterThreadId` (compare-exchange on its own id). The `Int64(FStdInWriterThreadId)` cast is same-size on every POSIX target in the dspec (64-bit only).
- User callback exceptions: `HandleData` (Exception and non-Exception), OnStarted, OnExit (direct and queued) are all contained and logged; `DoWaitForCompletion` exceptions are logged and the run still completes.
- `MarshallEventsToMainThread` uses `TThread.Queue` (never Synchronize), with the queued closure holding an `IProcess` reference; it cannot deadlock against a main thread blocked in `Terminate`.
- No `GetTickCount` arithmetic anywhere in the core or the wait loops (`TStopwatch` with Int64 throughout); the Windows run timeout and the POSIX loop measure one overall clock, not per stage; `TimeoutInMSec = 0` maps to INFINITE and the `Cardinal` subtraction at Windows.pas:1592 is guarded.
- Failed launch: `AbortStart` calls `Done` on exactly the targets whose `Start` succeeded, leaves `Status = Idle`, `ExitCode = $FFFFFFFF`, and re-signals the completion event - matching README lines 130-132. Start-time exceptions (missing `FromFile` / `FileAsStdIn` file, pipe creation) propagate as documented.
- `Clone` deep-copies the four builders and nothing else, as documented; `CreateClone` goes through the virtual `Create`, so platform fields are initialised.
- Use of a process object without any interface reference (RefCount 0) is unsafe in several places (stdin writer's `FOwnerRef`, `handler(Self)`), but the destructor comment declares that unsupported and `TProcess.Create` only hands out `IProcess`, so it is not reported.
- Performance: no busy loops in the core. Per-chunk cost is one critical section and one `Supports` call per target (negligible at 64 KB chunks). The 50 ms / 100 ms slice polling lives in the platform units (other reviewers).

---

## Pipe targets and sources

### PIPE-1. Line target raises ERangeError at the 1 MB forced line break when compiled with range checking

- Severity: Medium
- Category: bug
- Confidence: Confirmed by reading the code path (the failure only occurs when the unit is compiled with `{$R+}`; not run)
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:963-992` (`TLinePipeTargetBase.ForceLineBreak`, line 983)
- Explanation: When a line target has buffered `cMaxPendingLineBytes` (1 MB) with no LF, `ForceLineBreak` decodes the pending bytes and then shifts whatever was not decoded to the front of the buffer:

  ```pascal
  decoded := DecodeLenient(FEncoding, state.PendingBytes, 0, decodeLen);
  Move(state.PendingBytes[decodeLen], state.PendingBytes[0], totalLen - decodeLen);
  SetLength(state.PendingBytes, totalLen - decodeLen);
  ```

  In the normal case the whole buffer is decodable (it does not end in a partial character or in CRs), so `decodeLen = totalLen = Length(state.PendingBytes)`. `state.PendingBytes[decodeLen]` is then one past the last element. With range checking off this is harmless (the count is 0), but with `{$R+}` a dynamic array index is checked and this raises `ERangeError` before the text is emitted. The other two places that do the same shift are guarded (`if decodeLen < totalLen` at line 923, `if totalLen > decodeLen` at line 652); this one is not.

  The source units contain no `{$R-}` directive, so they take the project's setting. The runtime packages switch it off (`{$RANGECHECKS OFF}` in the `.dpk` files), but every demo project compiles the library source directly with `<DCC_RangeChecking>true</DCC_RangeChecking>` in Debug (for example `Demos\PipeTargets\PipeTargets.dproj:84` with `DCCReference Include="..\..\Source\VSoft.Process.PipeTarget.Classes.pas"`), and so does any user project that puts `Source` on its search path with range checking on.

  Consequence: the exception escapes `HandleData`, `TProcessBase.DeliverTo` logs "stdout pipe target raised ERangeError" and marks the target faulted, so the target gets no more output for the rest of the run. Trigger: any output with 1 MB between line feeds - a progress meter redrawn with lone CRs for a long time, a minified JSON blob, binary noise.
- Existing tests: `LineTarget_LineWithoutLF_EmittedAtCap`, `LineTarget_LineFeedAfterCap_NoEmptyLine` and `LineTarget_CapOnOneStream_OtherStreamEmptyLineKept` all hit exactly this path (`decodeLen = totalLen`), but `Tests\VSoft.Process.Tests.dproj` does not enable range checking, so they pass.
- Proposed test: no new test body is needed - turn on range checking (and overflow checking) for the Debug configuration of `Tests\VSoft.Process.Tests.dproj`, which is what the demos already do. `LineTarget_LineWithoutLF_EmittedAtCap` then fails with `ERangeError`. If the project setting must stay off, a dedicated test cannot force `{$R+}` into another unit, so the practical alternative is a CI build of the test project with `-$R+ -$Q+` on the command line.
- Suggested fix direction: guard the `Move` with `if decodeLen < totalLen` as the other two sites do. Consider compiling the test project with range and overflow checks on so this class of bug is caught.

### PIPE-2. TPipeTarget.ToAll: a child whose Start raises leaves the earlier children started (file left open and locked, later runs stop truncating it)

- Severity: Medium
- Category: handle leak
- Confidence: Confirmed by reading the code path
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:1099-1108` (`TMultiPipeTarget.Start`), with `TFilePipeTarget.Start` / `Done` at 520-553 and `TProcessBase.StartPipeTargets` at `Source\VSoft.Process.Base.pas:1011-1024`
- Explanation: `TMultiPipeTarget.Start` starts its children in order with no rollback:

  ```pascal
  for i := 0 to Length(FTargets) - 1 do
    FTargets[i].Start;
  ```

  The process only records a target in `FStartedTargets` after its `Start` returned (`slots[i].Target.Start; FStartedTargets.Add(...)`), and `StopPipeTargets` only calls `Done` on recorded targets. So when child N raises, the ToAll target itself is never recorded, its `Done` is never called, and children 0..N-1 never get `Done`.

  Concrete sequence: `ToAll([TPipeTarget.ToFile('build.log'), TPipeTarget.ToFile('Z:\missing\dir\copy.log')])`.
  1. Run 1: `build.log` is created and opened (`FStartCount = 1`), the second `ToFile` raises `EFCreateError`, `Execute` raises (as the README says a failing `Start` does).
  2. `build.log` stays open with `fmShareDenyWrite` for as long as the target object lives (the process keeps targets forever), so nothing else can write, rename or delete it.
  3. If a later run succeeds (the directory now exists): `TFilePipeTarget.Start` does `Inc(FStartCount)` (now 2) and returns early because `FFileStream <> nil` - the file is not truncated. `Done` only takes the count back to 1, so the file is still not closed after the run, and from then on every run appends to the same open handle. `ToFile(name, False)` has silently become append mode with a permanent lock.

  For comparison, the same failure with the two file targets attached separately (`WithStdOutPipe` twice) is handled correctly: the first is in `FStartedTargets` and gets its `Done` from `AbortStart`. The README (line 192) promises "`Start` and `Done` are called once per run ... (also when the launch itself then fails)".
- Existing tests: none. `MultiTarget_*` tests cover fan-out, encoding forwarding and a child raising in `HandleData`, not in `Start`.
- Proposed test (direct unit test, no process needed), in `VSoft.Process.Tests.PipeTarget.pas`:

  ```pascal
  type
    TStartRaisesTarget = class(TInterfacedObject, IPipeTarget)
    protected
      procedure Start;
      procedure HandleData(const data : TBytes; dataLength : NativeUInt);
      procedure Done;
    end;

  procedure TStartRaisesTarget.Start;
  begin
    raise EInOutError.Create('cannot start');
  end;

  procedure TPipeTargetTests.MultiTarget_ChildStartRaises_EarlierChildrenAreDone;
  var
    multi : IPipeTarget;
    fileName : string;
    probe : TFileStream;
    raised : boolean;
  begin
    fileName := TTestHelpers.TempFileName('vsoft_multi_start_', '.log');
    try
      multi := TPipeTarget.ToAll([TPipeTarget.ToFile(fileName), TStartRaisesTarget.Create]);
      raised := false;
      try
        multi.Start;
      except
        on EInOutError do
          raised := true;
      end;
      Assert.IsTrue(raised, 'The child''s Start exception should propagate');
      // The file target was started before the failure: it must have been
      // closed again, so an exclusive open succeeds while multi is alive.
      probe := TFileStream.Create(fileName, fmOpenReadWrite or fmShareExclusive);
      probe.Free;
    finally
      multi := nil;
      DeleteFile(fileName);
    end;
  end;
  ```

  Today the exclusive open raises `EFOpenError` (sharing violation). An end-to-end variant: attach the same ToAll to a process, assert `Execute` raises, then assert the first file can be opened exclusively while `proc` is still referenced.
- Suggested fix direction: in `TMultiPipeTarget.Start`, on an exception call `Done` on the children already started (each in its own try/except) and re-raise.

### PIPE-3. Default decoding is the ANSI code page, but console children on Windows write in the OEM / console code page

- Severity: Medium
- Category: bug (wrong encoding default; documented, so partly a design decision)
- Confidence: Likely - needs runtime verification on a machine where `GetACP <> GetOEMCP` (this dev machine has both at 65001, which hides it)
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:656-660` (`TStringBuilderPipeTarget.Start`), `994-1002` (`TLinePipeTargetBase.ResolveEncoding`); child creation flag at `Source\VSoft.Process.Windows.pas:1133` (`CREATE_NEW_CONSOLE`)
- Explanation: With no explicit encoding and no `StartInfo.OutputEncoding`, the line targets and `ToStringBuilder` fall back to `TEncoding.Default`:

  ```pascal
  if FEncoding = nil then
    FEncoding := TEncoding.Default;
  ```

  On Windows that is the ANSI code page (1252 on a Western system). The child is always given a brand new console (`CREATE_NEW_CONSOLE`), whose output code page is the OEM code page (437 / 850 on the same system). `cmd.exe` built-ins (`echo`, `dir`, `type`, `set`) and most classic console tools (`ping`, `ipconfig`, `net`, `sc`, `robocopy`) write redirected output in the console / OEM code page, not ANSI. So the out-of-the-box result for any non-ASCII character is mojibake: `cmd /c echo e-acute` writes byte `$82` (CP 850), which decodes as U+201A (low single quote) under CP 1252. Path names with accents from `dir`, localised error messages and so on are all affected. The README quick start uses exactly this combination (`cmd.exe /c echo ...` with `TEncoding.Default`).

  The README documents the default ("decode with `TEncoding.Default` (the ANSI code page on Windows)"), so the code matches the docs; the issue is that the default is the wrong one for the most common kind of child, and the tests cannot see it because this machine's ANSI and OEM code pages are both UTF-8.
- Existing tests: none that would detect it (ASCII-only fixtures, or explicit `TEncoding.UTF8`).
- Proposed test (end-to-end, Windows only; meaningful only when the two code pages differ, so it should report itself as skipped otherwise):

  ```pascal
  procedure TProcessE2ETests.DefaultEncoding_CmdEcho_NonAsciiRoundTrips;
  var
    proc : IProcess;
    output : TStringBuilder;
    expected : string;
  begin
    if GetACP = GetOEMCP then
    begin
      Assert.Pass('ANSI and OEM code pages are the same on this machine');
      exit;
    end;
    expected := string(WideChar($E9)); // e-acute, present in 437, 850 and 1252
    output := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.Executable := 'cmd.exe';
      proc.CommandLine.Add('/c', TQuoted.qtNone);
      proc.CommandLine.Add('echo ' + expected, TQuoted.qtNone);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output)); // no encoding
      Assert.IsTrue(proc.Execute);
      Assert.AreEqual(expected, Trim(output.ToString));
    finally
      output.Free;
    end;
  end;
  ```

  A deterministic unit-level variant is not possible because the bug is the choice of default, not the decoder.
- Suggested fix direction: on Windows default to the OEM code page (`TEncoding.GetEncoding(GetOEMCP)`, cached) when neither an explicit encoding nor `StartInfo.OutputEncoding` is given, or at least call the mismatch out in the README next to the default-encoding note and in the quick start.

### PIPE-4. README says a raising target inside ToAll stops the whole group; the code (and its tests) keep the siblings running

- Severity: Low
- Category: docs mismatch
- Confidence: Confirmed by reading the code path
- Location: `README.md:192` and `README.md:688`; `Source\VSoft.Process.PipeTarget.Classes.pas:1110-1132` (`TMultiPipeTarget.Fan`)
- Explanation: The README states "Targets combined with `TPipeTarget.ToAll` count as one target: if one of them raises, the whole group stops" and, in the fan-out example, "with `ToAll`, a target that raises stops the whole group". The implementation does the opposite since the sibling-isolation change:

  ```pascal
  // Each target in its own frame: one that raises must not starve its
  // siblings. Its exception is kept and raised from Done.
  ...
  except
    FFaulted[i] := true;
    if FFirstDataError = nil then
      FFirstDataError := TObject(AcquireExceptionObject);
  end;
  ```

  `Fan` never lets the exception out, so the process never marks the ToAll target as faulted; only the failing child stops receiving data. Two further user-visible differences from what the README implies: the failure is not in `Errors` until the run ends (it is re-raised from `TMultiPipeTarget.Done`), and it is logged as "Pipe target Done raised ..." although `Done` did not fail.
- Existing tests: `MultiTarget_RaisingChild_SiblingsKeepReceiving` and `SharedToAll_RaisingChild_SiblingStillSeesBothStreams` assert the code's behaviour, so the README is the stale side.
- Proposed test: none needed for the behaviour. Optionally extend `MultiTarget_RaisingChild_SiblingsKeepReceiving` to assert that `multi.Done` raises the child's original exception class, so the reporting path is pinned too.
- Suggested fix direction: correct both README sentences (siblings keep receiving; the failure is reported in `Errors` when the run ends).

### PIPE-5. A line target whose callback raised is called again from Done, with the failed line glued to an unrelated tail; a raise there also skips the stderr flush

- Severity: Low
- Category: bug
- Confidence: Confirmed by reading the code path
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:730-738` (`EndLine` in `ProcessText`), `802-825` (`FlushStream`), `827-840` (`Done`)
- Explanation: `EndLine` clears the current line only after the callback returns:

  ```pascal
  if (state.CurrentLine <> '') or (not state.LineBroken) then
    OutputLine(state.CurrentLine);   // user callback raises here
  state.CurrentLine := '';
  ```

  and `ProcessStreamData` has already removed the decoded bytes from `PendingBytes` and kept only the tail after the last LF. So when the callback raises, `CurrentLine` still holds the line that failed, the remaining lines of that read are dropped, and the unterminated tail stays pending. The process marks the target faulted ("receives no more data this run"), but `Done` is still called on it, and `FlushStream` then decodes the tail, appends it to the stale `CurrentLine` and calls the callback again.

  Example: one read of `'a'#10'b'#10'c'`, callback raises on `'a'`. At `Done` the callback is invoked with `'ac'` - a line the child never wrote - after the README said the target would receive nothing more. If the callback raises again (likely, it is the same failing code), the exception leaves `FlushStream(FStreams[false])`, so `FlushStream(FStreams[true])` never runs (a target shared by stdout and stderr loses the stderr tail) and the "forget the injected encoding" block at the end of `Done` is skipped, leaving `FEncoding` pointing at the `StartInfo.OutputEncoding` object of this run for the next one. The same applies to a line target inside `ToAll` (`TMultiPipeTarget.Done` calls `Done` on faulted children).
- Existing tests: none (`E2E` raising-target tests use byte targets; no test raises from a line callback and then checks `Done`).
- Proposed test (direct unit test):

  ```pascal
  type
    TRaiseOnFirstLine = class
    public
      Lines : TStringList;
      constructor Create;
      destructor Destroy;override;
      procedure OnLine(const line : string);
    end;

  procedure TRaiseOnFirstLine.OnLine(const line : string);
  begin
    Lines.Add(line);
    if Lines.Count = 1 then
      raise Exception.Create('boom');
  end;

  procedure TPipeTargetTests.LineTarget_CallbackRaised_DoneDoesNotCallItAgain;
  var
    target : IPipeTarget;
    capture : TRaiseOnFirstLine;
    payload : TBytes;
    raised : boolean;
  begin
    capture := TRaiseOnFirstLine.Create;
    try
      target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
      target.Start;
      payload := MakeBytes('a'#10'b'#10'c');
      raised := false;
      try
        target.HandleData(payload, Length(payload));
      except
        on Exception do
          raised := true;
      end;
      Assert.IsTrue(raised);
      target.Done;
      Assert.AreEqual(1, capture.Lines.Count, 'A faulted line target must not be called again from Done');
    finally
      capture.Free;
    end;
  end;
  ```

  Today `Lines` ends up as `a`, `ac`.
- Suggested fix direction: clear `CurrentLine` before calling `OutputLine` (take a local copy), remember that the target faulted so `Done` discards instead of flushing, and make `Done` flush stderr and reset the injected encoding in a `try..finally`.

### PIPE-6. A byte order mark at the start of the output is kept as U+FEFF in the first line / the StringBuilder

- Severity: Low
- Category: bug
- Confidence: Confirmed by reading the code path (no BOM handling exists anywhere in the unit)
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:413-446` (`DecodeLenient`), `895-937` (`TLinePipeTargetBase.ProcessStreamData`), `629-654` (`TStringBuilderPipeTarget.ProcessStreamData`)
- Explanation: The first bytes of a stream are decoded like any others. `MultiByteToWideChar(CP_UTF8, ...)` turns `EF BB BF` into U+FEFF, and `DecodeUtf16Lenient` copies `FF FE` through as U+FEFF, so the first line delivered to a line callback is `#$FEFF + 'text'` and `TStringBuilder.ToString` starts with the invisible character. Comparisons such as `line = 'OK'`, `StartsText`, `StrToInt(line)` or a JSON parse of the captured text then fail in a way that is hard to see in a debugger. Children that do this: `cmd /c type` of a file saved with a BOM, Windows PowerShell 5.1 once `[Console]::OutputEncoding` is set to UTF-8, and .NET tools that write through a `StreamWriter` with the default `UTF8Encoding(true)`. `ProcessText` drops control characters below U+0020 but U+FEFF is not one of them. The README describes the line splitting in detail and does not mention a BOM.
- Existing tests: none (no test feeds a preamble; a grep for BOM / FEFF / preamble in `Tests\VSoft.Process.Tests.PipeTarget.pas` finds nothing).
- Proposed test (direct unit test, reusing the existing `FeedLines` helper; split after the first BOM byte to cover the boundary case as well):

  ```pascal
  procedure TPipeTargetTests.LineTarget_Utf8Bom_NotPartOfFirstLine;
  begin
    Assert.AreEqual('first|second',
      FeedLines(TEncoding.UTF8, [TBytes.Create($EF), TBytes.Create($BB, $BF, Ord('f'), Ord('i'), Ord('r'), Ord('s'), Ord('t'), 10),
                                 MakeBytes('second'#10)]));
  end;
  ```

  plus the same for `TEncoding.Unicode` (`FF FE`) and for `ToStringBuilder`. Today the first line is `#$FEFF'first'`.
- Suggested fix direction: per stream, skip the encoding's preamble (`FEncoding.GetPreamble`) when it is the first thing decoded after `Start`, or document that a BOM is passed through.

### PIPE-7. ToStringBuilder's split-character guard does not cover GB18030 on Windows, or any non-UTF-8 multi-byte code page on POSIX

- Severity: Low
- Category: bug
- Confidence: Confirmed by reading for POSIX (the DBCS branch is inside `{$IFDEF MSWINDOWS}`); Likely for GB18030 on Windows (depends on `IsDBCSLeadByteEx(54936, ...)` returning False for every byte, which is how the API is documented for non-DBCS code pages - needs runtime verification)
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:448-486` (`CompleteCharLength`)
- Explanation: `TStringBuilderPipeTarget` decodes each read as it arrives and relies on `CompleteCharLength` to hold back the bytes of a character that is cut by the read boundary. That function knows UTF-8, UTF-16 and, on Windows only, two-byte DBCS code pages:

  ```pascal
  else
    {$IFDEF MSWINDOWS}
    if encoding.IsSingleByte then
      exit;
    ...
      if IsDBCSLeadByteEx(codePage, data[i]) then
    ...
    {$ENDIF}
  end;
  ```

  - POSIX: for any other multi-byte encoding (Shift-JIS, EUC-KR, GBK, Big5 via `TEncoding.GetEncoding`) the function returns `dataLength`, so a character split across two reads is decoded as two broken halves.
  - Windows: GB18030 (code page 54936, the mandatory encoding for software sold in China) has 2-byte and 4-byte characters and is not a DBCS code page for `IsDBCSLeadByteEx`, so nothing is held back and split characters are corrupted. A 4-byte character would be cut wrongly even if the lead-byte test worked, because the walk assumes two bytes.

  The line targets are not affected in normal operation (they decode only up to an LF, and `$0A` is never a trail byte in these encodings); they share the problem only at the 1 MB forced break, which uses the same function.
- Existing tests: `StringBuilderTarget_UTF8SplitAcrossReads` and `StringBuilderTarget_UTF16SplitAcrossReads` only. No DBCS / GB18030 test.
- Proposed test (direct unit test, Windows):

  ```pascal
  procedure TPipeTargetTests.StringBuilderTarget_Gb18030SplitAcrossReads;
  var
    encoding : TEncoding;
    target : IPipeTarget;
    sb : TStringBuilder;
    full : TBytes;
    part1 : TBytes;
    part2 : TBytes;
    splitAt : integer;
    text : string;
  begin
    // U+4E2D is 2 bytes in GB18030, U+20AC (euro) is 2, U+1F60A is 4.
    text := 'a' + #$4E2D + #$D83D#$DE0A + 'b';
    encoding := TEncoding.GetEncoding(54936);
    sb := TStringBuilder.Create;
    try
      full := encoding.GetBytes(text);
      for splitAt := 1 to Length(full) - 1 do
      begin
        part1 := Copy(full, 0, splitAt);
        part2 := Copy(full, splitAt, Length(full) - splitAt);
        target := TPipeTarget.ToStringBuilder(sb, encoding);
        target.Start;
        target.HandleData(part1, Length(part1));
        target.HandleData(part2, Length(part2));
        target.Done;
        Assert.AreEqual(text, sb.ToString, 'split at byte ' + IntToStr(splitAt));
      end;
    finally
      sb.Free;
      encoding.Free;
    end;
  end;
  ```

  A second test with `TEncoding.GetEncoding(932)` and a Shift-JIS character pins the Windows DBCS path that works today (it has no test) and shows the POSIX gap when the suite runs on Linux.
- Suggested fix direction: for encodings the function cannot reason about, decode statefully instead of guessing boundaries (for example keep the undecoded tail and retry with `MB_ERR_INVALID_CHARS` on the last few bytes, or use `TEncoding.GetCharCount` on shrinking prefixes), and give POSIX the same DBCS handling.

### PIPE-8. ToStringBuilder with a DBCS code page calls IsDBCSLeadByteEx once per byte of every read

- Severity: Low
- Category: performance
- Confidence: Confirmed by reading that the loop runs per byte; the cost per call needs runtime verification
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:463-484` (`CompleteCharLength`, called from `TStringBuilderPipeTarget.ProcessStreamData` line 648)
- Explanation: To find the last character boundary in a DBCS buffer the code walks from the start of the buffer and asks the OS about every byte:

  ```pascal
  while i < dataLength do
  begin
    if IsDBCSLeadByteEx(codePage, data[i]) then
  ```

  That is up to 65,536 calls into kernel32 (each one looks up the code page tables) for every 64 KB read, on top of the actual decode. On Japanese, Chinese and Korean Windows `TEncoding.Default` is a DBCS code page, so this is the default path for `ToStringBuilder` there. It does not make anything wrong, but it puts a per-byte API call in the hot loop of large captures. (On this dev machine the ANSI code page is 65001, which takes the cheap UTF-8 branch, so it will not show up in local profiling.) The line targets only use this function at the 1 MB forced break, so they are unaffected.
- Existing tests: none exercise a DBCS code page.
- Proposed test: not provable with a deterministic assertion. Best practical approach is a benchmark-style test that feeds, say, 64 MB of ASCII in 64 KB chunks through `TPipeTarget.ToStringBuilder(sb, TEncoding.GetEncoding(932))` and through `TEncoding.UTF8`, logs both timings with `TStopwatch`, and asserts only a generous ratio (for example the Shift-JIS run is not more than 3 times slower).
- Suggested fix direction: call `GetCPInfo` once when the encoding is resolved and test bytes against the cached `LeadByte` ranges (a 256-entry boolean table).

### PIPE-9. FromFile and FileAsStdIn open the input with fmShareDenyWrite, so a file another process has open for writing cannot be used as stdin

- Severity: Low
- Category: bug
- Confidence: Confirmed by reading the code path
- Location: `Source\VSoft.Process.PipeSource.Classes.pas:425-431` (`TFileStdInPipeSource.Start`), `471-477` (`TFilePipeSource.Start`)
- Explanation: Both sources open the file like this:

  ```pascal
  if not FileExists(FFileName) then
    raise EVSoftProcessError.Create('Stdin source file not found: ' + FFileName);
  FFileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyWrite);
  ```

  On Windows `fmShareDenyWrite` means the open fails with a sharing violation whenever any other handle to the file has write access - a log file a service is still appending to, a file an editor keeps open, the output file of a previous `ToFile` target that is still attached and started. The shell equivalent (`program < file`) opens with read and write sharing and works in those cases. Two user-visible consequences: `Execute` raises `EFOpenError` (not the `EVSoftProcessError` the README mentions for these sources, which only covers "missing"), and for the whole run nobody else can open the file for writing - with `FileAsStdIn` that includes the child itself.
- Existing tests: `FileSource_MissingFile_StartRaises`, `FileAsStdIn_MissingFile_ExecuteRaises`, `FileAsStdIn_ChildReadsTheFile`; none with the file open elsewhere.
- Proposed test (direct unit test):

  ```pascal
  procedure TPipeSourceTests.FileSource_FileOpenForWritingElsewhere_StillReadable;
  var
    src : IPipeSource;
    writer : TFileStream;
    fileName : string;
    data : TBytes;
    dataLen : NativeUInt;
    payload : TBytes;
  begin
    fileName := TTestHelpers.TempFileName('vsoft_shared_', '.txt');
    writer := TFileStream.Create(fileName, fmCreate or fmShareDenyNone);
    try
      payload := TEncoding.ASCII.GetBytes('still being written');
      writer.WriteBuffer(payload[0], Length(payload));
      src := TPipeSource.FromFile(fileName);
      src.Start; // raises EFOpenError today
      Assert.IsTrue(src.GetData(data, dataLen));
      Assert.AreEqual<NativeUInt>(Length(payload), dataLen);
      src.Done;
    finally
      writer.Free;
      DeleteFile(fileName);
    end;
  end;
  ```

  and the same with `TPipeSource.FileAsStdIn` (checking `Start` does not raise).
- Suggested fix direction: open with `fmShareDenyNone`, and wrap an open failure in `EVSoftProcessError` so callers have one exception class to catch for "stdin file could not be opened".

### PIPE-10. A line / data delegate that captures the IProcess creates a reference cycle that can never be broken (targets cannot be detached)

- Severity: Low
- Category: memory leak
- Confidence: Confirmed by reading (standard Delphi closure semantics plus the absence of any detach API)
- Location: `Source\VSoft.Process.PipeTarget.Classes.pas:102-109` and `130-137` (`TLineDelegatePipeTarget.FDelegate`, `TDelegatePipeTarget.FDelegate`); `Source\VSoft.Process.Base.pas:1219-1239` (`WithStdOutPipe` / `WithStdErrPipe` only ever add)
- Explanation: The process holds its targets in `FStdOutTargets` / `FStdErrTargets` for its whole life (README: "targets can't be removed and stay attached for later runs"), and a delegate target holds the anonymous method. An anonymous method keeps the whole frame of the routine that created it alive, and all anonymous methods of one routine share that frame. So as soon as any closure in the routine uses the local `proc` variable, the frame holds the process:

  ```pascal
  proc := TProcess.Create;
  proc.WithStdOutPipe(TPipeTarget.ToLineDelegate(
    procedure(const line : string)
    begin
      if Pos('fatal', line) > 0 then
        proc.Terminate;          // proc captured
    end));
  ```

  `proc -> target list -> TLineDelegatePipeTarget -> closure frame -> proc`. Nothing in the API can cut the chain afterwards (no `ClearStdOutPipes`, `WithStdOutPipe(nil)` raises). The process object, its targets, anything else captured, and on Windows the job handle are leaked; with the default `JobMode = KillOnRelease` this also means leftover child processes are never killed because the release never happens. The pattern is natural (stop the child when a line matches), and the README's own examples put the delegate and `proc` in the same routine. `OnExit := nil` can break the equivalent cycle for event handlers, but pipes have no counterpart.
- Existing tests: none.
- Proposed test (Windows or POSIX, no child needed):

  ```pascal
  type
    TDestroyFlagTarget = class(TInterfacedObject, IPipeTarget)
    private
      FFlag : PBoolean;
    protected
      procedure Start;
      procedure HandleData(const data : TBytes; dataLength : NativeUInt);
      procedure Done;
    public
      constructor Create(flag : PBoolean);
      destructor Destroy;override;   // sets FFlag^ := true
    end;

  procedure AttachCapturingDelegate(flag : PBoolean);
  var
    proc : IProcess;
  begin
    proc := TProcess.Create;
    proc.WithStdErrPipe(TDestroyFlagTarget.Create(flag));
    proc.WithStdOutPipe(TPipeTarget.ToLineDelegate(
      procedure(const line : string)
      begin
        proc.Terminate;
      end));
  end;

  procedure TPipeTargetTests.LineDelegate_CapturingProcess_ProcessIsStillReleased;
  var
    destroyed : boolean;
  begin
    destroyed := false;
    AttachCapturingDelegate(@destroyed);
    Assert.IsTrue(destroyed, 'The process and its targets should be released when the last outside reference goes');
  end;
  ```

  Today `destroyed` stays False. Whether this test should pass unmodified depends on the chosen fix: if the answer is an explicit detach call, the helper calls it before returning and the test documents the requirement.
- Suggested fix direction: add a way to detach targets (`ClearStdOutPipes` / `ClearPipes`, or drop the delegate reference in `Done` when the caller opts in) and document the cycle next to the lifetime contracts in the README.

#### Checked and found correct

- Multi-byte characters split across reads: UTF-8 (`Utf8CompleteLength`, all lead/continuation combinations including 4-byte sequences and invalid leads), UTF-16 LE/BE (odd byte and trailing high surrogate held back), two-byte DBCS on Windows. The line targets avoid the problem entirely by decoding only up to the last LF, and scan only the newly appended bytes for it.
- UTF-16 line splitting looks for the LF code unit at even offsets only, including when the carried tail has an odd length (`fromPos and not 1`). Covered by `LineTarget_Utf16LE/BE_EverySplitPoint` and `OneByteAtATime`.
- CR LF split across reads does not produce an extra empty line (the CR stays in the pending bytes until its LF arrives); CR CR LF, lone CR kept, trailing CRs at end of output stripped, final line without newline emitted from `Done`, NUL to space, control characters dropped - all match the README and have tests.
- The 1 MB cap: partial character and trailing CRs stay pending, `LineBroken` suppresses the empty line after a forced break, per-stream state (apart from finding 1).
- Invalid byte sequences never raise (Windows `MultiByteToWideChar` without `MB_ERR_INVALID_CHARS`, own UTF-8 decoder on POSIX with correct overlong / surrogate / >U+10FFFF ranges, ASCII fallback for custom encodings).
- No O(n^2) in line splitting: no Delete/Copy from the front of a growing string, one decode per read, one `Copy` plus one concatenation per line; pending bytes are shifted once per read.
- Threading: every `HandleData` / `HandleStreamData` for one process runs under `FDeliveryLock`, so a target attached to stdout and stderr is never entered concurrently and `FDispatchStdErr` is safe; stdout and stderr keep separate partial-line / partial-character state. No `Synchronize` / `Queue` in any target, so a main thread blocked in `Execute` cannot deadlock delivery. `Done` runs only after `CloseIO` has waited for the threadpool callbacks. The `TStringBuilder` monitor is taken once per read, not per character (note: the README never tells callers to take the same monitor, so it only helps code that knows to).
- `TFilePipeTarget`: file closed in `Done` and in the destructor, `FStartCount` balanced when `Start` itself fails, `fmCreate or fmShareDenyWrite` honoured on XE2 (`fmCreate = $FF00`), a write error faults the target but `Done` still closes the file.
- `TStreamPipeTarget` / `TStreamPipeSource` (factory path) never free the caller's stream; `TMultiPipeTarget` frees a stored exception object in `Start` and `Destroy`.
- Stdin: the writer is its own thread, so a large stdin cannot deadlock against stdout draining (`LargeStdIn_RoundTripsWithoutDeadlock`); partial writes are looped on both platforms; a child that exits or closes stdin early ends the loop through a failed `WriteFile` / `EPIPE` (SIGPIPE ignored) without an exception; the write end is always closed in `finally`, so the child gets EOF when the source is exhausted or raises; a source exception is caught in `TStdInWriter.Execute` and logged to `Errors`.
- `TStringPipeSource` encodes at `Start` with the explicit / injected / default encoding and never emits a preamble; an empty string still closes stdin.
- `TInteractivePipeSource`: event set and reset only under the lock, so no lost wake-up; data queued before `Close` is still delivered; closed automatically when the child exits. It is single-use (`FClosed` is never reset and leftover queued data is kept), which the README documents ("create a new one for the next run").
- `FileAsStdIn`: the handle is duplicated per run and made inheritable only under `GSpawnLock` (Windows) / duplicated with `F_DUPFD_CLOEXEC` (POSIX), no writer thread is created, the file is reopened at offset 0 for every run and closed in `Done`; a missing file raises `EVSoftProcessError` before any child is created and the already-started targets get their `Done`.
- A stdin writer left behind in `GetData` after the child exited shares the source object with a later run (documented in the README as "left to finish on its own"); with the built-in file source this is benign because `Start` creates a fresh stream.

---

## Supporting units

### SUP-1. A NUL (#0) in an argument defeats the batch-file protection (command injection) and truncates any command line

- Severity: High
- Category: security
- Confidence: Confirmed. The string the library builds was hand-traced; the cmd.exe behaviour was then reproduced at runtime with a stand-alone PowerShell P/Invoke harness in the scratchpad (not the library, not the repo): `CreateProcessW(app = x.bat, cmdline = '""<dir>\x.bat" "a&echo INJECTED>marker3.txt' + #0 + '""')` created `marker3.txt`; the same line without the NUL (what the library builds for a clean argument) did not. Harness: `C:\Users\VINCEN~1.OFF\AppData\Local\Temp\claude\09a837d3b9c62382\e5d19bdd-a8bf-4834-9a24-5c9dc95fad42\scratchpad\nulexp\run.ps1`.
- Location: `Source\VSoft.Process.Utils.pas:224-234` (`ContainsCmdUnsafeChars`), `Source\VSoft.Process.Windows.pas:500-518` (`RenderBatchArgument`), `:769-805` (`BuildCommandLine`), `:943-956` (validation). No NUL check exists anywhere on the command-line path (`grep "#0"` over `CommandLine.pas`, `Windows.pas`, `Base.pas`, `Posix.pas` finds nothing), although the environment builder does reject NUL (`Environment.pas:121-133`).
- Explanation: For a `.bat` / `.cmd` target the library refuses `% ! " CR LF` and wraps anything holding cmd metacharacters in quotes, then wraps the whole line in one more pair of quotes so that cmd's "strip the first and the last quote" rule for `/c` is harmless:

  ```pascal
  case value[i] of
    '%', '!', '"', #13, #10 :   // ContainsCmdUnsafeChars - #0 is not here
      Exit(True);
  ...
  result := result + '"' + value + '"';       // RenderBatchArgument
  ...
  result := '"' + result + '"';               // BuildCommandLine, batch branch
  ```

  A Delphi string can hold #0, but `CreateProcessW` / `CreateProcessWithLogonW` take a NUL-terminated `PChar(command)`, so everything after the first #0 is silently dropped - including the closing quote of that argument and the outer closing quote.

  Input: `proc.CommandLine.Add('a&echo INJECTED>marker.txt'#0)` with `Executable = C:\t\x.bat`.
  - Validation: no `% ! " CR LF` -> accepted.
  - `RenderBatchArgument`: `&` is a metacharacter -> `"a&echo INJECTED>marker.txt<NUL>"`.
  - `BuildCommandLine`: `""C:\t\x.bat" "a&echo INJECTED>marker.txt<NUL>""`.
  - What Windows sees: `""C:\t\x.bat" "a&echo INJECTED>marker.txt`.
  - cmd.exe strips the first quote and the *last quote on the line*, which is now the quote that opened the argument: `"C:\t\x.bat" a&echo INJECTED>marker.txt`. The `&` is outside quotes, so `echo INJECTED>marker.txt` runs as a second command.

  Expected: the launch is refused (or the NUL can never reach the line). Actual: text from an argument is executed by cmd.exe. This is exactly the BatBadBut class (CVE-2024-24576) that README "Batch files (Windows)" says the default rules prevent, reached through the safe `Add` path, not `AddUnsafeBatchRaw`. The same applies to a NUL in an argument Name or in `NameValueSeparator`.

  Secondary effect for ordinary executables: `Add('x'#0)` followed by further `Add` calls drops every later argument (for example a trailing `--dry-run` or `--` separator), with no error. On POSIX the damage is limited to the one argv slot (`AllocZ` copies the UTF-8 bytes and the C string ends at the NUL), but it is still silent truncation.
- Existing tests: not covered. `BatchFile_MetaCharsQuoted_UnsafeRejected` and `ContainsCmdUnsafeChars_DetectsExpansionAndQuotes` test `% ! " LF` only; the environment tests cover NUL (`AddOrSet_NulInName_Raises`, `AddOrSet_NulInValue_RaisesAndAddsNothing`) but there is no command-line equivalent.
- Proposed test (Lifecycle fixture, Windows):

  ```pascal
  procedure TProcessLifecycleTests.BatchFile_NulInArgument_IsRefused;
  var
    proc : IProcess;
    marker : string;
  begin
    // a marker path without spaces or cmd metacharacters
    marker := TTestHelpers.TempFileName('vsoft_nul_', '.txt');
    proc := TProcess.Create;
    proc.StartInfo.Executable := TTestHelpers.ScriptPath('echo-args');
    proc.StartInfo.TimeoutInMSec := 20000;
    proc.CommandLine.Add('a&echo INJECTED>' + marker + #0);
    try
      Assert.IsFalse(proc.Execute, 'an argument holding NUL must be refused');
      Assert.IsFalse(FileExists(marker), 'cmd.exe ran text from the argument as a command');
    finally
      if FileExists(marker) then
        DeleteFile(marker);
    end;
  end;
  ```

  Today `Execute` returns True and the marker file exists. A unit-level companion: `Assert.IsTrue(TStringUtils.ContainsCmdUnsafeChars('a'#0'b'))`. For the non-batch case: run `echo-args` style helper exe with `Add('one'#0)`, `Add('two')` and assert the launch is refused (today the child receives only `one`).
- Suggested fix direction: reject #0 in every argument Name / Value / separator (and in `DefaultArgumentSeparator`) at validation on all platforms and for all targets, including `AddUnsafeBatchRaw` text; adding #0 to `ContainsCmdUnsafeChars` alone fixes the batch case but leaves the silent truncation for executables.

### SUP-2. POSIX: one environment entry that is not valid UTF-8 makes `TProcess.Create` raise

- Severity: Medium
- Category: bug
- Confidence: Likely - confirmed by reading the code and the RTL source (Delphi 13 `System.SysUtils.pas` / `System.pas`); not run on Linux or macOS.
- Location: `Source\VSoft.Process.Environment.pas:348-374` (`LoadCurrentEnvironmentBlock`, POSIX branch), reached from the constructor (`:222-231`) and from `Base.pas:401` for every process object.
- Explanation: The builder snapshots `environ` in its constructor and decodes each entry with the strict RTL encoder:

  ```pascal
  envStr := TEncoding.UTF8.GetString(utf8Bytes);
  ```

  `TUTF8Encoding.Create` passes `MB_ERR_INVALID_CHARS`; on POSIX `UnicodeFromLocaleChars` then returns 0 when any byte sequence is invalid ("Return 0 if an invalid character was found"), and `TEncoding.GetString` raises `EEncodingError` (`SNoMappingForUnicodeCharacter`) when `ByteCount > 0` and the char count is 0. POSIX environment values are arbitrary bytes: a Latin-1 directory name in `PWD` / `OLDPWD`, a legacy-locale value exported by a parent, a binary token.

  Input: host environment contains `LEGACY=caf` + byte `$E9` (Latin-1 e-acute). Actual: `TProcess.Create` raises `EEncodingError` from the constructor, so no child can be launched at all, even when the caller never touches `Environment` (in which case the child would simply have inherited `environ` untouched). `Reset` and `Clone` raise the same way. Expected: process creation works; the entry is carried through (ideally byte for byte, at least lossy). The library already knows this RTL behaviour: README says the pipe targets decode UTF-8 themselves so that invalid bytes "never raise".

  Related lossy case: once the caller makes any override, `ToEnvironArray` re-encodes the whole snapshot, so even a tolerant decode would rewrite such an entry for the child.
- Existing tests: not covered (`Create_PopulatesFromCurrentProcess` uses the normal environment; the `print-invalid-utf8` fixture is for pipe output only).
- Proposed test (POSIX only, Environment fixture):

  ```pascal
  procedure TEnvironmentTests.Create_InvalidUtf8InHostEnvironment_DoesNotRaise;
  var
    name : TBytes;
    value : TBytes;
    env : IEnvironmentBuilder;
  begin
    name := TEncoding.ASCII.GetBytes('VSP_BAD_UTF8'#0);
    SetLength(value, 5);
    value[0] := Ord('c'); value[1] := Ord('a'); value[2] := Ord('f'); value[3] := $E9; value[4] := 0;
    setenv(MarshaledAString(@name[0]), MarshaledAString(@value[0]), 1);
    try
      env := TEnvironmentBuilder.Create;   // raises EEncodingError today
      Assert.IsTrue(env.Exists('VSP_BAD_UTF8'));
    finally
      unsetenv(MarshaledAString(@name[0]));
    end;
  end;
  ```
- Suggested fix direction: decode with a non-raising path (the library's own tolerant UTF-8 decoder, or a `TUTF8Encoding` created without `MB_ERR_INVALID_CHARS`), and preferably keep the original bytes of entries the caller did not change so they reach the child unmodified; also consider loading the snapshot lazily so an untouched builder never decodes anything.

### SUP-3. `AddUnsafeBatchRaw('')` passes an empty argument (`""`) instead of nothing

- Severity: Medium
- Category: bug / docs mismatch
- Confidence: Confirmed by tracing.
- Location: `Source\VSoft.Process.CommandLine.pas:228-232` (`TArgument.ToString`), `:377-381` (`TUnsafeBatchRawArgument.Create`); consumed at `Source\VSoft.Process.Windows.pas:790-791` and `Posix.pas:735-738`.
- Explanation: The raw argument is stored as `Name = text`, `Value = ''`, `Quoted = qtNone` and rendered through the shared `ToString`, whose first rule is the "explicit empty argument" shortcut:

  ```pascal
  if (FName = '') and (FValue = '') then
    Exit(EmptyArgument(FQuoted));     // '""' for qtNone
  ```

  Input: `proc.CommandLine.AddUnsafeBatchRaw(params)` where `params = ''` (a batch step with no parameters - the motivating use case passes the user's parameter string as one piece, and it is often empty), `Executable = C:\t\x.bat`.
  - `BuildCommandLine`: `""C:\t\x.bat" """` -> cmd runs `"C:\t\x.bat" ""`.
  - The script sees `%*` = `""` and `%1` = `""`.
  - Reference from README / the interface comment ("receives exactly what `CreateProcess(nil, '"<script>" ' + text)` would give it, measured byte for byte"): `%*` and `%1` are empty.

  Consequence: `if "%1"==""` is false, `shift` loops count one argument, and a script that forwards `%*` hands `""` to the tool it calls. For an `.exe` the child gets an extra empty argv entry; on POSIX `pieces.Add('')` adds an empty argv slot. The doc says the text is added "exactly as given", and "for an .exe it is the same as `Add(text, TQuoted.qtNone)`" - which is true, but `Add('', qtNone)` is the documented explicit-empty-argument form, so the two contracts collide for empty text.
- Existing tests: not covered. `BatchFile_UnsafeRaw_MatchesDirectCreateProcess` iterates nine inputs including `'""'` but not `''`; `AddUnsafeBatchRaw_VerbatimFlaggedAndCloned` does not use empty text.
- Proposed test: add `''` to `cInputs` in `BatchFile_UnsafeRaw_MatchesDirectCreateProcess` (the byte-for-byte comparison then fails: reference `*=[]`, actual `*=[""]`). Unit-level:

  ```pascal
  procedure TCommandLineTests.AddUnsafeBatchRaw_EmptyText_RendersNothing;
  var
    cmd : ICommandLineBuilder;
  begin
    cmd := TArgumentsBuilder.Create;
    cmd.AddUnsafeBatchRaw('');
    Assert.AreEqual('', cmd.ToString);   // '""' today
  end;
  ```
- Suggested fix direction: override `ToString` / `ToLogString` in `TUnsafeBatchRawArgument` to return the text unchanged (or make `AddUnsafeBatchRaw('')` add nothing), and skip the slot on POSIX when the raw text is empty.

### SUP-4. Batch target: a forced-quoted value ending in a backslash reaches the script with the backslash doubled

- Severity: Low
- Category: bug
- Confidence: Confirmed by tracing.
- Location: `Source\VSoft.Process.Windows.pas:505-508` (`RenderBatchArgument` falls back to `arg.ToString`), `Source\VSoft.Process.Utils.pas:130-136` (trailing-backslash doubling in `EscapeForWindowsCommandLine`).
- Explanation: When neither name nor value holds a cmd metacharacter, the batch renderer returns the normal `arg.ToString`. `Add(name, value)` defaults to `qtDouble`, which always quotes the value and applies the `CommandLineToArgvW` escaping. cmd.exe and batch parameters do not follow those rules: nothing un-doubles the backslashes.

  Input: `proc.CommandLine.Add('--out', 'C:\build\')`, `.cmd` target.
  - `ContainsCmdMetaChars('C:\build\')` = False -> `arg.ToString` -> `--out "C:\build\\"`.
  - In the script `%2` = `"C:\build\\"`, `%~2` = `C:\build\\`. Expected `C:\build\`.
  - The same value with a space takes the other branch (`'"' + value + '"'`) and arrives correctly: `Add('--out', 'C:\my build\')` -> `%~2` = `C:\my build\`.

  So whether the script receives one or two trailing backslashes depends on whether the path happens to contain a space (or `, ; = & ( )`). Paths with a doubled separator mostly still open, but string comparisons, `%~dp` style manipulation and anything the script writes out or forwards see different text.
- Existing tests: not covered (`Add_PathWithSpacesAndTrailingBackslash_Escaped` and the `DoubleQuoteString_*` tests are about `.exe` parsing; `BatchFile_MetaCharsQuoted_UnsafeRejected` has no backslash case).
- Proposed test (Lifecycle fixture, Windows):

  ```pascal
  procedure TProcessLifecycleTests.BatchFile_TrailingBackslash_NotDoubled;
  var
    proc : IProcess;
    output : TStringBuilder;
  begin
    output := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.Executable := TTestHelpers.ScriptPath('echo-args');
      proc.StartInfo.TimeoutInMSec := 20000;
      proc.CommandLine.Add('--out', 'C:\build\');
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.Contains(output.ToString, 'arg2=[C:\build\]');   // arg2=[C:\build\\] today
    finally
      output.Free;
    end;
  end;
  ```
- Suggested fix direction: for a batch target never use the `CommandLineToArgvW` escaper; render every part either bare or as plain `"` + text + `"` (a `"` inside is already rejected), whatever `Quoted` says.

### SUP-5. A name ending in a backslash directly followed by a quoted value corrupts both (Windows, .exe)

- Severity: Low
- Category: bug
- Confidence: Confirmed by tracing against the CommandLineToArgvW / MSVCRT rules.
- Location: `Source\VSoft.Process.CommandLine.pas:237-240` (`TArgument.ToString`; same code in `TSensitiveArgument.BuildRendered` `:312-318`).
- Explanation: Name and value are quoted independently and then concatenated:

  ```pascal
  result := QuotePart(FName, FQuoted, False) + FNameSeparator;
  result := result + QuotePart(FValue, FQuoted, True);
  ```

  A name without spaces stays bare. If it ends in `\` and the separator is empty (or itself ends in `\`), the backslash sits immediately before the value's opening quote, and `\"` is an escaped literal quote to the child's parser.

  Input: `cmd.WithDefaultValueSeparator('')` then `cmd.Add('/out:C:\build\', 'my file.txt')`.
  - Rendered: `/out:C:\build\"my file.txt"`.
  - Child argv: `/out:C:\build"my` and `file.txt` (the first `\"` is a literal quote, the space then splits, the last quote opens an unterminated quoted run).
  - Expected: one argument `/out:C:\build\my file.txt`.
- Existing tests: not covered (`Add_NameWithSpaceAndValue_NameQuoted` and the trailing-backslash tests do not combine a bare name ending in `\` with a quoted value).
- Proposed test:

  ```pascal
  procedure TCommandLineTests.Add_NameEndingInBackslash_ValueQuoted_StaysOneArgument;
  var
    cmd : ICommandLineBuilder;
  begin
    cmd := TArgumentsBuilder.Create;
    cmd.WithDefaultValueSeparator('');
    cmd.Add('/out:C:\build\', 'my file.txt');
    // any rendering CommandLineToArgvW reads back as the single argument
    // /out:C:\build\my file.txt, eg the backslash doubled before the quote
    Assert.AreEqual('/out:C:\build\\"my file.txt"', cmd.ToString);
  end;
  ```

  (An E2E variant with the `echo-args` helper exe asserting `total=1` is the stronger check.)
- Suggested fix direction: when the text placed before a quoted value (name + separator) ends in backslashes, double that run, or quote name + separator + value together as one escaped unit when the separator holds no whitespace.

### SUP-6. `DOMAIN\user` in `UserName` with no `Domain` is logged on against the local machine

- Severity: Low
- Category: bug (validation gap)
- Confidence: Needs runtime verification (the code path is certain; the exact Win32 error for user `CORP\bob` + domain `.` was not exercised - no real logon may be attempted in tests).
- Location: `Source\VSoft.Process.Windows.pas:831-835` (`LaunchWithLogon`), `Source\VSoft.Process.Credentials.pas:187-210` (`Validate`).
- Explanation: Only the UPN form is recognised when deciding the domain:

  ```pascal
  if (domain = '') and (Pos('@', userName) = 0) then
    domain := '.';
  ```

  Input: `creds.WithUser('CORP\bob').WithPassword(pw)` (the down-level logon name most Windows users type). Result: `CreateProcessWithLogonW('CORP\bob', '.', ...)`, i.e. a lookup of an account literally named `CORP\bob` in the local account database, which fails with a logon error that says nothing about the name format. `Validate` rejects UPN + Domain but accepts this. README does state the rule ("when no Domain is given and the user name is not in UPN form, the local account database is used"), so this is a trap rather than a contradiction.
- Existing tests: not covered (`Validate_*` tests cover UPN + domain, missing user, missing password; the Logon tests use a made-up plain user with `NetCredentialsOnly`).
- Proposed test:

  ```pascal
  procedure TCredentialsTests.Validate_RejectsDownLevelNameWithoutSplitting;
  var
    creds : ICredentialsBuilder;
    errors : TStringList;
  begin
    errors := TStringList.Create;
    try
      creds := TCredentialsBuilder.Create;
      creds.WithUser('CORP\bob').WithPassword('x');
      Assert.IsFalse(creds.Validate(procedure(const msg : string) begin errors.Add(msg); end),
                     'CORP\bob must be split into Domain + UserName or rejected');
    finally
      errors.Free;
    end;
  end;
  ```

  (Or, if splitting is chosen: stub the launcher as the Logon tests do and assert user `bob`, domain `CORP`.)
- Suggested fix direction: in `Validate` reject a `\` in `UserName` with a clear message, or split `DOMAIN\user` into the two parameters when `Domain` is empty.

### SUP-7. README describes the password scrub as `UniqueString` + `FillChar`; the code does something else

- Severity: Low
- Category: docs mismatch
- Confidence: Confirmed by reading.
- Location: `README.md:752` vs `Source\VSoft.Process.Credentials.pas:80-102, 106-114, 146-150, 172-180`.
- Explanation: README: "The credentials builder zeroes the password in its destructor (best-effort scrub via `UniqueString` + `FillChar`)". The implementation keeps a private heap copy (`PrivateCopy`) taken in `SetPassword` / `CreateClone`, zeroes it in place with `WipePrivate`, and `GetPassword` hands out a fresh copy that the caller must wipe with `ScrubString`. That last point is a real contract for anyone reading `Credentials.Password` (each read allocates an unzeroed copy the reader owns) and it is only stated in a source comment. `UniqueString` + `FillChar` would also describe a weaker scheme (it zeroes a new copy when the buffer is shared), so the README undersells and misdescribes what happens.
- Existing tests: `Password_ZeroedOnDestroy` covers the behaviour; nothing ties the README wording to it.
- Proposed test: none needed for the docs; optionally `Password_Getter_ReturnsPrivateCopy` asserting `Pointer(creds.Password) <> Pointer(creds.Password)` to pin the documented contract.
- Suggested fix direction: reword the README sentence and mention that the `Password` getter returns a copy the caller should pass to `ScrubString`.

### SUP-8. Every `TProcess.Create` (and every `Clone`) enumerates and copies the whole host environment, usually for nothing

- Severity: Low
- Category: performance
- Confidence: Confirmed by reading.
- Location: `Source\VSoft.Process.Environment.pas:222-242` (`Create` calls `Reset`; `CreateClone` calls `Create` and then `Assign`), `Base.pas:401, 428`.
- Explanation: `TEnvironmentBuilder.Create` calls `Reset` -> `LoadCurrentEnvironmentBlock`, which walks `GetEnvironmentStrings` / `environ` and allocates one string per variable (plus two `Trim` temporaries per entry on Windows, a `TBytes` and a UTF-8 decode per entry on POSIX). When the caller never touches `Environment`, `HasOverrides` stays False and the platform code passes nil, so the snapshot is never used. `CreateClone` is worse: it loads the host environment through `Create` and immediately throws it away with `FVariables.Assign(source.FVariables)`. For a host that launches many short-lived children (a build tool, a test runner) this is a few hundred allocations per launch that can be avoided; it is also the reason finding 2 hits callers that never use the environment. On Windows each `AddOrSet` / `Exists` / `TryGetValue` additionally does a linear scan with two string allocations per entry (`Copy` + `EnvName`) - fine for a handful of calls, quadratic for `AddOrSetValues` with a large list.
- Existing tests: n/a (behavioural tests such as `Create_PopulatesFromCurrentProcess` and `HasOverrides_FalseAfterCreate` would still need to pass).
- Proposed test: no failing functional test; a guard could be `Clone_DoesNotReloadHostEnvironment`: set a host variable after creating the source builder, `Clear` the source, clone it, and assert the clone has `Count = 0` (passes today, protects a lazy-load refactor).
- Suggested fix direction: load the snapshot lazily on first read or mutation, and give `CreateClone` a path that skips `Reset`.

#### Checked and found correct

- `EscapeForWindowsCommandLine`: 2N / 2N+1 backslash rules, trailing-backslash doubling, embedded quotes, empty string -> `""` (hand-traced `a\"b`, `C:\dir\`, `\\`, `"`).
- `DoubleQuoteString` / `QuoteString` / `QuotePart`: auto vs forced quoting, tab triggers quoting, empty value quoted, caller-wrapped value unwrapped only when no inner quote; matches README "Quoting".
- `TArgument.ToString` vs `TSensitiveArgument.BuildRendered`: same shape, mask never built from the secret; `Clone` keeps the sensitive and raw subclasses (and `FQuoted`, `FQuoteName`, separator).
- Batch detection: case-insensitive extension, trailing dots / spaces (both in `IsBatchFile` and through `ExpandFileName`), bare name found on PATH with extension, `.exe` only appended when there is no extension (PATHEXT cannot pull in a `.cmd`), `x.bat::$DATA` is not treated as batch and is not runnable either. Batch path with `%` / `!` refused; `& ^ space` in the path are inside quotes.
- Batch safe path apart from finding 1: `% ! " CR LF` refused in name, value and name/value separator after the same `StripQuotes` the renderer uses (no validate/render mismatch found for values such as `"a"b"`, `'"'`, `""`); metacharacters `& | < > ^ ( ) , ; =` space and tab force quotes even under `qtNone`; the outer quote pair survives cmd's first/last quote strip (covered by `BatchFile_UnsafeRaw_MatchesDirectCreateProcess` for paths with and without spaces, and reproduced in my harness baseline).
- Environment block (Windows): UTF-16, sorted by name with `CompareStringOrdinal` ignore-case, `=C:=...` drive entries kept and sorted by their `=X:` name, each entry NUL-terminated, final extra NUL, empty block is two NULs + terminator (4 zero bytes), buffer growth arithmetic is in bytes and has room for both terminators, cache invalidated by every mutator, block memory owned by the builder (no leak). Names: empty, `=`, NUL rejected; lookup is ordinal ignore-case on Windows and case-sensitive on POSIX; `AddOrSet` keeps the existing entry's casing; empty value kept (not deleted); `AddOrSetValues` validates everything before changing anything.
- `ToEnvironArray` (POSIX): UTF-8, each entry NUL-terminated, nil-terminated array, partial allocations freed on exception, freed by `FreeZArray` with matching `GetMem` / `FreeMem`.
- Executable search (Windows): only absolute PATH entries, quotes stripped, empty and relative entries skipped (no current-directory hijack), directories and wildcard names fail `FileExists`, relative path with a folder resolves against the host's current directory as documented, long paths handled by `ExpandFileName` (XE2 RTL re-queries when the buffer is too small). POSIX: absolute entries only, `/usr/bin:/bin` fallback, `X_OK` plus not-a-directory, relative path made absolute before the child's `chdir`.
- `TStartInfoBuilder.CreateClone`: all 19 fields are copied, including `FArgvZero`, `FPipeDrainTimeoutMS`, `FJobMode`, `FTerminateOnTimeout`, `FDetachedNewConsole`, `FInheritHostStdHandles`, `FDeliverOnRunThread`. Defaults match README (HideWindow True, timeout 0, drain 2000, KillOnRelease, TerminateOnTimeout True, the three new flags False, exit codes 9999 / 8888). The option combinations I looked at (DetachedNewConsole with Execute or credentials, InheritHostStdHandles with ExecuteDetached, DeliverOnRunThread on POSIX) are documented as "ignored" rather than silently conflicting.
- Credentials: password held in a private heap buffer, wiped on replace and on destroy, clone takes its own copy, getter never shares the internal buffer, password never appears in error or log text; validation covers UPN + domain, user without password, domain / password without user; POSIX refuses credentials.
- XE2 compatibility of the five units: no inline vars, no string helpers, no type inference; `Exit(value)`, `StringRefCount`, generics and `TEncoding` use are all XE2-era.
- Demos (`BasicConsole`, `PipeTargets`, `InteractiveShell`, `InteractiveShellFMX`): API use is consistent with the library (`cmd.exe /c` with a single quoted or `qtNone` tail works because cmd strips the one quote pair); no misuse found.

Not verified (would need a real logon): whether `LoadUserProfile` and `NetCredentialsOnly` set together (`LOGON_WITH_PROFILE or LOGON_NETCREDENTIALS_ONLY` = 3, `Windows.pas:836-840`) is accepted by `CreateProcessWithLogonW`; the API documents the flags as alternatives and `Validate` does not reject the combination. Also not verifiable without a compiler listing: whether `password := Credentials.Password` goes through a hidden temporary (which would leave `StringRefCount = 2` and make `ScrubString` skip the in-place wipe at `Windows.pas:854` and `Base.pas:1149`).

