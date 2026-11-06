unit VSoft.Process.Tests.ProcessE2E;

interface

uses
  DUnitX.TestFramework,
  {$IFDEF MSWINDOWS}
  WinAPi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  // End-to-end tests that spawn real child processes via batch script fixtures
  // in Tests\scripts\. Each script is small and produces a known, deterministic
  // output so we can assert on the exact bytes the library captured.
  //
  // What these tests prove that the unit-level tests cannot:
  //  - C1/C4 reach the child: large stdout (>64KB) round-trips byte-exact via
  //    every pipe target shape (stream, file, line method).
  //  - StdErr is captured separately from stdout (separate pipe).
  //  - StdIn redirection works for both static-source and interactive-source.
  //  - StartInfo.WorkingDirectory actually changes the child's CWD.
  //  - Environment overrides actually reach the child's env block.
  //  - Per-arg quoting (M8) survives the round trip through CreateProcess and
  //    is parsed back into individual args by the child.
  //  - ExecuteAsync + CancellationToken stops a running child.
  [TestFixture]
  TProcessE2ETests = class
  public
    [Setup]
    procedure SetUp;

    [Test]
    procedure StdOut_LargeOutputCaptured;

    [Test]
    procedure StdOut_LargeOutputToFile_RoundTripsByteExact;

    [Test]
    procedure StdErr_CapturedSeparatelyFromStdOut;

    [Test]
    procedure StdIn_FromStringSource_SentToChild;

    [Test]
    procedure StdIn_FromInteractiveSource_SentToChild;

    [Test]
    procedure WorkingDirectory_SetCorrectlyForChild;

    [Test]
    procedure Environment_OverrideReachesChild;

    [Test]
    procedure Environment_RemoveStripsFromChild;

    // Environment.Clear: the child sees only what was added after Clear,
    // none of the host's variables.
    [Test]
    procedure Environment_ClearReachesChild;

    [Test]
    procedure ExitCode_PropagatesNonZero;

    [Test]
    procedure CommandLine_ArgWithSpaces_ReachesChildIntact;

    [Test]
    procedure CommandLine_ArgWithEmbeddedQuote_ReachesChildIntact;

    [Test]
    procedure CommandLine_MultipleArgs_AllReachChildInOrder;

    [Test]
    procedure Pipe_LineTargetReceivesAllLinesInOrder;

    [Test]
    procedure Pipe_MultiTargetFansOutToTwoStreams;

    [Test]
    procedure ExecuteAsync_CancellationStopsRunningChild;

    // README example 8 - the cancellation API also accepts a TEvent (the other
    // ExecuteAsync overload). This proves the TEvent path stops a running child
    // the same way an ICancellationToken does.
    [Test]
    procedure ExecuteAsync_CancellationViaTEvent_StopsRunningChild;

    [Test]
    procedure ExecuteAsync_TimedOut_FlagSet;

    // W1 - HideWindow := False used to be a silent no-op (the Windows impl
    // hardcoded SW_HIDE). With the fix the property is honoured; an E2E
    // smoke test launches with HideWindow=False and verifies the process
    // still runs to completion. We cannot reliably assert window visibility
    // from automated tests; the value-add is "it no longer breaks".
    [Test]
    procedure StartInfo_HideWindowFalse_StillExecutes;

    // W3 - When credentials are misconfigured (UPN user + Domain), Execute
    // must refuse to launch and report the error in proc.Errors.
    [Test]
    procedure Credentials_InvalidConfiguration_ExecuteReturnsFalse;

    // W2 - When the user attaches a line target with no explicit encoding,
    // StartInfo.OutputEncoding becomes the default. Without this fix the
    // line target would silently fall back to TEncoding.Default.
    [Test]
    procedure StartInfo_OutputEncoding_FlowsToImplicitLineTarget;

    // README example 10 (multi-target fan-out) shows the canonical
    // ToFile + ToLineDelegate pairing. Pipe_MultiTargetFansOutToTwoStreams
    // already covers two stream targets; this one specifically exercises
    // mixing a byte-oriented target (file) with a line-oriented one
    // (delegate) under the same TPipeTarget.ToAll wrapper.
    [Test]
    procedure Pipe_MultiTargetFileAndLineDelegate_BothReceive;

    // L7 - Tree-kill verification. We spawn a script (spawn-and-wait) that
    // launches a long-running grandchild and prints its PID, then sleeps.
    // After capturing the grandchild PID we Terminate the IProcess and
    // assert the grandchild is gone (kill(pid, 0) returns ESRCH on POSIX,
    // OpenProcess fails / process is signalled on Windows). Without the
    // Job Object / setpgid plumbing the grandchild would survive Terminate.
    [Test]
    procedure Terminate_KillsGrandchildProcessTree;

    // C3 - Stdin pipe source's Start and Done used to fire twice per run
    // (once from TProcessBase.StartPipeTargets, once from the writer thread).
    // Stateful sources (TFilePipeSource, etc.) saw "already open" mis-ordering.
    // This test attaches a counting source and asserts Start / Done each
    // fire exactly once across a real Execute.
    [Test]
    procedure StdIn_SourceStartDoneCalledExactlyOnce;

    // C6 - Windows historically resolved an executable via lpCommandLine
    // parsing, which truncated paths at the first space (e.g.
    // "C:\Program Files\foo.exe" would try "C:\Program.exe" first). After
    // the fix CreateProcess receives lpApplicationName separately, so a
    // path with spaces resolves cleanly.
    [Test]
    procedure Execute_ExecutablePathWithSpacesResolves;

    // H2 (positive) - StartInfo.MarshallEventsToMainThread := True queues
    // OnExit onto the main thread via TThread.Queue so UI handlers are safe.
    [Test]
    procedure ExecuteAsync_MarshallEventsToMainThread_OnExitFiresOnMainThread;

    // H2 (negative / default) - Without MarshallEventsToMainThread, OnExit
    // is invoked from the worker thread that owns DoWaitForCompletion.
    [Test]
    procedure ExecuteAsync_DefaultThreading_OnExitFiresOnWorkerThread;

    // M3 - StartInfo.PipeBufferSize lets the caller shrink (or grow) the
    // named-pipe / threadpool read buffer. A 4 KB buffer must still deliver
    // every byte from a >64 KB stdout stream - it just takes more reads.
    [Test]
    procedure StartInfo_SmallPipeBufferSize_StillReceivesAllOutput;

    // H4 (Windows) - ExecuteDetached used to drop the priority on the
    // floor. The fix sets the corresponding priority class via the
    // creation flags; we observe it via GetPriorityClass on the detached
    // child's process handle.
    [Test]
    procedure ExecuteDetached_AppliesPriority;

    // C5 - Terminate must publish Status = Terminated AND the caller-
    // supplied TerminateExitCode (not the SIGKILL / TerminateProcess
    // raw exit value).
    [Test]
    procedure Terminate_SetsStatusTerminatedAndConfiguredExitCode;

    // C5 - Timeout must publish Status = TimedOut AND TimedOutExitCode.
    // The Windows / POSIX implementations diverged on the enum before
    // the fix (POSIX reported Terminated for the same scenario).
    [Test]
    procedure Timeout_SetsStatusTimedOutAndConfiguredExitCode;

    // M4 - ExecuteAsync(TEvent) used to skip the pre-flight cancellation
    // check that the token overload had. A pre-signalled event must now
    // make ExecuteAsync return False without launching the child.
    [Test]
    procedure ExecuteAsyncWithEvent_PreSignalledReturnsFalse;

    // Smoke test for IProcess.ProcessId - while a child is alive its PID
    // must match what OpenProcess can find.
    [Test]
    procedure ProcessId_PopulatedAndMatchesLiveChild;

    // The same IProcess can be Execute'd twice; the second run must see
    // a clean Idle->Running->Exited state machine, not stale fields from
    // the first run.
    [Test]
    procedure Execute_RunTwice_StateResetBetweenRuns;
  end;

