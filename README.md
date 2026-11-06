# VSoft.Process - Modern Process Execution for Delphi

[![Delphi: XE2+](https://img.shields.io/badge/Delphi-XE2%2B-red.svg)](https://www.embarcadero.com/products/delphi)
[![Platform: Windows](https://img.shields.io/badge/platform-windows-blue.svg)](#platform-support) [![Platform: MacOS](https://img.shields.io/badge/platform-macos-orange.svg)](#platform-support) [![Platform: Linux](https://img.shields.io/badge/platform-linux-green.svg)](#platform-support)
[![License](https://img.shields.io/badge/license-apache2-lightgrey.svg)](LICENSE.txt)

VSoft.Process is a cross-platform process library for Delphi. It wraps platform process APIs (`CreateProcess` on Windows, `fork`/`execve` with `epoll`/`kqueue` on POSIX) behind a small interface-driven API, and adds the bits you usually have to write yourself: command-line construction with safe quoting, stdin/stdout/stderr redirection, line-oriented capture, interactive stdin, timeouts, cancellation tokens, process groups, and credential-aware launching on Windows.

The goals are:

- One API, three platforms - Win32, Win64, Linux and macOS share the same `IProcess` surface.
- Interface-based - everything you touch is an interface, so lifetime is reference-counted and `IProcess` plays well with composition, fluent chaining, and cloning.
- Async I/O on every platform - large or chatty processes do not deadlock waiting for buffers to drain.
- Sensible defaults - safe quoting, process-tree termination, exit codes and post-exit output draining work out of the box; attach a pipe target to capture output.

## Features

- **Cross-platform**: Win32, Win64, Windows ARM64EC (Delphi 13.2+), Linux, macOS share a single `IProcess` API.
- **Fluent or imperative**: chain `WithStartInfo(...).WithCommandLine(...).Execute` or set properties step-by-step.
- **Three execution modes**: synchronous `Execute`, fire-and-monitor `ExecuteAsync`, fully-detached `ExecuteDetached`.
- **I/O redirection**: bind stdout/stderr to streams, files, `TStringBuilder`, or per-line delegates; feed stdin from strings, bytes, files, streams, or an interactive source.
- **Interactive stdin**: write to a running child's stdin from anywhere; the writer thread blocks on an event instead of busy-spinning.
- **Command-line builder**: declarative argument construction with per-argument quoting; sensitive arguments are masked in `ToLogString` but emitted normally to `ToString`.
- **Environment builder**: inherit, override, or strip variables; the platform impl only builds a custom block when you actually modify it.
- **Timeouts and cancellation**: per-process timeout with a configurable exit code, plus `ICancellationToken` / `TEvent`-based cancellation for `Execute` and `ExecuteAsync`.
- **Process trees**: on Windows the child runs in a Job Object, so Terminate / timeout / cancellation stop everything it started, and `JobMode` decides whether leftovers are killed when the `IProcess` is released ([Job mode](#job-mode)); POSIX signals the child's process group.
- **Credentials** (Windows): launch as a different user via `CreateProcessWithLogonW`; passwords are zeroed on builder destruction.
- **Pipe fan-out**: a single stdout pipe can feed any number of targets simultaneously via `TPipeTarget.ToAll`.

## Requirements

- Delphi XE2 or later (the code base intentionally avoids inline `var`, string helpers, and other post-XE2 syntax). Linux64 needs Delphi 10.2 or later, macOS x64 10.3 or later and macOS ARM64 11.0 or later; Windows ARM64EC needs 13.2 or later.
- Windows Vista or later at run time: the Windows implementation imports Vista APIs (threadpool I/O, `CancelIoEx`, process attribute lists) statically.
- [VSoft.CancellationToken](https://github.com/VSoftTechnologies/VSoft.CancellationToken) (the test project pulls it via [DPM](https://github.com/DelphiPackageManager/DPM); see [Tests/VSoft.Process.Tests.dproj](Tests/VSoft.Process.Tests.dproj) for the package-path pattern).

## Installation

### DPM

In the project folder :

`dpm install VSoft.Process`

This will install VSoft.Process and it's dependencies and add them to your project search path.

### Manual

1. Add the [Source/](Source/) directory to your Delphi library path, or include the units directly in your project.
2. Add `VSoft.Process` to your `uses` clause. The platform implementation unit (`VSoft.Process.Windows` or `VSoft.Process.Posix`) is selected automatically via conditional `uses` in the main unit - you do not need to add it yourself.
3. Make sure [VSoft.CancellationToken](https://github.com/VSoftTechnologies/VSoft.CancellationToken) is reachable on your search path.

## Quick Start

```delphi
uses
  System.SysUtils,
  System.Classes,
  VSoft.Process;

var
  proc   : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create
      .WithStartInfo(procedure(const info : IStartInfoBuilder)
        begin
          info.WithExecutable('C:\Windows\System32\cmd.exe')
              .WithHideWindow(True);
        end)
      .WithCommandLine(procedure(const cmd : ICommandLineBuilder)
        begin
          cmd.Add('/c').Add('echo hello-world');
        end)
      .WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));

    proc.Execute;

    if proc.Status = TProcessStatus.Exited then
      Writeln('Exit ', proc.ExitCode, ': ', output.ToString)
    else
      Writeln('Process did not exit normally: ', Ord(proc.Status));
  finally
    output.Free;
  end;
end;
```

The same configuration with property assignments instead of the fluent helpers:

```delphi
    proc := TProcess.Create;
    proc.StartInfo.Executable := 'C:\Windows\System32\cmd.exe';
    proc.StartInfo.HideWindow := True;
    proc.CommandLine.Add('/c');
    proc.CommandLine.Add('echo hello-world');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));

    proc.Execute;
```

## Core Concepts

### Builders

Configuration lives on four interfaces hung off `IProcess`:

| Interface | Reached via | Configures |
|-----------|-------------|------------|
| `IStartInfoBuilder` | `proc.StartInfo` | Executable, working directory, timeout and what it does, job mode, hide-window, priority, processor affinity, encoding, exit-code overrides |
| `ICommandLineBuilder` | `proc.CommandLine` | Arguments (positional, name/value, sensitive), quoting style, separators |
| `IEnvironmentBuilder` | `proc.Environment` | Environment variables (override, add, remove, clear, reset) |
| `ICredentialsBuilder` | `proc.Credentials` | Windows-only user / domain / password / profile flags |

You can either drive these directly with property assignments or use the fluent helpers (`WithStartInfo`, `WithCommandLine`, ...) that take an anonymous procedure.

### Execution modes

| Mode | API | Returns when |
|------|-----|-------------|
| Synchronous | `Execute` | The child exits, times out, is cancelled, or fails to start |
| Asynchronous | `ExecuteAsync` | The child has started; monitor via `Status`, events, `Terminate` |
| Detached | `ExecuteDetached` | The child has started; the library no longer tracks it |

`ExecuteDetached` has explicit caveats: `Status` stays `Running`, `ExitCode` and `TimedOut` raise `EInvalidOpException`, and `Terminate` returns `False` (the OS no longer notifies us). The configured pipes, `JobMode` and timeout are ignored (no target's `Start` or `Done` is called), `OnStarted` fires but `OnExit` never does. Use it only for true fire-and-forget launches. The `IProcess` itself can still be re-used for another run afterwards.

A process object runs one child at a time: calling any `Execute*` while a run is still in progress raises `EInvalidOpException`. That includes two threads calling `Execute*` on the same object at once: one starts the run and the other raises.

Every `Execute*` first resets the object: `Status` becomes `Idle`, `ExitCode` `$FFFFFFFF`, `LastError` 0, and `Errors` and `ResolvedExecutable` are cleared. When the configuration is invalid (missing executable or working directory, invalid credentials, unsafe batch-file arguments) or the cancellation token / event is already signalled, `Execute*` returns `False` with the reason in `Errors`; `Status` stays `Idle`, no pipe target is started and no event fires. Some failures raise instead of returning `False`: a pipe target or source whose `Start` fails (a `ToFile` that can't create its file, `FromFile` with a missing file) and OS errors creating the pipes.

When the configuration is valid but the operating system refuses to start the program (not a valid executable, access denied, elevation required, a wrong password with credentials), `Execute*` also returns `False` with the message in `Errors`, and `Status` stays `Idle`. `OnStarted` doesn't fire; for `Execute` / `ExecuteAsync` the pipe targets have already been started, so their `Done` is called. `LastError` then holds the OS error code: a Win32 error code on Windows (`ERROR_BAD_EXE_FORMAT`, `ERROR_ELEVATION_REQUIRED`, `ERROR_LOGON_FAILURE`, ...) and an `errno` value on POSIX (`EACCES`, ...), so compare it with the platform's own constants. `LastError` is 0 in every other case, so after `False` it tells you whether the OS refused the launch (non-zero) or validation or cancellation stopped it (0). A missing executable is a validation error, so it leaves `LastError` at 0.

### Status

`TProcessStatus = (Idle, Running, Exited, Terminated, TimedOut)` with `{$SCOPEDENUMS ON}`, so reference them as `TProcessStatus.Running` etc.

- `Idle` - never started, or has been reset before a re-run.
- `Running` - child is alive.
- `Exited` - child exited under its own steam; `ExitCode` is the child's reported code.
- `Terminated` - we killed it via `Terminate` or a cancellation token / event; `ExitCode` is `StartInfo.TerminateExitCode` (default `9999`). On POSIX a child ended by a signal we didn't send (a crash, an external `kill`) is also `Terminated`, with `ExitCode` = 128 + the signal number.
- `TimedOut` - the configured `TimeoutInMSec` elapsed; `ExitCode` is `StartInfo.TimedOutExitCode` (default `8888`) and `TimedOut` is `True`. The child was killed, or left running when `StartInfo.TerminateOnTimeout` is `False` (see [Timeouts](#5-timeouts)). A child that exits on its own right at the timeout can report `Exited` with `TimedOut = True`.

`Status` leaves `Running` only once the run has fully completed: all output has been delivered to the pipe targets, every target's `Done` has been called and all handles are closed. Polling `Status` and then reading captured output is therefore safe. `ExitCode` is `$FFFFFFFF` until then.

### Finding the executable

`StartInfo.Executable` can be a full path, a relative path (relative to the current directory, not `WorkingDirectory`) or a bare program name. A bare name (no folder part) is searched for on **this process's** `PATH` (POSIX searches `/usr/bin:/bin` when this process has no `PATH`, as `execvp` does). The `PATH` you give the child through `proc.Environment` is never used for the lookup, so you can give the child a constrained `PATH` (a single folder, say) or none at all (`Environment.Clear`) and the program is still found. To run a program that is only on the child's `PATH`, pass its full path. Only absolute `PATH` entries are searched; the current directory and the host program's folder never are. A program that can't be found is a validation error (`Execute` returns `False` and `Errors` says `Executable "git" was not found on the PATH`). After a run has started, `IProcess.ResolvedExecutable` is the full path that was launched.

On Windows this differs from `CreateProcess`, which looks in the host's folder, the current directory and the system folders first: `.exe` is appended to a name without an extension (`PATHEXT` is not used, so `git` finds `git.exe` but never `git.cmd`), and a `.bat` / `.cmd` found on the `PATH` (named with its extension) follows the batch-file rules below. On POSIX the file found must be executable (`X_OK`).

### Quoting

An argument has a name, a value or both: `Add(name, value)` renders as name + `NameValueSeparator` (`DefaultValueSeparator`, initially a space) + value, and `Add(text)` adds a name-only argument. `Add` and `AddSensitive` take a `TQuoted` enum, **default `qtDouble`**. A value is always quoted under `qtSingle` / `qtDouble`; a name - alone or before a value - is quoted only when it is empty or holds a space, a tab or a `"` (the auto rule of the same quote family), so a switch such as `-v` stays bare while `Add('C:\Program Files\Out\')` stays one argument. Set `IArgument.QuoteName` (reach it through `CommandLine.Arguments[i]` / `ArgumentsByName[name]`) to always quote a lone name under `qtSingle` / `qtDouble`. Use `qtNone` to add a pre-built fragment exactly as given (`Add('exit /b 17', TQuoted.qtNone)`).

The modes are `qtNone`, `qtSingle`, `qtDouble`, `qtAutoSingle` and `qtAutoDouble` (the auto modes quote only when the value contains a space, a tab or a `"`, or is empty). Every mode except `qtNone` first strips one pair of matching quotes surrounding the value when no other quote of that kind is inside it, so a value you quoted yourself isn't quoted twice, while `"a" b "c"` keeps its quotes. Single quotes do not group arguments for `CommandLineToArgvW`, so a single-quoted value holding a space, a tab or a `"` is also double-quoted and escaped, and the child receives `'x y'` as one argument. Whenever a value is double-quoted it is escaped following `CommandLineToArgvW` rules (`\"` and trailing-backslash doubling), so `C:\Program Files\Out\` reaches the child intact and quotes inside the value round-trip into the child's argv. `Add('', '')` adds an explicit empty argument.

Values added with `AddSensitive(name, value)` render as `****` in `ToLogString` while still being passed through to the actual child unchanged; the name stays visible (`--password ****`). `AddSensitive(text)`, with no separate value, masks the whole argument, so `AddSensitive('--password=secret')` logs as `****`. This only masks your logs; anyone who can list the child's command line (`ps`, Process Explorer, `/proc`) can still see the value.

> **Batch files (Windows)**: a `.bat` / `.cmd` executable is run by `cmd.exe`, which re-parses the command line. VSoft.Process quotes any argument containing cmd metacharacters (`& | < > ^ ( ) , ; =`, whitespace) and refuses to launch (validation error in `Errors`) when an argument contains `%`, `!`, `"`, CR or LF, because `cmd.exe` expands or splits those even inside quotes. If you need to pass such values, use a real executable or pass them through the environment. Running `cmd.exe /c ...` yourself bypasses this protection.

> POSIX argv assembly does NOT apply quoting. Each `IArgument` becomes one or two literal argv slots (Name+separator+Value as one slot, or Name and Value as separate slots when `NameValueSeparator = ' '`) and is encoded UTF-8 verbatim. The child sees the exact bytes you set on `Name` / `Value` - quoting is only meaningful for shell-parsed command-line strings, which POSIX never sees.

### Threading and events

`OnStarted` and `OnExit` are part of `IProcess`. Their thread context depends on execution mode and `StartInfo.MarshallEventsToMainThread`:

| Event | Sync `Execute` | `ExecuteAsync` |
|-------|----------------|----------------|
| `OnStarted` | Caller's thread, before the wait loop | Caller's thread, before `ExecuteAsync` returns |
| `OnExit`    | Caller's thread, after the wait loop | Worker thread, inside the spawned anonymous thread |

With `MarshallEventsToMainThread := True`, a handler that would run on any thread other than the main thread is queued to the main thread with `TThread.Queue` instead (for `OnExit` the exit code is snapshotted at queue time). This applies to a synchronous `Execute` called from a background thread too; a handler that would already run on the main thread is called directly.

If your handler touches the VCL/FMX UI from an async run, set `MarshallEventsToMainThread := True` (or `Synchronize` / `TThread.Queue` inside your handler). Queued events are run by the main thread's message loop; a console application must call `CheckSynchronize` for them to run. Exceptions raised by a handler are caught and appended to `IProcess.Errors` rather than propagating.

For the worker-thread cases, the implementation captures a live `IProcess` reference so the process object cannot be destroyed under the handler; safe to drop your `IProcess` ref immediately after `ExecuteAsync` returns. `OnExit` fires after the run has completed, so a handler may start the next run.

### Threading and lifetime contracts

- **Pipe targets** receive `HandleData` on a threadpool thread on Windows. On POSIX the wait loop reads the pipes itself, so it is the thread running the run: the caller's thread for a synchronous `Execute`, the worker thread for `ExecuteAsync`. Calls for all of a process's targets (stdout and stderr alike) are serialised, so a single target can safely be attached to both streams.
- **Attaching**: each `WithStdOutPipe` / `WithStdErrPipe` call adds another target (`nil` raises `EArgumentNilException`); targets can't be removed and stay attached for later runs. `WithStdInPipe` replaces the stdin source, and `nil` removes it.
- The `data` buffer passed to `HandleData` is reused: only the first `dataLength` bytes are valid, and they must be copied if you keep them after the call returns.
- A target that raises is logged to `Errors` and receives no more data for that run; the child keeps running and the other attached targets are unaffected. Targets combined with `TPipeTarget.ToAll` count as one target: if one of them raises, the whole group stops. `Start` and `Done` are called once per run when the launch gets past validation (also when the launch itself then fails), even for a target attached to several streams.
- **Default encodings**: without an explicit encoding or `StartInfo.OutputEncoding`, the line targets and `ToStringBuilder` decode with `TEncoding.Default` (the ANSI code page on Windows), and `TPipeSource.FromString` encodes with it. `IInteractivePipeSource.Write(text)` uses `StartInfo.InputEncoding`, or UTF-8 when that isn't set.
- `ToStringBuilder` clears the `TStringBuilder` at the start of every run.
- **Descendants holding the pipes**: after the child exits (or is killed) the library keeps reading for at most `StartInfo.PipeDrainTimeoutMS` (default 2000 ms) for output still held by a process the child started (a background job, a build server). It then cancels the reads, logs `Output may be truncated...` to `Errors`, and completes. Set it to `INFINITE` to wait for every writer on a normal exit; after the child has been killed (Terminate / timeout / cancellation) the drain is always bounded. Terminate or cancellation during the drain after a normal exit ends it at once: the rest of the output is discarded (logged as possible truncation) and `Status` stays `Exited` with the child's own exit code. On Windows the job is terminated too, ending what the child started; with `JobMode = NoJob`, and on POSIX, those programs are left running.
- **Slow targets**: after a normal exit, everything the child left in the pipes is delivered before the `PipeDrainTimeoutMS` clock starts, however long the targets take over it, so a slow target never loses the child's own output. The clock only limits waiting for *more* output from a descendant. After Terminate / timeout / cancellation the clock starts at once, so a slow target can still miss output that was in the pipe. Increasing `PipeBufferSize` does not help here: it means fewer calls into the target, but it also lets the child exit with more output still unread.
- **Leftover processes**: what happens to programs the child started and left running is set by `StartInfo.JobMode` - see [Job mode](#job-mode).
- **Terminate** called from `OnStarted`, a pipe target / source callback or the thread running a synchronous `Execute` only requests termination (it can't wait for itself) and returns `True` immediately. From `OnExit` it returns `False`: the run has already completed.
- **Encodings** passed to the pipe factories or `StartInfo` are not owned by the library - keep custom `TEncoding` instances alive until the run has completed.
- **Interactive sources** are closed automatically when the child exits; create a new one for the next run.
- **Stdin sources** should return from `GetData` promptly. Once the child has exited and its output has been read, the stdin writer is stopped. If the source's `GetData` still hasn't returned a second later, the run completes anyway and `Errors` says so. The source's `Done` is still called, and the writer thread finishes on its own whenever `GetData` returns; until then it keeps the `IProcess` object alive.
- `Errors` is appended to from worker threads while a run is in progress - read it once `Status` has left `Running`.

## Examples

The library accepts both the fluent style and a step-by-step style. Each example shows the fluent form first, then the same configuration with property assignments. The two styles are interchangeable and can be mixed. Arguments and environment variables have no per-item properties, so the step-by-step form calls `CommandLine.Add` / `Environment.AddOrSet` once per item. The pipes have no properties either: `WithStdOutPipe`, `WithStdErrPipe` and `WithStdInPipe` are simply called as statements.

### 1. Line-by-line stdout capture

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('C:\Windows\System32\ping.exe');
    end)
  .WithCommandLine(procedure(const cmd : ICommandLineBuilder)
    begin
      cmd.Add('-n').Add('3').Add('127.0.0.1');
    end)
  .WithStdOutPipe(TPipeTarget.ToLineDelegate(
    procedure(const line : string)
    begin
      Writeln('[out] ', line);
    end, TEncoding.UTF8));

proc.Execute;
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'C:\Windows\System32\ping.exe';
proc.CommandLine.Add('-n');
proc.CommandLine.Add('3');
proc.CommandLine.Add('127.0.0.1');
proc.WithStdOutPipe(TPipeTarget.ToLineDelegate(
  procedure(const line : string)
  begin
    Writeln('[out] ', line);
  end, TEncoding.UTF8));

proc.Execute;
```

The line target stitches multi-byte UTF-8 sequences across pipe-read boundaries, so non-ASCII output stays intact even when a code point gets split between two reads.

Line targets split the decoded text like this:

- LF ends a line. A run of CRs right before the LF (`CRLF`, or `CR CR LF` from a program that writes CRLF through a text-mode stream) ends the line too and is not part of it. Output that ends in CRs without an LF loses them as well.
- A CR that is not followed by LF (progress output such as `10%<CR>20%<CR>`) stays in the line text.
- NUL becomes a space; TAB is kept; every other control character (`#1..#31`, including ESC, so colour codes are lost) is dropped.
- Bytes that are not valid in the encoding never raise: each invalid sequence becomes U+FFFD, in the line targets and in `ToStringBuilder`, including a sequence cut short when the stream ends. Windows decodes through `MultiByteToWideChar` without `MB_ERR_INVALID_CHARS`; POSIX decodes UTF-8 itself.
- UTF-16 output (`TEncoding.Unicode` / `TEncoding.BigEndianUnicode`) is split on the LF code unit, never on a `0x0A` byte that is half of another character.

Use a byte target (`ToStream`, `ToFile`, `ToDelegate`) when you need the output exactly as written.

### 2. Building a complex command line

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('msbuild.exe');
    end)
  .WithCommandLine(procedure(const cmd : ICommandLineBuilder)
    begin
      cmd.Add('MyProject.dproj')
         .Add('/p:Configuration=Release')
         .Add('/p:Platform=Win64')
         .Add('/v:minimal')
         .WithDefaultValueSeparator('=')     // applies to arguments added after this
         .AddSensitive('/p:Password', GetSecret);
    end);

Writeln(proc.CommandLine.ToLogString); // -> ... /v:minimal /p:Password=****  (safe to log)
Writeln(proc.CommandLine.ToString);    // -> ... /v:minimal /p:Password="<real>" (sent to the child)
proc.Execute;
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'msbuild.exe';
proc.CommandLine.Add('MyProject.dproj');
proc.CommandLine.Add('/p:Configuration=Release');
proc.CommandLine.Add('/p:Platform=Win64');
proc.CommandLine.Add('/v:minimal');
proc.CommandLine.DefaultValueSeparator := '=';   // applies to arguments added after this
proc.CommandLine.AddSensitive('/p:Password', GetSecret);
```

### 3. Capturing stdout and stderr separately

```delphi
var
  outSB, errSB : TStringBuilder;
begin
  outSB := TStringBuilder.Create;
  errSB := TStringBuilder.Create;
  try
    proc := TProcess.Create
      .WithStartInfo(procedure(const info : IStartInfoBuilder)
        begin
          info.WithExecutable('git.exe');
        end)
      .WithCommandLine(procedure(const cmd : ICommandLineBuilder)
        begin
          cmd.Add('status');
        end)
      .WithStdOutPipe(TPipeTarget.ToStringBuilder(outSB, TEncoding.UTF8))
      .WithStdErrPipe(TPipeTarget.ToStringBuilder(errSB, TEncoding.UTF8));

    proc.Execute;
  finally
    outSB.Free;
    errSB.Free;
  end;
end;
```

With property assignments, the configuration inside the `try` becomes:

```delphi
    proc := TProcess.Create;
    proc.StartInfo.Executable := 'git.exe';
    proc.CommandLine.Add('status');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(outSB, TEncoding.UTF8));
    proc.WithStdErrPipe(TPipeTarget.ToStringBuilder(errSB, TEncoding.UTF8));

    proc.Execute;
```

### 4. Custom environment

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('myapp.exe');
    end)
  .WithEnvironment(procedure(const env : IEnvironmentBuilder)
    begin
      // The builder starts as a snapshot of the parent process environment.
      // Reset re-snapshots it; AddOrSet / Remove mark it as "overridden", so
      // the platform impl only builds a custom block when you have actually
      // changed something.
      env.AddOrSet('MY_FLAG', '1')
         .AddOrSet('LANG', 'C')
         .Remove('JAVA_HOME');
    end);

proc.Execute;
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'myapp.exe';
proc.Environment.AddOrSet('MY_FLAG', '1');
proc.Environment.AddOrSet('LANG', 'C');
proc.Environment.Remove('JAVA_HOME');

proc.Execute;
```

`IEnvironmentBuilder.HasOverrides` exposes the dirty bit if you need to inspect it.

`Clear` empties the builder, so the child gets only the variables you add afterwards (possibly none):

```delphi
proc.Environment
  .Clear
  .AddOrSet('SystemRoot', GetEnvironmentVariable('SystemRoot'))  // most Windows programs need it
  .AddOrSet('MY_FLAG', '1');
```

Or one statement at a time:

```delphi
proc.Environment.Clear;
proc.Environment.AddOrSet('SystemRoot', GetEnvironmentVariable('SystemRoot'));  // most Windows programs need it
proc.Environment.AddOrSet('MY_FLAG', '1');
```

`Clear` sets `HasOverrides`, `Clone` keeps the cleared state and `Reset` takes a new snapshot of this process's environment. An empty environment is passed as an empty block (two NULs) on Windows and an empty `envp` on POSIX. A cleared environment has no `PATH`. That does not stop a bare `Executable` name from being found (it is looked up on this process's `PATH`, see [Finding the executable](#finding-the-executable)), but the child, and anything it starts by name, has no `PATH` unless you add one.

### 5. Timeouts

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('slowapp.exe')
          .WithTimeout(5000)            // 5 seconds
          .WithTimedOutExitCode(999);   // custom code reported on timeout
    end);

proc.Execute;

if proc.TimedOut then
  Writeln('Process timed out')
else
  Writeln('Exit code: ', proc.ExitCode);
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'slowapp.exe';
proc.StartInfo.TimeoutInMSec := 5000;       // 5 seconds
proc.StartInfo.TimedOutExitCode := 999;     // custom code reported on timeout

proc.Execute;
```

By default a timeout kills the child and everything it started. Set `TerminateOnTimeout` to `False` to stop waiting but leave the child running:

```delphi
proc.StartInfo
  .WithTimeout(60000)
  .WithTerminateOnTimeout(False)
  .WithJobMode(TProcessJobMode.KillOnTerminate);   // KillOnRelease would kill it later

proc.Execute;   // returns after 60 s at most
```

With property assignments:

```delphi
proc.StartInfo.TimeoutInMSec := 60000;
proc.StartInfo.TerminateOnTimeout := False;
proc.StartInfo.JobMode := TProcessJobMode.KillOnTerminate;   // KillOnRelease would kill it later

proc.Execute;   // returns after 60 s at most
```

The run then completes at the timeout with `Status = TimedOut`, `TimedOut = True` and `ExitCode = TimedOutExitCode`. Output read before the timeout has been delivered, `Done` has been called on every target and no target is called after `Execute` returns. The library stops reading and closes its ends of the pipes, so a child that writes to stdout / stderr afterwards gets a broken pipe (`ERROR_NO_DATA` on Windows; `SIGPIPE`, which ends it unless it ignores the signal, or `EPIPE` on POSIX) and sees EOF on stdin. The child is not killed when the `IProcess` is released or run again. `TerminateOnTimeout = False` together with `JobMode = KillOnRelease` (the default) is rejected at validation, because the job would kill the child as soon as the `IProcess` is released or re-run. `ExecuteAsync` behaves the same way. On POSIX the child's process group is not signalled, and a background thread reaps the child when it exits so it does not stay a zombie.

### Job mode

`StartInfo.JobMode` (`TProcessJobMode`) controls the Windows job object around the child, and with it what happens to programs the child starts:

| `JobMode` | Terminate / timeout / cancellation | Releasing or re-running the `IProcess` |
|-----------|-------------------------------------|----------------------------------------|
| `KillOnRelease` (default) | kills the job: the child and everything it started | kills whatever the child left running (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) |
| `KillOnTerminate` | kills the job | leftovers keep running (job without `KILL_ON_JOB_CLOSE`) |
| `NoJob` | kills the child's process tree (`TSystemUtils.TerminateProcessTree`) | leftovers keep running |

If the child can't be assigned to the job (a host job that doesn't allow nesting on Windows 7, a Run-As child), the library falls back to the `NoJob` behaviour and logs it to `Errors`. POSIX has no job objects: leftovers always survive the `IProcess`, and Terminate / timeout / cancellation signal the child's process group, whatever the mode. The exception is a child that inherits the host's terminal as its stdin: it stays in the host's process group, so only the child itself is signalled and programs it started keep running (see [Platform Support](#platform-support)). Redirect stdin (`TPipeSource.FromString('')` is enough) when the whole tree must stop.

### 6. Async execution and status

`OnStarted` and `OnExit` are method pointers (`of object`), so the handlers live on a class:

```delphi
type
  TJobMonitor = class
  public
    procedure Started(const p : IProcess);
    procedure Exited(const p : IProcess; exitCode : Cardinal);
  end;

procedure TJobMonitor.Started(const p : IProcess);
begin
  Writeln('Started, PID = ', p.ProcessId);
end;

procedure TJobMonitor.Exited(const p : IProcess; exitCode : Cardinal);
begin
  Writeln('Exited with ', exitCode);
end;

...
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('long-task.exe');
    end);

proc.OnStarted := monitor.Started;
proc.OnExit := monitor.Exited;

proc.ExecuteAsync;

while proc.Status = TProcessStatus.Running do
  Sleep(200);
// All output has been delivered by the time Status changes.
```

With property assignments, the `TProcess.Create` statement becomes:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'long-task.exe';
```

The `ExecuteAsync` worker holds a reference to the process, so dropping your local `proc := nil` while it is still running does NOT free the underlying object out from under the worker - it continues to completion safely.

**Waiting on a handle (Windows only).** Instead of polling `Status`, you can wait on `proc.CompletionHandle` together with your own handles, using `WaitForMultipleObjects` or `MsgWaitForMultipleObjects`. It is a manual-reset event that is signalled while no run is in progress. `Execute` / `ExecuteAsync` reset it before the child is created, so it is already reset when `ExecuteAsync` returns `True`. It is set once the run has fully completed: `Status` has left `Running`, all output has been delivered and `ExitCode` is final (`OnExit` fires after that). A run that fails validation or fails to launch leaves it signalled, and so does `ExecuteDetached`. The handle belongs to the `IProcess`: never close or signal it, and keep your `IProcess` reference until the wait is over. The property doesn't exist on POSIX, where `TEvent` has no handle.

This waits for the run on the main thread, keeps the UI responsive, and wakes whenever a worker has queued output lines for you to log:

```delphi
var
  handles : array[0..1] of THandle;
  waitResult : DWORD;
begin
  if not proc.ExecuteAsync then
    raise Exception.Create(proc.Errors.Text);
  handles[0] := proc.CompletionHandle;
  handles[1] := FLinesQueued.Handle; // your own auto-reset TEvent, set when lines are queued
  repeat
    waitResult := MsgWaitForMultipleObjects(2, handles, False, INFINITE, QS_ALLINPUT);
    case waitResult of
      WAIT_OBJECT_0     : ;                            // the run has completed
      WAIT_OBJECT_0 + 1 : FlushQueuedLines;            // your event
      WAIT_OBJECT_0 + 2 : Application.ProcessMessages; // a message arrived
    else
      RaiseLastOSError;
    end;
  until waitResult = WAIT_OBJECT_0;
  FlushQueuedLines;
  // proc.Status, proc.ExitCode and all captured output are final here.
end;
```

Without a message loop, `WaitForMultipleObjects(2, @handles, False, timeoutMs)` works the same way.

### 7. Interactive stdin

```delphi
var
  proc  : IProcess;
  stdin : IInteractivePipeSource;
begin
  stdin := TPipeSource.Interactive;

  proc := TProcess.Create
    .WithStartInfo(procedure(const info : IStartInfoBuilder)
      begin
        info.WithExecutable('interactive-tool.exe');
      end)
    .WithStdInPipe(stdin);

  proc.ExecuteAsync;

  stdin.Write('hello'#10);
  Sleep(50);
  stdin.Write('world'#10);
  stdin.Close;   // signal EOF so the child can finish

  while proc.Status = TProcessStatus.Running do
    Sleep(50);
end;
```

With property assignments, the `TProcess.Create` statement becomes:

```delphi
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'interactive-tool.exe';
  proc.WithStdInPipe(stdin);
```

The writer thread blocks on an event (`IInteractivePipeSource.WaitForData`), so an interactive source that is idle for long stretches does not burn CPU.

### 8. Cancellation tokens

```delphi
uses
  VSoft.CancellationToken;

var
  proc  : IProcess;
  cts   : ICancellationTokenSource;
begin
  cts := TCancellationTokenSourceFactory.Create;

  proc := TProcess.Create
    .WithStartInfo(procedure(const info : IStartInfoBuilder)
      begin
        info.WithExecutable('long-task.exe');
      end);

  proc.ExecuteAsync(cts.Token);

  // ... some other code triggers cancellation ...
  cts.Cancel;

  while proc.Status = TProcessStatus.Running do
    Sleep(50);
end;
```

With property assignments, the `TProcess.Create` statement becomes:

```delphi
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'long-task.exe';
```

`Execute` and `ExecuteAsync` both accept either an `ICancellationToken` or a `TEvent` (handy when you already have an event-based wait somewhere).

### 9. Terminate

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('long-task.exe')
          .WithTerminateExitCode(1234);
    end);

proc.ExecuteAsync;
Sleep(2000);

if proc.Terminate then
  Writeln('Terminated, exit code = ', proc.ExitCode)  // 1234
else
  Writeln('Process was not running');
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'long-task.exe';
proc.StartInfo.TerminateExitCode := 1234;

proc.ExecuteAsync;
```

`Terminate` waits up to 5 seconds for the run to finish cleaning up and returns `True` when it has. That includes a child that happened to exit on its own first, in which case `Status` is `Exited` and `ExitCode` is the child's own code. It returns `False` when no run is in progress, or when cleanup takes longer than 5 seconds (termination still goes ahead).

### 10. Multi-target fan-out

```delphi
var
  fileTarget, consoleTarget, combined : IPipeTarget;
begin
  fileTarget    := TPipeTarget.ToFile('build.log', False);
  consoleTarget := TPipeTarget.ToLineDelegate(
    procedure(const line : string)
    begin
      Writeln(line);
    end);

  combined := TPipeTarget.ToAll([fileTarget, consoleTarget]);

  proc := TProcess.Create
    .WithStartInfo(procedure(const info : IStartInfoBuilder)
      begin
        info.WithExecutable('build.exe');
      end)
    .WithStdOutPipe(combined);

  proc.Execute;
end;
```

With property assignments, the `TProcess.Create` statement becomes:

```delphi
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'build.exe';
  proc.WithStdOutPipe(combined);
```

Calling `WithStdOutPipe` once for each target has the same effect, and keeps the targets independent: with `ToAll`, a target that raises stops the whole group.

### 11. Cloning a configured process

```delphi
template := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('myapp.exe').WithTimeout(10000);
    end)
  .WithCommandLine(procedure(const cmd : ICommandLineBuilder)
    begin
      cmd.Add('--verbose');
    end);

job1 := template.Clone;
job2 := template.Clone;
job1.Execute;
job2.Execute;
```

With property assignments:

```delphi
template := TProcess.Create;
template.StartInfo.Executable := 'myapp.exe';
template.StartInfo.TimeoutInMSec := 10000;
template.CommandLine.Add('--verbose');
```

Each clone gets its own deep copy of the four builders (start info, command line, environment and credentials), so per-invocation tweaks do not leak back into the template. Pipe targets, the stdin source and the `OnStarted` / `OnExit` handlers are not copied: attach them to each clone.

### 12. Windows: run as a different user

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('admin-task.exe');
    end)
  .WithCredentials(procedure(const creds : ICredentialsBuilder)
    begin
      creds.WithUser('Administrator')
           .WithDomain('CORP')
           .WithPassword(GetSecret)
           .WithUserProfile(True);
    end);

proc.Execute;
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'admin-task.exe';
proc.Credentials.UserName := 'Administrator';
proc.Credentials.Domain := 'CORP';
proc.Credentials.Password := GetSecret;
proc.Credentials.LoadUserProfile := True;

proc.Execute;
```

The credentials builder zeroes the password in its destructor (best-effort scrub via `UniqueString` + `FillChar`) so the plaintext does not linger in the heap after the builder is released. When no `Domain` is given and the user name is not in UPN form (`user@domain`), the local account database (`.`) is used. `CreateProcessWithLogonW` limits the command line to 1024 characters; longer command lines are rejected at validation, as are a `UserName` without a `Password`, a `Domain` or `Password` without a `UserName` (which would otherwise run the child as the current user), and a UPN user name combined with a `Domain`.

### 13. Detached launch

```delphi
proc := TProcess.Create
  .WithStartInfo(procedure(const info : IStartInfoBuilder)
    begin
      info.WithExecutable('opener.exe');
    end);

proc.ExecuteDetached;
// proc.Status will read Running forever, proc.ExitCode will raise.
// On Windows you still get proc.ProcessId (the immediate child);
// on POSIX the grandchild PID is lost across the double-fork.
```

With property assignments:

```delphi
proc := TProcess.Create;
proc.StartInfo.Executable := 'opener.exe';

proc.ExecuteDetached;
```

## Platform Support

| Platform | Async I/O | Process tree termination | Credentials | Notes |
|----------|-----------|--------------------------|-------------|-------|
| Windows  | Threadpool I/O completion on overlapped named pipes | Job Object (the child is created suspended and assigned before it runs; `KILL_ON_JOB_CLOSE` with the default `JobMode`); a process-tree kill with `JobMode = NoJob` or when the job can't be used | `CreateProcessWithLogonW` | UTF-16 environment block; only the child's own std handles are inherited |
| Windows ARM64EC (Delphi 13.2+) | as Windows | as Windows | as Windows | The Windows implementation, unchanged (`WIN64`, `CPUARM64` and `ARM64EC` are defined, `CPUX64` is not). The runtime package and test project compile and link; not yet run on ARM hardware, and not yet in the DPM package |
| Linux    | `epoll` (+ `pidfd` on kernel 5.3+) | `SIGTERM` to the child's process group, `SIGKILL` 500 ms later | n/a | UTF-8 environment + argv, `signal(SIGPIPE, SIG_IGN)` set for the whole host process at unit init (children get the default back) |
| macOS    | `kqueue` (+ `EVFILT_PROC`) | `SIGTERM` to the child's process group, `SIGKILL` 500 ms later | n/a | UTF-8 environment + argv, `signal(SIGPIPE, SIG_IGN)` as on Linux |

`ExecuteDetached` uses a double-fork on POSIX so the grandchild reparents to init (with `/dev/null` as its stdio), and `DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB` on Windows so the detached child survives the host's Job Object (CI runners etc.). When the host's job does not allow breakaway, the child is started inside it instead. On POSIX, child-init failures (chdir / dup2 / exec) come back through a self-pipe, so `ExecuteDetached` still returns `False` when the program can't be started; on Windows `CreateProcess` reports them directly.

On Windows the child always gets its own console (`CREATE_NEW_CONSOLE`), hidden unless `HideWindow` is `False`, so it never shares the host's console: output from a stream you don't redirect goes to that console. When you redirect some streams but not others, the others are connected to `NUL` (attach only a stdout target and the child's stderr is discarded and its stdin is at end of file). On POSIX, streams you don't redirect are inherited from the host.

On POSIX the child starts with an empty signal mask and SIGPIPE / SIGXFSZ reset to their defaults (any other signal the host ignores stays ignored), and every file descriptor of the host other than its stdio is closed. A file without a `#!` line that `execve` rejects is run with `/bin/sh`, as `execvp` does. When the host's stdin is a terminal and the child's stdin is not redirected, the child stays in the host's process group (so it can read the terminal and receives Ctrl+C); in that case Terminate signals the child itself rather than its whole tree. Executable lookup works the same way on every platform - see [Finding the executable](#finding-the-executable).

Background processes the child leaves behind are not killed on a normal exit. On Windows, with the default `JobMode = KillOnRelease`, they are ended when the `IProcess` is released or re-run (the job is closed); with `KillOnTerminate` or `NoJob`, and always on POSIX, they keep running.

### `IStartInfoBuilder` per-platform behaviour

| Property | Windows | Linux | macOS |
|----------|---------|-------|-------|
| `Executable`, `WorkingDirectory`, `TimeoutInMSec` | yes | yes | yes |
| `HideWindow` (default `True`) | shows or hides the child's console window | **ignored** | **ignored** |
| Bare `Executable` name | this process's `PATH` (never the child's), `.exe` appended when there is no extension, no `PATHEXT`, never the current directory | this process's `PATH` (never the child's; `/usr/bin:/bin` when it has none), file must be executable | same as Linux |
| `TerminateOnTimeout` (default `True`) | `False`: child left running, our pipe ends and handles closed | `False`: no signal, pipe fds closed, child reaped by a background thread when it exits | same as Linux |
| `JobMode` (default `KillOnRelease`) | job object flags / no job (see [Job mode](#job-mode)) | no job objects: leftovers always survive, stop signals go to the process group (only to the child when it inherits a terminal stdin) | same as Linux |
| `TimedOutExitCode`, `TerminateExitCode` | yes | yes | yes |
| `InputEncoding`, `OutputEncoding` | yes (auto-applied to line / `TStringBuilder` targets) | yes | yes |
| `PipeBufferSize` (0 = 64KB default) | named-pipe buffers + read buffer | read buffer only (the kernel's pipe size is unchanged) | same as Linux |
| `PipeDrainTimeoutMS` (default 2000) | yes | yes | yes |
| `MarshallEventsToMainThread` | yes | yes | yes |
| `ProcessorAffinity` | `SetProcessAffinityMask` | `sched_setaffinity` (in the child, before exec) | **ignored** (macOS has no equivalent) |
| `Priority` (`TProcessPriority`) | priority class on the process | `setpriority(PRIO_PROCESS, 0, nice)` | `setpriority(PRIO_PROCESS, 0, nice)` |
| `ArgvZero` | **ignored** (Windows command-line has no separate argv[0]) | yes | same as Linux |
| Credentials (`ICredentialsBuilder` / `WithCredentials`) | `CreateProcessWithLogonW` | rejected at validation - POSIX has no equivalent | same as Linux |

> **Maturity note**: Windows is the primary target and is exercised heavily by the unit and end-to-end test suite. The Linux and macOS implementations share the POSIX code path. The library and the whole test suite compile for Linux64, macOS x64 and macOS arm64, and the suite (including its shell-script fixtures and POSIX-specific tests) passes on Linux x64 and macOS arm64, but the POSIX code has seen little real-world use so far. Treat POSIX support as a work in progress; bug reports and fixes are very welcome. Windows ARM64EC (Delphi 13.2 and later) uses the Windows code path and is compile-tested only so far.

## Test Suite

The [Tests/](Tests/) directory contains a DUnitX test project (`VSoft.Process.Tests.dproj`) covering:

- **Unit tests** for each builder (`Tests/VSoft.Process.Tests.CommandLine.pas`, `Environment.pas`, `Credentials.pas`, `StartInfo.pas`), every pipe source and target (`PipeSource.pas`, `PipeTarget.pas`), and the string-quoting utilities (`Utils.pas`).
- **End-to-end tests** ([Tests/VSoft.Process.Tests.Process.pas](Tests/VSoft.Process.Tests.Process.pas), [Tests/VSoft.Process.Tests.ProcessE2E.pas](Tests/VSoft.Process.Tests.ProcessE2E.pas) and [Tests/VSoft.Process.Tests.Lifecycle.pas](Tests/VSoft.Process.Tests.Lifecycle.pas)) that spawn real child processes and assert on captured output, exit codes, environment propagation, cancellation, timeouts, process re-use, failing pipe targets, concurrent launches and pipe draining.
- **Process lifetime and lookup tests** ([Tests/VSoft.Process.Tests.Lifetime.pas](Tests/VSoft.Process.Tests.Lifetime.pas), [Tests/VSoft.Process.Tests.ExecutableSearch.pas](Tests/VSoft.Process.Tests.ExecutableSearch.pas)) for `JobMode`, `TerminateOnTimeout`, handle leaks and the `PATH` search.
- **Deterministic script fixtures** in [Tests/scripts/](Tests/scripts/), one `.cmd` and one `.sh` per scenario (echo-args, echo-stdin, print-env, print-cwd, print-large, print-stderr, print-both, print-then-sleep, print-invalid-utf8, exit-with, sleep, spawn-and-wait, spawn-background-and-exit). Each script has a fixed, known output so the E2E tests can compare against exact bytes rather than whatever the host's `ping` / `find` / etc. happens to print. Platform differences live in [Tests/VSoft.Process.Tests.Common.pas](Tests/VSoft.Process.Tests.Common.pas).

To run the tests, open the test dproj in the IDE and build/run. The console runner runs unattended (it only waits for a key press when started under the debugger), writes NUnit XML for CI ingestion (`dunitx-results.xml` next to the exe, or the path given with `--xml:<path>`) and accepts `--run:<fixture or test>` to run a subset. Test dependencies (DUnitX, VSoft.CancellationToken) are pulled in via DPM; see the `<DPMSearch>` lines in the dproj for the package layout if you are not using DPM. The project file targets Win32, Win64 and Linux64; to run the suite on macOS, add the platform.

## API Reference (high level)

**`IProcess`** - the central interface returned by `TProcess.Create`.
- Execution: `Execute(cancellationToken|cancellationEvent)`, `ExecuteAsync(cancellationToken|cancellationEvent)`, `ExecuteDetached`, `Terminate`, `Clone`.
- Configuration: `WithStartInfo`, `WithCommandLine`, `WithEnvironment`, `WithCredentials`, `WithStdOutPipe`, `WithStdErrPipe`, `WithStdInPipe`.
- State: `Status`, `ExitCode`, `TimedOut`, `ProcessId`, `ResolvedExecutable`, `StartMode`, `LastError` (the OS error code when the OS refused to start the child, otherwise 0; see [Execution modes](#execution-modes)), `Errors`, `CompletionHandle` (Windows only; see [Async execution and status](#6-async-execution-and-status)).
- Events: `OnStarted`, `OnExit`.

**`IStartInfoBuilder`** - `Executable`, `ArgvZero` (POSIX), `WorkingDirectory`, `HideWindow` (default `True`, Windows), `TimeoutInMSec` (default 0 = no timeout), `TimedOutExitCode`, `TerminateExitCode`, `Priority`, `ProcessorAffinity`, `InputEncoding`, `OutputEncoding`, `PipeBufferSize` (0 = 64KB), `PipeDrainTimeoutMS` (default 2000), `JobMode` (default `KillOnRelease`), `TerminateOnTimeout` (default `True`), `MarshallEventsToMainThread` (queue events on the main thread), `Clone`, and `With*` fluent equivalents (named after the property, except `WithTimeout` for `TimeoutInMSec` and `WithPipeDrainTimeout` for `PipeDrainTimeoutMS`). See the [Platform Support](#platform-support) matrix for per-platform behaviour.

**`ICommandLineBuilder`** - `Add` / `AddSensitive` (name-only or name + value, `qtDouble` by default), `Remove`, `Clear`, `Count`, `Arguments[]`, `ArgumentsByName[]`, `DefaultValueSeparator` (initially a space) / `WithDefaultValueSeparator`, `DefaultArgumentSeparator` / `WithDefaultArgumentSeparator`, `ToString`, `ToLogString`, `Clone`. `Arguments[]` returns `IArgument`: `Name`, `Value`, `Quoted`, `NameValueSeparator`, `QuoteName`. `DefaultArgumentSeparator`, `Quoted` and `QuoteName` only affect the Windows command line; POSIX passes argv slots verbatim.

**`IEnvironmentBuilder`** - `AddOrSet`, `AddOrSetValues`, `Remove`, `Clear`, `TryGetValue`, `Exists`, `Reset`, `Count`, `HasOverrides`, `ToEnvironmentBlock` (Windows), `ToEnvironArray` (POSIX), `ToString`, `Clone`. Names are case-insensitive on Windows and case-sensitive on POSIX; empty names and names containing `=` raise `EArgumentException`.

**`ICredentialsBuilder`** (Windows-only) - `UserName`, `Domain`, `Password`, `LoadUserProfile`, `NetCredentialsOnly`, plus `WithUser` / `WithDomain` / `WithPassword` / `WithUserProfile` / `WithNetCredentialsOnly`, `Validate`, `Clone`.

**`TPipeTarget`** factory - `ToStream`, `ToFile(name, append)`, `ToStringBuilder(sb, enc)`, `ToDelegate`, `ToMethod`, `ToProcedure`, `ToLineDelegate`, `ToLineMethod`, `ToLineProcedure`, `ToAll([target, ...])` (an open array; the targets are copied).

**`TPipeSource`** factory - `FromString(s, enc)`, `FromBytes(b)`, `FromStream(s)` (streams from the current position; a re-run sends the same data again), `FromFile(path)` (streamed in chunks; a missing file raises `EVSoftProcessError` from `Execute*`), `Interactive`.

**`IInteractivePipeSource`** - `Write(bytes|text)`, `Close`, `IsClosed`, `WaitForData(timeoutMs)`.

Constants in `VSoft.Process`: `EXIT_OK = 0`, `EXIT_TERMINATED = 9999`, `EXIT_TIMEDOUT = 8888` (defaults; override via the corresponding `StartInfo` properties), `DEFAULT_PIPE_DRAIN_TIMEOUT_MS = 2000`.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt) for details.

Copyright (c) Vincent Parrett and contributors.

## Contributing

Bug reports, fixes, and PRs are welcome. Please:

- Keep code XE2-compatible: no inline `var`, no string helpers (`s.Contains(...)`, `s.ToLower`, ...), no type inference.
- Use camelCase for locals and parameters, lowercase `result`, and `F`-prefixed class fields.
- Add or update tests under [Tests/](Tests/) for any behaviour change;
- Use CRLF line endings.
