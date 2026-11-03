unit MainForm;

// Minimal interactive shell demo for VSoft.Process.
//
// Hosts a hidden cmd.exe. The user types into edInput, presses Enter, the
// line is sent to cmd's stdin via IInteractivePipeSource. cmd's stdout +
// stderr stream back into lstOutput.
//
// Display: TListBox, not TMemo. TMemo wraps the Windows EDIT control and
// holds all text in a single buffer - every Delete(0) shifts the whole
// buffer (hundreds of KB once it's full), and a non-trivial trim freezes
// the UI. TListBox stores items as a pointer array; Delete(0) is a memmove
// of pointers, sub-ms even at 10K items.
//
// Cross-thread flush:
//   * Worker line callbacks Enqueue onto FPending (guarded by FPendingLock)
//     and then RequestFlush.
//   * RequestFlush uses TInterlocked.CompareExchange on FFlushPosted so
//     AT MOST ONE WM_FLUSH_LOG is in flight - N worker pushes collapse to
//     1 message.
//   * WMFlushLog drains a bounded batch, then calls Application.ProcessMessages
//     so input + paint for every window get serviced between flushes.
//     Without that yield the reposted WM_FLUSH_LOG dominates the queue and
//     starves WM_PAINT (lowest priority) - the window looks frozen.
//
// Stop: btnStop calls FProcess.Terminate synchronously. The library closes
// the interactive stdin source itself during teardown so the writer thread
// exits promptly; Terminate returns in low ms with no perceptible freeze.

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls,
  VSoft.Process;

const
  WM_FLUSH_LOG = WM_USER + 100;

type
  TfrmMainForm = class(TForm)
    lstOutput : TListBox;
    lblStatus : TLabel;
    edInput   : TEdit;
    btnSend   : TButton;
    btnStart  : TButton;
    btnStop   : TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure edInputKeyPress(Sender: TObject; var Key: Char);
  private
    FProcess     : IProcess;
    FStdIn       : IInteractivePipeSource;
    FPending     : TQueue<string>;
    FPendingLock : TCriticalSection;
    //0 = no flush queued, 1 = WM_FLUSH_LOG already posted.
    FFlushPosted : Integer;
    //Cached on FormCreate so worker threads do not touch VCL's Handle
    //property.
    FFormHandle  : HWND;
    //Thread-safe append to FPending + RequestFlush. Used by both the
    //worker callbacks and the main-thread echo of typed input.
    procedure AppendLine(const value : string);
    procedure RequestFlush;
    procedure DrainPending;
    procedure WMFlushLog(var Msg: TMessage); message WM_FLUSH_LOG;
    procedure StartProcess;
    procedure UpdateButtons;
    //IPipeTarget line callbacks - fire on the I/O worker thread.
    procedure HandleOutputLine(const line : string);
    procedure HandleErrorLine(const line : string);
    //IProcess event handlers - fire on the main thread.
    procedure HandleStarted(const sender : IProcess);
    procedure HandleExited(const sender : IProcess; exitCode : Cardinal);
  end;

var
  frmMainForm : TfrmMainForm;

implementation

{$R *.dfm}

const
  //Hard cap on lines moved from FPending to lstOutput per WM_FLUSH_LOG
  //dispatch. Keeps each dispatch quick (~ms) so other messages get
  //serviced between flushes.
  cMaxLinesPerFlush = 500;
  //Hard cap on FPending. If the producer is faster than the UI can
  //drain we drop OLDEST lines (matches what a terminal does under flood);
  //blocking the worker would back-pressure cmd's pipe and stall the child.
  cMaxPending       = 10000;
  //Soft cap on the listbox itself; over this we trim from the top.
  cMaxOutputLines   = 10000;

procedure TfrmMainForm.FormCreate(Sender: TObject);
begin
  FPending     := TQueue<string>.Create;
  FPendingLock := TCriticalSection.Create;
  FFlushPosted := 0;
  //Force window allocation on the main thread; cache for the workers.
  FFormHandle  := Handle;
  lstOutput.Clear;
  lblStatus.Caption := 'Idle - press Start to launch cmd.exe';
  UpdateButtons;
