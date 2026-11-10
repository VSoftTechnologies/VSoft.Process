unit VSoft.Process.Tests.Review.Posix;

// Tests written to prove or disprove the POSIX findings of
// docs\CODE_REVIEW_2026-11-10.md (POSIX-1 to POSIX-4 and SUP-2). Every test
// asserts the documented / expected behaviour, so a test that fails confirms
// its finding and passes once the library is fixed.
//
// POSIX-5 (redundant spawn lock) and POSIX-6 (compile-time guards) have no
// runtime test: neither describes behaviour a test could observe.

interface

{$IFDEF POSIX}
uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TReviewPosixTests = class
  public
    // POSIX-1: Terminate must end every member of the child's process group,
    // including one that ignores SIGTERM (README: "SIGTERM to the child's
    // process group, SIGKILL 500 ms later"). Fails when the group SIGKILL is
    // never sent because the direct child was already reaped.
    [Test]
    procedure POSIX1_Terminate_DescendantIgnoringSigTerm_IsKilled;

    // POSIX-1, timeout path: the same escalation when TimeoutInMSec elapses.
    // Fails for the same reason as the Terminate test.
    [Test]
    procedure POSIX1_Timeout_DescendantIgnoringSigTerm_IsKilled;

    {$IFDEF LINUX}
    // POSIX-2 (consequence 1): with the host in the foreground of a terminal
    // and the child's stdin redirected, a child that reads /dev/tty must not
    // be left stopped (SIGTTIN) while the run silently stays Running. Fails
    // when the child sits in state T and the library neither ends the run
    // nor reports anything. The test re-runs itself under script(1) to get a
    // controlling terminal.
    [Test]
    procedure POSIX2_RedirectedStdIn_ChildReadingTerminal_IsNotLeftStoppedSilently;
    {$ENDIF}

    // POSIX-3: a host descriptor numbered 65536 or above must not be open in
    // the child (README: every descriptor other than stdio is closed). Fails
    // where close_range is not available (macOS, Linux before 5.11, seccomp
    // profiles that reject it) because the fallback loop stops at 65535.
    [Test]
    procedure POSIX3_HostFdAbove65535_IsNotInheritedByChild;

    // POSIX-3: a host descriptor above the current soft RLIMIT_NOFILE (opened
    // before the limit was lowered) must not be open in the child. Fails
    // where close_range is not available: the fallback loop is bounded by
    // the current soft limit.
    [Test]
    procedure POSIX3_HostFdAboveLoweredSoftLimit_IsNotInheritedByChild;

    // POSIX-3: the cost of a spawn must not grow with RLIMIT_NOFILE. Fails
    // where close_range is not available: the child then makes one close()
    // call per possible descriptor (up to 65,533) before exec.
    [Test]
    procedure POSIX3_HighFdLimit_DoesNotSlowSpawn;

    // POSIX-4: a run of a short-lived child must not take a wait slice
    // (100 ms) longer than the child did. Fails where the exit wake-up is
    // missing (no pidfd_open: Linux before 5.3 or a seccomp profile) or is
    // consumed early (macOS, if NOTE_EXIT arrives before the child can be
    // reaped).
    [Test]
    procedure POSIX4_ShortLivedChild_WithStdOutPipe_CompletesPromptly;

    // POSIX-4, nothing redirected: there is no pipe EOF to wake the loop, so
    // only the exit wake-up can end the wait early.
    [Test]
    procedure POSIX4_ShortLivedChild_NoRedirection_CompletesPromptly;

    // SUP-2: a host environment entry that is not valid UTF-8 must not make
    // the environment builder raise. Fails when the strict UTF-8 decode of
    // environ raises EEncodingError.
    [Test]
    procedure SUP2_InvalidUtf8HostEnvironment_EnvironmentBuilderCreate_DoesNotRaise;

    // SUP-2: with such an entry in the host environment a process can still
    // be created and run, and (no overrides, so environ is inherited as is)
    // the child sees the entry byte for byte. Fails when TProcess.Create
    // raises.
    [Test]
    procedure SUP2_InvalidUtf8HostEnvironment_ProcessRuns_ChildInheritsEntry;

    // SUP-2, related case: once the caller overrides another variable the
    // environment is rebuilt from the snapshot; the invalid entry must still
    // reach the child (at least lossily). Fails when TProcess.Create raises
    // or the entry is dropped.
    [Test]
    procedure SUP2_InvalidUtf8HostEnvironment_WithOverride_ChildStillGetsEntry;
  end;
{$ENDIF}

