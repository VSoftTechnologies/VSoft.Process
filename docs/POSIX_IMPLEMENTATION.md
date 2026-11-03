# POSIX implementation (`VSoft.Process.Posix.pas`)

Maintainer notes for `TPosixProcess`, shared by Linux (epoll) and macOS (kqueue). The run lifecycle in `VSoft.Process.Base.pas` (publish-last status, serialised and exception-isolated delivery, re-run guard, Terminate) is described in [WINDOWS_IMPLEMENTATION.md](WINDOWS_IMPLEMENTATION.md#run-lifecycle-shared-with-posix-vsoftprocessbasepas).

> Status: compiles for Linux64, macOS x64 and macOS arm64. The test suite passes on Linux x64 (WSL, Ubuntu 24.04) and macOS arm64; macOS x64 has only been compiled.

## Host-wide side effect

The unit's initialization sets SIGPIPE to `SIG_IGN` for the whole host process, so a write to a child that has gone away fails with `EPIPE` instead of killing the host. Children get `SIG_DFL` back before `execve`.

## Launch (`DoCreateProcess`)

- **Pipes** come from `pipe2(O_CLOEXEC)` on Linux and from `pipe` + `FD_CLOEXEC` on macOS, under `GSpawnLock` so our own concurrent spawns can't inherit each other's pipes in the macOS window (a fork elsewhere in the host can still catch it). Any end that lands on fd 0..2 (host started with closed stdio) is moved to fd 3 or above, so `dup2` in the child never targets its own source. `PipeBufferSize` (0 = 64 KB) only sizes our read buffer; the kernel's pipe capacity is not changed.
- **Everything the child needs** (argv, `/bin/sh` fallback argv, envp, resolved path, working directory, `/dev/null`, an empty signal mask, nice value, affinity mask, maximum fd, and the `environ` pointer, because `Posix.Unistd.environ` uses `dlsym` on Linux) is built in the parent into a `TChildSetup` before `fork()`. `RunChild` makes only async-signal-safe calls.
- **argv** is `ArgvZero` (or `Executable` as written) followed by the arguments, verbatim: there is no shell and no quoting, so `Quoted` is ignored. An argument with `NameValueSeparator = ' '` becomes two slots; any other separator joins name and value into one. `Add('', '')` is an empty slot.
- **envp** is built from `Environment` only when it has overrides; otherwise the parent's `environ` is passed. Variable names are case-sensitive.
- **In the child:**
  1. `setpgid(0,0)` when using a process group (the parent also calls `setpgid`, so the group exists before any signal can be sent).
  2. Reset the signal mask, and SIGPIPE/SIGXFSZ to `SIG_DFL`. Ignored dispositions survive `execve`.
  3. Set affinity (Linux only, CPUs 0..31 from the 32-bit `ProcessorAffinity`) and the nice value (`Idle` 19, `BelowNormal` 10, `AboveNormal` -10, which needs `CAP_SYS_NICE` / root). Failures here and in `setpgid` are ignored.
  4. `dup2` the stdio. A stream that isn't redirected keeps the parent's handle unless it is closed, in which case it gets `/dev/null`.
  5. Close fds ≥ 3: on Linux 5.11+ `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` marks them close-on-exec; otherwise a loop closes fds 3 up to `sysconf(_SC_OPEN_MAX)` (capped at 65536), skipping the error pipe.
  6. `chdir`, then `execve`, with a `/bin/sh` retry on `ENOEXEC`.
- **Child init errors** (`dup2`, `chdir`, `execve`, with errno) reach the parent through a CLOEXEC self-pipe. EOF means `execve` succeeded.
- **Executable resolution** happens in the parent at validation (`ResolveExecutable`). A path containing `/` is made absolute against our current directory. A bare name is searched in this process's `PATH` (`/usr/bin:/bin` when that is empty; the `PATH` in `Environment` is never used, so the child can be given a constrained one), skipping empty and relative entries. The file found must not be a directory and must pass `access(X_OK)`. `execve` is always used.
- **Process group.** The child gets its own group (and therefore tree-wide signals) unless our stdin is a tty that the child inherits. That child must stay in our foreground group or reading the terminal stops it with SIGTTIN.
- **Credentials** are not supported: configuring any is a validation error.
- **One start at a time.** `ClaimRun` in the base class stops two threads from both starting the same object (see [WINDOWS_IMPLEMENTATION.md](WINDOWS_IMPLEMENTATION.md#run-lifecycle-shared-with-posix-vsoftprocessbasepas)).

## Wait loop (`DoWaitForCompletion`)

A loop of time slices (≤ 100 ms) moves through Running → Killing → Draining:

- `WaitForEvents` blocks in `epoll_wait` / `kevent`. The event instance is created even when nothing is redirected, and it also watches the child: a `pidfd` (`pidfd_open`, Linux 5.3+, via `syscall`) or `EVFILT_PROC NOTE_EXIT`. Exit therefore wakes the loop at once, and a run without redirection doesn't spin. Without either, exit is noticed within a slice. Once the child is reaped, `UnwatchChildExit` removes the pidfd from the epoll set and closes it: it stays readable after the exit and would otherwise wake every wait at once, a busy loop for as long as the pipes are drained. `EVFILT_PROC` is one-shot, so macOS has nothing to remove. If the event instance can't be created (logged), each pass sleeps for the slice and then reads the pipes.
- The read fds are `O_NONBLOCK`. `DrainFd` reads until `EAGAIN`, at most 16 reads per wake so stdout and stderr interleave fairly, and retries on `EINTR`. It closes a stream when `read()` returns 0 or fails with anything other than `EAGAIN`; a hang-up alone doesn't mean the pipe is empty.
- `TryReap` uses `waitpid(WNOHANG)`. A failure (`ECHILD`: reaped elsewhere, or SIGCHLD ignored) is reported as an unknown status (`Exited`, ExitCode `$FFFFFFFF`, logged), never as success.
- On timeout, cancel or Terminate: SIGTERM to the group (or the child), keep reading, SIGKILL after 500 ms. If the child still isn't reaped 5 s after SIGKILL (stuck in the kernel), the loop logs it and stops waiting; `ReapWhenExited` then reaps it whenever it does exit. Signals are only sent while the child is unreaped, so the pid can't have been recycled.
- Exit codes: a normal exit reports `WEXITSTATUS`. A child ended by a signal we didn't send reports `Terminated` with 128 + the signal number. When we killed it, the run reports `TerminateExitCode` or `TimedOutExitCode`, whatever signal ended it.
- On a timeout with `TerminateOnTimeout = False` the loop stops without signalling. The finally block reads what is already in the pipes (`DrainFd`, bounded), closes every fd (a later write by the child gets SIGPIPE / EPIPE) and starts `ReapWhenExited`, a small thread that blocks in `waitpid` for that pid so the child does not become a zombie. `JobMode` has no runtime effect on POSIX, but the validation rule that rejects `TerminateOnTimeout = False` with `JobMode = KillOnRelease` applies on every platform, so a configuration is valid everywhere or nowhere.
- After the child is reaped, the loop keeps reading until both pipes reach EOF or `PipeDrainTimeoutMS` elapses (always bounded after a kill; unbounded after a normal exit when it is `INFINITE`). Hitting the timeout is logged as possible truncation. After a normal exit, Terminate or cancellation (`IsStopRequested`) ends the drain at once, also logged as possible truncation; nothing is signalled, because the child has been reaped. After a normal exit the bytes still in each pipe are taken with `ioctl(FIONREAD)` (`FStdOutUnread` / `FStdErrUnread`). `DrainFd` pays them off, and the drain clock starts only once both are paid, so a slow target never loses the child's own output. `ioctl` is declared locally as `varargs` (Apple arm64 passes variadic arguments on the stack).
- The finally block fills in the outcome (the base class publishes it after `StopPipeTargets`), stops the stdin writer (closes an interactive source, sets the abort flag and waits up to 1 s for it; see below) and closes every fd.

## Stdin writer

The write end is `O_NONBLOCK`. The writer retries on `EINTR`, waits in `poll(POLLOUT, 100 ms)` on `EAGAIN` so it notices the abort flag, stops on any other write error (`EPIPE` when the child closed stdin or exited), and closes the write end when it finishes, which is EOF for the child.

Each run's writer is a `TPosixStdInWriter` (`TStdInWriter` in `VSoft.Process.Base.pas`) that owns the write end and holds the source, the abort flag and any error; the process doesn't keep the fd. The thread is a self-freeing anonymous `TThread` that holds a reference to the writer, and the writer holds one to the process until it finishes. Its id is set in `FStdInWriterThreadId` before it starts, and the writer clears it with a compare-exchange when it finishes, only if it is still its own. `StopStdInWriter` waits up to 1 s for the writer. One that is still blocked in its source's `GetData` is logged and left to finish on its own, without touching the next run.

## Detached launches

A double fork: the first child calls `setsid`, the grandchild runs `RunChild` with `/dev/null` stdio and no process group, and the first child exits immediately so init adopts the grandchild. Exec failures still come back through the self-pipe.

## Platform notes

| | Linux | macOS |
|---|---|---|
| Event API | `epoll`, level-triggered (`TPlatformEvent` is the **packed** 12-byte `epoll_event`) | `kqueue` (32-byte `kevent`) |
| Child exit wake-up | `pidfd_open` (5.3+) | `EVFILT_PROC` / `NOTE_EXIT` (`$80000000`), one-shot |
| CLOEXEC pipes | `pipe2` | `pipe` + `fcntl` under `GSpawnLock` |
| Closing inherited fds | `close_range` (5.11+), else a loop | loop |
| Processor affinity | `sched_setaffinity`, CPUs 0..31 | not available |

`fcntl` and `syscall` are variadic. They must be declared `varargs` with only their fixed parameters, because Apple arm64 passes variadic arguments on the stack. The `pidfd_open` (434) and `close_range` (436) syscall numbers are the x86-64 ones.

`TSystemUtils.TerminateProcessTree` (`VSoft.Process.Utils.pas`) has a POSIX branch, but `TPosixProcess` doesn't use it: it signals the child or its group itself (`SignalChild`).
