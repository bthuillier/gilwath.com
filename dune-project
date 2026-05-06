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
  (ocaml (>= 5.3.0))
  (yocaml (>= 2.5.0))
  (yocaml_unix (>= 2.5.0))
  cmarkit
  hilite
  (yocaml_yaml (>= 2.5.0))
  (yocaml_markdown (>= 2.5.0))
  (yocaml_jingoo (>= 2.5.0))
  
  ;; Dev setup
  (utop :with-dev-setup)
  (ocamlformat :with-dev-setup)
  (ocp-indent :with-dev-setup)
  (merlin :with-dev-setup)
  (ocaml-lsp-server :with-dev-setup)))