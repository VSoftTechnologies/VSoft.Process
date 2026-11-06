{***************************************************************************}
{                                                                           }
{           VSoft.Process - Process Execution for Delphi                    }
{                                                                           }
{           Copyright © Vincent Parrett and contributors                    }
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

//Inspired by - https://blog.s-schoener.com/2024-06-16-stream-redirection-win32/

unit VSoft.Process;

interface

uses
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  VSoft.CancellationToken;

{$SCOPEDENUMS ON}
// Make the status enums a full 4 bytes so TProcessBase can publish FStatus
// via TInterlocked.Exchange (PInteger trick) and get a memory barrier on
// weaker-ordered platforms (ARM/ARM64). The default {$MINENUMSIZE 1} packs
// these into a byte, which is hardware-atomic but not barrier-ordered, so
// a polling reader on ARM could observe a stale FExitCode against a fresh
// FStatus.
{$MINENUMSIZE 4}

{$REGION 'Forward declarations'}
type
  IProcess = interface;
{$ENDREGION}

{$REGION 'Types'}
  TConstProc<T> = reference to procedure (const Arg: T);
  TConstProc<T1,T2> = reference to procedure (const Arg1: T1; const Arg2 : T2);
  TProcessStatus = (Idle, Running, Exited, Terminated, TimedOut);
  TProcessStartMode = (Sync, Async, Detached);
  // Scheduling priority of the child process (Windows priority class /
  // POSIX nice value).
  TProcessPriority = (Normal, AboveNormal, BelowNormal, Idle);
  // What the Windows job object around the child does (IStartInfoBuilder.JobMode).
  //  KillOnRelease   : the job kills everything still in it when the IProcess
  //                    is released or re-run (programs the child left running
  //                    included). Terminate / timeout / cancellation kill the
  //                    whole job.
  //  KillOnTerminate : Terminate / timeout / cancellation kill the whole job,
  //                    but releasing or re-running the IProcess leaves
  //                    programs the child left behind running.
  //  NoJob           : no job. Terminate / timeout / cancellation kill the
  //                    child's process tree; leftovers survive release.
  // POSIX has no job object: leftovers always survive release and the stop
  // signals go to the child's process group, whatever the mode - except when
  // the child inherits a terminal as stdin, which keeps it in the host's group
  // so only the child itself is signalled.
  TProcessJobMode = (KillOnRelease, KillOnTerminate, NoJob);

  //events
  TProcessStartedEvent = procedure(const process : IProcess) of object;
  TProcessExitedEvent = procedure(const process : IProcess; exitCode : Cardinal) of object;

  //exceptions
  EVSoftProcessError = class(Exception);
  EProcessWaitError = class(EVSoftProcessError);
{$ENDREGION}

