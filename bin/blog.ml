open Yocaml

(* -------------------------------------------------------------------------- *)
(* Paths                                                                      *)
(* -------------------------------------------------------------------------- *)

let www = Path.rel [ "_www" ]

let assets = Path.rel [ "assets" ]
let css = Path.(assets / "css")
let images = Path.(assets / "images")
let templates = Path.(assets / "templates")

let content = Path.rel [ "content" ]
let pages = Path.(content / "pages")
let articles = Path.(content / "articles")

let experiences = Path.(content / "experiences")

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let with_ext exts file =
  List.exists (fun ext -> Path.has_extension ext file) exts

let is_markdown = with_ext [ "md"; "markdown"; "mdown" ]

let track_binary =
  Sys.executable_name
  |> Yocaml.Path.from_string
  |> Pipeline.track_file

let compute_link source =
  let into = Path.abs [ "articles" ] in
  source
  |> Path.move ~into
  |> Path.change_extension "html"

(* -------------------------------------------------------------------------- *)
(* Site-wide configuration                                                    *)
(* -------------------------------------------------------------------------- *)

(* [Site] mirrors the YAML record stored in [content/site.yml]. The fields are
   exposed under the [site.*] namespace in every template, both in HTML
   templates and in markdown bodies (which are pre-rendered with Jingoo, see
   [render_md]). *)
module Site : sig
  type t

  include Required.DATA_READABLE with type t := t
  include Required.DATA_INJECTABLE with type t := t

  val to_data : t -> Data.t
end = struct
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
end

let site_path = Path.(content / "site.yml")

let read_site =
  Yocaml_yaml.Pipeline.read_file_as_metadata (module Site) site_path

(* -------------------------------------------------------------------------- *)
(* Document kinds                                                             *)
(* -------------------------------------------------------------------------- *)

type document_kind =
  | Page
  | Article

module type ARCHETYPE = sig
  include Yocaml.Required.DATA_INJECTABLE
  include Yocaml.Required.DATA_READABLE with type t := t
end

(* Wraps a [DATA_INJECTABLE] so that templates also see a [site.*] namespace.
   We carry [Site.t] alongside the page-specific metadata as a pair, then
   project it into the normalized record under the [site] key. *)
module With_site (I : Yocaml.Required.DATA_INJECTABLE)
  : Yocaml.Required.DATA_INJECTABLE with type t = I.t * Site.t = struct
  type t = I.t * Site.t

  let normalize (inner, site) =
    ("site", Site.to_data site) :: I.normalize inner
end

(* Pre-render a markdown body with Jingoo so that [{{ site.* }}] (and any
   front-matter field) can be referenced inside the .md file itself. We run
   this *before* the markdown→HTML conversion so that values like email or
   URLs land cleanly in markdown link syntax. [strict:false] keeps unknown
   variables from blowing up — useful while front-matter shapes evolve. *)
let render_md ~metadata content =
  let parameters =
    metadata
    |> List.map (fun (k, v) -> (k, Yocaml_jingoo.from v))
  in
  Yocaml_jingoo.render ~strict:false parameters content

(* -------------------------------------------------------------------------- *)
(* Experience archetype + CV page                                             *)
(* -------------------------------------------------------------------------- *)

(* Note: the record fields are intentionally exposed (no signature ascription)
   so [fetch_experiences] can read [start_date] when sorting, and [Cv] can
   normalize values directly. *)
module Experience = struct
  type t =
    { company : string
    ; role : string
    ; start_date : Archetype.Datetime.t
    ; end_date : Archetype.Datetime.t option
    }

  let entity_name = "Experience"

  (* No sensible neutral value — fail like Article does. *)
  let neutral =
    Data.Validation.fail_with ~given:"null" "Cannot be null"
    |> Result.map_error (fun error ->
        Required.Validation_error { entity = entity_name; error })

  let validate =
    let open Data.Validation in
    record (fun fields ->
      let+ company = required fields "company" string
      and+ role = required fields "role" string
      and+ start_date = required fields "start_date" Archetype.Datetime.validate
      and+ end_date = optional fields "end_date" Archetype.Datetime.validate in
      { company; role; start_date; end_date })

  let normalize { company; role; start_date; end_date } =
    Data.[
      "company", string company;
      "role", string role;
      "start_date", Archetype.Datetime.normalize start_date;
      "end_date", option Archetype.Datetime.normalize end_date;
      "has_end_date", bool (Option.is_some end_date);
    ]
end

(* Fetches every markdown file under [content/experiences/], converts the body
   to HTML, and returns a list sorted most-recent-first. The body travels
   alongside the metadata as a tuple — same pattern as [Archetype.Articles]
   pairs a URL with each article rather than baking it into [Article.t]. *)
