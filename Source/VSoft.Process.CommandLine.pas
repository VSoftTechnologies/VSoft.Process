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

unit VSoft.Process.CommandLine;

interface

uses
  System.Generics.Collections,
  VSoft.Process;

type
  IArgumentInternal = interface
  ['{40950927-3416-4BC9-96F1-8E86BB8075E1}']
    function Clone : IArgument;
  end;

  TArgument = class(TInterfacedObject, IArgument, IArgumentInternal)
  private
    FName       : string;
    FValue      : string;
    FNameSeparator : string;
    FQuoted     : TQuoted;
    FQuoteName  : boolean;
  protected
    function GetNameSep: String;
    function GetName: String;
    function GetQuoted: TQuoted;
    function GetValue: String;
    procedure SetNameSep(const avalue: String);
    procedure SetName(const avalue: String);
    procedure SetQuoted(const avalue: TQuoted);
    procedure SetValue(const avalue: String);
    function GetQuoteName : boolean;
    procedure SetQuoteName(const Value : boolean);

    function ToLogString: string; virtual; // Overriden to hide passwords from the log

    function Clone : IArgument; virtual;

    constructor CreateClone(const source : TArgument);
  public
    constructor Create(const AName : string; const AValue : string);
    function ToString: string;override;
  end;

  TSensitiveArgument = class(TArgument)
  protected
    // Build a render of this arg with the value replaced by a fixed mask
    // string before any string concatenation. This avoids the fragile pattern
    // of rendering the full string then StringReplace'ing the value out
    // (which fails when the value is empty, is a substring of the name, or
    // appears elsewhere in the line).
    function BuildRendered(const maskValue : boolean) : string;
    function ToLogString: string; override;
    // A clone must stay sensitive, or the cloned command line logs the secret.
    function Clone : IArgument; override;
  public
    function ToString : string; override;
  end;

  TArgumentsBuilder = class(TInterfacedObject, ICommandLineBuilder)
  private
    FArgs : TList<IArgument>;
    FDefaultValueSeparator : string;
    FDefaultArgumentSeparator : string;
  protected
    function CreateArgument(const name : string; const value : string = ''; const Quoted : TQuoted = TQuoted.qtDouble) : IArgument;
    function CreateSensitiveArgument(const name : string; const value : string; const Quoted : TQuoted) : IArgument;
    function CreateSensitveArgument(const name : string; const value : string; const Quoted : TQuoted) : IArgument; deprecated 'Use CreateSensitiveArgument';


    function GetDefValueSep : string;
    procedure SetDefValueSep(const value : string);
    function GetDefArgSep : string;
    procedure SetDefArgSep(const value : string);
    function GetCount : integer;
    function GetArgument(const index : integer) : IArgument;
    function GetArgumentByName(const index : string) : IArgument;

    //adds a new argument
    function Add(const name : string; //the argument name
                         const value : string; //the argument value, options
                         const Quoted : TQuoted = TQuoted.qtDouble //quoting on the argument, doublequotes by default
                         ) : ICommandLineBuilder;overload;
    function Add(const name : string; //the argument name
                         const Quoted : TQuoted = TQuoted.qtDouble
                         ) : ICommandLineBuilder;overload;

    //adds a new Sensitive argument (like passwords), the value section will not be displayed in the log
    function AddSensitive(const name : string; //the argument name
                         const value : string; //the argument value, options
                         const Quoted : TQuoted = TQuoted.qtDouble //quoting on the argument, doublequotes by default
                         ) : ICommandLineBuilder;overload;
    function AddSensitive(const name : string; //the argument name
                         const Quoted : TQuoted = TQuoted.qtDouble //quoting on the argument, doublequotes by default
                         ) : ICommandLineBuilder;overload;

    //removes an argument from the command line
    function Remove(const arg : IArgument) : ICommandLineBuilder;overload;

    //removes an argument from the command line
    function Remove(const name : string) : ICommandLineBuilder;overload;

    //clear the command line builder
    function Clear : ICommandLineBuilder;

    function WithDefaultValueSeparator(const value : string) : ICommandLineBuilder;

    function WithDefaultArgumentSeparator(const value : string) : ICommandLineBuilder;

    // gets the command line as a string which is safe to log (sensite masked)
    function ToLogString : string;

    function Clone : ICommandLineBuilder;

    constructor CreateClone(const source : TArgumentsBuilder);

  public
    constructor Create;
    destructor Destroy;override;
    //gets the command line as a string
    function ToString : string;override;
  end;

implementation

uses
  System.SysUtils,
  VSoft.Process.Utils;

{ TArgument }

function TArgument.Clone: IArgument;
begin
  result := TArgument.CreateClone(self);
end;

constructor TArgument.Create(const AName, AValue: string);
begin
  inherited Create;
  FName := AName;
  FValue := AValue;
  FQuoted := TQuoted.qtAutoDouble;
  FNameSeparator := ' ';
  FQuoteName := False;
