unit VSoft.Process.Tests.StartInfo;

interface

uses
  DUnitX.TestFramework,
  VSoft.Process,
  VSoft.Process.StartInfo;

type
  [TestFixture]
  TStartInfoTests = class
  public
    [Test]
    procedure Defaults_Sensible;

    [Test]
    procedure FluentSetters_ReturnSelfAndUpdateProperties;

    [Test]
    procedure Clone_CopiesAllFields;

    // New properties added in the bug-review pass: PipeBufferSize (M3),
    // MarshallEventsToMainThread (H2), ArgvZero (L3).
    [Test]
    procedure Defaults_NewProperties_Sensible;

    [Test]
    procedure FluentSetters_NewProperties_ReturnSelfAndUpdate;

    [Test]
    procedure Clone_CopiesNewProperties;

    [Test]
    procedure PriorityAndDrainTimeout_DefaultsFluentAndClone;

    [Test]
    procedure JobModeAndTerminateOnTimeout_DefaultsFluentAndClone;

    // SetProcessAffinityMask takes a DWORD_PTR, so on Win64 a mask can name
    // CPUs 32-63. The property must not truncate it.
    [Test]
    procedure ProcessorAffinity_HoldsHighCpuBits;
  end;

implementation

function MakeBuilder : IStartInfoBuilder;
begin
  result := TStartInfoBuilder.Create;
end;

procedure TStartInfoTests.Defaults_Sensible;
var
  info : IStartInfoBuilder;
begin
  info := MakeBuilder;
  Assert.IsTrue(info.HideWindow, 'Default HideWindow should be True');
  Assert.AreEqual<Cardinal>(0, info.TimeoutInMSec, 'Default timeout should be 0');
  Assert.AreEqual('', info.Executable, 'Default executable should be empty');
end;

procedure TStartInfoTests.FluentSetters_ReturnSelfAndUpdateProperties;
var
  info, ret : IStartInfoBuilder;
begin
  info := MakeBuilder;
  ret := info.WithExecutable('cmd.exe')
              .WithWorkingDirectory('C:\Windows')
              .WithTimeout(5000)
              .WithHideWindow(False);
  Assert.AreSame(info, ret, 'Fluent setters must return the same builder');
  Assert.AreEqual('cmd.exe',  info.Executable);
  Assert.AreEqual('C:\Windows', info.WorkingDirectory);
  Assert.AreEqual<Cardinal>(5000, info.TimeoutInMSec);
  Assert.IsFalse(info.HideWindow);
end;

procedure TStartInfoTests.Clone_CopiesAllFields;
var
  src, dst : IStartInfoBuilder;
begin
  src := MakeBuilder;
  src.WithExecutable('foo.exe')
     .WithWorkingDirectory('C:\Work')
     .WithTimeout(1234)
     .WithHideWindow(False)
     .WithTimedOutExitCode(42)
     .WithTerminateExitCode(7);

  dst := src.Clone;
  Assert.AreEqual(src.Executable,         dst.Executable);
  Assert.AreEqual(src.WorkingDirectory,   dst.WorkingDirectory);
  Assert.AreEqual<Cardinal>(src.TimeoutInMSec, dst.TimeoutInMSec);
  Assert.AreEqual(src.HideWindow,         dst.HideWindow);
  Assert.AreEqual<Cardinal>(src.TimedOutExitCode,  dst.TimedOutExitCode);
  Assert.AreEqual<Cardinal>(src.TerminateExitCode, dst.TerminateExitCode);

  // Mutating the clone must not affect the source.
  dst.WithExecutable('other.exe');
  Assert.AreEqual('foo.exe', src.Executable, 'Clone mutation leaked into source');
end;

procedure TStartInfoTests.Defaults_NewProperties_Sensible;
var
  info : IStartInfoBuilder;
begin
  info := MakeBuilder;
  Assert.AreEqual<Cardinal>(0, info.PipeBufferSize,
    'Default PipeBufferSize must be 0 (=> platform default 64KB)');
  Assert.IsFalse(info.MarshallEventsToMainThread,
    'Default MarshallEventsToMainThread must be False to preserve worker-thread semantics');
  Assert.AreEqual('', info.ArgvZero,
    'Default ArgvZero must be empty (=> argv[0] = Executable)');
end;

procedure TStartInfoTests.FluentSetters_NewProperties_ReturnSelfAndUpdate;
var
  info, ret : IStartInfoBuilder;
