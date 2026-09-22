package tracker

import "core:mem"
import "core:strings"

// blocked_by graph over incident display IDs. An edge from A to B records
// "A is blocked by B". No internal lock: the tracker mutates it only under
// the manager's write mutex, and the fold itself is single-threaded.
// Adapted from the original DAG (itself adapted from vorpalstacks, MIT):
// WouldCreateCycle lets the write path reject cyclic edges up front, all
// results are sorted lexicographically for deterministic output, and
// RemoveNode drops deleted incidents. Nodes without edges exist explicitly
// so key ownership is uniform.

DAG_Node :: struct {
	edges: [dynamic]string, // owned clones: the IDs this node is blocked by
	rev:   [dynamic]string, // owned clones: the IDs blocked by this node
}

DAG :: struct {
	nodes:     map[string]^DAG_Node, // owned keys and values
	allocator: mem.Allocator,
}

dag_init :: proc(d: ^DAG, a: mem.Allocator) {
	d^ = {allocator = a}
	// The map is made here on the DAG's own allocator: a zero-value map
	// would grow through whatever context.allocator the first insert ran
	// under (the init-owns-collections rule).
	d.nodes = make(map[string]^DAG_Node, 16, a)
}

dag_destroy :: proc(d: ^DAG) {
	// Collect-then-free: mutating the map inside its own iteration is
	// outside Odin's iteration contract. The node values are freed in
	// the loop (the map only holds the pointers), the key bytes after.
	names := make([dynamic]string, 0, len(d.nodes), context.temp_allocator)
	for name, node in d.nodes {
		free_dag_node(node, d.allocator)
		append(&names, name)
	}
	for name in names {
		delete(name, d.allocator)
	}
	delete(names)
	delete(d.nodes)
}

@(private)
free_dag_node :: proc(node: ^DAG_Node, a: mem.Allocator) {
	for s in node.edges {
		delete(s, a)
	}
	delete(node.edges)
	for s in node.rev {
		delete(s, a)
	}
	delete(node.rev)
	free(node, a)
}

// dag_add_node adds a node if absent.
dag_add_node :: proc(d: ^DAG, name: string) {
	if _, ok := d.nodes[name]; ok {
		return
	}
	node := new(DAG_Node, d.allocator)
	// Both collections are made on the DAG's own allocator (the
	// init-owns-collections rule): a nil dynamic's first append in
	// dag_add_edge would grow through the calling thread's
	// context.allocator instead, leaving the long-lived fold state
	// backed by request-thread memory.
	node.edges = make([dynamic]string, 0, 2, d.allocator)
	node.rev = make([dynamic]string, 0, 2, d.allocator)
	d.nodes[strings.clone(name, d.allocator)] = node
}

// dag_add_edge records from→blocked-by-to, creating nodes on demand.
// Self-references are rejected; duplicate edges are ignored.
dag_add_edge :: proc(d: ^DAG, from: string, to: string) -> bool {
	if from == to {
		return false
	}
	dag_add_node(d, from)
	dag_add_node(d, to)
	fnode := d.nodes[from]
	tnode := d.nodes[to]
	for existing in fnode.edges {
		if existing == to {
			return true
		}
	}
	append(&fnode.edges, strings.clone(to, d.allocator))
	append(&tnode.rev, strings.clone(from, d.allocator))
	return true
}

// dag_remove_node drops a node and all incident edges (deleted incidents
// leave the graph while their header keeps the raw blocked_by list).
dag_remove_node :: proc(d: ^DAG, name: string) {
	node, ok := d.nodes[name]
	if !ok {
		return
	}
	for to in node.edges {
		if tn, present := d.nodes[to]; present {
			dag_list_remove(d, &tn.rev, name)
		}
	}
	for from in node.rev {
		if fn_, present := d.nodes[from]; present {
			dag_list_remove(d, &fn_.edges, name)
		}
	}
	free_dag_node(node, d.allocator)
	// The map owns the stored key clone; `name` may alias the caller's
	// string (a header's ID) and must not be freed here. delete_key
	// hands back the stored key, which is the one this map owns.
	stored_key, _ := delete_key(&d.nodes, name)
	delete(stored_key, d.allocator)
}

// dag_would_create_cycle reports whether adding from→to would close a
// cycle: true when `from` is already reachable from `to` by dependency
// edges (or from == to).
dag_would_create_cycle :: proc(d: ^DAG, from: string, to: string) -> bool {
	if from == to {
		return true
	}
	visited := make(map[string]bool, 8, context.temp_allocator)
	defer delete(visited)
	return dag_reaches(d, to, from, &visited)
}

@(private)
dag_reaches :: proc(d: ^DAG, node_id: string, target: string, visited: ^map[string]bool) -> bool {
	if node_id == target {
		return true
	}
	if visited[node_id] {
		return false
	}
	visited[node_id] = true
	node, ok := d.nodes[node_id]
	if !ok {
		return false
	}
	for next in node.edges {
		if dag_reaches(d, next, target, visited) {
			return true
		}
	}
	return false
}

// dag_dependents returns all nodes directly or transitively blocked by the
// given node, sorted lexicographically (excluding the node itself). The
// slice is owned by the caller's allocator (delete-able); its elements
// borrow the DAG's node ids and stay valid while the DAG lives.
dag_dependents :: proc(d: ^DAG, name: string, a: mem.Allocator) -> []string {
	visited := make(map[string]bool, 8, context.temp_allocator)
	defer delete(visited)
	result := make([dynamic]string, 0, 4, a)
	dag_collect_dependents(d, name, &visited, &result)
	for i in 1..<len(result) {
		j := i
		for j > 0 && result[j-1] > result[j] {
			result[j-1], result[j] = result[j], result[j-1]
			j -= 1
		}
	}
	out := make([]string, len(result), a)
	for v, i in result {
		out[i] = v
	}
	delete(result)
	return out
}

@(private)
dag_collect_dependents :: proc(d: ^DAG, node_id: string, visited: ^map[string]bool, result: ^[dynamic]string) {
	node, ok := d.nodes[node_id]
	if !ok {
		return
	}
	for dep in node.rev {
		if !visited[dep] {
			visited[dep] = true
			append(result, dep)
			dag_collect_dependents(d, dep, visited, result)
		}
	}
}

@(private)
dag_list_remove :: proc(d: ^DAG, list: ^[dynamic]string, v: string) {
	out := make([dynamic]string, 0, len(list^), d.allocator)
	for s in list^ {
		if s == v {
			delete(s, d.allocator)
		} else {
			append(&out, s)
		}
	}
	delete(list^)
	list^ = out
}
