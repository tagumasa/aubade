tree-sitter-perl @ ad74e6db234c35d537de9358799a8e0cc4f5dee0
(https://github.com/tree-sitter-perl/tree-sitter-perl), MIT (the clone's
LICENSE ships with the built grammar under lib/).

Generated artifact, not a pristine tree: upstream never commits
src/parser.c (the project builds via `tree-sitter generate`), so this
file is generated once per pin and committed here. Upstream also ships
only alloc.h of the tree_sitter runtime headers (parser.h/array.h are
generate-time copies), so the headers parser.c and scanner.c include
ride along under tree_sitter/. The builder compiles the vendored
parser.c together with the clone's scanner.c and headers whenever the
pinned revision carries no parser.c of its own (`tools/build`
install-parsers falls back to third_party/<repo-name>/).

Regeneration for a new pin:

    git clone https://github.com/tree-sitter-perl/tree-sitter-perl
    git -C tree-sitter-perl checkout --detach <commit>
    tree-sitter generate            # tree-sitter-cli 0.26.13, ABI 15
    cp tree-sitter-perl/src/parser.c third_party/tree-sitter-perl/parser.c
    cp tree-sitter-perl/src/tree_sitter/{parser.h,array.h} \
       third_party/tree-sitter-perl/tree_sitter/
    # alloc.h ships upstream; the vendored copy only exists so the
    # vendored array.h resolves "./alloc.h" relative to itself
    cp tree-sitter-perl/src/tree_sitter/alloc.h \
       third_party/tree-sitter-perl/tree_sitter/

The 0.26.x runtime vendored for the binary speaks ABI 15, matching.