{$REGION 'CommandLine'}
  //quoting style for arguments
  TQuoted = (qtNone, //None
            qtSingle, //Single quotes
            qtDouble, //Double quotes
            qtAutoSingle, //Single quotes if there are spaces in the value
            qtAutoDouble //Double quotes if there are spaces in the value
            );

  //Command line argument interface
  {$M+}
  IArgument = interface
  ['{22AABFAF-7CCF-4A1E-8AB6-0FCFDE03E9B4}']
    function GetNameSep : string;
    procedure SetNameSep(const value : string);
    function GetValue : string;
    procedure SetValue(const value : string);
    function GetName : string;
    procedure SetName(const value : string);
    function GetQuoted : TQuoted;
    procedure SetQuoted(const avalue : TQuoted);
    function GetQuoteName : boolean;
    procedure SetQuoteName(const value : boolean);

    function ToString : string;
    function ToLogString : string;

    //Argument name, e.g -d
    property Name : string read GetName write SetName;
    //argument value e.g. "c:\temp
    property Value : string read GetValue write SetValue;
    //determines if the argument value will have quotes around it and what sort of quotes
    property Quoted : TQuoted read GetQuoted write SetQuoted;
    //the separator between the name of a parameter and it's value, default is a space
    property NameValueSeparator : string read GetNameSep write SetNameSep;
    //determines if the parameter name should be quoted or not.
    property QuoteName : boolean read GetQuoteName write SetQuoteName;
  end;
  {$M-}

  //Command line builder interface
  ICommandLineBuilder = interface
  ['{70280187-3A4C-45F4-BD02-00AB63193BE3}']
    function GetDefValueSep : string;
    procedure SetDefValueSep(const value : string);
    function GetDefArgSep : string;
    procedure SetDefArgSep(const value : string);
    function GetCount : integer;
    function GetArgument(const index : integer) : IArgument;
    function GetArgumentByName(const index : string) : IArgument;

    //adds a new argument. Add('', '') adds an explicit empty argument ("" on
    //Windows, an empty argv slot on POSIX).
    function Add(const name : string; //the argument name
                         const value : string; //the argument value, options
                         const Quoted : TQuoted = TQuoted.qtDouble //quoting on the argument, doublequotes by default
                         ) : ICommandLineBuilder;overload;
    function Add(const name : string; //the argument name
                         const Quoted : TQuoted = TQuoted.qtDouble //quoting on the argument, doublequotes by default
                         ) : ICommandLineBuilder;overload;

    //adds a new Sensitive argument (like passwords), the value section will not be displayed in the log.
    //With no value (AddSensitive(name)) the whole argument is masked instead.
    //Note this only affects ToLogString - the value is still visible to anyone
    //who can list the child's command line (ps, Process Explorer, /proc).
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

    function Clone : ICommandLineBuilder;

    function WithDefaultValueSeparator(const value : string) : ICommandLineBuilder;

    function WithDefaultArgumentSeparator(const value : string) : ICommandLineBuilder;

    //gets the command line as a string
    function ToString : string;

    // gets the command line as a string which is safe to log (sensitive args excluded)
    function ToLogString : string;

    //the default NameValueSeparator for new arguments.
    property DefaultValueSeparator : string read GetDefValueSep write SetDefValueSep;
    //The default separator for new arguments
    property DefaultArgumentSeparator : string read GetDefArgSep write SetDefArgSep;
    //returns the number of arguments
    property Count : integer read GetCount;
    //arguments array property
    property Arguments[const index : integer] : IArgument read GetArgument;
    //arguments by name array property
    property ArgumentsByName[const index : string] : IArgument read GetArgumentByName;
  end;

{$ENDREGION}

{$REGION 'Environment'}
  IEnvironmentBuilder = interface
    ['{38F128A2-AA63-4D65-A182-DC4BDB80F554}']
    function GetCount : integer;
    // Reset to currrent process's environment
    function Reset : IEnvironmentBuilder;
    function AddOrSet(const name : string; const value : string) : IEnvironmentBuilder;
    function AddOrSetValues(const list : TStrings) : IEnvironmentBuilder;
    function Remove(const name : string) : IEnvironmentBuilder;
    // Value of a variable in the builder; False when it is not present.
    function TryGetValue(const name : string; out value : string) : boolean;
    // True when the variable is in the builder, including one with an empty
    // value. Names are case insensitive on Windows, case sensitive on POSIX.
    function Exists(const name : string) : boolean;
    // Removes every variable, so the child gets exactly the ones added
    // afterwards (possibly none). Sets HasOverrides; Clone keeps the cleared
    // state and Reset takes a new snapshot of the process environment. Most
    // Windows programs need at least SystemRoot (and often PATH, TEMP, ...)
    // to run.
    function Clear : IEnvironmentBuilder;
    function ToString : string;
    function Clone : IEnvironmentBuilder;
    function ToEnvironmentBlock : Pointer;
    function ToEnvironArray : TArray<PAnsiChar>;

    // True if the caller has mutated the environment (AddOrSet / Remove /
    // AddOrSetValues / Clear / a modified Clone source). When False, the contents
    // are equivalent to the current process's environment and the platform
    // impl can pass nil to CreateProcess / execve to inherit it without
    // building a block. Reset clears this flag (it returns the builder to
    // a "matches current process env" state).
    function HasOverrides : boolean;

    property Count : integer read GetCount;

  end;

{$ENDREGION}