implementation

{$IFDEF POSIX}
uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Generics.Collections,
  Posix.Base,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Signal,
  Posix.Fcntl,
  Posix.Stdlib,
  VSoft.CancellationToken,
  VSoft.Process,
  VSoft.Process.Environment,
  VSoft.Process.Tests.Common;

const
  cTestPrefix = 'VSoft.Process.Tests.Review.Posix.TReviewPosixTests.';
  cPtyMarkerVar = 'VSP_REVIEW_POSIX_PTY';
  cBadEnvName = 'VSP_REVIEW_BAD_UTF8';
  cBadEnvHex = '63 61 66 e9';
  {$IFDEF LINUX}
  cRlimitNoFile = 7;
  {$ELSE}
  cRlimitNoFile = 8;
  {$ENDIF}

type
  TRLimit = record
    Current : UInt64;
    Maximum : UInt64;
  end;

  TReviewLineCollector = class
  private
    FLock : TCriticalSection;
    FLines : TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
    // The number after "PID=" on the first such line, 0 when there is none.
    function FindPid : Cardinal;
  end;

function getrlimit(resource : Integer; var limit : TRLimit) : Integer; cdecl; external libc name _PU + 'getrlimit';
function setrlimit(resource : Integer; var limit : TRLimit) : Integer; cdecl; external libc name _PU + 'setrlimit';

constructor TReviewLineCollector.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TReviewLineCollector.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited;
end;

procedure TReviewLineCollector.OnLine(const line : string);
begin
  FLock.Enter;
  try
    FLines.Add(line);
  finally
    FLock.Leave;
  end;
end;

function TReviewLineCollector.FindPid : Cardinal;
var
  i : integer;
  parsed : Int64;
begin
  result := 0;
  FLock.Enter;
  try
    for i := 0 to FLines.Count - 1 do
      if Pos('PID=', FLines[i]) = 1 then
      begin
        if TryStrToInt64(Trim(Copy(FLines[i], 5, MaxInt)), parsed) and (parsed > 1) then
          result := Cardinal(parsed);
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

function WaitForPid(collector : TReviewLineCollector; timeoutMs : Cardinal) : Cardinal;
var
  deadline : Int64;
begin
  deadline := TTestHelpers.TickMs + timeoutMs;
  repeat
    result := collector.FindPid;
    if result <> 0 then
      Exit;
    Sleep(20);
  until TTestHelpers.TickMs >= deadline;
end;

// The process state letter (R, S, T, Z, ...), #0 when there is no such
// process. Without /proc (macOS) a process that exists is reported as 'R'.
function ProcessState(processId : Cardinal) : Char;
{$IFDEF LINUX}
var
  stream : TFileStream;
  buffer : array[0..1023] of Byte;
  count : integer;
  i : integer;
{$ENDIF}
begin
  result := #0;
  if processId = 0 then
    Exit;
  {$IFDEF LINUX}
  try
    stream := TFileStream.Create('/proc/' + IntToStr(processId) + '/stat', fmOpenRead or fmShareDenyNone);
    try
      count := stream.Read(buffer[0], SizeOf(buffer));
    finally
      stream.Free;
    end;
  except
    Exit;
  end;
  // "pid (comm) S ...": comm may contain spaces and brackets, so search for
  // the last ')'.
  for i := count - 3 downto 0 do
    if buffer[i] = Ord(')') then
    begin
      result := Char(buffer[i + 2]);
      Exit;
    end;
  {$ELSE}
  if kill(pid_t(processId), 0) = 0 then
    result := 'R';
  {$ENDIF}
end;

function IsProcessAlive(processId : Cardinal) : boolean;
var
  state : Char;
