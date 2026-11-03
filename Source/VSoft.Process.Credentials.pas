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

implementation

uses
  System.SysUtils;

{ TCredentialsBuilder }

procedure ZeroAndClearString(var s : string);
begin
  if Length(s) > 0 then
  begin
    // Make the string unique so we are zeroing our copy only, not a shared
    // reference still in use by another owner.
    UniqueString(s);
    FillChar(Pointer(s)^, Length(s) * SizeOf(Char), 0);
  end;
  s := '';
end;

destructor TCredentialsBuilder.Destroy;
begin
  // Best-effort secure scrub of the password before the heap reclaims it.
  // Reference counting will free the underlying buffer, but only after we
  // overwrite it with zeros. UniqueString is used to avoid scrubbing a
  // string still aliased elsewhere.
  ZeroAndClearString(FPassword);
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
  FPassword := source.FPassword;
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
  result := FPassword;
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
begin
  FPassword := value;
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
  FPassword := value;
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