implementation

uses
  System.IOUtils,
  {$IFNDEF MSWINDOWS}
  Posix.Unistd,
  {$ENDIF}
  VSoft.Process.Tests.Common,
  {$IFDEF MSWINDOWS}
  // Polyfills BELOW_NORMAL_PRIORITY_CLASS / ABOVE_NORMAL_PRIORITY_CLASS for
  // older Delphi versions that don't declare them in WinAPI.Windows.
  VSoft.Process.WinAPI,
  {$ENDIF}
  {$IFNDEF MSWINDOWS}
  Posix.Stdlib,
  Posix.SysTypes,
  Posix.Signal,
  {$ENDIF}
  VSoft.CancellationToken;

procedure TProcessE2ETests.SetUp;
begin
  // Fails the fixture early (with a clear message) when the scripts folder
  // cannot be found next to the test exe.
  TTestHelpers.ScriptsDir;
end;

// The exact text print-large writes for count lines.
function ExpectedLargeOutput(count : integer) : string;
var
  sb : TStringBuilder;
  i : integer;
begin
  sb := TStringBuilder.Create;
  try
    for i := 1 to count do
      sb.Append('line ').Append(i).Append(': the quick brown fox jumps over the lazy dog 0123456789').Append(sLineBreak);
    result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TProcessE2ETests.StdOut_LargeOutputCaptured;
const
  cLineCount = 2000;
