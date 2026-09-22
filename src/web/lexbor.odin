// The lexbor FFI seam: the HTML5 parser behind the markdown conversion.
// Only the handful of exported symbols the converter walks are bound; the
// node and character-data structs mirror their C layouts field for field
// (the text payload is read through the struct because lexbor ships no
// exported accessor for it).
package web


when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lexbor {
		"../../lib/windows_amd64/liblexbor.lib",
	}
} else when ODIN_OS == .Windows && ODIN_ARCH == .arm64 {
	foreign import lexbor {
		"../../lib/windows_arm64/liblexbor.lib",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lexbor {
		"../../lib/darwin_amd64/liblexbor.a",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lexbor {
		"../../lib/darwin_arm64/liblexbor.a",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lexbor {
		"../../lib/linux_amd64/liblexbor.a",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lexbor {
		"../../lib/linux_arm64/liblexbor.a",
	}
} else {
	// The vendored C libraries exist for windows, darwin, and linux on
	// amd64 and arm64 only (lib/<os>_<arch>, tools/build's naming); any
	// other combination fails here instead of at the link line.
	#assert(false)
}

LXB_Status :: distinct u32

LXB_STATUS_OK :: LXB_Status(0)

LXB_Document :: distinct rawptr
LXB_Attr :: distinct rawptr

// Node type values (the DOM spec's set — the C enum is a plain
// unsigned integer in the struct, so the mirror uses u32).
LXB_NODE_ELEMENT :: u32(1)
LXB_NODE_TEXT :: u32(3)

// LXB_Dom_Node mirrors struct lxb_dom_node: the event-target base (one
// pointer), the tag ids, the tree links, and the type. The C struct's
// size on the platforms we target is 96 bytes; the character-data
// extension hangs its lexbor_str_t right after.
LXB_Dom_Node :: struct {
	events:         rawptr,
	local_name:     uintptr,
	prefix:         uintptr,
	ns:             uintptr,
	owner_document: rawptr,
	next:           ^LXB_Dom_Node,
	prev:           ^LXB_Dom_Node,
	parent:         ^LXB_Dom_Node,
	first_child:    ^LXB_Dom_Node,
	last_child:     ^LXB_Dom_Node,
	user:           rawptr,
	type_:          u32,
	_pad:           u32,
}

LXB_Str :: struct {
	data:   [^]u8,
	length: uint,
	size:   uint,
}

LXB_Dom_Character_Data :: struct {
	node: LXB_Dom_Node,
	data: LXB_Str,
}

@(default_calling_convention = "c")
foreign lexbor {
	lxb_html_parser_create :: proc() -> rawptr ---
	lxb_html_parser_init :: proc(parser: rawptr) -> u32 ---
	lxb_html_parser_destroy :: proc(parser: rawptr) -> rawptr ---
	lxb_html_parse :: proc(parser: rawptr, html: ^u8, size: uint) -> rawptr ---
	lxb_html_document_destroy :: proc(document: rawptr) -> u32 ---
	lxb_html_document_body_element_noi :: proc(document: rawptr) -> rawptr ---
	lxb_dom_node_first_child_noi :: proc(node: ^LXB_Dom_Node) -> ^LXB_Dom_Node ---
	lxb_dom_node_prev_noi :: proc(node: ^LXB_Dom_Node) -> ^LXB_Dom_Node ---
	lxb_dom_node_next_noi :: proc(node: ^LXB_Dom_Node) -> ^LXB_Dom_Node ---
	lxb_dom_element_tag_name :: proc(element: rawptr, len: ^uint) -> ^u8 ---
	lxb_dom_element_first_attribute_noi :: proc(element: rawptr) -> rawptr ---
	lxb_dom_element_next_attribute_noi :: proc(attr: rawptr) -> rawptr ---
	lxb_dom_attr_qualified_name :: proc(attr: rawptr, len: ^uint) -> ^u8 ---
	lxb_dom_attr_value_noi :: proc(attr: rawptr, len: ^uint) -> ^u8 ---
}

// lxb_parse_one parses a full document and returns the body element's
// node. The parser is created and destroyed per call: parsing is not
// concurrent within one conversion and lexbor parsers are not cheap to
// keep alive. The writable input copy rides the temp allocator; the
// document outlives the walk — destroy it with lxb_document_destroy.
lxb_parse_one :: proc(html: string) -> (doc: LXB_Document, body_node: ^LXB_Dom_Node, ok: bool) {
	// An empty body has no document: guard before the writable-copy step
	// indexes &buf[0] on a zero-length slice (a bounds panic).
	if len(html) == 0 {
		return nil, nil, false
	}
	parser := lxb_html_parser_create()
	if parser == nil {
		return nil, nil, false
	}
	if lxb_html_parser_init(parser) != u32(LXB_STATUS_OK) {
		_ = lxb_html_parser_destroy(parser)
		return nil, nil, false
	}
	defer _ = lxb_html_parser_destroy(parser)

	// The input is copied into a writable buffer: string memory may sit in
	// read-only pages, and the parse must never write there.
	buf := make([]u8, len(html), context.temp_allocator)
	for i := 0; i < len(html); i += 1 {
		buf[i] = html[i]
	}
	parsed := lxb_html_parse(parser, &buf[0], uint(len(html)))
	if parsed == nil {
		return nil, nil, false
	}
	body := lxb_html_document_body_element_noi(parsed)
	if body == nil {
		_ = lxb_html_document_destroy(parsed)
		return nil, nil, false
	}
	doc = LXB_Document(parsed)
	body_node = cast(^LXB_Dom_Node)body
	ok = true
	return
}

lxb_document_destroy :: proc(doc: LXB_Document) {
	_ = lxb_html_document_destroy(doc)
}

// lxb_node_tag returns the lowercased tag name of an element node.
lxb_node_tag :: proc(node: ^LXB_Dom_Node, a := context.allocator) -> string {
	name_len := uint(0)
	raw := lxb_dom_element_tag_name(cast(rawptr)node, &name_len)
	if raw == nil || name_len == 0 {
		return ""
	}
	view := transmute(string)(cast([^]u8)raw)[:int(name_len)]
	lower := make([]u8, int(name_len), a)
	for i := 0; i < len(view); i += 1 {
		c := view[i]
		if c >= 'A' && c <= 'Z' {
			c = c + ('a' - 'A')
		}
		lower[i] = c
	}
	return transmute(string)lower
}

// lxb_node_text returns the text payload of a text node (a borrowed view
// into the document — clone before the document dies).
lxb_node_text :: proc(node: ^LXB_Dom_Node) -> string {
	cd := cast(^LXB_Dom_Character_Data)node
	if cd.data.data == nil {
		return ""
	}
	return transmute(string)(cd.data.data[:])[:int(cd.data.length)]
}

// lxb_attr_pair reads one attribute's qualified name and value as
// borrowed views.
lxb_attr_pair :: proc(attr: LXB_Attr) -> (name: string, value: string) {
	name_len := uint(0)
	value_len := uint(0)
	raw_name := lxb_dom_attr_qualified_name(rawptr(attr), &name_len)
	raw_value := lxb_dom_attr_value_noi(rawptr(attr), &value_len)
	if raw_name != nil && name_len > 0 {
		name = transmute(string)(cast([^]u8)raw_name)[:int(name_len)]
	}
	if raw_value != nil && value_len > 0 {
		value = transmute(string)(cast([^]u8)raw_value)[:int(value_len)]
	}
	return name, value
}

// lxb_first_attribute walks to the node's first attribute.
lxb_first_attribute :: proc(node: ^LXB_Dom_Node) -> LXB_Attr {
	return LXB_Attr(lxb_dom_element_first_attribute_noi(cast(rawptr)node))
}

lxb_next_attribute :: proc(attr: LXB_Attr) -> LXB_Attr {
	return LXB_Attr(lxb_dom_element_next_attribute_noi(attr))
}

lxb_prev :: proc(node: ^LXB_Dom_Node) -> ^LXB_Dom_Node {
	return lxb_dom_node_prev_noi(node)
}
