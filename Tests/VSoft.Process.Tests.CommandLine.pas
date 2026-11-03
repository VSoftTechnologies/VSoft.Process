unit VSoft.Process.Tests.CommandLine;

interface

uses
  DUnitX.TestFramework,
  VSoft.Process,
  VSoft.Process.CommandLine;

type
  [TestFixture]
  TCommandLineTests = class
  public
    [Test]
    procedure Add_NameOnly_AppearsInToString;

    [Test]
    procedure Add_NameValue_AppearsWithSeparator;

    [Test]
    procedure Add_ValueWithSpaces_GetsAutoDoubleQuoted;

    [Test]
    procedure Add_ValueWithoutSpaces_NotQuotedWhenAutoDouble;

    [Test]
    procedure Remove_ByName_DecrementsCount;

    [Test]
    procedure Clear_EmptiesArgs;

    [Test]
    procedure Clone_DeepCopiesArguments;

    // H14 - sensitive args must NOT show their value in ToLogString, even when
    // the value also contains other text. ToString must still emit the real
    // value (we only mask the log version).
    [Test]
    procedure Sensitive_MaskedInLogString_RealInToString;

    // A sensitive argument without a separate value (AddSensitive(name)) is
    // masked whole; the other arguments still render.
    [Test]
    procedure Sensitive_NameOnly_MaskedWhole;

    [Test]
    procedure ArgumentsByName_FindsAddedArgument;

    [Test]
    procedure ArgumentsByName_ReturnsNilWhenAbsent;

    [Test]
    procedure Add_NameValue_DefaultDoubleQuotesWhenValueHasSpaces;

    [Test]
    procedure DefaultArgumentSeparator_CustomValueUsed;

    [Test]
    procedure Remove_AbsentName_LeavesCountUnchanged;

    [Test]
    procedure ToLogString_NonSensitive_MatchesToString;

    // M6 - Add('', '') is an explicit empty argument.
    [Test]
    procedure Add_EmptyNameAndValue_RendersEmptyArgument;

    // M6 - auto quoting must escape a trailing backslash.
    [Test]
    procedure Add_PathWithSpacesAndTrailingBackslash_Escaped;

    // L8 - name-only arguments stay unquoted with the (interface) default.
    [Test]
    procedure Add_NameOnly_DefaultQuoting_LeavesNameBare;
  end;

implementation

uses
  System.SysUtils,
  VSoft.Process.Tests.Common;

function MakeBuilder : ICommandLineBuilder;
begin
  result := TArgumentsBuilder.Create;
end;

procedure TCommandLineTests.Add_NameOnly_AppearsInToString;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--verbose');
  Assert.AreEqual('--verbose', b.ToString);
end;

procedure TCommandLineTests.Add_NameValue_AppearsWithSeparator;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--out', 'file.txt', TQuoted.qtNone);
  Assert.AreEqual('--out file.txt', b.ToString);
end;

procedure TCommandLineTests.Add_ValueWithSpaces_GetsAutoDoubleQuoted;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--path', 'c:\Program Files\Foo', TQuoted.qtAutoDouble);
  Assert.AreEqual('--path "c:\Program Files\Foo"', b.ToString);
end;

procedure TCommandLineTests.Add_ValueWithoutSpaces_NotQuotedWhenAutoDouble;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--id', '42', TQuoted.qtAutoDouble);
  Assert.AreEqual('--id 42', b.ToString);
end;

procedure TCommandLineTests.Remove_ByName_DecrementsCount;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--a');
  b.Add('--b');
  Assert.AreEqual(2, b.Count);
  b.Remove('--a');
  Assert.AreEqual(1, b.Count);
end;

procedure TCommandLineTests.Clear_EmptiesArgs;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--a');
  b.Add('--b');
  b.Clear;
  Assert.AreEqual(0, b.Count);
end;

procedure TCommandLineTests.Clone_DeepCopiesArguments;
var
  src, dst : ICommandLineBuilder;
begin
  src := MakeBuilder;
  src.Add('--a', '1', TQuoted.qtNone);
  src.Add('--b', '2', TQuoted.qtNone);
  dst := src.Clone;
  Assert.AreEqual(2, dst.Count, 'Clone must copy arg count');
  Assert.AreEqual(src.ToString, dst.ToString, 'Clone content must match');

  // Mutating the clone must not change the source.
  dst.Add('--c');
  Assert.AreEqual(2, src.Count, 'Cloned builder mutation leaked into source');
end;

procedure TCommandLineTests.Sensitive_MaskedInLogString_RealInToString;
var
  b : ICommandLineBuilder;
  full, masked : string;
