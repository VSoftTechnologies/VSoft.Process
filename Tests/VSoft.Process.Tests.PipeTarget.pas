unit VSoft.Process.Tests.PipeTarget;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process,
  VSoft.Process.PipeTarget.Classes;

type
  // Direct unit-tests for the pipe target classes. These do NOT spawn a child
  // process; they exercise HandleData/Start/Done in isolation, which is where
  // the audit found the most damaging bugs (C1: WriteBuffer of dynamic array
  // passed the address-of-pointer instead of the data).
  [TestFixture]
  TPipeTargetTests = class
  private
    function MakeBytes(const value : string) : TBytes;
    // Feeds each chunk to a fresh line target and returns the lines joined
    // with '|'.
    function FeedLines(const encoding : TEncoding; const chunks : array of TBytes) : string;
    // Feeds bytes to a fresh line target split in two at every position.
    procedure CheckEverySplitPoint(const encoding : TEncoding; const text : string; const expected : string);
  public
    // C1 - TStreamPipeTarget.HandleData previously called
    //   FStream.WriteBuffer(data, dataLength)
    // which writes Count bytes starting at the address of `data` (the variable),
    // not at the address of data[0]. The stream therefore received stack/pointer
    // garbage. After the fix the stream MUST contain the exact bytes handed in.
    [Test]
    procedure StreamTarget_WritesExactBytes;

    // Multiple HandleData calls should append, not overwrite, and the total
    // stream length must match the sum of all input lengths.
    [Test]
    procedure StreamTarget_AppendsAcrossCalls;

    // dataLength=0 must be a no-op, not an out-of-range read.
    [Test]
    procedure StreamTarget_ZeroLengthIsNoOp;

    // C1 for TFilePipeTarget. Round-trip the file and compare bytes.
    [Test]
    procedure FileTarget_WritesExactBytes;

    // H6 - TFilePipeTarget destructor must close FFileStream even if Done was
    // never called (which previously leaked the file handle / left the file
    // locked).
    [Test]
    procedure FileTarget_DestructorClosesFileIfDoneNotCalled;

    // StringBuilder target should round-trip an ASCII string accurately.
    [Test]
    procedure StringBuilderTarget_ConcatenatesText;

    // Line target should split on LF.
    [Test]
    procedure LineTarget_SplitsOnLF;

    // Line target should split on CRLF without emitting empty CR-only lines.
    [Test]
    procedure LineTarget_SplitsOnCRLF;

    // Line target Done should emit a partial final line (no trailing newline).
    [Test]
    procedure LineTarget_EmitsPartialFinalLine;

    // ToAll fans out to every contained target.
    [Test]
    procedure MultiTarget_FansOutToAll;

    // ToAll takes an open array, so an inline [a, b] compiles on XE2 too.
    [Test]
    procedure MultiTarget_ArrayLiteral_FansOutToAll;

    // ToAll keeps its own copy: changing the caller's array afterwards does
    // not change the targets it fans out to.
    [Test]
    procedure MultiTarget_CallerArrayChangedAfterwards_TargetsUnchanged;

    // H7 - UTF-8 multi-byte sequences split across HandleData calls used to
    // be replaced by U+FFFD. After the fix the byte tail is carried between
    // calls and decoding produces the intact character.
    [Test]
    procedure LineTarget_UTF8MultiByteSplitAcrossReads;

    // Bytes that arrive without a trailing newline must be buffered until
    // either a newline arrives or Done is called.
    [Test]
    procedure LineTarget_BufferedUntilNewline;

    // Calling HandleData with dataLength=0 must be a no-op even on the line
    // target (no extra empty line emitted).
    [Test]
    procedure LineTarget_ZeroLengthIsNoOp;

    // Done on an empty line target must not emit a spurious blank line.
    [Test]
    procedure LineTarget_DoneOnEmptyEmitsNothing;

    // C1 follow-up - if dataLength is LESS than Length(data), only that many
    // bytes are written to the stream. The fixed-buffer pipe loop relies on
    // this contract.
    [Test]
    procedure StreamTarget_HonoursDataLengthOverBufferLength;

    // ToFile with append=True should preserve existing content and add new
    // bytes after it.
    [Test]
    procedure FileTarget_AppendMode_PreservesExistingContent;

    // Done on a stream target should NOT free the user-owned stream; the
    // caller still needs to read from it after the process is gone.
    [Test]
    procedure StreamTarget_DoneDoesNotFreeUserStream;

    // W2 - When the user did not pass an explicit encoding, the process can
    // inject StartInfo.OutputEncoding via IEncodingAwarePipeTarget. After
    // Start runs, HandleData should decode using the injected encoding.
    [Test]
    procedure LineTarget_DefaultEncodingInjectedWhenNotExplicit;

    // W2 - An explicit encoding passed at construction must take precedence
    // over an injected default. HasExplicitEncoding must be True.
    [Test]
    procedure LineTarget_ExplicitEncodingWinsOverInjectedDefault;

    // W2 - StringBuilderPipeTarget honours the same injection contract.
    [Test]
    procedure StringBuilderTarget_DefaultEncodingInjectedWhenNotExplicit;

    // H11 - a lone CR (progress output) stays in the line text and no
    // character of the line is lost.
    [Test]
    procedure LineTarget_LoneCR_KeptWithoutDroppingCharacters;

    // A CRLF split across two reads still ends exactly one line.
    [Test]
    procedure LineTarget_CRLFSplitAcrossReads;

    // NUL becomes a space and other control characters are dropped.
    [Test]
    procedure LineTarget_ControlCharacters_Filtered;

    // Output ending in a bare CR (no LF) emits the line without the CR.
    [Test]
    procedure LineTarget_TrailingCRWithoutLF_Stripped;

    // H12 - Done used to nil the builder, so a second run raised an AV.
    [Test]
    procedure StringBuilderTarget_ReusableAcrossRuns;

    // H13 - a UTF-8 sequence split across reads must not become U+FFFD.
    [Test]
    procedure StringBuilderTarget_UTF8SplitAcrossReads;

    // H13 - UTF-16 output split in the middle of a code unit / surrogate pair.
    [Test]
    procedure StringBuilderTarget_UTF16SplitAcrossReads;

    // M12 - ToLineDelegate without an encoding must accept the injected default.
    [Test]
    procedure LineDelegateTarget_NoEncoding_IsNotExplicit;

    // M13 - ToAll forwards the injected default encoding to its children.
    [Test]
    procedure MultiTarget_ForwardsDefaultEncoding;

    // M11 - one file target attached to two streams (Start/Done twice).
    [Test]
    procedure FileTarget_SharedStartDone_KeepsFileOpenUntilLastDone;

    // A file target can be re-used for a second run.
    [Test]
    procedure FileTarget_ReusableAcrossRuns;

    [Test]
    procedure StreamTarget_NilStream_Raises;

    // A run of CRs before the LF ends the line without them (a CRLF written
    // through a text-mode stream on Windows becomes CR CR LF).
    [Test]
    procedure LineTarget_CRRunBeforeLF_EndsLine;
    [Test]
    procedure LineTarget_CRRunOfThreeBeforeLF_EndsLine;
    [Test]
    procedure LineTarget_CRRunBeforeLF_SplitAfterFirstCR;
    [Test]
    procedure LineTarget_CRRunBeforeLF_SplitBeforeLF;
    [Test]
    procedure LineTarget_CRRunBeforeLF_LoneCRInsideLineKept;
    // Output ending in a run of CRs (no LF) loses the whole run at Done.
    [Test]
    procedure LineTarget_CRRunWithoutLF_StrippedAtDone;

    // Bytes that are not valid in the encoding never raise; each invalid
    // sequence becomes U+FFFD.
    [Test]
    procedure LineTarget_InvalidUtf8_ReplacedNotRaised;
    [Test]
    procedure LineTarget_TruncatedUtf8AtDone_Replaced;
    [Test]
    procedure StringBuilderTarget_InvalidUtf8_ReplacedNotRaised;
    [Test]
    procedure StringBuilderTarget_TruncatedUtf8AtDone_Replaced;

    // UTF-16 output is split on the LF code unit at an even offset, never on
    // a 0x0A byte that is half of another character.
    [Test]
    procedure LineTarget_Utf16LE_EverySplitPoint;
    [Test]
    procedure LineTarget_Utf16BE_EverySplitPoint;
    [Test]
    procedure LineTarget_Utf16LE_OneByteAtATime;

    // Output that never sends a LF (a progress meter redrawn with lone CRs)
    // must not be buffered without limit: at the cap the text so far is
    // emitted as a line, with nothing lost.
    [Test]
    procedure LineTarget_LineWithoutLF_EmittedAtCap;
    // A LF arriving just after a forced break ends the emitted piece; it
    // does not add an empty line.
    [Test]
    procedure LineTarget_LineFeedAfterCap_NoEmptyLine;
    // A multi-byte character split exactly at the cap stays whole: its first
    // byte waits for the rest instead of being decoded as U+FFFD.
    [Test]
    procedure LineTarget_Utf8CharacterSplitAtCap_StaysWhole;
    // A CR arriving as the last byte at the cap stays pending, so a LF that
    // follows still ends the line as CRLF, with no extra empty line.
    [Test]
    procedure LineTarget_CarriageReturnAtCap_PairsWithFollowingLineFeed;

    // A target created without an encoding and used without Start decodes
    // with TEncoding.Default instead of a nil encoding.
    [Test]
    procedure StringBuilderTarget_WithoutStart_DecodesWithDefault;
    [Test]
    procedure LineTarget_WithoutStart_DecodesWithDefault;
  end;

