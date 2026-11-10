unit VSoft.Process.Tests.Review.Support;

interface

// Tests for the "Supporting units" findings of docs\CODE_REVIEW_2026-11-10.md
// (SUP-1, SUP-3 .. SUP-8; SUP-2 is POSIX only and lives elsewhere). Every
// test asserts the correct behaviour, so a test that fails proves its finding
// and passes once the library is fixed.
//
// The Windows tests that need a child which reports its argv start this test
// exe itself with --review-sup-argv: the initialization section of this unit
// then prints the arguments (as CommandLineToArgvW splits them) and halts
// before the test runner starts.

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TReviewSupportTests = class
  public
    {$IFDEF MSWINDOWS}
    [Setup]
    procedure SetUp;

    // SUP-1 (batch half). A failure with "cmd.exe ran text from the argument"
    // means a NUL in an argument added with the safe Add let cmd.exe run part
    // of that argument as a command (the marker file was created). A failure
    // on the second assert alone means nothing was injected but the launch
    // was still not refused.
    [Test]
    procedure SUP1_BatchArgument_WithNul_IsRejected;

    // SUP-1 (batch half), the same through Add(name, value).
    [Test]
    procedure SUP1_BatchArgumentValue_WithNul_IsRejected;

    // SUP-1 (.exe half). A failure means the arguments added after one that
    // holds a NUL never reached the child and no error was reported.
    [Test]
    procedure SUP1_ExeArgument_WithNul_LaterArgumentsNotDropped;

    // SUP-3. A failure means AddUnsafeBatchRaw('') hands the batch file an
    // empty argument ("") where CreateProcess(nil, '"x.bat" ' + '') gives it
    // none.
    [Test]
    procedure SUP3_AddUnsafeBatchRaw_EmptyText_BatchReceivesNoArgument;

    // SUP-4. A failure means a value ending in a backslash reaches a batch
    // file with the backslash doubled when the value holds no space.
    [Test]
    procedure SUP4_BatchValue_TrailingBackslash_NotDoubled;

    // SUP-5. A failure means the rendered text, split the way a child splits
    // its command line (CommandLineToArgvW), is not the one argument added.
    [Test]
    procedure SUP5_NameEndingInBackslash_QuotedValue_RendersAsOneArgument;

    // SUP-5, through a real child. A failure shows what the child received.
    [Test]
    procedure SUP5_NameEndingInBackslash_QuotedValue_ChildReceivesOneArgument;

    // SUP-6. A failure means Validate accepts a DOMAIN\user name with no
    // Domain (which the launch then looks up in the local account database).
    // This pins the "reject it" fix; see the next test for "split it".
    [Test]
    procedure SUP6_Validate_DownLevelUserNameWithoutDomain_IsRejected;

    // SUP-6, through Execute with the logon stubbed (no logon is attempted).
    // Passes when the launch is refused before the logon, or when the
    // credentials the launcher sees have been split into user and domain. A
    // failure means the launcher was reached with DOMAIN\user and no domain.
    // A fix that splits the name in local variables inside LaunchWithLogon
    // cannot be seen from here and would still fail this test.
    [Test]
    procedure SUP6_Execute_DownLevelUserNameWithoutDomain_NotSentAsLocalAccount;

    // SUP-8. A failure means TProcess.Create copies the host environment
    // although Environment is never touched: the number of allocations it
    // makes grows with the number of host variables. The message gives the
    // measured counts and times.
    [Test]
    procedure SUP8_Create_AllocationsDoNotGrowWithHostEnvironment;

    // SUP-8, for Clone. A failure means Clone reads the host environment
    // again before copying the source's variables over it.
    [Test]
    procedure SUP8_Clone_AllocationsDoNotGrowWithHostEnvironment;
    {$ENDIF}

    // SUP-3, the rendered text. A failure means the empty raw text renders
    // as an explicit empty argument.
    [Test]
    procedure SUP3_AddUnsafeBatchRaw_EmptyText_RendersNothing;

    // SUP-7 is a README wording problem; this pins the code side the README
    // should describe. A failure means the Password getter no longer hands
    // out a copy of its own that the caller can wipe with ScrubString.
    [Test]
    procedure SUP7_PasswordGetter_ReturnsCopyTheCallerCanScrub;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  System.Diagnostics,
  VSoft.Process.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  VSoft.Process,
  VSoft.Process.CommandLine,
  VSoft.Process.Credentials,
  VSoft.Process.Tests.Common;

