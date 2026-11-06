unit VSoft.Process.PipeTarget.Classes;

interface

uses
  System.Classes,
  System.SysUtils,
  VSoft.Process;

type
  TPipeTargetBase = class(TInterfacedObject, IPipeTarget)
  protected
    procedure HandleData(const data : TBytes; length : NativeUInt);virtual;abstract;
    procedure Start;virtual;
    procedure Done;virtual;
  end;

  TStreamPipeTarget = class(TPipeTargetBase)
  private
    FStream : TStream;
  public
    constructor Create(const stream : TStream);
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
  end;

  TFilePipeTarget = class(TPipeTargetBase)
  private
    FFileName : string;
    FAppend : Boolean;
    FFileStream : TFileStream;
    // Start/Done are reference counted so one target can be attached to
    // several streams (e.g. nested inside two TPipeTarget.ToAll targets).
    FStartCount : integer;
  public
    constructor Create(const fileName : string; append : boolean);
    destructor Destroy;override;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
    procedure Start;override;
    procedure Done;override;
  end;

  TLinePipeTargetBase = class(TPipeTargetBase, IEncodingAwarePipeTarget, IStreamAwarePipeTarget)
  private
    type
      // One per stream, so a target attached to both stdout and stderr never
      // joins a partial line of one to the other.
      TStreamState = record
        CurrentLine : string;
        // Bytes received after the last LF. Only text up to an LF is decoded,
        // so a multi-byte sequence split across two pipe reads is decoded
        // intact (0x0A never occurs inside a UTF-8 or DBCS character). For
        // UTF-16 the LF is the code unit $000A at an even offset.
        PendingBytes : TBytes;
      end;
    var
      FEncoding : TEncoding;
      // True when the caller passed a non-nil encoding to the constructor.
      // Used by SetDefaultEncoding to refuse to overwrite an explicit choice.
      FEncodingExplicit : boolean;
      // Indexed by isStdErr; HandleData counts as stdout.
      FStreams : array[boolean] of TStreamState;
      // Set by Start from the encoding: 1 for byte encodings, 2 for UTF-16.
      FUnitSize : integer;
      FBigEndian : boolean;
      // The stream HandleStreamData is delivering, so the default HandleData
      // (and an override that calls inherited) files the bytes under it.
      FDispatchStdErr : boolean;
    procedure ProcessStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    function LastLineFeedEnd(const bytes : TBytes; fromPos : NativeUInt; totalLen : NativeUInt) : NativeInt;
    procedure ProcessText(var state : TStreamState; var text : string);
    procedure FlushStream(var state : TStreamState);
  protected
    procedure OutputLine(const line : string);virtual;abstract;

    procedure Start;override;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
    procedure HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    procedure Done;override;

    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
    // True while HandleStreamData is delivering stderr, so a HandleData
    // override can tell which stream its bytes belong to.
    property DispatchingStdErr : boolean read FDispatchStdErr;
  public
    constructor Create(const encoding : TEncoding);
  end;

  TLineDelegatePipeTarget = class(TLinePipeTargetBase)
  private
    FDelegate : TPipeTargetLineDelegate;
  protected
    procedure OutputLine(const line : string);override;
  public
    constructor Create(const delegate : TPipeTargetLineDelegate; const encoding : TEncoding);
  end;

  TLineMethodPipeTarget = class(TLinePipeTargetBase)
  private
    FMethod : TPipeTargetLineMethod;
  protected
    procedure OutputLine(const line : string);override;
  public
    constructor Create(const method  : TPipeTargetLineMethod; const encoding : TEncoding);
  end;

  TLineProcedurePipeTarget = class(TLinePipeTargetBase)
  private
    FProc : TPipeTargetLineProcedure;
  protected
    procedure OutputLine(const line : string);override;
  public
    constructor Create(const proc  : TPipeTargetLineProcedure; const encoding : TEncoding);
  end;


  TDelegatePipeTarget = class(TPipeTargetBase)
  private
    FDelegate : TPipeTargetDelegate;
  protected
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
  public
    constructor Create(const delegate : TPipeTargetDelegate);
  end;

  TMethodPipeTarget = class(TPipeTargetBase)
  private
    FMethod : TPipeTargetMethod;
  protected
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
  public
    constructor Create(const method : TPipeTargetMethod);
  end;

  TProcedurePipeTarget = class(TPipeTargetBase)
  private
    FProc : TPipeTargetProcedure;
  protected
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
  public
    constructor Create(const proc : TPipeTargetProcedure);
  end;

  TStringBuilderPipeTarget = class(TPipeTargetBase, IEncodingAwarePipeTarget, IStreamAwarePipeTarget)
  private
    FStringBuilder : TStringBuilder;
    FEncoding : TEncoding;
    FEncodingExplicit : boolean;
    // Trailing bytes of an incomplete character, carried to the next read.
    // Indexed by isStdErr, so one stream's character is never completed by
    // the other's bytes; HandleData counts as stdout.
    FPendingBytes : array[boolean] of TBytes;
    // The stream HandleStreamData is delivering (see TLinePipeTargetBase).
    FDispatchStdErr : boolean;
    procedure ProcessStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    procedure AppendText(const s : string);
  protected
    procedure Start;override;
    procedure HandleData(const data : TBytes; length : NativeUInt);override;
    procedure HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    procedure Done;override;

    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
    // True while HandleStreamData is delivering stderr, so a HandleData
    // override can tell which stream its bytes belong to.
    property DispatchingStdErr : boolean read FDispatchStdErr;
  public
    constructor Create(const stringBuilder : TStringBuilder; const encoding : TEncoding);
  end;

  TMultiPipeTarget = class(TPipeTargetBase, IEncodingAwarePipeTarget, IStreamAwarePipeTarget)
  private
    FTargets : TArray<IPipeTarget>;
  protected
    procedure Start;override;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);override;
    // Passes the stream on to every contained target that is stream aware.
    procedure HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
    procedure Done;override;

    // Forwarded to every contained target that is encoding aware.
    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
  public
    constructor Create(const targets : array of IPipeTarget);
  end;

