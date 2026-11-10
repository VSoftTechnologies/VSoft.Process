# POSIX implementation (`VSoft.Process.Posix.pas`)

Maintainer notes for `TPosixProcess`, shared by Linux (epoll) and macOS (kqueue). The run lifecycle in `VSoft.Process.Base.pas` (publish-last status, serialised and exception-isolated delivery, re-run guard, Terminate) is described in [WINDOWS_IMPLEMENTATION.md](WINDOWS_IMPLEMENTATION.md#run-lifecycle-shared-with-posix-vsoftprocessbasepas).

> Status: compiles for Linux64, macOS x64 and macOS arm64. The test suite passes on Linux x64 (WSL, Ubuntu 24.04) and macOS arm64; macOS x64 has only been compiled. The latest changes (listing the open descriptors in the child, the unreaped group leader and group check on a kill, exit polling without an exit watch, the terminal-stop check, no spawn lock) have been run on Linux on that one kernel only; their macOS-specific code paths (`proc_pidinfo`, `proc_listpgrppids`, the `NOTE_EXIT` handling) have been compiled but not run.
>
> Supported targets: Linux x86-64 and 64-bit macOS (x64 and arm64). The unit starts with `{$MESSAGE FATAL}` guards for anything else (another Linux CPU, 32-bit macOS, iOS), because the record layouts (`epoll_event`, `kevent`, `timespec`), constants and system call numbers are those of these targets; the sizes of `TPlatformEvent` are checked at compile time too.

## Host-wide side effect

The unit's initialization sets SIGPIPE to `SIG_IGN` for the whole host process, so a write to a child that has gone away fails with `EPIPE` instead of killing the host. Children get `SIG_DFL` back before `execve`.

## Launch (`DoCreateProcess`)

- **Pipes** come from `pipe2(O_CLOEXEC)` on Linux and from `pipe` + `FD_CLOEXEC` on macOS. There is no spawn lock: the parent's ends of every running child's pipes are open in the host for the whole run, so any later fork copies them whatever was locked while they were created. What keeps them (and every other descriptor of the host) out of a new program is the child's own close step (step 5 below), and that is what isolates concurrent spawns. Any end that lands on fd 0..2 (host started with closed stdio) is moved to fd 3 or above, so `dup2` in the child never targets its own source. `PipeBufferSize` (0 = 64 KB) only sizes our read buffer; the kernel's pipe capacity is not changed.
- **Everything the child needs** (argv, `/bin/sh` fallback argv, envp, resolved path, working directory, `/dev/null`, an empty signal mask, nice value, affinity mask, maximum fd, and the `environ` pointer, because `Posix.Unistd.environ` uses `dlsym` on Linux) is built in the parent into a `TChildSetup` before `fork()`. `RunChild` makes only async-signal-safe calls.
- **argv** is `ArgvZero` (or `Executable` as written) followed by the arguments, verbatim: there is no shell and no quoting, so `Quoted` is ignored. An argument with `NameValueSeparator = ' '` becomes two slots; any other separator joins name and value into one. `Add('', '')` is an empty slot.
- **envp** is built from `Environment` only when it has overrides; otherwise the parent's `environ` is passed. Variable names are case-sensitive. The builder copies `environ` in one block at `Create` / `Reset` and splits it into variables only on first use (`EnsureLoaded`). An entry that is not valid UTF-8 is decoded with U+FFFD for the invalid bytes (`DecodeEnvironEntry`; it never raises) and its original bytes are kept (`FRawEntries`), so `ToEnvironArray` passes it on byte for byte unless the variable is set again.
- **In the child:**
  1. `setpgid(0,0)` when using a process group (the parent also calls `setpgid`, so the group exists before any signal can be sent).
  2. Reset the signal mask, and SIGPIPE/SIGXFSZ to `SIG_DFL`. Ignored dispositions survive `execve`.
  3. Set affinity (Linux only, CPUs 0..63 from the pointer-sized `ProcessorAffinity`) and the nice value (`Idle` 19, `BelowNormal` 10, `AboveNormal` -10, which needs `CAP_SYS_NICE` / root). Failures here and in `setpgid` are ignored.
  4. `dup2` the stdio. A stream that isn't redirected keeps the parent's handle unless it is closed, in which case it gets `/dev/null`.
  5. Close fds ≥ 3: on Linux 5.11+ `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` marks them close-on-exec. Without it (macOS, older kernels, seccomp profiles) `CloseOpenFds` closes the descriptors that are actually open, skipping the error pipe: on Linux it reads `/proc/self/fd` with `getdents64` directly (`opendir` / `readdir` allocate, so they can't be used between fork and exec), on macOS it lists them with `proc_pidinfo(PROC_PIDLISTFDS)`, again until nothing is left to close. So there is no cap on the descriptor number and the cost doesn't depend on `RLIMIT_NOFILE`. Only when the descriptors can't be listed does a loop close every number from 3 up to the limit (`MaxFd`: `sysconf(_SC_OPEN_MAX)`, capped at 65536).
  6. `chdir`, then `execve`, with a `/bin/sh` retry on `ENOEXEC`.
- **Child init errors** (`dup2`, `chdir`, `execve`, with errno) reach the parent through a CLOEXEC self-pipe. EOF means `execve` succeeded.
- **Executable resolution** happens in the parent at validation (`ResolveExecutable`). A path containing `/` is made absolute against our current directory. A bare name is searched in this process's `PATH` (`/usr/bin:/bin` when that is empty; the `PATH` in `Environment` is never used, so the child can be given a constrained one), skipping empty and relative entries. The file found must not be a directory and must pass `access(X_OK)`. `execve` is always used.
- **Process group.** The child gets its own group (and therefore tree-wide signals) unless our stdin is a tty that the child inherits. That child must stay in our foreground group or reading the terminal stops it with SIGTTIN. A child in its own group is in a background group for the controlling terminal; see the stop check in the wait loop.
- **Credentials** are not supported: configuring any is a validation error.
- **One start at a time.** `ClaimRun` in the base class stops two threads from both starting the same object (see [WINDOWS_IMPLEMENTATION.md](WINDOWS_IMPLEMENTATION.md#run-lifecycle-shared-with-posix-vsoftprocessbasepas)).

## Wait loop (`DoWaitForCompletion`)

A loop of time slices (≤ 100 ms) moves through Running → Killing → Draining:

- `WaitForEvents` blocks in `epoll_wait` / `kevent`. The event instance is created even when nothing is redirected, and it also watches the child: a `pidfd` (`pidfd_open`, Linux 5.3+, via `syscall`) or `EVFILT_PROC NOTE_EXIT`. Exit therefore wakes the loop at once, and a run without redirection doesn't spin. Without either (`FExitWatched` False: Linux before 5.3, seccomp-restricted containers), the exit is polled after 1, 2, 4 ... ms up to the 100 ms slice, rather than in fixed 100 ms slices, so a short-lived child isn't kept waiting for a whole slice and a long-lived one costs a handful of wake-ups. The steps start again at 1 ms when the exit is known to be close: both pipes have just reached EOF, or macOS has posted its one-shot `NOTE_EXIT` (it can arrive before the child can be reaped). Once the child is reaped, `UnwatchChildExit` removes the pidfd from the epoll set and closes it: it stays readable after the exit and would otherwise wake every wait at once, a busy loop for as long as the pipes are drained. `EVFILT_PROC` is one-shot, so macOS has nothing to remove. If the event instance can't be created (logged), each pass sleeps for the slice and then reads the pipes.
- The read fds are `O_NONBLOCK`. `DrainFd` reads until `EAGAIN`, at most 16 reads per wake so stdout and stderr interleave fairly, and retries on `EINTR`. It closes a stream when `read()` returns 0 or fails with anything other than `EAGAIN`; a hang-up alone doesn't mean the pipe is empty.
- `TryReap` uses `waitpid(WNOHANG | WUNTRACED)`. A failure (`ECHILD`: reaped elsewhere, or SIGCHLD ignored) is reported as an unknown status (`Exited`, ExitCode `$FFFFFFFF`, logged), never as success.
- **Stopped by the terminal.** `WUNTRACED` makes a stopped child visible; without it, it would look like one that is still running for as long as nothing continues it. A child in its own process group is in a background group, so the kernel stops it with SIGTTIN / SIGTTOU when it uses the controlling terminal, and nothing would ever continue it. When the direct child is stopped by one of those two signals the run is failed: the reason is logged, SIGTERM and then SIGCONT are sent (a stopped process only acts on SIGTERM once it is continued) and the run ends as `Terminated`. Only with a group of its own: in our group we would have been stopped with it, and the shell continues the whole job. A stopped grandchild is not seen (only the child is waited for), and a stop by SIGSTOP / SIGTSTP is left alone.
- On timeout, cancel or Terminate: SIGTERM to the group (or the child), keep reading, SIGKILL after 500 ms. If the child still isn't reaped 5 s after SIGKILL (stuck in the kernel), the loop logs it and stops waiting; `ReapWhenExited` then reaps it whenever it does exit. Signals are only sent while the child is unreaped, so the pid can't have been recycled.
  - **Group members that outlive the child.** With a process group, the child is not reaped between SIGTERM and SIGKILL when it exits: `HasExited` (`waitid` with `WEXITED | WNOWAIT | WNOHANG`) only looks. The group may hold members that ignore or outlive SIGTERM, and only an unreaped leader keeps the group id from being reused before they get their SIGKILL.
  - **When SIGKILL goes.** Once the leader has exited, SIGKILL is sent to the group when the 500 ms are over, or at once when `GroupHasOtherMembers` finds no other live member, so the usual Terminate doesn't wait for it. The group is looked at after 1, 2, 4 ... up to 50 ms. Then the leader is reaped. Terminate / a timeout can therefore take up to about 500 ms when such members exist.
  - **`GroupHasOtherMembers`.** On Linux it walks `/proc` and reads the process group and state from each `/proc/<pid>/stat` (zombies don't count); on macOS it uses `proc_listpgrppids`. When it can't tell, it answers True, which means waiting out the 500 ms.
  - **Without a group** (the child inherits our terminal stdin) only the child is signalled and it is reaped as soon as it exits, as before.
- Exit codes: a normal exit reports `WEXITSTATUS`. A child ended by a signal we didn't send reports `Terminated` with 128 + the signal number. When we killed it, the run reports `TerminateExitCode` or `TimedOutExitCode`, whatever signal ended it.
- On a timeout with `TerminateOnTimeout = False` the loop stops without signalling. The finally block reads what is already in the pipes (`DrainFd`, bounded), closes every fd (a later write by the child gets SIGPIPE / EPIPE) and starts `ReapWhenExited`, a small thread that blocks in `waitpid` for that pid so the child does not become a zombie. `JobMode` has no runtime effect on POSIX, but the validation rule that rejects `TerminateOnTimeout = False` with `JobMode = KillOnRelease` applies on every platform (to `Execute` / `ExecuteAsync`; `ExecuteDetached` ignores both settings), so a configuration is valid everywhere or nowhere.
- After the child is reaped, the loop keeps reading until both pipes reach EOF or `PipeDrainTimeoutMS` elapses (always bounded after a kill; unbounded after a normal exit when it is `INFINITE`). Hitting the timeout is logged as possible truncation. After a normal exit, Terminate or cancellation (`IsStopRequested`) ends the drain at once, also logged as possible truncation; nothing is signalled, because the child has been reaped. After a normal exit the bytes still in each pipe are taken with `ioctl(FIONREAD)` (`FStdOutUnread` / `FStdErrUnread`). `DrainFd` pays them off, and the drain clock starts only once both are paid, so a slow target never loses the child's own output. `ioctl` is declared locally as `varargs` (Apple arm64 passes variadic arguments on the stack).
- The finally block fills in the outcome (the base class publishes it after `StopPipeTargets`), stops the stdin writer (closes an interactive source, sets the abort flag and waits up to 1 s for it; see below) and closes every fd.

## Stdin writer

`TPipeSource.FileAsStdIn` (`IFileStdInPipeSource`) has no writer. Its `Start` opens the file (shared with writers, `fmShareDenyNone`, as `FromFile` does). `DoCreateProcess` takes an `F_DUPFD_CLOEXEC` copy (at 3 or above, like the pipe ends) of that fd in place of the stdin pipe and passes it to `RunChild` as `stdinFd`, so the existing `dup2` makes the file the child's fd 0. The copy is closed with the other child ends after `fork`.

The write end is `O_NONBLOCK`. The writer retries on `EINTR`, waits in `poll(POLLOUT, 100 ms)` on `EAGAIN` so it notices the abort flag, stops on any other write error (`EPIPE` when the child closed stdin or exited), and closes the write end when it finishes, which is EOF for the child.

Each run's writer is a `TPosixStdInWriter` (`TStdInWriter` in `VSoft.Process.Base.pas`) that owns the write end and holds the source, the abort flag and any error; the process doesn't keep the fd. The thread is a self-freeing anonymous `TThread` that holds a reference to the writer, and the writer holds one to the process until it finishes. Its id is set in `FStdInWriterThreadId` before it starts, and the writer clears it with a compare-exchange when it finishes, only if it is still its own. `StopStdInWriter` waits up to 1 s for the writer. One that is still blocked in its source's `GetData` is logged and left to finish on its own, without touching the next run.

## Detached launches

A double fork: the first child calls `setsid`, the grandchild runs `RunChild` with `/dev/null` stdio and no process group, and the first child exits immediately so init adopts the grandchild. Exec failures still come back through the self-pipe.

## Platform notes

| | Linux | macOS |
|---|---|---|
| Event API | `epoll`, level-triggered (`TPlatformEvent` is the **packed** 12-byte `epoll_event`) | `kqueue` (32-byte `kevent`) |
| Child exit wake-up | `pidfd_open` (5.3+), else polled in 1, 2, 4 ... 100 ms steps | `EVFILT_PROC` / `NOTE_EXIT` (`$80000000`), one-shot |
| CLOEXEC pipes | `pipe2` | `pipe` + `fcntl` |
| Closing inherited fds | `close_range` (5.11+), else the fds listed in `/proc/self/fd` (`getdents64`), else a loop | the fds listed by `proc_pidinfo`, else a loop |
| Other members of the group | `/proc/<pid>/stat` | `proc_listpgrppids` |
| CPU | x86-64 only | x64 and arm64 |
| Processor affinity | `sched_setaffinity`, CPUs 0..63 | not available |

`fcntl` and `syscall` are variadic. They must be declared `varargs` with only their fixed parameters, because Apple arm64 passes variadic arguments on the stack. The `getdents64` (217), `pidfd_open` (434) and `close_range` (436) syscall numbers are the x86-64 ones, which the compile-time guard at the top of the unit enforces.

`TSystemUtils.TerminateProcessTree` (`VSoft.Process.Utils.pas`) has a POSIX branch, but `TPosixProcess` doesn't use it: it signals the child or its group itself (`SignalChild`).
