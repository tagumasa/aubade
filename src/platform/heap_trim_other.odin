#+build !linux

// Post-churn heap release (non-glibc half — see heap_trim_linux.odin for
// the rationale). The retention this fights is a glibc arena behavior;
// the Windows and macOS allocators lack the knob, and neither exhibits
// the ratchet, so releasing after a mass free is a no-op here.
package platform

heap_trim :: proc() {}
