unit VSoft.Process.Tests.Credentials;

interface

uses
  DUnitX.TestFramework,
  VSoft.Process,
  VSoft.Process.Credentials;

type
  [TestFixture]
  TCredentialsTests = class
  public
    [Test]
    procedure FluentSetters_Apply;

    [Test]
    procedure Clone_CopiesAllFields;

    // C6 - the builder keeps the password in a buffer of its own (not shared
    // with the caller's string) and zeroes that buffer when it is destroyed.
    // The test holds an extra reference to the builder's buffer (read through
    // RTTI) so it outlives the builder and can be inspected afterwards.
    {$IFDEF MSWINDOWS}
    [Test]
    procedure Password_ZeroedOnDestroy;
    {$ENDIF}

    // W3 - Validate must reject a UPN-format username paired with a Domain.
    // CreateProcessWithLogonW rejects this combo with an opaque error; we
    // catch it earlier and return a clear message.
    [Test]
    procedure Validate_RejectsUpnUsernameWithDomain;

    // W3 - Validate must reject UserName-without-Password. The Win32 logon
    // APIs require both.
    [Test]
    procedure Validate_RejectsUserNameWithoutPassword;

    // W3 - Validate must accept a clean UserName+Password combination with no domain.
    [Test]
    procedure Validate_AcceptsCleanUserAndPassword;

    // W3 - Validate must accept Domain + sAMAccountName + Password (the classic shape).
    [Test]
    procedure Validate_AcceptsDomainPlusUserAndPassword;

    // A Domain or Password without a UserName would otherwise be ignored and
    // the child run as the current user.
    [Test]
    procedure Validate_RejectsDomainWithoutUserName;
    [Test]
    procedure Validate_RejectsPasswordWithoutUserName;
    [Test]
    procedure Execute_PasswordWithoutUserName_IsRejected;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  System.Rtti,
  {$ENDIF}
  System.SysUtils,
  VSoft.Process.Tests.Common;

function MakeBuilder : ICredentialsBuilder;
begin
  result := TCredentialsBuilder.Create;
end;

procedure TCredentialsTests.FluentSetters_Apply;
var
  creds : ICredentialsBuilder;
begin
  creds := MakeBuilder;
  creds.WithUser('alice')
       .WithDomain('CORP')
       .WithPassword('hunter2')
       .WithUserProfile(True)
       .WithNetCredentialsOnly(False);
  Assert.AreEqual('alice',   creds.UserName);
  Assert.AreEqual('CORP',    creds.Domain);
  Assert.AreEqual('hunter2', creds.Password);
  Assert.IsTrue(creds.LoadUserProfile);
  Assert.IsFalse(creds.NetCredentialsOnly);
end;

procedure TCredentialsTests.Clone_CopiesAllFields;
var
  src, dst : ICredentialsBuilder;
begin
  src := MakeBuilder;
  src.WithUser('bob').WithDomain('OFFICE').WithPassword('p@ss').WithUserProfile(True);
  dst := src.Clone;
  Assert.AreEqual('bob',    dst.UserName);
  Assert.AreEqual('OFFICE', dst.Domain);
  Assert.AreEqual('p@ss',   dst.Password);
  Assert.IsTrue(dst.LoadUserProfile);
end;

{$IFDEF MSWINDOWS}
procedure TCredentialsTests.Password_ZeroedOnDestroy;
var
  builder : TCredentialsBuilder;
  creds : ICredentialsBuilder;
  secret : string;
  held : string;
  ctx : TRttiContext;
  field : TRttiField;
  i : integer;
begin
  // A heap string of the caller's own, as a password usually is.
  secret := 'super-secret-' + IntToStr(GetTickCount mod 1000) + '-password';
  builder := TCredentialsBuilder.Create;
  creds := builder;
  creds.Password := secret; // not WithPassword: its result would hold a hidden reference
  field := ctx.GetType(TCredentialsBuilder).GetField('FPassword');
  Assert.IsNotNull(field, 'FPassword field not found through RTTI');
  // An extra reference to the builder's own buffer keeps it alive after the
  // builder is destroyed, so what the destructor did to it can be seen.
  held := PString(PByte(builder) + field.Offset)^;
  Assert.AreEqual(secret, held, false, 'sanity: the builder holds the password');
  Assert.IsTrue(Pointer(held) <> Pointer(secret), 'the builder shares the caller''s buffer instead of keeping its own');
  creds := nil; // the only reference: destroys the builder
  for i := 1 to Length(held) do
    if held[i] <> #0 then
      Assert.Fail('the builder''s password buffer was not zeroed when it was destroyed');
end;
{$ENDIF}

// Helper that captures the error string Validate passes to its errorProc.
type
  TValidateErrorSink = class
  public
    Last : string;
    procedure Capture(const value : string);
  end;

procedure TValidateErrorSink.Capture(const value: string);
begin
  Last := value;
end;

procedure TCredentialsTests.Validate_RejectsUpnUsernameWithDomain;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
  ok    : boolean;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithUser('alice@example.com')
         .WithDomain('CORP')
         .WithPassword('hunter2');
    ok := creds.Validate(sink.Capture);
    Assert.IsFalse(ok, 'UPN-format user + non-empty Domain must fail Validate');
    Assert.IsTrue(Pos('UPN', sink.Last) > 0,
                  'Error message should mention UPN format');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Validate_RejectsUserNameWithoutPassword;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
  ok    : boolean;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithUser('alice');
    // No WithPassword call - FPassword is empty.
    ok := creds.Validate(sink.Capture);
    Assert.IsFalse(ok, 'UserName without Password must fail Validate');
    Assert.IsTrue(Pos('password', LowerCase(sink.Last)) > 0,
                  'Error message should mention password');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Validate_AcceptsCleanUserAndPassword;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithUser('alice').WithPassword('hunter2');
    Assert.IsTrue(creds.Validate(sink.Capture),
                  'Bare user + password (no domain) is a valid combination');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Validate_AcceptsDomainPlusUserAndPassword;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithUser('alice').WithDomain('CORP').WithPassword('hunter2');
    Assert.IsTrue(creds.Validate(sink.Capture),
                  'CORP\alice with password is the canonical combination');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Validate_RejectsDomainWithoutUserName;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithDomain('CORP');
    Assert.IsFalse(creds.Validate(sink.Capture), 'Domain without UserName must fail Validate');
    Assert.Contains(sink.Last, 'UserName is required');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Validate_RejectsPasswordWithoutUserName;
var
  creds : ICredentialsBuilder;
  sink  : TValidateErrorSink;
begin
  sink := TValidateErrorSink.Create;
  try
    creds := MakeBuilder;
    creds.WithPassword('hunter2');
    Assert.IsFalse(creds.Validate(sink.Capture), 'Password without UserName must fail Validate');
    Assert.Contains(sink.Last, 'UserName is required');
  finally
    sink.Free;
  end;
end;

procedure TCredentialsTests.Execute_PasswordWithoutUserName_IsRejected;
var
  proc : IProcess;
begin
  proc := TProcess.Create;
  TTestHelpers.SetupInlineCommand(proc, 'exit 0', 'exit 0');
  proc.Credentials.Password := 'hunter2';
  Assert.IsFalse(proc.Execute, 'the child must not be run as the current user');
  Assert.AreEqual<Cardinal>(0, proc.ProcessId);
  {$IFDEF MSWINDOWS}
  Assert.Contains(proc.Errors.Text, 'UserName is required');
  {$ENDIF}
end;

initialization
  TDUnitX.RegisterTestFixture(TCredentialsTests);

end.
