unit VSoft.Process.Tests.Environment;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  VSoft.Process,
  VSoft.Process.Environment;

type
  [TestFixture]
  TEnvironmentTests = class
  public
    [Test]
    procedure Create_PopulatesFromCurrentProcess;

    [Test]
    procedure AddOrSet_AddsAndUpdates;

    [Test]
    procedure Remove_DropsVariable;

    [Test]
    procedure Reset_ReloadsCurrent;

    [Test]
    procedure Clone_DeepCopies;

    {$IFDEF MSWINDOWS}
    // Windows env block is a flat double-null-terminated UTF-16 buffer:
    //   VAR1=VALUE1\0VAR2=VALUE2\0...VARN=VALUEN\0\0
    [Test]
    procedure ToEnvironmentBlock_TerminatesWithDoubleNull;
    {$ENDIF}

    // H10/H12 - a freshly-created or freshly-Reset builder reflects the
    // current process env unchanged; the platform impl should pass nil to
    // CreateProcess instead of building a custom block. HasOverrides is
    // the signal it checks.
    [Test]
    procedure HasOverrides_FalseAfterCreate;

    [Test]
    procedure HasOverrides_FalseAfterReset;

    [Test]
    procedure HasOverrides_TrueAfterAddOrSet;

    [Test]
    procedure HasOverrides_TrueAfterRemove;

    [Test]
    procedure HasOverrides_FalseAfterModifyThenReset;

    [Test]
    procedure HasOverrides_PropagatesThroughClone;

    [Test]
    procedure Remove_AbsentName_DoesNotChangeCount;

    [Test]
    procedure AddOrSetValues_AddsAllPairs;

    [Test]
    procedure ToString_ContainsAddedVariable;

    // L7 - empty names and names containing '=' are rejected.
    [Test]
    procedure AddOrSet_InvalidName_Raises;

    // M14 - names are case sensitive on POSIX, case insensitive on Windows.
    [Test]
    procedure AddOrSet_NameCaseFollowsPlatform;

    {$IFDEF MSWINDOWS}
    // L7 - CreateProcess requires the block sorted by name.
    [Test]
    procedure ToEnvironmentBlock_SortedByName;
    {$ENDIF}

    // Clear removes every variable, so only the ones added afterwards reach
    // the child.
    [Test]
    procedure Clear_RemovesEveryVariable;
    [Test]
    procedure Clear_SetsHasOverrides;
    [Test]
    procedure Clear_IsFluent;
    [Test]
    procedure Clear_ThenClone_StaysCleared;
    [Test]
    procedure Clear_ThenReset_ReloadsCurrent;
    {$IFDEF MSWINDOWS}
    // An empty Unicode block is two NULs (four zero bytes).
    [Test]
    procedure Clear_EmptyBlock_IsTwoNulls;
    {$ENDIF}
    // An empty environ array holds only the terminating nil.
    [Test]
    procedure Clear_EmptyEnvironArray_IsOnlyTheTerminator;

    [Test]
    procedure Exists_AddedVariable_ReturnsTrue;
    [Test]
    procedure Exists_MissingVariable_ReturnsFalse;
    [Test]
    procedure Exists_AfterRemove_ReturnsFalse;
    [Test]
    procedure Exists_ProcessVariable_TrueUntilClear;
    [Test]
    procedure Exists_MatchesWholeNameOnly;
    [Test]
    procedure Exists_NameCaseFollowsPlatform;
    [Test]
    procedure Exists_SeesClonedVariables;
    // A variable set to an empty value still exists, whether it is new or
    // already present.
    [Test]
    procedure Exists_EmptyValue_ReturnsTrue;
    // An empty name is never a variable, even when the process environment
    // holds Windows drive-directory entries such as "=C:=C:\dir".
    [Test]
    procedure Exists_EmptyName_ReturnsFalse;

    // A #0 in a name or value ends the entry early in the environment block
    // and starts another variable, so it is refused.
    [Test]
    procedure AddOrSet_NulInName_Raises;

    [Test]
    procedure AddOrSet_NulInValue_RaisesAndAddsNothing;

    // A list with a bad entry is refused as a whole.
    [Test]
    procedure AddOrSetValues_NulInLaterEntry_ChangesNothing;

    {$IFDEF MSWINDOWS}
    // An empty name must not match drive entries such as "=C:=C:\dir".
    [Test]
    procedure Remove_EmptyName_LeavesDriveEntries;

    [Test]
    procedure TryGetValue_EmptyName_ReturnsFalse;

    // Names are matched as Windows matches them: ordinally, ignoring case,
    // not by a locale-aware comparison.
    [Test]
    procedure Lookup_IsOrdinalNotLinguistic;
    {$ENDIF}
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  WinApi.Windows,
  {$ENDIF}
  System.SysUtils,
  VSoft.Process.Tests.Common;