var
  proc : IProcess;
  output : TStringBuilder;
  text : string;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'script should exit 0');
    // Taken once: every ToString call builds a new ~144 KB string.
    text := output.ToString;
    Assert.AreEqual(cLineCount, TTestHelpers.CountChar(text, #10),
                    'Should have captured all 2000 lines (~144 KB across many pipe reads)');
    Assert.AreEqual(ExpectedLargeOutput(cLineCount), text, False,
                    'The captured text differs from what the script printed');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.StdOut_LargeOutputToFile_RoundTripsByteExact;
const
  cLineCount = 1500;
var
  proc : IProcess;
  outFile : string;
  fileBytes : TBytes;
  expected : TBytes;
  i : integer;
begin
  outFile := TTestHelpers.TempFileName('vsoft_proc_e2e_', '.txt');
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
    proc.WithStdOutPipe(TPipeTarget.ToFile(outFile, False));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.IsTrue(FileExists(outFile), 'output file should exist');

    fileBytes := TTestHelpers.ReadFileBytes(outFile);

    // Validate the byte-level content: pre-C1-fix, the file would have been
    // full of pointer/stack garbage instead of script output. Compare every
    // byte with what the script prints (pure ASCII).
    Assert.IsTrue(Length(fileBytes) > 64 * 1024,
                  'output should exceed 64 KB to cover multiple pipe reads');
    expected := TEncoding.ASCII.GetBytes(ExpectedLargeOutput(cLineCount));
    Assert.AreEqual(Length(expected), Length(fileBytes),
                    'The file is not the size of the output printed');
    for i := 0 to High(expected) do
      if fileBytes[i] <> expected[i] then
        Assert.Fail(Format('The file differs from the output printed at byte %d', [i]));
  finally
    if FileExists(outFile) then
      DeleteFile(outFile);
  end;
end;

procedure TProcessE2ETests.StdErr_CapturedSeparatelyFromStdOut;
var
  proc : IProcess;
  outSB, errSB : TStringBuilder;
  outText, errText : string;
begin
  outSB := TStringBuilder.Create;
  errSB := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(outSB, TEncoding.Default));
    proc.WithStdErrPipe(TPipeTarget.ToStringBuilder(errSB, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    outText := outSB.ToString;
    errText := errSB.ToString;
    Assert.Contains(outText, 'this-is-stdout',
                    'stdout pipe must carry the stdout line');
    Assert.IsFalse(Pos('this-is-stderr', outText) > 0,
                   'stdout must NOT contain the stderr line');
    Assert.Contains(errText, 'this-is-stderr',
                    'stderr pipe must carry the stderr line');
    Assert.IsFalse(Pos('this-is-stdout', errText) > 0,
                   'stderr must NOT contain the stdout line');
  finally
    outSB.Free;
    errSB.Free;
  end;
end;

procedure TProcessE2ETests.StdIn_FromStringSource_SentToChild;
var
  proc : IProcess;
  output : TStringBuilder;
  newline : string;
begin
  output := TStringBuilder.Create;
  try
    // CRLF on Windows so cmd.exe's findstr treats each as a line boundary;
    // LF on POSIX where `cat` doesn't care but findstr-style readers expect
    // the native newline.
    {$IFDEF MSWINDOWS}
    newline := #13#10;
    {$ELSE}
    newline := #10;
    {$ENDIF}
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
    proc.WithStdInPipe(TPipeSource.FromString('alpha' + newline + 'beta' + newline + 'gamma' + newline,
                                              TEncoding.Default));
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(output.ToString, 'alpha', 'stdin line 1 missing from echo output');
    Assert.Contains(output.ToString, 'beta',  'stdin line 2 missing from echo output');
    Assert.Contains(output.ToString, 'gamma', 'stdin line 3 missing from echo output');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.StdIn_FromInteractiveSource_SentToChild;
var
  proc    : IProcess;
  output  : TStringBuilder;
  stdin   : IInteractivePipeSource;
  start   : TDateTime;
  newline : string;
begin
  {$IFDEF MSWINDOWS}
  newline := #13#10;
  {$ELSE}
  newline := #10;
  {$ENDIF}
  output := TStringBuilder.Create;
  try
    stdin := TPipeSource.Interactive;
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
    proc.WithStdInPipe(stdin);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.ExecuteAsync;

    // Feed lines incrementally so we exercise the WaitForData wake path (H3).
    stdin.Write('first-interactive-line' + newline);
    Sleep(50);
    stdin.Write('second-interactive-line' + newline);
    Sleep(50);
    stdin.Write('third-interactive-line' + newline);
    stdin.Close; // signal EOF so the reader exits

    // Wait for the child to drain stdin and exit.
    start := Now;
    while (proc.Status = TProcessStatus.Running) and
          ((Now - start) * 86400 < 10) do
      Sleep(20);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'child should exit after stdin EOF');
    Assert.Contains(output.ToString, 'first-interactive-line');
    Assert.Contains(output.ToString, 'second-interactive-line');
    Assert.Contains(output.ToString, 'third-interactive-line');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.WorkingDirectory_SetCorrectlyForChild;
var
  proc : IProcess;
  output : TStringBuilder;
  desiredCwd : string;
  outText : string;
begin
  // Use TempPath - it definitely exists and is unrelated to the test exe's
  // own working dir, so we can verify the cwd really took effect.
  desiredCwd := ExcludeTrailingPathDelimiter(TPath.GetTempPath);

  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.WorkingDirectory := desiredCwd;
    TTestHelpers.SetupShellCommand(proc, 'print-cwd', []);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    // Case-insensitive compare on Windows is fine. On POSIX the temp path
    // is reported as-is by `pwd`; lowercasing both sides is harmless because
    // /tmp / /var/folders/... are already lowercase. On macOS `pwd` may
    // return the realpath form (/private/var/folders/...) where GetTempPath
    // returned the symlink form (/var/folders/...). Match on the trailing
    // segment of the temp path to tolerate that.
    outText := output.ToString;
    {$IFDEF MACOS}
    Assert.IsTrue(Pos(LowerCase(ExtractFileName(desiredCwd)), LowerCase(outText)) > 0,
                  Format('Child cwd should reference %s but output was: %s',
                         [desiredCwd, outText]));
    {$ELSE}
    Assert.IsTrue(Pos('cwd=' + LowerCase(desiredCwd), LowerCase(outText)) > 0,
                  Format('Child cwd should be %s but output was: %s',
                         [desiredCwd, outText]));
    {$ENDIF}
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.Environment_OverrideReachesChild;
const
  cVarName  = 'VSOFT_E2E_OVERRIDE';
  cVarValue = 'value-from-test-suite';
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.Environment.AddOrSet(cVarName, cVarValue);
    TTestHelpers.SetupShellCommand(proc, 'print-env', [cVarName]);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(output.ToString, cVarName + '=' + cVarValue,
                    'Override env var must reach the child');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.Environment_RemoveStripsFromChild;
const
  cVarName = 'VSOFT_E2E_TO_REMOVE';
var
  proc : IProcess;
  output : TStringBuilder;
begin
  // Plant the variable in OUR process env, then have the child explicitly
  // remove it via the builder, then verify the child does NOT see it.
  TTestHelpers.SetEnvVar(cVarName, 'should-not-be-visible-in-child');
  try
    output := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.HideWindow := True;
      proc.Environment.Remove(cVarName);
      TTestHelpers.SetupShellCommand(proc, 'print-env', [cVarName]);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
      proc.Execute(nil);

      Assert.AreEqual<Cardinal>(0, proc.ExitCode);
      // When the var doesn't exist the script prints NAME= (or NAME=%NAME%
      // on cmd's un-expanded form). The KEY assertion is that the original
      // value does not appear.
      Assert.IsFalse(Pos('should-not-be-visible-in-child', output.ToString) > 0,
                     'Removed var must not reach the child');
    finally
      output.Free;
    end;
  finally
    TTestHelpers.UnsetEnvVar(cVarName);
  end;
end;

procedure TProcessE2ETests.Environment_ClearReachesChild;
const
  cHostVar  = 'VSOFT_E2E_HOST_ONLY';
  cAddedVar = 'VSOFT_E2E_AFTER_CLEAR';
var
  proc : IProcess;
  output : TStringBuilder;
begin
  TTestHelpers.SetEnvVar(cHostVar, 'host-value');
  try
    output := TStringBuilder.Create;
    try
      proc := TProcess.Create;
      proc.StartInfo.HideWindow := True;
      proc.Environment.Clear.AddOrSet(cAddedVar, 'added-value');
      {$IFDEF MSWINDOWS}
      // cmd.exe (like most Windows programs) needs SystemRoot.
      proc.Environment.AddOrSet('SystemRoot', GetEnvironmentVariable('SystemRoot'));
      {$ENDIF}
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));

      TTestHelpers.SetupShellCommand(proc, 'print-env', [cAddedVar]);
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.AreEqual<Cardinal>(0, proc.ExitCode);
      Assert.Contains(output.ToString, cAddedVar + '=added-value');

      proc.CommandLine.Clear;
      TTestHelpers.SetupShellCommand(proc, 'print-env', [cHostVar]);
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
      Assert.AreEqual<Cardinal>(0, proc.ExitCode);
      Assert.IsFalse(Pos('host-value', output.ToString) > 0,
                     'A cleared environment must not pass the host''s variables: ' + output.ToString);
    finally
      output.Free;
    end;
  finally
    TTestHelpers.UnsetEnvVar(cHostVar);
  end;
end;

procedure TProcessE2ETests.ExitCode_PropagatesNonZero;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['42']);
  proc.Execute(nil);
  Assert.AreEqual<Cardinal>(42, proc.ExitCode, 'Exit code from child must propagate');
end;

procedure TProcessE2ETests.CommandLine_ArgWithSpaces_ReachesChildIntact;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'echo-args',
                      ['hello', 'arg with spaces', 'trailing-paren)']);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(output.ToString, 'arg1=[hello]');
    Assert.Contains(output.ToString, 'arg2=[arg with spaces]',
                    'Multi-word arg must be passed as ONE arg, not multiple');
    Assert.Contains(output.ToString, 'arg3=[trailing-paren)]');
    Assert.Contains(output.ToString, 'total=3');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.CommandLine_ArgWithEmbeddedQuote_ReachesChildIntact;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  // Verifies that an arg containing embedded double quotes does NOT split
  // into multiple args. On Windows, cmd.exe represents a literal double
  // quote inside a quoted region as "" (two quotes), and that pair is
  // preserved verbatim in %~1. On POSIX the library passes the argv array
  // directly to execvp, so embedded quotes are completely transparent and
  // the child sees the raw byte sequence.
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'echo-args',
                      ['he said "hello"', 'next-arg']);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(output.ToString, 'arg2=[next-arg]',
                    'Subsequent arg must NOT be merged into the quoted one');
    Assert.Contains(output.ToString, 'total=2',
                    'Must be exactly 2 args, not 3+ due to corrupted quoting');
    Assert.Contains(output.ToString, 'hello',
                    'Embedded text must survive the round trip even with quotes around it');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.CommandLine_MultipleArgs_AllReachChildInOrder;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'echo-args', ['a', 'b', 'c', 'd', 'e']);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.Contains(output.ToString, 'arg1=[a]');
    Assert.Contains(output.ToString, 'arg2=[b]');
    Assert.Contains(output.ToString, 'arg3=[c]');
    Assert.Contains(output.ToString, 'arg4=[d]');
    Assert.Contains(output.ToString, 'arg5=[e]');
    Assert.Contains(output.ToString, 'total=5');
  finally
    output.Free;
  end;
