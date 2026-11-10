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

unit VSoft.Process.StartInfo;

interface

uses
  System.Generics.Collections,
  System.SysUtils,
  VSoft.Process;

type
  TStartInfoBuilder = class(TInterfacedObject, IStartInfoBuilder)
  private
    FHideWindow : boolean;
    FTimeout    : Cardinal;
    FExecutable : string;
    FArgvZero   : string;
    FWorkingDir : string;
    FProcessorAffinity : NativeUInt;
    FPriority : TProcessPriority;
    FTerminateExitCode : Cardinal;
    FTimedOutExitCode : Cardinal;
    FInputEncoding : TEncoding;
    FOutputEncoding : TEncoding;
    FPipeBufferSize : Cardinal;
    FMarshallEventsToMainThread : boolean;
    FPipeDrainTimeoutMS : Cardinal;
    FJobMode : TProcessJobMode;
    FTerminateOnTimeout : boolean;
    FDetachedNewConsole : boolean;
    FInheritHostStdHandles : boolean;
    FDeliverOnRunThread : boolean;
  protected
    function GetHideWindow : boolean;
    procedure SetHideWindow(value : boolean);
    function GetTimeoutMS : Cardinal;
    procedure SetTimeoutMS(value : Cardinal);
    function GetExecutable : string;
    procedure SetExecutable(const value : string);
    function GetArgvZero : string;
    procedure SetArgvZero(const value : string);
    function GetWorkingDir : string;
    procedure SetWorkingDir(const value : string);
    function GetProcessorAffinity: NativeUInt;
    procedure SetProcessorAffinity(value : NativeUInt);
    function GetPriority : TProcessPriority;
    procedure SetPriority(value : TProcessPriority);
    function GetTerminateExitCode: Cardinal;
    procedure SetTerminateExitCode(value : Cardinal);
    function GetTimedOutExitCode: Cardinal;
    procedure SetTimedOutExitCode(value : Cardinal);
    function GetInputEncoding: TEncoding;
    procedure SetInputEncoding(const value: TEncoding);
    function GetOutputEncoding: TEncoding;
    procedure SetOutputEncoding(const value: TEncoding);
    function GetPipeBufferSize : Cardinal;
    procedure SetPipeBufferSize(value : Cardinal);
    function GetMarshallEventsToMainThread : boolean;
    procedure SetMarshallEventsToMainThread(value : boolean);
    function GetPipeDrainTimeoutMS : Cardinal;
    procedure SetPipeDrainTimeoutMS(value : Cardinal);
    function GetJobMode : TProcessJobMode;
    procedure SetJobMode(value : TProcessJobMode);
    function GetTerminateOnTimeout : boolean;
    procedure SetTerminateOnTimeout(value : boolean);
    function GetDetachedNewConsole : boolean;
    procedure SetDetachedNewConsole(value : boolean);
    function GetInheritHostStdHandles : boolean;
    procedure SetInheritHostStdHandles(value : boolean);
    function GetDeliverOnRunThread : boolean;
    procedure SetDeliverOnRunThread(value : boolean);


    function WithTimeout(timeoutMs : Cardinal) : IStartInfoBuilder;
    function WithExecutable(const value : string) : IStartInfoBuilder;
    function WithArgvZero(const value : string) : IStartInfoBuilder;
    function WithHideWindow(value : boolean) : IStartInfoBuilder;
    function WithWorkingDirectory(const value : string) : IStartInfoBuilder;
    function WithProcessorAffinity(value : NativeUInt) : IStartInfoBuilder;
    function WithPriority(value : TProcessPriority) : IStartInfoBuilder;
    function WithTerminateExitCode(value : Cardinal) : IStartInfoBuilder;
    function WithTimedOutExitCode(value : Cardinal) : IStartInfoBuilder;
    function WithInputEncoding(const value: TEncoding) : IStartInfoBuilder;
    function WithOutputEncoding(const value: TEncoding) : IStartInfoBuilder;
    function WithPipeBufferSize(value : Cardinal) : IStartInfoBuilder;
    function WithMarshallEventsToMainThread(value : boolean) : IStartInfoBuilder;
    function WithPipeDrainTimeout(value : Cardinal) : IStartInfoBuilder;
    function WithJobMode(value : TProcessJobMode) : IStartInfoBuilder;
    function WithTerminateOnTimeout(value : boolean) : IStartInfoBuilder;
    function WithDetachedNewConsole(value : boolean) : IStartInfoBuilder;
    function WithInheritHostStdHandles(value : boolean) : IStartInfoBuilder;
    function WithDeliverOnRunThread(value : boolean) : IStartInfoBuilder;


    function Clone : IStartInfoBuilder;

    constructor CreateClone(const source : TStartInfoBuilder);
  public
    constructor Create;
    destructor Destroy;override;
  end;

implementation

{ TProcessStartInfo }

function TStartInfoBuilder.Clone: IStartInfoBuilder;
begin
  result := TStartInfoBuilder.CreateClone(self);
end;