begin
  info := MakeBuilder;
  ret := info.WithPipeBufferSize(8192)
              .WithMarshallEventsToMainThread(True)
              .WithArgvZero('-bash');
  Assert.AreSame(info, ret, 'Fluent setters must return the same builder');
  Assert.AreEqual<Cardinal>(8192, info.PipeBufferSize);
  Assert.IsTrue(info.MarshallEventsToMainThread);
  Assert.AreEqual('-bash', info.ArgvZero);
end;

procedure TStartInfoTests.Clone_CopiesNewProperties;
var
  src, dst : IStartInfoBuilder;
begin
  src := MakeBuilder;
  src.WithPipeBufferSize(16384)
     .WithMarshallEventsToMainThread(True)
     .WithArgvZero('multicall-name');

  dst := src.Clone;
  Assert.AreEqual<Cardinal>(src.PipeBufferSize, dst.PipeBufferSize);
  Assert.AreEqual(src.MarshallEventsToMainThread, dst.MarshallEventsToMainThread);
  Assert.AreEqual(src.ArgvZero, dst.ArgvZero);

  // Independence check.
  dst.WithArgvZero('other');
  Assert.AreEqual('multicall-name', src.ArgvZero,
    'Clone mutation must not leak back into the source');
end;

procedure TStartInfoTests.PriorityAndDrainTimeout_DefaultsFluentAndClone;
var
  src, dst, ret : IStartInfoBuilder;
begin
  src := MakeBuilder;
  Assert.AreEqual(TProcessPriority.Normal, src.Priority);
  Assert.AreEqual<Cardinal>(DEFAULT_PIPE_DRAIN_TIMEOUT_MS, src.PipeDrainTimeoutMS);
  ret := src.WithPriority(TProcessPriority.BelowNormal).WithPipeDrainTimeout(750);
  Assert.AreSame(src, ret);
  Assert.AreEqual(TProcessPriority.BelowNormal, src.Priority);
  Assert.AreEqual<Cardinal>(750, src.PipeDrainTimeoutMS);
  dst := src.Clone;
  Assert.AreEqual(TProcessPriority.BelowNormal, dst.Priority);
  Assert.AreEqual<Cardinal>(750, dst.PipeDrainTimeoutMS);
end;

procedure TStartInfoTests.JobModeAndTerminateOnTimeout_DefaultsFluentAndClone;
var
  src, dst, ret : IStartInfoBuilder;
begin
  src := MakeBuilder;
  Assert.AreEqual(TProcessJobMode.KillOnRelease, src.JobMode);
  Assert.IsTrue(src.TerminateOnTimeout);
  ret := src.WithJobMode(TProcessJobMode.KillOnTerminate).WithTerminateOnTimeout(false);
  Assert.AreSame(src, ret);
  Assert.AreEqual(TProcessJobMode.KillOnTerminate, src.JobMode);
  Assert.IsFalse(src.TerminateOnTimeout);
  dst := src.Clone;
  Assert.AreEqual(TProcessJobMode.KillOnTerminate, dst.JobMode);
  Assert.IsFalse(dst.TerminateOnTimeout);
  src.JobMode := TProcessJobMode.NoJob;
  Assert.AreEqual(TProcessJobMode.NoJob, src.JobMode);
  Assert.AreEqual(TProcessJobMode.KillOnTerminate, dst.JobMode, 'the clone is independent');
end;

procedure TStartInfoTests.ProcessorAffinity_HoldsHighCpuBits;
var
  info : IStartInfoBuilder;
  mask : NativeUInt;
  shift : integer;
begin
  shift := (SizeOf(NativeUInt) * 8) - 24; // CPU 40 on Win64, CPU 8 on Win32
  mask := NativeUInt(1) shl shift;
  info := MakeBuilder;
  info.ProcessorAffinity := mask;
  Assert.AreEqual<NativeUInt>(mask, info.ProcessorAffinity, 'property');
  info := MakeBuilder;
  Assert.AreEqual<NativeUInt>(mask, info.WithProcessorAffinity(mask).ProcessorAffinity, 'fluent setter');
  Assert.AreEqual<NativeUInt>(mask, info.Clone.ProcessorAffinity, 'Clone');
end;

initialization
  TDUnitX.RegisterTestFixture(TStartInfoTests);

end.