end;

type
  TLineCollector = class
  public
    Lines : TStringList;
    Lock  : TCriticalSection;
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
  end;

constructor TLineCollector.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lock  := TCriticalSection.Create;
end;

destructor TLineCollector.Destroy;
begin
  Lines.Free;
  Lock.Free;
  inherited;
end;

procedure TLineCollector.OnLine(const line: string);
begin
  // The pipe target may invoke us from the IO worker thread; serialise.
  Lock.Enter;
  try
    Lines.Add(line);
  finally
    Lock.Leave;
  end;
end;

procedure TProcessE2ETests.Pipe_LineTargetReceivesAllLinesInOrder;
const
  cLineCount = 200;
var
  proc      : IProcess;
  collector : TLineCollector;
  i         : integer;
  expectedPrefix : string;
begin
  collector := TLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.AreEqual(cLineCount, collector.Lines.Count,
                    'Line target should receive every line emitted by the script');
    // Spot-check first and last to verify ordering preserved.
    expectedPrefix := 'line 1:';
    Assert.IsTrue(Copy(collector.Lines[0], 1, Length(expectedPrefix)) = expectedPrefix,
                  'First captured line should be "line 1:..."');
    expectedPrefix := 'line ' + IntToStr(cLineCount) + ':';
    i := collector.Lines.Count - 1;
    Assert.IsTrue(Copy(collector.Lines[i], 1, Length(expectedPrefix)) = expectedPrefix,
                  'Last captured line should be the final emitted line');
  finally
    collector.Free;
  end;
end;

procedure TProcessE2ETests.Pipe_MultiTargetFansOutToTwoStreams;
var
  proc    : IProcess;
  sb1, sb2 : TStringBuilder;
  inner   : TArray<IPipeTarget>;
  multi   : IPipeTarget;
begin
  sb1 := TStringBuilder.Create;
  sb2 := TStringBuilder.Create;
  try
    SetLength(inner, 2);
    inner[0] := TPipeTarget.ToStringBuilder(sb1, TEncoding.Default);
    inner[1] := TPipeTarget.ToStringBuilder(sb2, TEncoding.Default);
    multi := TPipeTarget.ToAll(inner);

    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-large', ['50']);
    proc.WithStdOutPipe(multi);
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.IsTrue(sb1.Length > 0, 'first target received nothing');
    Assert.IsTrue(sb2.Length > 0, 'second target received nothing');
    Assert.AreEqual(sb1.ToString, sb2.ToString,
                    'Both fan-out targets should receive identical content');
  finally
    sb1.Free;
    sb2.Free;
  end;
end;

procedure TProcessE2ETests.ExecuteAsync_CancellationStopsRunningChild;
var
  proc  : IProcess;
  token : ICancellationTokenSource;
  start : TDateTime;
begin
  token := TCancellationTokenSourceFactory.Create;

  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TerminateExitCode := 8765;
  // Sleep for 30 seconds so we definitely have time to cancel it.
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['30']);
  proc.ExecuteAsync(token.Token);

  Sleep(300);
  Assert.AreEqual(TProcessStatus.Running, proc.Status,
                  'Sanity: child should be running before cancellation');

  token.Cancel;

  // Wait for the worker to observe the cancellation and exit.
  start := Now;
  while (proc.Status = TProcessStatus.Running) and
        ((Now - start) * 86400 < 10) do
    Sleep(20);
  Assert.AreNotEqual(TProcessStatus.Running, proc.Status,
                     'Cancellation should have stopped the running child');
end;

procedure TProcessE2ETests.ExecuteAsync_TimedOut_FlagSet;
var
  proc : IProcess;
  start : TDateTime;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 500;
  proc.StartInfo.TimedOutExitCode := 4321;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  proc.ExecuteAsync;

  start := Now;
  while (proc.Status = TProcessStatus.Running) and
        ((Now - start) * 86400 < 5) do
    Sleep(20);
  Assert.IsTrue(proc.TimedOut,
                'TimedOut flag must be set when the timeout fires asynchronously');
  Assert.AreEqual<Cardinal>(4321, proc.ExitCode,
                            'Configured TimedOutExitCode should be reported');
end;

procedure TProcessE2ETests.ExecuteAsync_CancellationViaTEvent_StopsRunningChild;
var
  proc  : IProcess;
  evt   : TEvent;
  start : TDateTime;
begin
  // Manual-reset event because we may want to inspect / re-use it.
  evt := TEvent.Create(nil, True, False, '');
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.TerminateExitCode := 5432;
    TTestHelpers.SetupShellCommand(proc, 'sleep', ['30']);
    proc.ExecuteAsync(evt);

    Sleep(300);
    Assert.AreEqual(TProcessStatus.Running, proc.Status,
                    'Sanity: child should be running before TEvent signalled');

    evt.SetEvent;

    start := Now;
    while (proc.Status = TProcessStatus.Running) and
          ((Now - start) * 86400 < 10) do
      Sleep(20);
    Assert.AreNotEqual(TProcessStatus.Running, proc.Status,
                       'Signalling the cancellation TEvent must stop the running child');
  finally
    evt.Free;
  end;
end;

type
  TFanOutLineSink = class
  public
    Lines : TStringList;
    Lock  : TCriticalSection;
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
  end;

constructor TFanOutLineSink.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lock  := TCriticalSection.Create;
end;

destructor TFanOutLineSink.Destroy;
begin
  Lines.Free;
  Lock.Free;
  inherited;
end;

procedure TFanOutLineSink.OnLine(const line: string);
begin
  Lock.Enter;
  try
    Lines.Add(line);
  finally
    Lock.Leave;
  end;
end;

procedure TProcessE2ETests.Pipe_MultiTargetFileAndLineDelegate_BothReceive;
const
  cLineCount = 75;
var
  proc     : IProcess;
  outFile  : string;
  sink     : TFanOutLineSink;
  inner    : TArray<IPipeTarget>;
  multi    : IPipeTarget;
  fs       : TFileStream;
  fileBytes : TBytes;
  fileLines : Integer;
  i : Integer;
