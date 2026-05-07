(** Site-wide configuration, mirroring the YAML record stored in
    [content/site.yml]. Exposed under the [site.*] namespace in every template,
    both in HTML templates and in markdown bodies (which are pre-rendered with
    Jingoo). *)

open Yocaml

type t = {
  name : string;
  author : string;
  email : string;
  github : string;
  linkedin : string;
  bluesky : string;
  url : string;
  description : string;
  lang : string;
  og_image : string;
  theme_color : string;
}

let entity_name = "Site"

(* No sensible neutral value — [content/site.yml] is required. *)
let neutral = Metadata.required entity_name

let validate =
  let open Data.Validation in
  record (fun fields ->
      let+ name = required fields "name" string
      and+ author = required fields "author" string
      and+ email = required fields "email" string
      and+ github = required fields "github" string
      and+ linkedin = optional_or ~default:"" fields "linkedin" string
      and+ bluesky = optional_or ~default:"" fields "bluesky" string
      and+ url = required fields "url" string
      and+ description = required fields "description" string
      and+ lang = optional_or ~default:"en" fields "lang" string
      and+ og_image = optional_or ~default:"" fields "og_image" string
      and+ theme_color =
        optional_or ~default:"#ffffff" fields "theme_color" string
      in
      {
        name;
        author;
        email;
        github;
        linkedin;
        bluesky;
        url;
        description;
        lang;
        og_image;
        theme_color;
      })

let normalize
    {
      name;
      author;
      email;
      github;
      linkedin;
      bluesky;
      url;
      description;
      lang;
      og_image;
      theme_color;
    } =
  Data.
    [
      ("name", string name);
      ("author", string author);
      ("email", string email);
      ("github", string github);
      ("linkedin", string linkedin);
      ("bluesky", string bluesky);
      ("url", string url);
      ("description", string description);
      ("lang", string lang);
      ("og_image", string og_image);
      ("theme_color", string theme_color);
    ]

let to_data s = Data.record (normalize s)
let url s = s.url
let name s = s.name
let author s = s.author
let email s = s.email
let description s = s.description
