open Yocaml

type t

val make
  :  ?source_folder:Path.t
  -> ?target_folder:Path.t
  -> ?server_folder:Path.t
  -> unit
  -> t

module Source : sig
  val source_root : t -> Path.t

  (* Assets *)
  val assets : t -> Path.t
  val images : t -> Path.t
  val css : t -> Path.t
  val templates : t -> Path.t
  val resolve_templates : t -> string list -> Path.t list
  val og_article_template : t -> Path.t

  (* Content *)
  val content : t -> Path.t
  val pages : t -> Path.t
  val articles : t -> Path.t
  val experiences : t -> Path.t
  val education : t -> Path.t
  val index : t -> Path.t
  val blog : t -> Path.t
  val cv : t -> Path.t
  val site : t -> Path.t
end

module Target : sig
  val target_root : t -> Path.t
  val cache : t -> Path.t
  val images : t -> Path.t
  val og_dir : t -> Path.t
  val article_og_svg : t -> Path.t -> Path.t
  val article_og_png : t -> Path.t -> Path.t
  val article_og_url : Path.t -> string
  val article_url : Path.t -> string
  val style_css : t -> Path.t
  val page : t -> Path.t -> Path.t
  val article : t -> Path.t -> Path.t
  val index : t -> Path.t
  val cv : t -> Path.t
  val blog : t -> Path.t
  val atom : t -> Path.t
end

module Server : sig
  val server_root : t -> Path.t
  val from_target : t -> Path.t -> Path.t
end
