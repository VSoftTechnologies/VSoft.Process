unit VSoft.Process.PipeSource.Classes;

interface

uses
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  VSoft.Process;

type
  TPipeSourceBase = class(TInterfacedObject, IPipeSource)
  protected
    procedure Start;virtual;
    //not sure what the best interface should be here
    //returns true if more data available
    function GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;virtual;abstract;
    procedure Done;virtual;
  end;

  TStringPipeSource = class(TPipeSourceBase, IEncodingAwarePipeSource)
  private
    // Encoding plumbing: we keep the original string + the chosen encoding
    // until Start. That lets the process inject StartInfo.InputEncoding as a
    // default via SetDefaultEncoding when the caller didn't pass an explicit
    // one (the constructor leaves FEncoding nil in that case). Start finalises
    // the choice and produces the byte buffer.
    FValue : string;
    FEncoding : TEncoding;
    FEncodingExplicit : boolean;
    FBytes : TBytes;
  protected
    procedure Start;override;
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
    procedure Done;override;

    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
  public
    constructor Create(const value : string; const encoding : TEncoding);
  end;

  TBytesPipeSource = class(TPipeSourceBase)
  private
    FBytes : TBytes;
  protected
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
  public
    constructor Create(const value : TBytes);

  end;

  TInteractivePipeSource = class(TPipeSourceBase, IInteractivePipeSource, IEncodingAwarePipeSource)
  private
    FWriteQueue : TList<TBytes>;
    // Encoding used by Write(string) when no encoding is passed: the injected
    // StartInfo.InputEncoding, else UTF-8.
    FDefaultEncoding : TEncoding;
    FLock : TCriticalSection;
    FClosed : Boolean;
    // H3: an event the stdin writer thread can wait on instead of busy-spinning
    // through GetData when the queue is empty. Signalled by Write/Close, reset
    // by GetData when it drains the queue.
    FDataReadyEvent : TEvent;
  protected
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
    procedure Done;override;
  public
    constructor Create;
    destructor Destroy;override;

    // IInteractivePipeSource methods
    function Write(const data : TBytes) : Boolean;overload;
    function Write(const text : string; const encoding : TEncoding = nil) : Boolean; overload;
    procedure Close;
    function IsClosed : Boolean;
    // Exposed so the worker thread can block until data is available
    // without holding any lock. Public for the platform impl to use.
    function WaitForData(timeoutMS : Cardinal) : Boolean;

    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
  end;

  // TPipeSource.FileAsStdIn: the platform gives the child the file opened by
  // Start as its stdin, so no data passes through GetData. A missing file
  // raises when the run starts, as TFilePipeSource does.
  TFileStdInPipeSource = class(TPipeSourceBase, IFileStdInPipeSource)
  private
    FFileName : string;
    FFileStream : TFileStream;
  protected
    procedure Start;override;
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
    procedure Done;override;
    function GetFileName : string;
    function GetFileHandle : THandle;
  public
    constructor Create(const fileName : string);
    destructor Destroy;override;
  end;

  // Streams the file to stdin in chunks, so large files are not loaded into
  // memory. A missing file raises when the run starts.
  TFilePipeSource = class(TPipeSourceBase)
  private
    FFileName : string;
    FFileStream : TFileStream;
  protected
    procedure Start;override;
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
    procedure Done;override;
  public
    constructor Create(const fileName : string);
    destructor Destroy;override;
  end;

  // Streams from the current position of the stream to its end, in chunks.
  // The starting position is remembered so a re-run sends the same data.
  TStreamPipeSource = class(TPipeSourceBase)
  private
    FStream : TStream;
    FOwnsStream : Boolean;
    FStartPosition : Int64;
    FStartPositionKnown : Boolean;
  protected
    procedure Start;override;
    function GetData(var data : TBytes; out dataLength: NativeUInt) : boolean;override;
  public
    constructor Create(const stream : TStream; ownsStream : Boolean = False);
    destructor Destroy;override;
  end;

implementation

uses
  System.Generics.Defaults;

const
  cSourceChunkSize = 64 * 1024;

{ TPipeSourceBase }

procedure TPipeSourceBase.Done;
begin
  //do nothing
end;

procedure TPipeSourceBase.Start;
begin
  //do nothing
end;

{ TStringPipeSource }

constructor TStringPipeSource.Create(const value: string; const encoding: TEncoding);
begin
  // Defer byte encoding to Start so SetDefaultEncoding (injected by the
  // process from StartInfo.InputEncoding) can take effect when the user
  // didn't pass an explicit encoding.
  FValue := value;
  FEncoding := encoding;
  FEncodingExplicit := encoding <> nil;
end;

procedure TStringPipeSource.Start;
begin
  if FEncoding = nil then
    FEncoding := TEncoding.Default;
  FBytes := FEncoding.GetBytes(FValue);
end;

procedure TStringPipeSource.Done;
begin
  // An injected default belongs to this run only: the next run may inject a
  // different one, or none, and this one may since have been freed.
  if not FEncodingExplicit then
    FEncoding := nil;
end;