{$REGION 'ProcessStartInfo'}
  IStartInfoBuilder = interface
  ['{B9FDC36E-895B-4BF9-8868-8BA3682427D9}']
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
    function GetProcessorAffinity: Cardinal;
    procedure SetProcessorAffinity(value : Cardinal);
    function GetPriority : TProcessPriority;
    procedure SetPriority(value : TProcessPriority);
    function GetTerminateExitCode: Cardinal;
    procedure SetTerminateExitCode(value : Cardinal);
    function GetTimedOutExitCode: Cardinal;
    procedure SetTimedOutExitCode(value : Cardinal);
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

    function GetInputEncoding: TEncoding;
    procedure SetInputEncoding(const value: TEncoding);
    function GetOutputEncoding: TEncoding;
    procedure SetOutputEncoding(const value: TEncoding);

    function Clone : IStartInfoBuilder;

    //fluent config
    function WithInputEncoding(const value: TEncoding) : IStartInfoBuilder;
    function WithOutputEncoding(const value: TEncoding) : IStartInfoBuilder;
    function WithTimeout(timeoutMs : Cardinal) : IStartInfoBuilder;
    function WithExecutable(const value : string) : IStartInfoBuilder;
    function WithArgvZero(const value : string) : IStartInfoBuilder;
    function WithHideWindow(value : boolean) : IStartInfoBuilder;
    function WithWorkingDirectory(const value : string) : IStartInfoBuilder;
    function WithProcessorAffinity(value : Cardinal) : IStartInfoBuilder;
    function WithPriority(value : TProcessPriority) : IStartInfoBuilder;
    function WithTerminateExitCode(value : Cardinal) : IStartInfoBuilder;
    function WithTimedOutExitCode(value : Cardinal) : IStartInfoBuilder;
    function WithPipeBufferSize(value : Cardinal) : IStartInfoBuilder;
    function WithMarshallEventsToMainThread(value : boolean) : IStartInfoBuilder;
    function WithPipeDrainTimeout(value : Cardinal) : IStartInfoBuilder;
    function WithJobMode(value : TProcessJobMode) : IStartInfoBuilder;
    function WithTerminateOnTimeout(value : boolean) : IStartInfoBuilder;

    //non fluent config
    // On Windows a .bat / .cmd executable is run by cmd.exe, which re-parses
    // the command line. Arguments containing cmd metacharacters are therefore
    // force-quoted, and arguments containing % ! " CR or LF are rejected at
    // validation because cmd.exe cannot be given them safely.
    // A bare name (no folder part) is searched for on this process's PATH
    // (POSIX uses /usr/bin:/bin when it has none, like execvp). The PATH given
    // to the child in Environment is never searched, so the child can have a
    // constrained PATH, or none. Only absolute PATH entries are searched,
    // never the current directory or this program's folder. On Windows ".exe"
    // is appended to a name without an extension (PATHEXT is not used), and a
    // .bat / .cmd found this way follows the batch-file rules above. A path
    // with a folder part is relative to the current directory, not
    // WorkingDirectory. A program that cannot be found is a validation error.
    // IProcess.ResolvedExecutable is the path launched.
    property Executable : string read GetExecutable write SetExecutable;
    // Optional argv[0] override. Empty (default) means argv[0] = Executable.
    // Set this when the child needs to see a different process name in
    // argv[0] than the actual binary path (busybox-style multicall, login
    // shells using `-bash`, etc.). POSIX only - ignored on Windows where
    // there is no separate argv[0].
    property ArgvZero : string read GetArgvZero write SetArgvZero;
    property HideWindow : boolean read GetHideWindow write SetHideWindow;
    // 0 = wait forever (default). Users who want indefinite waits typically
    // pair Execute/ExecuteAsync with a cancellation token / event so they
    // can still abort.
    property TimeoutInMSec : Cardinal read GetTimeoutMS write SetTimeoutMS;
    property WorkingDirectory : string read GetWorkingDir write SetWorkingDir;

    property Priority : TProcessPriority read GetPriority write SetPriority;
    property TerminateExitCode : Cardinal read GetTerminateExitCode write SetTerminateExitCode;
    property TimedOutExitCode : Cardinal read GetTimedOutExitCode write SetTimedOutExitCode;
    property InputEncoding : TEncoding read GetInputEncoding write SetInputEncoding;
    property OutputEncoding : TEncoding read GetOutputEncoding write SetOutputEncoding;
    property ProcessorAffinity : Cardinal read GetProcessorAffinity write SetProcessorAffinity;
    // Pipe buffer size for stdout/stderr/stdin redirection. 0 (default)
    // means 64KB - the historical hard-coded value. Larger values reduce
    // wakeup frequency for chatty processes; smaller values reduce memory
    // for many concurrent children.
    property PipeBufferSize : Cardinal read GetPipeBufferSize write SetPipeBufferSize;
    // When True, OnStarted / OnExit fire on the main thread via TThread.Queue
    // (UI-safe). Default False - events fire on the worker thread (no
    // marshalling overhead, but UI access must Synchronize/Queue itself).
    // Console apps must pump CheckSynchronize for queued events to run.
    property MarshallEventsToMainThread : boolean read GetMarshallEventsToMainThread write SetMarshallEventsToMainThread;
    // How long to keep reading stdout/stderr after the child has exited, for
    // output still held by a descendant that inherited the pipe (a background
    // grandchild, a build server, etc). When it elapses the reads are
    // cancelled, an error is logged and the run completes. Default 2000.
    // After a normal exit the clock only starts once everything the child
    // left in the pipes has been delivered, however long the targets take.
    // INFINITE waits for every writer to close the pipe on a normal exit; after
    // Terminate / timeout / cancellation the drain is always bounded (INFINITE
    // is treated as the default there) and starts straight away. Terminate or
    // cancellation during the drain after a normal exit ends it at once (on
    // Windows the job, if any, is terminated as well).
    property PipeDrainTimeoutMS : Cardinal read GetPipeDrainTimeoutMS write SetPipeDrainTimeoutMS;
    // See TProcessJobMode. Default KillOnRelease.
    property JobMode : TProcessJobMode read GetJobMode write SetJobMode;
    // What happens when TimeoutInMSec elapses. True (default): the child and
    // its children are killed. False: the child is left running - the run
    // completes with Status = TimedOut, TimedOut = True and ExitCode =
    // TimedOutExitCode, output read up to that point is delivered, the
    // library stops reading and closes its pipe ends (a child that writes
    // afterwards may see a broken pipe), and the child survives the IProcess
    // being released or re-run. False requires JobMode KillOnTerminate or
    // NoJob (validation error otherwise, on every platform). On POSIX the
    // child's process group is not signalled and a background thread reaps
    // the child when it exits.
    property TerminateOnTimeout : boolean read GetTerminateOnTimeout write SetTerminateOnTimeout;
  end;
{$ENDREGION}


