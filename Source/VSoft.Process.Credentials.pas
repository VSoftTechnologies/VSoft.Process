{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright � Vincent Parrett and contributors                    }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit VSoft.Process.Credentials;

interface

uses
  VSoft.Process;

type
  TCredentialsBuilder = class(TInterfacedObject,ICredentialsBuilder)
  private
    FUserName : string;
    FDomain   : string;
    FPassword : string;
    FLoadProfile : boolean;
    FNetCredOnly : boolean;
  protected
    function GetDomain : string;
    procedure SetDomain(const value : string);
    function GetUserName : string;
    procedure SetUserName(const value : string);
    function GetPassword : string;
    procedure SetPassword(const value : string);
    function GetLoadUserProfile : boolean;
    procedure SetLoadUserProfile(value : boolean);
    function GetNetCredentialsOnly : boolean;
    procedure SetNetCredentialsOnly(value : boolean);

    function WithUser(const value : string) : ICredentialsBuilder;
    function WithDomain(const value : string) : ICredentialsBuilder;
    function WithPassword(const value : string) : ICredentialsBuilder;
    function WithUserProfile(value : boolean) : ICredentialsBuilder;
    function WithNetCredentialsOnly(value : boolean) : ICredentialsBuilder;


    function Clone : ICredentialsBuilder;
    function Validate(const errorProc : TConstProc<string>): boolean;

    constructor CreateClone(const source : TCredentialsBuilder);

  public
    destructor Destroy;override;
  end;

// Wipes a string holding a secret: when s alone references its buffer the
// buffer is zeroed in place, then s is cleared. A buffer still shared with
// another string, or a constant, is only released, never written to.
procedure ScrubString(var s : string);

implementation

uses
  System.SysUtils;

procedure ScrubString(var s : string);
begin
  // StringRefCount is -1 for a constant and above 1 when shared.
  if (Length(s) > 0) and (StringRefCount(s) = 1) then
    FillChar(Pointer(s)^, Length(s) * SizeOf(Char), 0);
  s := '';
end;

// Zeroes a buffer made by PrivateCopy, whatever else references it (it is
// always on the heap, so never read-only), then clears s.
procedure WipePrivate(var s : string);
begin
  if Length(s) > 0 then
    FillChar(Pointer(s)^, Length(s) * SizeOf(Char), 0);
  s := '';
end;

// Copies value into a new heap buffer, so the copy is never shared with the
// caller's string (or a constant) and can be zeroed in place.
function PrivateCopy(const value : string) : string;
begin
  SetString(result, PChar(value), Length(value));
end;

{ TCredentialsBuilder }

destructor TCredentialsBuilder.Destroy;
begin
  // Scrub the password before the heap reclaims it. FPassword is a buffer
  // only this builder owns (copied in when set), so zeroing it reaches the
  // only copy this object holds. Copies handed out by GetPassword are the
  // caller's to scrub (ScrubString).
  WipePrivate(FPassword);
  inherited;
end;

function TCredentialsBuilder.Clone: ICredentialsBuilder;
begin
  result := TCredentialsBuilder.CreateClone(self);
end;

constructor TCredentialsBuilder.CreateClone(const source: TCredentialsBuilder);
begin
  inherited Create;
  FUserName := source.FUserName;
  FDomain := source.FDomain;
  FPassword := PrivateCopy(source.FPassword);
  FLoadProfile := source.FLoadProfile;
  FNetCredOnly := source.FNetCredOnly;
end;

function TCredentialsBuilder.GetDomain: string;
begin
  result := FDomain;
end;

function TCredentialsBuilder.GetLoadUserProfile: boolean;
begin
  result := FLoadProfile;
end;

function TCredentialsBuilder.GetNetCredentialsOnly: boolean;
begin
  result := FNetCredOnly;
end;

function TCredentialsBuilder.GetPassword: string;
begin
  // A copy the caller owns, so our own buffer is never shared.
  result := PrivateCopy(FPassword);
end;

function TCredentialsBuilder.GetUserName: string;
begin
  result := FUserName;
end;

procedure TCredentialsBuilder.SetDomain(const value: string);
begin
  FDomain := value;
end;

procedure TCredentialsBuilder.SetLoadUserProfile(value: boolean);
begin
  FLoadProfile := value;
end;

procedure TCredentialsBuilder.SetNetCredentialsOnly(value: boolean);
begin
  FNetCredOnly := value;
end;

procedure TCredentialsBuilder.SetPassword(const value: string);
var
  copied : string;
begin
  // Copied before the wipe, in case value is the current password.
  copied := PrivateCopy(value);
  WipePrivate(FPassword);
  FPassword := copied;
end;

procedure TCredentialsBuilder.SetUserName(const value: string);
begin
  FUserName := value;
end;

function TCredentialsBuilder.Validate(const errorProc: TConstProc<string>): boolean;
begin
  result := true;
  // UPN-format (user@domain) usernames must not also set Domain - the Win32
  // logon APIs reject this combination and the error message is opaque.
  if (FDomain <> '') and (Pos('@', FUserName) > 0) then
  begin
    errorProc('If you use the UPN format for username (user@domain), the Domain property must be empty');
    result := false;
  end;
  // A down-level name (DOMAIN\user) is never split: with no Domain the logon
  // would look for an account of that whole name in the local account
  // database, and with a Domain it names two.
  if Pos('\', FUserName) > 0 then
  begin
    if FDomain = '' then
      errorProc('The DOMAIN\user format is not supported for UserName: set the Domain property and give UserName without the domain, or use the UPN format (user@domain)')
    else
      errorProc('The UserName must not contain a domain (DOMAIN\user) when the Domain property is set');
    result := false;
  end;
  // CreateProcessWithLogonW requires both a username AND a password.
  if (FUserName <> '') and (FPassword = '') then
  begin
    errorProc('A password is required when a UserName is specified');
    result := false;
  end;
  // Without a UserName no logon happens: the child would silently run as the
  // current user.
  if (FUserName = '') and ((FDomain <> '') or (FPassword <> '')) then
  begin
    errorProc('A UserName is required when a Domain or Password is specified');
    result := false;
  end;
end;

function TCredentialsBuilder.WithDomain(const value: string): ICredentialsBuilder;
begin
  FDomain := value;
  result := Self;
end;

function TCredentialsBuilder.WithNetCredentialsOnly(value: boolean): ICredentialsBuilder;
begin
  FNetCredOnly := value;
  result := Self;
end;

function TCredentialsBuilder.WithPassword(const value: string): ICredentialsBuilder;
begin
  SetPassword(value);
  result := Self;
end;

function TCredentialsBuilder.WithUser(const value: string): ICredentialsBuilder;
begin
  FUserName := value;
  result := Self;
end;

function TCredentialsBuilder.WithUserProfile(value: boolean): ICredentialsBuilder;
begin
  FLoadProfile := value;
  result := Self;
end;

end.