begin
  state := ProcessState(processId);
  result := (state <> #0) and (state <> 'Z') and (state <> 'X');
end;

function WaitForDeath(processId : Cardinal; timeoutMs : Cardinal) : boolean;
var
  deadline : Int64;
begin
  deadline := TTestHelpers.TickMs + timeoutMs;
  repeat
    if not IsProcessAlive(processId) then
      Exit(true);
    Sleep(25);
  until TTestHelpers.TickMs >= deadline;
  result := false;
end;

procedure KillByPid(processId : Cardinal);
begin
  if processId > 1 then
    kill(pid_t(processId), SIGKILL);
end;

procedure DeleteIfExists(const fileName : string);
begin
  if (fileName <> '') and FileExists(fileName) then
    System.SysUtils.DeleteFile(fileName);
end;

function ReadTextFile(const fileName : string) : string;
var
  lines : TStringList;
begin
  result := '';
  if not FileExists(fileName) then
    Exit;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fileName);
    result := Trim(lines.Text);
  finally
    lines.Free;
  end;
end;

procedure WriteTextFile(const fileName : string; const text : string);
var
  lines : TStringList;
begin
  lines := TStringList.Create;
  try
    lines.Text := text;
    lines.SaveToFile(fileName);
  finally
    lines.Free;
  end;
end;

function Utf8ZBytes(const value : string) : TBytes;
var
  raw : TBytes;
begin
  raw := TEncoding.UTF8.GetBytes(value);
  SetLength(result, Length(raw) + 1);
  if Length(raw) > 0 then
    Move(raw[0], result[0], Length(raw));
  result[High(result)] := 0;
end;

function SetSoftFdLimit(value : UInt64) : boolean;
var
  limit : TRLimit;
begin
  result := false;
  if getrlimit(cRlimitNoFile, limit) <> 0 then
    Exit;
  if value > limit.Maximum then
    Exit;
  limit.Current := value;
  result := setrlimit(cRlimitNoFile, limit) = 0;
end;

function GetSoftFdLimit : UInt64;
var
  limit : TRLimit;
begin
  result := 0;
  if getrlimit(cRlimitNoFile, limit) = 0 then
    result := limit.Current;
end;

// Runs /bin/sh -c command with stdout captured. False (with the reason in
// output) when the run failed.
function RunShell(const command : string; out output : string) : boolean;
var
  proc : IProcess;
  builder : TStringBuilder;
begin
  builder := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 20000;
    TTestHelpers.SetupInlineCommand(proc, '', command);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(builder, TEncoding.UTF8));
    result := proc.Execute and (proc.Status = TProcessStatus.Exited);
    if result then
      output := builder.ToString
    else
      output := 'run failed: ' + proc.Errors.Text;
  finally
    builder.Free;
  end;
end;

// Elapsed milliseconds of each of count synchronous runs of
// /bin/sh -c "exit 0", sorted ascending. Empty (with the reason in error)
// when a run fails.
function TimeShortRuns(count : integer; withStdOutPipe : boolean; out error : string) : TArray<Double>;
var
  i : integer;
  proc : IProcess;
  builder : TStringBuilder;
  clock : TStopwatch;
  ok : boolean;
begin
  error := '';
  SetLength(result, count);
  builder := TStringBuilder.Create;
  try
    for i := 0 to count - 1 do
    begin
      proc := TProcess.Create;
      proc.StartInfo.TimeoutInMSec := 10000;
      TTestHelpers.SetupInlineCommand(proc, '', 'exit 0');
      if withStdOutPipe then
        proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(builder, TEncoding.UTF8));
      clock := TStopwatch.StartNew;
      ok := proc.Execute;
      clock.Stop;
      if (not ok) or (proc.Status <> TProcessStatus.Exited) or (proc.ExitCode <> 0) then
      begin
        error := 'run ' + IntToStr(i) + ' failed: ' + proc.Errors.Text;
        SetLength(result, 0);
        Exit;
      end;
      result[i] := clock.Elapsed.TotalMilliseconds;
      proc := nil;
    end;
  finally
    builder.Free;
  end;
  TArray.Sort<Double>(result);
end;

function FormatMs(value : Double) : string;
begin
  result := FormatFloat('0.0', value) + 'ms';
end;

