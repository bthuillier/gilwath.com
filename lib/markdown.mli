(** Markdown rendering with syntax-highlighted code blocks.

    Wraps {!Yocaml_markdown} so that fenced code blocks are highlighted with an
    extended grammar set. Yocaml's default highlighter only ships grammars for
    OCaml, dune, opam and diff; this module adds Scala and shell ([bash]/[sh])
    on top, so [```scala] and [```bash] blocks are tokenised rather than
    rendered as plain text. Highlight classes follow the usual scheme
    ([.scala-keyword], [.shell-string-quoted-double], …) and are styled in
    [assets/css/style.css]. *)

(** [to_html content] renders the markdown [content] to an HTML string,
    highlighting fenced code blocks. Drop-in replacement for
    [Yocaml_markdown.from_string_to_html] with the extended grammar set. *)
val to_html : string -> string
