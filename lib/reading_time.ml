(** Approximate reading time for a piece of prose, in minutes. The estimate
    is the standard word-count divided by an average reading speed; we round
    up so a 30-second read still says ["1 min"] rather than ["0 min"]. *)

(* 200 wpm sits in the middle of the commonly-cited 200–250 range for adult
   silent reading of prose. Technical writing skews slower (closer to 150),
   so this is mildly optimistic — fine for a back-of-the-envelope hint. *)
let words_per_minute = 200

(* Counts whitespace-separated tokens. Markdown syntax (fences, link targets,
   front-matter that snuck through) inflates the count slightly, but for the
   length of post we publish here the drift is well under a minute. *)
let count_words s =
  let n = String.length s in
  let rec loop i in_word acc =
    if i >= n then if in_word then acc + 1 else acc
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' ->
        loop (i + 1) false (if in_word then acc + 1 else acc)
      | _ -> loop (i + 1) true acc
  in
  loop 0 false 0

let estimate content =
  let words = count_words content in
  max 1 ((words + words_per_minute - 1) / words_per_minute)