begin
  outFile := TTestHelpers.TempFileName('vsoft_e2e_fanout_', '.log');
  sink := TFanOutLineSink.Create;
  try
    SetLength(inner, 2);
    inner[0] := TPipeTarget.ToFile(outFile, False);
    inner[1] := TPipeTarget.ToLineMethod(sink.OnLine, TEncoding.UTF8);
    multi := TPipeTarget.ToAll(inner);

    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
    proc.WithStdOutPipe(multi);
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.IsTrue(FileExists(outFile), 'File target should have created the file');

    // The file target should hold the byte-exact stream.
    fs := TFileStream.Create(outFile, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(fileBytes, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(fileBytes[0], fs.Size);
    finally
      fs.Free;
    end;
    fileLines := 0;
    for i := 0 to High(fileBytes) do
      if fileBytes[i] = 10 then
        Inc(fileLines);
    Assert.AreEqual(cLineCount, fileLines,
                    'File target should have received every line');

    // The line delegate should have seen the same lines.
    Assert.AreEqual(cLineCount, sink.Lines.Count,
                    'Line delegate target should have received every line');
    Assert.IsTrue(Copy(sink.Lines[0], 1, 7) = 'line 1:',
                  'First captured line should be "line 1:..."');
  finally
    sink.Free;
    if FileExists(outFile) then
      DeleteFile(outFile);
  end;
end;

procedure TProcessE2ETests.StartInfo_HideWindowFalse_StillExecutes;
{$IFDEF MSWINDOWS}
var
  proc : IProcess;
{$ENDIF}
begin
  {$IFNDEF MSWINDOWS}
  // POSIX has no console window concept; HideWindow is a no-op there and
  // the regression this test guards against was Windows-specific
  // (SW_HIDE hardcoded into CreateProcess startup info).
  Assert.Pass('HideWindow semantics only apply on Windows');
  Exit;
  {$ELSE}
  // Smoke test only: the previous bug was that HideWindow=False silently
  // collapsed to SW_HIDE (so this assertion was vacuous because the window
  // was always hidden anyway). After the fix, HideWindow=False asks for
  // SW_SHOWNORMAL - we cannot reliably assert visibility from automation,
  // but we can confirm the process still launches and completes.
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ShellExePath;
  proc.StartInfo.HideWindow := False;
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit 0');
  proc.Execute(nil);
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode);
  {$ENDIF}
end;

procedure TProcessE2ETests.Credentials_InvalidConfiguration_ExecuteReturnsFalse;
var
  proc : IProcess;
  started : Boolean;
  joinedErrors : string;
  i : Integer;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := TTestHelpers.ShellExePath;
  proc.StartInfo.HideWindow := True;
  {$IFDEF MSWINDOWS}
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit 0');
  {$ELSE}
  proc.CommandLine.Add('-c');
  proc.CommandLine.Add('exit 0');
  {$ENDIF}
  // Invalid combination: UPN-format user PLUS a non-empty Domain.
  // On Windows the cross-platform validator rejects the UPN+Domain conflict.
  // On POSIX the entire credentials feature is unsupported, so Execute must
  // also refuse to launch - the failure mode is different (the error message
  // is "Credentials are not supported on POSIX platforms") but the contract
  // (Execute returns False, proc.Errors is populated) is the same.
  proc.Credentials.WithUser('alice@example.com')
                  .WithDomain('CORP')
                  .WithPassword('hunter2');

  started := proc.Execute(nil);
  Assert.IsFalse(started,
                 'Execute must return False when credential validation fails');

  joinedErrors := '';
  for i := 0 to proc.Errors.Count - 1 do
    joinedErrors := joinedErrors + proc.Errors[i] + #10;
  {$IFDEF MSWINDOWS}
  Assert.IsTrue(Pos('UPN', joinedErrors) > 0,
                'proc.Errors should mention the UPN/Domain conflict; got: ' + joinedErrors);
  {$ELSE}
  Assert.IsTrue(Pos('POSIX', joinedErrors) > 0,
                'proc.Errors should mention POSIX credentials not supported; got: ' + joinedErrors);
  {$ENDIF}
end;

procedure TProcessE2ETests.StartInfo_OutputEncoding_FlowsToImplicitLineTarget;
var
  proc      : IProcess;
  collector : TLineCollector;
  hadNonAscii : Boolean;
  i : Integer;
  s : string;
  fileName : string;
begin
  fileName := '';
  collector := TLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    // The whole point of this test: set the encoding ON StartInfo and use a
    // line target WITHOUT an explicit encoding. Previously this was a silent
    // no-op (the line target fell back to TEncoding.Default).
    proc.StartInfo.OutputEncoding := TEncoding.UTF8;
    {$IFDEF MSWINDOWS}
    // The child prints the UTF-8 bytes of "caf" + e-acute from a file, so
    // they do not depend on the console code page (chcp 65001 on the same
    // cmd /c line does not change the code page of that line's echo).
    fileName := TTestHelpers.SetupPrintUtf8(proc, 'caf' + #$00E9);
    {$ELSE}
    proc.StartInfo.Executable := TTestHelpers.ShellExePath;
    // POSIX shells default to UTF-8 in modern locales. printf emits the byte
    // sequence verbatim so the UTF-8 encoding of e-acute (#$C3 #$A9) reaches
    // the pipe and the implicit StartInfo.OutputEncoding decodes it back.
    proc.CommandLine.Add('-c');
    proc.CommandLine.Add('printf ''caf' + #$00E9 + '\n''');
    {$ENDIF}
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine)); // no encoding arg
    proc.Execute(nil);

    Assert.AreEqual<Cardinal>(0, proc.ExitCode);
    Assert.IsTrue(collector.Lines.Count >= 1,
                  'Expected at least one captured line');

    // The captured line should contain the UTF-8 decoded char. We just look
    // for ANY captured line that contains the e-acute - decoding with the
    // default ANSI code page would have produced "cafA(c)" or similar.
    hadNonAscii := False;
    for i := 0 to collector.Lines.Count - 1 do
    begin
      s := collector.Lines[i];
      if Pos(#$00E9, s) > 0 then
      begin
        hadNonAscii := True;
        Break;
      end;
    end;
    Assert.IsTrue(hadNonAscii,
                  'Line target should have decoded e-acute via the injected UTF-8 default');
  finally
    collector.Free;
    if fileName <> '' then
      DeleteFile(fileName);
  end;
end;

{$IFDEF MSWINDOWS}
const
  // Defined in Windows.h since Vista but missing from WinAPI.Windows on
  // some Delphi versions. PROCESS_QUERY_INFORMATION is the older,
  // wider-access alternative and works back to XP.
  cPROCESS_QUERY_LIMITED_INFORMATION = $1000;
{$ENDIF}

type
  // Class with a real method so we can hand it to ToLineMethod (a local
  // procedure can't be assigned to a method-of-object procedure variable).
  TPidLineCollector = class
  private
    FLock : TCriticalSection;
    FLines : TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
    function Snapshot : TArray<string>;
  end;

constructor TPidLineCollector.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TPidLineCollector.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited;
end;

procedure TPidLineCollector.OnLine(const line : string);
begin
  FLock.Enter;
  try
    FLines.Add(line);
  finally
    FLock.Leave;
  end;
end;

function TPidLineCollector.Snapshot : TArray<string>;
var
  i : Integer;
begin
  FLock.Enter;
  try
    SetLength(result, FLines.Count);
    for i := 0 to FLines.Count - 1 do
      result[i] := FLines[i];
  finally
    FLock.Leave;
  end;
end;

procedure TProcessE2ETests.Terminate_KillsGrandchildProcessTree;
var
  proc : IProcess;
  collector : TPidLineCollector;
  snapshot : TArray<string>;
  pidLine : string;
  i : Integer;
  grandPid : Cardinal;
  parsed : Int64;
  deadline : Int64;
  alive : Boolean;
  before : string;
  {$IFDEF MSWINDOWS}
  hProc : THandle;
  exitCode : DWORD;
  {$ENDIF}
begin
  collector := TPidLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    // Generous timeout so the script's own sleep dominates; we'll Terminate
    // long before that anyway.
    proc.StartInfo.TimeoutInMSec := 60000;
    TTestHelpers.SetupShellCommand(proc, 'spawn-and-wait', ['60']);
    proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
    // With stdin redirected the POSIX child always gets its own process
    // group, whether or not the runner was started from a terminal.
    proc.WithStdInPipe(TPipeSource.FromString(''));
    Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)),
                  'ExecuteAsync should report success');

    // Poll stdout until the grandchild PID arrives. spawn-and-wait prints
    // "PID=<n>" then sleeps. Give it a few seconds to launch.
    grandPid := 0;
    deadline := TTestHelpers.TickMs + 5000;
    while TTestHelpers.TickMs < deadline do
    begin
      snapshot := collector.Snapshot;
      for i := 0 to High(snapshot) do
      begin
        pidLine := snapshot[i];
        if Pos('PID=', pidLine) = 1 then
        begin
          if TryStrToInt64(Copy(pidLine, 5, MaxInt), parsed) and (parsed > 0) then
            grandPid := Cardinal(parsed);
          Break;
        end;
      end;
      if grandPid <> 0 then
        Break;
      Sleep(50);
    end;

    Assert.IsTrue(grandPid <> 0,
                  'spawn-and-wait should have printed the grandchild PID within 5s');

    before := TTestHelpers.DescribeProcess(proc.ProcessId) + ' / ' + TTestHelpers.DescribeProcess(grandPid);
    // Now kill the parent. The library should reap the entire process tree
    // (Job Object on Windows, kill(-pgid, SIGKILL) on POSIX).
    Assert.IsTrue(proc.Terminate,
                  'Terminate should return True (worker acknowledged within 5s)');

    // Poll for grandchild death. Use a generous deadline: the grandchild can
    // be in a kernel sleep that takes a moment to interrupt.
    alive := True;
    deadline := TTestHelpers.TickMs + 5000;
    while TTestHelpers.TickMs < deadline do
    begin
      {$IFDEF MSWINDOWS}
      hProc := OpenProcess(cPROCESS_QUERY_LIMITED_INFORMATION, False, grandPid);
      if hProc = 0 then
      begin
        alive := False;
        Break;
      end;
      if GetExitCodeProcess(hProc, exitCode) and (exitCode <> STILL_ACTIVE) then
      begin
        CloseHandle(hProc);
        alive := False;
        Break;
      end;
      CloseHandle(hProc);
      {$ELSE}
      // kill(pid, 0) returns 0 if the process exists, -1 with ESRCH if not.
      if kill(pid_t(grandPid), 0) <> 0 then
      begin
        alive := False;
        Break;
      end;
      {$ENDIF}
      Sleep(100);
    end;

    if alive then
      before := before + '; grandchild after: ' + TTestHelpers.DescribeProcess(grandPid);
    Assert.IsFalse(alive,
                   'Grandchild PID ' + IntToStr(grandPid) +
                   ' should be dead after Terminate killed the process tree. Before (child / grandchild): ' + before);
  finally
    collector.Free;
  end;