{$REGION 'Credentials'}
  ICredentialsBuilder = interface
  ['{34A8C65D-9E49-4C79-9EC8-C533589B4B63}']
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
    function Clone : ICredentialsBuilder;
    function Validate(const errorProc : TConstProc<string>): boolean;

    //fluent
    function WithUser(const value : string) : ICredentialsBuilder;
    function WithDomain(const value : string) : ICredentialsBuilder;
    function WithPassword(const value : string) : ICredentialsBuilder;
    function WithUserProfile(value : boolean) : ICredentialsBuilder;
    function WithNetCredentialsOnly(value : boolean) : ICredentialsBuilder;

    //non fluent
    property Domain : string read GetDomain write SetDomain;
    property UserName : string read GetUserName write SetUserName;
    property Password : string read GetPassword write SetPassword;
    property LoadUserProfile : boolean read GetLoadUserProfile write SetLoadUserProfile;
    property NetCredentialsOnly : boolean read GetNetCredentialsOnly write SetNetCredentialsOnly;
  end;
{$ENDREGION}

{$REGION 'TIPipeTarget'}
  TPipeTargetMethod = procedure(const data : TBytes; length : NativeUInt) of object;
  TPipeTargetLineMethod = procedure(const line : string ) of object;
  TPipeTargetProcedure = procedure(const data : TBytes; length : NativeUInt);
  TPipeTargetLineProcedure = procedure(const line : string );
  TPipeTargetDelegate = reference to procedure(const data : TBytes; length : NativeUInt);
  TPipeTargetLineDelegate = reference to procedure(const line : string );

  // Receives a child's stdout or stderr.
  //  * Start is called once per run before the child is created; Done once per
  //    run after the last HandleData (also when the launch fails). Neither is
  //    called when validation fails or for ExecuteDetached.
  //  * HandleData is called on a threadpool thread on Windows, and on the
  //    thread running the run on POSIX (the caller of a synchronous Execute,
  //    the worker thread of ExecuteAsync). Calls for all of a process's
  //    targets are serialised (never concurrent).
  //  * data is a reused read buffer: only the first dataLength bytes are
  //    valid and the contents must be copied if they are kept after the call.
  //  * An exception raised by HandleData is logged to IProcess.Errors and the
  //    target receives no further data for that run; the child keeps running.
  IPipeTarget = interface
  ['{0F08A7BE-047C-47F1-BB18-9D09DD89A253}']
    procedure Start;
    procedure HandleData(const data : TBytes; dataLength : NativeUInt);
    procedure Done;
  end;

  // Implemented by pipe targets that keep separate state for stdout and
  // stderr (line targets, StringBuilder target, ToAll), so one instance
  // attached to both streams never joins a partial line, or a split
  // multi-byte character, of one stream to the other. The process calls
  // HandleStreamData instead of IPipeTarget.HandleData when the target
  // supports it; HandleData counts as stdout. The same rules apply as for
  // HandleData.
  IStreamAwarePipeTarget = interface
  ['{B608D9F4-7656-49DF-BACE-CDF5CBC98E88}']
    procedure HandleStreamData(isStdErr : boolean; const data : TBytes; dataLength : NativeUInt);
  end;

  // Implemented by pipe targets that decode bytes into a string (line targets,
  // StringBuilder target). Lets the process inject StartInfo.OutputEncoding as
  // the default when the user did not pass an explicit encoding to the
  // TPipeTarget factory method.
  IEncodingAwarePipeTarget = interface
  ['{A1B1C2D3-4E5F-4A60-9F12-2E0B6C8F4D11}']
    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
  end;

  TPipeTarget = record
  public
    class function ToFile(const fileName : string; append : boolean = false) : IPipeTarget;static;
    class function ToStream(const stream : TStream) : IPipeTarget;static;
    class function ToStringBuilder(const stringBuilder : TStringBuilder; const encoding : TEncoding = nil) : IPipeTarget;static;
    class function ToLineDelegate(const proc : TPipeTargetLineDelegate; const encoding : TEncoding = nil) : IPipeTarget;overload;static;
    class function ToDelegate(const proc : TPipeTargetDelegate) : IPipeTarget;overload;static;
    class function ToMethod(const proc : TPipeTargetMethod) : IPipeTarget;overload;static;
    class function ToLineMethod(const proc : TPipeTargetLineMethod; const encoding : TEncoding = nil) : IPipeTarget;overload;static;
    class function ToProcedure(const proc : TPipeTargetProcedure) : IPipeTarget;overload;static;
    class function ToLineProcedure(const proc : TPipeTargetLineProcedure; const encoding : TEncoding = nil) : IPipeTarget;overload;static;

    // An open array, so ToAll([a, b]) works on every compiler version; a
    // TArray<IPipeTarget> can still be passed. The targets are copied.
    class function ToAll(const targets : array of IPipeTarget) : IPipeTarget;static;
  end;

  IPipeSource = interface
  ['{986A0B47-714D-4957-8252-803F3ED248CD}']
    procedure Start;
    //not sure what the best interface should be here
    //returns true if more data available
    //Called on the stdin writer thread; should return promptly. Once the
    //child has exited, a call that hasn't returned within a second is left
    //to finish on its own and the run completes without it.
    function GetData(var data : TBytes; out length : NativeUInt) : boolean;

    procedure Done;

  end;

  // Implemented by pipe sources that encode a string into bytes (TStringPipeSource).
  // Lets the process inject StartInfo.InputEncoding as the default when the
  // user did not pass an explicit encoding to TPipeSource.FromString.
  IEncodingAwarePipeSource = interface
  ['{B2C3D4E5-6F70-4A81-90F2-3F0C7D9F5E22}']
    function HasExplicitEncoding : boolean;
    procedure SetDefaultEncoding(const value : TEncoding);
  end;

  // Interactive pipe source allows writing data to stdin during process execution
  IInteractivePipeSource = interface(IPipeSource)
  ['{8E5C8B7F-6A4D-4E2F-9B1A-5C3D7E2F4A8B}']
    // Write bytes to stdin (can be called multiple times during execution)
    function Write(const data : TBytes) : Boolean;overload;

    // Write string to stdin with optional encoding (defaults to UTF-8)
    function Write(const text : string; const encoding : TEncoding = nil) : Boolean; overload;

    // Close stdin to signal EOF to child process
    procedure Close;

    // Check if stdin has been closed
    function IsClosed : Boolean;

    // Block until either data becomes available, the source is closed, or
    // the timeout elapses. The stdin writer thread uses this to avoid
    // busy-spinning through GetData when the producer has not yet written
    // anything. Returns True if data is (likely) available or the source is
    // closed; False if the wait timed out with no new state.
    function WaitForData(timeoutMS : Cardinal) : Boolean;
  end;

  TPipeSource = record
  public
    class function FromString(const value : string; const encoding : TEncoding = nil) : IPipeSource;static;
    class function FromBytes(const bytes : TBytes) : IPipeSource;static;
    class function FromStream(const stream : TStream) : IPipeSource;static;
    class function FromFile(const fileName : string) : IPipeSource;static;
    // Create an interactive pipe source for runtime writing during process execution
    class function Interactive : IInteractivePipeSource;static;
  end;