begin
  b := MakeBuilder;
  b.Add('--user', 'alice', TQuoted.qtNone);
  b.AddSensitive('--password', 'topsecret123', TQuoted.qtNone);
  full   := b.ToString;
  masked := b.ToLogString;

  Assert.Contains(full, 'topsecret123', 'ToString must include real value');
  Assert.IsFalse(Pos('topsecret123', masked) > 0,
                 'ToLogString must NOT leak the sensitive value');
  Assert.Contains(masked, '****', 'ToLogString should substitute a mask token');
end;

procedure TCommandLineTests.Sensitive_NameOnly_MaskedWhole;
var
  b : ICommandLineBuilder;
  full, masked : string;
begin
  b := MakeBuilder;
  b.Add('--user', 'alice', TQuoted.qtNone);
  b.AddSensitive('--password=topsecret123');
  b.AddSensitive('rawtoken456', TQuoted.qtNone);
  full := b.ToString;
  masked := b.ToLogString;
  Assert.Contains(full, '--password=topsecret123', 'ToString must include the real argument');
  Assert.Contains(full, 'rawtoken456', 'ToString must include the real argument');
  Assert.IsFalse(Pos('topsecret123', masked) > 0, 'ToLogString must NOT leak a name-only sensitive argument');
  Assert.IsFalse(Pos('rawtoken456', masked) > 0, 'ToLogString must NOT leak a name-only sensitive argument');
  Assert.AreEqual(2, TTestHelpers.CountChar(StringReplace(masked, '****', '#', [rfReplaceAll]), '#'), 'each sensitive argument is masked');
  Assert.Contains(masked, '--user alice', 'Other args must still render alongside sensitive');
end;

procedure TCommandLineTests.ArgumentsByName_FindsAddedArgument;
var
  b : ICommandLineBuilder;
  found : IArgument;
begin
  b := MakeBuilder;
  b.Add('--name', 'alice', TQuoted.qtNone);
  found := b.ArgumentsByName['--name'];
  Assert.IsNotNull(found, 'Lookup by name should find the added argument');
  Assert.AreEqual('alice', found.Value);
end;

procedure TCommandLineTests.ArgumentsByName_ReturnsNilWhenAbsent;
var
  b : ICommandLineBuilder;
  found : IArgument;
begin
  b := MakeBuilder;
  found := b.ArgumentsByName['--missing'];
  Assert.IsNull(found, 'Lookup by name returns nil for missing arg, not an exception');
end;

procedure TCommandLineTests.Add_NameValue_DefaultDoubleQuotesWhenValueHasSpaces;
var
  b : ICommandLineBuilder;
begin
  // Default Quoted is qtDouble - the value is ALWAYS wrapped in double quotes.
  b := MakeBuilder;
  b.Add('--path', 'C:\some path\file.txt');
  Assert.AreEqual('--path "C:\some path\file.txt"', b.ToString);
end;

procedure TCommandLineTests.DefaultArgumentSeparator_CustomValueUsed;
var
  b : ICommandLineBuilder;
begin
  // Switching to a non-space arg separator must be reflected in ToString.
  b := MakeBuilder;
  b.WithDefaultArgumentSeparator(';');
  b.Add('--a');
  b.Add('--b');
  b.Add('--c');
  Assert.AreEqual('--a;--b;--c', b.ToString,
                  'Custom argument separator should join args');
end;

procedure TCommandLineTests.Remove_AbsentName_LeavesCountUnchanged;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--present');
  b.Remove('--definitely-not-there');
  Assert.AreEqual(1, b.Count,
                  'Removing an absent arg must be a no-op, not raise');
end;

procedure TCommandLineTests.ToLogString_NonSensitive_MatchesToString;
var
  b : ICommandLineBuilder;
begin
  // When no sensitive args are present, ToLogString and ToString must agree
  // exactly. The mask only shows up when there is something to mask.
  b := MakeBuilder;
  b.Add('--verbose');
  b.Add('--out', 'file.txt', TQuoted.qtNone);
  Assert.AreEqual(b.ToString, b.ToLogString,
                  'Without sensitive args, ToLogString must equal ToString');
end;

procedure TCommandLineTests.Add_EmptyNameAndValue_RendersEmptyArgument;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('git').Add('', '').Add('end');
  Assert.AreEqual('git "" end', b.ToString);
end;

procedure TCommandLineTests.Add_PathWithSpacesAndTrailingBackslash_Escaped;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('/out', 'C:\Program Files\Out\');
  Assert.AreEqual('/out "C:\Program Files\Out\\"', b.ToString);
end;

procedure TCommandLineTests.Add_NameOnly_DefaultQuoting_LeavesNameBare;
var
  b : ICommandLineBuilder;
begin
  b := MakeBuilder;
  b.Add('--verbose');
  Assert.AreEqual('--verbose', b.ToString);
end;

initialization
  TDUnitX.RegisterTestFixture(TCommandLineTests);

end.
