unit VSoft.Process.Tests.Review.Pipes;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process,
  VSoft.Process.PipeTarget.Classes;

type
  // Tests for the findings PIPE-1 to PIPE-10 of docs\CODE_REVIEW_2026-11-10.md
  // ("Pipe targets and sources"). Every test asserts the correct behaviour,
  // so a test that fails confirms its finding and passes once the library is
  // fixed. PIPE-4 (README wording) has no test here: the behaviour, including
  // Done raising the child's exception, is already pinned by
  // TPipeTargetTests.MultiTarget_RaisingChild_SiblingsKeepReceiving.
  [TestFixture]
  TReviewPipesTests = class
  private
    function FeedLines(const encoding : TEncoding; const chunks : array of TBytes) : string;
    function FeedStringBuilder(const encoding : TEncoding; const chunks : array of TBytes) : string;
    // Feeds the encoded text to a fresh StringBuilder target split in two at
    // every byte position and returns the split points that corrupted it.
    function FailingSplitPoints(codePage : integer; const text : string) : string;
    function TimeStringBuilderFeed(const encoding : TEncoding; megabytes : integer) : Double;
    // Time spent finding the last character boundary of each 64 KB read, and
    // decoding it, for megabytes of ASCII in the given code page.
    procedure TimeScanAndDecode(codePage : integer; megabytes : integer; out scanMs : Double; out decodeMs : Double);
    procedure CheckChildReadsFileOpenForWriting(asStdInFile : boolean);
  public
    // PIPE-1. Only fails when the LIBRARY unit is compiled with range
    // checking ($R+, e.g. dcc32 -$R+ or DCC_RangeChecking in the dproj): the
    // forced line break then raises ERangeError instead of emitting the line.
    // Passing in a build without range checking does not disprove the finding.
    [Test]
    procedure PIPE1_ForcedLineBreak_WholeBufferDecodable_NoRangeError;

    // PIPE-2. A failure means the file target started before the failing
    // sibling was never given its Done: the file is still open and locked.
    [Test]
    procedure PIPE2_ToAll_ChildStartRaises_EarlierFileTargetIsClosed;
    // PIPE-2. A failure means the leaked start count turned ToFile(name,
    // False) into append mode for the following runs.
    [Test]
    procedure PIPE2_ToAll_ChildStartRaised_LaterRunStillTruncatesTheFile;
    // PIPE-2 through a process: a failure means Execute raised (as it should)
    // but left the first file locked for as long as the process lives.
    [Test]
    procedure PIPE2_ToAll_ChildStartRaises_ExecuteLeavesNoFileLocked;

    // PIPE-3. A failure means text written by cmd.exe was decoded with a code
    // page other than the one the child's console writes in. Can only fail on
    // a machine whose ANSI code page differs from the console (OEM) code
    // page; otherwise it passes with a message saying so.
    [Test]
    procedure PIPE3_DefaultEncoding_CmdEchoNonAscii_RoundTrips;
    // PIPE-3, the premise only: cmd.exe writes redirected echo output in the
    // console code page whatever the ANSI code page is. A failure means the
    // premise of the finding does not hold on this machine.
    [Test]
    procedure PIPE3_Premise_CmdEchoWritesConsoleCodePageBytes;

    // PIPE-5. A failure means a line callback that raised was called again
    // from Done although the target had faulted.
    [Test]
    procedure PIPE5_LineCallbackRaised_DoneDoesNotCallItAgain;
    // PIPE-5. A failure means Done delivered a line the child never wrote
    // (the failed line glued to the unterminated tail).
    [Test]
    procedure PIPE5_LineCallbackRaised_NoLineTheChildNeverWrote;
    // PIPE-5. A failure means a callback raising again from Done made Done
    // skip forgetting the injected encoding, so the next run decodes with the
    // previous run's StartInfo.OutputEncoding object.
    [Test]
    procedure PIPE5_LineCallbackRaisesAgainInDone_InjectedEncodingForgotten;

    // PIPE-6. A failure means the byte order mark is delivered as U+FEFF at
    // the start of the first line / the captured text.
    [Test]
    procedure PIPE6_LineTarget_Utf8Bom_NotPartOfFirstLine;
    [Test]
    procedure PIPE6_LineTarget_Utf16LEBom_NotPartOfFirstLine;
    [Test]
    procedure PIPE6_StringBuilderTarget_Utf8Bom_NotInText;

    // PIPE-7. A failure means a GB18030 character cut by a read boundary was
    // decoded as two broken halves.
    [Test]
    procedure PIPE7_StringBuilderTarget_Gb18030_EverySplitPoint;
    // PIPE-7 control: two-byte DBCS (Shift-JIS) is handled on Windows today,
    // so this should pass; it pins the path the finding says is correct.
    [Test]
    procedure PIPE7_StringBuilderTarget_ShiftJis_EverySplitPoint;

    // PIPE-8. Timing: a failure means that for a DBCS code page, finding
    // where the last whole character of each read ends (the per-byte
    // IsDBCSLeadByteEx walk) costs more than twice what decoding the read
    // costs. The numbers, and UTF-8 for comparison, are logged either way.
    [Test]
    procedure PIPE8_DbcsCodePage_FindingCharBoundary_NotDearerThanDecoding;

    // PIPE-9. A failure means a file another handle has open for writing
    // cannot be used as stdin (sharing violation from Start).
    [Test]
    procedure PIPE9_FromFile_FileOpenForWritingElsewhere_StartSucceeds;
    [Test]
    procedure PIPE9_FileAsStdIn_FileOpenForWritingElsewhere_StartSucceeds;
    [Test]
    procedure PIPE9_FromFile_FileOpenForWritingElsewhere_ChildReadsIt;
    [Test]
    procedure PIPE9_FileAsStdIn_FileOpenForWritingElsewhere_ChildReadsIt;

    // PIPE-10. A failure means a delegate that uses the IProcess keeps the
    // process alive after the last outside reference is gone.
    [Test]
    procedure PIPE10_LineDelegateCapturingProcess_ProcessStillReleased;
    // PIPE-10 with a child: a failure means the program the child left
    // running was not killed (JobMode KillOnRelease) because the release
    // never happened.
    [Test]
    procedure PIPE10_LineDelegateCapturingProcess_KillOnReleaseStillKillsLeftovers;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.Diagnostics,
  System.TimeSpan,
  VSoft.Process.Tests.Common;