end;

constructor TArgument.CreateClone(const source: TArgument);
begin
  inherited Create;
  FName       := source.FName;
  FValue      := source.FValue;
  FNameSeparator := source.FNameSeparator;
  FQuoted     := source.FQuoted;
  FQuoteName  := source.FQuoteName;
end;

function TArgument.ToLogString: String;
begin
  Result := ToString;
end;

function EmptyArgument(quoted : TQuoted) : string;
begin
  if quoted in [TQuoted.qtSingle, TQuoted.qtAutoSingle] then
    result := ''''''
  else
    result := '""';
end;

// Quotes a name or value by the argument's quoting style. When allowForced
// is False, qtSingle / qtDouble fall back to the auto rule of the same family
// (quote only when the text is empty or holds a space, tab or "), so a switch
// such as -v stays bare while a path with spaces stays one argument.
function QuotePart(const text : string; const quoted : TQuoted; const allowForced : boolean) : string;
begin
  case quoted of
    TQuoted.qtSingle     : result := TStringUtils.QuoteString(text, not allowForced);
    TQuoted.qtDouble     : result := TStringUtils.DoubleQuoteString(text, not allowForced);
    TQuoted.qtAutoSingle : result := TStringUtils.QuoteString(text, True);
    TQuoted.qtAutoDouble : result := TStringUtils.DoubleQuoteString(text, True);
  else
    result := text;
  end;
end;

function TArgument.ToString: string;
begin
  // Add('', '') is an explicit empty argument.
  if (FName = '') and (FValue = '') then
    Exit(EmptyArgument(FQuoted));
  // Add(name): a switch or a bare value. It is quoted when it needs to be,
  // or always when QuoteName is set; qtNone leaves it as given.
  if FValue = '' then
    Exit(QuotePart(FName, FQuoted, FQuoteName));
  result := '';
  if FName <> '' then
    result := QuotePart(FName, FQuoted, False) + FNameSeparator;
  result := result + QuotePart(FValue, FQuoted, True);
end;

function TArgument.GetNameSep: String;
begin
  result := FNameSeparator;
end;

function TArgument.GetName: String;
begin
  result := FName;
end;

function TArgument.GetQuoted: TQuoted;
begin
  result := FQuoted;
end;

function TArgument.GetValue: String;
begin
  result := FValue;
end;

procedure TArgument.SetNameSep(const avalue: String);
begin
  FNameSeparator := avalue;
end;

procedure TArgument.SetName(const avalue: String);
begin
  FName := avalue;
end;

procedure TArgument.SetQuoted(const avalue: TQuoted);
begin
  FQuoted := avalue;
end;

procedure TArgument.SetValue(const avalue: String);
begin
  FValue := avalue;
end;


function TArgument.GetQuoteName: boolean;
begin
  result := FQuoteName;
end;

procedure TArgument.SetQuoteName(const Value: boolean);
begin
  FQuoteName := Value;
end;


function TSensitiveArgument.BuildRendered(const maskValue : boolean) : string;
const
  cMask = '****';
begin
  // Mirror TArgument.ToString but substitute the mask token in place of the
  // real value so we never produce a string containing the secret that we
  // then have to scrub.
  if (FName = '') and (FValue = '') then
    Exit(EmptyArgument(FQuoted));
  if FValue = '' then
  begin
    // AddSensitive(name): the whole argument is the secret
    // ('--password=secret', a token passed on its own).
    if maskValue then
      Exit(cMask);
    Exit(QuotePart(FName, FQuoted, FQuoteName));
  end;
  result := '';
  if FName <> '' then
    result := QuotePart(FName, FQuoted, False) + FNameSeparator;
  if maskValue then
    result := result + cMask
  else
    result := result + QuotePart(FValue, FQuoted, True);
end;

function TSensitiveArgument.Clone : IArgument;
begin
  result := TSensitiveArgument.CreateClone(self);
end;

function TSensitiveArgument.ToString : string;
begin
  result := BuildRendered(False);
end;

function TSensitiveArgument.ToLogString : string;
begin
  result := BuildRendered(True);
end;


{ TArgumentsBuilder }

function TArgumentsBuilder.Add(const name, value: string; const Quoted: TQuoted): ICommandLineBuilder;
var
  arg : IArgument;
begin
  result := Self;
  arg := CreateArgument(name,value,Quoted);
  FArgs.Add(arg);
end;

function TArgumentsBuilder.Add(const name: string; const Quoted: TQuoted): ICommandLineBuilder;
var
  arg : IArgument;
begin
  result := Self;
  arg := CreateArgument(name,'',Quoted);
  FArgs.Add(arg);
end;

function TArgumentsBuilder.AddSensitive(const name, value: string; const Quoted: TQuoted): ICommandLineBuilder;
var
  arg : IArgument;
