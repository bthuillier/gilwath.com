(** Approximate reading time for a piece of prose, in minutes. *)

val estimate : string -> int
(** [estimate content] — number of minutes it should take to read [content],
    rounded up and clamped to a minimum of [1]. Operates on raw text; pass the
    markdown body directly. *)
