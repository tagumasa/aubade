#+build windows

// Windows Job object primitives: the process-tree containment shared by
// both consumers — lsproc's language-server containment (a memory
// ceiling plus kill-on-close orphan protection, the Pdeathsig/cgroup
// analog) and procrun's group discipline (kill-on-close so a spawned
// tree dies with its call; TerminateJobObject as the tree stop).
// core:sys/windows ships none of this API, so the seam declares the
// kernel32 entries it uses (core's own ioringapi file carries the same
// shape for its kernel32 subset).
package platform

import "core:os"
import "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	CreateJobObjectW :: proc(
		lpJobAttributes: windows.LPSECURITY_ATTRIBUTES,
		lpName:          windows.LPCWSTR,
	) -> windows.HANDLE ---
	AssignProcessToJobObject :: proc(
		hJob:     windows.HANDLE,
		hProcess: windows.HANDLE,
	) -> windows.BOOL ---
	SetInformationJobObject :: proc(
		hJob:                         windows.HANDLE,
		JobObjectInformationClass:    Job_Info_Class,
		lpJobObjectInformation:       rawptr,
		cbJobObjectInformationLength: windows.DWORD,
	) -> windows.BOOL ---
	TerminateJobObject :: proc(
		hJob:      windows.HANDLE,
		uExitCode: windows.DWORD,
	) -> windows.BOOL ---
}

// Job_Info_Class carries the one JOBOBJECTINFOCLASS value this seam
// sets (JobObjectExtendedLimitInformation in the Windows headers).
Job_Info_Class :: enum u32 {
	Extended_Limit = 9,
}

JOB_OBJECT_LIMIT_JOB_MEMORY        :: windows.DWORD(0x0200)
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: windows.DWORD(0x2000)

// IO_COUNTERS and the JOBOBJECT_* limit structs mirror the winnt.h
// layout the SetInformationJobObject call reads.
IO_COUNTERS :: struct {
	ReadOperationCount:  windows.DWORDLONG,
	WriteOperationCount: windows.DWORDLONG,
	OtherOperationCount: windows.DWORDLONG,
	ReadTransferCount:   windows.DWORDLONG,
	WriteTransferCount:  windows.DWORDLONG,
	OtherTransferCount:  windows.DWORDLONG,
}

JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: windows.LARGE_INTEGER,
	PerJobUserTimeLimit:     windows.LARGE_INTEGER,
	LimitFlags:              windows.DWORD,
	MinimumWorkingSetSize:   windows.SIZE_T,
	MaximumWorkingSetSize:   windows.SIZE_T,
	ActiveProcessLimit:      windows.DWORD,
	Affinity:                windows.ULONG_PTR,
	PriorityClass:           windows.DWORD,
	SchedulingClass:         windows.DWORD,
}

JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    windows.DWORDLONG,
	JobMemoryLimit:        windows.DWORDLONG,
	PeakProcessMemoryUsed: windows.DWORDLONG,
	PeakJobMemoryUsed:     windows.DWORDLONG,
}

// job_create makes an anonymous kill-on-close job: every member dies
// when the last job handle closes, so a member can never outlive the
// process holding that handle. limit_mb > 0 adds a job-wide memory
// ceiling (the tree's allocations fail once it passes the cap — the
// cgroup memory.max analog with fail-the-allocation enforcement instead
// of the OOM kill); limit_mb <= 0 leaves memory unbounded. nil means the
// job could not be made and the caller runs uncontained.
job_create :: proc(limit_mb: int) -> windows.HANDLE {
	job := CreateJobObjectW(nil, nil)
	if job == nil {
		return nil
	}
	info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if limit_mb > 0 {
		info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY
		info.JobMemoryLimit = windows.DWORDLONG(limit_mb) * 1024 * 1024
	}
	if !SetInformationJobObject(job, .Extended_Limit, &info, size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) {
		_ = windows.CloseHandle(job)
		return nil
	}
	return job
}

// job_assign moves a freshly spawned process into the job; every child
// it spawns from then on is born inside the job too.
job_assign :: proc(job: windows.HANDLE, child: os.Process) -> bool {
	return AssignProcessToJobObject(job, windows.HANDLE(child.handle)) != windows.FALSE
}

// job_terminate lands on every member of the job at once — the process
// tree stop. The exit code surfaces as each member's process exit code.
job_terminate :: proc(job: windows.HANDLE, exit_code: u32) -> bool {
	return TerminateJobObject(job, windows.DWORD(exit_code)) != windows.FALSE
}

// job_close drops the caller's handle; with kill-on-close set the close
// is also the sweep that reaps stragglers nobody waited on.
job_close :: proc(job: windows.HANDLE) {
	if job != nil {
		_ = windows.CloseHandle(job)
	}
}