// Number of leading bytes of data[0..dataLength-1] that end on a character
// boundary for the given encoding, so they can be decoded without splitting a
// multi-byte sequence. The remainder must be carried to the next read.
function CompleteCharLength(const encoding : TEncoding; const data : TBytes; dataLength : integer) : integer;

// Decodes count bytes from data[index] without ever raising: each sequence
// that is not valid in the encoding becomes U+FFFD. Windows decodes through
// MultiByteToWideChar (without MB_ERR_INVALID_CHARS), POSIX decodes UTF-8
// itself. UTF-16 is decoded directly; a dangling odd byte becomes U+FFFD.
function DecodeLenient(const encoding : TEncoding; const data : TBytes; index : integer; count : integer) : string;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SyncObjs;

const
  CP_UTF8_VALUE = 65001;
  CP_UTF16LE = 1200;
  CP_UTF16BE = 1201;

function Utf8CompleteLength(const data : TBytes; dataLength : integer) : integer;
var
  i : integer;
  lead : Byte;
  need : integer;
begin
  result := dataLength;
  if dataLength = 0 then
    exit;
  // Walk back over at most 3 continuation bytes to the lead byte of the last
  // character, then check that the whole sequence is present.
  i := dataLength - 1;
  while (i > 0) and (dataLength - i < 4) and ((data[i] and $C0) = $80) do
    Dec(i);
  lead := data[i];
  if lead < $80 then
    need := 1
  else if (lead and $E0) = $C0 then
    need := 2
  else if (lead and $F0) = $E0 then
    need := 3
  else if (lead and $F8) = $F0 then
    need := 4
  else
    need := 1; // invalid lead byte - let the decoder replace it
  if i + need > dataLength then
    result := i;