constructor TStartInfoBuilder.Create;
begin
  FHideWindow := true;
  FTimeout    := 0;
  FProcessorAffinity := 0;
  FPriority := TProcessPriority.Normal;
  FTimedOutExitCode := EXIT_TIMEDOUT;
  FTerminateExitCode := EXIT_TERMINATED;
  FPipeBufferSize := 0; // 0 = use platform default (64KB)
  FMarshallEventsToMainThread := false;
  FPipeDrainTimeoutMS := DEFAULT_PIPE_DRAIN_TIMEOUT_MS;
  FJobMode := TProcessJobMode.KillOnRelease;
  FTerminateOnTimeout := true;
  FDetachedNewConsole := false;
  FInheritHostStdHandles := false;
  FDeliverOnRunThread := false;
end;

constructor TStartInfoBuilder.CreateClone(const source: TStartInfoBuilder);
begin
  Create;
  FHideWindow := source.FHideWindow;
  FTimeout    := source.FTimeout;
  FExecutable := source.FExecutable;
  FArgvZero   := source.FArgvZero;
  FWorkingDir := source.FWorkingDir;
  FProcessorAffinity := source.FProcessorAffinity;
  FPriority := source.FPriority;
  FInputEncoding := source.FInputEncoding;
  FOutputEncoding := source.FOutputEncoding;
  FTerminateExitCode := source.FTerminateExitCode;
  FTimedOutExitCode := source.FTimedOutExitCode;
  FPipeBufferSize := source.FPipeBufferSize;
  FMarshallEventsToMainThread := source.FMarshallEventsToMainThread;
  FJobMode := source.FJobMode;
  FTerminateOnTimeout := source.FTerminateOnTimeout;
  FPipeDrainTimeoutMS := source.FPipeDrainTimeoutMS;
  FDetachedNewConsole := source.FDetachedNewConsole;
  FInheritHostStdHandles := source.FInheritHostStdHandles;
  FDeliverOnRunThread := source.FDeliverOnRunThread;
end;

destructor TStartInfoBuilder.Destroy;
begin

  inherited;
end;

function TStartInfoBuilder.GetExecutable: string;
begin
  result := FExecutable;
end;

function TStartInfoBuilder.GetArgvZero: string;
begin
  result := FArgvZero;
end;

function TStartInfoBuilder.GetHideWindow: boolean;
begin
  result := FHideWindow;
end;

function TStartInfoBuilder.GetMarshallEventsToMainThread: boolean;
begin
  result := FMarshallEventsToMainThread;
end;

function TStartInfoBuilder.GetPipeBufferSize: Cardinal;
begin
  result := FPipeBufferSize;
end;

function TStartInfoBuilder.GetProcessorAffinity: NativeUInt;
begin
  result := FProcessorAffinity;
end;

function TStartInfoBuilder.GetTerminateExitCode: Cardinal;
begin
  result := FTerminateExitCode;
end;

function TStartInfoBuilder.GetPriority: TProcessPriority;
begin
  result := FPriority;
end;

function TStartInfoBuilder.GetPipeDrainTimeoutMS: Cardinal;
begin
  result := FPipeDrainTimeoutMS;
end;

function TStartInfoBuilder.GetJobMode: TProcessJobMode;
begin
  result := FJobMode;
end;

function TStartInfoBuilder.GetTerminateOnTimeout: boolean;
begin
  result := FTerminateOnTimeout;
end;

function TStartInfoBuilder.GetDetachedNewConsole : boolean;
begin
  result := FDetachedNewConsole;
end;

function TStartInfoBuilder.GetInheritHostStdHandles : boolean;
begin
  result := FInheritHostStdHandles;
end;

function TStartInfoBuilder.GetDeliverOnRunThread : boolean;
begin
  result := FDeliverOnRunThread;
end;

function TStartInfoBuilder.GetTimedOutExitCode: Cardinal;
begin
  result := FTimedOutExitCode;
end;

function TStartInfoBuilder.GetTimeoutMS: Cardinal;
begin
  result := FTimeout;
end;

function TStartInfoBuilder.GetWorkingDir: string;
begin
  result := FWorkingDir;
end;

function TStartInfoBuilder.GetInputEncoding: TEncoding;
begin
  result := FInputEncoding;
end;

function TStartInfoBuilder.GetOutputEncoding: TEncoding;
begin
  result := FOutputEncoding;
end;

procedure TStartInfoBuilder.SetExecutable(const value: string);
begin
  FExecutable := value;
end;

procedure TStartInfoBuilder.SetArgvZero(const value: string);
begin
  FArgvZero := value;
end;

procedure TStartInfoBuilder.SetHideWindow(value: boolean);
begin
  FHideWindow := value;
end;

procedure TStartInfoBuilder.SetMarshallEventsToMainThread(value: boolean);
begin
  FMarshallEventsToMainThread := value;
end;

procedure TStartInfoBuilder.SetPipeBufferSize(value: Cardinal);
begin
  FPipeBufferSize := value;
end;

procedure TStartInfoBuilder.SetProcessorAffinity(value: NativeUInt);
begin
  FProcessorAffinity := value;
