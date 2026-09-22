// The svc.web/* method names and their wire contracts.
package svc

METHOD_WEB_FETCH :: "svc.web/fetch" // {url, max_chars?} -> {text}
METHOD_WEB_SEARCH :: "svc.web/search" // {query, count?, range?} -> {text}