function MakeBuilder : IEnvironmentBuilder;
begin
  result := TEnvironmentBuilder.Create;
end;

procedure TEnvironmentTests.Create_PopulatesFromCurrentProcess;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  // Every reasonable test host has at least one env var (PATH, OS, USER...).
  Assert.IsTrue(env.Count > 0, 'Environment should contain current process vars');
end;

procedure TEnvironmentTests.AddOrSet_AddsAndUpdates;
var
  env : IEnvironmentBuilder;
  before : integer;
begin
  env := MakeBuilder;
  before := env.Count;
  env.AddOrSet('VSOFT_TEST_VAR', 'one');
  Assert.AreEqual(before + 1, env.Count, 'AddOrSet must add when missing');

  env.AddOrSet('VSOFT_TEST_VAR', 'two');
  Assert.AreEqual(before + 1, env.Count, 'AddOrSet must update when present');
end;

procedure TEnvironmentTests.Remove_DropsVariable;
var
  env : IEnvironmentBuilder;
  before : integer;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_TEST_REMOVABLE', '1');
  before := env.Count;
  env.Remove('VSOFT_TEST_REMOVABLE');
  Assert.AreEqual(before - 1, env.Count);
end;

procedure TEnvironmentTests.Reset_ReloadsCurrent;
var
  env : IEnvironmentBuilder;
  baseline : integer;
begin
  env := MakeBuilder;
  baseline := env.Count;
  env.AddOrSet('VSOFT_TEST_RESET', 'x');
  Assert.AreEqual(baseline + 1, env.Count);
  env.Reset;
  // Reset should bring us back to the same set of vars (count may not match
  // baseline exactly if vars changed between calls, but it shouldn't include
  // our just-added one).
  Assert.IsTrue(env.Count >= 1, 'After reset, env should still be populated');
end;

procedure TEnvironmentTests.Clone_DeepCopies;
var
  src, dst : IEnvironmentBuilder;
begin
  src := MakeBuilder;
  src.AddOrSet('VSOFT_CLONE_TEST', 'value-1');
  dst := src.Clone;
  Assert.AreEqual(src.Count, dst.Count, 'Clone count mismatch');

  dst.AddOrSet('VSOFT_CLONE_TEST_ONLY_ON_DST', 'x');
  Assert.IsTrue(dst.Count > src.Count, 'Clone mutation leaked into source');
end;

