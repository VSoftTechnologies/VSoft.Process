program PipeTargets;

// Demonstrates every shape of IPipeTarget VSoft.Process ships with by
// running the same short command (cmd /c set) several times, each time
// wired to a different capture mechanism. The deterministic, modest-sized
// output makes each section's summary easy to eyeball.
//
// Sections:
//   1. ToStringBuilder           - accumulate text into a TStringBuilder
//   2. ToFile                    - stream bytes straight to disk
//   3. ToStream                  - stream bytes to any TStream (here a TMemoryStream)
//   4. ToLineProcedure           - per-line callback via global procedure
//   5. ToLineDelegate            - per-line callback via anonymous method
//   6. ToProcedure (raw bytes)   - byte-level callback, no decoding
//   7. ToAll                     - fan-out to multiple targets at once
//   8. Stdout + stderr separately - two pipes, one per stream

{$APPTYPE CONSOLE}

{$R *.res}

uses
  WinApi.Windows,
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  System.IOUtils,
  System.Math,
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

// --- Demo plumbing ----------------------------------------------------------

var
  // cmd.exe writes to a pipe in the console's OEM code page, which is not
  // TEncoding.Default (the ANSI code page) - e.g. 850 against 1252.
  GConsoleEncoding : TEncoding;

function CmdExePath : string;
begin
  result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) +
            'System32\cmd.exe';
end;

// Spawn cmd.exe with the supplied tail and let the caller wire pipes via
// `configure`. Returns (exit code, elapsed ms) via out params. The caller
// owns the IProcess only for the lifetime of this call.
procedure RunCmd(const tail : string;
                 const configure : TConstProc<IProcess>;
                 out exitCode : Cardinal;
                 out elapsedMs : Int64);
var
  proc : IProcess;
  sw   : TStopwatch;
  i    : Integer;
begin
  proc := TProcess.Create;
  proc.StartInfo.Executable := CmdExePath;
  proc.StartInfo.HideWindow := True;
  proc.StartInfo.TimeoutInMSec := 5000;
  proc.CommandLine.Add('/c');
  proc.CommandLine.Add(tail, TQuoted.qtNone);
  if Assigned(configure) then
    configure(proc);
  sw := TStopwatch.StartNew;
  if not proc.Execute(nil) then
    WriteLn('  ! cmd.exe could not be started');
  sw.Stop;
  if proc.TimedOut then
    WriteLn('  ! timed out after 5 seconds: the output is partial');
  for i := 0 to proc.Errors.Count - 1 do
    WriteLn('  ! ' + proc.Errors[i]);
  exitCode := proc.ExitCode;
  elapsedMs := sw.ElapsedMilliseconds;
end;

procedure PrintHeader(const title : string);
begin
  WriteLn;
  WriteLn(StringOfChar('-', 70));
  WriteLn('  ' + title);
  WriteLn(StringOfChar('-', 70));
end;

procedure PrintResult(const summary : string;
                      const exitCode : Cardinal;
                      const elapsedMs : Int64);
begin
  WriteLn(Format('  > %s  [exit=%d, %dms]', [summary, exitCode, elapsedMs]));
end;

function SizeOfFile(const fileName : string) : Int64;
var
  stream : TFileStream;
begin
  stream := TFileStream.Create(fileName, fmOpenRead or fmShareDenyNone);
  try
    result := stream.Size;
  finally
    stream.Free;
  end;
end;

// --- 1. ToStringBuilder -----------------------------------------------------

procedure Demo_ToStringBuilder;
var
  sb        : TStringBuilder;
  exitCode  : Cardinal;
  elapsedMs : Int64;
  lines     : TStringList;
  firstLine : string;
  lastLine  : string;
begin
  PrintHeader('1. TPipeTarget.ToStringBuilder');
  lines := nil;
  sb := TStringBuilder.Create;
  try
    RunCmd('set',
      procedure(const proc : IProcess)
      begin
        // GConsoleEncoding is the console's OEM code page, which cmd.exe
        // writes. Passing nil would decode with StartInfo.OutputEncoding
        // or, when that is not set, TEncoding.Default (the ANSI code page).
        proc.WithStdOutPipe(
          TPipeTarget.ToStringBuilder(sb, GConsoleEncoding));
      end, exitCode, elapsedMs);

    lines := TStringList.Create;
    lines.Text := sb.ToString;
    if lines.Count > 0 then
    begin
      firstLine := lines[0];
      lastLine  := lines[lines.Count - 1];
    end
    else
    begin
      firstLine := '<no output>';
      lastLine  := '<no output>';
    end;
    PrintResult(Format('captured %d chars, %d lines (first=%s, last=%s)',
                       [sb.Length, lines.Count, firstLine, lastLine]),
                exitCode, elapsedMs);
  finally
    lines.Free;
    sb.Free;
  end;
