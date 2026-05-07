(** Site-wide configuration, mirroring the YAML record stored in
    [content/site.yml]. Exposed under the [site.*] namespace in every
    template, both in HTML templates and in markdown bodies (which are
    pre-rendered with Jingoo). *)

open Yocaml

type t

include Required.DATA_READABLE with type t := t
include Required.DATA_INJECTABLE with type t := t

(** [to_data s] is the [Data.t] representation of [s] — the same record
    shape templates see as [{{ site.* }}]. Useful for nesting [Site] inside
    a larger record like [With_site] does. *)
val to_data : t -> Data.t

(** [url s] — the canonical site origin (e.g. [https://gilwath.com]). Exposed
    so build actions (sitemap, robots.txt) can prefix relative paths without
    going through [to_data]. *)
val url : t -> string