const
  cReleaseLine = '##release##';

type
  EReviewSinkError = class(Exception);

  TLineSink = class
  private
    FLines : TStringList;
    FRaiseOnFirstLine : boolean;
    FRaiseAlways : boolean;
  public
    constructor Create;
    destructor Destroy;override;
    procedure OnLine(const line : string);
    function Joined : string;
    property Lines : TStringList read FLines;
    property RaiseOnFirstLine : boolean read FRaiseOnFirstLine write FRaiseOnFirstLine;
    property RaiseAlways : boolean read FRaiseAlways write FRaiseAlways;
  end;

  TStartRaisesTarget = class(TInterfacedObject, IPipeTarget)
  private
    FRaiseOnStart : boolean;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  public
    constructor Create;
    property RaiseOnStart : boolean read FRaiseOnStart write FRaiseOnStart;
  end;

  TDestroyFlagTarget = class(TInterfacedObject, IPipeTarget)
  private
    FFlag : PBoolean;
  protected
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  public
    constructor Create(flag : PBoolean);
    destructor Destroy;override;
  end;

{ TLineSink }

constructor TLineSink.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
end;

destructor TLineSink.Destroy;
begin
  FLines.Free;
  inherited;
end;

procedure TLineSink.OnLine(const line : string);
begin
  FLines.Add(line);
  if FRaiseAlways or (FRaiseOnFirstLine and (FLines.Count = 1)) then
    raise EReviewSinkError.Create('boom');
end;

function TLineSink.Joined : string;
var
  i : integer;
begin
  result := '';
  for i := 0 to FLines.Count - 1 do
  begin
    if i > 0 then
      result := result + '|';
    result := result + FLines[i];
  end;
end;

{ TStartRaisesTarget }

constructor TStartRaisesTarget.Create;
begin
  inherited Create;
  FRaiseOnStart := true;
end;

procedure TStartRaisesTarget.Start;
begin
  if FRaiseOnStart then
    raise EInOutError.Create('cannot start');
end;

procedure TStartRaisesTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TStartRaisesTarget.Done;
begin
end;

{ TDestroyFlagTarget }

constructor TDestroyFlagTarget.Create(flag : PBoolean);
begin
  inherited Create;
  FFlag := flag;
end;

destructor TDestroyFlagTarget.Destroy;
begin
  FFlag^ := true;
  inherited;
end;

procedure TDestroyFlagTarget.Start;
begin
end;

procedure TDestroyFlagTarget.HandleData(const data : TBytes; dataLength : NativeUInt);
begin
end;

procedure TDestroyFlagTarget.Done;
begin
end;

{ helpers }

procedure LogInfo(const msg : string);
begin
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, msg);
end;

// Printable ASCII is kept, everything else becomes \uXXXX, so a failure
// message shows U+FEFF / U+FFFD whatever the console code page is.
function Escaped(const value : string) : string;
var
  i : integer;
begin
  result := '';
  for i := 1 to Length(value) do
  begin
    if (Ord(value[i]) >= 32) and (Ord(value[i]) <= 126) then
      result := result + value[i]
    else
      result := result + '\u' + IntToHex(Ord(value[i]), 4);
  end;
end;

function HexOf(const bytes : TBytes) : string;
var
  i : integer;
begin
  result := '';
  for i := 0 to High(bytes) do
  begin
    if i > 0 then
      result := result + ' ';
    result := result + IntToHex(bytes[i], 2);
  end;
end;

function BytesOf(const values : array of Byte) : TBytes;
var
  i : integer;
begin
  SetLength(result, Length(values));
  for i := 0 to High(values) do
    result[i] := values[i];
end;

function Concat2(const first : TBytes; const second : TBytes) : TBytes;
begin
  SetLength(result, Length(first) + Length(second));
  if Length(first) > 0 then
    Move(first[0], result[0], Length(first));
  if Length(second) > 0 then
    Move(second[0], result[Length(first)], Length(second));
end;

procedure WriteFileBytes(const fileName : string; const bytes : TBytes);
var
  fs : TFileStream;
begin
  fs := TFileStream.Create(fileName, fmCreate);
  try
    if Length(bytes) > 0 then
      fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

procedure RemoveFile(const fileName : string);
begin
  if fileName <> '' then
    System.SysUtils.DeleteFile(fileName);
end;

function CanOpenExclusive(const fileName : string) : boolean;
var
  probe : TFileStream;
begin
  try
    probe := TFileStream.Create(fileName, fmOpenReadWrite or fmShareExclusive);
    probe.Free;
    result := true;
  except
    on EFOpenError do
      result := false;
  end;
end;

// In a routine of its own so that no hidden temporary of the caller keeps the
// file target (and its open file) alive after the ToAll target is released.
function FileThenTarget(const fileName : string; const second : IPipeTarget) : IPipeTarget;
begin
  result := TPipeTarget.ToAll([TPipeTarget.ToFile(fileName), second]);
end;

procedure SendLine(const target : IPipeTarget; const line : string);
var
  bytes : TBytes;