end;

procedure TfrmMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if (FProcess <> nil) and (FProcess.Status = TProcessStatus.Running) then
    FProcess.Terminate;
  CanClose := True;
end;

procedure TfrmMainForm.FormDestroy(Sender: TObject);
begin
  FStdIn := nil;
  //Destructor waits on FCompletionEvent so the worker is fully done and
  //no more callbacks can fire after this returns.
  FProcess := nil;
  FreeAndNil(FPending);
  FreeAndNil(FPendingLock);
end;

procedure TfrmMainForm.UpdateButtons;
var
  running : Boolean;
begin
  running := (FProcess <> nil) and (FProcess.Status = TProcessStatus.Running);
  btnStart.Enabled := not running;
  btnSend.Enabled  := running;
  btnStop.Enabled  := running;
  edInput.Enabled  := running;
  if running then
    ActiveControl := edInput;
end;

procedure TfrmMainForm.RequestFlush;
begin
  //Atomic test-and-set. Only the thread that flips 0 -> 1 gets to post,
  //so the message queue holds AT MOST ONE WM_FLUSH_LOG at any time. Every
  //other push within that window just buffers and returns.
  if TInterlocked.CompareExchange(FFlushPosted, 1, 0) = 0 then
    if not PostMessage(FFormHandle, WM_FLUSH_LOG, 0, 0) then
      //Window gone - reset the flag so a later post can succeed.
      TInterlocked.Exchange(FFlushPosted, 0);
end;

procedure TfrmMainForm.AppendLine(const value: string);
begin
  FPendingLock.Enter;
  try
    while FPending.Count >= cMaxPending do
      FPending.Dequeue;
    FPending.Enqueue(value);
  finally
    FPendingLock.Leave;
  end;
  RequestFlush;
end;

procedure TfrmMainForm.HandleOutputLine(const line: string);
begin
  AppendLine(line);
end;

procedure TfrmMainForm.HandleErrorLine(const line: string);
begin
  AppendLine('[stderr] ' + line);
end;

procedure TfrmMainForm.DrainPending;
var
  batch   : TStringList;
  drained : Integer;
  excess  : Integer;
begin
  batch := TStringList.Create;
  try
    FPendingLock.Enter;
    try
      drained := 0;
      while (drained < cMaxLinesPerFlush) and (FPending.Count > 0) do
      begin
        batch.Add(FPending.Dequeue);
        Inc(drained);
      end;
    finally
      FPendingLock.Leave;
    end;

    if batch.Count = 0 then
      Exit;

    lstOutput.Items.BeginUpdate;
    try
      lstOutput.Items.AddStrings(batch);
      excess := lstOutput.Items.Count - cMaxOutputLines;
      while excess > 0 do
      begin
        lstOutput.Items.Delete(0);
        Dec(excess);
      end;
    finally
      lstOutput.Items.EndUpdate;
    end;

    //Scroll the last item into view.
    if lstOutput.Items.Count > 0 then
      lstOutput.TopIndex := lstOutput.Items.Count - 1;

    //Drain other queued messages so input, hover effects, and paint on
    //ALL windows (the listbox itself plus status label, buttons, form
    //chrome) stay responsive. Under heavy flood the reposted WM_FLUSH_LOG
    //would otherwise dominate the queue indefinitely and starve WM_PAINT
    //(lowest priority). Safe to re-enter from here: FFlushPosted is still
    //1, so no other WM_FLUSH_LOG can be in the queue to dispatch.
    Application.ProcessMessages;
  finally
    batch.Free;
  end;
end;

procedure TfrmMainForm.WMFlushLog(var Msg: TMessage);
var
  hasMore : Boolean;
begin
  try
    DrainPending;
  finally
    //Reset BEFORE the hasMore check. Order matters: any worker push that
    //arrives between Exchange and the check below will see FFlushPosted=0
    //and will post its own WM_FLUSH_LOG.
    TInterlocked.Exchange(FFlushPosted, 0);
  end;

  //Lines that arrived DURING our drain whose RequestFlush call saw
  //FFlushPosted=1 and skipped the post. Re-post on their behalf.
  FPendingLock.Enter;
  try
    hasMore := FPending.Count > 0;
  finally
    FPendingLock.Leave;
  end;

  if hasMore then
    RequestFlush;
