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
(* Domain modules — defined in the [blog_core] library                        *)
(* -------------------------------------------------------------------------- *)

module Site = Blog_core.Site
module Experience = Blog_core.Experience
module Cv = Blog_core.Cv
module Reading_time = Blog_core.Reading_time

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
        ~- (Archetype.Datetime.compare
              (Experience.start_date a) (Experience.start_date b)))

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

(* Article-only extras injected into the template namespace. Computed from
   the raw markdown body before rendering — see [Reading_time.estimate]. *)
let document_extras document_kind content =
  match document_kind with
  | Article -> Data.[ "reading_time", int (Reading_time.estimate content) ]
  | Page -> []

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
    let extras = document_extras document_kind content in
    (* Wrap [Bundle] so that [extras] are visible to both the in-body Jingoo
       pre-render (via [render_md]) and to the surrounding template chain. *)
    let module Bundle_with_extras = struct
      type t = Bundle.t
      let normalize b = extras @ Bundle.normalize b
    end in
    content
    |> render_md ~metadata:(Bundle_with_extras.normalize bundle)
    |> Yocaml_markdown.from_string_to_html
    |> templates (module Bundle_with_extras) ~metadata:bundle
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

(* The /blog.html listing — same shape as [create_index], with its own
   template chain and source. Kept as a distinct action (rather than
   parameterised) until a third listing appears and the duplication earns
   its own helper. *)
let create_blog =
  let module Bundle = With_site (Archetype.Articles) in
  let source = Path.(content / "blog.md") in
  let blog_path =
    source
    |> Path.move ~into:www
    |> Path.change_extension "html"
  in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ templates / "blog.html"
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
  Action.Static.write_file blog_path pipeline

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

(* Copies [assets/CNAME] verbatim into [_www/CNAME]. GitHub Pages reads this
   file from the deploy artifact to bind the site to the custom domain
   (gilwath.com). Keeping the source in [assets/] means it travels with the
   build pipeline rather than being a stray file in the generated output. *)
let copy_cname =
  Action.copy_file ~into:www Path.(assets / "CNAME")

(* SVG favicon — referenced by [/favicon.svg] in layout.html. Living in
   [assets/] (not [assets/images/]) so it lands at the site root, where
   browsers expect it. *)
let copy_favicon =
  Action.copy_file ~into:www Path.(assets / "favicon.svg")

(* Permissive robots.txt with a sitemap pointer. Crawlers find sitemap.xml
   through this hint even without manual webmaster-tools registration. *)
let create_robots =
  let robots_path = Path.(www / "robots.txt") in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ site = read_site in
    Printf.sprintf "User-agent: *\nAllow: /\n\nSitemap: %s/sitemap.xml\n"
      (Site.url site)
  in
  Action.Static.write_file robots_path pipeline

(* sitemap.xml — covers the four top-level pages plus every article. The
   article list is the same one used to build the index/blog listings; its
   URLs are absolute paths under [/articles/], which we prefix with the
   site origin to satisfy the sitemap schema. *)
let create_sitemap =
  let sitemap_path = Path.(www / "sitemap.xml") in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ site = read_site
    and+ articles = fetch_articles in
    let url loc =
      Printf.sprintf "  <url><loc>%s%s</loc></url>" (Site.url site) loc
    in
    let static_urls = List.map url [ "/"; "/blog.html"; "/cv.html" ] in
    let article_urls =
      List.map (fun (path, _article) -> url (Path.to_string path)) articles
    in
    String.concat "\n"
      ([ {|<?xml version="1.0" encoding="UTF-8"?>|}
       ; {|<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">|} ]
       @ static_urls
       @ article_urls
       @ [ "</urlset>" ])
  in
  Action.Static.write_file sitemap_path pipeline

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
  >>= copy_cname
  >>= copy_favicon
  >>= create_css
  >>= create_pages
  >>= create_articles
  >>= create_index
  >>= create_blog
  >>= create_cv
  >>= create_robots
  >>= create_sitemap
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