end;

function Utf16CompleteLength(const data : TBytes; dataLength : integer; bigEndian : boolean) : integer;
var
  lastUnit : Word;
begin
  result := dataLength and not 1;
  if result >= 2 then
  begin
    if bigEndian then
      lastUnit := (Word(data[result - 2]) shl 8) or data[result - 1]
    else
      lastUnit := (Word(data[result - 1]) shl 8) or data[result - 2];
    // A trailing high surrogate needs its low surrogate from the next read.
    if (lastUnit >= $D800) and (lastUnit <= $DBFF) then
      Dec(result, 2);
  end;
end;

function DecodeUtf16Lenient(const data : TBytes; index : integer; count : integer; bigEndian : boolean) : string;
var
  units : integer;
  i : integer;
  p : integer;
begin
  units := count div 2;
  SetLength(result, units + (count and 1));
  for i := 1 to units do
  begin
    p := index + (i - 1) * 2;
    if bigEndian then
      result[i] := Char((Word(data[p]) shl 8) or data[p + 1])
    else
      result[i] := Char((Word(data[p + 1]) shl 8) or data[p]);
  end;
  if (count and 1) <> 0 then
    result[units + 1] := #$FFFD;
end;

{$IFNDEF MSWINDOWS}
// UTF-8 with each maximal subpart of an ill-formed sequence replaced by one
// U+FFFD (the Unicode recommended practice, which Windows also follows).
function DecodeUtf8Lenient(const data : TBytes; index : integer; count : integer) : string;
var
  i : integer;
  last : integer;
  outLen : integer;
  b : Byte;
  need : integer;
  got : integer;
  codePoint : Cardinal;
  lower : Byte;
  upper : Byte;
begin
  // Never more UTF-16 code units than bytes.
  SetLength(result, count);
  outLen := 0;
  i := index;
  last := index + count;
  while i < last do
  begin
    b := data[i];
    Inc(i);
    if b < $80 then
    begin
      Inc(outLen);
      result[outLen] := Char(b);
      Continue;
    end;
    lower := $80;
    upper := $BF;
    codePoint := 0;
    case b of
      $C2..$DF : need := 1;
      $E0 :
        begin
          need := 2;
          lower := $A0;
        end;
      $E1..$EC, $EE, $EF : need := 2;
      $ED :
        begin
          need := 2;
          upper := $9F;
        end;
      $F0 :
        begin
          need := 3;
          lower := $90;
        end;
      $F1..$F3 : need := 3;
      $F4 :
        begin
          need := 3;
          upper := $8F;
        end;
    else
      need := 0;
    end;
    case need of
      1 : codePoint := b and $1F;
      2 : codePoint := b and $0F;
      3 : codePoint := b and $07;
    end;
    got := 0;
    while (got < need) and (i < last) and (data[i] >= lower) and (data[i] <= upper) do
    begin
      codePoint := (codePoint shl 6) or (data[i] and $3F);
      lower := $80;
      upper := $BF;
      Inc(i);
      Inc(got);
    end;
    if (need = 0) or (got < need) then
    begin
      Inc(outLen);
      result[outLen] := #$FFFD;
    end
    else if codePoint >= $10000 then
    begin
      Dec(codePoint, $10000);
      Inc(outLen);
      result[outLen] := Char($D800 + (codePoint shr 10));
      Inc(outLen);
      result[outLen] := Char($DC00 + (codePoint and $3FF));
    end
    else
    begin
      Inc(outLen);
      result[outLen] := Char(codePoint);
    end;
  end;
  SetLength(result, outLen);
end;
{$ENDIF}

// Last resort for an encoding that rejects the bytes: ASCII is kept and every
// other byte becomes U+FFFD.
function DecodeAsciiLenient(const data : TBytes; index : integer; count : integer) : string;
var
  i : integer;