end;

type
  // Counting IPipeSource for C3. Returns a tiny payload then ends. We
  // bump StartCount / DoneCount so the test can prove the framework
  // calls them exactly once per Execute (TProcessBase.StartPipeTargets
  // owns the lifecycle; the stdin writer thread used to call them too,
  // making it twice).
  TCountingPipeSource = class(TInterfacedObject, IPipeSource)
  private
    FStartCount : Integer;
    FDoneCount  : Integer;
    FPayload    : TBytes;
    FDelivered  : Boolean;
  public
    constructor Create(const payload : TBytes);
    procedure Start;
    function GetData(var data : TBytes; out length : NativeUInt) : Boolean;
    procedure Done;
    property StartCount : Integer read FStartCount;
    property DoneCount  : Integer read FDoneCount;
  end;

constructor TCountingPipeSource.Create(const payload : TBytes);
begin
  inherited Create;
  FPayload := payload;
end;

procedure TCountingPipeSource.Start;
begin
  Inc(FStartCount);
end;

function TCountingPipeSource.GetData(var data : TBytes; out length : NativeUInt) : Boolean;
begin
  if FDelivered then
  begin
    SetLength(data, 0);
    length := 0;
    result := False;
  end
  else
  begin
    data := FPayload;
    length := System.Length(FPayload);
    FDelivered := True;
    // One more GetData expected (will return False, ending the writer loop).
    result := True;
  end;
end;

procedure TCountingPipeSource.Done;
begin
  Inc(FDoneCount);
end;

procedure TProcessE2ETests.StdIn_SourceStartDoneCalledExactlyOnce;
var
  proc    : IProcess;
  source  : TCountingPipeSource;
  srcIntf : IPipeSource;
  payload : TBytes;
begin
  // 'hello' as ASCII bytes - echo-stdin will echo whatever it receives.
  SetLength(payload, 5);
  payload[0] := Ord('h'); payload[1] := Ord('e'); payload[2] := Ord('l');
  payload[3] := Ord('l'); payload[4] := Ord('o');

  source := TCountingPipeSource.Create(payload);
  // The IPipeSource ref keeps the object alive; we still need a typed
  // pointer to read the counts afterwards. Hold both refs explicitly.
  srcIntf := source;

  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 10000;
  TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
  proc.WithStdInPipe(srcIntf);
  proc.Execute(ICancellationToken(nil));

  Assert.AreEqual(1, source.StartCount,
                  'IPipeSource.Start must be invoked exactly once per Execute');
  Assert.AreEqual(1, source.DoneCount,
                  'IPipeSource.Done must be invoked exactly once per Execute');