{$ENDREGION}

{$REGION 'Process'}
  IProcess = interface
  ['{60365419-B3F5-4903-B815-47B7A1F11D02}']
    function GetStartInfo : IStartInfoBuilder;
    function GetCredentials : ICredentialsBuilder;
    function GetCommandLine : ICommandLineBuilder;
    function GetEnvironment : IEnvironmentBuilder;

    function GetOnStarted   : TProcessStartedEvent;
    procedure SetOnStarted(const value : TProcessStartedEvent);
    function GetOnExited   : TProcessExitedEvent;
    procedure SetOnExited(const value : TProcessExitedEvent);

    function GetLastError : Cardinal;
    function GetStartMode : TProcessStartMode;
    function GetExitCode : Cardinal;
    function GetStatus : TProcessStatus;
    function GetTimedOut : boolean;
    function GetProcessId : Cardinal;
    function GetErrors : TStrings;
    function GetResolvedExecutable : string;
    //fluent configuration
    function WithStartInfo(const proc : TConstProc<IStartInfoBuilder>) : IProcess;
    function WithCommandLine(const proc : TConstProc<ICommandLineBuilder>) : IProcess;
    function WithEnvironment(const proc : TConstProc<IEnvironmentBuilder>) : IProcess;
    function WithCredentials(const proc : TConstProc<ICredentialsBuilder>) : IProcess;

    /// <summary>
    ///
    /// </summary>
    function WithStdOutPipe(const pipeTarget : IPipeTarget) : IProcess;

    /// <summary>
    ///
    /// </summary>
    function WithStdErrPipe(const pipeTarget : IPipeTarget) : IProcess;

    /// <summary>
    ///
    /// </summary>
    function WithStdInPipe(const pipeSource : IPipeSource) : IProcess;

    /// <summary>
    ///  Executes the process and returns when the process exits;
    ///  returns true if the process started
    ///  </summary>
    function Execute(const cancellationToken : ICancellationToken = nil) : boolean;overload;

    /// <summary>
    ///  Executes the process and returns when the process exits;
    ///  returns true if the process started.                                    `
    ///  </summary>
    function Execute(const cancellationEvent : TEvent) : boolean;overload;


    /// <summary>
    ///  Executes the process and returns true if process started;
    ///  Use the status method or events to determine when process completed.
    ///  </summary>
    function ExecuteAsync(const cancellationToken : ICancellationToken = nil) : boolean;overload;


    /// <summary>
    ///  Executes the process and returns true if process started;
    ///  Use the status method or events to determine when process completed.
    ///  </summary>
    function ExecuteAsync(const cancellationEvent : TEvent) : boolean;overload;

    /// <summary>
    ///  Executes the process and returns when the process has started.
    ///  The child process is started detached, so we no longer have any
    ///  control over it and do not redirect stdio.
    ///  Returns true if process started.
    ///
    ///  Caveats for detached processes:
    ///  - Status remains Running (the OS never notifies us when the
    ///    detached process exits). The IProcess can still be re-used for
    ///    another Execute / ExecuteAsync / ExecuteDetached.
    ///  - ExitCode raises EInvalidOpException (we cannot read it).
    ///  - Terminate returns False (cannot terminate a detached process).
    ///  - ProcessId is populated on Windows (the immediate child) but is
    ///    0 on POSIX (the grandchild PID is lost across the double-fork).
    /// </summary>
    function ExecuteDetached : boolean;

    /// <summary>
    ///  Terminates the process tree. When called from another thread it
    ///  blocks until the run has fully completed (or 5 seconds elapse) and
    ///  returns True if it did complete. When called from OnStarted, a pipe
    ///  target / source callback, or the thread running a synchronous
    ///  Execute, it only requests termination and returns True immediately.
    ///  Returns False when no run is in progress (including from OnExit,
    ///  which fires after the run has completed) or the run is detached.
    ///  </summary>
    function Terminate : boolean;

    /// <summary>
    ///  Create a Copy of this process with the same config
    ///  </summary>
    function Clone : IProcess;

    //non fluent
    property CommandLine : ICommandLineBuilder read GetCommandLine;
    property Credentials : ICredentialsBuilder read GetCredentials;
    property Environment :  IEnvironmentBuilder read GetEnvironment;
    property StartInfo : IStartInfoBuilder read GetStartInfo;


    //status stuff
    property ProcessId : Cardinal read GetProcessId;
    // The full path of the program that is (or was last) launched: a bare
    // Executable name found on the PATH, a relative path made absolute.
    // Valid once a run has started (empty before, or when validation failed).
    property ResolvedExecutable : string read GetResolvedExecutable;
    // Only meaningful once Status has left Running ($FFFFFFFF until then).
    property ExitCode : Cardinal read GetExitCode;
    // Leaves Running only after the run has fully completed: all output has
    // been delivered, every pipe target's Done has been called and handles
    // are closed. Polling Status is therefore safe for reading results, and a
    // new Execute* may be started as soon as it changes.
    property Status : TProcessStatus read GetStatus;
    property TimedOut : boolean read GetTimedOut;
    property StartMode :  TProcessStartMode read GetStartMode;
    // Why the OS refused to start the child: the CreateProcess /
    // CreateProcessWithLogonW error code on Windows, the errno from fork /
    // chdir / dup2 / execve on POSIX (the numbering differs per platform).
    // 0 in every other case, including when Execute* returns False because
    // validation failed (a missing executable among them) or cancellation
    // was already requested. Reset by every Execute*; the same failure is
    // also logged to Errors as text.
    property LastError : Cardinal read GetLastError;
    // Diagnostics for the last run. Appended to from worker threads while a
    // run is in progress, so only read it once Status has left Running.
    property Errors : TStrings read GetErrors;

    {$IFDEF MSWINDOWS}
    function GetCompletionHandle : THandle;
    // Signalled while no run is in progress. Reset when Execute / ExecuteAsync starts a run;
    // set once the run has fully completed - output delivered, every target's Done called,
    // handles closed, i.e. the moment Status leaves Running (before OnExit fires). Stays
    // signalled for ExecuteDetached and when validation fails. Wait on it alongside your own
    // handles (WaitForMultipleObjects / MsgWaitForMultipleObjects); never close or signal it.
    // Windows only - a POSIX TEvent has no handle.
    property CompletionHandle : THandle read GetCompletionHandle;
    {$ENDIF}

    //events
    property OnStarted : TProcessStartedEvent read GetOnStarted write SetOnStarted;
    property OnExit : TProcessExitedEvent read GetOnExited write SetOnExited;

  end;

  TProcess = class
    class function Create : IProcess;static;
  end;
{$ENDREGION}