begin
  SetLength(result, count);
  for i := 1 to count do
    if data[index + i - 1] < $80 then
      result[i] := Char(data[index + i - 1])
    else
      result[i] := #$FFFD;
end;

function DecodeLenient(const encoding : TEncoding; const data : TBytes; index : integer; count : integer) : string;
{$IFDEF MSWINDOWS}
var
  len : integer;
{$ENDIF}
begin
  result := '';
  if count <= 0 then
    exit;
  case encoding.CodePage of
    CP_UTF16LE : result := DecodeUtf16Lenient(data, index, count, false);
    CP_UTF16BE : result := DecodeUtf16Lenient(data, index, count, true);
  else
    {$IFDEF MSWINDOWS}
    len := MultiByteToWideChar(encoding.CodePage, 0, PAnsiChar(@data[index]), count, nil, 0);
    if len > 0 then
    begin
      SetLength(result, len);
      MultiByteToWideChar(encoding.CodePage, 0, PAnsiChar(@data[index]), count, PWideChar(result), len);
      exit;
    end;
    {$ELSE}
    if encoding.CodePage = CP_UTF8_VALUE then
      exit(DecodeUtf8Lenient(data, index, count));
    {$ENDIF}
    // A code page the platform cannot convert (a custom TEncoding).
    try
      result := encoding.GetString(data, index, count);
    except
      on EEncodingError do
        result := DecodeAsciiLenient(data, index, count);
    end;
  end;
end;

function CompleteCharLength(const encoding : TEncoding; const data : TBytes; dataLength : integer) : integer;
{$IFDEF MSWINDOWS}
var
  i : integer;
  codePage : Cardinal;
{$ENDIF}
begin
  result := dataLength;
  if (encoding = nil) or (dataLength <= 0) then
    exit;
  case encoding.CodePage of
    CP_UTF8_VALUE : result := Utf8CompleteLength(data, dataLength);
    CP_UTF16LE    : result := Utf16CompleteLength(data, dataLength, false);
    CP_UTF16BE    : result := Utf16CompleteLength(data, dataLength, true);
  else
    {$IFDEF MSWINDOWS}
    // DBCS code pages (Shift-JIS, GBK, Big5, ...): walk from the start (which
    // is always a character boundary) and stop before a dangling lead byte.
    if encoding.IsSingleByte then
      exit;
    codePage := encoding.CodePage;
    i := 0;
    while i < dataLength do
    begin
      if IsDBCSLeadByteEx(codePage, data[i]) then
      begin
        if i + 1 >= dataLength then
        begin
          result := i;
          exit;
        end;
        Inc(i, 2);
      end
      else
        Inc(i);
    end;
    {$ENDIF}
  end;
end;

{ TStreamPipeTarget }

constructor TStreamPipeTarget.Create(const stream: TStream);
begin
  inherited Create;
  if stream = nil then
    raise EArgumentNilException.Create('stream');
  FStream := stream;
end;

procedure TStreamPipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  if dataLength > 0 then
    FStream.WriteBuffer(data[0], dataLength);
end;

{ TFilePipeTarget }

constructor TFilePipeTarget.Create(const fileName: string; append : boolean);
begin
  inherited Create;
  FFileName := fileName;
  FAppend := append;
end;

destructor TFilePipeTarget.Destroy;
begin
  // Guard against Start without matching Done (e.g. process raised mid-execution)
  FreeAndNil(FFileStream);
  inherited;
end;

procedure TFilePipeTarget.Done;
begin
  if FStartCount > 0 then
    Dec(FStartCount);
  if FStartCount = 0 then
    FreeAndNil(FFileStream);
end;

procedure TFilePipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  if (dataLength > 0) and (FFileStream <> nil) then
    FFileStream.WriteBuffer(data[0], dataLength);
end;

