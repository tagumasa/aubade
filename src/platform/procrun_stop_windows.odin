#+build windows

// procrun's stop seam (Windows): the direct path stops its child, and a
// group run stops the whole Job instead — TerminateJobObject lands on
// every member at once (cmd.exe and the commands it spawned), where the
// plain process kill would only take the shell and leave the workload
// tree running.
package platform

import "core:os"
import "core:sys/windows"

// procrun_arm_stop_job wraps a freshly spawned child in a kill-on-close
// Job with no memory ceiling (procrun caps streams and time, not
// memory). 0 when the job could not be made — the run then degrades to
// the plain direct-child stop.
procrun_arm_stop_job :: proc(child: os.Process) -> uintptr {
	job := job_create(0)
	if job == nil {
		return 0
	}
	if !job_assign(job, child) {
		job_close(job)
		return 0
	}
	return cast(uintptr)job
}

// procrun_kill_child stops the run: the whole Job when one is armed
// (falling back to the plain kill if the terminate call itself failed —
// the child may already be exiting), else the direct child.
procrun_kill_child :: proc(child: os.Process, stop_job: uintptr) -> os.Error {
	if stop_job != 0 {
		if job_terminate(cast(windows.HANDLE)stop_job, 1) {
			return nil
		}
	}
	return os.process_kill(child)
}

// procrun_release_stop_job drops the Job handle once the run is done;
// with kill-on-close set this is also the sweep that takes down any
// straggler the wait never saw — a backgrounded job must not outlive
// the call that spawned it.
procrun_release_stop_job :: proc(stop_job: uintptr) {
	if stop_job != 0 {
		job_close(cast(windows.HANDLE)stop_job)
	}
}
