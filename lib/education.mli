(** A single education entry, sourced from a markdown file under
    [content/education/]. The body of that file is the description; the front
    matter populates this record. *)

open Yocaml

type t

include Required.DATA_READABLE with type t := t
include Required.DATA_INJECTABLE with type t := t

(** [start_date e] — exposed so callers can sort education entries
    chronologically without reaching into the record. *)
val start_date : t -> Archetype.Datetime.t