procedure TFilePipeTarget.Start;
begin
  Inc(FStartCount);
  if FFileStream <> nil then
    exit;
  try
    if FAppend and FileExists(FFileName) then
    begin
      // Read/write, not write only: on POSIX fmShareDenyWrite is a read lock,
      // which needs a descriptor open for reading (EBADF on macOS otherwise).
      FFileStream := TFileStream.Create(FFileName, fmOpenReadWrite or fmShareDenyWrite);
      FFileStream.Seek(0, soEnd);
    end
    else
      FFileStream := TFileStream.Create(FFileName, fmCreate or fmShareDenyWrite);
  except
    Dec(FStartCount);
    raise;
  end;
end;

{ TLineDelegatePipeTarget }

constructor TLineDelegatePipeTarget.Create(const delegate: TPipeTargetLineDelegate; const encoding : TEncoding);
begin
  inherited Create(encoding);
  FDelegate := delegate;
end;

procedure TLineDelegatePipeTarget.OutputLine(const line: string);
begin
  FDelegate(line);
end;

{ TStringBuilderPipeTarget }

constructor TStringBuilderPipeTarget.Create(const stringBuilder: TStringBuilder; const encoding: TEncoding);
begin
  inherited Create;
  if stringBuilder = nil then
    raise EArgumentNilException.Create('stringBuilder');
  FStringBuilder := stringBuilder;
  // Keep nil so the process can inject StartInfo.OutputEncoding via
  // SetDefaultEncoding before Start; Start falls back to TEncoding.Default.
  FEncoding := encoding;
  FEncodingExplicit := encoding <> nil;
end;

procedure TStringBuilderPipeTarget.AppendText(const s : string);
begin
  if s = '' then
    exit;
  // The builder belongs to the caller, who may read it from another thread.
  MonitorEnter(FStringBuilder);
  try
    FStringBuilder.Append(s);
  finally
    MonitorExit(FStringBuilder);
  end;
end;

procedure TStringBuilderPipeTarget.Done;
var
  isStdErr : boolean;
begin
  // Flush an incomplete trailing sequence (the stream ended mid-character).
  for isStdErr := false to true do
  begin
    if Length(FPendingBytes[isStdErr]) > 0 then
    begin
      AppendText(DecodeLenient(FEncoding, FPendingBytes[isStdErr], 0, Length(FPendingBytes[isStdErr])));
      SetLength(FPendingBytes[isStdErr], 0);
    end;
  end;
end;

procedure TStringBuilderPipeTarget.HandleData(const data: TBytes; length: NativeUInt);
begin
  ProcessStreamData(FDispatchStdErr, data, length);
end;

procedure TStringBuilderPipeTarget.HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
begin
  FDispatchStdErr := isStdErr;
  try
    HandleData(data, dataLength);
  finally
    FDispatchStdErr := false;
  end;
end;

procedure TStringBuilderPipeTarget.ProcessStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
var
  tailLen : integer;
  totalLen : integer;
  bytes : TBytes;
  decodeLen : integer;
begin
  if dataLength = 0 then
    exit;
  tailLen := Length(FPendingBytes[isStdErr]);
  totalLen := tailLen + Integer(dataLength);
  SetLength(bytes, totalLen);
  if tailLen > 0 then
    Move(FPendingBytes[isStdErr][0], bytes[0], tailLen);
  Move(data[0], bytes[tailLen], dataLength);

  decodeLen := CompleteCharLength(FEncoding, bytes, totalLen);
  if decodeLen > 0 then
    AppendText(DecodeLenient(FEncoding, bytes, 0, decodeLen));
  SetLength(FPendingBytes[isStdErr], totalLen - decodeLen);
  if totalLen > decodeLen then
    Move(bytes[decodeLen], FPendingBytes[isStdErr][0], totalLen - decodeLen);
end;

procedure TStringBuilderPipeTarget.Start;
begin
  if FEncoding = nil then
    FEncoding := TEncoding.Default;
  SetLength(FPendingBytes[false], 0);
  SetLength(FPendingBytes[true], 0);
  MonitorEnter(FStringBuilder);
  try
    FStringBuilder.Clear;
  finally
    MonitorExit(FStringBuilder);
  end;
