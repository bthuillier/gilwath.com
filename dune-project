(lang dune 3.20)
(name blog)
(version dev)
(generate_opam_files)

(source (github bthuillier/blog))
(license MIT)
(authors "Benjamin Thuillier <benjamin@thuillier.com>")
(maintainers "Benjamin Thuillier <benjamin@thuillier.com>")

(package
 (name blog)
 (synopsis "My first blog using YOCaml")
 (description
   "My first personal blog using YOCaml for
   fun and profit")
 (depends
  (ocaml (>= 5.5.0))
  (yocaml (>= 3.0.0))
  (yocaml_unix (>= 3.0.0))
  cmarkit
  hilite
  yojson
  textmate-language
  (yocaml_yaml (>= 3.0.0))
  (yocaml_markdown (>= 3.0.0))
  (yocaml_jingoo (>= 3.0.0))
  (yocaml_syndication (>= 3.0.0))
  
  ;; Dev setup
  (utop :with-dev-setup)
  (ocamlformat :with-dev-setup)
  (ocp-indent :with-dev-setup)
  (merlin :with-dev-setup)
  (ocaml-lsp-server :with-dev-setup)))