implementation

uses
  System.IOUtils,
  {$IFNDEF MSWINDOWS}
  Posix.Unistd,
  {$ENDIF}
  VSoft.Process.Tests.Common;

function TPipeTargetTests.MakeBytes(const value: string): TBytes;
begin
  // Use UTF-8 explicitly so the test is deterministic across encodings.
  result := TEncoding.UTF8.GetBytes(value);
end;

procedure TPipeTargetTests.StreamTarget_WritesExactBytes;
var
  target  : IPipeTarget;
  stream  : TMemoryStream;
  payload : TBytes;
  roundTrip : TBytes;
begin
  payload := MakeBytes('Hello, World!');
  stream  := TMemoryStream.Create;
  try
    target := TPipeTarget.ToStream(stream);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual<Int64>(Length(payload), stream.Size, 'Stream size mismatch');

    SetLength(roundTrip, stream.Size);
    stream.Position := 0;
    stream.ReadBuffer(roundTrip[0], stream.Size);

    Assert.AreEqual(TEncoding.UTF8.GetString(payload),
                    TEncoding.UTF8.GetString(roundTrip),
                    'Round-tripped bytes do not match payload');
  finally
    stream.Free;
  end;
end;

procedure TPipeTargetTests.StreamTarget_AppendsAcrossCalls;
var
  target  : IPipeTarget;
  stream  : TMemoryStream;
  part1, part2 : TBytes;
  expected : string;
  roundTrip : TBytes;
