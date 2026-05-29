(** Markdown rendering with syntax-highlighted code blocks. See [markdown.mli]
    for the rationale; in short, we rebuild Yocaml's default grammar table and
    add two grammars on top: the Scala TextMate grammar (embedded at build time
    via [Scala_grammar]) and shell (which hilite ships but Yocaml's default set
    omits), so [```scala] and [```bash] blocks are highlighted alongside
    OCaml/dune/opam/diff. *)

(* Grammars are looked up by [name], but hilite's shell grammar has no [name]
   field, so we inject one — mirroring the (unexposed) [Hilite.add_name]. This
   lets us register the same grammar under several fence aliases. *)
let with_name name = function
  | `Assoc assoc -> `Assoc (("name", `String name) :: assoc)
  | _ -> invalid_arg "Markdown.with_name: grammar is not a JSON object"
;;

let grammars =
  let t = TmLanguage.create () in
  let add g = g |> TmLanguage.of_yojson_exn |> TmLanguage.add_grammar t in
  List.iter
    add
    [ Hilite.Grammars.ocaml
    ; Hilite.Grammars.ocaml_interface
    ; Hilite.Grammars.dune
    ; Hilite.Grammars.opam
    ; Hilite.Grammars.diff
    ];
  (* Register the shell grammar under the fence aliases we use. *)
  List.iter
    (fun alias -> add (with_name alias Hilite.Grammars.shell))
    [ "bash"; "sh"; "shell" ];
  add (Yojson.Basic.from_string Scala_grammar.json);
  t
;;

let highlight = Yocaml_markdown.Doc.syntax_highlighting ~tm:grammars ()
let to_html content = Yocaml_markdown.from_string_to_html ~highlight content
