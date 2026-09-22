// The closed failure vocabulary of the web boundary. fetch, search, and
// the HTTP transport return it alongside a human-readable message; the
// svc boundary maps the kinds structurally (web_err_platform_kind) so a
// timeout surfaces as a retryable platform error and a guard denial as
// .Denied, instead of every failure arriving as .Internal.
package web

import "src:platform"

Web_Err :: enum {
	None,
	Not_Configured, // the fetcher/searcher is absent or failed to build
	Invalid_Url,    // malformed URL, scheme, or query input
	Denied,         // SSRF guard or safety refusal
	Dns,            // name resolution failed
	Connect,        // TCP/TLS connection failed
	Timeout,        // transfer timeout
	Cancelled,      // the cancel token fired mid-transfer
	Too_Large,      // response exceeded the byte cap
	Busy,           // the fetch admission cap is full — retry shortly
	Provider_Error, // search provider failed upstream
	Internal,       // conversion/protocol failure
}

// web_err_platform_kind maps the vocabulary onto the cross-boundary
// platform kinds: the transient shapes (dns/connect/timeout/provider)
// are retryable so the read-only tool retry path can re-apply them;
// denials and malformed input are terminal; a cancellation keeps its own
// kind.
web_err_platform_kind :: proc(e: Web_Err) -> platform.Err_Kind {
	switch e {
	case .Not_Configured:
		return .Terminated
	case .Invalid_Url, .Too_Large:
		return .Invalid
	case .Denied:
		return .Denied
	case .Dns, .Connect, .Timeout, .Busy, .Provider_Error:
		return .Retryable
	case .Cancelled:
		return .Cancelled
	case .Internal, .None:
		return .Internal
	}
	return .Internal
}