end;

procedure TStartInfoBuilder.SetTerminateExitCode(value: Cardinal);
begin
  FTerminateExitCode := value;
end;

procedure TStartInfoBuilder.SetPriority(value: TProcessPriority);
begin
  FPriority := value;
end;

procedure TStartInfoBuilder.SetPipeDrainTimeoutMS(value: Cardinal);
begin
  FPipeDrainTimeoutMS := value;
end;

procedure TStartInfoBuilder.SetJobMode(value: TProcessJobMode);
begin
  FJobMode := value;
end;

procedure TStartInfoBuilder.SetTerminateOnTimeout(value: boolean);
begin
  FTerminateOnTimeout := value;
end;

procedure TStartInfoBuilder.SetDetachedNewConsole(value : boolean);
begin
  FDetachedNewConsole := value;
end;

procedure TStartInfoBuilder.SetInheritHostStdHandles(value : boolean);
begin
  FInheritHostStdHandles := value;
end;

procedure TStartInfoBuilder.SetDeliverOnRunThread(value : boolean);
begin
  FDeliverOnRunThread := value;
end;

procedure TStartInfoBuilder.SetTimedOutExitCode(value: Cardinal);
begin
  FTimedOutExitCode := value;
end;

procedure TStartInfoBuilder.SetTimeoutMS(value: Cardinal);
begin
  FTimeout := value;
end;

procedure TStartInfoBuilder.SetWorkingDir(const value: string);
begin
  FWorkingDir := value;
end;

procedure TStartInfoBuilder.SetInputEncoding(const value: TEncoding);
begin
  FInputEncoding := value;
end;

procedure TStartInfoBuilder.SetOutputEncoding(const value: TEncoding);
begin
  FOutputEncoding := value;
end;

function TStartInfoBuilder.WithExecutable(const value: string): IStartInfoBuilder;
begin
  FExecutable := value;
  result := Self;
end;

function TStartInfoBuilder.WithArgvZero(const value: string): IStartInfoBuilder;
begin
  FArgvZero := value;
  result := Self;
end;

function TStartInfoBuilder.WithHideWindow(value: boolean): IStartInfoBuilder;
begin
  FHideWindow := value;
  result := Self;
end;

function TStartInfoBuilder.WithMarshallEventsToMainThread(value: boolean): IStartInfoBuilder;
begin
  FMarshallEventsToMainThread := value;
  result := Self;
end;

function TStartInfoBuilder.WithPipeBufferSize(value: Cardinal): IStartInfoBuilder;
begin
  FPipeBufferSize := value;
  result := Self;
end;

function TStartInfoBuilder.WithProcessorAffinity(value: NativeUInt): IStartInfoBuilder;
begin
  FProcessorAffinity := value;
  result := Self;
end;

function TStartInfoBuilder.WithTerminateExitCode(value: Cardinal): IStartInfoBuilder;
begin
  FTerminateExitCode := value;
  result := Self;
end;

function TStartInfoBuilder.WithPriority(value: TProcessPriority): IStartInfoBuilder;
begin
  FPriority := value;
  result := Self;
end;

function TStartInfoBuilder.WithPipeDrainTimeout(value: Cardinal): IStartInfoBuilder;
begin
  FPipeDrainTimeoutMS := value;
  result := Self;
end;

function TStartInfoBuilder.WithJobMode(value: TProcessJobMode): IStartInfoBuilder;
begin
  FJobMode := value;
  result := Self;
end;

function TStartInfoBuilder.WithTerminateOnTimeout(value: boolean): IStartInfoBuilder;
begin
  FTerminateOnTimeout := value;
  result := Self;
end;

function TStartInfoBuilder.WithDetachedNewConsole(value : boolean) : IStartInfoBuilder;
begin
  FDetachedNewConsole := value;
  result := Self;
end;

function TStartInfoBuilder.WithInheritHostStdHandles(value : boolean) : IStartInfoBuilder;
begin
  FInheritHostStdHandles := value;
  result := Self;
end;

function TStartInfoBuilder.WithDeliverOnRunThread(value : boolean) : IStartInfoBuilder;
begin
  FDeliverOnRunThread := value;
  result := Self;
end;

function TStartInfoBuilder.WithTimedOutExitCode(value: Cardinal): IStartInfoBuilder;
begin
  FTimedOutExitCode := value;
  result := Self;
end;

function TStartInfoBuilder.WithTimeout(timeoutMs: Cardinal): IStartInfoBuilder;
begin
  FTimeout := timeoutMs;
  result := Self;
end;

function TStartInfoBuilder.WithWorkingDirectory(const value: string): IStartInfoBuilder;
begin
  FWorkingDir := value;
  result := Self;
end;

function TStartInfoBuilder.WithInputEncoding(const value: TEncoding): IStartInfoBuilder;
begin
  FInputEncoding := value;
  result := Self;
end;

function TStartInfoBuilder.WithOutputEncoding(const value: TEncoding): IStartInfoBuilder;
begin
  FOutputEncoding := value;
  result := Self;
end;

end.
