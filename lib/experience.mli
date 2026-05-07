(** A single professional experience, sourced from a markdown file under
    [content/experiences/]. The body of that file is the experience description;
    the front matter populates this record. *)

open Yocaml

type t

include Required.DATA_READABLE with type t := t
include Required.DATA_INJECTABLE with type t := t

val start_date : t -> Archetype.Datetime.t
(** [start_date e] — exposed so callers can sort experiences chronologically
    without reaching into the record. *)
