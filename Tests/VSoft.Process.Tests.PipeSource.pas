unit VSoft.Process.Tests.PipeSource;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process,
  VSoft.Process.PipeSource.Classes;

type
  [TestFixture]
  TPipeSourceTests = class
  public
    [Test]
    procedure StringSource_ReturnsExactBytes;

    [Test]
    procedure BytesSource_ReturnsExactBytes;

    [Test]
    procedure FileSource_LoadsFileContents;

    [Test]
    procedure StreamSource_DrainsFromCurrentPosition;

    [Test]
    procedure Interactive_QueueAndDrain;

    [Test]
    procedure Interactive_ClosedRejectsFurtherWrites;

    [Test]
    procedure Interactive_IsClosedReflectsState;

    // H3 - the interactive source must indicate "no more data may come"
    // promptly after Close so the stdin writer thread exits the busy-spin.
    [Test]
    procedure Interactive_GetDataAfterCloseReturnsFalse;

    // H3 - WaitForData must time out (return False) when no data is queued
    // and the source has not been closed. Without this the writer thread
    // would tight-loop calling GetData.
    [Test]
    procedure Interactive_WaitForData_TimesOutWhenIdle;

    // H3 - Write must signal the event so a parked WaitForData wakes up.
    [Test]
    procedure Interactive_WaitForData_WakesAfterWrite;

    // H3 - Close must signal the event so a parked WaitForData wakes up.
    [Test]
    procedure Interactive_WaitForData_WakesAfterClose;

    // Round-trip a TBytes payload through Interactive without an encoding step.
    [Test]
    procedure Interactive_WriteBytes_PreservedExactly;

    // Two consecutive writes should both arrive in a single GetData call (FIFO).
    [Test]
    procedure Interactive_MultipleWritesConcatenateInOrder;

    // L6 - a missing stdin file used to send nothing silently.
    [Test]
    procedure FileSource_MissingFile_StartRaises;

    // L6 - large files are streamed in chunks rather than loaded at once.
    [Test]
    procedure FileSource_LargeFile_StreamedInChunks;

    // L6 - a second run re-sends the stream from the original position.
    [Test]
    procedure StreamSource_SecondRun_ResendsFromOriginalPosition;

    // L6 - Write(string) without an encoding uses the injected InputEncoding.
    [Test]
    procedure Interactive_WriteString_UsesInjectedDefaultEncoding;

    // An injected InputEncoding belongs to one run: a later run with no
    // injection must not reuse it (it may have been freed since).
    [Test]
    procedure StringSource_InjectedDefault_ForgottenAfterDone;
    [Test]
    procedure Interactive_InjectedDefault_ForgottenAfterDone;
  end;

implementation

uses
  System.IOUtils,
  {$IFNDEF MSWINDOWS}
  Posix.Unistd,
  {$ENDIF}
  VSoft.Process.Tests.Common;

procedure TPipeSourceTests.StringSource_ReturnsExactBytes;
var
  src : IPipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.FromString('hello', TEncoding.UTF8);
  src.Start;
  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(5, len);
  Assert.AreEqual('hello', TEncoding.UTF8.GetString(data, 0, len));
end;

procedure TPipeSourceTests.BytesSource_ReturnsExactBytes;
var
  src : IPipeSource;
  input, data : TBytes;
  len : NativeUInt;
begin
  input := TEncoding.UTF8.GetBytes('XYZ');
  src := TPipeSource.FromBytes(input);
  src.Start;
  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(3, len);
  Assert.AreEqual('XYZ', TEncoding.UTF8.GetString(data, 0, len));
end;

procedure TPipeSourceTests.FileSource_LoadsFileContents;
var
  src : IPipeSource;
  data : TBytes;
  len : NativeUInt;
  fileName : string;
  fs : TFileStream;
  payload : TBytes;
begin
  payload := TEncoding.UTF8.GetBytes('file-content');
  fileName := TTestHelpers.TempFileName('vsoft_filesrc_', '.txt');
  try
    fs := TFileStream.Create(fileName, fmCreate);
    try
      fs.WriteBuffer(payload[0], Length(payload));
    finally
      fs.Free;
    end;

    src := TPipeSource.FromFile(fileName);
    src.Start;
    src.GetData(data, len);
    Assert.AreEqual<NativeUInt>(Length(payload), len);
    Assert.AreEqual('file-content', TEncoding.UTF8.GetString(data, 0, len));
  finally
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeSourceTests.StreamSource_DrainsFromCurrentPosition;
var
  src : IPipeSource;
  data : TBytes;
  len : NativeUInt;
  payload : TBytes;
  ms : TMemoryStream;