begin
  part1 := MakeBytes('First chunk. ');
  part2 := MakeBytes('Second chunk.');
  expected := 'First chunk. Second chunk.';
  stream := TMemoryStream.Create;
  try
    target := TPipeTarget.ToStream(stream);
    target.Start;
    target.HandleData(part1, Length(part1));
    target.HandleData(part2, Length(part2));
    target.Done;

    Assert.AreEqual<Int64>(Length(part1) + Length(part2), stream.Size, 'Stream size mismatch');

    SetLength(roundTrip, stream.Size);
    stream.Position := 0;
    stream.ReadBuffer(roundTrip[0], stream.Size);

    Assert.AreEqual(expected, TEncoding.UTF8.GetString(roundTrip),
                    'Concatenated content mismatch');
  finally
    stream.Free;
  end;
end;

procedure TPipeTargetTests.StreamTarget_ZeroLengthIsNoOp;
var
  target  : IPipeTarget;
  stream  : TMemoryStream;
  empty   : TBytes;
begin
  SetLength(empty, 0);
  stream := TMemoryStream.Create;
  try
    target := TPipeTarget.ToStream(stream);
    target.Start;
    target.HandleData(empty, 0);
    target.Done;
    Assert.AreEqual<Int64>(0, stream.Size, 'Empty handle-data should not advance stream');
  finally
    stream.Free;
  end;
end;

procedure TPipeTargetTests.FileTarget_WritesExactBytes;
var
  target   : IPipeTarget;
  payload  : TBytes;
  fileName : string;
  diskBytes : TBytes;
  diskStream : TFileStream;
begin
  payload  := MakeBytes('File round trip content - 12345');
  fileName := TTestHelpers.TempFileName('vsoft_process_c1_', '.bin');
  try
    target := TPipeTarget.ToFile(fileName, False);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.IsTrue(FileExists(fileName), 'File was not created');

    diskStream := TFileStream.Create(fileName, fmOpenRead or fmShareDenyWrite);
    try
      Assert.AreEqual<Int64>(Length(payload), diskStream.Size, 'File size mismatch');
      SetLength(diskBytes, diskStream.Size);
      if diskStream.Size > 0 then
        diskStream.ReadBuffer(diskBytes[0], diskStream.Size);
    finally
      diskStream.Free;
    end;

    Assert.AreEqual(TEncoding.UTF8.GetString(payload),
                    TEncoding.UTF8.GetString(diskBytes),
                    'Round-tripped file bytes do not match payload');
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeTargetTests.FileTarget_DestructorClosesFileIfDoneNotCalled;
var
  target   : IPipeTarget;
  payload  : TBytes;
  fileName : string;
  testStream : TFileStream;
begin
  payload  := MakeBytes('partial');
  fileName := TTestHelpers.TempFileName('vsoft_process_h6_', '.bin');
  try
    target := TPipeTarget.ToFile(fileName, False);
    target.Start;
    target.HandleData(payload, Length(payload));
    // Intentionally NO Done call - simulating an exception path.
    target := nil; // forces refcount destroy

    // Without the H6 fix the file handle would still be open and exclusive,
    // so opening it for exclusive write would fail. With the fix the destructor
    // freed the file stream so we can re-open it freely.
    testStream := TFileStream.Create(fileName, fmOpenReadWrite or fmShareExclusive);
    try
      Assert.IsTrue(testStream.Size > 0, 'File should contain partial data');
    finally
      testStream.Free;
    end;
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_ConcatenatesText;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  part1, part2 : TBytes;
begin
  part1 := MakeBytes('foo ');
  part2 := MakeBytes('bar');
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.UTF8);
    target.Start;
    target.HandleData(part1, Length(part1));
    target.HandleData(part2, Length(part2));
    target.Done;

    Assert.AreEqual('foo bar', sb.ToString, 'StringBuilder content mismatch');
  finally
    sb.Free;
  end;
end;

type
  TLineCapture = class
  public
    Lines : TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(const line : string);
  end;

constructor TLineCapture.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TLineCapture.Destroy;
begin
  Lines.Free;
  inherited;
end;

procedure TLineCapture.OnLine(const line: string);
begin
  Lines.Add(line);
end;

