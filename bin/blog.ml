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
let site_path = Path.(content / "site.yml")

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let with_ext exts file =
  List.exists (fun ext -> Path.has_extension ext file) exts

let is_markdown = with_ext [ "md"; "markdown"; "mdown" ]

let track_binary =
  Sys.executable_name |> Yocaml.Path.from_string |> Pipeline.track_file

(* The value is read once at program start; this keeps it in the dep set
   so editing [site.yml] reruns every page. *)
let track_site = Pipeline.track_file site_path

let compute_link source =
  let into = Path.abs [ "articles" ] in
  source |> Path.move ~into |> Path.change_extension "html"

(* -------------------------------------------------------------------------- *)
(* Domain modules                                                             *)
(* -------------------------------------------------------------------------- *)

module Site = Blog_core.Site
module Experience = Blog_core.Experience
module Cv = Blog_core.Cv
module Reading_time = Blog_core.Reading_time

module Feed = struct
  let path = "atom.xml"

  let owner site =
    Yocaml_syndication.Person.make ~uri:(Site.url site) ~email:(Site.email site)
      (Site.author site)

  let authors site = Nel.singleton (owner site)

  let article_to_entry ~site (url, article) =
    let open Yocaml.Archetype in
    let open Yocaml_syndication in
    let page = Article.page article in
    let title = Article.title article
    and content_url = Site.url site ^ Path.to_string url
    and updated = Datetime.make (Article.date article)
    and categories = List.map Category.make (Page.tags page)
    and summary = Option.map Atom.text (Page.description page) in

    let links = [ Atom.alternate content_url ~title ] in
    Atom.entry ~links ~categories ?summary ~updated ~id:content_url
      ~title:(Atom.text title) ()

  let make ~site entries =
    let open Yocaml_syndication in
    Atom.feed
      ~title:(Atom.text (Site.name site))
      ~subtitle:(Atom.text (Site.description site))
      ~updated:(Atom.updated_from_entries ())
      ~authors:(authors site) ~id:(Site.url site) (article_to_entry ~site)
      entries
end

(* Not a top-level [let]: [_ Eff.t] performs its effects on construction
   (via [let*]), so we'd raise [Effect.Unhandled] before the runtime
   handler is installed. *)
let read_site () =
  Eff.read_file_as_metadata
    (module Yocaml_yaml)
    (module Site)
    ~on:`Source site_path

let inject_site site fields = ("site", Site.to_data site) :: fields

(* Pre-normalized fields — [Yocaml_jingoo.read_templates] still wants a
   [DATA_INJECTABLE], so we hand it the identity. *)
module Fields : Required.DATA_INJECTABLE with type t = (string * Data.t) list =
struct
  type t = (string * Data.t) list

  let normalize fields = fields
end

(* -------------------------------------------------------------------------- *)
(* Document kinds                                                             *)
(* -------------------------------------------------------------------------- *)

type document_kind = Page | Article

module type ARCHETYPE = sig
  include Yocaml.Required.DATA_INJECTABLE
  include Yocaml.Required.DATA_READABLE with type t := t
end

(* Run *before* markdown→HTML so [{{ site.* }}] expands into raw markdown
   (e.g. into link targets). [strict:false] tolerates unknown variables. *)
let render_md ~metadata content =
  let parameters =
    metadata |> List.map (fun (k, v) -> (k, Yocaml_jingoo.from v))
  in
  Yocaml_jingoo.render ~strict:false parameters content

(* (Experience.t * html body) list, sorted most-recent-first. *)
let fetch_experiences =
  let open Task in
  Pipeline.fetch ~only:`Files ~where:is_markdown ~on:`Source
    (fun file ->
      let open Eff in
      let+ metadata, content =
        Eff.read_file_with_metadata
          (module Yocaml_yaml)
          (module Experience)
          ~on:`Source file
      in
      (metadata, Yocaml_markdown.from_string_to_html content))
    experiences
  >>| List.sort (fun (a, _) (b, _) ->
      ~-(Archetype.Datetime.compare (Experience.start_date a)
           (Experience.start_date b)))

let document_sources = function Page -> pages | Article -> articles

let document_path document_kind path =
  let into =
    match document_kind with Page -> www | Article -> Path.(www / "articles")
  in
  path |> Path.move ~into |> Path.change_extension "html"

let get_specific_template document_kind =
  let file =
    match document_kind with Page -> "page.html" | Article -> "article.html"
  in
  Path.(templates / file)

let document_archetype : document_kind -> (module ARCHETYPE) = function
  | Page -> (module Archetype.Page)
  | Article -> (module Archetype.Article)

(* -------------------------------------------------------------------------- *)
(* Articles index                                                             *)
(* -------------------------------------------------------------------------- *)

let fetch_articles =
  Archetype.Articles.fetch ~where:is_markdown ~compute_link
    (module Yocaml_yaml)
    articles

(* -------------------------------------------------------------------------- *)
(* Build actions                                                              *)
(* -------------------------------------------------------------------------- *)

(* Estimated on the raw markdown, before rendering. *)
let document_extras document_kind content =
  match document_kind with
  | Article -> Data.[ ("reading_time", int (Reading_time.estimate content)) ]
  | Page -> []

(* The shared tail of every page builder: pre-render markdown, convert to
   HTML, apply the template chain. *)
let render_through templates fields content =
  content |> render_md ~metadata:fields |> Yocaml_markdown.from_string_to_html
  |> templates
       (module Fields : Required.DATA_INJECTABLE
         with type t = (string * Data.t) list)
       ~metadata:fields