// Starts review-posix-term-ignoring (stdin redirected, so the child leads
// its own process group) and returns the pid of the grandchild that ignores
// SIGTERM once it is known to be in the child's group.
function StartTermIgnoringTree(const proc : IProcess; collector : TReviewLineCollector) : Cardinal;
var
  groupId : pid_t;
begin
  TTestHelpers.SetupShellCommand(proc, 'review-posix-term-ignoring', ['30', '60']);
  proc.WithStdOutPipe(TPipeTarget.ToLineMethod(collector.OnLine, TEncoding.UTF8));
  proc.WithStdInPipe(TPipeSource.FromString(''));
  Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)), 'ExecuteAsync: ' + proc.Errors.Text);
  result := WaitForPid(collector, 5000);
  if result = 0 then
    Exit;
  groupId := getpgid(pid_t(result));
  if Cardinal(groupId) <> proc.ProcessId then
  begin
    KillByPid(result);
    Assert.Fail('Test setup: the grandchild is in process group ' + IntToStr(groupId) +
                ', expected the child''s group ' + IntToStr(proc.ProcessId));
  end;
end;

procedure TReviewPosixTests.POSIX1_Terminate_DescendantIgnoringSigTerm_IsKilled;
var
  proc : IProcess;
  collector : TReviewLineCollector;
  grandPid : Cardinal;
  terminated : boolean;
  dead : boolean;
  description : string;
begin
  grandPid := 0;
  collector := TReviewLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 20000;
    try
      grandPid := StartTermIgnoringTree(proc, collector);
      Assert.IsTrue(grandPid <> 0, 'Test setup: no PID= line within 5s');
      Assert.IsTrue(IsProcessAlive(grandPid), 'Test setup: the grandchild is not running before Terminate');

      terminated := proc.Terminate;
      // SIGTERM, 500 ms grace, SIGKILL: well inside 3 s.
      dead := WaitForDeath(grandPid, 3000);
      description := '';
      if not dead then
        description := TTestHelpers.DescribeProcess(grandPid);
      Assert.IsTrue(terminated, 'Terminate returned False');
      Assert.AreEqual(Ord(TProcessStatus.Terminated), Ord(proc.Status), 'Status after Terminate');
      Assert.IsTrue(dead, 'A member of the child''s process group that ignores SIGTERM is still running 3s after Terminate (pid ppid pgid stat comm: ' +
                          description + ')');
    finally
      if proc.Status = TProcessStatus.Running then
        proc.Terminate;
      proc := nil;
    end;
  finally
    KillByPid(grandPid);
    collector.Free;
  end;
end;

procedure TReviewPosixTests.POSIX1_Timeout_DescendantIgnoringSigTerm_IsKilled;
var
  proc : IProcess;
  collector : TReviewLineCollector;
  grandPid : Cardinal;
  finished : boolean;
  dead : boolean;
  description : string;
begin
  grandPid := 0;
  collector := TReviewLineCollector.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 2500;
    try
      grandPid := StartTermIgnoringTree(proc, collector);
      Assert.IsTrue(grandPid <> 0, 'Test setup: no PID= line within 5s');
      Assert.IsTrue(IsProcessAlive(grandPid), 'Test setup: the grandchild is not running before the timeout');

      finished := TTestHelpers.WaitWhileRunning(proc, 15000);
      Assert.IsTrue(finished, 'The run did not end after its timeout');
      Assert.AreEqual(Ord(TProcessStatus.TimedOut), Ord(proc.Status), 'Status after the timeout');
      dead := WaitForDeath(grandPid, 3000);
      description := '';
      if not dead then
        description := TTestHelpers.DescribeProcess(grandPid);
      Assert.IsTrue(dead, 'A member of the child''s process group that ignores SIGTERM is still running 3s after the run timed out (pid ppid pgid stat comm: ' +
                          description + ')');
    finally
      if proc.Status = TProcessStatus.Running then
        proc.Terminate;
      proc := nil;
    end;
  finally
    KillByPid(grandPid);
    collector.Free;
  end;
end;

{$IFDEF LINUX}
function ShellQuote(const value : string) : string;
begin
  result := '''' + StringReplace(value, '''', '''\''''', [rfReplaceAll]) + '''';
end;