begin
  bytes := TEncoding.UTF8.GetBytes(line + #10);
  target.HandleData(bytes, Length(bytes));
end;

// The cycle of PIPE-10: the delegate uses the local proc, so the frame it
// shares with this routine holds the process, which holds the target, which
// holds the delegate. breaker is that target: sending it cReleaseLine makes
// the delegate drop the frame's reference, which is the only way to free the
// process again. The sentinel on stderr sets flag^ when the process frees
// its targets. With runLeftoverChild the process also runs a child that
// leaves a program running; watch is a handle on that program.
procedure BuildProcessCapturedByItsDelegate(flag : PBoolean; runLeftoverChild : boolean; out breaker : IPipeTarget; out watch : NativeUInt);
var
  proc : IProcess;
  lineDelegate : TPipeTargetLineDelegate;
  sentinel : IPipeTarget;
  pid : Cardinal;
begin
  breaker := nil;
  watch := 0;
  proc := TProcess.Create;
  sentinel := TDestroyFlagTarget.Create(flag);
  proc.WithStdErrPipe(sentinel);
  sentinel := nil;
  lineDelegate :=
    procedure(const line : string)
    begin
      if line = cReleaseLine then
        proc := nil
      else if Pos('fatal', line) > 0 then
        proc.Terminate;
    end;
  breaker := TPipeTarget.ToLineDelegate(lineDelegate, TEncoding.UTF8);
  lineDelegate := nil;
  proc.WithStdOutPipe(breaker);
  if not runLeftoverChild then
  begin
    // The documented way to break the cycle. breaker goes too: it holds the
    // delegate, and through it the process.
    proc.ClearPipes;
    breaker := nil;
    exit;
  end;
  {$IFDEF MSWINDOWS}
  proc.StartInfo.JobMode := TProcessJobMode.KillOnRelease;
  proc.StartInfo.TimeoutInMSec := 30000;
  // The program left running inherits the pipes and keeps them open.
  proc.StartInfo.PipeDrainTimeoutMS := 300;
  TTestHelpers.SetupShellCommand(proc, 'spawn-background-and-exit', ['30']);
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  pid := TTestHelpers.FindChildProcess(proc.ProcessId, 'ping.exe');
  Assert.IsTrue(pid <> 0, 'the program the child started in the background was not found');
  watch := TTestHelpers.WatchProcess(pid);
  Assert.IsTrue(watch <> 0, 'could not open the program the child started in the background');
  {$ENDIF}
  proc.ClearPipes;
  breaker := nil;
end;

{$IFDEF MSWINDOWS}
// Runs `cmd /c <command>` and returns the bytes it wrote to stdout. decoded,
// when given, receives the same output through a ToStringBuilder target with
// the given encoding (nil = the library default).
function RunCmdCapture(const command : string; const decoded : TStringBuilder; const encoding : TEncoding) : TBytes;
var
  proc : IProcess;
  stream : TMemoryStream;
begin
  SetLength(result, 0);
  stream := TMemoryStream.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupInlineCommand(proc, command, command);
    proc.WithStdOutPipe(TPipeTarget.ToStream(stream));
    if decoded <> nil then
      proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(decoded, encoding));
    Assert.IsTrue(proc.Execute, proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, 'the child did not exit by itself: ' + proc.Errors.Text);
    SetLength(result, stream.Size);
    if stream.Size > 0 then
    begin
      stream.Position := 0;
      stream.ReadBuffer(result[0], stream.Size);
    end;
  finally
    proc := nil;
    stream.Free;
  end;
end;

// The output code page of the console a child is given: the number `chcp`
// prints (the text around it is localised).
function ChildConsoleCodePage : integer;
var
  raw : TBytes;
  i : integer;
  digits : string;
begin
  raw := RunCmdCapture('chcp', nil, nil);
  digits := '';
  i := High(raw);
  while (i >= 0) and not (raw[i] in [Ord('0')..Ord('9')]) do
    Dec(i);
  while (i >= 0) and (raw[i] in [Ord('0')..Ord('9')]) do
  begin
    digits := Char(raw[i]) + digits;
    Dec(i);
  end;
  result := StrToIntDef(digits, 0);
end;
{$ENDIF}

{ TReviewPipesTests }

function TReviewPipesTests.FeedLines(const encoding : TEncoding; const chunks : array of TBytes) : string;
var
  target : IPipeTarget;
  sink : TLineSink;
  i : integer;
begin
  sink := TLineSink.Create;
  try
    target := TPipeTarget.ToLineMethod(sink.OnLine, encoding);
    target.Start;
    for i := 0 to High(chunks) do
      target.HandleData(chunks[i], Length(chunks[i]));
    target.Done;
    target := nil;
    result := sink.Joined;
  finally
    sink.Free;
  end;
end;

function TReviewPipesTests.FeedStringBuilder(const encoding : TEncoding; const chunks : array of TBytes) : string;
var
  target : IPipeTarget;
  sb : TStringBuilder;
  i : integer;
begin
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, encoding);
    target.Start;
    for i := 0 to High(chunks) do
      target.HandleData(chunks[i], Length(chunks[i]));
    target.Done;
    target := nil;
    result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TReviewPipesTests.FailingSplitPoints(codePage : integer; const text : string) : string;
var
  encoding : TEncoding;
  full : TBytes;
  actual : string;
  splitAt : integer;