{$IFDEF MSWINDOWS}
const
  cArgvSwitch = '--review-sup-argv';
  cChildTimeoutMs = 20000;
  cFakePassword = 'not a password';
  // Made up: no such domain or account.
  cFakeDomain = 'VSPNOSUCHDOMAIN';
  cFakeAccount = 'sup6-nobody';
  cExtraHostVariables = 400;
  cTimedRuns = 200;

function ShellCommandLineToArgvW(commandLine : PWideChar; var argCount : Integer) : Pointer; stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

// The arguments a child using the standard Windows rules gets from
// commandLine (the program name, argv[0], included).
function SplitCommandLine(const commandLine : string) : TArray<string>;
var
  argv : Pointer;
  argCount : Integer;
  i : integer;
begin
  SetLength(result, 0);
  argCount := 0;
  argv := ShellCommandLineToArgvW(PWideChar(commandLine), argCount);
  if argv = nil then
    RaiseLastOSError;
  try
    SetLength(result, argCount);
    for i := 0 to argCount - 1 do
      result[i] := PPWideChar(NativeUInt(argv) + NativeUInt(i) * SizeOf(Pointer))^;
  finally
    LocalFree(HLOCAL(argv));
  end;
end;

// argc=<n> then arg<i>=[<text>] for each argument after startIndex - 1.
function DescribeArguments(const args : TArray<string>; startIndex : integer) : string;
var
  i : integer;
begin
  result := 'argc=' + IntToStr(Length(args) - startIndex) + sLineBreak;
  for i := startIndex to High(args) do
    result := result + 'arg' + IntToStr(i - startIndex + 1) + '=[' + args[i] + ']' + sLineBreak;
end;

procedure RunArgvChildIfRequested;
begin
  if ParamStr(1) <> cArgvSwitch then
    Exit;
  // Skips the program name and the switch.
  Write(DescribeArguments(SplitCommandLine(GetCommandLineW), 2));
  Flush(Output);
  Halt(0);
end;

// A process that runs this exe as the argv-printing child.
function NewArgvChild : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.Executable := ParamStr(0);
  result.StartInfo.TimeoutInMSec := cChildTimeoutMs;
  result.CommandLine.Add(cArgvSwitch);
end;

function NewBatchProcess(const scriptBaseName : string) : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.Executable := TTestHelpers.ScriptPath(scriptBaseName);
  result.StartInfo.TimeoutInMSec := cChildTimeoutMs;
end;

// Runs proc to the end and returns what it wrote to stdout.
function RunCaptured(const proc : IProcess; out text : string) : boolean;
var
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    result := proc.Execute;
    text := output.ToString;
  finally
    output.Free;
  end;
end;

function RunSummary(const proc : IProcess; launched : boolean; const text : string) : string;
begin
  result := 'Execute=' + BoolToStr(launched, True) + ' errors=[' + Trim(proc.Errors.Text) + '] stdout=[' + Trim(text) + ']';
end;

// The payload is harmless: all the injected command can do is create the
// marker file in the TEMP directory, which is deleted again here. The marker
// is named without its folder (the child's working directory is TEMP), so
// the payload holds no character from the TEMP path.
procedure CheckBatchNulInjection(asValue : boolean);
var
  markerPath : string;
  markerName : string;
  payload : string;
  text : string;
  proc : IProcess;
  launched : boolean;
  injected : boolean;

  function NewRun(const argument : string) : IProcess;
  begin
    result := NewBatchProcess('review-sup-noop');
    result.StartInfo.WorkingDirectory := ExcludeTrailingPathDelimiter(ExtractFilePath(markerPath));
    if asValue then
      result.CommandLine.Add('--name', argument)
    else
      result.CommandLine.Add(argument);
  end;