end;

// --- 2. ToFile --------------------------------------------------------------

procedure Demo_ToFile;
var
  tempFile  : string;
  exitCode  : Cardinal;
  elapsedMs : Int64;
  size      : Int64;
begin
  PrintHeader('2. TPipeTarget.ToFile');
  tempFile := TPath.Combine(TPath.GetTempPath,
    'vsoft_proc_demo_' + IntToStr(GetTickCount) + '.txt');
  try
    RunCmd('set',
      procedure(const proc : IProcess)
      begin
        // append=False overwrites any existing file (here always fresh).
        proc.WithStdOutPipe(TPipeTarget.ToFile(tempFile, False));
      end, exitCode, elapsedMs);

    if FileExists(tempFile) then
      size := SizeOfFile(tempFile)
    else
      size := -1;
    PrintResult(Format('wrote %s (%d bytes)', [tempFile, size]),
                exitCode, elapsedMs);
  finally
    if FileExists(tempFile) then
      DeleteFile(tempFile);
  end;
end;

// --- 3. ToStream ------------------------------------------------------------

procedure Demo_ToStream;
var
  ms        : TMemoryStream;
  exitCode  : Cardinal;
  elapsedMs : Int64;
begin
  PrintHeader('3. TPipeTarget.ToStream');
  ms := TMemoryStream.Create;
  try
    RunCmd('set',
      procedure(const proc : IProcess)
      begin
        proc.WithStdOutPipe(TPipeTarget.ToStream(ms));
      end, exitCode, elapsedMs);
    PrintResult(Format('captured %d bytes into TMemoryStream', [ms.Size]),
                exitCode, elapsedMs);
  finally
    ms.Free;
  end;
end;

// --- 4. ToLineProcedure -----------------------------------------------------

var
  GLineCounter : Integer;

procedure CountLine(const line : string);
begin
  Inc(GLineCounter);
end;

procedure Demo_ToLineProcedure;
var
  exitCode  : Cardinal;
  elapsedMs : Int64;
begin
  PrintHeader('4. TPipeTarget.ToLineProcedure');
  GLineCounter := 0;
  RunCmd('set',
    procedure(const proc : IProcess)
    begin
      // Plain procedure pointer - no `of object`, no closure capture. The
      // library handles UTF-8 / CRLF / partial-line buffering for you.
      proc.WithStdOutPipe(
        TPipeTarget.ToLineProcedure(CountLine, GConsoleEncoding));
    end, exitCode, elapsedMs);
  PrintResult(Format('counted %d lines via plain procedure callback',
                     [GLineCounter]),
              exitCode, elapsedMs);
end;

// --- 5. ToLineDelegate (anonymous method) -----------------------------------

procedure Demo_ToLineDelegate;
var
  captured  : TStringList;
  exitCode  : Cardinal;
  elapsedMs : Int64;
  i         : Integer;
  preview   : string;
  target    : IPipeTarget;
begin
  PrintHeader('5. TPipeTarget.ToLineDelegate (anonymous method)');
  captured := TStringList.Create;
  try
    // The anonymous procedure can close over `captured` directly - useful
    // when you don't want a global or an `of object` method. The target is
    // created here rather than inside RunCmd's anonymous method because XE2
    // cannot pass an anonymous method nested in another one to an
    // overloaded function.
    target := TPipeTarget.ToLineDelegate(
      procedure(const line : string)
      begin
        captured.Add(line);
      end,
      GConsoleEncoding);
    RunCmd('set',
      procedure(const proc : IProcess)
      begin
        proc.WithStdOutPipe(target);
      end, exitCode, elapsedMs);

    preview := '';
    for i := 0 to Min(2, captured.Count - 1) do
    begin
      if preview <> '' then
        preview := preview + ' | ';
      preview := preview + captured[i];
    end;
    if captured.Count > 3 then
      preview := preview + ' | ...';
    PrintResult(Format('captured %d lines via anonymous method [%s]',
                       [captured.Count, preview]),
                exitCode, elapsedMs);
  finally
    captured.Free;
  end;
end;

// --- 6. ToProcedure (raw bytes) ---------------------------------------------

var
  GByteCounter : Int64;