function TStringPipeSource.HasExplicitEncoding: boolean;
begin
  result := FEncodingExplicit;
end;

procedure TStringPipeSource.SetDefaultEncoding(const value: TEncoding);
begin
  if not FEncodingExplicit then
    FEncoding := value;
end;

function TStringPipeSource.GetData(var data: TBytes; out dataLength: NativeUInt): boolean;
begin
  data := FBytes;
  dataLength := Length(FBytes);
  result := false; //no more data;
end;

{ TBytesPipeSource }

constructor TBytesPipeSource.Create(const value: TBytes);
begin
  FBytes := Copy(value); //do we need to do this?
end;

function TBytesPipeSource.GetData(var data: TBytes; out dataLength: NativeUInt): boolean;
begin
  data := FBytes;
  dataLength := Length(FBytes);
  result := false; //no more data;
end;

{ TInteractivePipeSource }

constructor TInteractivePipeSource.Create;
begin
  inherited;
  FWriteQueue := TList<TBytes>.Create;
  FLock := TCriticalSection.Create;
  // Manual-reset so multiple waiters wake; we explicitly reset inside GetData.
  FDataReadyEvent := TEvent.Create(nil, True, False, '');
  FClosed := False;
  FDefaultEncoding := nil;
end;

destructor TInteractivePipeSource.Destroy;
begin
  // Wake any waiter before we tear the event down.
  if FDataReadyEvent <> nil then
    FDataReadyEvent.SetEvent;
  FWriteQueue.Free;
  FLock.Free;
  FDataReadyEvent.Free;
  inherited;
end;

function TInteractivePipeSource.WaitForData(timeoutMS : Cardinal) : Boolean;
begin
  // Returns True if data is (likely) available OR the source has been closed.
  // Caller should then call GetData to actually consume. False means the
  // wait timed out with no new data and the source is still open.
  result := FDataReadyEvent.WaitFor(timeoutMS) = wrSignaled;
end;

function TInteractivePipeSource.GetData(var data: TBytes; out dataLength: NativeUInt): boolean;
//
// M10 note - threading trade-off in this method.
//
// We currently hold FLock for the entire concat loop (lines that build
// `data` from FWriteQueue). That serialises Write() calls against the
// concat, which can throttle very high-throughput producers because Write
// must wait until the concat completes before it can append the next chunk.
//
// If that ever becomes a bottleneck, the redesign is:
//   1. Under the lock: swap the live queue with a fresh empty one (cheap)
//      and capture the count - then release the lock immediately. This
//      lets new Write() calls land in the new queue while we work.
//   2. Outside the lock: compute totalLen, allocate `data`, and Move()
//      each captured chunk into it. No producer is blocked during the
//      Move loop.
//   3. The data-ready event reset still needs the lock, but it's a single
//      Enter/Leave at the very end - much shorter critical section.
//
// We have NOT made that change because the current pattern is correct,
// simple, and the producer is bounded by stdin writer throughput which
// is itself constrained by the child process's read rate. The lock-held
// time is microseconds in the common case. Revisit only if profiling
// shows real contention.
//
var
  i: Integer;
  totalLen: Integer;
  offset: Integer;
begin
  FLock.Enter;
  try
    // If queue is empty and closed, we're done
    if (FWriteQueue.Count = 0) and FClosed then
    begin
      dataLength := 0;
      result := False;  // No more data
      // Leave the data-ready event signalled so any blocked waiter wakes
      // and observes the closed state.
      Exit;
    end;

    // If queue is empty but not closed, no data yet but more may come.
    // Reset the event so the next WaitForData() blocks until Write/Close.
    if FWriteQueue.Count = 0 then
    begin
      dataLength := 0;
      result := True;  // More data may come
      FDataReadyEvent.ResetEvent;
      Exit;
    end;

    // Concatenate all queued data into single array
    totalLen := 0;
    for i := 0 to FWriteQueue.Count - 1 do
      Inc(totalLen, Length(FWriteQueue[i]));

    SetLength(data, totalLen);
    offset := 0;

    for i := 0 to FWriteQueue.Count - 1 do
    begin
      if Length(FWriteQueue[i]) > 0 then
      begin
        Move(FWriteQueue[i][0], data[offset], Length(FWriteQueue[i]));
        Inc(offset, Length(FWriteQueue[i]));
      end;
    end;

    dataLength := totalLen;
    FWriteQueue.Clear;

    // Queue is now empty; reset event so the next WaitForData blocks until
    // more data arrives (or the source is closed).
    if not FClosed then
      FDataReadyEvent.ResetEvent;

    // More data available if not closed
    result := not FClosed;
  finally
    FLock.Leave;
  end;
end;

function TInteractivePipeSource.Write(const data: TBytes): Boolean;
begin
  result := False;

  FLock.Enter;
  try
    if FClosed then
      Exit;  // Can't write after close

    if Length(data) > 0 then
    begin
      FWriteQueue.Add(Copy(data));
      result := True;
      // Wake any waiter blocked in WaitForData.
      FDataReadyEvent.SetEvent;
    end;
  finally
    FLock.Leave;
  end;
