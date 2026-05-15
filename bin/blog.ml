open Yocaml

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let with_ext exts file =
  List.exists (fun ext -> Path.has_extension ext file) exts
;;

let is_markdown = with_ext [ "md"; "markdown"; "mdown" ]

let track_binary =
  Sys.executable_name |> Yocaml.Path.from_string |> Pipeline.track_file
;;

let compute_link source =
  let into = Path.abs [ "articles" ] in
  source |> Path.move ~into |> Path.change_extension "html"
;;

(* -------------------------------------------------------------------------- *)
(* Domain modules                                                             *)
(* -------------------------------------------------------------------------- *)

module Site = Blog_core.Site
module Experience = Blog_core.Experience
module Education = Blog_core.Education
module Cv = Blog_core.Cv
module Reading_time = Blog_core.Reading_time
module Resolver = Blog_core.Resolver

module Feed = struct
  let owner site =
    Yocaml_syndication.Person.make
      ~uri:(Site.url site)
      ~email:(Site.email site)
      (Site.author site)
  ;;

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
    Atom.entry
      ~links
      ~categories
      ?summary
      ~updated
      ~id:content_url
      ~title:(Atom.text title)
      ()
  ;;

  let make ~site entries =
    let open Yocaml_syndication in
    Atom.feed
      ~title:(Atom.text (Site.name site))
      ~subtitle:(Atom.text (Site.description site))
      ~updated:(Atom.updated_from_entries ())
      ~authors:(authors site)
      ~id:(Site.url site)
      (article_to_entry ~site)
      entries
  ;;
end

(* Not a top-level [let]: [_ Eff.t] performs its effects on construction
   (via [let*]), so we'd raise [Effect.Unhandled] before the runtime
   handler is installed. *)
let read_site resolver () =
  Eff.read_file_as_metadata
    (module Yocaml_yaml)
    (module Site)
    ~on:`Source
    (Resolver.Source.site resolver)
;;

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

type document_kind =
  | Page
  | Article

module type ARCHETYPE = sig
  include Yocaml.Required.DATA_INJECTABLE
  include Yocaml.Required.DATA_READABLE with type t := t
end

(* Run *before* markdown→HTML so [{{ site.* }}] expands into raw markdown
   (e.g. into link targets). [strict:false] tolerates unknown variables. *)
let render_md ~metadata content =
  let parameters =
    metadata |> List.map (fun (k, v) -> k, Yocaml_jingoo.from v)
  in
  Yocaml_jingoo.render ~strict:false parameters content
;;

(* The value is read once at program start; this keeps it in the dep set
   so editing [site.yml] reruns every page. *)
let track_site resolver = Pipeline.track_file (Resolver.Source.site resolver)

(* The dep prelude shared by every site-aware pipeline. *)
let track_deps resolver =
  let open Task in
  let+ () = track_binary
  and+ () = track_site resolver in
  ()
;;

(* Fetch every markdown file under [folder] as an [Entry.t], parsed with
   [Entry], sorted most-recent-first by [start_date]. *)
let fetch_dated
      (type a)
      (module Entry : Required.DATA_READABLE with type t = a)
      ~start_date
      folder
  =
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
           (module Entry)
           ~on:`Source
           file
       in
       metadata, Yocaml_markdown.from_string_to_html content)
    folder
  >>| List.sort (fun (a, _) (b, _) ->
    ~-(Archetype.Datetime.compare (start_date a) (start_date b)))
;;

(* (Experience.t * html body) list, sorted most-recent-first. *)
let fetch_experiences resolver =
  fetch_dated
    (module Experience)
    ~start_date:Experience.start_date
    (Resolver.Source.experiences resolver)
;;

(* (Education.t * html body) list, sorted most-recent-first. *)
let fetch_education resolver =
  fetch_dated
    (module Education)
    ~start_date:Education.start_date
    (Resolver.Source.education resolver)
;;

let document_sources resolver = function
  | Page -> Resolver.Source.pages resolver
  | Article -> Resolver.Source.articles resolver
;;

let document_path resolver document_kind path =
  let into =
    match document_kind with
    | Page -> Resolver.Target.page resolver
    | Article -> Resolver.Target.article resolver
  in
  path |> into
;;

let get_specific_template resolver document_kind =
  let templates = Resolver.Source.templates resolver in
  let file =
    match document_kind with
    | Page -> "page.html"
    | Article -> "article.html"
  in
  Path.(templates / file)
;;