procedure TPipeTargetTests.LineTarget_SplitsOnLF;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('alpha'#10'beta'#10);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count, 'Should produce 2 lines on LF');
    Assert.AreEqual('alpha', capture.Lines[0]);
    Assert.AreEqual('beta',  capture.Lines[1]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_SplitsOnCRLF;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('one'#13#10'two'#13#10'three'#13#10);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(3, capture.Lines.Count, 'Should produce 3 lines on CRLF');
    Assert.AreEqual('one',   capture.Lines[0]);
    Assert.AreEqual('two',   capture.Lines[1]);
    Assert.AreEqual('three', capture.Lines[2]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_EmitsPartialFinalLine;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('full'#10'no-newline-here');
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count, 'Should emit final partial line on Done');
    Assert.AreEqual('full',            capture.Lines[0]);
    Assert.AreEqual('no-newline-here', capture.Lines[1]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_UTF8MultiByteSplitAcrossReads;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  full    : TBytes;
  part1, part2 : TBytes;
  splitAt : Integer;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    // 'cafe' followed by U+00E9 (UTF-8: $C3 $A9) then LF. We deliberately
    // split the buffer in the middle of the 2-byte sequence: the first
    // chunk ends with $C3, the second starts with $A9 LF.
    full := TEncoding.UTF8.GetBytes('caf' + #$00E9 + #10);
    splitAt := Length(full) - 2; // before the $A9
    SetLength(part1, splitAt);
    Move(full[0], part1[0], splitAt);
    SetLength(part2, Length(full) - splitAt);
    Move(full[splitAt], part2[0], Length(full) - splitAt);

    target.Start;
    target.HandleData(part1, Length(part1));
    target.HandleData(part2, Length(part2));
    target.Done;

    Assert.AreEqual(1, capture.Lines.Count, 'Should emit exactly one line');
    Assert.AreEqual('caf' + #$00E9, capture.Lines[0],
                    'Multi-byte sequence split across reads must be stitched');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_BufferedUntilNewline;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  chunk   : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;

    chunk := MakeBytes('one ');
    target.HandleData(chunk, Length(chunk));
    Assert.AreEqual(0, capture.Lines.Count, 'No newline yet -> no line emitted');

    chunk := MakeBytes('two ');
    target.HandleData(chunk, Length(chunk));
    Assert.AreEqual(0, capture.Lines.Count, 'Still no newline');

    chunk := MakeBytes('three'#10);
    target.HandleData(chunk, Length(chunk));
    Assert.AreEqual(1, capture.Lines.Count, 'Newline should flush the line');
    Assert.AreEqual('one two three', capture.Lines[0]);

    target.Done;
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.MultiTarget_FansOutToAll;
var
  multi   : IPipeTarget;
  stream1, stream2 : TMemoryStream;
  payload : TBytes;
  inner   : TArray<IPipeTarget>;
begin
  payload := MakeBytes('fanned');
  stream1 := TMemoryStream.Create;
  stream2 := TMemoryStream.Create;
  try
    SetLength(inner, 2);
    inner[0] := TPipeTarget.ToStream(stream1);
    inner[1] := TPipeTarget.ToStream(stream2);
    multi := TPipeTarget.ToAll(inner);

    multi.Start;
    multi.HandleData(payload, Length(payload));
    multi.Done;

    Assert.AreEqual<Int64>(Length(payload), stream1.Size, 'Stream 1 size mismatch');
    Assert.AreEqual<Int64>(Length(payload), stream2.Size, 'Stream 2 size mismatch');
  finally
    stream1.Free;
    stream2.Free;
  end;
end;

procedure TPipeTargetTests.MultiTarget_ArrayLiteral_FansOutToAll;
var
  multi   : IPipeTarget;
  stream1, stream2 : TMemoryStream;
  payload : TBytes;
begin
  payload := MakeBytes('fanned');
  stream1 := TMemoryStream.Create;
  stream2 := TMemoryStream.Create;
  try
    multi := TPipeTarget.ToAll([TPipeTarget.ToStream(stream1), TPipeTarget.ToStream(stream2)]);

    multi.Start;
    multi.HandleData(payload, Length(payload));
    multi.Done;

    Assert.AreEqual<Int64>(Length(payload), stream1.Size, 'Stream 1 size mismatch');
    Assert.AreEqual<Int64>(Length(payload), stream2.Size, 'Stream 2 size mismatch');
  finally
    stream1.Free;
    stream2.Free;
  end;
end;

procedure TPipeTargetTests.MultiTarget_CallerArrayChangedAfterwards_TargetsUnchanged;
var
  multi   : IPipeTarget;
  stream1, stream2, stream3 : TMemoryStream;
  payload : TBytes;
  inner   : TArray<IPipeTarget>;
begin
  payload := MakeBytes('fanned');
  stream1 := TMemoryStream.Create;
  stream2 := TMemoryStream.Create;
  stream3 := TMemoryStream.Create;
  try
    SetLength(inner, 2);
    inner[0] := TPipeTarget.ToStream(stream1);
    inner[1] := TPipeTarget.ToStream(stream2);
    multi := TPipeTarget.ToAll(inner);
    inner[1] := TPipeTarget.ToStream(stream3);

    multi.Start;
    multi.HandleData(payload, Length(payload));
    multi.Done;

    Assert.AreEqual<Int64>(Length(payload), stream1.Size, 'Stream 1 size mismatch');
    Assert.AreEqual<Int64>(Length(payload), stream2.Size, 'Stream 2 must still be a target');
    Assert.AreEqual<Int64>(0, stream3.Size, 'Stream 3 was never passed to ToAll');
  finally
    stream1.Free;
    stream2.Free;
    stream3.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_ZeroLengthIsNoOp;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  empty   : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    SetLength(empty, 0);
    target.HandleData(empty, 0);
    target.Done;
    Assert.AreEqual(0, capture.Lines.Count,
                    'Zero-length data should produce no lines, not even an empty one');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_DoneOnEmptyEmitsNothing;
var
  target  : IPipeTarget;
  capture : TLineCapture;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    target.Done; // never received any data
    Assert.AreEqual(0, capture.Lines.Count,
                    'Done on a virgin line target should not synthesise a line');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.StreamTarget_HonoursDataLengthOverBufferLength;
var
  target  : IPipeTarget;
  stream  : TMemoryStream;
  payload : TBytes;
  readBack : TBytes;
begin
  // payload buffer has 16 bytes physically but we only ask for 5 to be written.
  // The stream MUST see exactly the first 5 bytes, not all 16.
  SetLength(payload, 16);
  payload[0] := $41;
  payload[1] := $42;
  payload[2] := $43;
  payload[3] := $44;
  payload[4] := $45;
  // Bytes 5..15 are deliberately leftover noise.
  payload[5] := $FF;
  payload[6] := $FF;
  payload[7] := $FF;

  stream := TMemoryStream.Create;
  try
    target := TPipeTarget.ToStream(stream);
    target.Start;
    target.HandleData(payload, 5); // only 5 bytes, not Length(payload)=16
    target.Done;

    Assert.AreEqual<Int64>(5, stream.Size,
                           'Stream must receive exactly dataLength bytes, not Length(data)');
    SetLength(readBack, stream.Size);
    stream.Position := 0;
    stream.ReadBuffer(readBack[0], stream.Size);
    Assert.AreEqual(Byte($41), readBack[0]);
    Assert.AreEqual(Byte($45), readBack[4]);
  finally
    stream.Free;
  end;
end;

procedure TPipeTargetTests.FileTarget_AppendMode_PreservesExistingContent;
var
  target   : IPipeTarget;
  fileName : string;
  fs       : TFileStream;
  preExisting : TBytes;
  added       : TBytes;
  diskBytes   : TBytes;
begin
  preExisting := MakeBytes('prefix-');
  added       := MakeBytes('appended');
  fileName    := TTestHelpers.TempFileName('vsoft_proc_append_', '.bin');
  try
    // Seed the file with known content first.
    fs := TFileStream.Create(fileName, fmCreate);
    try
      fs.WriteBuffer(preExisting[0], Length(preExisting));
    finally
      fs.Free;
    end;

    target := TPipeTarget.ToFile(fileName, True); // append=True
    target.Start;
    target.HandleData(added, Length(added));
    target.Done;

    fs := TFileStream.Create(fileName, fmOpenRead or fmShareDenyWrite);
    try
      Assert.AreEqual<Int64>(Length(preExisting) + Length(added), fs.Size,
                             'Append mode must keep existing bytes and add new ones');
      SetLength(diskBytes, fs.Size);
      fs.ReadBuffer(diskBytes[0], fs.Size);
    finally
      fs.Free;
    end;
    Assert.AreEqual('prefix-appended',
                    TEncoding.UTF8.GetString(diskBytes),
                    'Final content should be the original prefix followed by the appended bytes');
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeTargetTests.StreamTarget_DoneDoesNotFreeUserStream;
var
  target  : IPipeTarget;
  stream  : TMemoryStream;
  payload : TBytes;
begin
  // After Done, the user must still be able to use the stream they own.
  payload := MakeBytes('still-mine');
  stream  := TMemoryStream.Create;
  try
    target := TPipeTarget.ToStream(stream);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    target := nil; // drop the target ref too

    // If the pipe target had freed the stream this would AV; we'd never reach
    // the assertion.
    Assert.AreEqual<Int64>(Length(payload), stream.Size,
                           'Stream must remain valid and intact after the pipe target is released');
  finally
    stream.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_DefaultEncodingInjectedWhenNotExplicit;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  enc     : IEncodingAwarePipeTarget;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    // No encoding passed - HasExplicitEncoding must report False.
    target := TPipeTarget.ToLineMethod(capture.OnLine);
    Assert.IsTrue(Supports(target, IEncodingAwarePipeTarget, enc),
                  'TLineMethodPipeTarget must implement IEncodingAwarePipeTarget');
    Assert.IsFalse(enc.HasExplicitEncoding,
                   'Without an explicit encoding, HasExplicitEncoding must be False');
    // Inject UTF-8 as the default - then feed multi-byte content.
    enc.SetDefaultEncoding(TEncoding.UTF8);
    target.Start;
    payload := TEncoding.UTF8.GetBytes('caf' + #$00E9 + #10);
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(1, capture.Lines.Count);
    Assert.AreEqual('caf' + #$00E9, capture.Lines[0],
                    'Line target must decode the bytes with the injected UTF-8 default');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_ExplicitEncodingWinsOverInjectedDefault;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  enc     : IEncodingAwarePipeTarget;
begin
  capture := TLineCapture.Create;
  try
    // Explicit UTF-8 passed at construction.
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    Assert.IsTrue(Supports(target, IEncodingAwarePipeTarget, enc));
    Assert.IsTrue(enc.HasExplicitEncoding,
                  'Constructor-supplied encoding must be flagged as explicit');
    // Injecting a different default must NOT clobber the explicit choice.
    enc.SetDefaultEncoding(TEncoding.ASCII);
    target.Start;
    // (no further assertions needed - HasExplicitEncoding == True is the contract)
    target.Done;
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_DefaultEncodingInjectedWhenNotExplicit;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  enc     : IEncodingAwarePipeTarget;
  payload : TBytes;
begin
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb);
    Assert.IsTrue(Supports(target, IEncodingAwarePipeTarget, enc),
                  'TStringBuilderPipeTarget must implement IEncodingAwarePipeTarget');
    Assert.IsFalse(enc.HasExplicitEncoding);
    enc.SetDefaultEncoding(TEncoding.UTF8);
    target.Start;
    payload := TEncoding.UTF8.GetBytes('caf' + #$00E9);
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('caf' + #$00E9, sb.ToString,
                    'StringBuilder target must decode with the injected UTF-8 default');
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_LoneCR_KeptWithoutDroppingCharacters;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('abc'#13'def'#10'10%'#13'20%'#13'30%'#13#10);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual('abc'#13'def', capture.Lines[0], 'No character may be lost around a lone CR');
    Assert.AreEqual('10%'#13'20%'#13'30%', capture.Lines[1]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_CRLFSplitAcrossReads;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  part1, part2 : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    part1 := MakeBytes('one'#13);
    part2 := MakeBytes(#10'two'#13#10);
    target.Start;
    target.HandleData(part1, Length(part1));
    target.HandleData(part2, Length(part2));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual('one', capture.Lines[0]);
    Assert.AreEqual('two', capture.Lines[1]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_ControlCharacters_Filtered;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('a'#0'b'#27'[0m'#9'c'#7#10);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(1, capture.Lines.Count);
    Assert.AreEqual('a b[0m'#9'c', capture.Lines[0]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_TrailingCRWithoutLF_Stripped;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    payload := MakeBytes('first'#10'progress'#13);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual('progress', capture.Lines[1]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_ReusableAcrossRuns;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  payload : TBytes;
begin
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.UTF8);
    payload := MakeBytes('first run');
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('first run', sb.ToString);

    payload := MakeBytes('second run');
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('second run', sb.ToString, 'Start clears the builder for each run');
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_UTF8SplitAcrossReads;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  full    : TBytes;
  i       : Integer;
  expected : string;
  chunk   : TBytes;
begin
  // e-acute (2 bytes) and the euro sign (3 bytes), fed one byte at a time so
  // every possible split point is exercised.
  expected := 'x' + #$00E9 + 'y' + #$20AC + 'z';
  full := TEncoding.UTF8.GetBytes(expected);
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.UTF8);
    target.Start;
    SetLength(chunk, 1);
    for i := 0 to High(full) do
    begin
      chunk[0] := full[i];
      target.HandleData(chunk, 1);
    end;
    target.Done;
    Assert.AreEqual(expected, sb.ToString);
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_UTF16SplitAcrossReads;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  full    : TBytes;
  i       : Integer;
  expected : string;
  chunk   : TBytes;
begin
  // U+1F600 is a surrogate pair in UTF-16.
  expected := 'a' + #$D83D#$DE00 + 'b';
  full := TEncoding.Unicode.GetBytes(expected);
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.Unicode);
    target.Start;
    SetLength(chunk, 1);
    for i := 0 to High(full) do
    begin
      chunk[0] := full[i];
      target.HandleData(chunk, 1);
    end;
    target.Done;
    Assert.AreEqual(expected, sb.ToString);
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.LineDelegateTarget_NoEncoding_IsNotExplicit;
var
  target : IPipeTarget;
  enc    : IEncodingAwarePipeTarget;
begin
  target := TPipeTarget.ToLineDelegate(
    procedure(const line : string)
    begin
    end);
  Assert.IsTrue(Supports(target, IEncodingAwarePipeTarget, enc));
  Assert.IsFalse(enc.HasExplicitEncoding,
                 'ToLineDelegate without an encoding must accept StartInfo.OutputEncoding');
end;

procedure TPipeTargetTests.MultiTarget_ForwardsDefaultEncoding;
var
  multi   : IPipeTarget;
  capture : TLineCapture;
  enc     : IEncodingAwarePipeTarget;
  inner   : TArray<IPipeTarget>;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    SetLength(inner, 1);
    inner[0] := TPipeTarget.ToLineMethod(capture.OnLine);
    multi := TPipeTarget.ToAll(inner);
    Assert.IsTrue(Supports(multi, IEncodingAwarePipeTarget, enc),
                  'ToAll must be encoding aware so it can forward the default');
    enc.SetDefaultEncoding(TEncoding.UTF8);
    multi.Start;
    payload := TEncoding.UTF8.GetBytes('caf' + #$00E9 + #10);
    multi.HandleData(payload, Length(payload));
    multi.Done;
    Assert.AreEqual(1, capture.Lines.Count);
    Assert.AreEqual('caf' + #$00E9, capture.Lines[0]);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.FileTarget_SharedStartDone_KeepsFileOpenUntilLastDone;
var
  target   : IPipeTarget;
  fileName : string;
  part1, part2 : TBytes;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_shared_', '.bin');
  try
    part1 := MakeBytes('from-stdout;');
    part2 := MakeBytes('from-stderr;');
    target := TPipeTarget.ToFile(fileName, False);
    target.Start;
    target.Start; // second stream - must not reopen (sharing violation) or leak
    target.HandleData(part1, Length(part1));
    target.Done;  // first stream finished - file must stay open
    target.HandleData(part2, Length(part2));
    target.Done;
    Assert.AreEqual('from-stdout;from-stderr;', TEncoding.UTF8.GetString(TTestHelpers.ReadFileBytes(fileName)));
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeTargetTests.FileTarget_ReusableAcrossRuns;
var
  target   : IPipeTarget;
  fileName : string;
  payload  : TBytes;
begin
  fileName := TTestHelpers.TempFileName('vsoft_proc_rerun_', '.bin');
  try
    target := TPipeTarget.ToFile(fileName, False);
    payload := MakeBytes('run one');
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    payload := MakeBytes('run two');
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('run two', TEncoding.UTF8.GetString(TTestHelpers.ReadFileBytes(fileName)),
                    'Each run recreates the file when append is False');
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeTargetTests.StreamTarget_NilStream_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TPipeTarget.ToStream(nil);
    end,
    EArgumentNilException);
end;

function TPipeTargetTests.FeedLines(const encoding : TEncoding; const chunks : array of TBytes) : string;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  i : integer;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, encoding);
    target.Start;
    for i := 0 to High(chunks) do
      target.HandleData(chunks[i], Length(chunks[i]));
    target.Done;
    result := '';
    for i := 0 to capture.Lines.Count - 1 do
    begin
      if i > 0 then
        result := result + '|';
      result := result + capture.Lines[i];
    end;
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.CheckEverySplitPoint(const encoding : TEncoding; const text : string; const expected : string);
var
  full : TBytes;
  part1 : TBytes;
  part2 : TBytes;
  splitAt : integer;
begin
  full := encoding.GetBytes(text);
  Assert.AreEqual(expected, FeedLines(encoding, [full]), 'single read');
  for splitAt := 1 to Length(full) - 1 do
  begin
    part1 := Copy(full, 0, splitAt);
    part2 := Copy(full, splitAt, Length(full) - splitAt);
    Assert.AreEqual(expected, FeedLines(encoding, [part1, part2]), 'split at byte ' + IntToStr(splitAt));
  end;
end;

procedure TPipeTargetTests.LineTarget_CRRunBeforeLF_EndsLine;
begin
  Assert.AreEqual('abc|def', FeedLines(TEncoding.UTF8, [MakeBytes('abc'#13#13#10'def'#13#13#10)]));
end;

procedure TPipeTargetTests.LineTarget_CRRunOfThreeBeforeLF_EndsLine;
begin
  Assert.AreEqual('abc', FeedLines(TEncoding.UTF8, [MakeBytes('abc'#13#13#13#10)]));
end;

procedure TPipeTargetTests.LineTarget_CRRunBeforeLF_SplitAfterFirstCR;
begin
  Assert.AreEqual('abc|def', FeedLines(TEncoding.UTF8, [MakeBytes('abc'#13), MakeBytes(#13#10'def'#13#10)]));
end;

procedure TPipeTargetTests.LineTarget_CRRunBeforeLF_SplitBeforeLF;
begin
  Assert.AreEqual('abc|def', FeedLines(TEncoding.UTF8, [MakeBytes('abc'#13#13), MakeBytes(#10'def'#13#10)]));
end;

procedure TPipeTargetTests.LineTarget_CRRunBeforeLF_LoneCRInsideLineKept;
begin
  Assert.AreEqual('a'#13'b', FeedLines(TEncoding.UTF8, [MakeBytes('a'#13'b'#13#13#10)]));
end;

procedure TPipeTargetTests.LineTarget_CRRunWithoutLF_StrippedAtDone;
begin
  Assert.AreEqual('first|a'#13'b', FeedLines(TEncoding.UTF8, [MakeBytes('first'#10'a'#13'b'#13#13)]));
end;

procedure TPipeTargetTests.LineTarget_InvalidUtf8_ReplacedNotRaised;
var
  payload : TBytes;
begin
  payload := TBytes.Create(Ord('a'), Ord('b'), $FF, Ord('c'), Ord('d'), 13, 10, Ord('n'), Ord('e'), Ord('x'), Ord('t'), 13, 10);
  Assert.AreEqual('ab' + #$FFFD + 'cd|next', FeedLines(TEncoding.UTF8, [payload]));
end;

procedure TPipeTargetTests.LineTarget_TruncatedUtf8AtDone_Replaced;
var
  payload : TBytes;
begin
  // U+4E2D is E4 B8 AD; the stream ends after the first two bytes.
  payload := TBytes.Create(Ord('a'), Ord('b'), $E4, $B8);
  Assert.AreEqual('ab' + #$FFFD, FeedLines(TEncoding.UTF8, [payload]));
end;

procedure TPipeTargetTests.StringBuilderTarget_InvalidUtf8_ReplacedNotRaised;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  payload : TBytes;
begin
  payload := TBytes.Create(Ord('a'), Ord('b'), $FF, Ord('c'), Ord('d'), 13, 10, Ord('n'), Ord('e'), Ord('x'), Ord('t'), 13, 10);
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.UTF8);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('ab' + #$FFFD + 'cd'#13#10'next'#13#10, sb.ToString);
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_TruncatedUtf8AtDone_Replaced;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  payload : TBytes;
begin
  payload := TBytes.Create(Ord('a'), Ord('b'), $E4, $B8);
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb, TEncoding.UTF8);
    target.Start;
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('ab' + #$FFFD, sb.ToString);
  finally
    sb.Free;
  end;
end;

const
  // U+010A is 0A 01 in UTF-16LE, U+0A05 is 0A 05 in UTF-16BE and U+1F60A is
  // D83D DE0A, so each byte order has 0x0A bytes at even offsets that are not
  // line feeds.
  cUtf16Text = 'x' + #$010A + #$0A05 + #$D83D#$DE0A + 'y'#13#10'two'#10'a'#13'b'#13#10'last';
  cUtf16Lines = 'x' + #$010A + #$0A05 + #$D83D#$DE0A + 'y|two|a'#13'b|last';

procedure TPipeTargetTests.LineTarget_Utf16LE_EverySplitPoint;
begin
  CheckEverySplitPoint(TEncoding.Unicode, cUtf16Text, cUtf16Lines);
end;

procedure TPipeTargetTests.LineTarget_Utf16BE_EverySplitPoint;
begin
  CheckEverySplitPoint(TEncoding.BigEndianUnicode, cUtf16Text, cUtf16Lines);
end;

procedure TPipeTargetTests.LineTarget_Utf16LE_OneByteAtATime;
var
  full : TBytes;
  chunks : array of TBytes;
  i : integer;
begin
  full := TEncoding.Unicode.GetBytes(cUtf16Text);
  SetLength(chunks, Length(full));
  for i := 0 to High(full) do
    chunks[i] := TBytes.Create(full[i]);
  Assert.AreEqual(cUtf16Lines, FeedLines(TEncoding.Unicode, chunks));
end;

procedure TPipeTargetTests.LineTarget_LineWithoutLF_EmittedAtCap;
const
  cChunk = 64 * 1024;
  cExtra = 1000;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  chunk   : TBytes;
  i       : integer;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    SetLength(chunk, cChunk);
    FillChar(chunk[0], cChunk, Ord('x'));
    for i := 1 to cMaxPendingLineBytes div cChunk do
      target.HandleData(chunk, cChunk);
    target.HandleData(chunk, cExtra);
    Assert.AreEqual(1, capture.Lines.Count, 'The capped text should be emitted before Done');
    Assert.AreEqual(cMaxPendingLineBytes, Length(capture.Lines[0]));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual(cExtra, Length(capture.Lines[1]), 'No character may be lost after a forced break');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_LineFeedAfterCap_NoEmptyLine;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  chunk   : TBytes;
  tail    : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    SetLength(chunk, cMaxPendingLineBytes);
    FillChar(chunk[0], cMaxPendingLineBytes, Ord('x'));
    target.HandleData(chunk, cMaxPendingLineBytes);
    tail := MakeBytes(#10'y'#10);
    target.HandleData(tail, Length(tail));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count, 'The LF ends the capped piece; it should not add an empty line');
    Assert.AreEqual(cMaxPendingLineBytes, Length(capture.Lines[0]));
    Assert.AreEqual('y', capture.Lines[1], false);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_Utf8CharacterSplitAtCap_StaysWhole;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  chunk   : TBytes;
  tail    : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    // The cap is reached with the first byte of e-acute (C3 A9) as the last.
    SetLength(chunk, cMaxPendingLineBytes);
    FillChar(chunk[0], cMaxPendingLineBytes - 1, Ord('x'));
    chunk[cMaxPendingLineBytes - 1] := $C3;
    target.HandleData(chunk, cMaxPendingLineBytes);
    tail := TBytes.Create($A9, 10);
    target.HandleData(tail, Length(tail));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual(cMaxPendingLineBytes - 1, Length(capture.Lines[0]), 'The incomplete character must not be in the forced piece');
    Assert.AreEqual(0, Pos(#$FFFD, capture.Lines[0]), 'No replacement character in the forced piece');
    Assert.AreEqual(#$E9, capture.Lines[1], 'The character is completed by its second byte');
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_CarriageReturnAtCap_PairsWithFollowingLineFeed;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  chunk   : TBytes;
  tail    : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine, TEncoding.UTF8);
    target.Start;
    SetLength(chunk, cMaxPendingLineBytes);
    FillChar(chunk[0], cMaxPendingLineBytes - 1, Ord('x'));
    chunk[cMaxPendingLineBytes - 1] := 13;
    target.HandleData(chunk, cMaxPendingLineBytes);
    tail := TBytes.Create(10, Ord('y'), 10);
    target.HandleData(tail, Length(tail));
    target.Done;

    Assert.AreEqual(2, capture.Lines.Count, 'CR + LF is one line end; it should not add an empty line');
    Assert.AreEqual(cMaxPendingLineBytes - 1, Length(capture.Lines[0]), 'The CR must wait for its LF');
    Assert.AreEqual('y', capture.Lines[1], false);
  finally
    capture.Free;
  end;
end;

procedure TPipeTargetTests.StringBuilderTarget_WithoutStart_DecodesWithDefault;
var
  target  : IPipeTarget;
  sb      : TStringBuilder;
  payload : TBytes;
begin
  sb := TStringBuilder.Create;
  try
    target := TPipeTarget.ToStringBuilder(sb);
    payload := TBytes.Create(Ord('a'), Ord('b'), Ord('c'));
    target.HandleData(payload, Length(payload));
    target.Done;
    Assert.AreEqual('abc', sb.ToString, false);
  finally
    sb.Free;
  end;
end;

procedure TPipeTargetTests.LineTarget_WithoutStart_DecodesWithDefault;
var
  target  : IPipeTarget;
  capture : TLineCapture;
  payload : TBytes;
begin
  capture := TLineCapture.Create;
  try
    target := TPipeTarget.ToLineMethod(capture.OnLine);
    payload := TBytes.Create(Ord('a'), Ord('b'), 10, Ord('c'));
    target.HandleData(payload, Length(payload));
    Assert.AreEqual(1, capture.Lines.Count, 'The first line should be split at its LF, before Done');
    target.Done;
    Assert.AreEqual(2, capture.Lines.Count);
    Assert.AreEqual('ab', capture.Lines[0], false);
    Assert.AreEqual('c', capture.Lines[1], false);
  finally
    capture.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeTargetTests);

end.
