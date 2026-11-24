(** A talk I gave, sourced from a markdown file under [content/talks/]. Only
    the front matter is used: talks are listed on the home page with their
    date, a short description and a link to the slides. The slides themselves
    live in [talks/<slug>/] and are copied verbatim under [/talks/<slug>/]. *)

open Yocaml

type t

include Required.DATA_READABLE with type t := t
include Required.DATA_INJECTABLE with type t := t

(** [date t] — exposed so callers can sort talks most-recent-first. *)
val date : t -> Archetype.Datetime.t