end;

function TInteractivePipeSource.Write(const text: string; const encoding: TEncoding): Boolean;
var
  bytes: TBytes;
  enc: TEncoding;
begin
  if encoding <> nil then
    enc := encoding
  else if FDefaultEncoding <> nil then
    enc := FDefaultEncoding
  else
    enc := TEncoding.UTF8;

  bytes := enc.GetBytes(text);
  result := Write(bytes);
end;

procedure TInteractivePipeSource.Close;
begin
  FLock.Enter;
  try
    FClosed := True;
    // Wake any waiter so it can observe the closed state and exit cleanly.
    FDataReadyEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TInteractivePipeSource.HasExplicitEncoding: boolean;
begin
  result := false;
end;

procedure TInteractivePipeSource.SetDefaultEncoding(const value: TEncoding);
begin
  FDefaultEncoding := value;
end;

procedure TInteractivePipeSource.Done;
begin
  // An injected default belongs to this run only: the next run may inject a
  // different one, or none, and this one may since have been freed.
  FLock.Enter;
  try
    FDefaultEncoding := nil;
  finally
    FLock.Leave;
  end;
end;

function TInteractivePipeSource.IsClosed: Boolean;
begin
  FLock.Enter;
  try
    result := FClosed;
  finally
    FLock.Leave;
  end;
end;

{ TFileStdInPipeSource }

constructor TFileStdInPipeSource.Create(const fileName : string);
begin
  inherited Create;
  FFileName := fileName;
end;

destructor TFileStdInPipeSource.Destroy;
begin
  FreeAndNil(FFileStream);
  inherited;
end;

procedure TFileStdInPipeSource.Start;
begin
  FreeAndNil(FFileStream);
  if not FileExists(FFileName) then
    raise EVSoftProcessError.Create('Stdin source file not found: ' + FFileName);
  // Shared with writers, as a shell redirect opens it: the file may be a log
  // another program is still writing.
  FFileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
end;

procedure TFileStdInPipeSource.Done;
begin
  FreeAndNil(FFileStream);
end;

function TFileStdInPipeSource.GetData(var data : TBytes; out dataLength : NativeUInt) : boolean;
begin
  dataLength := 0;
  result := false;
end;

function TFileStdInPipeSource.GetFileName : string;
begin
  result := FFileName;
end;

function TFileStdInPipeSource.GetFileHandle : THandle;
begin
  if FFileStream <> nil then
    result := FFileStream.Handle
  else
    result := 0;
end;

{ TFilePipeSource }

constructor TFilePipeSource.Create(const fileName: string);
begin
  inherited Create;
  FFileName := fileName;
end;

destructor TFilePipeSource.Destroy;
begin
  FreeAndNil(FFileStream);
  inherited;
end;

procedure TFilePipeSource.Start;
begin
  FreeAndNil(FFileStream);
  if not FileExists(FFileName) then
    raise EVSoftProcessError.Create('Stdin source file not found: ' + FFileName);
  // Shared with writers, as a shell redirect opens it: the file may be a log
  // another program is still writing.
  FFileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
end;

procedure TFilePipeSource.Done;
begin
  FreeAndNil(FFileStream);
end;

function TFilePipeSource.GetData(var data: TBytes; out dataLength: NativeUInt): boolean;
var
  bytesRead : integer;
begin
  dataLength := 0;
  result := False;
  if FFileStream = nil then
    exit;
  SetLength(data, cSourceChunkSize);
  bytesRead := FFileStream.Read(data[0], cSourceChunkSize);
  if bytesRead <= 0 then
  begin
    FreeAndNil(FFileStream);
    exit;
  end;
  dataLength := bytesRead;
  result := True;
end;

{ TStreamPipeSource }

constructor TStreamPipeSource.Create(const stream: TStream; ownsStream: Boolean);
begin
  inherited Create;
  FStream := stream;
  FOwnsStream := ownsStream;
  FStartPositionKnown := False;
end;

destructor TStreamPipeSource.Destroy;
begin
  if FOwnsStream and (FStream <> nil) then
    FStream.Free;
  inherited;
end;

procedure TStreamPipeSource.Start;
begin
  if FStream = nil then
    exit;
  // Non-seekable streams (pipes, sockets) raise from Position; they are
  // simply read from wherever they are.
  try
    if FStartPositionKnown then
      FStream.Position := FStartPosition
    else
    begin
      FStartPosition := FStream.Position;
      FStartPositionKnown := True;
    end;
  except
    on EStreamError do
      FStartPositionKnown := False;
  end;
end;

function TStreamPipeSource.GetData(var data: TBytes; out dataLength: NativeUInt): boolean;
var
  bytesRead : integer;
begin
  dataLength := 0;
  result := False;
  if FStream = nil then
    exit;
  SetLength(data, cSourceChunkSize);
  bytesRead := FStream.Read(data[0], cSourceChunkSize);
  if bytesRead <= 0 then
    exit;
  dataLength := bytesRead;
  result := True;
end;

end.