// Runs this test again in a second instance of the test program that
// script(1) gives a controlling terminal, and takes over its verdict.
procedure RunTestUnderPty(const testName : string);
var
  proc : IProcess;
  output : TStringBuilder;
  stdIn : IInteractivePipeSource;
  markerFile : string;
  xmlFile : string;
  command : string;
  ok : boolean;
  verdict : string;
begin
  markerFile := TTestHelpers.TempFileName('vsp_review_pty_', '.txt');
  xmlFile := TTestHelpers.TempFileName('vsp_review_pty_', '.xml');
  output := TStringBuilder.Create;
  try
    command := ShellQuote(ExpandFileName(ParamStr(0))) + ' --run:' + cTestPrefix + testName +
               ' --xmlfile:' + ShellQuote(xmlFile);
    proc := TProcess.Create;
    proc.StartInfo.Executable := 'script';
    proc.StartInfo.TimeoutInMSec := 60000;
    proc.CommandLine.Add('-q');
    proc.CommandLine.Add('-e');
    proc.CommandLine.Add('-c');
    proc.CommandLine.Add(command);
    proc.CommandLine.Add('/dev/null');
    proc.Environment.AddOrSet(cPtyMarkerVar, markerFile);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    // Held open for the whole run: at end of input script would type an EOF
    // character into the terminal.
    stdIn := TPipeSource.Interactive;
    proc.WithStdInPipe(stdIn);
    ok := proc.Execute;
    stdIn.Close;
    Assert.IsTrue(ok, 'Could not run script(1) to get a controlling terminal: ' + proc.Errors.Text);
    verdict := ReadTextFile(markerFile);
    Assert.AreEqual(Ord(TProcessStatus.Exited), Ord(proc.Status), 'The run under script(1) did not exit by itself. ' + verdict + sLineBreak + output.ToString);
    Assert.IsTrue(verdict <> '', 'The test did not run under script(1):' + sLineBreak + output.ToString);
    Assert.IsTrue(Pos('PASS', verdict) = 1, verdict);
    Assert.AreEqual(0, Integer(proc.ExitCode), 'Exit code of the test program under script(1). ' + verdict + sLineBreak + output.ToString);
  finally
    output.Free;
    DeleteIfExists(markerFile);
    DeleteIfExists(xmlFile);
  end;
end;

procedure TReviewPosixTests.POSIX2_RedirectedStdIn_ChildReadingTerminal_IsNotLeftStoppedSilently;
var
  markerFile : string;
  proc : IProcess;
  ttyFd : Integer;
  foreground : boolean;
  childPid : Cardinal;
  deadline : Int64;
  state : Char;
  sawStopped : boolean;
  stillRunning : boolean;
  errorCount : integer;
  verdict : string;
begin
  markerFile := GetEnvironmentVariable(cPtyMarkerVar);
  if markerFile = '' then
  begin
    RunTestUnderPty('POSIX2_RedirectedStdIn_ChildReadingTerminal_IsNotLeftStoppedSilently');
    Exit;
  end;

  // From here on: second instance, started by script(1).
  ttyFd := open('/dev/tty', O_RDWR);
  foreground := (ttyFd >= 0) and (tcgetpgrp(ttyFd) = getpgrp);
  if ttyFd >= 0 then
    __close(ttyFd);
  if not foreground then
  begin
    verdict := 'SETUP: the test program is not in the foreground process group of a controlling terminal';
    WriteTextFile(markerFile, verdict);
    Assert.Fail(verdict);
  end;

  childPid := 0;
  stillRunning := false;
  errorCount := 0;
  proc := TProcess.Create;
  try
    // No timeout: the caller relies on the child ending by itself.
    proc.StartInfo.TimeoutInMSec := 0;
    TTestHelpers.SetupInlineCommand(proc, '', 'read answer < /dev/tty; exit 0');
    proc.WithStdInPipe(TPipeSource.FromString(''));
    Assert.IsTrue(proc.ExecuteAsync(ICancellationToken(nil)), 'ExecuteAsync: ' + proc.Errors.Text);
    childPid := proc.ProcessId;

    // A child in the foreground group just waits for input (state S); one in
    // a background group is stopped by SIGTTIN (state T).
    deadline := TTestHelpers.TickMs + 3000;
    repeat
      state := ProcessState(childPid);
      sawStopped := (state = 'T') and (proc.Status = TProcessStatus.Running);
      if sawStopped or (proc.Status <> TProcessStatus.Running) then
        Break;
      Sleep(25);
    until TTestHelpers.TickMs >= deadline;

    if sawStopped then
    begin
      // Give the library time to notice the stop and end or report it.
      deadline := TTestHelpers.TickMs + 2000;
      repeat
        Sleep(50);
        stillRunning := proc.Status = TProcessStatus.Running;
      until (not stillRunning) or (TTestHelpers.TickMs >= deadline);
      if stillRunning then
        errorCount := proc.Errors.Count;
    end;
  finally
    if proc.Status = TProcessStatus.Running then
      proc.Terminate;
    KillByPid(childPid);
    proc := nil;
  end;

  if sawStopped and stillRunning and (errorCount = 0) then
    verdict := 'FAIL: the child (stdin redirected, so in a background process group) was stopped by reading /dev/tty; ' +
               '2s later the run was still Running with nothing in Errors, and with no timeout it would never end'
  else if sawStopped then
    verdict := 'PASS: the child was stopped and the library ended or reported the run'
  else
    verdict := 'PASS: the child was not stopped by reading the terminal';
  WriteTextFile(markerFile, verdict);
  Assert.IsTrue(Pos('PASS', verdict) = 1, verdict);
