program InteractiveShell;

uses
  Vcl.Forms,
  MainForm in 'MainForm.pas' {frmMainForm},
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

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'VSoft.Process - Interactive Shell';
  Application.CreateForm(TfrmMainForm, frmMainForm);
  Application.Run;
end.