begin
  result := '';
  encoding := TEncoding.GetEncoding(codePage);
  try
    full := encoding.GetBytes(text);
    Assert.AreEqual(Escaped(text), Escaped(FeedStringBuilder(encoding, [full])),
      'Precondition: the text must round-trip through code page ' + IntToStr(codePage) + ' in one read (bytes ' + HexOf(full) + ')');
    for splitAt := 1 to Length(full) - 1 do
    begin
      actual := FeedStringBuilder(encoding, [Copy(full, 0, splitAt), Copy(full, splitAt, Length(full) - splitAt)]);
      if actual <> text then
      begin
        if result <> '' then
          result := result + '; ';
        result := result + 'split at byte ' + IntToStr(splitAt) + ' of ' + IntToStr(Length(full)) + ' gave "' + Escaped(actual) + '"';
      end;
    end;
    if result <> '' then
      result := 'bytes ' + HexOf(full) + ': ' + result;
  finally
    encoding.Free;
  end;
end;

function TReviewPipesTests.TimeStringBuilderFeed(const encoding : TEncoding; megabytes : integer) : Double;
const
  cChunk = 64 * 1024;
var
  target : IPipeTarget;
  sb : TStringBuilder;
  chunk : TBytes;
  watch : TStopwatch;
  megabyte : integer;
  i : integer;
begin
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, encoding);
    SetLength(chunk, cChunk);
    FillChar(chunk[0], cChunk, Ord('x'));
    watch := TStopwatch.StartNew;
    // Start clears the builder, so memory stays at 1 MB of text.
    for megabyte := 1 to megabytes do
    begin
      target.Start;
      for i := 1 to (1024 * 1024) div cChunk do
        target.HandleData(chunk, cChunk);
      target.Done;
    end;
    watch.Stop;
    result := watch.Elapsed.TotalMilliseconds;
    target := nil;
  finally
    sb.Free;
  end;
end;

procedure TReviewPipesTests.TimeScanAndDecode(codePage : integer; megabytes : integer; out scanMs : Double; out decodeMs : Double);
const
  cChunk = 64 * 1024;
var
  encoding : TEncoding;
  chunk : TBytes;
  watch : TStopwatch;
  i : integer;
  total : integer;
begin
  encoding := TEncoding.GetEncoding(codePage);
  try
    SetLength(chunk, cChunk);
    FillChar(chunk[0], cChunk, Ord('x'));
    total := 0;
    watch := TStopwatch.StartNew;
    for i := 1 to megabytes * ((1024 * 1024) div cChunk) do
      Inc(total, CompleteCharLength(encoding, chunk, cChunk) div cChunk);
    watch.Stop;
    scanMs := watch.Elapsed.TotalMilliseconds;
    watch := TStopwatch.StartNew;
    for i := 1 to megabytes * ((1024 * 1024) div cChunk) do
      Inc(total, Length(DecodeLenient(encoding, chunk, 0, cChunk)) div cChunk);
    watch.Stop;
    decodeMs := watch.Elapsed.TotalMilliseconds;
    Assert.AreEqual(2 * megabytes * ((1024 * 1024) div cChunk), total, 'Precondition: every read is complete and decodes to as many characters');
  finally
    encoding.Free;
  end;
end;

procedure TReviewPipesTests.PIPE1_ForcedLineBreak_WholeBufferDecodable_NoRangeError;
const
  cChunk = 64 * 1024;
var
  target : IPipeTarget;
  sink : TLineSink;
  chunk : TBytes;
  i : integer;
  raisedText : string;
begin
  {$IFOPT R+}
  LogInfo('PIPE-1: this test unit is compiled with range checking on');
  {$ELSE}
  LogInfo('PIPE-1: this test unit is compiled with range checking OFF - if the library unit is too, the fault cannot show');
  {$ENDIF}
  sink := TLineSink.Create;
  try
    target := TPipeTarget.ToLineMethod(sink.OnLine, TEncoding.UTF8);
    target.Start;
    SetLength(chunk, cChunk);
    FillChar(chunk[0], cChunk, Ord('x'));
    raisedText := '';
    try
      // Exactly cMaxPendingLineBytes of complete characters with no LF and no
      // trailing CR: the whole buffer is decodable at the forced break.
      for i := 1 to cMaxPendingLineBytes div cChunk do
        target.HandleData(chunk, cChunk);
    except
      on e : Exception do
        raisedText := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raisedText, 'HandleData raised at the 1 MB forced line break');
    Assert.AreEqual(1, sink.Lines.Count, 'The capped text should have been emitted as a line');
    Assert.AreEqual(cMaxPendingLineBytes, Length(sink.Lines[0]));
    target.Done;
    Assert.AreEqual(1, sink.Lines.Count, 'Nothing was left to flush');
  finally
    target := nil;
    sink.Free;
  end;
end;

procedure TReviewPipesTests.PIPE2_ToAll_ChildStartRaises_EarlierFileTargetIsClosed;
var
  multi : IPipeTarget;
  raiserRef : IPipeTarget;
  fileName : string;
  raised : boolean;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe2_', '.log');
  try
    raiserRef := TStartRaisesTarget.Create;
    multi := FileThenTarget(fileName, raiserRef);
    raised := false;
    try
      multi.Start;
    except
      on EInOutError do
        raised := true;
    end;
    Assert.IsTrue(raised, 'The child''s Start exception should propagate');
    Assert.IsTrue(FileExists(fileName), 'Precondition: the file target was started before the failing one');
    Assert.IsTrue(CanOpenExclusive(fileName),
      'The file target started before the failing sibling still holds its file open (it never got Done)');
  finally
    multi := nil;
    RemoveFile(fileName);
  end;
end;

