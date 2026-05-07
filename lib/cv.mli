(** The CV page: a [Yocaml.Archetype.Page.t] (front-matter + body) carrying a
    list of [Experience]s, each paired with its rendered HTML body. *)

open Yocaml

type t

(** Bundle a page and its experiences. The page metadata is read separately (it
    has its own [Archetype.Page] front matter); the experiences come from the
    [content/experiences/] folder. *)
val with_page
  :  page:Archetype.Page.t
  -> experiences:(Experience.t * string) list
  -> t

(** [normalize cv] — exposed for use as the [DATA_INJECTABLE.normalize] of a
    locally-defined module wrapping [t]. *)
val normalize : t -> (string * Data.t) list
