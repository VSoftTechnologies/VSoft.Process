unit VSoft.Process.Tests.Logon;

interface

// Launches with credentials (CreateProcessWithLogonW, Windows only). No test
// logs on to a real account: the launcher is stubbed, or the logon is
// LOGON_NETCREDENTIALS_ONLY with a made-up user, which Windows does not check
// locally (the child runs with our own token; the credentials would only be
// used for network access).

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VSoft.Process;

type
  [TestFixture]
  TProcessLogonTests = class
  public
    [Setup]
    procedure SetUp;

    // A launch with credentials can take seconds (a user profile to load).
    // Other launches in the process must not wait for it.
    [Test]
    procedure LogonLaunch_DoesNotBlockOtherLaunches;

    // Through the Secondary Logon service, the child still gets the
    // redirected stdout / stderr pipe ends.
    [Test]
    procedure NetOnlyLogon_RedirectsStdOutAndStdErr;

    // The logon child inherits no handle of ours other than its std handles,
    // so it is safe to launch without the spawn lock: an inheritable handle
    // of another launch at that moment does not leak into it.
    [Test]
    procedure NetOnlyLogon_ChildInheritsNoOtherHandle;

    // A launch the Secondary Logon service refuses reports the Windows error
    // in LastError and Errors (with no %1 left in the message).
    [Test]
    procedure NetOnlyLogon_LaunchFails_ReportsTheOsError;

    // StartInfo.InheritHostStdHandles with credentials: the copy of our
    // stderr reaches the logon child (the service duplicates it in).
    [Test]
    procedure NetOnlyLogon_InheritHostStdHandles_StdErrGoesToHostStdErr;

    // TPipeSource.FileAsStdIn with credentials: the logon child reads the file.
    [Test]
    procedure NetOnlyLogon_FileAsStdIn_ChildReadsTheFile;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  VSoft.Process.Windows,
  VSoft.Process.Tests.Common;

const
  cFakeUser = 'nobody@nowhere.example';
  cFakePassword = 'not a password';

type
  // Stands in for CreateProcessWithLogonW: says it has been entered, blocks
  // until released (or ReleaseAfterMs), then fails as a wrong password would.
  TBlockingLogonProcess = class(TWindowsProcess)
  protected
    function LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                             const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL; override;
  public
    Entered : TEvent;
    Release : TEvent;
    ReleaseAfterMs : Cardinal;
  end;

function TBlockingLogonProcess.LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                                               const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL;
begin
  Entered.SetEvent;
  Release.WaitFor(ReleaseAfterMs);
  SetLastError(ERROR_LOGON_FAILURE);
  result := False;
end;

procedure SetNetOnlyCredentials(const proc : IProcess);
begin
  proc.Credentials.UserName := cFakeUser;
  proc.Credentials.Password := cFakePassword;
  proc.Credentials.NetCredentialsOnly := True;
end;

// Ends the test (not run, so passed, as the suite does elsewhere) when the
// Secondary Logon service can't be used here.
procedure IgnoreWhenNoSecondaryLogon(const proc : IProcess);
begin
  if (proc.LastError = ERROR_SERVICE_DISABLED) or (proc.LastError = ERROR_SERVICE_DOES_NOT_EXIST) then
    Assert.Pass('NOT RUN: the Secondary Logon service is not available: ' + proc.Errors.Text);
end;

{ TProcessLogonTests }

procedure TProcessLogonTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TProcessLogonTests.LogonLaunch_DoesNotBlockOtherLaunches;
var
  entered : TEvent;
  release : TEvent;
  blocking : TBlockingLogonProcess;
  logonProc : IProcess;
  logonOutput : TStringBuilder;
  plainOutput : TStringBuilder;
  plain : IProcess;
  launcher : TThread;
  logonResult : boolean;
  started : Int64;
  elapsed : Int64;
  completed : boolean;
