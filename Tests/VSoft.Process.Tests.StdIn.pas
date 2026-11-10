unit VSoft.Process.Tests.StdIn;

interface

// Stdin sources end to end: what the child reads, and what happens when a
// source misbehaves. The child is a byte-exact cat: the test exe's cat
// helper mode on Windows, /bin/cat elsewhere.

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  [TestFixture]
  TProcessStdInTests = class
  public
    [Setup]
    procedure SetUp;

    // GetData raises: logged, the child sees end of file, the run completes.
    [Test]
    procedure SourceRaises_LoggedAndRunCompletes;
    // A source that reports more bytes than its buffer holds.
    [Test]
    procedure SourceReportsLengthBeyondBuffer_OnlyBufferIsWritten;
    // The writer is blocked on a full pipe when the child exits.
    [Test]
    procedure ChildExitsWithoutReading_LargeSource_RunCompletes;
    [Test]
    procedure SourceDoneRaises_LoggedAndRunCompletes;

    // Binary data arrives unchanged (no text mode, no Ctrl+Z, no NUL loss).
    [Test]
    procedure FromBytes_AllByteValues_RoundTrip;
    [Test]
    procedure FromStream_LargerThanPipeBuffer_RoundTrip;
    [Test]
    procedure FromFile_LargerThanPipeBuffer_RoundTrip;
  end;

implementation

uses
  {$IFNDEF MSWINDOWS}
  Posix.Unistd,
  {$ENDIF}
  VSoft.Process.Tests.Common,
  VSoft.Process.Tests.Helper;

type
  // Hands out one chunk and can be told to misbehave.
  TTestSource = class(TInterfacedObject, IPipeSource)
  private
    FData : TBytes;
    FReportedLength : NativeUInt;
    FRaiseInGetData : boolean;
    FRaiseInDone : boolean;
  protected
    procedure Start;
    function GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;
    procedure Done;
  public
    constructor Create(const data : TBytes; reportedLength : NativeUInt; raiseInGetData : boolean; raiseInDone : boolean);
  end;

constructor TTestSource.Create(const data : TBytes; reportedLength : NativeUInt; raiseInGetData : boolean; raiseInDone : boolean);
begin
  inherited Create;
  FData := data;
  FReportedLength := reportedLength;
  FRaiseInGetData := raiseInGetData;
  FRaiseInDone := raiseInDone;
end;

procedure TTestSource.Start;
begin
end;

function TTestSource.GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;
begin
  if FRaiseInGetData then
    raise Exception.Create('source-boom');
  data := FData;
  dataLength := FReportedLength;
  result := False;
end;

procedure TTestSource.Done;
begin
  if FRaiseInDone then
    raise Exception.Create('done-boom');
end;

function PatternBytes(count : integer) : TBytes;
var
  i : integer;
begin
  SetLength(result, count);
  for i := 0 to count - 1 do
    result[i] := Byte((i * 31 + (i shr 8)) and $FF);
end;

// Runs cat with source as its stdin and returns what it wrote to stdout.
function RoundTrip(const source : IPipeSource; out proc : IProcess) : TBytes;
var
  captured : TBytesStream;
begin
  captured := TBytesStream.Create;
  try
    proc := TProcess.Create;
    proc.StartInfo.TimeoutInMSec := 60000;
    SetupCatChild(proc);
    proc.WithStdInPipe(source);
    proc.WithStdOutPipe(TPipeTarget.ToStream(captured));
    try
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
    finally
      proc.ClearPipes;
    end;
    Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
    result := Copy(captured.Bytes, 0, captured.Size);
  finally
    captured.Free;
  end;
end;

{ TProcessStdInTests }

procedure TProcessStdInTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TProcessStdInTests.SourceRaises_LoggedAndRunCompletes;
var
  proc : IProcess;
  received : TBytes;
begin
  received := RoundTrip(TTestSource.Create(nil, 0, True, False), proc);
  Assert.AreEqual<Integer>(0, Length(received), 'the child sees end of file');
  Assert.Contains(proc.Errors.Text, 'Stdin pipe source raised');
  Assert.Contains(proc.Errors.Text, 'source-boom');
end;

procedure TProcessStdInTests.SourceReportsLengthBeyondBuffer_OnlyBufferIsWritten;
var
  proc : IProcess;
  sent : TBytes;
  received : TBytes;