begin
  payload := TEncoding.UTF8.GetBytes('1234567890');
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(payload[0], Length(payload));
    ms.Position := 5; // start reading from middle

    src := TPipeSource.FromStream(ms);
    src.Start;
    src.GetData(data, len);
    Assert.AreEqual<NativeUInt>(5, len, 'Should read only remaining bytes from current position');
    Assert.AreEqual('67890', TEncoding.UTF8.GetString(data, 0, len));
  finally
    ms.Free;
  end;
end;

procedure TPipeSourceTests.Interactive_QueueAndDrain;
var
  src : IInteractivePipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.Interactive;
  Assert.IsTrue(src.Write('first line'#10));
  Assert.IsTrue(src.Write('second line'#10));
  src.Close;

  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(NativeUInt(Length('first line'#10'second line'#10)), len);
  Assert.AreEqual('first line'#10'second line'#10, TEncoding.UTF8.GetString(data, 0, len));
end;

procedure TPipeSourceTests.Interactive_ClosedRejectsFurtherWrites;
var
  src : IInteractivePipeSource;
begin
  src := TPipeSource.Interactive;
  src.Close;
  Assert.IsFalse(src.Write('too late'),
                 'Write after Close should return False');
end;

procedure TPipeSourceTests.Interactive_IsClosedReflectsState;
var
  src : IInteractivePipeSource;
begin
  src := TPipeSource.Interactive;
  Assert.IsFalse(src.IsClosed);
  src.Close;
  Assert.IsTrue(src.IsClosed);
end;

procedure TPipeSourceTests.Interactive_GetDataAfterCloseReturnsFalse;
var
  src : IInteractivePipeSource;
  data : TBytes;
  len : NativeUInt;
  hasMore : boolean;
begin
  src := TPipeSource.Interactive;
  src.Close;
  hasMore := src.GetData(data, len);
  Assert.IsFalse(hasMore, 'After Close with empty queue, GetData must signal no-more-data');
  Assert.AreEqual<NativeUInt>(0, len);
end;

procedure TPipeSourceTests.Interactive_WaitForData_TimesOutWhenIdle;
var
  src : IInteractivePipeSource;
  start : Int64;
  woke : Boolean;
  elapsed : Int64;
begin
  src := TPipeSource.Interactive;
  start := TTestHelpers.TickMs;
  woke := src.WaitForData(100);
  elapsed := TTestHelpers.TickMs - start;
  Assert.IsFalse(woke, 'Idle WaitForData must return False on timeout');
  Assert.IsTrue(elapsed >= 90,
                'WaitForData should have blocked for ~100ms, not returned immediately');
end;

procedure TPipeSourceTests.Interactive_WaitForData_WakesAfterWrite;
var
  src : IInteractivePipeSource;
  woke : Boolean;
begin
  src := TPipeSource.Interactive;
  src.Write('payload'#10);
  // A Write that landed before WaitForData was called must still leave the
  // event signalled - WaitForData should return immediately.
  woke := src.WaitForData(500);
  Assert.IsTrue(woke, 'WaitForData must return True after a Write has signalled');
end;

procedure TPipeSourceTests.Interactive_WaitForData_WakesAfterClose;
var
  src : IInteractivePipeSource;
  woke : Boolean;
begin
  src := TPipeSource.Interactive;
  src.Close;
  woke := src.WaitForData(500);
  Assert.IsTrue(woke, 'WaitForData must return True after Close (so writer can observe EOF)');
end;

procedure TPipeSourceTests.Interactive_WriteBytes_PreservedExactly;
var
  src : IInteractivePipeSource;
  input, data : TBytes;
  len : NativeUInt;
  i : integer;
begin
  // Binary payload including a zero byte - must NOT be filtered out.
  SetLength(input, 4);
  input[0] := $00;
  input[1] := $7F;
  input[2] := $FE;
  input[3] := $FF;

  src := TPipeSource.Interactive;
  Assert.IsTrue(src.Write(input));
  src.Close;

  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(4, len, 'Byte payload length mismatch');
  for i := 0 to High(input) do
    Assert.AreEqual(input[i], data[i],
                    Format('Byte at index %d corrupted', [i]));
end;

procedure TPipeSourceTests.Interactive_MultipleWritesConcatenateInOrder;
var
  src : IInteractivePipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.Interactive;
  src.Write('AAA');
  src.Write('BBB');
  src.Write('CCC');
  src.Close;
  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(9, len);
  Assert.AreEqual('AAABBBCCC', TEncoding.UTF8.GetString(data, 0, len),
                  'Multiple writes must be concatenated in the order they were submitted');
end;

// Drains a source the way the stdin writer does and returns everything sent.
function DrainSource(const src : IPipeSource; out calls : integer) : TBytes;
var
  data : TBytes;
  len : NativeUInt;
  hasMore : boolean;
  total : integer;
begin
  calls := 0;
  total := 0;
  SetLength(result, 0);
  repeat
    hasMore := src.GetData(data, len);
    Inc(calls);
    if len > 0 then
    begin
      SetLength(result, total + Integer(len));
      Move(data[0], result[total], len);
      Inc(total, len);
    end;
  until not hasMore;
end;

procedure TPipeSourceTests.FileSource_MissingFile_StartRaises;
var
  src : IPipeSource;
begin
  src := TPipeSource.FromFile(TTestHelpers.TempFileName('vsoft_missing_', '.txt'));
  Assert.WillRaise(
    procedure
    begin
      src.Start;
    end,
    EVSoftProcessError);
end;

procedure TPipeSourceTests.FileSource_LargeFile_StreamedInChunks;
const
  cSize = 300 * 1024;
var
  src : IPipeSource;
  fileName : string;
  fs : TFileStream;
  payload : TBytes;
  received : TBytes;
  calls : integer;
  i : integer;
begin
  SetLength(payload, cSize);
  for i := 0 to cSize - 1 do
    payload[i] := Byte(i mod 251);
  fileName := TTestHelpers.TempFileName('vsoft_bigsrc_', '.bin');
  try
    fs := TFileStream.Create(fileName, fmCreate);
    try
      fs.WriteBuffer(payload[0], cSize);
    finally
      fs.Free;
    end;
    src := TPipeSource.FromFile(fileName);
    src.Start;
    received := DrainSource(src, calls);
    src.Done;
    Assert.AreEqual<Int64>(cSize, Length(received), 'Every byte must be sent');
    Assert.IsTrue(calls > 2, 'A large file should be delivered in several chunks');
    for i := 0 to cSize - 1 do
      if received[i] <> payload[i] then
        Assert.Fail('Byte ' + IntToStr(i) + ' corrupted');
  finally
    src := nil;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

procedure TPipeSourceTests.StreamSource_SecondRun_ResendsFromOriginalPosition;
var
  src : IPipeSource;
  ms : TMemoryStream;
  payload : TBytes;
  calls : integer;
begin
  payload := TEncoding.UTF8.GetBytes('header|body');
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(payload[0], Length(payload));
    ms.Position := 7;
    src := TPipeSource.FromStream(ms);
    src.Start;
    Assert.AreEqual('body', TEncoding.UTF8.GetString(DrainSource(src, calls)));
    src.Done;
    src.Start;
    Assert.AreEqual('body', TEncoding.UTF8.GetString(DrainSource(src, calls)),
                    'A re-run must send the same bytes again');
    src.Done;
  finally
    src := nil;
    ms.Free;
  end;
end;

procedure TPipeSourceTests.Interactive_WriteString_UsesInjectedDefaultEncoding;
var
  src : IInteractivePipeSource;
  enc : IEncodingAwarePipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.Interactive;
  Assert.IsTrue(Supports(src, IEncodingAwarePipeSource, enc),
                'The interactive source must accept StartInfo.InputEncoding');
  enc.SetDefaultEncoding(TEncoding.Unicode);
  src.Write('A');
  src.Close;
  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(2, len, 'UTF-16 encodes A as two bytes');
end;

procedure TPipeSourceTests.StringSource_InjectedDefault_ForgottenAfterDone;
var
  src : IPipeSource;
  enc : IEncodingAwarePipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.FromString('hello');
  Assert.IsTrue(Supports(src, IEncodingAwarePipeSource, enc));
  // Run 1: the process injects UTF-16.
  enc.SetDefaultEncoding(TEncoding.Unicode);
  src.Start;
  src.GetData(data, len);
  src.Done;
  Assert.AreEqual<NativeUInt>(10, len, 'Run 1 uses the injected UTF-16');

  // Run 2: no injection, so TEncoding.Default applies.
  src.Start;
  src.GetData(data, len);
  src.Done;
  Assert.AreEqual<NativeUInt>(5, len, 'Run 2 must not reuse run 1''s injected UTF-16');
  Assert.AreEqual('hello', TEncoding.Default.GetString(data, 0, len));
end;

procedure TPipeSourceTests.Interactive_InjectedDefault_ForgottenAfterDone;
var
  src : IInteractivePipeSource;
  enc : IEncodingAwarePipeSource;
  data : TBytes;
  len : NativeUInt;
begin
  src := TPipeSource.Interactive;
  Assert.IsTrue(Supports(src, IEncodingAwarePipeSource, enc));
  // Run 1: the process injects UTF-16.
  enc.SetDefaultEncoding(TEncoding.Unicode);
  src.Start;
  src.Done;

  // Run 2: no injection, so Write(string) uses UTF-8.
  src.Start;
  Assert.IsTrue(src.Write('A'));
  src.Close;
  src.GetData(data, len);
  Assert.AreEqual<NativeUInt>(1, len, 'Run 2 must not reuse run 1''s injected UTF-16');
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeSourceTests);

end.
