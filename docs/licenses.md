<!-- GENERATED FILE — regenerate with `odin run tools/build --
     emit-licenses` after a full install-parsers run; do not edit
     by hand. Rows are alphabetical. -->

# Grammar licences and acknowledgments

Aubade is MIT-licensed (see the repository `LICENSE`). The binary
also embeds, statically compiled, the vendored C libraries documented
in [third_party/README.md](../third_party/README.md) — tree-sitter
core, SQLite, PCRE2 with its SLJIT JIT, and lexbor; libcurl is a
system library resolved at link time — and the tree-sitter grammar
parsers listed below, each built from the pinned upstream revision
recorded here.

With thanks to the tree-sitter project, to the authors and
maintainers of every grammar below, and to the library teams above.

`aubade about` prints the per-licence-kind summary at runtime; the
machine-readable manifest behind this document is the generated
table `src/ts/licenses_table.odin`.

## Summary

- 166 x MIT
- 14 x Apache-2.0
- 3 x ISC
- 1 x Apache-2.0 WITH LLVM-exception
- 1 x CC0-1.0
- 1 x MPL-2.0
- 1 x Unlicense

187 grammars in total.

## Per-grammar manifest

| Language | Upstream | Pin | Licence |
|---|---|---|---|
| ada | github.com/briot/tree-sitter-ada | `6b58259a08b1a22ba0247a7ce30be384db618da6` | MIT |
| agda | github.com/tree-sitter/tree-sitter-agda | `e8d47a6987effe34d5595baf321d82d3519a8527` | MIT |
| angular | github.com/dlvandenberg/tree-sitter-angular | `f0d0685701b70883fa2dfe94ee7dc27965cab841` | MIT |
| apex | github.com/aheber/tree-sitter-sfapex | `3597575a429766dd7ecce9f5bb97f6fec4419d5d` | MIT |
| arduino | github.com/ObserverOfTime/tree-sitter-arduino | `53eb391da4c6c5857f8defa2c583c46c2594f565` | MIT |
| asm | github.com/RubixDev/tree-sitter-asm | `839741fef4dab5128952334624905c82b40c7133` | MIT |
| astro | github.com/virchau13/tree-sitter-astro | `213f6e6973d9b456c6e50e86f19f66877e7ef0ee` | MIT |
| awk | github.com/Beaglefoot/tree-sitter-awk | `34bbdc7cce8e803096f47b625979e34c1be38127` | MIT |
| bash | github.com/tree-sitter/tree-sitter-bash | `a06c2e4415e9bc0346c6b86d401879ffb44058f7` | MIT |
| bass | github.com/vito/tree-sitter-bass | `28dc7059722be090d04cd751aed915b2fee2f89a` | MIT |
| beancount | github.com/polarmutex/tree-sitter-beancount | `d7a03a7506fbbbc4b16a9a2054ff7c2b337744b8` | MIT |
| bibtex | github.com/latex-lsp/tree-sitter-bibtex | `8d04ed27b3bc7929f14b7df9236797dab9f3fa66` | MIT |
| bicep | github.com/amaanq/tree-sitter-bicep | `bff59884307c0ab009bd5e81afd9324b46a6c0f9` | MIT |
| bitbake | github.com/amaanq/tree-sitter-bitbake | `a5d04fdb5a69a02b8fa8eb5525a60dfb5309b73b` | MIT |
| blade | github.com/EmranMR/tree-sitter-blade | `42b3c5a06bc29fbd2c2cbd52b96113365fbed646` | MIT |
| c | github.com/tree-sitter/tree-sitter-c | `v0.24.2` | MIT |
| c_sharp | github.com/tree-sitter/tree-sitter-c-sharp | `v0.23.5` | MIT |
| cairo | github.com/amaanq/tree-sitter-cairo | `6238f609bea233040fe927858156dee5515a0745` | MIT |
| capnp | github.com/amaanq/tree-sitter-capnp | `7b0883c03e5edd34ef7bcf703194204299d7099f` | MIT |
| chatito | github.com/ObserverOfTime/tree-sitter-chatito | `c0ed82c665b732395073f635c74c300f09530a7f` | MIT |
| circom | github.com/Decurity/tree-sitter-circom | `02150524228b1e6afef96949f2d6b7cc0aaf999e` | MIT |
| cmake | github.com/uyha/tree-sitter-cmake | `c7b2a71e7f8ecb167fad4c97227c838439280175` | MIT |
| cobol | github.com/yutaro-sakamoto/tree-sitter-cobol | `e99dbdc3d800d5fa2796476efd60af91f6b43d93` | MIT |
| comment | github.com/stsewd/tree-sitter-comment | `66272d2b6c73fb61157541b69dd0a7ce7b42a5ad` | MIT |
| commonlisp | github.com/theHamsta/tree-sitter-commonlisp | `32323509b3d9fe96607d151c2da2c9009eb13a2f` | MIT |
| cpon | github.com/amaanq/tree-sitter-cpon | `594289eadfec719198e560f9d7fd243c4db678d5` | MIT |
| cpp | github.com/tree-sitter/tree-sitter-cpp | `v0.23.4` | MIT |
| crystal | github.com/keidax/tree-sitter-crystal | `51ad1411de9414b4600227553bb70953c352a627` | MIT |
| css | github.com/tree-sitter/tree-sitter-css | `dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f` | MIT |
| csv | github.com/amaanq/tree-sitter-csv | `f6bf6e35eb0b95fbadea4bb39cb9709507fcb181` | MIT |
| cuda | github.com/theHamsta/tree-sitter-cuda | `48b066f334f4cf2174e05a50218ce2ed98b6fd01` | MIT |
| cue | github.com/eonpatapon/tree-sitter-cue | `be0f609c73cc2929811a9bce0ed90ca71ea87604` | MIT |
| cylc | github.com/elliotfontaine/tree-sitter-cylc | `6d1d81137112299324b526477ce1db989ab58fb8` | MIT |
| d | github.com/gdamore/tree-sitter-d | `fb028c8f14f4188286c2eef143f105def6fbf24f` | MIT |
| dart | github.com/UserNobody14/tree-sitter-dart | `0fc19c3a57b1109802af41d2b8f60d8835c5da3a` | MIT |
| desktop | github.com/ValdezFOmar/tree-sitter-desktop | `58e2ae16828d20889a36e657d728d901b4de47ec` | MIT |
| devicetree | github.com/joelspadin/tree-sitter-devicetree | `e685f1f6ac1702b046415efb476444167d63e41a` | MIT |
| dhall | github.com/jbellerb/tree-sitter-dhall | `62013259b26ac210d5de1abf64cf1b047ef88000` | MIT |
| diff | github.com/the-mikedavis/tree-sitter-diff | `2520c3f934b3179bb540d23e0ef45f75304b5fed` | MIT |
| djot | github.com/treeman/tree-sitter-djot | `74fac1f53c6d52aeac104b6874e5506be6d0cfe6` | MIT |
| dockerfile | github.com/camdencheek/tree-sitter-dockerfile | `971acdd908568b4531b0ba28a445bf0bb720aba5` | MIT |
| dot | github.com/rydesun/tree-sitter-dot | `80327abbba6f47530edeb0df9f11bd5d5c93c14d` | MIT |
| doxygen | github.com/amaanq/tree-sitter-doxygen | `ccd998f378c3f9345ea4eeb223f56d7b84d16687` | MIT |
| dtd | github.com/tree-sitter-grammars/tree-sitter-xml | `5000ae8f22d11fbe93939b05c1e37cf21117162d` | MIT |
| earthfile | github.com/glehmann/tree-sitter-earthfile | `5baef88717ad0156fd29a8b12d0d8245bb1096a8` | MIT |
| editorconfig | github.com/ValdezFOmar/tree-sitter-editorconfig | `63f104dab268a25237f773323c172a4a380a00e1` | MIT |
| elisp | github.com/Wilfred/tree-sitter-elisp | `29b4e49275f4a947ce17c8533bc20a1f97768c70` | MIT |
| elixir | github.com/elixir-lang/tree-sitter-elixir | `7937d3b4d65fa574163cfa59394515d3c1cf16f4` | Apache-2.0 |
| elm | github.com/elm-tooling/tree-sitter-elm | `6d9511c28181db66daee4e883f811f6251220943` | MIT |
| embedded_template | github.com/tree-sitter/tree-sitter-embedded-template | `3499d85f0a0d937c507a4a65368f2f63772786e1` | MIT |
| enforce | github.com/simonvic/tree-sitter-enforce | `eb2796871d966264cdb041b797416ef1757c8b4f` | MIT |
| erlang | github.com/WhatsApp/tree-sitter-erlang | `1d78195c4fbb1fc027eb3e4220427f1eb8bfc89e` | Apache-2.0 |
| faust | github.com/khiner/tree-sitter-faust | `122dd101919289ea809bad643712fcb483a1bed0` | MIT |
| fennel | github.com/alexmozaidze/tree-sitter-fennel | `3f0f6b24d599e92460b969aabc4f4c5a914d15a0` | CC0-1.0 |
| fidl | github.com/google/tree-sitter-fidl | `0a8910f293268e27ff554357c229ba172b0eaed2` | Apache-2.0 |
| firrtl | github.com/amaanq/tree-sitter-firrtl | `8503d3a0fe0f9e427863cb0055699ff2d29ae5f5` | Apache-2.0 |
| fish | github.com/ram02z/tree-sitter-fish | `fa2143f5d66a9eb6c007ba9173525ea7aaafe788` | Unlicense |
| foam | github.com/FoamScience/tree-sitter-foam | `472c24f11a547820327fb1be565bcfff98ea96a4` | MIT |
| forth | github.com/AlexanderBrevig/tree-sitter-forth | `360ef13f8c609ec6d2e80782af69958b84e36cd0` | MIT |
| fortran | github.com/stadelmanma/tree-sitter-fortran | `2880b7aab4fb7cc618de1ef3d4c6d93b2396c031` | MIT |
| fsharp | github.com/ionide/tree-sitter-fsharp | `5141851c278a99958469eb1736c7afc4ec738e47` | MIT |
| gdscript | github.com/PrestonKnopp/tree-sitter-gdscript | `89e66b6bdc002ab976283f277cbb48b780c5d0e9` | MIT |
| git_config | github.com/the-mikedavis/tree-sitter-git-config | `0fbc9f99d5a28865f9de8427fb0672d66f9d83a5` | MIT |
| git_rebase | github.com/the-mikedavis/tree-sitter-git-rebase | `bff4b66b44b020d918d67e2828eada1974a966aa` | MIT |
| gitattributes | github.com/tree-sitter-grammars/tree-sitter-gitattributes | `1b7af09d45b579f9f288453b95ad555f1f431645` | MIT |
| gitignore | github.com/shunsambongi/tree-sitter-gitignore | `f4685bf11ac466dd278449bcfe5fd014e94aa504` | MIT |
| gleam | github.com/gleam-lang/tree-sitter-gleam | `6ea757f7eb8d391dbf24dbb9461990757946dd5e` | Apache-2.0 |
| glsl | github.com/tree-sitter-grammars/tree-sitter-glsl | `24a6c8ef698e4480fecf8340d771fbcb5de8fbb4` | MIT |
| gn | github.com/tree-sitter-grammars/tree-sitter-gn | `bc06955bc1e3c9ff8e9b2b2a55b38b94da923c05` | MIT |
| go | github.com/tree-sitter/tree-sitter-go | `v0.25.0` | MIT |
| godot_resource | github.com/PrestonKnopp/tree-sitter-godot-resource | `302c1895f54bf74d53a08572f7b26a6614209adc` | MIT |
| gomod | github.com/camdencheek/tree-sitter-go-mod | `2e886870578eeba1927a2dc4bd2e2b3f598c5f9a` | MIT |
| graphql | github.com/bkegley/tree-sitter-graphql | `5e66e961eee421786bdda8495ed1db045e06b5fe` | MIT |
| groovy | github.com/murtaza64/tree-sitter-groovy | `a88865a3301a538e2060af5b401f4f431f71406e` | MIT |
| hack | github.com/slackhq/tree-sitter-hack | `1a7ded90288189746c54861ac144ede97df95081` | MIT |
| hare | github.com/tree-sitter-grammars/tree-sitter-hare | `eed7ddf6a66b596906aa8ca3d40521b8278adc6f` | MIT |
| haskell | github.com/tree-sitter/tree-sitter-haskell | `0975ef72fc3c47b530309ca93937d7d143523628` | MIT |
| haxe | github.com/vantreeseba/tree-sitter-haxe | `f2a2394d9ca7a6099f78d8b0d178530e7c9a8e26` | MIT |
| hcl | github.com/tree-sitter-grammars/tree-sitter-hcl | `64ad62785d442eb4d45df3a1764962dafd5bc98b` | Apache-2.0 |
| heex | github.com/phoenixframework/tree-sitter-heex | `b5a7cb5f74dc695a9ff5f04919f872ebc7a895e9` | MIT |
| hlsl | github.com/tree-sitter-grammars/tree-sitter-hlsl | `bab9111922d53d43668fabb61869bec51bbcb915` | MIT |
| html | github.com/tree-sitter/tree-sitter-html | `73a3947324f6efddf9e17c0ea58d454843590cc0` | MIT |
| http | github.com/rest-nvim/tree-sitter-http | `db8b4398de90b6d0b6c780aba96aaa2cd8e9202c` | MIT |
| hurl | github.com/pfeiferj/tree-sitter-hurl | `597efbd7ce9a814bb058f48eabd055b1d1e12145` | Apache-2.0 |
| hyprlang | github.com/tree-sitter-grammars/tree-sitter-hyprlang | `22723f25f3faf329863d952c9601b492afd971c9` | MIT |
| ini | github.com/justinmk/tree-sitter-ini | `e4018b5176132b4f3c5d6e61cea383f42288d0f5` | Apache-2.0 |
| java | github.com/tree-sitter/tree-sitter-java | `v0.23.5` | MIT |
| javascript | github.com/tree-sitter/tree-sitter-javascript | `v0.25.0` | MIT |
| jinja2 | github.com/dbt-labs/tree-sitter-jinja2 | `a82ed374f4cb58a1358dd6b26a7157bde1bca3b7` | Apache-2.0 |
| jsdoc | github.com/tree-sitter/tree-sitter-jsdoc | `658d18dcdddb75c760363faa4963427a7c6b52db` | MIT |
| json | github.com/tree-sitter/tree-sitter-json | `001c28d7a29832b06b0e831ec77845553c89b56d` | MIT |
| json5 | github.com/Joakker/tree-sitter-json5 | `aa630ef48903ab99e406a8acd2e2933077cc34e1` | MIT |
| jsonnet | github.com/sourcegraph/tree-sitter-jsonnet | `ddd075f1939aed8147b7aa67f042eda3fce22790` | MIT |
| julia | github.com/tree-sitter/tree-sitter-julia | `e0f9dcd180fdcfcfa8d79a3531e11d99e79321d3` | MIT |
| just | github.com/IndianBoy42/tree-sitter-just | `60df3d5b3fda2a22fdb3621226cafab50b763663` | Apache-2.0 |
| kconfig | github.com/amaanq/tree-sitter-kconfig | `9ac99fe4c0c27a35dc6f757cef534c646e944881` | MIT |
| kdl | github.com/tree-sitter-grammars/tree-sitter-kdl | `b37e3d58e5c5cf8d739b315d6114e02d42e66664` | MIT |
| kotlin | github.com/fwcd/tree-sitter-kotlin | `cbed96ab13dbc082eeeb2e8333c342a62829c29d` | MIT |
| ledger | github.com/cbarrete/tree-sitter-ledger | `96c92d4908a836bf8f661166721c98439f8afb80` | MIT |
| less | github.com/rhino1998/tree-sitter-less | `2bd739e106a3485bca210cf7b6d25ba09fd10dff` | MIT |
| linkerscript | github.com/amaanq/tree-sitter-linkerscript | `f99011a3554213b654985a4b0a65b3b032ec4621` | MIT |
| liquid | github.com/hankthetank27/tree-sitter-liquid | `fa11c7ba45038b61e03a8a00ad667fb5f3d72088` | MIT |
| llvm | github.com/benwilliamgraham/tree-sitter-llvm | `2914786ae6774d4c4e25a230f4afe16aa68fe1c1` | MIT |
| lua | github.com/tree-sitter-grammars/tree-sitter-lua | `10fe0054734eec83049514ea2e718b2a56acd0c9` | MIT |
| luau | github.com/tree-sitter-grammars/tree-sitter-luau | `a8914d6c1fc5131f8e1c13f769fa704c9f5eb02f` | MIT |
| make | github.com/tree-sitter-grammars/tree-sitter-make | `70613f3d812cbabbd7f38d104d60a409c4008b43` | MIT |
| markdown | github.com/tree-sitter-grammars/tree-sitter-markdown | `v0.5.3` | MIT |
| markdown_inline | github.com/tree-sitter-grammars/tree-sitter-markdown | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5` | MIT |
| matlab | github.com/acristoffers/tree-sitter-matlab | `574dde565caddf8cf44eec7df3cb89eb96053ed7` | MIT |
| mermaid | github.com/monaqa/tree-sitter-mermaid | `90ae195b31933ceb9d079abfa8a3ad0a36fee4cc` | MIT |
| meson | github.com/tree-sitter-grammars/tree-sitter-meson | `c84f3540624b81fc44067030afce2ff78d6ede05` | MIT |
| mojo | github.com/whistlebee/tree-sitter-mojo | `c307dab71a43add26b4715f14e2d6de2a42e6007` | MIT |
| move | github.com/aptos-labs/tree-sitter-move-on-aptos | `12906b341de7cef81cf03d7d91dae51d8a9299e7` | Apache-2.0 |
| nginx | github.com/opa-oz/tree-sitter-nginx | `47ade644d754cce57974aac44d2c9450e823d4f4` | MIT |
| nickel | github.com/nickel-lang/tree-sitter-nickel | `b5b6cc3bc7b9ea19f78fed264190685419cd17a8` | MIT |
| nim | github.com/alaviss/tree-sitter-nim | `9b4ede21a6ca866d29263f6b66c070961bc622b4` | MPL-2.0 |
| ninja | github.com/alemuller/tree-sitter-ninja | `0a95cfdc0745b6ae82f60d3a339b37f19b7b9267` | MIT |
| nix | github.com/nix-community/tree-sitter-nix | `eabf96807ea4ab6d6c7f09b671a88cd483542840` | MIT |
| norg | github.com/nvim-neorg/tree-sitter-norg | `d89d95af13d409f30a6c7676387bde311ec4a2c8` | MIT |
| nushell | github.com/nushell/tree-sitter-nu | `bb3f533e5792260291945e1f329e1f0a779def6e` | MIT |
| objc | github.com/tree-sitter-grammars/tree-sitter-objc | `181a81b8f23a2d593e7ab4259981f50122909fda` | MIT |
| ocaml | github.com/tree-sitter/tree-sitter-ocaml | `5a979b3ec7f1fe990b8e8c4412294a0cf7228e45` | MIT |
| odin | github.com/tree-sitter-grammars/tree-sitter-odin | `v1.3.0` | MIT |
| org | github.com/emiasims/tree-sitter-org | `64cfbc213f5a83da17632c95382a5a0a2f3357c1` | MIT |
| pascal | github.com/Isopod/tree-sitter-pascal | `042119eca2e18a60e56317fb06ee3ba5c32cb447` | MIT |
| pem | github.com/ObserverOfTime/tree-sitter-pem | `e525b177a229b1154fd81bc0691f943028d9e685` | MIT |
| perl | github.com/tree-sitter-perl/tree-sitter-perl | `ad74e6db234c35d537de9358799a8e0cc4f5dee0` | MIT |
| php | github.com/tree-sitter/tree-sitter-php | `3f2465c217d0a966d41e584b42d75522f2a3149e` | MIT |
| pkl | github.com/apple/tree-sitter-pkl | `a02fc36f6001a22e7fdf35eaabbadb7b39c74ba5` | Apache-2.0 |
| powershell | github.com/airbus-cert/tree-sitter-powershell | `da65ba3acc93777255781b447f5e7448245df4bf` | MIT |
| prisma | github.com/victorhqc/tree-sitter-prisma | `3556b2c1f20ec9ac91e92d32c43d9d2a0ca3cc49` | MIT |
| prolog | github.com/Rukiza/tree-sitter-prolog | `c246cf2bf36590a3cb4de380205376d3c46208e8` | ISC |
| promql | github.com/MichaHoffmann/tree-sitter-promql | `77625d78eebc3ffc44d114a07b2f348dff3061b0` | Apache-2.0 |
| properties | github.com/tree-sitter-grammars/tree-sitter-properties | `6310671b24d4e04b803577b1c675d765cbd5773b` | MIT |
| proto | github.com/treywood/tree-sitter-proto | `e9f6b43f6844bd2189b50a422d4e2094313f6aa3` | MIT |
| pug | github.com/zealot128/tree-sitter-pug | `13e9195370172c86a8b88184cc358b23b677cc46` | MIT |
| puppet | github.com/tree-sitter-grammars/tree-sitter-puppet | `15f192929b7d317f5914de2b4accd37b349182a6` | MIT |
| purescript | github.com/postsolar/tree-sitter-purescript | `f541f95ffd6852fbbe88636317c613285bc105af` | MIT |
| python | github.com/tree-sitter/tree-sitter-python | `v0.25.0` | MIT |
| ql | github.com/tree-sitter/tree-sitter-ql | `1fd627a4e8bff8c24c11987474bd33112bead857` | MIT |
| r | github.com/r-lib/tree-sitter-r | `0e6ef7741712c09dc3ee6e81c42e919820cc65ef` | MIT |
| racket | github.com/6cdh/tree-sitter-racket | `56b57807f86aa4ddb14892572b318edd4bc90ebe` | MIT |
| regex | github.com/tree-sitter/tree-sitter-regex | `b2ac15e27fce703d2f37a79ccd94a5c0cbe9720b` | MIT |
| rego | github.com/FallenAngel97/tree-sitter-rego | `ddd39af81fe8b0288102a7cb97959dfce723e0f3` | MIT |
| requirements | github.com/tree-sitter-grammars/tree-sitter-requirements | `caeb2ba854dea55931f76034978de1fd79362939` | MIT |
| rescript | github.com/rescript-lang/tree-sitter-rescript | `43c2f1f35024918d415dc933d4cc534d6419fedf` | MIT |
| robot | github.com/Hubro/tree-sitter-robot | `278958ff2fc44732833f717ee864c9fe4dae6e11` | ISC |
| rst | github.com/stsewd/tree-sitter-rst | `4e562e1598b95b93db4f3f64fe40ddefbc677a15` | MIT |
| ruby | github.com/tree-sitter/tree-sitter-ruby | `ad907a69da0c8a4f7a943a7fe012712208da6dee` | MIT |
| rust | github.com/tree-sitter/tree-sitter-rust | `v0.24.2` | MIT |
| scala | github.com/tree-sitter/tree-sitter-scala | `97aead18d97708190a51d4f551ea9b05b60641c9` | MIT |
| scheme | github.com/6cdh/tree-sitter-scheme | `b5c701148501fa056302827442b5b4956f1edc03` | MIT |
| scss | github.com/tree-sitter-grammars/tree-sitter-scss | `bca847c1410f7dd97e13fbe7838b3c2c203fb473` | MIT |
| smithy | github.com/indoorvivants/tree-sitter-smithy | `ec4fe14586f2b0a1bc65d6db17f8d8acd8a90433` | MIT |
| solidity | github.com/JoranHonig/tree-sitter-solidity | `048fe686cb1fde267243739b8bdbec8fc3a55272` | MIT |
| sparql | github.com/GordianDziwis/tree-sitter-sparql | `1ef52d35a73a2a5f2e433ecfd1c751c1360a923b` | MIT |
| sql | github.com/m-novikov/tree-sitter-sql | `587f30d184b058450be2a2330878210c5f33b3f9` | MIT |
| squirrel | github.com/amaanq/tree-sitter-squirrel | `072c969749e66f000dba35a33c387650e203e96e` | MIT |
| ssh_config | github.com/tree-sitter-grammars/tree-sitter-ssh-config | `71d2693deadaca8cdc09e38ba41d2f6042da1616` | MIT |
| starlark | github.com/tree-sitter-grammars/tree-sitter-starlark | `a453dbf3ba433db0e5ec621a38a7e59d72e4dc69` | MIT |
| svelte | github.com/tree-sitter-grammars/tree-sitter-svelte | `ae5199db47757f785e43a14b332118a5474de1a2` | MIT |
| swift | github.com/alex-pinkus/tree-sitter-swift | `ce6a915cd937ecb2c6d9f79bbf7ef7f7c1ccc61a` | MIT |
| tablegen | github.com/amaanq/tree-sitter-tablegen | `b1170880c61355aaf38fc06f4af7d3c55abdabc4` | MIT |
| tcl | github.com/tree-sitter-grammars/tree-sitter-tcl | `8f11ac7206a54ed11210491cee1e0657e2962c47` | MIT |
| teal | github.com/euclidianAce/tree-sitter-teal | `05d276e737055e6f77a21335b7573c9d3c091e2f` | MIT |
| templ | github.com/vrischmann/tree-sitter-templ | `1c6db04effbcd7773c826bded9783cbc3061bd55` | MIT |
| textproto | github.com/PorterAtGoogle/tree-sitter-textproto | `568471b80fd8793d37ed01865d8c2208a9fefd1b` | ISC |
| thrift | github.com/duskmoon314/tree-sitter-thrift | `68fd0d80943a828d9e6f49c58a74be1e9ca142cf` | MIT |
| tlaplus | github.com/tlaplus-community/tree-sitter-tlaplus | `add40814fda369f6efd989977b2c498aaddde984` | MIT |
| todotxt | github.com/arnarg/tree-sitter-todotxt | `3937c5cd105ec4127448651a21aef45f52d19609` | MIT |
| toml | github.com/tree-sitter/tree-sitter-toml | `342d9be207c2dba869b9967124c679b5e6fd0ebe` | MIT |
| tsx | github.com/tree-sitter/tree-sitter-typescript | `75b3874edb2dc714fb1fd77a32013d0f8699989f` | MIT |
| turtle | github.com/GordianDziwis/tree-sitter-turtle | `7f789ea7ef765080f71a298fc96b7c957fa24422` | MIT |
| typescript | github.com/tree-sitter/tree-sitter-typescript | `v0.23.2` | MIT |
| typst | github.com/uben0/tree-sitter-typst | `46cf4ded12ee974a70bf8457263b67ad7ee0379d` | MIT |
| uxntal | github.com/amaanq/tree-sitter-uxntal | `ad9b638b914095320de85d59c49ab271603af048` | MIT |
| v | github.com/vlang/v-analyzer | `9cf6a37689f06b17d170dec644ace81eb8eab280` | MIT |
| verilog | github.com/tree-sitter/tree-sitter-verilog | `227d277b6a1a5e2bf818d6206935722a7503de08` | MIT |
| vimdoc | github.com/neovim/tree-sitter-vimdoc | `f061895a0eff1d5b90e4fb60d21d87be3267031a` | Apache-2.0 |
| vue | github.com/tree-sitter-grammars/tree-sitter-vue | `ce8011a414fdf8091f4e4071752efc376f4afb08` | MIT |
| wat | github.com/wasm-lsp/tree-sitter-wasm | `2ca28a9f9d709847bf7a3de0942a84e912f59088` | Apache-2.0 WITH LLVM-exception |
| wgsl | github.com/szebniok/tree-sitter-wgsl | `40259f3c77ea856841a4e0c4c807705f3e4a2b65` | MIT |
| wolfram | github.com/bostick/tree-sitter-wolfram | `63ebdac6f040d9082d3d8fa88be96ce24549adc5` | MIT |
| xml | github.com/tree-sitter-grammars/tree-sitter-xml | `5000ae8f22d11fbe93939b05c1e37cf21117162d` | MIT |
| yaml | github.com/tree-sitter-grammars/tree-sitter-yaml | `4463985dfccc640f3d6991e3396a2047610cf5f8` | MIT |
| yuck | github.com/Philipp-M/tree-sitter-yuck | `e877f6ade4b77d5ef8787075141053631ba12318` | MIT |
| zig | github.com/tree-sitter-grammars/tree-sitter-zig | `6479aa13f32f701c383083d8b28360ebd682fb7d` | MIT |