begin
  entered := TEvent.Create(nil, true, false, '');
  release := TEvent.Create(nil, true, false, '');
  logonOutput := TStringBuilder.Create;
  plainOutput := TStringBuilder.Create;
  launcher := nil;
  try
    blocking := TBlockingLogonProcess.Create;
    blocking.Entered := entered;
    blocking.Release := release;
    blocking.ReleaseAfterMs := 8000;
    logonProc := blocking;
    TTestHelpers.SetupInlineCommand(logonProc, 'exit 0', 'exit 0');
    SetNetOnlyCredentials(logonProc);
    // Redirected, so the logon launch has pipe ends to hand over.
    logonProc.WithStdOutPipe(TPipeTarget.ToStringBuilder(logonOutput));
    logonResult := true;
    launcher := TThread.CreateAnonymousThread(
      procedure
      begin
        logonResult := logonProc.Execute;
      end);
    launcher.FreeOnTerminate := False;
    launcher.Start;
    Assert.IsTrue(entered.WaitFor(10000) = wrSignaled, 'the logon launch was never made');

    // The logon launch is now in progress. A plain launch must not wait for
    // it: ExecuteAsync blocks for as long as the launch itself does.
    plain := TProcess.Create;
    TTestHelpers.SetupInlineCommand(plain, 'echo plain-done', 'echo plain-done');
    plain.WithStdOutPipe(TPipeTarget.ToStringBuilder(plainOutput));
    started := TTestHelpers.TickMs;
    Assert.IsTrue(plain.ExecuteAsync, plain.Errors.Text);
    completed := TTestHelpers.WaitWhileRunning(plain, 5000);
    elapsed := TTestHelpers.TickMs - started;

    release.SetEvent;
    launcher.WaitFor;
    Assert.IsTrue(completed and (elapsed < 3000),
                  'The plain launch took ' + IntToStr(elapsed) + 'ms: it waited for the logon launch');
    Assert.Contains(plainOutput.ToString, 'plain-done');
    Assert.IsFalse(logonResult, 'the stubbed logon fails');
    Assert.AreEqual<Cardinal>(ERROR_LOGON_FAILURE, logonProc.LastError, logonProc.Errors.Text);
  finally
    release.SetEvent;
    if launcher <> nil then
    begin
      launcher.WaitFor;
      launcher.Free;
    end;
    plain := nil;
    logonProc := nil;
    plainOutput.Free;
    logonOutput.Free;
    release.Free;
    entered.Free;
  end;
end;

procedure TProcessLogonTests.NetOnlyLogon_RedirectsStdOutAndStdErr;
var
  proc : IProcess;
  outSB : TStringBuilder;
  errSB : TStringBuilder;
  launched : boolean;
begin
  outSB := TStringBuilder.Create;
  errSB := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'print-both', ['3']);
    SetNetOnlyCredentials(proc);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(outSB));
    proc.WithStdErrPipe(TPipeTarget.ToStringBuilder(errSB));
    launched := proc.Execute;
    IgnoreWhenNoSecondaryLogon(proc);
    Assert.IsTrue(launched, 'LastError ' + IntToStr(proc.LastError) + ': ' + proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.Contains(outSB.ToString, 'out 3: the quick brown fox', 'stdout: ' + proc.Errors.Text);
    Assert.Contains(errSB.ToString, 'err 3: the quick brown fox', 'stderr: ' + proc.Errors.Text);
  finally
    proc := nil;
    errSB.Free;
    outSB.Free;
  end;
end;

procedure TProcessLogonTests.NetOnlyLogon_ChildInheritsNoOtherHandle;
var
  sa : TSecurityAttributes;
  readEnd : THandle;
  writeEnd : THandle;

  // Closes our write end and times how long a read takes to see the end of
  // the pipe: until every other holder of the write end has closed it.
  function MsUntilPipeEnds : Int64;
  var
    started : Int64;
    buffer : Byte;
    bytesRead : DWORD;
  begin
    CloseHandle(writeEnd);
    writeEnd := 0;
    started := TTestHelpers.TickMs;
    ReadFile(readEnd, buffer, 1, bytesRead, nil);
    result := TTestHelpers.TickMs - started;
  end;

  procedure CreateProbePipe;
  begin
    sa.nLength := SizeOf(sa);
    sa.lpSecurityDescriptor := nil;
    sa.bInheritHandle := True;
    Win32Check(CreatePipe(readEnd, writeEnd, @sa, 0));
    // Only the write end is the probe.
    SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);
  end;

  procedure ClosePipe;
  begin
    if writeEnd <> 0 then
      CloseHandle(writeEnd);
    if readEnd <> 0 then
      CloseHandle(readEnd);
    writeEnd := 0;
    readEnd := 0;
  end;

var
  proc : IProcess;
  startup : TStartupInfo;
  processInfo : TProcessInformation;
  command : string;
  elapsed : Int64;
  launched : boolean;
begin
  readEnd := 0;
  writeEnd := 0;
  try
    // Control: a child that does inherit the write end keeps the pipe open
    // until it exits, so the read waits for it.
    CreateProbePipe;
    ZeroMemory(@startup, SizeOf(startup));
    startup.cb := SizeOf(startup);
    command := TTestHelpers.ShellExePath + ' /c ping -n 3 127.0.0.1 > nul';
    UniqueString(command);
    Win32Check(CreateProcess(nil, PChar(command), nil, nil, True, CREATE_NO_WINDOW, nil, nil, startup, processInfo));
    CloseHandle(processInfo.hThread);
    try
      elapsed := MsUntilPipeEnds;
      Assert.IsTrue(elapsed >= 1000, 'Control: a child that inherited the probe should hold it open (' + IntToStr(elapsed) + 'ms)');
    finally
      WaitForSingleObject(processInfo.hProcess, 10000);
      CloseHandle(processInfo.hProcess);
    end;
    ClosePipe;

    // The logon child, launched while the probe is inheritable.
    CreateProbePipe;
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupInlineCommand(proc, 'ping -n 4 127.0.0.1 > nul', '');
    SetNetOnlyCredentials(proc);
    launched := proc.ExecuteAsync;
    IgnoreWhenNoSecondaryLogon(proc);
    Assert.IsTrue(launched, 'LastError ' + IntToStr(proc.LastError) + ': ' + proc.Errors.Text);
    elapsed := MsUntilPipeEnds;
    Assert.IsTrue(elapsed < 1000, 'The logon child inherited the probe handle: the pipe stayed open ' + IntToStr(elapsed) + 'ms');
    Assert.IsTrue(TTestHelpers.WaitWhileRunning(proc, 15000), 'the logon child did not finish');
  finally
    proc := nil;
    ClosePipe;
  end;