end;

function TStringBuilderPipeTarget.HasExplicitEncoding: boolean;
begin
  result := FEncodingExplicit;
end;

procedure TStringBuilderPipeTarget.SetDefaultEncoding(const value: TEncoding);
begin
  if not FEncodingExplicit then
    FEncoding := value;
end;

{ TPipeTargetBase }

procedure TPipeTargetBase.Done;
begin
  //do nothing by default
end;

procedure TPipeTargetBase.Start;
begin
  //do nothing by default
end;

{ TLinePipeTargetBase }

constructor TLinePipeTargetBase.Create(const encoding: TEncoding);
begin
  inherited Create;
  // Keep nil until Start so the process can inject StartInfo.OutputEncoding
  // as a default via SetDefaultEncoding when the caller didn't supply one.
  FEncoding := encoding;
  FEncodingExplicit := encoding <> nil;
end;

function TLinePipeTargetBase.HasExplicitEncoding: boolean;
begin
  result := FEncodingExplicit;
end;

procedure TLinePipeTargetBase.SetDefaultEncoding(const value: TEncoding);
begin
  if not FEncodingExplicit then
    FEncoding := value;
end;

procedure TLinePipeTargetBase.ProcessText(var state : TStreamState; var text : string);
var
  i : integer;
  j : integer;
  textLen : integer;
  start : integer;
  len : integer;

  procedure FlushSpan;
  begin
    if len > 0 then
      state.CurrentLine := state.CurrentLine + Copy(text, start, len);
    len := 0;
  end;