let fetch_experiences =
  let open Task in
  Pipeline.fetch
    ~only:`Files
    ~where:is_markdown
    ~on:`Source
    (fun file ->
      let open Eff in
      let+ metadata, content =
        Eff.read_file_with_metadata
          (module Yocaml_yaml)
          (module Experience)
          ~on:`Source
          file
      in
      (metadata, Yocaml_markdown.from_string_to_html content))
    experiences
  >>| List.sort (fun (a, _) (b, _) ->
        ~- (Archetype.Datetime.compare a.Experience.start_date b.Experience.start_date))

module Cv = struct
  type t =
    { page : Archetype.Page.t
    ; experiences : (Experience.t * string) list
    }

  let with_page ~page ~experiences = { page; experiences }

  let normalize { page; experiences } =
    Archetype.Page.normalize page
    @ Data.[
        "experiences",
          list_of
            (fun (exp, body) ->
              record (("body", string body) :: Experience.normalize exp))
            experiences;
        "has_experiences", bool (experiences <> []);
      ]
end

let document_sources = function
  | Page -> pages
  | Article -> articles

let document_path document_kind path =
  let into = match document_kind with
    | Page -> www
    | Article -> Path.(www / "articles")
  in
  path |> Path.move ~into |> Path.change_extension "html"

let get_specific_template document_kind =
  let file = match document_kind with
    | Page -> "page.html"
    | Article -> "article.html"
  in
  Path.(templates / file)

let document_archetype : document_kind -> (module ARCHETYPE) = function
  | Page -> (module Archetype.Page)
  | Article -> (module Archetype.Article)

(* -------------------------------------------------------------------------- *)
(* Articles index                                                             *)
(* -------------------------------------------------------------------------- *)

let fetch_articles =
  Archetype.Articles.fetch
    ~where:is_markdown
    ~compute_link
    (module Yocaml_yaml)
    articles

(* -------------------------------------------------------------------------- *)
(* Build actions                                                              *)
(* -------------------------------------------------------------------------- *)

let create_document document_kind source =
  let module Archetype = (val document_archetype document_kind) in
  let module Bundle = With_site (Archetype) in
  let target = document_path document_kind source
  and pipeline =
    let open Task in
    let+ () = track_binary
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ get_specific_template document_kind
             ; templates / "layout.html" ]
    and+ site = read_site
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype)
        source
    in
    let bundle = (metadata, site) in
    content
    |> render_md ~metadata:(Bundle.normalize bundle)
    |> Yocaml_markdown.from_string_to_html
    |> templates (module Bundle) ~metadata:bundle
  in
  Action.Static.write_file target pipeline

let create_documents document_kind =
  let sources = document_sources document_kind in
  Batch.iter_files ~where:is_markdown sources
    (create_document document_kind)

let create_pages = create_documents Page
let create_articles = create_documents Article

let create_index =
  let module Bundle = With_site (Archetype.Articles) in
  let source = Path.(content / "index.md") in
  let index_path =
    source
    |> Path.move ~into:www
    |> Path.change_extension "html"
  in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ templates / "index.html"
             ; templates / "page.html"
             ; templates / "layout.html"
             ]
    and+ site = read_site
    and+ articles = fetch_articles
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype.Page)
        source
    in
    let metadata =
      Archetype.Articles.with_page
        ~page:metadata
        ~articles
    in
    let bundle = (metadata, site) in
    content
    |> render_md ~metadata:(Bundle.normalize bundle)
    |> Yocaml_markdown.from_string_to_html
    |> templates (module Bundle) ~metadata:bundle
  in
  Action.Static.write_file index_path pipeline

let create_cv =
  let module Bundle = With_site (struct
    type t = Cv.t
    let normalize = Cv.normalize
  end) in
  let source = Path.(content / "cv.md") in
  let cv_path =
    source
    |> Path.move ~into:www
    |> Path.change_extension "html"
  in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ templates / "cv.html"
             ; templates / "layout.html"
             ]
    and+ site = read_site
    and+ experiences = fetch_experiences
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype.Page)
        source
    in
    let cv = Cv.with_page ~page:metadata ~experiences in
    let bundle = (cv, site) in
    content
    |> render_md ~metadata:(Bundle.normalize bundle)
    |> Yocaml_markdown.from_string_to_html
    |> templates (module Bundle) ~metadata:bundle
  in
  Action.Static.write_file cv_path pipeline

let copy_images =
  let images_path = Path.(www / "images")
  and where = with_ext [ "svg"; "png"; "jpg"; "gif" ] in
  Batch.iter_files
    ~where images
    (Action.copy_file ~into:images_path)

let create_css =
  let css_path = Path.(www / "style.css") in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ content =
      Pipeline.pipe_files ~separator:"\n"
        Path.[ css / "reset.css"
             ; css / "style.css" ]
    in
    content
  in
  Action.Static.write_file css_path pipeline

(* -------------------------------------------------------------------------- *)
(* Program                                                                    *)
(* -------------------------------------------------------------------------- *)

let program () =
  let open Eff in
  let cache = Path.(www / ".cache") in
  Action.restore_cache cache
  >>= copy_images
  >>= create_css
  >>= create_pages
  >>= create_articles
  >>= create_index
  >>= create_cv
  >>= Action.store_cache cache

let () =
  match Sys.argv.(1) with
  | "server" ->
    Yocaml_unix.serve
      ~level:`Info
      ~target:www
      ~port:8000
      program
  | _ | (exception _) ->
    Yocaml_unix.run
      ~level:`Debug
      program