end;
{$ENDIF}

// Lists the descriptors open in a child (one per line) while the host holds
// a copy of a temp file's descriptor at hostFdNumber, with the soft
// RLIMIT_NOFILE at limitDuringRun for the spawn. skipReason is set when the
// descriptor could not be created (the test cannot run here).
procedure ListChildFdsWithHostFdAt(hostFdNumber : Integer; limitToOpen : UInt64; limitDuringRun : UInt64;
                                   listing : TStrings; out skipReason : string);
var
  fileName : string;
  nameBytes : TBytes;
  lowFd : Integer;
  highFd : Integer;
  originalLimit : UInt64;
  output : string;
  ok : boolean;
begin
  skipReason := '';
  listing.Clear;
  originalLimit := GetSoftFdLimit;
  fileName := TTestHelpers.TempFileName('vsp_review_fd_', '.txt');
  nameBytes := Utf8ZBytes(fileName);
  lowFd := -1;
  highFd := -1;
  try
    if (originalLimit < limitToOpen) and (not SetSoftFdLimit(limitToOpen)) then
    begin
      skipReason := 'RLIMIT_NOFILE cannot be raised to ' + UIntToStr(limitToOpen);
      Exit;
    end;
    lowFd := open(MarshaledAString(@nameBytes[0]), O_RDWR or O_CREAT, $1B6);
    if lowFd < 0 then
    begin
      skipReason := 'cannot create ' + fileName;
      Exit;
    end;
    // F_DUPFD: the copy does not have FD_CLOEXEC, like a TFileStream handle.
    highFd := fcntl(lowFd, F_DUPFD, hostFdNumber);
    if highFd < 0 then
    begin
      skipReason := 'cannot open a descriptor numbered ' + IntToStr(hostFdNumber) + ' or above';
      Exit;
    end;
    if not SetSoftFdLimit(limitDuringRun) then
    begin
      skipReason := 'RLIMIT_NOFILE cannot be set to ' + UIntToStr(limitDuringRun);
      Exit;
    end;
    ok := RunShell('ls /dev/fd', output);
    Assert.IsTrue(ok, output);
    listing.Text := output;
    listing.Insert(0, 'HOSTFD=' + IntToStr(highFd));
  finally
    if highFd >= 0 then
      __close(highFd);
    if lowFd >= 0 then
      __close(lowFd);
    if originalLimit <> 0 then
      SetSoftFdLimit(originalLimit);
    DeleteIfExists(fileName);
  end;
end;

procedure TReviewPosixTests.POSIX3_HostFdAbove65535_IsNotInheritedByChild;
var
  listing : TStringList;
  skipReason : string;
  hostFd : string;
