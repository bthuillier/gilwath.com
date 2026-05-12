(** A single education entry, sourced from a markdown file under
    [content/education/]. The body of that file is the description; the front
    matter populates this record. *)

open Yocaml

type t =
  { degree : string
  ; school : string
  ; field : string option
  ; location : string option
  ; start_date : Archetype.Datetime.t
  ; end_date : Archetype.Datetime.t option
  }

let entity_name = "Education"

(* No sensible neutral value — front matter is required. *)
let neutral = Metadata.required entity_name
let start_date e = e.start_date

let validate =
  let open Data.Validation in
  record (fun fields ->
    let+ degree = required fields "degree" string
    and+ school = required fields "school" string
    and+ field = optional fields "field" string
    and+ location = optional fields "location" string
    and+ start_date = required fields "start_date" Archetype.Datetime.validate
    and+ end_date = optional fields "end_date" Archetype.Datetime.validate in
    { degree; school; field; location; start_date; end_date })
;;

let normalize { degree; school; field; location; start_date; end_date } =
  Data.
    [ "degree", string degree
    ; "school", string school
    ; "field", option string field
    ; "location", option string location
    ; "start_date", Archetype.Datetime.normalize start_date
    ; "end_date", option Archetype.Datetime.normalize end_date
    ; "has_end_date", bool (Option.is_some end_date)
    ; "has_field", bool (Option.is_some field)
    ; "has_location", bool (Option.is_some location)
    ]
;;