{$REGION 'Constants' }

const
  EXIT_OK = 0;
  //these are defaults, can be configured per process
  EXIT_TERMINATED = 9999;
  EXIT_TIMEDOUT = 8888;
  // Default for IStartInfoBuilder.PipeDrainTimeoutMS.
  DEFAULT_PIPE_DRAIN_TIMEOUT_MS = 2000;

{$ENDREGION}


implementation

uses
{$IFDEF MSWINDOWS}
  VSoft.Process.Windows,
{$ELSEIF DEFINED(LINUX) OR DEFINED(MACOS)}
  VSoft.Process.Posix,
{$IFEND}
  VSoft.Process.PipeSource.Classes,
  VSoft.Process.PipeTarget.Classes;

{ TProcessFactory }

class function TProcess.Create: IProcess;
begin
{$IFDEF MSWINDOWS}
  result := TWindowsProcess.Create;
{$ELSEIF DEFINED(LINUX) OR DEFINED(MACOS)}
  result := TPosixProcess.Create;
{$ELSE}
  {$MESSAGE ERROR 'Unsupported platform - Windows, Linux, or macOS required'}
{$IFEND}
end;

{ PipeTarget }

class function TPipeTarget.ToLineDelegate(const proc: TPipeTargetLineDelegate; const encoding : TEncoding = nil): IPipeTarget;
begin
  result := TLineDelegatePipeTarget.Create(proc, encoding);