begin
  listing := TStringList.Create;
  try
    ListChildFdsWithHostFdAt(70000, 70016, 70016, listing, skipReason);
    if skipReason <> '' then
    begin
      Assert.Pass('Not run: ' + skipReason);
      Exit;
    end;
    hostFd := listing.Values['HOSTFD'];
    listing.Delete(0);
    Assert.IsTrue(listing.Count >= 3, 'Unexpected listing: ' + listing.CommaText);
    Assert.IsTrue(listing.IndexOf(hostFd) < 0, 'Host fd ' + hostFd + ' is open in the child (child fds: ' + listing.CommaText + ')');
  finally
    listing.Free;
  end;
end;

procedure TReviewPosixTests.POSIX3_HostFdAboveLoweredSoftLimit_IsNotInheritedByChild;
var
  listing : TStringList;
  skipReason : string;
  hostFd : string;
begin
  listing := TStringList.Create;
  try
    ListChildFdsWithHostFdAt(3000, 3016, 256, listing, skipReason);
    if skipReason <> '' then
    begin
      Assert.Pass('Not run: ' + skipReason);
      Exit;
    end;
    hostFd := listing.Values['HOSTFD'];
    listing.Delete(0);
    Assert.IsTrue(listing.Count >= 3, 'Unexpected listing: ' + listing.CommaText);
    Assert.IsTrue(listing.IndexOf(hostFd) < 0, 'Host fd ' + hostFd + ' (above the soft limit of 256) is open in the child (child fds: ' +
                                               listing.CommaText + ')');
  finally
    listing.Free;
  end;
end;

procedure TReviewPosixTests.POSIX3_HighFdLimit_DoesNotSlowSpawn;
const
  cRuns = 40;
  cHighLimit = 65536;
  cLowLimit = 256;
  cAllowedExtraMs = 2.0;
var
  originalLimit : UInt64;
  lowTimes : TArray<Double>;
  highTimes : TArray<Double>;
  error : string;
  summary : string;
begin
  originalLimit := GetSoftFdLimit;
  if originalLimit = 0 then
  begin
    Assert.Pass('Not run: RLIMIT_NOFILE cannot be read');
    Exit;
  end;
  try
    if not SetSoftFdLimit(cHighLimit) then
    begin
      Assert.Pass('Not run: RLIMIT_NOFILE cannot be raised to ' + IntToStr(cHighLimit));
      Exit;
    end;
    highTimes := TimeShortRuns(cRuns, true, error);
    Assert.IsTrue(Length(highTimes) = cRuns, error);
    Assert.IsTrue(SetSoftFdLimit(cLowLimit), 'RLIMIT_NOFILE cannot be lowered to ' + IntToStr(cLowLimit));
    lowTimes := TimeShortRuns(cRuns, true, error);
    Assert.IsTrue(Length(lowTimes) = cRuns, error);
  finally
    SetSoftFdLimit(originalLimit);
  end;
  // The fastest run of each series: the least disturbed by other load.
  summary := 'fastest / median run of /bin/sh -c "exit 0": ' +
             FormatMs(lowTimes[0]) + ' / ' + FormatMs(lowTimes[cRuns div 2]) + ' with RLIMIT_NOFILE ' + IntToStr(cLowLimit) + ', ' +
             FormatMs(highTimes[0]) + ' / ' + FormatMs(highTimes[cRuns div 2]) + ' with RLIMIT_NOFILE ' + IntToStr(cHighLimit);
  Assert.IsTrue(highTimes[0] <= lowTimes[0] + cAllowedExtraMs, 'A spawn costs more with a high descriptor limit: ' + summary);
end;

procedure CheckShortRunsArePrompt(withStdOutPipe : boolean);
const
  cRuns = 50;
  cMaxMedianMs = 30.0;
var
  times : TArray<Double>;
  error : string;
begin
  times := TimeShortRuns(cRuns, withStdOutPipe, error);
  Assert.IsTrue(Length(times) = cRuns, error);
  Assert.IsTrue(times[cRuns div 2] < cMaxMedianMs,
                'Median run time of /bin/sh -c "exit 0" over ' + IntToStr(cRuns) + ' runs is ' + FormatMs(times[cRuns div 2]) +
                ' (fastest ' + FormatMs(times[0]) + ', slowest ' + FormatMs(times[cRuns - 1]) + '); expected less than ' +
                FormatMs(cMaxMedianMs));
