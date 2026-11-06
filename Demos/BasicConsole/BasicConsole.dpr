// JCL_DEBUG_EXPERT_GENERATEJDBG OFF
// JCL_DEBUG_EXPERT_INSERTJDBG OFF
program BasicConsole;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  WinApi.Windows,
  VSoft.Process in '..\..\Source\VSoft.Process.pas',
  VSoft.Process.StartInfo in '..\..\Source\VSoft.Process.StartInfo.pas',
  VSoft.Process.Environment in '..\..\Source\VSoft.Process.Environment.pas',
  VSoft.Process.Windows in '..\..\Source\VSoft.Process.Windows.pas',
  VSoft.Process.CommandLine in '..\..\Source\VSoft.Process.CommandLine.pas',
  VSoft.Process.Utils in '..\..\Source\VSoft.Process.Utils.pas',
  VSoft.Process.Credentials in '..\..\Source\VSoft.Process.Credentials.pas',
  VSoft.Process.PipeTarget.Classes in '..\..\Source\VSoft.Process.PipeTarget.Classes.pas',
  VSoft.Process.PipeSource.Classes in '..\..\Source\VSoft.Process.PipeSource.Classes.pas',
  VSoft.Process.Base in '..\..\Source\VSoft.Process.Base.pas',
  VSoft.Process.WinAPI in '..\..\Source\VSoft.Process.WinAPI.pas';

var
  process : IProcess;


procedure StdOutput(const line : string );
begin
  WriteLn(line);
end;

// The console Ctrl handler must be a plain top-level routine: a nested one
// takes a hidden parent-frame parameter, so Windows' single argument would
// not arrive as CtrlType.
function ConProc(CtrlType : DWORD) : BOOL; stdcall;
begin
 Result := True;
 case CtrlType of
   CTRL_C_EVENT        : process.Terminate ;
   CTRL_BREAK_EVENT    : ;
   CTRL_CLOSE_EVENT    : ;
   CTRL_SHUTDOWN_EVENT : ;
 end;
end;

procedure RunTest;
var
  stopwatch : TStopWatch;
  sBuilder : TStringBuilder;
begin
  SetConsoleCtrlHandler(@ConProc, True);
  stopwatch := TStopWatch.Create;
  process := TProcess.Create;
  process.StartInfo.Executable := 'c:\Windows\System32\cmd.exe';
  process.StartInfo.WorkingDirectory := 'c:\windows';
  process.StartInfo.HideWindow := true;
  process.CommandLine.Add('/c');
//  process.StartInfo.TimeoutInMSec := 500;
//  process.CommandLine.Add('"set start=!time! && dir C:\Windows﻿ /s && set end=!time! && echo Start time: !start! && echo End time: !end!"');
  process.CommandLine.Add('dir c:\windows /s');

  sBuilder := TStringBuilder.Create(32768);
//  process.WithStdOutPipe(TPipeTarget.ToStringBuilder(sBuilder));

  process.WithStdOutPipe(TPipeTarget.ToLineProcedure(StdOutput));

  WriteLn('Press Enter to start the process. Press Enter again to terminate');
  ReadLn;
  stopwatch.Start;
//  process.ExecuteAsync();
  process.Execute(nil);
//  while process.Status = TProcessStatus.Running do
//    TThread.Yield;
//  if process.Status = TProcessStatus.Running then
//    process.Terminate;
  stopwatch.Stop;
//  writeLn(sbuilder.ToString);                                                                                                            //

  WriteLn;
  WriteLn('Exit code : ' + IntToStr(process.ExitCode) + ' time (ms) ' + IntToStr(stopwatch.ElapsedMilliseconds) );


  //doscommand doesn't have a synchronous mode or a way to wait on it.
//  var demo := TDemo.Create;
//  stopwatch := TStopwatch.StartNew;
//  demo.Execute;
//  stopwatch.Stop;
//  WriteLn('Exit code : ' + IntToStr(demo.ExitCode) + ' time (ms) ' + IntToStr(stopwatch.ElapsedMilliseconds) );
  ReadLn;
  sBuilder.Free;
end;


begin
  try
    RunTest;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