let document_archetype : document_kind -> (module ARCHETYPE) = function
  | Page -> (module Archetype.Page)
  | Article -> (module Archetype.Article)
;;

(* -------------------------------------------------------------------------- *)
(* Articles index                                                             *)
(* -------------------------------------------------------------------------- *)

let fetch_articles resolver =
  Archetype.Articles.fetch
    ~where:is_markdown
    ~compute_link
    (module Yocaml_yaml)
    (Resolver.Source.articles resolver)
;;

(* -------------------------------------------------------------------------- *)
(* Build actions                                                              *)
(* -------------------------------------------------------------------------- *)

(* Estimated on the raw markdown, before rendering. *)
let document_extras document_kind content =
  match document_kind with
  | Article -> Data.[ "reading_time", int (Reading_time.estimate content) ]
  | Page -> []
;;

(* The shared tail of every page builder: pre-render markdown, convert to
   HTML, apply the template chain. *)
let render_through templates fields content =
  content
  |> render_md ~metadata:fields
  |> Yocaml_markdown.from_string_to_html
  |> templates
       (module Fields : Required.DATA_INJECTABLE
         with type t = (string * Data.t) list)
       ~metadata:fields
;;

let create_feed resolver ~site =
  let pipeline =
    let open Task in
    let+ () = track_deps resolver
    and+ articles = fetch_articles resolver in
    articles |> Feed.make ~site |> Yocaml_syndication.Xml.to_string
  in
  Action.Static.write_file (Resolver.Target.atom resolver) pipeline
;;

let create_document resolver ~site document_kind source =
  let module Archetype = (val document_archetype document_kind) in
  let target = document_path resolver document_kind source
  and pipeline =
    let open Task in
    let+ () = track_deps resolver
    and+ templates =
      Yocaml_jingoo.read_templates
        Path.
          [ get_specific_template resolver document_kind
          ; Resolver.Source.templates resolver / "layout.html"
          ]
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata (module Archetype) source
    in
    let extras = document_extras document_kind content in
    let fields = inject_site site (extras @ Archetype.normalize metadata) in
    render_through templates fields content
  in
  Action.Static.write_file target pipeline
;;

let create_documents resolver ~site document_kind =
  let sources = document_sources resolver document_kind in
  Batch.iter_files
    ~where:is_markdown
    sources
    (create_document resolver ~site document_kind)
;;

let create_pages resolver ~site = create_documents resolver ~site Page
let create_articles resolver ~site = create_documents resolver ~site Article

(* Shared by [/] and [/blog.html]: a [Page] enriched with the article list. *)
let create_listing
      resolver
      ~site
      ~source
      ~into:dest_dir
      ~templates:template_chain
  =
  let listing_path =
    source |> Path.move ~into:dest_dir |> Path.change_extension "html"
  in
  let pipeline =
    let open Task in
    let+ () = track_deps resolver
    and+ templates = Yocaml_jingoo.read_templates template_chain
    and+ articles = fetch_articles resolver
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
;;

let create_index resolver ~site =
  create_listing
    resolver
    ~site
    ~source:(Resolver.Source.index resolver)
    ~into:(Resolver.Target.target_root resolver)
    ~templates:
      (Resolver.Source.resolve_templates
         resolver
         [ "index.html"; "page.html"; "layout.html" ])
;;

let create_blog resolver ~site =
  create_listing
    resolver
    ~site
    ~source:(Resolver.Source.blog resolver)
    ~into:(Resolver.Target.target_root resolver)
    ~templates:
      (Resolver.Source.resolve_templates
         resolver
         [ "blog.html"; "layout.html" ])
;;

let create_cv resolver ~site =
  let source = Resolver.Source.cv resolver in
  let cv_path = Resolver.Target.cv resolver in
  let pipeline =
    let open Task in
    let+ () = track_deps resolver
    and+ templates =
      Yocaml_jingoo.read_templates
        (Resolver.Source.resolve_templates
           resolver
           [ "cv.html"; "layout.html" ])
    and+ experiences = fetch_experiences resolver
    and+ education = fetch_education resolver
    and+ metadata, content =
      Yocaml_yaml.Pipeline.read_file_with_metadata
        (module Archetype.Page)
        source
    in
    let cv = Cv.with_page ~page:metadata ~experiences ~education in
    let fields = inject_site site (Cv.normalize cv) in
    render_through templates fields content
  in
  Action.Static.write_file cv_path pipeline
;;

