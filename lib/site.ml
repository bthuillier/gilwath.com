(** Site-wide configuration, mirroring the YAML record stored in
    [content/site.yml]. Exposed under the [site.*] namespace in every
    template, both in HTML templates and in markdown bodies (which are
    pre-rendered with Jingoo). *)

open Yocaml

type t =
  { name : string
  ; author : string
  ; email : string
  ; github : string
  }

let entity_name = "Site"

let neutral = Result.ok
  { name = ""; author = ""; email = ""; github = "" }

let validate =
  let open Data.Validation in
  record (fun fields ->
    let+ name = required fields "name" string
    and+ author = required fields "author" string
    and+ email = required fields "email" string
    and+ github = required fields "github" string in
    { name; author; email; github })

let normalize { name; author; email; github } =
  Data.[
    "name", string name;
    "author", string author;
    "email", string email;
    "github", string github;
  ]

let to_data s = Data.record (normalize s)
