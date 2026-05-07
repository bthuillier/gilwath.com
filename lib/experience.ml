(** A single professional experience, sourced from a markdown file under
    [content/experiences/]. The body of that file is the experience
    description; the front matter populates this record. *)

open Yocaml

type t =
  { role : string
  ; company : string
  ; skills : string list
  ; start_date : Archetype.Datetime.t
  ; end_date : Archetype.Datetime.t option
  }

let entity_name = "Experience"

(* No sensible neutral value — fail like Article does. *)
let neutral =
  Data.Validation.fail_with ~given:"null" "Cannot be null"
  |> Result.map_error (fun error ->
      Required.Validation_error { entity = entity_name; error })

let start_date e = e.start_date

let validate =
  let open Data.Validation in
  record (fun fields ->
    let+ role = required fields "role" string
    and+ company = required fields "company" string
    and+ skills = optional_or ~default:[] fields "skills" (list_of string)
    and+ start_date = required fields "start_date" Archetype.Datetime.validate
    and+ end_date = optional fields "end_date" Archetype.Datetime.validate in
    { role; company; skills; start_date; end_date })

let normalize { role; company; skills; start_date; end_date } =
  Data.[
    "role", string role;
    "company", string company;
    "skills", list_of string skills;
    "start_date", Archetype.Datetime.normalize start_date;
    "end_date", option Archetype.Datetime.normalize end_date;
    "has_end_date", bool (Option.is_some end_date);
  ]