end;

procedure TProcessE2ETests.Execute_ExecutablePathWithSpacesResolves;
{$IFDEF MSWINDOWS}
var
  proc      : IProcess;
  spaceDir  : string;
  probeExe  : string;
  systemCmd : string;
begin
  // CreateProcess doesn't auto-invoke cmd.exe for .cmd / .bat (that's a
  // ShellExecute behaviour). To prove the lpApplicationName fix copes with
  // spaces in the executable path we need a REAL .exe in a folder with a
  // space; cmd.exe itself is convenient because it's always present and
  // copies cheaply. Pre-C6, lpCommandLine parsing tried "C:\Users\...\
  // vsoft test dir\probe.exe" up to the first space and failed.
  spaceDir := TTestHelpers.TempFileName('vsoft test dir_', '');
  TDirectory.CreateDirectory(spaceDir);
  try
    probeExe := TPath.Combine(spaceDir, 'probe.exe');
    systemCmd := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) +
                 'System32\cmd.exe';
    TFile.Copy(systemCmd, probeExe, False);

    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.Executable := probeExe;
    proc.StartInfo.TimeoutInMSec := 5000;
    proc.CommandLine.Add('/c');
    proc.CommandLine.Add('exit /b 17', TQuoted.qtNone);
    Assert.IsTrue(proc.Execute(ICancellationToken(nil)),
                  'Execute should succeed when the executable path contains spaces');
    Assert.AreEqual<Cardinal>(17, proc.ExitCode,
                              'probe.exe (== cmd.exe) should return 17 if it actually ran');
  finally
    if FileExists(probeExe) then
      DeleteFile(probeExe);
    if DirectoryExists(spaceDir) then
      TDirectory.Delete(spaceDir, True);
  end;
{$ELSE}
begin
  Assert.Pass('Windows-only test (verifies CreateProcess lpApplicationName fix)');
{$ENDIF}
end;

type
  // Holder for the OnExit thread-id capture tests. Bound to an instance so
  // OnExit (which is `of object`) can be assigned to its method.
  TThreadIdCapture = class
  private
    FCapturedThreadId : TThreadID;
    FFired : Boolean;
  public
    procedure OnExit(const process : IProcess; exitCode : Cardinal);
    property CapturedThreadId : TThreadID read FCapturedThreadId;
    property Fired : Boolean read FFired;
  end;

procedure TThreadIdCapture.OnExit(const process : IProcess; exitCode : Cardinal);
begin
  FCapturedThreadId := TThread.CurrentThread.ThreadID;
  FFired := True;
end;

procedure TProcessE2ETests.ExecuteAsync_MarshallEventsToMainThread_OnExitFiresOnMainThread;
var
  proc     : IProcess;
  capture  : TThreadIdCapture;
  deadline : Int64;
begin
  // The flag wraps DoOnExited in TThread.Queue, which needs the main
  // thread to drain via CheckSynchronize. We call it here so the test
  // doesn't depend on a message pump existing in the console runner.
  capture := TThreadIdCapture.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.MarshallEventsToMainThread := True;
    proc.StartInfo.TimeoutInMSec := 10000;
    TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
    proc.OnExit := capture.OnExit;

    Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)),
                  'ExecuteAsync should report success');

    // Wait for the worker to finish AND for CheckSynchronize to drain the
    // queued OnExit. 5s is plenty for the child + queue round-trip.
    deadline := TTestHelpers.TickMs + 5000;
    while (not capture.Fired) and (TTestHelpers.TickMs < deadline) do
    begin
      CheckSynchronize(50);
      Sleep(5);
    end;

    Assert.IsTrue(capture.Fired,
                  'OnExit should have fired within 5 seconds');
    Assert.AreEqual<TThreadID>(MainThreadID, capture.CapturedThreadId,
                              'OnExit must run on the main thread when MarshallEventsToMainThread is set');
  finally
    capture.Free;
  end;
end;

procedure TProcessE2ETests.ExecuteAsync_DefaultThreading_OnExitFiresOnWorkerThread;
var
  proc     : IProcess;
  capture  : TThreadIdCapture;
  deadline : Int64;
begin
  // Default behaviour: OnExit fires directly from the worker thread that
  // owns DoWaitForCompletion. No marshalling, no CheckSynchronize required.
  capture := TThreadIdCapture.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.TimeoutInMSec := 10000;
    TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
    proc.OnExit := capture.OnExit;

    Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)),
                  'ExecuteAsync should report success');

    deadline := TTestHelpers.TickMs + 5000;
    while (not capture.Fired) and (TTestHelpers.TickMs < deadline) do
      Sleep(20);

    Assert.IsTrue(capture.Fired,
                  'OnExit should have fired within 5 seconds');
    Assert.AreNotEqual<TThreadID>(MainThreadID, capture.CapturedThreadId,
                                  'OnExit must run on the worker thread when MarshallEventsToMainThread is False');
  finally
    capture.Free;
  end;
end;

procedure TProcessE2ETests.StartInfo_SmallPipeBufferSize_StillReceivesAllOutput;
const
  cLineCount = 2000;
var
  proc          : IProcess;
  output        : TStringBuilder;
  text          : string;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    // Force a small buffer so the same payload (~144 KB) requires many more
    // reads than the 64 KB default; the threadpool re-queue + accumulator
    // path is what we are exercising.
    proc.StartInfo.PipeBufferSize := 4096;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-large', [IntToStr(cLineCount)]);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.Default));
    proc.Execute(ICancellationToken(nil));

    Assert.AreEqual<Cardinal>(0, proc.ExitCode, 'script should exit 0');
    // Taken once: every ToString call builds a new ~144 KB string.
    text := output.ToString;
    Assert.AreEqual(cLineCount, TTestHelpers.CountChar(text, #10),
                    'Every line must arrive even when PipeBufferSize is 4 KB');
    Assert.AreEqual(ExpectedLargeOutput(cLineCount), text, False,
                    'The captured text differs from what the script printed');
  finally
    output.Free;
  end;
end;

procedure TProcessE2ETests.ExecuteDetached_AppliesPriority;
{$IFDEF MSWINDOWS}
var
  proc      : IProcess;
  childPid  : Cardinal;
  hChild    : THandle;
  cls       : DWORD;
begin
  // We launch detached and immediately read GetPriorityClass off the child
  // before terminating it.
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.Priority := TProcessPriority.BelowNormal;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['30']);
  Assert.IsTrue(proc.ExecuteDetached,
                'ExecuteDetached should succeed for sleep.cmd');
  try
    childPid := proc.ProcessId;
    Assert.IsTrue(childPid <> 0,
                  'Detached child should publish a non-zero ProcessId on Windows');

    hChild := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_TERMINATE,
                          False, childPid);
    Assert.IsTrue(hChild <> 0,
                  'OpenProcess should succeed for the detached child');
    try
      cls := GetPriorityClass(hChild);
      Assert.AreEqual<DWORD>(BELOW_NORMAL_PRIORITY_CLASS, cls,
        'GetPriorityClass should reflect StartInfo.Priority');
    finally
      // Detached, so we are responsible for terminating.
      TerminateProcess(hChild, 0);
      CloseHandle(hChild);
    end;
  except
    // If the assertion phase raised, still try to clean up the child.
    if proc.ProcessId <> 0 then
    begin
      hChild := OpenProcess(PROCESS_TERMINATE, False, proc.ProcessId);
      if hChild <> 0 then
      begin
        TerminateProcess(hChild, 0);
        CloseHandle(hChild);
      end;
    end;
    raise;
  end;
{$ELSE}
begin
  // The test asserts a Windows-specific Win32 priority class value.
  Assert.Pass('Windows-only test - skipped on POSIX');
{$ENDIF}
end;

