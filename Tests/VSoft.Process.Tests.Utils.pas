unit VSoft.Process.Tests.Utils;

interface

uses
  DUnitX.TestFramework,
  VSoft.Process.Utils;

type
  [TestFixture]
  TStringUtilsTests = class
  public
    [Test]
    procedure StripQuotes_RemovesMatchingDoubleQuotes;

    [Test]
    procedure StripQuotes_RemovesMatchingSingleQuotes;

    [Test]
    procedure StripQuotes_LeavesUnquoted;

    [Test]
    procedure StripQuotes_LeavesMismatchedQuotes;

    [Test]
    procedure StripQuotes_EmptyString;

    [Test]
    procedure DoubleQuoteString_WrapsWhenSpaces;

    [Test]
    procedure DoubleQuoteString_DoesNotWrapWithoutSpacesWhenChecked;

    [Test]
    procedure DoubleQuoteString_AlwaysWrapsWhenNotChecking;

    [Test]
    procedure QuoteString_WrapsWhenSpaces;

    // M8 - embedded double quotes used to be left bare, producing a string
    // that CommandLineToArgvW parses as TWO arguments. The fix routes
    // through EscapeForWindowsCommandLine when the value contains `"`.
    [Test]
    procedure DoubleQuoteString_EscapesEmbeddedDoubleQuote;

    // M8 - trailing backslashes must be doubled before the closing quote
    // or the parser eats the closer.
    [Test]
    procedure EscapeForWindowsCommandLine_DoublesTrailingBackslashes;

    // M8 - a sequence of backslashes before a literal " is doubled and one
    // backslash precedes the escaped quote.
    [Test]
    procedure EscapeForWindowsCommandLine_HandlesBackslashesBeforeQuote;

    // M8 - bare ASCII values without spaces or quotes should still be left
    // unquoted when checkString is True.
    [Test]
    procedure DoubleQuoteString_LeavesBareAsciiAlone;

    // M6 - auto quoting a path that ends in a backslash used to produce
    // `"C:\dir with space\"` whose closing quote the child treats as escaped.
    [Test]
    procedure DoubleQuoteString_TrailingBackslashWithSpaces_Escaped;

    // M6 - a forced quote must escape trailing backslashes too.
    [Test]
    procedure DoubleQuoteString_ForcedQuote_EscapesTrailingBackslash;

    // M6 - tabs split arguments just like spaces.
    [Test]
    procedure DoubleQuoteString_TabTriggersQuoting;

    // M6 - an empty value must survive as "" rather than vanish.
    [Test]
    procedure DoubleQuoteString_EmptyValue_Quoted;

    [Test]
    procedure IsBatchFile_DetectsBatAndCmd;

    [Test]
    procedure ContainsCmdMetaChars_DetectsShellSyntax;

    [Test]
    procedure ContainsCmdUnsafeChars_DetectsExpansionAndQuotes;

    // H10 - ids that must never be tree-killed (0, our own pid, System / init).
    [Test]
    procedure CanTerminateTree_RejectsUnsafeIds;

    {$IFDEF MSWINDOWS}
    // A child we may not terminate must not stop the walk: its own
    // children (our grandchildren) are still killed.
    [Test]
    procedure TerminateProcessTree_UnopenableChild_StillKillsGrandchild;
    {$ENDIF}
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  System.SysUtils,
  Winapi.Windows,
  VSoft.Process.WinAPI;
  {$ELSE}
  Posix.Unistd;
  {$ENDIF}

procedure TStringUtilsTests.StripQuotes_RemovesMatchingDoubleQuotes;
begin
  Assert.AreEqual('hello', TStringUtils.StripQuotes('"hello"'));
end;