let create_feed ~site =
  let feed_path = Path.(www / Feed.path)
  and pipeline =
    let open Task in
    let+ () = track_binary
    and+ () = track_site
    and+ articles = fetch_articles in
    articles |> Feed.make ~site |> Yocaml_syndication.Xml.to_string
  in
  Action.Static.write_file feed_path pipeline

let create_document ~site document_kind source =
  let module Archetype = (val document_archetype document_kind) in
  let target = document_path document_kind source
  and pipeline =
    let open Task in
    let+ () = track_binary
    and+ () = track_site
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ get_specific_template document_kind; templates / "layout.html" ]
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata (module Archetype) source
    in
    let extras = document_extras document_kind content in
    let fields = inject_site site (extras @ Archetype.normalize metadata) in
    render_through templates fields content
  in
  Action.Static.write_file target pipeline

let create_documents ~site document_kind =
  let sources = document_sources document_kind in
  Batch.iter_files ~where:is_markdown sources
    (create_document ~site document_kind)

let create_pages ~site = create_documents ~site Page
let create_articles ~site = create_documents ~site Article

(* Shared by [/] and [/blog.html]: a [Page] enriched with the article list. *)
let create_listing ~site ~source ~into:dest_dir ~templates:template_chain =
  let listing_path =
    source |> Path.move ~into:dest_dir |> Path.change_extension "html"
  in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ () = track_site
    and+ templates = Yocaml_jingoo.read_templates template_chain
    and+ articles = fetch_articles
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype.Page)
        source
    in
    let listing = Archetype.Articles.with_page ~page:metadata ~articles in
    let fields = inject_site site (Archetype.Articles.normalize listing) in
    render_through templates fields content
  in
  Action.Static.write_file listing_path pipeline

let create_index ~site =
  create_listing ~site
    ~source:Path.(content / "index.md")
    ~into:www
    ~templates:
      Path.
        [
          templates / "index.html";
          templates / "page.html";
          templates / "layout.html";
        ]

let create_blog ~site =
  create_listing ~site
    ~source:Path.(content / "blog.md")
    ~into:www
    ~templates:Path.[ templates / "blog.html"; templates / "layout.html" ]

let create_cv ~site =
  let source = Path.(content / "cv.md") in
  let cv_path = source |> Path.move ~into:www |> Path.change_extension "html" in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ () = track_site
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.[ templates / "cv.html"; templates / "layout.html" ]
    and+ experiences = fetch_experiences
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype.Page)
        source
    in
    let cv = Cv.with_page ~page:metadata ~experiences in
    let fields = inject_site site (Cv.normalize cv) in
    render_through templates fields content
  in
  Action.Static.write_file cv_path pipeline

let copy_images =
  let images_path = Path.(www / "images")
  and where = with_ext [ "svg"; "png"; "jpg"; "gif" ] in
  Batch.iter_files ~where images (Action.copy_file ~into:images_path)

(* GitHub Pages reads [_www/CNAME] to bind the site to gilwath.com. *)
let copy_cname = Action.copy_file ~into:www Path.(assets / "CNAME")

(* Lives at the site root (not [assets/images/]) so browsers find it. *)
let copy_favicon = Action.copy_file ~into:www Path.(assets / "favicon.svg")

let create_robots ~site =
  let robots_path = Path.(www / "robots.txt") in
  let body =
    Printf.sprintf "User-agent: *\nAllow: /\n\nSitemap: %s/sitemap.xml\n"
      (Site.url site)
  in
  let pipeline =
    let open Task in
    let+ () = track_binary and+ () = track_site in
    body
  in
  Action.Static.write_file robots_path pipeline

(* The article paths are absolute under [/articles/]; the schema requires a
   full URL, so we prefix them with the site origin. *)
let create_sitemap ~site =
  let sitemap_path = Path.(www / "sitemap.xml") in
  let url loc =
    Printf.sprintf "  <url><loc>%s%s</loc></url>" (Site.url site) loc
  in
  let static_urls = List.map url [ "/"; "/blog.html"; "/cv.html" ] in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ () = track_site
    and+ articles = fetch_articles in
    let article_urls =
      List.map (fun (path, _article) -> url (Path.to_string path)) articles
    in
    String.concat "\n"
      ([
         {|<?xml version="1.0" encoding="UTF-8"?>|};
         {|<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">|};
       ]
      @ static_urls @ article_urls @ [ "</urlset>" ])
  in
  Action.Static.write_file sitemap_path pipeline

let create_css =
  let css_path = Path.(www / "style.css") in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ content =
      Pipeline.pipe_files ~separator:"\n"
        Path.[ css / "reset.css"; css / "style.css" ]
    in
    content
  in
  Action.Static.write_file css_path pipeline

(* -------------------------------------------------------------------------- *)
(* Program                                                                    *)
(* -------------------------------------------------------------------------- *)

let program () =
  let open Eff in
  let* site = read_site () in
  let cache = Path.(www / ".cache") in
  Action.restore_cache cache >>= copy_images >>= copy_cname >>= copy_favicon
  >>= create_css >>= create_pages ~site >>= create_articles ~site
  >>= create_index ~site >>= create_blog ~site >>= create_cv ~site
  >>= create_robots ~site >>= create_sitemap ~site >>= create_feed ~site
  >>= Action.store_cache cache

let () =
  match Sys.argv.(1) with
  | "server" -> Yocaml_unix.serve ~level:`Info ~target:www ~port:8000 program
  | _ | (exception _) -> Yocaml_unix.run ~level:`Debug program