begin
  markerPath := TTestHelpers.TempFileName('vsp_sup1_', '.txt');
  markerName := ExtractFileName(markerPath);
  payload := 'a&echo INJECTED>' + markerName;
  try
    // Control: without the NUL the same text is quoted and stays an argument.
    proc := NewRun(payload);
    launched := RunCaptured(proc, text);
    Assert.IsTrue(launched, 'control run: ' + RunSummary(proc, launched, text));
    Assert.Contains(text, 'review-sup-noop ran', 'control run: ' + RunSummary(proc, launched, text));
    Assert.IsFalse(FileExists(markerPath), 'control run: the argument without a NUL was run as a command');

    proc := NewRun(payload + #0);
    launched := RunCaptured(proc, text);
    injected := FileExists(markerPath);
    Assert.IsFalse(injected, 'cmd.exe ran text from the argument as a command: the marker file ' + markerPath +
                             ' was created. ' + RunSummary(proc, launched, text));
    Assert.IsFalse(launched, 'an argument holding a NUL must be refused. ' + RunSummary(proc, launched, text));
  finally
    proc := nil;
    if FileExists(markerPath) then
      DeleteFile(markerPath);
  end;
end;

type
  // Stands in for CreateProcessWithLogonW: records the credentials it would
  // have used and fails as a wrong password would. Nothing is logged on.
  TRecordingLogonProcess = class(TWindowsProcess)
  private
    FCalled : boolean;
    FSeenUserName : string;
    FSeenDomain : string;
  protected
    function LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                             const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL; override;
  public
    property Called : boolean read FCalled;
    property SeenUserName : string read FSeenUserName;
    property SeenDomain : string read FSeenDomain;
  end;

function TRecordingLogonProcess.LaunchWithLogon(const command : string; creationFlags : DWORD; pEnvironment : Pointer; pWorkingDir : PChar;
                                                const startupInfo : TStartupInfoW; var processInfo : TProcessInformation) : BOOL;
begin
  FCalled := True;
  FSeenUserName := Credentials.UserName;
  FSeenDomain := Credentials.Domain;
  SetLastError(ERROR_LOGON_FAILURE);
  result := False;
end;

var
  GInnerMemoryManager : TMemoryManagerEx;
  GCountedThreadId : TThreadID;
  GAllocationCount : Integer;

function CountingGetMem(size : NativeInt) : Pointer;
begin
  if GetCurrentThreadId = GCountedThreadId then
    Inc(GAllocationCount);
  result := GInnerMemoryManager.GetMem(size);
end;

function CountingAllocMem(size : NativeInt) : Pointer;
begin
  if GetCurrentThreadId = GCountedThreadId then
    Inc(GAllocationCount);
  result := GInnerMemoryManager.AllocMem(size);
end;

// Counts the blocks this thread allocates until EndAllocationCount. The
// wrapper passes every call on to the memory manager in use, so blocks made
// under it are freed as usual.
procedure BeginAllocationCount;
var
  counting : TMemoryManagerEx;
begin
  GetMemoryManager(GInnerMemoryManager);
  counting := GInnerMemoryManager;
  counting.GetMem := CountingGetMem;
  counting.AllocMem := CountingAllocMem;
  GAllocationCount := 0;
  GCountedThreadId := GetCurrentThreadId;
  SetMemoryManager(counting);
end;

function EndAllocationCount : Integer;
begin
  SetMemoryManager(GInnerMemoryManager);
  GCountedThreadId := 0;
  result := GAllocationCount;
end;

function AllocationsOfCreate : Integer;
var
  proc : IProcess;
begin
  BeginAllocationCount;
  try
    proc := TProcess.Create;
  finally
    result := EndAllocationCount;
  end;
end;

function AllocationsOfClone(const source : IProcess) : Integer;
var
  proc : IProcess;
begin
  BeginAllocationCount;
  try
    proc := source.Clone;
  finally
    result := EndAllocationCount;
  end;
end;

function MicrosecondsPerCreate : Double;
var
  clock : TStopwatch;
  proc : IProcess;
  i : integer;
begin
  clock := TStopwatch.StartNew;
  for i := 1 to cTimedRuns do
    proc := TProcess.Create;
  result := clock.Elapsed.TotalMilliseconds * 1000 / cTimedRuns;
end;

function MicrosecondsPerClone(const source : IProcess) : Double;
var
  clock : TStopwatch;
  proc : IProcess;
  i : integer;
begin
  clock := TStopwatch.StartNew;
  for i := 1 to cTimedRuns do
    proc := source.Clone;
  result := clock.Elapsed.TotalMilliseconds * 1000 / cTimedRuns;
end;

function ExtraHostVariableName(index : integer) : string;
begin
  result := 'VSP_REVIEW_SUP8_' + IntToStr(index);
end;

procedure SetExtraHostVariables;
var
  i : integer;
begin
  for i := 1 to cExtraHostVariables do
    TTestHelpers.SetEnvVar(ExtraHostVariableName(i), 'value-' + IntToStr(i));
end;

procedure RemoveExtraHostVariables;
var
  i : integer;
begin
  for i := 1 to cExtraHostVariables do
    TTestHelpers.UnsetEnvVar(ExtraHostVariableName(i));
end;

{ TReviewSupportTests - Windows }

procedure TReviewSupportTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TReviewSupportTests.SUP1_BatchArgument_WithNul_IsRejected;
begin
  CheckBatchNulInjection(False);
end;

procedure TReviewSupportTests.SUP1_BatchArgumentValue_WithNul_IsRejected;
begin
  CheckBatchNulInjection(True);
end;

procedure TReviewSupportTests.SUP1_ExeArgument_WithNul_LaterArgumentsNotDropped;
var
  proc : IProcess;
  text : string;
  launched : boolean;
begin
  // Control: the child reports every argument when none holds a NUL.
  proc := NewArgvChild;
  proc.CommandLine.Add('one').Add('two').Add('--dry-run');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, 'control run: ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'argc=3', 'control run: ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'arg3=[--dry-run]', 'control run: ' + RunSummary(proc, launched, text));

  proc := NewArgvChild;
  proc.CommandLine.Add('one' + #0).Add('two').Add('--dry-run');
  launched := RunCaptured(proc, text);
  // Refusing the launch is the correct outcome. If it is launched anyway,
  // nothing added after the NUL may go missing.
  if launched then
  begin
    Assert.IsTrue((Pos('arg2=[two]', text) > 0) and (Pos('arg3=[--dry-run]', text) > 0),
                  'the arguments after the one holding a NUL were dropped without an error. ' + RunSummary(proc, launched, text));
  end
  else
    Assert.IsTrue(proc.Errors.Count > 0, 'a refused launch must say why');
end;

procedure TReviewSupportTests.SUP3_AddUnsafeBatchRaw_EmptyText_BatchReceivesNoArgument;
var
  proc : IProcess;
  text : string;
  launched : boolean;
begin
  // Control: the script reports raw text as it received it.
  proc := NewBatchProcess('review-sup-rawargs');
  proc.CommandLine.AddUnsafeBatchRaw('x "y z"');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, 'control run: ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'all=[x "y z"]', 'control run: ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'first=[x]', 'control run: ' + RunSummary(proc, launched, text));

  proc := NewBatchProcess('review-sup-rawargs');
  proc.CommandLine.AddUnsafeBatchRaw('');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, RunSummary(proc, launched, text));
  Assert.Contains(text, 'all=[]', 'the batch file was given something for empty raw text. ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'first=[]', 'the batch file was given a first argument for empty raw text. ' + RunSummary(proc, launched, text));
end;

procedure TReviewSupportTests.SUP4_BatchValue_TrailingBackslash_NotDoubled;
var
  proc : IProcess;
  text : string;
  launched : boolean;
begin
  // Control: with a space in it the same kind of value arrives unchanged.
  proc := NewBatchProcess('echo-args');
  proc.CommandLine.Add('--out', 'C:\my build\');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, 'control run: ' + RunSummary(proc, launched, text));
  Assert.Contains(text, 'arg2=[C:\my build\]', 'control run: ' + RunSummary(proc, launched, text));

  proc := NewBatchProcess('echo-args');
  proc.CommandLine.Add('--out', 'C:\build\');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, RunSummary(proc, launched, text));
  Assert.Contains(text, 'arg2=[C:\build\]', 'the batch file did not receive the value as added. ' + RunSummary(proc, launched, text));
end;

procedure TReviewSupportTests.SUP5_NameEndingInBackslash_QuotedValue_RendersAsOneArgument;
var
  cmd : ICommandLineBuilder;
  args : TArray<string>;
  rendered : string;
begin
  // Control: without the trailing backslash on the name it is one argument.
  cmd := TArgumentsBuilder.Create;
  cmd.WithDefaultValueSeparator('');
  cmd.Add('/out:C:\build', 'my file.txt');
  args := SplitCommandLine('x.exe ' + cmd.ToString);
  Assert.AreEqual('argc=1' + sLineBreak + 'arg1=[/out:C:\buildmy file.txt]' + sLineBreak, DescribeArguments(args, 1), 'control: ' + cmd.ToString);

  cmd := TArgumentsBuilder.Create;
  cmd.WithDefaultValueSeparator('');
  cmd.Add('/out:C:\build\', 'my file.txt');
  rendered := cmd.ToString;
  args := SplitCommandLine('x.exe ' + rendered);
  Assert.AreEqual('argc=1' + sLineBreak + 'arg1=[/out:C:\build\my file.txt]' + sLineBreak, DescribeArguments(args, 1),
                  'what a child makes of the rendered text ' + rendered);
end;

procedure TReviewSupportTests.SUP5_NameEndingInBackslash_QuotedValue_ChildReceivesOneArgument;
var
  proc : IProcess;
  text : string;
  launched : boolean;
begin
  proc := NewArgvChild;
  proc.CommandLine.WithDefaultValueSeparator('');
  proc.CommandLine.Add('/out:C:\build\', 'my file.txt');
  launched := RunCaptured(proc, text);
  Assert.IsTrue(launched, RunSummary(proc, launched, text));
  Assert.AreEqual('argc=1' + sLineBreak + 'arg1=[/out:C:\build\my file.txt]', Trim(text),
                  'what the child received for ' + proc.CommandLine.ToString);
end;

procedure TReviewSupportTests.SUP6_Validate_DownLevelUserNameWithoutDomain_IsRejected;
var
  creds : ICredentialsBuilder;
  errors : TStringList;
  collect : TConstProc<string>;
  valid : boolean;
begin
  errors := TStringList.Create;
  try
    collect := procedure(const msg : string)
               begin
                 errors.Add(msg);
               end;
    // Control: the same account given as Domain + UserName is accepted.
    creds := TCredentialsBuilder.Create;
    creds.WithUser(cFakeAccount).WithDomain(cFakeDomain).WithPassword(cFakePassword);
    Assert.IsTrue(creds.Validate(collect), 'control: ' + errors.Text);

    creds := TCredentialsBuilder.Create;
    creds.WithUser(cFakeDomain + '\' + cFakeAccount).WithPassword(cFakePassword);
    valid := creds.Validate(collect);
    Assert.IsFalse(valid, 'Validate accepted UserName "' + creds.UserName + '" with Domain "' + creds.Domain +
                          '": the launch would look that name up in the local account database (domain ".")');
    Assert.IsTrue(errors.Count > 0, 'a rejected user name must come with a message');
  finally
    creds := nil;
    collect := nil;
    errors.Free;
  end;
end;

procedure TReviewSupportTests.SUP6_Execute_DownLevelUserNameWithoutDomain_NotSentAsLocalAccount;
var
  recorder : TRecordingLogonProcess;
  proc : IProcess;
  launched : boolean;
begin
  recorder := TRecordingLogonProcess.Create;
  proc := recorder;
  proc.StartInfo.TimeoutInMSec := cChildTimeoutMs;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
  proc.Credentials.UserName := cFakeDomain + '\' + cFakeAccount;
  proc.Credentials.Password := cFakePassword;
  proc.Credentials.NetCredentialsOnly := True;
  launched := proc.Execute;
  Assert.IsFalse(launched, 'the stubbed logon never starts anything');
  if recorder.Called then
  begin
    Assert.IsTrue((recorder.SeenUserName = cFakeAccount) and SameText(recorder.SeenDomain, cFakeDomain),
                  'the logon was reached with UserName "' + recorder.SeenUserName + '" and Domain "' + recorder.SeenDomain +
                  '": LaunchWithLogon passes domain "." for that, the local account database');
  end
  else
    Assert.IsTrue(proc.Errors.Count > 0, 'a launch refused at validation must say why');
end;

procedure TReviewSupportTests.SUP8_Create_AllocationsDoNotGrowWithHostEnvironment;
var
  proc : IProcess;
  hostVariables : integer;
  plainAllocations : integer;
  grownAllocations : integer;
  plainMicros : Double;
  grownMicros : Double;
  report : string;
begin
  // Warm up, so one-off allocations are not counted.
  proc := TProcess.Create;
  hostVariables := proc.Environment.Count;
  proc := nil;
  plainAllocations := AllocationsOfCreate;
  plainMicros := MicrosecondsPerCreate;
  SetExtraHostVariables;
  try
    grownAllocations := AllocationsOfCreate;
    grownMicros := MicrosecondsPerCreate;
  finally
    RemoveExtraHostVariables;
  end;
  report := Format('TProcess.Create, Environment never touched: %d allocations and %.1f us with the host environment as it is (%d variables); ' +
                   '%d allocations and %.1f us with %d more variables in the host environment',
                   [plainAllocations, plainMicros, hostVariables, grownAllocations, grownMicros, cExtraHostVariables]);
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, report);
  Assert.IsTrue(grownAllocations - plainAllocations < cExtraHostVariables div 2,
                'Creating a process copies the host environment. ' + report);
end;

procedure TReviewSupportTests.SUP8_Clone_AllocationsDoNotGrowWithHostEnvironment;
var
  source : IProcess;
  proc : IProcess;
  sourceVariables : integer;
  plainAllocations : integer;
  grownAllocations : integer;
  plainMicros : Double;
  grownMicros : Double;
  report : string;
begin
  source := TProcess.Create;
  sourceVariables := source.Environment.Count;
  proc := source.Clone;
  proc := nil;
  plainAllocations := AllocationsOfClone(source);
  plainMicros := MicrosecondsPerClone(source);
  SetExtraHostVariables;
  try
    // The source still holds the variables it was created with: a clone has
    // no use for the ones added to the host since.
    grownAllocations := AllocationsOfClone(source);
    grownMicros := MicrosecondsPerClone(source);
  finally
    RemoveExtraHostVariables;
  end;
  report := Format('IProcess.Clone of a process holding %d variables: %d allocations and %.1f us with the host environment as it was; ' +
                   '%d allocations and %.1f us with %d more variables in the host environment',
                   [sourceVariables, plainAllocations, plainMicros, grownAllocations, grownMicros, cExtraHostVariables]);
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, report);
  Assert.IsTrue(grownAllocations - plainAllocations < cExtraHostVariables div 2,
                'Cloning a process reads the host environment again. ' + report);
end;
{$ENDIF}

{ TReviewSupportTests - all platforms }

procedure TReviewSupportTests.SUP3_AddUnsafeBatchRaw_EmptyText_RendersNothing;
var
  cmd : ICommandLineBuilder;
begin
  // Control: raw text is rendered exactly as given.
  cmd := TArgumentsBuilder.Create;
  cmd.AddUnsafeBatchRaw('x "y z"');
  Assert.AreEqual('x "y z"', cmd.ToString, 'control');

  cmd := TArgumentsBuilder.Create;
  cmd.AddUnsafeBatchRaw('');
  Assert.AreEqual('', cmd.ToString, 'empty raw text must add nothing to the command line');
  Assert.AreEqual('', cmd.ToLogString, 'empty raw text must add nothing to the logged command line');
end;

procedure TReviewSupportTests.SUP7_PasswordGetter_ReturnsCopyTheCallerCanScrub;
var
  creds : ICredentialsBuilder;
  secret : string;
  first : string;
  second : string;
begin
  // A heap string, as a password read at run time is.
  secret := 'sup7-secret-' + IntToStr(TTestHelpers.TickMs mod 1000);
  creds := TCredentialsBuilder.Create;
  creds.Password := secret;
  first := creds.Password;
  second := creds.Password;
  Assert.AreEqual(secret, first);
  Assert.IsTrue(Pointer(first) <> Pointer(secret), 'the builder shares the buffer of the string it was given');
  Assert.IsTrue(Pointer(first) <> Pointer(second), 'two reads of Password share one buffer');
  // ScrubString only zeroes a buffer nothing else references.
  Assert.AreEqual(1, StringRefCount(first), 'the copy handed out is referenced by something besides the caller');
  ScrubString(first);
  Assert.AreEqual('', first);
  Assert.AreEqual(secret, second, 'scrubbing one copy changed another');
  Assert.AreEqual(secret, creds.Password, 'scrubbing a copy changed the password the builder holds');
  ScrubString(second);
end;

initialization
  {$IFDEF MSWINDOWS}
  RunArgvChildIfRequested;
  {$ENDIF}
  TDUnitX.RegisterTestFixture(TReviewSupportTests);

end.