begin
  // This is a line-oriented target intended for plain-text output (logs,
  // CLI tool stdout). It rewrites/strips low ASCII control characters so
  // binary noise can't break a log file or the receiving line delegate:
  //   * #0 (NUL) becomes a space.
  //   * #1..#8, #11, #12, #14..#31 are dropped - this includes ANSI ESC
  //     (#27), so colour codes are lost.
  //   * LF ends a line, and so does a run of CRs followed by LF (CRLF, or
  //     CR CR LF from a CRLF written through a text-mode stream); the CRs are
  //     not part of the line. A CR that is not followed by LF (progress
  //     output) is kept in the line text. TAB is kept.
  // Use the byte-oriented targets (ToDelegate/ToStream/ToFile) for
  // binary-safe capture.
  textLen := Length(text);
  start := 1;
  len := 0;
  i := 1;
  while i <= textLen do
  begin
    case text[i] of
      #0:
        begin
          text[i] := ' ';
          Inc(len);
        end;
      #1..#8, #11, #12, #14..#31:
        begin
          FlushSpan;
          start := i + 1;
        end;
      #10:
        begin
          FlushSpan;
          OutputLine(state.CurrentLine);
          state.CurrentLine := '';
          start := i + 1;
        end;
      #13:
        begin
          j := i;
          while (j < textLen) and (text[j + 1] = #13) do
            Inc(j);
          if (j < textLen) and (text[j + 1] = #10) then
          begin
            FlushSpan;
            OutputLine(state.CurrentLine);
            state.CurrentLine := '';
            i := j + 1; // the LF
            start := i + 1;
          end
          else
          begin
            Inc(len, j - i + 1);
            i := j;
          end;
        end;
    else
      Inc(len);
    end;
    Inc(i);
  end;
  FlushSpan;
end;

procedure TLinePipeTargetBase.FlushStream(var state : TStreamState);
var
  remainder : string;
  lineLen : integer;
begin
  // Flush any byte tail that never saw a final line terminator.
  if Length(state.PendingBytes) > 0 then
  begin
    if FEncoding = nil then
      FEncoding := TEncoding.Default;
    remainder := DecodeLenient(FEncoding, state.PendingBytes, 0, Length(state.PendingBytes));
    SetLength(state.PendingBytes, 0);
    ProcessText(state, remainder);
  end;
  // Output that ends with CRs has no LF to complete the line ending.
  lineLen := Length(state.CurrentLine);
  while (lineLen > 0) and (state.CurrentLine[lineLen] = #13) do
    Dec(lineLen);
  SetLength(state.CurrentLine, lineLen);
  if state.CurrentLine <> '' then
    OutputLine(state.CurrentLine);
  state.CurrentLine := '';
end;

procedure TLinePipeTargetBase.Done;
begin
  FlushStream(FStreams[false]);
  FlushStream(FStreams[true]);
end;

function TLinePipeTargetBase.LastLineFeedEnd(const bytes : TBytes; fromPos : NativeUInt; totalLen : NativeUInt) : NativeInt;
var
  scanPos : NativeUInt;
begin
  // Number of bytes up to and including the last LF in
  // bytes[fromPos..totalLen-1], or -1 when there is none.
  result := -1;
  if FUnitSize = 1 then
  begin
    scanPos := totalLen;
    while scanPos > fromPos do
    begin
      Dec(scanPos);
      if bytes[scanPos] = $0A then
        Exit(scanPos + 1);
    end;
  end
  else
  begin
    // The pending bytes always start on a code unit boundary.
    fromPos := fromPos and not NativeUInt(1);
    scanPos := totalLen and not NativeUInt(1);
    while scanPos > fromPos do
    begin
      Dec(scanPos, 2);
      if FBigEndian then
      begin
        if (bytes[scanPos] = 0) and (bytes[scanPos + 1] = $0A) then
          Exit(scanPos + 2);
      end
      else if (bytes[scanPos] = $0A) and (bytes[scanPos + 1] = 0) then
        Exit(scanPos + 2);
    end;
  end;
end;

procedure TLinePipeTargetBase.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  ProcessStreamData(FDispatchStdErr, data, dataLength);
end;

procedure TLinePipeTargetBase.HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
begin
  // Through the virtual HandleData, so a subclass overriding it still sees
  // the bytes of both streams.
  FDispatchStdErr := isStdErr;
  try
    HandleData(data, dataLength);
  finally
    FDispatchStdErr := false;
  end;
end;

procedure TLinePipeTargetBase.ProcessStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
var
  tailLen : NativeUInt;
  totalLen : NativeUInt;
  lineEnd : NativeInt;
  decodeLen : NativeUInt;
  decoded : string;
begin
  if dataLength = 0 then
    Exit;

  // Append the new bytes to whatever tail was left from the previous call.
  tailLen := Length(FStreams[isStdErr].PendingBytes);
  totalLen := tailLen + dataLength;
  SetLength(FStreams[isStdErr].PendingBytes, totalLen);
  Move(data[0], FStreams[isStdErr].PendingBytes[tailLen], dataLength);

  // Find the last LF. The previous tail never contains one, so only the
  // newly appended bytes need scanning.
  lineEnd := LastLineFeedEnd(FStreams[isStdErr].PendingBytes, tailLen, totalLen);
  if lineEnd < 0 then
    // No newline yet - keep the entire buffer for the next call.
    Exit;

  // Decode everything up to and including the last LF and keep the rest.
  decodeLen := NativeUInt(lineEnd);
  decoded := DecodeLenient(FEncoding, FStreams[isStdErr].PendingBytes, 0, decodeLen);
  if decodeLen < totalLen then
  begin
    Move(FStreams[isStdErr].PendingBytes[decodeLen], FStreams[isStdErr].PendingBytes[0], totalLen - decodeLen);
    SetLength(FStreams[isStdErr].PendingBytes, totalLen - decodeLen);
  end
  else
    SetLength(FStreams[isStdErr].PendingBytes, 0);

  ProcessText(FStreams[isStdErr], decoded);
end;

procedure TLinePipeTargetBase.Start;
begin
  if FEncoding = nil then
    FEncoding := TEncoding.Default;
  FUnitSize := 1;
  FBigEndian := FEncoding.CodePage = CP_UTF16BE;
  if FBigEndian or (FEncoding.CodePage = CP_UTF16LE) then
    FUnitSize := 2;
  FStreams[false].CurrentLine := '';
  SetLength(FStreams[false].PendingBytes, 0);
  FStreams[true].CurrentLine := '';
  SetLength(FStreams[true].PendingBytes, 0);
end;

{ TLineMethodPipeTarget }

constructor TLineMethodPipeTarget.Create(const method: TPipeTargetLineMethod; const encoding: TEncoding);
begin
  inherited Create(encoding);
  FMethod := method;
end;

procedure TLineMethodPipeTarget.OutputLine(const line: string);
begin
  FMethod(line);
end;

{ TDelegatePipeTarget }

constructor TDelegatePipeTarget.Create(const delegate: TPipeTargetDelegate);
begin
  inherited Create;
  FDelegate := delegate;
end;

procedure TDelegatePipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  FDelegate(data, dataLength);
end;

{ TMethodPipeTarget }

constructor TMethodPipeTarget.Create(const method: TPipeTargetMethod);
begin
  inherited Create;
  FMethod := method;
end;

procedure TMethodPipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  FMethod(data, dataLength);
end;

{ TLineProcedurePipeTarget }

constructor TLineProcedurePipeTarget.Create(const proc: TPipeTargetLineProcedure; const encoding: TEncoding);
begin
  inherited Create(encoding);
  FProc := proc;
end;

procedure TLineProcedurePipeTarget.OutputLine(const line: string);
begin
  FProc(line);
end;

{ TProcedurePipeTarget }

constructor TProcedurePipeTarget.Create(const proc: TPipeTargetProcedure);
begin
  inherited Create;
  FProc := proc;
end;

procedure TProcedurePipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
begin
  FProc(data, dataLength);
end;

{ TMultiPipeTarget }

constructor TMultiPipeTarget.Create(const targets: array of IPipeTarget);
var
  i : integer;
begin
  inherited Create;
  SetLength(FTargets, Length(targets));
  for i := 0 to High(targets) do
    FTargets[i] := targets[i];
end;

procedure TMultiPipeTarget.Start;
var
  i: Integer;
begin
  for i := 0 to Length(FTargets) - 1 do
    FTargets[i].Start;
end;

procedure TMultiPipeTarget.HandleData(const data: TBytes; dataLength: NativeUInt);
var
  i: Integer;
begin
  for i := 0 to Length(FTargets) - 1 do
    FTargets[i].HandleData(data, dataLength);
end;

procedure TMultiPipeTarget.HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
var
  i : integer;
  streamAware : IStreamAwarePipeTarget;
begin
  for i := 0 to Length(FTargets) - 1 do
  begin
    if Supports(FTargets[i], IStreamAwarePipeTarget, streamAware) then
      streamAware.HandleStreamData(isStdErr, data, dataLength)
    else
      FTargets[i].HandleData(data, dataLength);
  end;
end;

function TMultiPipeTarget.HasExplicitEncoding: boolean;
begin
  result := false;
end;

procedure TMultiPipeTarget.SetDefaultEncoding(const value: TEncoding);
var
  i : integer;
  aware : IEncodingAwarePipeTarget;
begin
  for i := 0 to Length(FTargets) - 1 do
    if Supports(FTargets[i], IEncodingAwarePipeTarget, aware) then
      aware.SetDefaultEncoding(value);
end;

procedure TMultiPipeTarget.Done;
var
  i: Integer;
  firstError : TObject;
begin
  // Every contained target gets its Done even if an earlier one raises.
  firstError := nil;
  for i := 0 to Length(FTargets) - 1 do
  begin
    try
      FTargets[i].Done;
    except
      if firstError = nil then
        firstError := TObject(AcquireExceptionObject);
    end;
  end;
  if firstError <> nil then
    raise firstError;
end;

end.