procedure TStringUtilsTests.StripQuotes_RemovesMatchingSingleQuotes;
begin
  Assert.AreEqual('hello', TStringUtils.StripQuotes(''''+'hello'+''''));
end;

procedure TStringUtilsTests.StripQuotes_LeavesUnquoted;
begin
  Assert.AreEqual('hello', TStringUtils.StripQuotes('hello'));
end;

procedure TStringUtilsTests.StripQuotes_LeavesMismatchedQuotes;
begin
  // Only strips when first AND last char are the same quote char.
  Assert.AreEqual('"hello', TStringUtils.StripQuotes('"hello'));
end;

procedure TStringUtilsTests.StripQuotes_EmptyString;
begin
  Assert.AreEqual('', TStringUtils.StripQuotes(''));
end;

procedure TStringUtilsTests.DoubleQuoteString_WrapsWhenSpaces;
begin
  Assert.AreEqual('"a b c"', TStringUtils.DoubleQuoteString('a b c', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_DoesNotWrapWithoutSpacesWhenChecked;
begin
  Assert.AreEqual('foo', TStringUtils.DoubleQuoteString('foo', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_AlwaysWrapsWhenNotChecking;
begin
  Assert.AreEqual('"foo"', TStringUtils.DoubleQuoteString('foo', False));
end;

procedure TStringUtilsTests.QuoteString_WrapsWhenSpaces;
begin
  Assert.AreEqual(''''+'x y'+'''', TStringUtils.QuoteString('x y', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_EscapesEmbeddedDoubleQuote;
var
  produced : string;
begin
  // Input contains an embedded double quote. Pre-fix output was
  // `"he said "hi""` which CommandLineToArgvW parses as two args. Post-fix
  // output must be a valid single quoted argument that round-trips to
  // `he said "hi"`.
  produced := TStringUtils.DoubleQuoteString('he said "hi"', True);
  Assert.AreEqual('"he said \"hi\""', produced,
                  'Embedded " must be backslash-escaped inside the quoted region');
end;

procedure TStringUtilsTests.EscapeForWindowsCommandLine_DoublesTrailingBackslashes;
var
  produced : string;
begin
  // A value ending in `\` must have the trailing backslash doubled before
  // the closing quote, otherwise the parser treats `\"` as an escaped quote
  // and swallows the closing delimiter.
  produced := TStringUtils.EscapeForWindowsCommandLine('C:\Program Files\');
  Assert.AreEqual('"C:\Program Files\\"', produced,
                  'Trailing backslash must be doubled before the closing quote');
end;

procedure TStringUtilsTests.EscapeForWindowsCommandLine_HandlesBackslashesBeforeQuote;
var
  produced : string;
begin
  // Two backslashes followed by a literal " must become four backslashes
  // followed by an escaped quote (2N + 1 backslashes + `"`), so the parser
  // produces 2 literal backslashes followed by a literal ".
  produced := TStringUtils.EscapeForWindowsCommandLine('a\\"b');
  Assert.AreEqual('"a\\\\\"b"', produced,
                  '2 backslashes + " must produce 4 backslashes + \"');
end;

procedure TStringUtilsTests.DoubleQuoteString_LeavesBareAsciiAlone;
begin
  // Bare ASCII argument with no spaces and no quotes: still safe to pass
  // unquoted when checkString is True. The pre-fix behaviour is preserved
  // so existing call-sites don't get extra quoting noise.
  Assert.AreEqual('foo', TStringUtils.DoubleQuoteString('foo', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_TrailingBackslashWithSpaces_Escaped;
begin
  Assert.AreEqual('"C:\dir with space\\"', TStringUtils.DoubleQuoteString('C:\dir with space\', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_ForcedQuote_EscapesTrailingBackslash;
begin
  Assert.AreEqual('"C:\out\\"', TStringUtils.DoubleQuoteString('C:\out\', False));
end;

procedure TStringUtilsTests.DoubleQuoteString_TabTriggersQuoting;
begin
  Assert.AreEqual('"a'#9'b"', TStringUtils.DoubleQuoteString('a'#9'b', True));
end;

procedure TStringUtilsTests.DoubleQuoteString_EmptyValue_Quoted;
begin
  Assert.AreEqual('""', TStringUtils.DoubleQuoteString('', True));
  Assert.AreEqual('""', TStringUtils.DoubleQuoteString('""', True), 'Pre-quoted empty value');
end;

procedure TStringUtilsTests.IsBatchFile_DetectsBatAndCmd;
begin
  Assert.IsTrue(TStringUtils.IsBatchFile('C:\x\build.cmd'));
  Assert.IsTrue(TStringUtils.IsBatchFile('C:\x\BUILD.BAT'));
  Assert.IsFalse(TStringUtils.IsBatchFile('C:\x\cmd.exe'));
  Assert.IsFalse(TStringUtils.IsBatchFile('C:\x\script.cmdline'));
end;

procedure TStringUtilsTests.ContainsCmdMetaChars_DetectsShellSyntax;
begin
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a&b'));
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a|b'));
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a>b'));
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a^b'));
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a b'));
  Assert.IsTrue(TStringUtils.ContainsCmdMetaChars('a,b'));
  Assert.IsFalse(TStringUtils.ContainsCmdMetaChars('plain-value_1.txt'));
end;

procedure TStringUtilsTests.ContainsCmdUnsafeChars_DetectsExpansionAndQuotes;
begin
  Assert.IsTrue(TStringUtils.ContainsCmdUnsafeChars('%PATH%'));
  Assert.IsTrue(TStringUtils.ContainsCmdUnsafeChars('!x!'));
  Assert.IsTrue(TStringUtils.ContainsCmdUnsafeChars('a"b'));
  Assert.IsTrue(TStringUtils.ContainsCmdUnsafeChars('a'#10'b'));
  Assert.IsFalse(TStringUtils.ContainsCmdUnsafeChars('a & b'));
end;

procedure TStringUtilsTests.CanTerminateTree_RejectsUnsafeIds;
begin
  Assert.IsFalse(TSystemUtils.CanTerminateTree(0));
  {$IFDEF MSWINDOWS}
  Assert.IsFalse(TSystemUtils.CanTerminateTree(4), 'System process');
  Assert.IsFalse(TSystemUtils.CanTerminateTree(GetCurrentProcessId), 'Own process');
  {$ELSE}
  Assert.IsFalse(TSystemUtils.CanTerminateTree(1), 'init - kill(-1) would signal everything');
  Assert.IsFalse(TSystemUtils.CanTerminateTree(Cardinal(getpid)), 'Own process');
  Assert.IsFalse(TSystemUtils.CanTerminateTree($FFFFFFFF), 'Negative as a pid_t');
  {$ENDIF}
  Assert.IsTrue(TSystemUtils.CanTerminateTree(12345));
end;

{$IFDEF MSWINDOWS}
function TestConvertSddl(StringSecurityDescriptor : PWideChar; StringSDRevision : DWORD; var SecurityDescriptor : Pointer;
                         SecurityDescriptorSize : PULONG) : BOOL; stdcall;
  external advapi32 name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

const
  cProcThreadAttributeParentProcess = $00020000;

// Starts a suspended cmd.exe, optionally under another parent process and
// with a security descriptor given in SDDL.
function StartSuspended(hParent : THandle; const sddl : string) : TProcessInformation;
var
  exe, command : string;
  security : TSecurityAttributes;
  pSecurity : PSecurityAttributes;
  descriptor : Pointer;
  startup : TVProcStartupInfoExW;
  attrList : Pointer;
  parentCopy : THandle;
  size : NativeUInt;
begin
  exe := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) + 'System32\cmd.exe';
  command := '"' + exe + '"';
  UniqueString(command);
  pSecurity := nil;
  descriptor := nil;
  attrList := nil;
  parentCopy := hParent;
  FillChar(security, SizeOf(security), 0);
  FillChar(startup, SizeOf(startup), 0);
  FillChar(result, SizeOf(result), 0);
  startup.StartupInfo.cb := SizeOf(startup);
  try
    if sddl <> '' then
    begin
      Assert.IsTrue(TestConvertSddl(PWideChar(sddl), 1, descriptor, nil), 'SDDL: ' + SysErrorMessage(GetLastError));
      security.nLength := SizeOf(security);
      security.lpSecurityDescriptor := descriptor;
      pSecurity := @security;
    end;
    if hParent <> 0 then
    begin
      size := 0;
      VProcInitializeProcThreadAttributeList(nil, 1, 0, size);
      GetMem(attrList, size);
      Assert.IsTrue(VProcInitializeProcThreadAttributeList(attrList, 1, 0, size), 'attribute list');
      Assert.IsTrue(VProcUpdateProcThreadAttribute(attrList, 0, cProcThreadAttributeParentProcess, @parentCopy, SizeOf(THandle), nil, nil),
                    'parent attribute: ' + SysErrorMessage(GetLastError));
      startup.lpAttributeList := attrList;
    end;
    Assert.IsTrue(VProcCreateProcessW(PWideChar(exe), PWideChar(command), pSecurity, nil, False,
                                      CREATE_SUSPENDED or CREATE_NO_WINDOW or VPROC_EXTENDED_STARTUPINFO_PRESENT, nil, nil,
                                      @startup, result), 'CreateProcess: ' + SysErrorMessage(GetLastError));
  finally
    if attrList <> nil then
    begin
      VProcDeleteProcThreadAttributeList(attrList);
      FreeMem(attrList);
    end;
    if descriptor <> nil then
      LocalFree(HLOCAL(descriptor));
  end;
end;

procedure DisposeProcess(const info : TProcessInformation);
begin
  if info.hProcess = 0 then
    exit;
  TerminateProcess(info.hProcess, 1);
  CloseHandle(info.hThread);
  CloseHandle(info.hProcess);
end;

procedure TStringUtilsTests.TerminateProcessTree_UnopenableChild_StillKillsGrandchild;
var
  root, child, grandchild : TProcessInformation;
  probe : THandle;
begin
  FillChar(root, SizeOf(root), 0);
  FillChar(child, SizeOf(child), 0);
  FillChar(grandchild, SizeOf(grandchild), 0);
  try
    root := StartSuspended(0, '');
    // Everyone may read the creation time; nobody may terminate it.
    child := StartSuspended(root.hProcess, 'D:(A;;0x1000;;;WD)');
    grandchild := StartSuspended(child.hProcess, '');

    probe := OpenProcess(PROCESS_TERMINATE, False, child.dwProcessId);
    if probe <> 0 then
    begin
      CloseHandle(probe);
      Assert.Fail('sanity: the middle process must not be openable for PROCESS_TERMINATE');
    end;
    TSystemUtils.TerminateProcessTree(root.dwProcessId, 7);
    Assert.AreEqual(Cardinal(WAIT_OBJECT_0), WaitForSingleObject(grandchild.hProcess, 5000),
                    'the grandchild below an unopenable child must be killed');
    Assert.AreEqual(Cardinal(WAIT_OBJECT_0), WaitForSingleObject(root.hProcess, 5000), 'the root must be killed');
    Assert.AreEqual(Cardinal(WAIT_TIMEOUT), WaitForSingleObject(child.hProcess, 0), 'the protected child cannot be killed');
  finally
    DisposeProcess(grandchild);
    DisposeProcess(child);
    DisposeProcess(root);
  end;
end;
{$ENDIF}

initialization
  TDUnitX.RegisterTestFixture(TStringUtilsTests);

end.