begin
  result := Self;
  arg := CreateSensitiveArgument(name,value,Quoted);
  FArgs.Add(arg);
end;

function TArgumentsBuilder.AddSensitive(const name: string; const Quoted: TQuoted): ICommandLineBuilder;
var
  arg : IArgument;
begin
  result := Self;
  arg := CreateSensitiveArgument(name,'',Quoted);
  FArgs.Add(arg);
end;

function TArgumentsBuilder.Clear : ICommandLineBuilder;
begin
  result := Self;
  FArgs.Clear;
end;

function TArgumentsBuilder.Clone : ICommandLineBuilder;
begin
  result := TArgumentsBuilder.CreateClone(self);
end;

constructor TArgumentsBuilder.Create;
begin
  FArgs := TList<IArgument>.Create;
  FDefaultValueSeparator := ' ';
  FDefaultArgumentSeparator := ' ';
end;

function TArgumentsBuilder.CreateArgument(const name, value: string; const Quoted: TQuoted): IArgument;
begin
  result := TArgument.Create(name,value);
  result.NameValueSeparator := FDefaultValueSeparator;
  result.Quoted := Quoted;
end;

constructor TArgumentsBuilder.CreateClone(const source: TArgumentsBuilder);
var
  i: Integer;
  arg : IArgument;
begin
  Create;
  FDefaultValueSeparator := source.FDefaultValueSeparator;
  FDefaultArgumentSeparator := source.FDefaultArgumentSeparator;
  for i := 0 to source.FArgs.Count -1 do
  begin
    arg := (source.FArgs[i] as IArgumentInternal).Clone;
    FArgs.Add(arg);
  end;
end;

function TArgumentsBuilder.CreateSensitiveArgument(const name, value: string; const Quoted: TQuoted): IArgument;
begin
  result := TSensitiveArgument.Create(name,value);
  result.NameValueSeparator := FDefaultValueSeparator;
  result.Quoted := Quoted;
end;

function TArgumentsBuilder.CreateSensitveArgument(const name, value: string; const Quoted: TQuoted): IArgument;
begin
  result := CreateSensitiveArgument(name, value, Quoted);
end;

destructor TArgumentsBuilder.Destroy;
begin
  FArgs.Free;
  inherited;
end;

function TArgumentsBuilder.GetArgument(const index: integer): IArgument;
begin
  if (index >= 0) and (index < FArgs.Count) then
    result := FArgs.Items[index]
  else
    result := nil;
end;

function TArgumentsBuilder.GetArgumentByName(const index: string): IArgument;
var
  i: Integer;
begin
  result := nil;
  for i := 0 to FArgs.Count - 1 do    // Iterate
  begin
    if FArgs.Items[i].Name = index then
    begin
      result := FArgs.Items[i];
      break;
    end;
  end;    // for
end;

function TArgumentsBuilder.GetCount: integer;
begin
  result := FArgs.Count;
end;

function TArgumentsBuilder.GetDefArgSep: string;
begin
  result := FDefaultArgumentSeparator;
end;

function TArgumentsBuilder.GetDefValueSep: string;
begin
  result := FDefaultValueSeparator;
end;

function TArgumentsBuilder.Remove(const arg: IArgument): ICommandLineBuilder;
begin
  result := Self;
  FArgs.Remove(arg);
end;

function TArgumentsBuilder.Remove(const name: string): ICommandLineBuilder;
var
  arg : IArgument;
begin
  arg := GetArgumentByName(name);
  if arg <> nil then
    Remove(arg);
  result := Self;

end;

procedure TArgumentsBuilder.SetDefArgSep(const value: string);
begin
  FDefaultArgumentSeparator := value;
end;

procedure TArgumentsBuilder.SetDefValueSep(const value: string);
begin
  FDefaultValueSeparator := value;
end;

function TArgumentsBuilder.ToLogString: string;
var
  i: Integer;
  arg : IArgument;
begin
  result := '';
  for i := 0 to Fargs.Count - 1 do
  begin
    arg := FArgs.Items[i];
    result := result + arg.ToLogString;
    if i < Fargs.Count - 1 then
      result := result + FDefaultArgumentSeparator;
  end;    // for
end;

function TArgumentsBuilder.ToString: string;
var
  i: Integer;
  arg : IArgument;
begin
  result := '';
  for i := 0 to Fargs.Count - 1 do
  begin
    arg := FArgs.Items[i];
    result := result + arg.ToString;
    if i < Fargs.Count - 1 then
      result := result + FDefaultArgumentSeparator;
  end;    // for
end;

function TArgumentsBuilder.WithDefaultArgumentSeparator(const value: string): ICommandLineBuilder;
begin
  FDefaultArgumentSeparator := value;
  result := Self;
end;

function TArgumentsBuilder.WithDefaultValueSeparator(const value: string): ICommandLineBuilder;
begin
  FDefaultValueSeparator := value;
  result := Self;

end;

end.
