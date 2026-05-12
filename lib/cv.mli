(** The CV page: a [Yocaml.Archetype.Page.t] (front-matter + body) carrying a
    list of [Experience]s and a list of [Education] entries. *)

open Yocaml

type t

(** Bundle a page with its experiences and education. The page metadata is
    read separately (it has its own [Archetype.Page] front matter); the
    experiences come from [content/experiences/] and the education entries
    from [content/education/]. *)
val with_page
  :  page:Archetype.Page.t
  -> experiences:(Experience.t * string) list
  -> education:(Education.t * string) list
  -> t

(** [normalize cv] — exposed for use as the [DATA_INJECTABLE.normalize] of a
    locally-defined module wrapping [t]. *)
val normalize : t -> (string * Data.t) list
