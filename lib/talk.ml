open Yocaml

type t =
  { title : string
  ; date : Archetype.Datetime.t
  ; description : string
  ; slides : string
  ; event : string option
  ; event_url : string option
  }

let entity_name = "Talk"

(* No sensible neutral value — front matter is required. *)
let neutral = Metadata.required entity_name
let date t = t.date

let validate =
  let open Data.Validation in
  record (fun fields ->
    let+ title = required fields "title" string
    and+ date = required fields "date" Archetype.Datetime.validate
    and+ description = required fields "description" string
    and+ slides = required fields "slides" string
    and+ event = optional fields "event" string
    and+ event_url = optional fields "event_url" string in
    { title; date; description; slides; event; event_url })
;;

let normalize { title; date; description; slides; event; event_url } =
  Data.
    [ "title", string title
    ; "date", Archetype.Datetime.normalize date
    ; "description", string description
    ; "slides", string slides
    ; "event", option string event
    ; "has_event", bool (Option.is_some event)
    ; "event_url", option string event_url
    ; "has_event_url", bool (Option.is_some event_url)
    ]
;;
