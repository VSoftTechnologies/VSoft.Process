unit MainForm;
// Minimal interactive shell demo for VSoft.Process, FireMonkey edition.
//
// The FMX counterpart of Demos\InteractiveShell, running on Windows and
// macOS. Hosts a hidden shell (cmd.exe on Windows, /bin/sh elsewhere). The
// user types into edInput, presses Enter, the line is sent to the shell's
// stdin via IInteractivePipeSource. stdout + stderr stream back into
// lvOutput.
//
// Display: TListView, not TListBox or TMemo. An FMX TListBox creates a
// styled control per item, so 10K lines means 10K controls to lay out. A
// TMemo re-lays its whole text on every top trim. TListView items are plain
// data drawn only while visible, so adding and trimming stays cheap.
//
// Cross-thread flush:
//   * Worker line callbacks Enqueue onto FPending (guarded by FPendingLock)
//     and then RequestFlush.
//   * RequestFlush uses TInterlocked.CompareExchange on FFlushPosted so
//     AT MOST ONE FlushPending is queued - N worker pushes collapse to 1.
//     There is no window message to post on every platform, so the flush is
//     queued with TThread.ForceQueue (ForceQueue rather than Queue, as Queue
//     runs at once when called from the main thread - the echo of typed
//     input).
//   * FlushPending drains a bounded batch. When more is waiting it queues
//     itself again; CheckSynchronize only runs what was queued before it
//     started, so input and paint get serviced between flushes without the
//     VCL demo's Application.ProcessMessages.
//
// Stop: btnStop calls FProcess.Terminate synchronously. The library closes
// the interactive stdin source itself during teardown so the writer thread
// exits promptly; Terminate returns in low ms with no perceptible freeze.

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.SyncObjs, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Edit, FMX.Layouts, FMX.Controls.Presentation,
  FMX.ListView, FMX.ListView.Types, FMX.ListView.Appearances,
  FMX.ListView.Adapters.Base,
  VSoft.Process;

type
  TfrmMainForm = class(TForm)
    lvOutput   : TListView;
    layBottom  : TLayout;
    lblStatus  : TLabel;
    layInput   : TLayout;
    edInput    : TEdit;
    btnSend    : TButton;
    layButtons : TLayout;
    btnStart   : TButton;
    btnStop    : TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure edInputKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: WideChar; Shift: TShiftState);
  private
    FProcess     : IProcess;
    FStdIn       : IInteractivePipeSource;
    FPending     : TQueue<string>;
    FPendingLock : TCriticalSection;
    //0 = no flush queued, 1 = FlushPending already queued.
    FFlushPosted : Integer;
    //Thread-safe append to FPending + RequestFlush. Used by both the
    //worker callbacks and the main-thread echo of typed input.
    procedure AppendLine(const value : string);
    procedure RequestFlush;
    procedure FlushPending;
    procedure DrainPending;
    //Main thread only.
    procedure AddOutputLines(const lines : TStrings);
    procedure AddOutputLine(const line : string);
    procedure StartProcess;
    procedure UpdateButtons;
    function IdleText : string;
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

{$R *.fmx}

const
  //Hard cap on lines moved from FPending to lvOutput per FlushPending.
  //Keeps each flush quick (~ms) so other events get serviced between
  //flushes.
  cMaxLinesPerFlush = 500;
  //Hard cap on FPending. If the producer is faster than the UI can
  //drain we drop OLDEST lines (matches what a terminal does under flood);
  //blocking the worker would back-pressure the shell's pipe and stall it.
  cMaxPending       = 10000;
  //Soft cap on the list itself; over this we trim from the top.
  cMaxOutputLines   = 10000;

  {$IFDEF MSWINDOWS}
  cShellName = 'cmd.exe';
  cMonoFont  = 'Consolas';
  {$ELSE}
  cShellName = '/bin/sh';
  {$IFDEF MACOS}
  cMonoFont  = 'Menlo';
  {$ELSE}
  cMonoFont  = 'monospace';
  {$ENDIF}
  {$ENDIF}

procedure TfrmMainForm.FormCreate(Sender: TObject);
var
  text : TTextObjectAppearance;
begin
  FPending     := TQueue<string>.Create;
  FPendingLock := TCriticalSection.Create;
  FFlushPosted := 0;

  //One compact monospaced line per item, no accessory arrow, no selection.
  lvOutput.ItemAppearance.ItemHeight := 18;
  lvOutput.ItemAppearanceObjects.ItemObjects.Accessory.Visible := False;
  text := lvOutput.ItemAppearanceObjects.ItemObjects.Text;
  text.Font.Family := cMonoFont;
  text.Font.Size   := 12;
  text.WordWrap    := False;
  text.Trimming    := TTextTrimming.None;
  lvOutput.AllowSelection := False;

  btnStart.Text := 'Start ' + ExtractFileName(cShellName);
  lvOutput.Items.Clear;
  lblStatus.Text := IdleText;
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
  //A flush queued before that must not run against a freed form.
  TThread.RemoveQueuedEvents(FlushPending);
  FreeAndNil(FPending);
  FreeAndNil(FPendingLock);