end;

procedure TReviewPosixTests.POSIX4_ShortLivedChild_WithStdOutPipe_CompletesPromptly;
begin
  CheckShortRunsArePrompt(true);
end;

procedure TReviewPosixTests.POSIX4_ShortLivedChild_NoRedirection_CompletesPromptly;
begin
  CheckShortRunsArePrompt(false);
end;

// Adds VSP_REVIEW_BAD_UTF8=caf<E9> (Latin-1 e-acute, not valid UTF-8) to the
// host environment.
procedure SetBadEnvironmentEntry;
var
  name : TBytes;
  value : TBytes;
begin
  name := Utf8ZBytes(cBadEnvName);
  SetLength(value, 5);
  value[0] := Ord('c');
  value[1] := Ord('a');
  value[2] := Ord('f');
  value[3] := $E9;
  value[4] := 0;
  if setenv(MarshaledAString(@name[0]), MarshaledAString(@value[0]), 1) <> 0 then
    raise Exception.Create('setenv failed');
end;

procedure ClearBadEnvironmentEntry;
var
  name : TBytes;
begin
  name := Utf8ZBytes(cBadEnvName);
  unsetenv(MarshaledAString(@name[0]));
end;

// The bytes of the entry as the child sees them, in hex ("63 61 66 e9").
function RunChildDumpingBadEntry(const proc : IProcess) : string;
var
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc.StartInfo.TimeoutInMSec := 20000;
    TTestHelpers.SetupInlineCommand(proc, '', 'printf %s "$' + cBadEnvName + '" | od -An -tx1');
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    Assert.IsTrue(proc.Execute, 'Execute: ' + proc.Errors.Text);
    Assert.AreEqual(Ord(TProcessStatus.Exited), Ord(proc.Status), 'Status');
    result := Trim(output.ToString);
  finally
    output.Free;
  end;
end;

procedure TReviewPosixTests.SUP2_InvalidUtf8HostEnvironment_EnvironmentBuilderCreate_DoesNotRaise;
var
  env : IEnvironmentBuilder;
  raised : string;
begin
  raised := '';
  SetBadEnvironmentEntry;
  try
    try
      env := TEnvironmentBuilder.Create;
    except
      on e : Exception do
        raised := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raised, 'TEnvironmentBuilder.Create raised with a non-UTF-8 entry in the host environment');
    Assert.IsTrue(env.Exists(cBadEnvName), 'The non-UTF-8 entry is missing from the builder');
  finally
    ClearBadEnvironmentEntry;
  end;
end;

procedure TReviewPosixTests.SUP2_InvalidUtf8HostEnvironment_ProcessRuns_ChildInheritsEntry;
var
  proc : IProcess;
  raised : string;
  hex : string;
begin
  raised := '';
  SetBadEnvironmentEntry;
  try
    try
      proc := TProcess.Create;
    except
      on e : Exception do
        raised := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raised, 'TProcess.Create raised with a non-UTF-8 entry in the host environment');
    hex := RunChildDumpingBadEntry(proc);
    Assert.AreEqual(cBadEnvHex, hex, 'Bytes of the entry in a child that inherits the environment unchanged');
  finally
    proc := nil;
    ClearBadEnvironmentEntry;
  end;
end;

procedure TReviewPosixTests.SUP2_InvalidUtf8HostEnvironment_WithOverride_ChildStillGetsEntry;
var
  proc : IProcess;
  raised : string;
  hex : string;
begin
  raised := '';
  SetBadEnvironmentEntry;
  try
    try
      proc := TProcess.Create;
    except
      on e : Exception do
        raised := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raised, 'TProcess.Create raised with a non-UTF-8 entry in the host environment');
    proc.Environment.AddOrSet('VSP_REVIEW_OTHER', 'x');
    hex := RunChildDumpingBadEntry(proc);
    // "caf" then whatever the invalid byte became.
    Assert.IsTrue(Pos('63 61 66', hex) = 1, 'The entry did not reach a child whose environment was rebuilt: "' + hex + '"');
  finally
    proc := nil;
    ClearBadEnvironmentEntry;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TReviewPosixTests);
{$ENDIF}

end.
