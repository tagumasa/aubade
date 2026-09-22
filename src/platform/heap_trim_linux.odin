#+build linux

// Post-churn heap release. glibc's arenas keep freed chunks resident —
// parked in bins and arena tops — instead of returning the pages to the
// OS, so a workload that allocates and frees gigabytes in a burst leaves
// most of that churn parked in RSS long after every allocation is freed
// (measured on the whole-project scans: each call parses every
// grammar-served file, ~25x the source bytes per tree, and three calls
// settled ~700 MB above the pre-scan baseline with only ~90 MB genuinely
// live). malloc_trim(0) walks every arena and releases what is fully free
// (trims tops, madvises interior free pages), handing that retention back.
// It costs single-digit milliseconds against work measured in seconds, so
// the mass-free boundaries — the end of a whole-project scan or crawl —
// call it unconditionally rather than thresholding on churn size.
package platform

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	malloc_trim :: proc(pad: uint) -> i32 --- // size_t pad
}

heap_trim :: proc() {
	malloc_trim(0)
}
