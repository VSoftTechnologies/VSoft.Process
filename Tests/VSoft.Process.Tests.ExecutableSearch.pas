unit VSoft.Process.Tests.ExecutableSearch;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  // An Executable without a folder part is searched for on this process's
  // PATH, never on the PATH given to the child in Environment, so the child
  // can be given a constrained PATH (or none) without affecting the lookup.
  [TestFixture]
  TExecutableSearchTests = class
  private
    FTempDir : string;
    FProbe : string;
    FSavedHostPath : string;
    FHadHostPath : boolean;
    FHostPathChanged : boolean;
    procedure SetHostPath(const value : string; exists : boolean);
    procedure PrependToHostPath(const dir : string);
    procedure SetupProbe(const proc : IProcess; const executable : string; exitCode : integer);
    procedure SetupBareShell(const proc : IProcess; const windowsCommand : string; const posixCommand : string);
    function IsSystemShell(const fileName : string) : boolean;
  public
    [Setup]
    procedure SetUp;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure BareName_FoundOnHostPath;
    [Test]
    procedure BareName_FoundOnHostPath_WhenChildPathIsConstrained;
    [Test]
    procedure BareName_ConstrainedChildPath_ReachesChild;
    [Test]
    procedure BareName_ChildPathIsNotSearched;
    [Test]
    procedure BareName_EnvironmentCleared_FoundOnHostPath;
    [Test]
    procedure BareName_NotOnPath_IsAValidationError;
    [Test]
    procedure UnknownName_IsAValidationError;
    [Test]
    procedure BareName_CurrentDirectoryIsNotSearched;
    [Test]
    procedure PathWithFolder_RelativeToCurrentDirectory;
    {$IFDEF MSWINDOWS}
    [Test]
    procedure BareName_WithExtension_FoundOnHostPath;
    [Test]
    procedure BareName_WithoutExtension_ExeIsAppended;
    [Test]
    procedure BareName_BatchFile_RunsWithBatchRules;
    {$ELSE}
    [Test]
    procedure BareName_NotExecutable_IsSkipped;
    {$ENDIF}
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Stdlib,
  Posix.SysStat,
  {$ENDIF}
  System.StrUtils,
  System.IOUtils,
  VSoft.Process.Tests.Common;

const
  cProbeName = 'vproc_probe';
  {$IFDEF MSWINDOWS}
  cProbeFileName = cProbeName + '.exe';
  {$ELSE}
  cProbeFileName = cProbeName;
  {$ENDIF}

{$IFDEF MSWINDOWS}
function SystemCmd : string;
var
  buffer : array[0..MAX_PATH] of Char;
begin
  GetSystemDirectory(buffer, MAX_PATH);
  result := IncludeTrailingPathDelimiter(buffer) + 'cmd.exe';
end;
{$ELSE}
procedure MakeExecutable(const fileName : string);
begin
  if chmod(MarshaledAString(UTF8String(fileName)), $1ED) <> 0 then
    raise Exception.Create('chmod 755 failed for ' + fileName);
end;
{$ENDIF}

procedure TExecutableSearchTests.SetHostPath(const value : string; exists : boolean);
begin
  {$IFDEF MSWINDOWS}
  if exists then
    SetEnvironmentVariable('PATH', PChar(value))
  else
    SetEnvironmentVariable('PATH', nil);
  {$ELSE}
  if exists then
    setenv('PATH', MarshaledAString(UTF8String(value)), 1)
  else
    unsetenv('PATH');
  {$ENDIF}
end;

procedure TExecutableSearchTests.PrependToHostPath(const dir : string);
begin
  FHostPathChanged := true;
  SetHostPath(dir + PathSep + FSavedHostPath, true);
end;

procedure TExecutableSearchTests.SetupProbe(const proc : IProcess; const executable : string; exitCode : integer);
begin
  proc.StartInfo.Executable := executable;
  {$IFDEF MSWINDOWS}
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit ' + IntToStr(exitCode));
  {$ELSE}
  proc.CommandLine.Add(IntToStr(exitCode));
  {$ENDIF}
end;

procedure TExecutableSearchTests.SetupBareShell(const proc : IProcess; const windowsCommand : string; const posixCommand : string);
begin
  {$IFDEF MSWINDOWS}
  proc.StartInfo.Executable := 'cmd';
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add(windowsCommand);
  {$ELSE}
  proc.StartInfo.Executable := 'sh';
  proc.CommandLine.Add('-c');
  proc.CommandLine.Add(posixCommand);
  {$ENDIF}
