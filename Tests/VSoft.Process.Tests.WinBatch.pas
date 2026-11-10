unit VSoft.Process.Tests.WinBatch;

interface

// What a real batch file receives for each way RenderBatchArgument
// (VSoft.Process.Windows) renders an argument. The review-sup-rawargs
// fixture prints %* exactly as received, so the quoting that reached
// cmd.exe is visible.

{$IFDEF MSWINDOWS}
uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  VSoft.Process;

type
  [TestFixture]
  TWindowsBatchArgumentTests = class
  public
    [Setup]
    procedure SetUp;

    [Test]
    procedure SingleQuoted_ValueIsSingleQuoted;
    [Test]
    procedure AutoSingleQuoted_ValueWithoutSpaces_LeftBare;
    [Test]
    procedure NotQuoted_PassedAsGiven;
    // A value the caller already wrapped in quotes is not quoted twice.
    [Test]
    procedure CallerQuotedValue_QuotedOnce;
    [Test]
    procedure EmptyArgument_IsAnEmptyQuotedArgument;
    [Test]
    procedure NameOnly_LeftBare;
    [Test]
    procedure NameOnly_QuoteName_IsQuoted;
    // cmd.exe metacharacters are only safe inside quotes.
    [Test]
    procedure MetaCharacterInName_NameAndValueAreQuoted;
    [Test]
    procedure MetaCharacterInValueWithoutName_ValueIsQuoted;
    [Test]
    procedure EveryMetaCharacter_ArrivesInsideOneQuotedArgument;
    [Test]
    procedure SeveralArguments_ArriveInOrder;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  VSoft.Process.Tests.Common;

function NewBatchProcess : IProcess;
begin
  result := TProcess.Create;
  result.StartInfo.TimeoutInMSec := 30000;
  result.StartInfo.Executable := TTestHelpers.ScriptPath('review-sup-rawargs');
end;

// Runs the batch file and returns the arguments it received: the text
// between "all=[" and the closing "]".
function ReceivedArguments(const proc : IProcess) : string;
var
  output : TStringBuilder;
  lines : TStringList;
  value : string;
begin
  output := TStringBuilder.Create;
  lines := TStringList.Create;
  try
    proc.WithStdOutPipe(TPipeTarget.ToStringBuilder(output));
    try
      Assert.IsTrue(proc.Execute, proc.Errors.Text);
    finally
      proc.ClearStdOutPipes;
    end;
    Assert.AreEqual<Cardinal>(0, proc.ExitCode, output.ToString + proc.Errors.Text);
    lines.Text := output.ToString;
    value := TTestHelpers.ValueAfter(lines, 'all=[');
    Assert.IsTrue((value <> '') and (value[Length(value)] = ']'), 'unexpected output: ' + output.ToString);
    result := Copy(value, 1, Length(value) - 1);
  finally
    lines.Free;
    output.Free;
  end;
end;

{ TWindowsBatchArgumentTests }

procedure TWindowsBatchArgumentTests.SetUp;
begin
  TTestHelpers.ScriptsDir;
end;

procedure TWindowsBatchArgumentTests.SingleQuoted_ValueIsSingleQuoted;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-n', 'value', TQuoted.qtSingle);
  Assert.AreEqual('-n ''value''', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.AutoSingleQuoted_ValueWithoutSpaces_LeftBare;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('', 'value', TQuoted.qtAutoSingle);
  Assert.AreEqual('value', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.NotQuoted_PassedAsGiven;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-n', 'value', TQuoted.qtNone);
  Assert.AreEqual('-n value', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.CallerQuotedValue_QuotedOnce;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-n', '"value"');
  Assert.AreEqual('-n "value"', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.EmptyArgument_IsAnEmptyQuotedArgument;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('', '');
  Assert.AreEqual('""', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.NameOnly_LeftBare;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-flag');
  Assert.AreEqual('-flag', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.NameOnly_QuoteName_IsQuoted;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-flag');
  proc.CommandLine.Arguments[0].QuoteName := True;
  Assert.AreEqual('"-flag"', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.MetaCharacterInName_NameAndValueAreQuoted;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('a&b', 'v');
  Assert.AreEqual('"a&b" "v"', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.MetaCharacterInValueWithoutName_ValueIsQuoted;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('', 'a&b');
  Assert.AreEqual('"a&b"', ReceivedArguments(proc));
end;

procedure TWindowsBatchArgumentTests.EveryMetaCharacter_ArrivesInsideOneQuotedArgument;
const
  cMetaChars : array[0..11] of Char = (' ', #9, '&', '|', '<', '>', '^', '(', ')', ',', ';', '=');
var
  i : integer;
  proc : IProcess;
  value : string;
begin
  for i := 0 to High(cMetaChars) do
  begin
    value := 'x' + cMetaChars[i] + 'y';
    proc := NewBatchProcess;
    proc.CommandLine.Add('-n', value);
    Assert.AreEqual('-n "' + value + '"', ReceivedArguments(proc), 'character ' + IntToStr(Ord(cMetaChars[i])));
  end;
end;

procedure TWindowsBatchArgumentTests.SeveralArguments_ArriveInOrder;
var
  proc : IProcess;
begin
  proc := NewBatchProcess;
  proc.CommandLine.Add('-a');
  proc.CommandLine.Add('-n', 'v w');
  proc.CommandLine.Add('last');
  Assert.AreEqual('-a -n "v w" last', ReceivedArguments(proc));
end;

initialization
  TDUnitX.RegisterTestFixture(TWindowsBatchArgumentTests);
{$ENDIF}

end.