end;

class function TPipeTarget.ToAll(const targets: array of IPipeTarget): IPipeTarget;
begin
  result := TMultiPipeTarget.Create(targets);
end;

class function TPipeTarget.ToDelegate(const proc: TPipeTargetDelegate): IPipeTarget;
begin
  result := TDelegatePipeTarget.Create(proc);
end;

class function TPipeTarget.ToFile(const fileName: string; append : boolean = false): IPipeTarget;
begin
  result := TFilePipeTarget.Create(fileName, append);
end;

class function TPipeTarget.ToMethod(const proc: TPipeTargetMethod): IPipeTarget;
begin
  result := TMethodPipeTarget.Create(proc);
end;

class function TPipeTarget.ToProcedure(const proc: TPipeTargetProcedure): IPipeTarget;
begin
  result := TProcedurePipeTarget.Create(proc);
end;

class function TPipeTarget.ToLineMethod(const proc: TPipeTargetLineMethod; const encoding : TEncoding): IPipeTarget;
begin
  result := TLineMethodPipeTarget.Create(proc,encoding);
end;

class function TPipeTarget.ToLineProcedure(const proc: TPipeTargetLineProcedure; const encoding: TEncoding): IPipeTarget;
begin
  result := TLineProcedurePipeTarget.Create(proc, encoding);
end;

class function TPipeTarget.ToStream(const stream: TStream): IPipeTarget;
begin
  result := TStreamPipeTarget.Create(stream);
end;

class function TPipeTarget.ToStringBuilder(const stringBuilder: TStringBuilder; const encoding: TEncoding): IPipeTarget;
begin
 result := TStringBuilderPipeTarget.Create(stringBuilder, encoding);
end;

class function TPipeSource.FromBytes(const bytes : TBytes): IPipeSource;
begin
  result := TBytesPipeSource.Create(bytes);
end;

{ IPipeSource }

class function TPipeSource.FromFile(const fileName : string): IPipeSource;
begin
  result := TFilePipeSource.Create(fileName);
end;

class function TPipeSource.FromStream(const stream : TStream): IPipeSource;
begin
  result := TStreamPipeSource.Create(stream);
end;

class function TPipeSource.FromString(const value : string; const encoding : TEncoding): IPipeSource;
begin
  result := TStringPipeSource.Create(value, encoding);
end;

class function TPipeSource.Interactive: IInteractivePipeSource;
begin
  result := TInteractivePipeSource.Create;
end;

end.