end;

function TExecutableSearchTests.IsSystemShell(const fileName : string) : boolean;
begin
  {$IFDEF MSWINDOWS}
  result := SameText(SystemCmd, fileName);
  {$ELSE}
  result := (Copy(fileName, 1, 1) = '/') and (ExtractFileName(fileName) = 'sh') and FileExists(fileName);
  {$ENDIF}
end;

procedure TExecutableSearchTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
  FSavedHostPath := GetEnvironmentVariable('PATH');
  FHadHostPath := FSavedHostPath <> '';
  FHostPathChanged := false;
  // A program that is on no PATH, in a folder of its own: a copy of cmd.exe
  // on Windows, a script that exits with its first argument on POSIX.
  FTempDir := TTestHelpers.TempFileName('vproc_search_', '');
  TDirectory.CreateDirectory(FTempDir);
  FProbe := TPath.Combine(FTempDir, cProbeFileName);
  {$IFDEF MSWINDOWS}
  TFile.Copy(SystemCmd, FProbe);
  {$ELSE}
  TFile.WriteAllText(FProbe, '#!/bin/sh' + #10 + 'exit "$1"' + #10, TEncoding.ASCII);
  MakeExecutable(FProbe);
  {$ENDIF}
end;

procedure TExecutableSearchTests.TearDown;
begin
  if FHostPathChanged then
    SetHostPath(FSavedHostPath, FHadHostPath);
  if DirectoryExists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TExecutableSearchTests.BareName_FoundOnHostPath;
var
  proc : IProcess;
begin
  PrependToHostPath(FTempDir);
  proc := TProcess.Create;
  SetupProbe(proc, cProbeName, 5);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(5, proc.ExitCode);
  Assert.AreEqual(FProbe, proc.ResolvedExecutable);
end;

procedure TExecutableSearchTests.BareName_FoundOnHostPath_WhenChildPathIsConstrained;
var
  proc : IProcess;
begin
  // The child's PATH is a single folder that does not hold the program.
  PrependToHostPath(FTempDir);
  proc := TProcess.Create;
  SetupProbe(proc, cProbeName, 5);
  proc.Environment.AddOrSet('PATH', ExcludeTrailingPathDelimiter(TTestHelpers.ScriptsDir));
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(5, proc.ExitCode);
  Assert.AreEqual(FProbe, proc.ResolvedExecutable);
end;

procedure TExecutableSearchTests.BareName_ConstrainedChildPath_ReachesChild;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    SetupBareShell(proc, 'echo [%PATH%]', 'printf "[%s]\n" "$PATH"');
    proc.Environment.AddOrSet('PATH', FTempDir);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.IsTrue(IsSystemShell(proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
    Assert.Contains(output.ToString, '[' + FTempDir + ']');
  finally
    output.Free;
  end;
end;

procedure TExecutableSearchTests.BareName_ChildPathIsNotSearched;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  SetupProbe(proc, cProbeName, 5);
  proc.Environment.AddOrSet('PATH', FTempDir + PathSep + FSavedHostPath);
  Assert.IsFalse(proc.Execute, 'only this process''s PATH is searched, not the child''s');
  Assert.AreEqual<Cardinal>(0, proc.ProcessId);
  Assert.Contains(proc.Errors.Text, 'not found on the PATH');
end;

procedure TExecutableSearchTests.BareName_EnvironmentCleared_FoundOnHostPath;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  SetupBareShell(proc, 'exit 4', 'exit 4');
  proc.Environment.Clear;
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(4, proc.ExitCode);
  Assert.IsTrue(IsSystemShell(proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
end;

procedure TExecutableSearchTests.BareName_NotOnPath_IsAValidationError;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  SetupProbe(proc, cProbeName, 5);
  Assert.IsFalse(proc.Execute, 'a program that is not on the PATH must not be launched');
  Assert.AreEqual<Cardinal>(0, proc.ProcessId);
  Assert.Contains(proc.Errors.Text, cProbeName);
  Assert.Contains(proc.Errors.Text, 'not found on the PATH');
end;

procedure TExecutableSearchTests.UnknownName_IsAValidationError;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'vproc_definitely_not_a_program';
  Assert.IsFalse(proc.Execute);
  Assert.AreEqual<Cardinal>(0, proc.ProcessId);
  Assert.Contains(proc.Errors.Text, 'vproc_definitely_not_a_program');
  Assert.Contains(proc.Errors.Text, 'not found on the PATH');
end;

procedure TExecutableSearchTests.BareName_CurrentDirectoryIsNotSearched;
var
  proc : IProcess;
  previousDir : string;
begin
  // CreateProcess would look in the current directory first (a planting
  // risk); the library does not.
  previousDir := GetCurrentDir;
  SetCurrentDir(FTempDir);
  try
    proc := TProcess.Create;
    SetupProbe(proc, cProbeName, 5);
    Assert.IsFalse(proc.Execute, 'the current directory must not be searched');
    Assert.Contains(proc.Errors.Text, 'not found on the PATH');
  finally
    SetCurrentDir(previousDir);
  end;
end;

procedure TExecutableSearchTests.PathWithFolder_RelativeToCurrentDirectory;
var
  proc : IProcess;
  previousDir : string;
  relative : string;
begin
  previousDir := GetCurrentDir;
  SetCurrentDir(ExtractFilePath(ExcludeTrailingPathDelimiter(FTempDir)));
  try
    relative := TPath.Combine(ExtractFileName(FTempDir), cProbeFileName);
    proc := TProcess.Create;
    SetupProbe(proc, relative, 6);
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual<Cardinal>(6, proc.ExitCode);
    // Compare the tail only: the current directory may be reported through a
    // different (symlinked) path than the temp folder, as on macOS.
    Assert.IsTrue(EndsText(PathDelim + relative, proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
  finally
    SetCurrentDir(previousDir);
  end;
end;

{$IFDEF MSWINDOWS}
procedure TExecutableSearchTests.BareName_WithExtension_FoundOnHostPath;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'cmd.exe';
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit 3');
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(3, proc.ExitCode);
  Assert.IsTrue(SameText(SystemCmd, proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
end;

procedure TExecutableSearchTests.BareName_WithoutExtension_ExeIsAppended;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'cmd';
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add('exit 4');
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(4, proc.ExitCode);
  Assert.IsTrue(SameText(SystemCmd, proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
end;

procedure TExecutableSearchTests.BareName_BatchFile_RunsWithBatchRules;
var
  proc : IProcess;
  output : TStringBuilder;
begin
  PrependToHostPath(ExcludeTrailingPathDelimiter(TTestHelpers.ScriptsDir));
  output := TStringBuilder.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.Executable := 'echo-args.cmd';
    // Without the batch quoting cmd would split these into four arguments.
    proc.CommandLine.Add('a,b', TQuoted.qtNone);
    proc.CommandLine.Add('g h', TQuoted.qtNone);
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.IsTrue(SameText(TTestHelpers.ScriptPath('echo-args'), proc.ResolvedExecutable), 'ResolvedExecutable = "' + proc.ResolvedExecutable + '"');
    Assert.Contains(output.ToString, 'arg1=[a,b]');
    Assert.Contains(output.ToString, 'arg2=[g h]');
    Assert.Contains(output.ToString, 'total=2');

    proc := TProcess.Create;
    proc.StartInfo.Executable := 'echo-args.cmd';
    proc.CommandLine.Add('%PATH%');
    Assert.IsFalse(proc.Execute, 'batch rules must apply to a batch file found on the PATH');
    Assert.Contains(proc.Errors.Text, 'cannot be passed safely');
  finally
    output.Free;
  end;
end;
{$ELSE}
procedure TExecutableSearchTests.BareName_NotExecutable_IsSkipped;
var
  proc : IProcess;
begin
  TFile.WriteAllText(TPath.Combine(FTempDir, 'vproc_noexec'), '#!/bin/sh' + #10 + 'exit 0' + #10, TEncoding.ASCII);
  PrependToHostPath(FTempDir);
  proc := TProcess.Create;
  proc.StartInfo.Executable := 'vproc_noexec';
  Assert.IsFalse(proc.Execute, 'a file without execute permission must not be picked');
  Assert.Contains(proc.Errors.Text, 'not found on the PATH');
end;
{$ENDIF}

initialization
  TDUnitX.RegisterTestFixture(TExecutableSearchTests);

end.