begin
  sent := TEncoding.ASCII.GetBytes('abc');
  received := RoundTrip(TTestSource.Create(sent, 1000, False, False), proc);
  Assert.IsTrue(TTestHelpers.SameBytes(sent, received), Format('the child read %d bytes, the buffer held 3', [Length(received)]));
end;

procedure TProcessStdInTests.ChildExitsWithoutReading_LargeSource_RunCompletes;
var
  proc : IProcess;
  big : TBytes;
  started : Int64;
  elapsed : Int64;
begin
  // Far more than the pipe holds, so the writer is blocked when the child
  // (which never reads its stdin) exits.
  SetLength(big, 16 * 1024 * 1024);
  proc := TProcess.Create;
  proc.StartInfo.TimeoutInMSec := 60000;
  TTestHelpers.SetupShellCommand(proc, 'exit-with', ['0']);
  proc.WithStdInPipe(TPipeSource.FromBytes(big));
  started := TTestHelpers.TickMs;
  Assert.IsTrue(proc.Execute, proc.Errors.Text);
  elapsed := TTestHelpers.TickMs - started;
  Assert.AreEqual(TProcessStatus.Exited, proc.Status, proc.Errors.Text);
  Assert.AreEqual<Cardinal>(0, proc.ExitCode);
  Assert.IsTrue(elapsed < 15000, Format('the run took %d ms: it waited for a writer nobody was reading from', [elapsed]));
  Assert.AreEqual('', Trim(proc.Errors.Text), 'a child that does not read its stdin is not an error');
end;

procedure TProcessStdInTests.SourceDoneRaises_LoggedAndRunCompletes;
var
  proc : IProcess;
  received : TBytes;
begin
  received := RoundTrip(TTestSource.Create(nil, 0, False, True), proc);
  Assert.AreEqual<Integer>(0, Length(received));
  Assert.Contains(proc.Errors.Text, 'Stdin pipe source Done raised');
  Assert.Contains(proc.Errors.Text, 'done-boom');
end;

procedure TProcessStdInTests.FromBytes_AllByteValues_RoundTrip;
var
  proc : IProcess;
  sent : TBytes;
  received : TBytes;
  i : integer;
begin
  SetLength(sent, 4096);
  for i := 0 to High(sent) do
    sent[i] := Byte(i and $FF);
  received := RoundTrip(TPipeSource.FromBytes(sent), proc);
  Assert.IsTrue(TTestHelpers.SameBytes(sent, received), Format('sent %d bytes, the child wrote back %d', [Length(sent), Length(received)]));
  Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
end;

procedure TProcessStdInTests.FromStream_LargerThanPipeBuffer_RoundTrip;
var
  proc : IProcess;
  sent : TBytes;
  received : TBytes;
  stream : TBytesStream;
begin
  sent := PatternBytes(300000);
  stream := TBytesStream.Create(sent);
  try
    received := RoundTrip(TPipeSource.FromStream(stream), proc);
    Assert.IsTrue(TTestHelpers.SameBytes(sent, received), Format('sent %d bytes, the child wrote back %d', [Length(sent), Length(received)]));
    Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
  finally
    proc := nil;
    stream.Free;
  end;
end;

procedure TProcessStdInTests.FromFile_LargerThanPipeBuffer_RoundTrip;
var
  proc : IProcess;
  sent : TBytes;
  received : TBytes;
  fileName : string;
  fileStream : TFileStream;
begin
  sent := PatternBytes(300000);
  fileName := TTestHelpers.TempFileName('vsoft_proc_stdin_', '.bin');
  try
    fileStream := TFileStream.Create(fileName, fmCreate);
    try
      fileStream.WriteBuffer(sent[0], Length(sent));
    finally
      fileStream.Free;
    end;
    received := RoundTrip(TPipeSource.FromFile(fileName), proc);
    Assert.IsTrue(TTestHelpers.SameBytes(sent, received), Format('sent %d bytes, the child wrote back %d', [Length(sent), Length(received)]));
    Assert.AreEqual('', Trim(proc.Errors.Text), 'no errors expected');
  finally
    proc := nil;
    if FileExists(fileName) then
      DeleteFile(fileName);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessStdInTests);

end.