let copy_images resolver =
  let images_path = Resolver.Target.images resolver
  and where = with_ext [ "svg"; "png"; "jpg"; "gif" ] in
  Batch.iter_files
    ~where
    (Resolver.Source.images resolver)
    (Action.copy_file ~into:images_path)
;;

(* The OG preview is hand-authored in [assets/og-default.svg]; we rasterize
   it through [rsvg-convert] (must be on PATH). [Cmd.w] watches the SVG so
   the cache invalidates whenever it changes; the [target] is filled in by
   [Action.exec_cmd], like in the official [d2] example. *)
let og_svg resolver = Path.(Resolver.Source.assets resolver / "og-default.svg")

let invoke_rsvg resolver target =
  let open Cmd in
  make
    "rsvg-convert"
    [ param ~prefix:"-" "w" (i 1200)
    ; param ~prefix:"-" "h" (i 630)
    ; arg (w (og_svg resolver))
    ; param ~prefix:"-" "o" target
    ]
;;

let render_og_image resolver =
  Action.exec_cmd
    (invoke_rsvg resolver)
    Path.(Resolver.Target.images resolver / "og-default.png")
;;

let copy_asset_to_root name resolver =
  Action.copy_file
    ~into:(Resolver.Target.target_root resolver)
    Path.(Resolver.Source.assets resolver / name)
;;

(* GitHub Pages reads [_www/CNAME] to bind the site to gilwath.com. *)
let copy_cname = copy_asset_to_root "CNAME"

(* Lives at the site root (not [assets/images/]) so browsers find it. *)
let copy_favicon = copy_asset_to_root "favicon.svg"

let create_robots resolver ~site =
  let robots_path =
    Path.(Resolver.Target.target_root resolver / "robots.txt")
  in
  let body =
    Printf.sprintf
      "User-agent: *\nAllow: /\n\nSitemap: %s/sitemap.xml\n"
      (Site.url site)
  in
  let pipeline =
    let open Task in
    let+ () = track_deps resolver in
    body
  in
  Action.Static.write_file robots_path pipeline
;;

(* The article paths are absolute under [/articles/]; the schema requires a
   full URL, so we prefix them with the site origin. *)
let create_sitemap resolver ~site =
  let sitemap_path =
    Path.(Resolver.Target.target_root resolver / "sitemap.xml")
  in
  let url loc =
    Printf.sprintf "  <url><loc>%s%s</loc></url>" (Site.url site) loc
  in
  let static_urls = List.map url [ "/"; "/blog.html"; "/cv.html" ] in
  let pipeline =
    let open Task in
    let+ () = track_deps resolver
    and+ articles = fetch_articles resolver in
    let article_urls =
      List.map (fun (path, _article) -> url (Path.to_string path)) articles
    in
    String.concat
      "\n"
      ([ {|<?xml version="1.0" encoding="UTF-8"?>|}
       ; {|<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">|}
       ]
       @ static_urls
       @ article_urls
       @ [ "</urlset>" ])
  in
  Action.Static.write_file sitemap_path pipeline
;;

let create_css resolver =
  let css_path = Resolver.Target.style_css resolver in
  let css = Resolver.Source.css resolver in
  let pipeline =
    let open Task in
    let+ () = track_binary
    and+ content =
      Pipeline.pipe_files
        ~separator:"\n"
        Path.[ css / "reset.css"; css / "style.css" ]
    in
    content
  in
  Action.Static.write_file css_path pipeline
;;

(* -------------------------------------------------------------------------- *)
(* Program                                                                    *)
(* -------------------------------------------------------------------------- *)

let program resolver () =
  let open Eff in
  let* site = read_site resolver () in
  let cache = Resolver.Target.cache resolver in
  Action.restore_cache cache
  >>= copy_images resolver
  >>= copy_cname resolver
  >>= copy_favicon resolver
  >>= render_og_image resolver
  >>= create_css resolver
  >>= create_pages resolver ~site
  >>= create_articles resolver ~site
  >>= create_index resolver ~site
  >>= create_blog resolver ~site
  >>= create_cv resolver ~site
  >>= create_robots resolver ~site
  >>= create_sitemap resolver ~site
  >>= create_feed resolver ~site
  >>= Action.store_cache cache
;;

let () =
  let resolver = Resolver.make () in
  match Sys.argv.(1) with
  | "server" ->
    Yocaml_unix.serve
      ~level:`Info
      ~target:(Resolver.Target.target_root resolver)
      ~port:8000
      (program resolver)
  | _ | (exception _) -> Yocaml_unix.run ~level:`Debug (program resolver)
;;