procedure TReviewPipesTests.PIPE2_ToAll_ChildStartRaised_LaterRunStillTruncatesTheFile;
var
  multi : IPipeTarget;
  raiser : TStartRaisesTarget;
  raiserRef : IPipeTarget;
  fileName : string;
  raised : boolean;
  payload : TBytes;
  content : string;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe2_', '.log');
  try
    raiser := TStartRaisesTarget.Create;
    raiserRef := raiser;
    multi := FileThenTarget(fileName, raiserRef);
    raised := false;
    try
      multi.Start;
    except
      on EInOutError do
        raised := true;
    end;
    Assert.IsTrue(raised, 'The child''s Start exception should propagate');

    // The cause of the failure is gone: two normal runs follow.
    raiser.RaiseOnStart := false;
    payload := TEncoding.ASCII.GetBytes('one');
    multi.Start;
    multi.HandleData(payload, Length(payload));
    multi.Done;
    payload := TEncoding.ASCII.GetBytes('two');
    multi.Start;
    multi.HandleData(payload, Length(payload));
    multi.Done;

    // Released first, so the file can be read whatever state it was left in.
    multi := nil;
    content := TEncoding.ASCII.GetString(TTestHelpers.ReadFileBytes(fileName));
    Assert.AreEqual('two', content, 'ToFile(name, False) must truncate the file at the start of every run');
  finally
    multi := nil;
    raiserRef := nil;
    RemoveFile(fileName);
  end;
end;

// In a routine of its own: the hidden temporary for the result of the fluent
// WithStdOutPipe keeps the process (and so the open file) alive until the
// routine returns, and the caller deletes the file after that.
procedure CheckFailedExecuteLeavesNoFileLocked(const fileName : string);
var
  proc : IProcess;
  multi : IPipeTarget;
  raiserRef : IPipeTarget;
  raisedText : string;
begin
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 30000;
  TTestHelpers.SetupInlineCommand(proc, 'echo hello', 'echo hello');
  raiserRef := TStartRaisesTarget.Create;
  multi := FileThenTarget(fileName, raiserRef);
  proc.WithStdOutPipe(multi);
  // From here only the process holds the targets.
  multi := nil;
  raisedText := '';
  try
    proc.Execute;
  except
    on e : Exception do
      raisedText := e.ClassName;
  end;
  Assert.AreEqual('EInOutError', raisedText, 'Execute should raise the exception of the target whose Start failed');
  Assert.IsTrue(FileExists(fileName), 'Precondition: the file target was started before the failing one');
  // proc is still referenced, as it would be in a program that reports the
  // error and carries on.
  Assert.IsTrue(CanOpenExclusive(fileName),
    'After the failed Execute the first ToAll file is still open and locked while the process object lives');
end;

procedure TReviewPipesTests.PIPE2_ToAll_ChildStartRaises_ExecuteLeavesNoFileLocked;
var
  fileName : string;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe2_', '.log');
  try
    CheckFailedExecuteLeavesNoFileLocked(fileName);
  finally
    RemoveFile(fileName);
  end;
end;

procedure TReviewPipesTests.PIPE3_DefaultEncoding_CmdEchoNonAscii_RoundTrips;
{$IFDEF MSWINDOWS}
var
  consoleCodePage : integer;
  consoleEncoding : TEncoding;
  expected : string;
  roundTrip : string;
  raw : TBytes;
  output : TStringBuilder;
  facts : string;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  // e-acute: present in 437, 850, 1252 and UTF-8.
  expected := Char($E9);
  consoleCodePage := ChildConsoleCodePage;
  Assert.IsTrue(consoleCodePage <> 0, 'could not read the child''s console code page from chcp');
  facts := 'GetACP=' + IntToStr(GetACP) + ' GetOEMCP=' + IntToStr(GetOEMCP) + ' child console code page=' + IntToStr(consoleCodePage);
  LogInfo('PIPE-3: ' + facts);
  consoleEncoding := TEncoding.GetEncoding(consoleCodePage);
  try
    roundTrip := consoleEncoding.GetString(consoleEncoding.GetBytes(expected));
  finally
    consoleEncoding.Free;
  end;
  if roundTrip <> expected then
  begin
    Assert.Pass('NOT RUN: the child''s console code page has no e-acute (' + facts + ')');
    exit;
  end;
  output := TStringBuilder.Create;
  try
    // No encoding on the target and no StartInfo.OutputEncoding: the library
    // default decodes what cmd.exe's echo wrote.
    raw := RunCmdCapture('echo ' + expected, output, nil);
    Assert.AreEqual(Escaped(expected), Escaped(Trim(output.ToString)),
      'cmd.exe wrote bytes ' + HexOf(raw) + ' and the default-encoding target decoded them wrongly (' + facts + ')');
  finally
    output.Free;
  end;
  if Cardinal(consoleCodePage) = GetACP then
    Assert.Pass('NOT PROVEN EITHER WAY: the ANSI code page equals the child''s console code page here, so the fault cannot show (' + facts + ')');
  {$ELSE}
  Assert.Pass('Windows only');
  {$ENDIF}
end;

