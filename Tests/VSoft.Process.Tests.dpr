program VSoft.Process.Tests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  {$IFDEF MSWINDOWS}
  WinApi.Windows,
  {$ENDIF }
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  VSoft.Process in '..\Source\VSoft.Process.pas',
  VSoft.Process.Base in '..\Source\VSoft.Process.Base.pas',
  VSoft.Process.CommandLine in '..\Source\VSoft.Process.CommandLine.pas',
  VSoft.Process.Credentials in '..\Source\VSoft.Process.Credentials.pas',
  VSoft.Process.Environment in '..\Source\VSoft.Process.Environment.pas',
  VSoft.Process.PipeSource.Classes in '..\Source\VSoft.Process.PipeSource.Classes.pas',
  VSoft.Process.PipeTarget.Classes in '..\Source\VSoft.Process.PipeTarget.Classes.pas',
  VSoft.Process.StartInfo in '..\Source\VSoft.Process.StartInfo.pas',
  VSoft.Process.Utils in '..\Source\VSoft.Process.Utils.pas',
  {$IFDEF MSWINDOWS}
  VSoft.Process.Windows in '..\Source\VSoft.Process.Windows.pas',
  {$ENDIF }
  {$IF DEFINED(LINUX) OR DEFINED(MACOS)}
  VSoft.Process.Posix in '..\Source\VSoft.Process.Posix.pas',
  {$IFEND }
  VSoft.Process.Tests.PipeTarget in 'VSoft.Process.Tests.PipeTarget.pas',
  VSoft.Process.Tests.PipeSource in 'VSoft.Process.Tests.PipeSource.pas',
  VSoft.Process.Tests.CommandLine in 'VSoft.Process.Tests.CommandLine.pas',
  VSoft.Process.Tests.Environment in 'VSoft.Process.Tests.Environment.pas',
  VSoft.Process.Tests.StartInfo in 'VSoft.Process.Tests.StartInfo.pas',
  VSoft.Process.Tests.Credentials in 'VSoft.Process.Tests.Credentials.pas',
  VSoft.Process.Tests.Utils in 'VSoft.Process.Tests.Utils.pas',
  VSoft.Process.Tests.Process in 'VSoft.Process.Tests.Process.pas',
  VSoft.Process.Tests.ProcessE2E in 'VSoft.Process.Tests.ProcessE2E.pas',
  VSoft.Process.Tests.Common in 'VSoft.Process.Tests.Common.pas',
  VSoft.Process.Tests.Lifecycle in 'VSoft.Process.Tests.Lifecycle.pas',
  VSoft.Process.Tests.Lifetime in 'VSoft.Process.Tests.Lifetime.pas',
  VSoft.Process.Tests.ExecutableSearch in 'VSoft.Process.Tests.ExecutableSearch.pas',
  VSoft.Process.Tests.Logon in 'VSoft.Process.Tests.Logon.pas',
  VSoft.Process.Tests.Helper in 'VSoft.Process.Tests.Helper.pas',
  VSoft.Process.Tests.Review.Windows in 'VSoft.Process.Tests.Review.Windows.pas',
  VSoft.Process.Tests.Review.Posix in 'VSoft.Process.Tests.Review.Posix.pas',
  VSoft.Process.Tests.Review.Core in 'VSoft.Process.Tests.Review.Core.pas',
  VSoft.Process.Tests.Review.Pipes in 'VSoft.Process.Tests.Review.Pipes.pas',
  VSoft.Process.Tests.Review.Support in 'VSoft.Process.Tests.Review.Support.pas',
  VSoft.Process.WinAPI in '..\Source\VSoft.Process.WinAPI.pas';

{$R *.RES}

var
  runner : ITestRunner;
  results : IRunResults;
  logger : ITestLogger;
  nunitLogger : ITestLogger;
begin
  // Started by a test as a child process to do one job (see the unit).
  if RunTestHelperMode then
    Exit;
  ReportMemoryLeaksOnShutdown := True;
  try
    // Pull --teamcity, --xml, etc. out of the command line.
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.FailsOnNoAsserts := False;
    
    // Console logger so failures are visible in the test output.
    logger := TDUnitXConsoleLogger.Create(false);
    runner.AddLogger(logger);

    // NUnit XML so CI systems can ingest results.
    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;
    if not results.AllPassed then
      ExitCode := 1;

    {$IFDEF MSWINDOWS}
    // When launched from the IDE, give the user a chance to read the output.
    if (DebugHook <> 0) and IsConsole then
    begin
      System.Write('Press any key to exit . . . ');
      ReadLn;
    end;
    {$ENDIF}
  except
    on E : Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