end;

function TfrmMainForm.IdleText : string;
begin
  result := 'Idle - press Start to launch ' + cShellName;
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
    edInput.SetFocus;
end;

procedure TfrmMainForm.RequestFlush;
begin
  //Atomic test-and-set. Only the thread that flips 0 -> 1 gets to queue,
  //so the queue holds AT MOST ONE FlushPending at any time. Every other
  //push within that window just buffers and returns.
  if TInterlocked.CompareExchange(FFlushPosted, 1, 0) = 0 then
    TThread.ForceQueue(nil, FlushPending);
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

procedure TfrmMainForm.AddOutputLines(const lines: TStrings);
var
  i      : Integer;
  excess : Integer;
begin
  lvOutput.BeginUpdate;
  try
    for i := 0 to lines.Count - 1 do
      lvOutput.Items.Add.Text := lines[i];
    excess := lvOutput.Items.Count - cMaxOutputLines;
    while excess > 0 do
    begin
      lvOutput.Items.Delete(0);
      Dec(excess);
    end;
  finally
    lvOutput.EndUpdate;
  end;
  //Scroll the last item into view.
  if lvOutput.Items.Count > 0 then
    lvOutput.ScrollTo(lvOutput.Items.Count - 1);
end;

procedure TfrmMainForm.AddOutputLine(const line: string);
var
  lines : TStringList;
begin
  lines := TStringList.Create;
  try
    lines.Add(line);
    AddOutputLines(lines);
  finally
    lines.Free;
  end;
end;

procedure TfrmMainForm.DrainPending;
var
  batch   : TStringList;
  drained : Integer;
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
    if batch.Count > 0 then
      AddOutputLines(batch);
  finally
    batch.Free;
  end;
end;

procedure TfrmMainForm.FlushPending;
var
  hasMore : Boolean;
begin
  try
    DrainPending;
  finally
    //Reset BEFORE the hasMore check. Order matters: any worker push that
    //arrives between Exchange and the check below will see FFlushPosted=0
    //and will queue its own FlushPending.
    TInterlocked.Exchange(FFlushPosted, 0);
  end;

  //Lines left over by the batch cap, or that arrived DURING our drain
  //whose RequestFlush call saw FFlushPosted=1 and skipped the queue.
  //Queue again on their behalf.
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
  lblStatus.Text := Format('Running %s (PID %d)', [cShellName, sender.ProcessId]);
  UpdateButtons;
end;

procedure TfrmMainForm.HandleExited(const sender: IProcess; exitCode: Cardinal);
begin
  //Discard anything still buffered. Between btnStop and the worker
  //actually finishing, the I/O callbacks keep draining the shell's pipe
  //buffer (which can already hold thousands of lines) and queuing them
  //onto FPending. Without this clear the list would keep scrolling for
  //seconds after the user pressed Stop. A FlushPending that's still
  //queued (at most one) will run shortly, find FPending empty, and return
  //immediately.
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
      AddOutputLine(Format('-- Exited (code %d) --', [exitCode]));
    TProcessStatus.Terminated:
      AddOutputLine(Format('-- Terminated (code %d) --', [exitCode]));
    TProcessStatus.TimedOut:
      AddOutputLine(Format('-- Timed out (code %d) --', [exitCode]));
  else
    AddOutputLine(Format('-- Done (status=%d code=%d) --',
                         [Ord(sender.Status), exitCode]));
  end;

  FStdIn := nil;
  FProcess := nil;
  lblStatus.Text := IdleText;
  UpdateButtons;
end;

procedure TfrmMainForm.StartProcess;
begin
  FProcess := TProcess.Create;
  {$IFDEF MSWINDOWS}
  FProcess.StartInfo.WorkingDirectory :=
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemDrive'));
  FProcess.StartInfo.Executable :=
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) +
    'System32\cmd.exe';
  {$ELSE}
  //sh reads commands from a pipe without printing a prompt; output and
  //errors still come back line by line.
  FProcess.StartInfo.WorkingDirectory := GetEnvironmentVariable('HOME');
  FProcess.StartInfo.Executable := cShellName;
  {$ENDIF}
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
    lblStatus.Text := 'Failed to start ' + cShellName;
    FProcess := nil;
    FStdIn   := nil;
    UpdateButtons;
  end;
end;

procedure TfrmMainForm.btnStartClick(Sender: TObject);
begin
  lvOutput.Items.Clear;
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
  //they sent, interleaved with the shell's response.
  AppendLine('> ' + line);
  //The shell reads a line at a time; sLineBreak is CRLF on Windows, LF
  //elsewhere.
  FStdIn.Write(line + sLineBreak);
end;

procedure TfrmMainForm.btnStopClick(Sender: TObject);
begin
  if (FProcess <> nil) and (FProcess.Status = TProcessStatus.Running) then
    FProcess.Terminate;
end;

procedure TfrmMainForm.edInputKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    btnSendClick(nil);
  end;
end;

end.