procedure CountBytes(const data : TBytes; length : NativeUInt);
begin
  Inc(GByteCounter, length);
end;

procedure Demo_ToProcedure;
var
  exitCode  : Cardinal;
  elapsedMs : Int64;
begin
  PrintHeader('6. TPipeTarget.ToProcedure (raw bytes)');
  GByteCounter := 0;
  RunCmd('set',
    procedure(const proc : IProcess)
    begin
      // Byte-level callback - no decoding, no line splitting. Suitable for
      // binary payloads (downloads, archives) where TEncoding doesn't apply.
      proc.WithStdOutPipe(TPipeTarget.ToProcedure(CountBytes));
    end, exitCode, elapsedMs);
  PrintResult(Format('callback fired with a total of %d bytes', [GByteCounter]),
              exitCode, elapsedMs);
end;

// --- 7. ToAll fan-out -------------------------------------------------------

procedure Demo_ToAll;
var
  tempFile  : string;
  sb        : TStringBuilder;
  fan       : IPipeTarget;
  exitCode  : Cardinal;
  elapsedMs : Int64;
  fileSize  : Int64;
begin
  PrintHeader('7. TPipeTarget.ToAll (fan-out)');
  tempFile := TPath.Combine(TPath.GetTempPath,
    'vsoft_proc_demo_fan_' + IntToStr(GetTickCount) + '.txt');
  sb := TStringBuilder.Create;
  try
    // Wire two independent targets behind a single IPipeTarget the library
    // sees. Every chunk fans out to both - useful for "log to file AND
    // show in UI" patterns.
    fan := TPipeTarget.ToAll([
      TPipeTarget.ToFile(tempFile, False),
      TPipeTarget.ToStringBuilder(sb, GConsoleEncoding)
    ]);
    RunCmd('set',
      procedure(const proc : IProcess)
      begin
        proc.WithStdOutPipe(fan);
      end, exitCode, elapsedMs);

    if FileExists(tempFile) then
      fileSize := SizeOfFile(tempFile)
    else
      fileSize := -1;
    // sb.Length is a char count; the OEM code page is usually a single-byte
    // one, so it should match fileSize byte-for-byte.
    PrintResult(Format('file=%d bytes, builder=%d chars (match? %s)',
                       [fileSize, sb.Length,
                        BoolToStr(fileSize = sb.Length, True)]),
                exitCode, elapsedMs);
  finally
    sb.Free;
    if FileExists(tempFile) then
      DeleteFile(tempFile);
  end;
end;

// --- 8. Stdout + stderr separately ------------------------------------------

var
  GOutLines : Integer;
  GErrLines : Integer;

procedure RecordOut(const line : string);
begin
  Inc(GOutLines);
  WriteLn('    [out] ' + line);
end;

procedure RecordErr(const line : string);
begin
  Inc(GErrLines);
  WriteLn('    [err] ' + line);
end;

procedure Demo_StdOutStdErr;
var
  exitCode  : Cardinal;
  elapsedMs : Int64;
begin
  PrintHeader('8. Stdout + stderr captured to separate targets');
  GOutLines := 0;
  GErrLines := 0;
  // The `1>&2` redirect makes the second echo go to stderr while the first
  // and third stay on stdout. The library captures both independently so
  // the [out] / [err] tags below should align with the script's intent.
  RunCmd('echo Hello-stdout&echo Hello-stderr 1>&2&echo Bye-stdout&exit /b 0',
    procedure(const proc : IProcess)
    begin
      proc
        .WithStdOutPipe(TPipeTarget.ToLineProcedure(RecordOut, GConsoleEncoding))
        .WithStdErrPipe(TPipeTarget.ToLineProcedure(RecordErr, GConsoleEncoding));
    end, exitCode, elapsedMs);
  PrintResult(Format('stdout=%d lines, stderr=%d lines', [GOutLines, GErrLines]),
              exitCode, elapsedMs);
end;

// --- Main -------------------------------------------------------------------

begin
  GConsoleEncoding := TEncoding.GetEncoding(Integer(GetOEMCP));
  try
    WriteLn('VSoft.Process - Pipe Targets demo');
    Demo_ToStringBuilder;
    Demo_ToFile;
    Demo_ToStream;
    Demo_ToLineProcedure;
    Demo_ToLineDelegate;
    Demo_ToProcedure;
    Demo_ToAll;
    Demo_StdOutStdErr;
    WriteLn;
    WriteLn('Press Enter to close...');
    ReadLn;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ReadLn;
    end;
  end;
  GConsoleEncoding.Free;
end.