end;

procedure TProcessLogonTests.NetOnlyLogon_LaunchFails_ReportsTheOsError;
var
  proc : IProcess;
  exeName : string;
  textFile : TStringList;
begin
  exeName := TTestHelpers.TempFileName('vsoft_proc_notexe_', '.exe');
  textFile := TStringList.Create;
  try
    textFile.Add('This is a text file, not a program.');
    textFile.SaveToFile(exeName);
  finally
    textFile.Free;
  end;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := exeName;
    SetNetOnlyCredentials(proc);
    Assert.IsFalse(proc.Execute, 'a text file is not a program');
    IgnoreWhenNoSecondaryLogon(proc);
    // The code is the service's (ERROR_FILE_NOT_FOUND here, for a file
    // CreateProcess calls not a valid application), but never 0.
    Assert.AreNotEqual<Cardinal>(0, proc.LastError, 'LastError: ' + proc.Errors.Text);
    Assert.AreEqual(0, Pos(SysErrorMessage(ERROR_SUCCESS), proc.Errors.Text), proc.Errors.Text);
    Assert.AreEqual(0, Pos('%1', proc.Errors.Text), proc.Errors.Text);
  finally
    proc := nil;
    if FileExists(exeName) then
      DeleteFile(exeName);
  end;
end;

procedure TProcessLogonTests.NetOnlyLogon_InheritHostStdHandles_StdErrGoesToHostStdErr;
var
  fileName : string;
  fileHandle : THandle;
  oldStdErr : THandle;
  proc : IProcess;
  output : TStringBuilder;
  launched : boolean;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_logonerr_', '.txt');
  fileHandle := CreateFile(PChar(fileName), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  Win32Check(fileHandle <> INVALID_HANDLE_VALUE);
  output := TStringBuilder.Create;
  try
    // Only stderr is swapped: the test logger writes to stdout.
    oldStdErr := GetStdHandle(STD_ERROR_HANDLE);
    SetStdHandle(STD_ERROR_HANDLE, fileHandle);
    try
      proc := TProcess.Create;
      proc.StartInfo.InheritHostStdHandles := True;
      proc.StartInfo.TimeoutInMSec := 30000;
      TTestHelpers.SetupShellCommand(proc, 'print-stderr', []);
      SetNetOnlyCredentials(proc);
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
      launched := proc.Execute;
    finally
      SetStdHandle(STD_ERROR_HANDLE, oldStdErr);
      CloseHandle(fileHandle);
    end;
    IgnoreWhenNoSecondaryLogon(proc);
    Assert.IsTrue(launched, 'LastError ' + IntToStr(proc.LastError) + ': ' + proc.Errors.Text);
    Assert.Contains(output.ToString, 'this-is-stdout', proc.Errors.Text);
    Assert.Contains(TEncoding.ANSI.GetString(TTestHelpers.ReadFileBytes(fileName)), 'this-is-stderr', proc.Errors.Text);
  finally
    proc := nil;
    output.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TProcessLogonTests.NetOnlyLogon_FileAsStdIn_ChildReadsTheFile;
var
  fileName : string;
  lines : TStringList;
  proc : IProcess;
  output : TStringBuilder;
  launched : boolean;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_logonin_', '.txt');
  lines := TStringList.Create;
  try
    lines.Add('line-for-the-logon-child');
    lines.SaveToFile(fileName);
  finally
    lines.Free;
  end;
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
    SetNetOnlyCredentials(proc);
    proc.WithStdInPipe(TPipeSource.FileAsStdIn(fileName));
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    launched := proc.Execute;
    IgnoreWhenNoSecondaryLogon(proc);
    Assert.IsTrue(launched, 'LastError ' + IntToStr(proc.LastError) + ': ' + proc.Errors.Text);
    Assert.Contains(output.ToString, 'line-for-the-logon-child', proc.Errors.Text);
  finally
    proc := nil;
    output.Free;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessLogonTests);
{$ENDIF}

end.