procedure TReviewPipesTests.PIPE3_Premise_CmdEchoWritesConsoleCodePageBytes;
{$IFDEF MSWINDOWS}
var
  scriptName : string;
  command : string;
  raw : TBytes;
  expectedRaw : TBytes;
  explicitOutput : TStringBuilder;
  defaultOutput : TStringBuilder;
  cp850 : TEncoding;
  cp1252 : TEncoding;
  expected : string;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  // A batch file whose bytes are known: it switches its console to code page
  // 850 and echoes "caf" + e-acute, which is byte $82 in code page 850 ($E9
  // in 1252, $C3 $A9 in UTF-8).
  expected := 'caf' + Char($E9);
  expectedRaw := Concat2(TEncoding.ASCII.GetBytes('caf'), BytesOf([$82, 13, 10]));
  scriptName := TTestHelpers.TempFileName('vsoft_review_pipe3_', '.cmd');
  explicitOutput := TStringBuilder.Create;
  defaultOutput := TStringBuilder.Create;
  cp850 := TEncoding.GetEncoding(850);
  cp1252 := TEncoding.GetEncoding(1252);
  try
    WriteFileBytes(scriptName, Concat2(TEncoding.ASCII.GetBytes('@echo off'#13#10'chcp 850 >nul'#13#10'echo caf'), BytesOf([$82, 13, 10])));
    command := TTestHelpers.BuildSingleCommand(scriptName, []);
    raw := RunCmdCapture(command, explicitOutput, cp850);
    Assert.AreEqual(HexOf(expectedRaw), HexOf(raw), 'cmd.exe should write redirected echo output in its console code page (850 here)');
    Assert.AreEqual(Escaped(expected), Escaped(Trim(explicitOutput.ToString)), 'Decoding with the console code page gives the text');

    // What the finding is about, shown but not asserted: no fix of the
    // default can know about a chcp inside the child.
    RunCmdCapture(command, defaultOutput, nil);
    LogInfo('PIPE-3 premise: console code page 850 wrote ' + HexOf(raw) + '; the default-encoding target (ANSI code page ' +
      IntToStr(GetACP) + ') decoded it as "' + Escaped(Trim(defaultOutput.ToString)) + '"; code page 1252 would give "' +
      Escaped(Trim(cp1252.GetString(raw))) + '"');
  finally
    cp1252.Free;
    cp850.Free;
    defaultOutput.Free;
    explicitOutput.Free;
    RemoveFile(scriptName);
  end;
  {$ELSE}
  Assert.Pass('Windows only');
  {$ENDIF}
end;

procedure TReviewPipesTests.PIPE5_LineCallbackRaised_DoneDoesNotCallItAgain;
var
  target : IPipeTarget;
  sink : TLineSink;
  payload : TBytes;
  raised : boolean;
begin
  sink := TLineSink.Create;
  try
    sink.RaiseOnFirstLine := true;
    target := TPipeTarget.ToLineMethod(sink.OnLine, TEncoding.UTF8);
    target.Start;
    payload := TEncoding.UTF8.GetBytes('a'#10'b'#10'c');
    raised := false;
    try
      target.HandleData(payload, Length(payload));
    except
      on EReviewSinkError do
        raised := true;
    end;
    Assert.IsTrue(raised, 'Precondition: the callback''s exception leaves HandleData');
    Assert.AreEqual('a', sink.Joined, 'Precondition: the callback saw only the line it raised on');
    // The process marks a target that raised as faulted ("receives no more
    // data this run") and then calls Done.
    target.Done;
    Assert.AreEqual('a', Escaped(sink.Joined), 'A line target whose callback raised must not be called again from Done');
  finally
    target := nil;
    sink.Free;
  end;
end;

procedure TReviewPipesTests.PIPE5_LineCallbackRaised_NoLineTheChildNeverWrote;
var
  target : IPipeTarget;
  sink : TLineSink;
  payload : TBytes;
begin
  sink := TLineSink.Create;
  try
    sink.RaiseOnFirstLine := true;
    target := TPipeTarget.ToLineMethod(sink.OnLine, TEncoding.UTF8);
    target.Start;
    payload := TEncoding.UTF8.GetBytes('a'#10'b'#10'c');
    try
      target.HandleData(payload, Length(payload));
    except
      on EReviewSinkError do
        ;
    end;
    target.Done;
    // Whatever Done does with the tail, the child wrote the lines a, b and
    // c: "ac" is not one of them.
    Assert.IsTrue(sink.Lines.IndexOf('ac') < 0, 'Done delivered "ac", a line the child never wrote (all lines: ' + Escaped(sink.Joined) + ')');
  finally
    target := nil;
    sink.Free;
  end;
end;

procedure TReviewPipesTests.PIPE5_LineCallbackRaisesAgainInDone_InjectedEncodingForgotten;
var
  target : IPipeTarget;
  aware : IEncodingAwarePipeTarget;
  sink : TLineSink;
  payload : TBytes;
begin
  sink := TLineSink.Create;
  try
    target := TPipeTarget.ToLineMethod(sink.OnLine);
    Assert.IsTrue(Supports(target, IEncodingAwarePipeTarget, aware));

    // Run 1: the process injects StartInfo.OutputEncoding (UTF-16 here); the
    // callback raises in HandleData and again when Done calls it.
    aware.SetDefaultEncoding(TEncoding.Unicode);
    target.Start;
    sink.RaiseAlways := true;
    payload := TEncoding.Unicode.GetBytes('a'#10'b'#10'c');
    try
      target.HandleData(payload, Length(payload));
    except
      on EReviewSinkError do
        ;
    end;
    try
      target.Done;
    except
      on EReviewSinkError do
        ;
    end;

    // Run 2: nothing injected, so the default encoding applies. ASCII bytes
    // decode the same in every default; in UTF-16 they are not lines at all.
    sink.RaiseAlways := false;
    sink.Lines.Clear;
    target.Start;
    payload := TEncoding.ASCII.GetBytes('x'#10'y'#10);
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('x|y', Escaped(sink.Joined), 'The second run still decoded with the first run''s injected encoding');
  finally
    aware := nil;
    target := nil;
    sink.Free;
  end;
end;

procedure TReviewPipesTests.PIPE6_LineTarget_Utf8Bom_NotPartOfFirstLine;
var
  actual : string;
begin
  // Split after the first byte of the BOM to cover the boundary as well.
  actual := FeedLines(TEncoding.UTF8, [BytesOf([$EF]),
                                       Concat2(BytesOf([$BB, $BF]), TEncoding.ASCII.GetBytes('first'#10)),
                                       TEncoding.ASCII.GetBytes('second'#10)]);
  Assert.AreEqual('first|second', Escaped(actual), 'The UTF-8 byte order mark must not be part of the first line');
end;

procedure TReviewPipesTests.PIPE6_LineTarget_Utf16LEBom_NotPartOfFirstLine;
var
  actual : string;
begin
  actual := FeedLines(TEncoding.Unicode, [Concat2(BytesOf([$FF, $FE]), TEncoding.Unicode.GetBytes('first'#10'second'#10))]);
  Assert.AreEqual('first|second', Escaped(actual), 'The UTF-16 byte order mark must not be part of the first line');
end;

procedure TReviewPipesTests.PIPE6_StringBuilderTarget_Utf8Bom_NotInText;
var
  actual : string;
begin
  actual := FeedStringBuilder(TEncoding.UTF8, [BytesOf([$EF]),
                                               Concat2(BytesOf([$BB, $BF]), TEncoding.ASCII.GetBytes('{"ok":true}'))]);
  Assert.AreEqual('{"ok":true}', Escaped(actual), 'The UTF-8 byte order mark must not be part of the captured text');
end;

procedure TReviewPipesTests.PIPE7_StringBuilderTarget_Gb18030_EverySplitPoint;
{$IFDEF MSWINDOWS}
var
  text : string;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  // U+4E2D is two bytes in GB18030, U+1F60A (a surrogate pair) is four.
  text := 'a' + Char($4E2D) + Char($D83D) + Char($DE0A) + 'b';
  Assert.AreEqual('', FailingSplitPoints(54936, text), 'A GB18030 character split across two reads was corrupted');
  {$ELSE}
  Assert.Pass('Windows only (code page 54936 through MultiByteToWideChar)');
  {$ENDIF}
end;

procedure TReviewPipesTests.PIPE7_StringBuilderTarget_ShiftJis_EverySplitPoint;
{$IFDEF MSWINDOWS}
var
  text : string;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  // Hiragana A and the kanji for "day": two bytes each in Shift-JIS.
  text := 'a' + Char($3042) + Char($65E5) + 'b';
  Assert.AreEqual('', FailingSplitPoints(932, text), 'A Shift-JIS character split across two reads was corrupted');
  {$ELSE}
  Assert.Pass('Windows only (code page 932 through MultiByteToWideChar)');
  {$ENDIF}
end;

procedure TReviewPipesTests.PIPE8_DbcsCodePage_FindingCharBoundary_NotDearerThanDecoding;
{$IFDEF MSWINDOWS}
const
  cMegabytes = 32;
  cRounds = 3;
  // Finding where the last whole character of a read ends may cost at most
  // this many times what decoding the read costs.
  cMaxScanToDecode = 2.0;
var
  shiftJis : TEncoding;
  utf8Ms : Double;
  dbcsMs : Double;
  elapsed : Double;
  scanMs : Double;
  decodeMs : Double;
  bestScanMs : Double;
  bestDecodeMs : Double;
  round : integer;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  shiftJis := TEncoding.GetEncoding(932);
  try
    // Best of a few rounds each, interleaved, so load from other programs
    // hits all of them alike.
    utf8Ms := 0;
    dbcsMs := 0;
    bestScanMs := 0;
    bestDecodeMs := 0;
    for round := 1 to cRounds do
    begin
      elapsed := TimeStringBuilderFeed(TEncoding.UTF8, cMegabytes);
      if (round = 1) or (elapsed < utf8Ms) then
        utf8Ms := elapsed;
      elapsed := TimeStringBuilderFeed(shiftJis, cMegabytes);
      if (round = 1) or (elapsed < dbcsMs) then
        dbcsMs := elapsed;
      TimeScanAndDecode(932, cMegabytes, scanMs, decodeMs);
      if (round = 1) or (scanMs < bestScanMs) then
        bestScanMs := scanMs;
      if (round = 1) or (decodeMs < bestDecodeMs) then
        bestDecodeMs := decodeMs;
    end;
  finally
    shiftJis.Free;
  end;
  if utf8Ms < 1 then
    utf8Ms := 1;
  if bestDecodeMs < 1 then
    bestDecodeMs := 1;
  LogInfo(Format('PIPE-8: %d MB of ASCII in 64 KB reads through ToStringBuilder: UTF-8 %.1f ms, code page 932 %.1f ms (%.1f times)',
    [cMegabytes, utf8Ms, dbcsMs, dbcsMs / utf8Ms]));
  LogInfo(Format('PIPE-8: code page 932 alone: finding the character boundary (CompleteCharLength) %.1f ms, decoding (DecodeLenient) %.1f ms (%.1f times)',
    [bestScanMs, bestDecodeMs, bestScanMs / bestDecodeMs]));
  Assert.IsTrue(bestScanMs <= cMaxScanToDecode * bestDecodeMs,
    Format('For %d MB in code page 932, finding the character boundaries took %.1f ms against %.1f ms for decoding (%.1f times, limit %.1f); through ToStringBuilder: %.1f ms against %.1f ms for UTF-8',
      [cMegabytes, bestScanMs, bestDecodeMs, bestScanMs / bestDecodeMs, cMaxScanToDecode, dbcsMs, utf8Ms]));
  {$ELSE}
  Assert.Pass('Windows only (the per-byte IsDBCSLeadByteEx walk)');
  {$ENDIF}
end;

procedure TReviewPipesTests.PIPE9_FromFile_FileOpenForWritingElsewhere_StartSucceeds;
var
  source : IPipeSource;
  writer : TFileStream;
  fileName : string;
  payload : TBytes;
  data : TBytes;
  dataLength : NativeUInt;
  raisedText : string;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe9_', '.txt');
  writer := nil;
  try
    payload := TEncoding.ASCII.GetBytes('still being written');
    WriteFileBytes(fileName, payload);
    // Another handle with write access that shares everything, as a logger
    // appending to the file would hold.
    writer := TFileStream.Create(fileName, fmOpenReadWrite or fmShareDenyNone);
    source := TPipeSource.FromFile(fileName);
    raisedText := '';
    try
      source.Start;
    except
      on e : Exception do
        raisedText := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raisedText, 'FromFile could not open a file that another handle has open for writing');
    Assert.IsTrue(source.GetData(data, dataLength));
    Assert.AreEqual(Integer(Length(payload)), Integer(dataLength));
    source.Done;
  finally
    source := nil;
    writer.Free;
    RemoveFile(fileName);
  end;
end;

procedure TReviewPipesTests.PIPE9_FileAsStdIn_FileOpenForWritingElsewhere_StartSucceeds;
var
  source : IPipeSource;
  fileSource : IFileStdInPipeSource;
  writer : TFileStream;
  fileName : string;
  raisedText : string;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe9_', '.txt');
  writer := nil;
  try
    WriteFileBytes(fileName, TEncoding.ASCII.GetBytes('still being written'));
    writer := TFileStream.Create(fileName, fmOpenReadWrite or fmShareDenyNone);
    source := TPipeSource.FileAsStdIn(fileName);
    Assert.IsTrue(Supports(source, IFileStdInPipeSource, fileSource));
    raisedText := '';
    try
      source.Start;
    except
      on e : Exception do
        raisedText := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raisedText, 'FileAsStdIn could not open a file that another handle has open for writing');
    Assert.IsTrue(fileSource.FileHandle <> 0, 'Start should have opened the file');
    source.Done;
  finally
    fileSource := nil;
    source := nil;
    writer.Free;
    RemoveFile(fileName);
  end;
end;

procedure TReviewPipesTests.CheckChildReadsFileOpenForWriting(asStdInFile : boolean);
var
  proc : IProcess;
  writer : TFileStream;
  output : TStringBuilder;
  fileName : string;
  raisedText : string;
  started : boolean;
begin
  fileName := TTestHelpers.TempFileName('vsoft_review_pipe9_', '.txt');
  writer := nil;
  output := TStringBuilder.Create;
  try
    WriteFileBytes(fileName, TEncoding.ASCII.GetBytes('line one'#13#10'line two'#13#10));
    writer := TFileStream.Create(fileName, fmOpenReadWrite or fmShareDenyNone);
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 30000;
    TTestHelpers.SetupShellCommand(proc, 'echo-stdin', []);
    if asStdInFile then
      proc.WithStdInPipe(TPipeSource.FileAsStdIn(fileName))
    else
      proc.WithStdInPipe(TPipeSource.FromFile(fileName));
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output, TEncoding.UTF8));
    raisedText := '';
    started := false;
    try
      started := proc.Execute;
    except
      on e : Exception do
        raisedText := e.ClassName + ': ' + e.Message;
    end;
    Assert.AreEqual('', raisedText, 'Execute raised for a stdin file that another handle has open for writing');
    Assert.IsTrue(started, proc.Errors.Text);
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    Assert.IsTrue((Pos('line one', output.ToString) > 0) and (Pos('line two', output.ToString) > 0),
      'The child did not read the file: "' + Escaped(output.ToString) + '"');
  finally
    proc := nil;
    writer.Free;
    output.Free;
    RemoveFile(fileName);
  end;
end;

procedure TReviewPipesTests.PIPE9_FromFile_FileOpenForWritingElsewhere_ChildReadsIt;
begin
  CheckChildReadsFileOpenForWriting(false);
end;

procedure TReviewPipesTests.PIPE9_FileAsStdIn_FileOpenForWritingElsewhere_ChildReadsIt;
begin
  CheckChildReadsFileOpenForWriting(true);
end;

procedure TReviewPipesTests.PIPE10_LineDelegateCapturingProcess_ProcessStillReleased;
var
  destroyed : boolean;
  destroyedAfterBreak : boolean;
  breaker : IPipeTarget;
  watch : NativeUInt;
begin
  destroyed := false;
  breaker := nil;
  try
    // On return the routine's own reference to the process is gone; nothing
    // outside the process refers to it (breaker is one of its targets).
    BuildProcessCapturedByItsDelegate(@destroyed, false, breaker, watch);
    Assert.IsTrue(destroyed, 'The process and its targets should be freed when the last outside reference goes; the delegate that uses the process keeps it alive');
  finally
    // Break the cycle so the test itself leaks nothing.
    if (breaker <> nil) and (not destroyed) then
      SendLine(breaker, cReleaseLine);
    destroyedAfterBreak := destroyed;
    breaker := nil;
  end;
  Assert.IsTrue(destroyedAfterBreak, 'Test cleanup could not free the process');
end;

procedure TReviewPipesTests.PIPE10_LineDelegateCapturingProcess_KillOnReleaseStillKillsLeftovers;
{$IFDEF MSWINDOWS}
var
  destroyed : boolean;
  breaker : IPipeTarget;
  watch : NativeUInt;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  destroyed := false;
  breaker := nil;
  watch := 0;
  try
    BuildProcessCapturedByItsDelegate(@destroyed, true, breaker, watch);
    // JobMode KillOnRelease: releasing the IProcess kills what the child
    // left running. The routine above has released it.
    Assert.IsTrue(TTestHelpers.HasEndedWithin(watch, 5000),
      'The program the child left running is still alive 5 s after the last outside reference to the IProcess was released');
    Assert.IsTrue(destroyed, 'The process object was not freed');
  finally
    if (breaker <> nil) and (not destroyed) then
      SendLine(breaker, cReleaseLine);
    breaker := nil;
    TTestHelpers.KillWatched(watch);
  end;
  {$ELSE}
  Assert.Pass('Windows only (job object)');
  {$ENDIF}
end;

initialization
  TDUnitX.RegisterTestFixture(TReviewPipesTests);

end.