end;

procedure TfrmMainForm.HandleStarted(const sender: IProcess);
begin
  lblStatus.Caption := Format('Running (PID %d)', [sender.ProcessId]);
  UpdateButtons;
end;

procedure TfrmMainForm.HandleExited(const sender: IProcess; exitCode: Cardinal);
begin
  //Discard anything still buffered. Between btnStop and the worker
  //actually finishing, the I/O callbacks keep draining cmd's pipe
  //buffer (which can already hold thousands of lines) and queuing them
  //onto FPending. Without this clear the listbox would keep scrolling
  //for seconds after the user pressed Stop. Any WM_FLUSH_LOG that's
  //still in the message queue (at most one) will dispatch shortly,
  //find FPending empty, and return immediately.
  FPendingLock.Enter;
  try
    FPending.Clear;
  finally
    FPendingLock.Leave;
  end;

  //Echo the exit reason to the output pane so the user can see what
  //happened. lblStatus then resets to its idle text below so the form
  //matches its initial state.
  case sender.Status of
    TProcessStatus.Exited:
      lstOutput.Items.Add(Format('-- Exited (code %d) --', [exitCode]));
    TProcessStatus.Terminated:
      lstOutput.Items.Add(Format('-- Terminated (code %d) --', [exitCode]));
    TProcessStatus.TimedOut:
      lstOutput.Items.Add(Format('-- Timed out (code %d) --', [exitCode]));
  else
    lstOutput.Items.Add(Format('-- Done (status=%d code=%d) --',
                               [Ord(sender.Status), exitCode]));
  end;

  FStdIn := nil;
  FProcess := nil;
  lblStatus.Caption := 'Idle - press Start to launch cmd.exe';
  UpdateButtons;
end;

procedure TfrmMainForm.StartProcess;
var
  cmdExe : string;
begin
  cmdExe := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) +
            'System32\cmd.exe';

  FProcess := TProcess.Create;
  FProcess.StartInfo.WorkingDirectory := 'c:\';
  FProcess.StartInfo.Executable := cmdExe;
  FProcess.StartInfo.HideWindow := True;
  FProcess.StartInfo.MarshallEventsToMainThread := True;

  FStdIn := TPipeSource.Interactive;
  FProcess
    .WithStdInPipe(FStdIn)
    .WithStdOutPipe(
      TPipeTarget.ToLineMethod(HandleOutputLine, TEncoding.Default))
    .WithStdErrPipe(
      TPipeTarget.ToLineMethod(HandleErrorLine, TEncoding.Default));

  FProcess.OnStarted := HandleStarted;
  FProcess.OnExit    := HandleExited;

  if not FProcess.ExecuteAsync then
  begin
    lblStatus.Caption := 'Failed to start cmd.exe';
    FProcess := nil;
    FStdIn   := nil;
    UpdateButtons;
  end;
end;

procedure TfrmMainForm.btnStartClick(Sender: TObject);
begin
  lstOutput.Clear;
  FPendingLock.Enter;
  try
    FPending.Clear;
  finally
    FPendingLock.Leave;
  end;
  //Reset the flush flag in case a stale wakeup is still pending from a
  //previous run.
  TInterlocked.Exchange(FFlushPosted, 0);
  StartProcess;
end;

procedure TfrmMainForm.btnSendClick(Sender: TObject);
var
  line : string;
begin
  if FStdIn = nil then
    Exit;
  line := edInput.Text;
  edInput.Text := '';
  //Echo the typed line back through the same buffer so the user sees what
  //they sent, interleaved with cmd's response.
  AppendLine('> ' + line);
  //cmd reads a line at a time; CRLF on Windows.
  FStdIn.Write(line + sLineBreak);
end;

procedure TfrmMainForm.btnStopClick(Sender: TObject);
begin
  if (FProcess <> nil) and (FProcess.Status = TProcessStatus.Running) then
    FProcess.Terminate;
end;

procedure TfrmMainForm.edInputKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    btnSendClick(nil);
  end;
end;

end.