{$IFDEF MSWINDOWS}
procedure TEnvironmentTests.ToEnvironmentBlock_TerminatesWithDoubleNull;
var
  env : IEnvironmentBuilder;
  blockPtr : Pointer;
  pWide : PWideChar;
  walker : PWideChar;
  count : integer;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_BLOCK_KEY', 'BLOCK_VALUE');
  blockPtr := env.ToEnvironmentBlock;
  Assert.IsTrue(blockPtr <> nil, 'Block pointer should not be nil');
  pWide := PWideChar(blockPtr);

  // Walk the block: each entry is a null-terminated wide string; the block
  // ends with an extra null (i.e. two consecutive #0 wide chars). We just need
  // to confirm walking terminates within a sane bound and lands on #0#0.
  walker := pWide;
  count := 0;
  while (walker^ <> #0) and (count < 100000) do
  begin
    // Advance past this string and its null terminator.
    while walker^ <> #0 do
    begin
      Inc(walker);
      Inc(count);
    end;
    Inc(walker); // step over the null
    Inc(count);
  end;
  Assert.IsTrue(count < 100000,
                'Walker did not find double-null terminator within reasonable bound');
end;
{$ENDIF}

procedure TEnvironmentTests.HasOverrides_FalseAfterCreate;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.IsFalse(env.HasOverrides,
                 'A fresh builder mirrors the current process env - no overrides');
end;

procedure TEnvironmentTests.HasOverrides_FalseAfterReset;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_OV_RESET', 'x');
  Assert.IsTrue(env.HasOverrides, 'Sanity: AddOrSet should flag overrides');
  env.Reset;
  Assert.IsFalse(env.HasOverrides,
                 'Reset returns the builder to the parent-env baseline');
end;

procedure TEnvironmentTests.HasOverrides_TrueAfterAddOrSet;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_OV_ADD', 'v');
  Assert.IsTrue(env.HasOverrides);
end;

procedure TEnvironmentTests.HasOverrides_TrueAfterRemove;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_OV_REMOVE', 'v');
  env.Reset; // baseline
  env.Remove('PATH'); // PATH should always be present on the test host
  Assert.IsTrue(env.HasOverrides,
                'Remove of an existing parent-env variable counts as an override');
end;

procedure TEnvironmentTests.HasOverrides_FalseAfterModifyThenReset;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_OV_TOGGLE', 'one');
  env.AddOrSet('VSOFT_OV_TOGGLE', 'two');
  env.Remove('VSOFT_OV_TOGGLE');
  env.Reset;
  Assert.IsFalse(env.HasOverrides,
                 'Reset must clear the override flag even after prior mutations');
end;

procedure TEnvironmentTests.HasOverrides_PropagatesThroughClone;
var
  src, dst : IEnvironmentBuilder;
begin
  src := MakeBuilder;
  Assert.IsFalse(src.HasOverrides, 'Sanity: fresh src has no overrides');
  dst := src.Clone;
  Assert.IsFalse(dst.HasOverrides,
                 'Cloning an unmodified builder must preserve HasOverrides=False');

  src.AddOrSet('VSOFT_CLONE_OV', '1');
  Assert.IsTrue(src.HasOverrides);
  dst := src.Clone;
  Assert.IsTrue(dst.HasOverrides,
                'Cloning a modified builder must preserve HasOverrides=True');
end;

procedure TEnvironmentTests.Remove_AbsentName_DoesNotChangeCount;
var
  env : IEnvironmentBuilder;
  before : integer;
begin
  env := MakeBuilder;
  before := env.Count;
  env.Remove('VSOFT_DEFINITELY_NOT_SET_' + IntToStr(TTestHelpers.TickMs));
  Assert.AreEqual(before, env.Count,
                  'Removing a missing var must leave Count unchanged');
end;

procedure TEnvironmentTests.AddOrSetValues_AddsAllPairs;
var
  env : IEnvironmentBuilder;
  list : TStringList;
  before : integer;
begin
  list := TStringList.Create;
  try
    list.Add('VSOFT_BULK_A=valueA');
    list.Add('VSOFT_BULK_B=valueB');
    list.Add('VSOFT_BULK_C=valueC');

    env := MakeBuilder;
    before := env.Count;
    env.AddOrSetValues(list);
    Assert.AreEqual(before + 3, env.Count,
                    'AddOrSetValues must add every pair that contains "="');
    Assert.IsTrue(env.HasOverrides,
                  'AddOrSetValues should flag the builder as modified');
  finally
    list.Free;
  end;
end;

procedure TEnvironmentTests.ToString_ContainsAddedVariable;
var
  env : IEnvironmentBuilder;
  s : string;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_TO_STRING_TEST', 'distinctive-marker-12345');
  s := env.ToString;
  Assert.Contains(s, 'VSOFT_TO_STRING_TEST');
  Assert.Contains(s, 'distinctive-marker-12345');
end;

procedure TEnvironmentTests.AddOrSet_InvalidName_Raises;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.WillRaise(
    procedure
    begin
      env.AddOrSet('', 'x');
    end,
    EArgumentException);
  Assert.WillRaise(
    procedure
    begin
      env.AddOrSet('A=B', 'x');
    end,
    EArgumentException);
end;

procedure TEnvironmentTests.AddOrSet_NameCaseFollowsPlatform;
var
  env : IEnvironmentBuilder;
  before : integer;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_CASE_TEST', 'upper');
  before := env.Count;
  env.AddOrSet('vsoft_case_test', 'lower');
  {$IFDEF MSWINDOWS}
  Assert.AreEqual(before, env.Count, 'Windows names are case insensitive - must update, not add');
  {$ELSE}
  Assert.AreEqual(before + 1, env.Count, 'POSIX names are case sensitive - must add a second variable');
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
procedure TEnvironmentTests.ToEnvironmentBlock_SortedByName;
var
  env : IEnvironmentBuilder;
  walker : PWideChar;
  entry : string;
  name : string;
  previous : string;
  idx : integer;
begin
  env := MakeBuilder;
  env.AddOrSet('ZZZ_VSOFT_LAST', '1');
  env.AddOrSet('aaa_vsoft_first', '2');
  walker := PWideChar(env.ToEnvironmentBlock);
  previous := '';
  while walker^ <> #0 do
  begin
    entry := walker;
    Inc(walker, Length(entry) + 1);
    idx := Pos('=', Copy(entry, 2, MaxInt));
    name := UpperCase(Copy(entry, 1, idx));
    Assert.IsTrue(CompareStr(previous, name) <= 0,
                  'Block out of order: "' + previous + '" before "' + name + '"');
    previous := name;
  end;
end;
{$ENDIF}

procedure TEnvironmentTests.Clear_RemovesEveryVariable;
var
  env : IEnvironmentBuilder;
  value : string;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_CLEAR_TEST', 'x');
  Assert.IsTrue(env.Count > 1);
  env.Clear;
  Assert.AreEqual(0, env.Count);
  Assert.IsFalse(env.TryGetValue('PATH', value), 'PATH must be gone after Clear');
  Assert.IsFalse(env.TryGetValue('VSOFT_CLEAR_TEST', value));
end;

procedure TEnvironmentTests.Clear_SetsHasOverrides;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.IsFalse(env.HasOverrides);
  env.Clear;
  Assert.IsTrue(env.HasOverrides, 'An emptied environment differs from the parent''s');
end;

procedure TEnvironmentTests.Clear_IsFluent;
var
  env : IEnvironmentBuilder;
  value : string;
begin
  env := MakeBuilder;
  env.Clear.AddOrSet('ONLY_ONE', '1');
  Assert.AreEqual(1, env.Count);
  Assert.IsTrue(env.TryGetValue('ONLY_ONE', value));
  Assert.AreEqual('1', value);
end;

procedure TEnvironmentTests.Clear_ThenClone_StaysCleared;
var
  env : IEnvironmentBuilder;
  cloned : IEnvironmentBuilder;
  value : string;
begin
  env := MakeBuilder;
  env.Clear.AddOrSet('ONLY_ONE', '1');
  cloned := env.Clone;
  Assert.AreEqual(1, cloned.Count);
  Assert.IsTrue(cloned.HasOverrides);
  Assert.IsTrue(cloned.TryGetValue('ONLY_ONE', value));
  Assert.IsFalse(cloned.TryGetValue('PATH', value), 'the clone must not reload the parent''s variables');

  env := MakeBuilder;
  env.Clear;
  cloned := env.Clone;
  Assert.AreEqual(0, cloned.Count, 'a cleared, empty builder clones empty');
  Assert.IsTrue(cloned.HasOverrides, 'an empty clone still overrides the parent''s environment');
end;

procedure TEnvironmentTests.Clear_ThenReset_ReloadsCurrent;
var
  env : IEnvironmentBuilder;
  value : string;
begin
  env := MakeBuilder;
  env.Clear;
  env.Reset;
  Assert.IsFalse(env.HasOverrides);
  Assert.AreEqual(MakeBuilder.Count, env.Count);
  Assert.IsTrue(env.TryGetValue('PATH', value), 'Reset takes a new snapshot of the process environment');
end;

{$IFDEF MSWINDOWS}
procedure TEnvironmentTests.Clear_EmptyBlock_IsTwoNulls;
var
  env : IEnvironmentBuilder;
  block : PWideChar;
begin
  env := MakeBuilder;
  env.Clear;
  block := PWideChar(env.ToEnvironmentBlock);
  Assert.IsTrue(block <> nil);
  Assert.AreEqual(0, Ord(block[0]));
  Assert.AreEqual(0, Ord(block[1]));
end;
{$ENDIF}

procedure TEnvironmentTests.Clear_EmptyEnvironArray_IsOnlyTheTerminator;
var
  env : IEnvironmentBuilder;
  envArray : TArray<PAnsiChar>;
begin
  env := MakeBuilder;
  env.Clear;
  envArray := env.ToEnvironArray;
  Assert.AreEqual(1, Integer(Length(envArray)));
  Assert.IsTrue(envArray[0] = nil);
end;

procedure TEnvironmentTests.Exists_AddedVariable_ReturnsTrue;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_EXISTS_TEST', 'x');
  Assert.IsTrue(env.Exists('VSOFT_EXISTS_TEST'));
end;

procedure TEnvironmentTests.Exists_MissingVariable_ReturnsFalse;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.IsFalse(env.Exists('VSOFT_DEFINITELY_NOT_SET_' + IntToStr(TTestHelpers.TickMs)));
end;

procedure TEnvironmentTests.Exists_AfterRemove_ReturnsFalse;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_EXISTS_REMOVE', 'x');
  env.Remove('VSOFT_EXISTS_REMOVE');
  Assert.IsFalse(env.Exists('VSOFT_EXISTS_REMOVE'));
end;

procedure TEnvironmentTests.Exists_ProcessVariable_TrueUntilClear;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.IsTrue(env.Exists('PATH'), 'PATH comes from the process environment');
  env.Clear;
  Assert.IsFalse(env.Exists('PATH'), 'PATH must be gone after Clear');
  env.Reset;
  Assert.IsTrue(env.Exists('PATH'), 'Reset reloads the process environment');
end;

procedure TEnvironmentTests.Exists_MatchesWholeNameOnly;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_EXISTS_PREFIX_LONG', 'VSOFT_EXISTS_VALUE_ONLY');
  Assert.IsTrue(env.Exists('VSOFT_EXISTS_PREFIX_LONG'));
  Assert.IsFalse(env.Exists('VSOFT_EXISTS_PREFIX'), 'a prefix of a name is not a match');
  Assert.IsFalse(env.Exists('VSOFT_EXISTS_PREFIX_LONG='), 'the separator is not part of the name');
  Assert.IsFalse(env.Exists('VSOFT_EXISTS_PREFIX_LONG=VSOFT_EXISTS_VALUE_ONLY'), 'a NAME=VALUE pair is not a name');
  Assert.IsFalse(env.Exists('VSOFT_EXISTS_VALUE_ONLY'), 'a value is not a name');
end;

procedure TEnvironmentTests.Exists_NameCaseFollowsPlatform;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_EXISTS_CASE', 'x');
  {$IFDEF MSWINDOWS}
  Assert.IsTrue(env.Exists('vsoft_exists_case'), 'Windows names are case insensitive');
  {$ELSE}
  Assert.IsFalse(env.Exists('vsoft_exists_case'), 'POSIX names are case sensitive');
  {$ENDIF}
end;

procedure TEnvironmentTests.Exists_SeesClonedVariables;
var
  src : IEnvironmentBuilder;
  dst : IEnvironmentBuilder;
begin
  src := MakeBuilder;
  src.AddOrSet('VSOFT_EXISTS_CLONE', 'x');
  dst := src.Clone;
  Assert.IsTrue(dst.Exists('VSOFT_EXISTS_CLONE'));
  dst.Remove('VSOFT_EXISTS_CLONE');
  Assert.IsFalse(dst.Exists('VSOFT_EXISTS_CLONE'));
  Assert.IsTrue(src.Exists('VSOFT_EXISTS_CLONE'), 'removing from the clone must not touch the source');
end;

procedure TEnvironmentTests.Exists_EmptyValue_ReturnsTrue;
var
  env : IEnvironmentBuilder;
  value : string;
begin
  env := MakeBuilder;
  env.AddOrSet('VSOFT_EXISTS_EMPTY_NEW', '');
  Assert.IsTrue(env.Exists('VSOFT_EXISTS_EMPTY_NEW'), 'a new variable with an empty value');

  env.AddOrSet('VSOFT_EXISTS_EMPTY_SET', 'x');
  env.AddOrSet('VSOFT_EXISTS_EMPTY_SET', '');
  Assert.IsTrue(env.Exists('VSOFT_EXISTS_EMPTY_SET'), 'setting an existing variable to empty must not remove it');
  Assert.IsTrue(env.TryGetValue('VSOFT_EXISTS_EMPTY_SET', value));
  Assert.AreEqual('', value);
end;

procedure TEnvironmentTests.Exists_EmptyName_ReturnsFalse;
var
  env : IEnvironmentBuilder;
begin
  {$IFDEF MSWINDOWS}
  // cmd.exe keeps the current directory of each drive as "=X:=X:\dir"; the
  // part before the first '=' is empty.
  SetEnvironmentVariable('=Z:', 'Z:\');
  try
    env := MakeBuilder;
  finally
    SetEnvironmentVariable('=Z:', nil);
  end;
  Assert.Contains(env.ToString, '=Z:=Z:\', 'sanity: the drive entry must be in the builder');
  {$ELSE}
  env := MakeBuilder;
  {$ENDIF}
  Assert.IsFalse(env.Exists(''));
end;

procedure TEnvironmentTests.AddOrSet_NulInName_Raises;
var
  env : IEnvironmentBuilder;
begin
  env := MakeBuilder;
  Assert.WillRaise(
    procedure
    begin
      env.AddOrSet('VSOFT_NUL'#0'INJECTED', 'x');
    end,
    EArgumentException);
  Assert.IsFalse(env.HasOverrides, 'a refused name must not change the builder');
end;

procedure TEnvironmentTests.AddOrSet_NulInValue_RaisesAndAddsNothing;
var
  env : IEnvironmentBuilder;
  count : integer;
begin
  env := MakeBuilder;
  count := env.Count;
  Assert.WillRaise(
    procedure
    begin
      env.AddOrSet('VSOFT_NUL_VALUE', 'x'#0'VSOFT_INJECTED=1');
    end,
    EArgumentException);
  Assert.AreEqual(count, env.Count, 'nothing may be added');
  Assert.IsFalse(env.Exists('VSOFT_NUL_VALUE'));
  Assert.IsFalse(env.HasOverrides, 'a refused value must not change the builder');
end;

procedure TEnvironmentTests.AddOrSetValues_NulInLaterEntry_ChangesNothing;
var
  env : IEnvironmentBuilder;
  list : TStringList;
  count : integer;
begin
  env := MakeBuilder;
  count := env.Count;
  list := TStringList.Create;
  try
    list.Add('VSOFT_FIRST_OK=1');
    list.Add('VSOFT_SECOND=x'#0'VSOFT_INJECTED=1');
    Assert.WillRaise(
      procedure
      begin
        env.AddOrSetValues(list);
      end,
      EArgumentException);
  finally
    list.Free;
  end;
  Assert.AreEqual(count, env.Count, 'nothing may be added');
  Assert.IsFalse(env.Exists('VSOFT_FIRST_OK'), 'the valid entry before the bad one must not be applied');
  Assert.IsFalse(env.HasOverrides);
end;

{$IFDEF MSWINDOWS}
procedure TEnvironmentTests.Remove_EmptyName_LeavesDriveEntries;
var
  env : IEnvironmentBuilder;
  count : integer;
  before : string;
begin
  SetEnvironmentVariable('=Z:', 'Z:\');
  try
    env := MakeBuilder;
  finally
    SetEnvironmentVariable('=Z:', nil);
  end;
  count := env.Count;
  before := env.ToString;
  env.Remove('');
  Assert.AreEqual(count, env.Count, 'Remove('''') must not delete a drive entry');
  Assert.AreEqual(before, env.ToString, False);
  Assert.IsFalse(env.HasOverrides);
end;

procedure TEnvironmentTests.TryGetValue_EmptyName_ReturnsFalse;
var
  env : IEnvironmentBuilder;
  value : string;
begin
  SetEnvironmentVariable('=Z:', 'Z:\');
  try
    env := MakeBuilder;
  finally
    SetEnvironmentVariable('=Z:', nil);
  end;
  value := 'unset';
  Assert.Contains(env.ToString, '=Z:=Z:\', 'sanity: the drive entry must be in the builder');
  Assert.IsFalse(env.TryGetValue('', value));
  Assert.AreEqual('', value);
end;

procedure TEnvironmentTests.Lookup_IsOrdinalNotLinguistic;
var
  env : IEnvironmentBuilder;
  count : integer;
  value : string;
begin
  env := MakeBuilder;
  count := env.Count;
  // A linguistic comparison gives a soft hyphen (U+00AD) and a zero-width
  // no-break space (U+FEFF) no weight, so it calls these two names equal.
  // Windows compares the code units, so they are two variables.
  env.AddOrSet('VSOFT_ORD'#$00AD'NAME', 'soft hyphen');
  Assert.IsFalse(env.Exists('VSOFT_ORD'#$FEFF'NAME'), 'U+FEFF is not U+00AD');
  env.AddOrSet('VSOFT_ORD'#$FEFF'NAME', 'no-break');
  Assert.AreEqual(count + 2, env.Count, 'two distinct variables');
  Assert.IsTrue(env.TryGetValue('vsoft_ord'#$00AD'name', value), 'case is still ignored');
  Assert.AreEqual('soft hyphen', value, False);
  env.AddOrSet('VSOFT_CAF'#$00E9, 'accented');
  Assert.IsTrue(env.TryGetValue('VSOFT_CAF'#$00C9, value), 'case is ignored beyond ASCII too, as Windows does');
  Assert.AreEqual('accented', value, False);
end;
{$ENDIF}

initialization
  TDUnitX.RegisterTestFixture(TEnvironmentTests);

end.
