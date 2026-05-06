(** The CV page: a [Page] (front-matter + body) carrying a list of
    [Experience]s, each paired with its rendered HTML body. The pairing
    pattern mirrors [Yocaml.Archetype.Articles], which carries a URL alongside
    each [Article] without baking it into the type. *)

open Yocaml

type t =
  { page : Archetype.Page.t
  ; experiences : (Experience.t * string) list
  }

let with_page ~page ~experiences = { page; experiences }

let normalize { page; experiences } =
  Archetype.Page.normalize page
  @ Data.[
      "experiences",
        list_of
          (fun (exp, body) ->
            record (("body", string body) :: Experience.normalize exp))
          experiences;
      "has_experiences", bool (experiences <> []);
    ]