procedure TProcessE2ETests.Terminate_SetsStatusTerminatedAndConfiguredExitCode;
var
  proc     : IProcess;
  deadline : Int64;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TerminateExitCode := 31415;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['30']);
  Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)),
                'ExecuteAsync should report success');
  // Wait a moment for the child to actually start.
  Sleep(200);
  Assert.AreEqual(TProcessStatus.Running, proc.Status,
                  'Sanity: child should still be running before Terminate');

  Assert.IsTrue(proc.Terminate,
                'Terminate should return True (worker acknowledged)');

  // Status publishes via SetStatusAtomic; FCompletionEvent is signalled
  // before Terminate returns, so the assertion below is a happens-after
  // edge. Belt-and-braces: short poll just in case.
  deadline := TTestHelpers.TickMs + 2000;
  while (proc.Status = TProcessStatus.Running) and
        (TTestHelpers.TickMs < deadline) do
    Sleep(10);

  Assert.AreEqual(TProcessStatus.Terminated, proc.Status,
                  'Status must publish as Terminated after Terminate');
  Assert.AreEqual<Cardinal>(31415, proc.ExitCode,
    'ExitCode must reflect the configured TerminateExitCode (not the SIGKILL / TerminateProcess raw value)');
end;

procedure TProcessE2ETests.Timeout_SetsStatusTimedOutAndConfiguredExitCode;
var
  proc     : IProcess;
  deadline : Int64;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 400;
  proc.StartInfo.TimedOutExitCode := 27182;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  proc.ExecuteAsync;

  // Wait for the timeout to fire and the worker to publish status.
  deadline := TTestHelpers.TickMs + 5000;
  while (proc.Status = TProcessStatus.Running) and
        (TTestHelpers.TickMs < deadline) do
    Sleep(20);

  Assert.IsTrue(proc.TimedOut,
                'TimedOut flag must be set after the timeout fires');
  Assert.AreEqual(TProcessStatus.TimedOut, proc.Status,
                  'Status must be TimedOut (matching Windows + POSIX after the C5 fix)');
  Assert.AreEqual<Cardinal>(27182, proc.ExitCode,
                            'ExitCode must reflect TimedOutExitCode');
end;

procedure TProcessE2ETests.ExecuteAsyncWithEvent_PreSignalledReturnsFalse;
var
  proc    : IProcess;
  evt     : TEvent;
  started : Boolean;
begin
  evt := TEvent.Create(nil, True, True, ''); // manual-reset, initially signalled
  try
    proc := TProcess.Create;
    proc.StartInfo.HideWindow := True;
    proc.StartInfo.TimeoutInMSec := 5000;
    TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);

    started := proc.ExecuteAsync(evt);
    Assert.IsFalse(started,
      'ExecuteAsync(event) must return False when the cancellation event is already signalled');
    Assert.AreEqual(TProcessStatus.Idle, proc.Status,
      'Status must remain Idle when the launch was vetoed');
    Assert.IsTrue(proc.Errors.Count > 0,
      'A reason must be logged so callers can diagnose why launch was skipped');
  finally
    evt.Free;
  end;
end;

procedure TProcessE2ETests.ProcessId_PopulatedAndMatchesLiveChild;
{$IFDEF MSWINDOWS}
var
  proc     : IProcess;
  pid      : Cardinal;
  hChild   : THandle;
  deadline : Int64;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupShellCommand(proc, 'sleep', ['10']);
  Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)),
                'ExecuteAsync should report success');
  try
    // PID is published before ExecuteAsync returns.
    pid := proc.ProcessId;
    Assert.IsTrue(pid <> 0,
                  'IProcess.ProcessId must be populated while child is alive');
    hChild := OpenProcess(cPROCESS_QUERY_LIMITED_INFORMATION, False, pid);
    Assert.IsTrue(hChild <> 0,
                  'OpenProcess by ProcessId must succeed while child is alive');
    CloseHandle(hChild);
  finally
    proc.Terminate;
    deadline := TTestHelpers.TickMs + 2000;
    while (proc.Status = TProcessStatus.Running) and
          (TTestHelpers.TickMs < deadline) do
      Sleep(10);
  end;
{$ELSE}
begin
  Assert.Pass('Windows-only test (uses OpenProcess) - skipped on POSIX');
{$ENDIF}
end;

procedure TProcessE2ETests.Execute_RunTwice_StateResetBetweenRuns;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 10000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['5']);
  Assert.IsTrue(proc.Execute(ICancellationToken(nil)),
                'First Execute should succeed');
  Assert.AreEqual<Cardinal>(5, proc.ExitCode, 'First run exit code');
  Assert.AreEqual(TProcessStatus.Exited, proc.Status);
  Assert.IsFalse(proc.TimedOut, 'First run did not time out');

  // Reconfigure the same IProcess and re-run. The CommandLineBuilder still
  // holds the previous '5' argument; replace just that one.
  proc.CommandLine.Clear;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['7']);
  Assert.IsTrue(proc.Execute(ICancellationToken(nil)),
                'Second Execute on the same IProcess should succeed');
  Assert.AreEqual<Cardinal>(7, proc.ExitCode,
                            'Second run exit code must come from THIS run, not the previous one');
  Assert.AreEqual(TProcessStatus.Exited, proc.Status,
                  'Status must reset to Exited on the second run, not stay Exited from the first run with stale value');
  Assert.IsFalse(proc.TimedOut, 'Second run did not time out');
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessE2ETests);

end.
