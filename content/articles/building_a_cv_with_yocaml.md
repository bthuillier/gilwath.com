---
title: Building a CV page with YOCaml
synopsis: A retrospective of how I turned a folder of markdown files into a CV page
date: 2026-05-06
---

## Yocaml

This blog is built with [YOCaml](https://github.com/xhtmlboi/yocaml), a static-site generator written in OCaml that one of his maintainer introduced me, thanks XVW for that. Yocaml unlike other static site generator doesn't force you in a proper workflow or structure, we can say that Yocaml is just a build system allowing you to create pipeline to build in our case a website, but if you want to have something similar to what jekyll or other static site generator you can just follow the tutorial that will allow you to build a blog easily with pages and articles.

but, because is my personal website, I think that having also a place where I can put my CV with all my experience will be a nice improvement and also a good exercice to try to learn more about yocaml and ocaml, so basically I reuse what I learned during the tutorial to build my resumé

## Modelling Experience

A resumé is a set of experience and skill that we want to display in a chronological order for the experience case, in this case on yocaml we can create our own Datastructure, for that we can say that an experience is composed of a role, a company, a start date, and optionally an end date (when the end date is missing, the experience is current). The natural OCaml type:

```ocaml
type t =
  { role : string
  ; company : string
  ; start_date : Archetype.Datetime.t
  ; end_date : Archetype.Datetime.t option
  }
```

The field types are intentional. `start_date` and `end_date` aren't strings — they're `Archetype.Datetime.t`, the same type YOCaml uses for article dates. This buys formatting ({% raw %}`{{ start.repr.date }}`{% endraw %}), comparison (so I can sort experiences chronologically), and validation (a malformed date in front matter fails the build, rather than rendering as garbage).

Validation lives in two places: a `validate` function for reading YAML, and a `normalize` function for exposing fields to templates.

```ocaml
let validate =
  let open Data.Validation in
  record (fun fields ->
    let+ role = required fields "role" string
    and+ company = required fields "company" string
    and+ start_date = required fields "start_date" Archetype.Datetime.validate
    and+ end_date = optional fields "end_date" Archetype.Datetime.validate in
    { role; company; start_date; end_date })
```

The `let+ … and+` syntax composes independent validations, each field is checked on its own, and YOCaml accumulates errors rather than bailing on the first failure. That's nicer than I expected: editing two unrelated fields in the same file gives me both errors at once.

`normalize` is the mirror image, it turns a `t` back into the key-value pairs templates iterate over. The interesting bit is the `has_end_date` boolean:

```ocaml
"has_end_date", bool (Option.is_some end_date);
```

Jingoo's truthiness on `null` is awkward, so I expose an explicit flag rather than asking the template to check `end_date` directly. The same trick exists in YOCaml's standard archetypes — `has_synopsis`, `has_tags` — and once you see it once, it becomes the natural way to surface optionality across a template boundary.

## The Cv archetype

A CV page is a regular `Page` (front matter, body, the usual) that also carries a list of experiences. Rather than extend `Experience.t` with an HTML body field, I pair each experience with its rendered body in a tuple:

```ocaml
type t =
  { page : Archetype.Page.t
  ; experiences : (Experience.t * string) list
  }
```

The split is deliberate. `Experience.t` describes what's in a markdown file — role, company, dates — and that definition has no business knowing about HTML. The rendered body is a build artifact: it only exists once a markdown-to-HTML pass has run. Keeping it outside the type means `Experience` stays pure data, and the library that holds it doesn't need to depend on `yocaml_markdown`.

`normalize` then has to surface both halves to the template:

```ocaml
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
```

Two things to notice. The body is glued onto the front of `Experience.normalize exp`, so from the template's point of view it's just another field — {% raw %}`{{ experience.body }}`{% endraw %} sits next to {% raw %}`{{ experience.role }}`{% endraw %} with no hint that one came from markdown and the other from YAML. And `has_experiences` is the same trick as `has_end_date` from the previous section: an explicit boolean rather than asking the template to introspect a list.

## Fetching the experiences

`Yocaml.Pipeline.fetch` walks a folder, reads each file, and returns a list of whatever the per-file callback produces. Sorting most-recent-first is straightforward:

```ocaml
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
```

Two things worth pointing out. First, the body conversion (`Yocaml_markdown.from_string_to_html`) happens inside the fetch callback — once per file, not once per render. Second, the comparator is negated (`~-`) to flip the default ascending order. Most recent first reads naturally on a CV.

## The build action

`create_cv` mirrors `create_index` from the default scaffold — read a template chain, read site metadata, fetch experiences, read `cv.md`, glue them together with a small functor:

```ocaml
let create_cv =
  let module Bundle = With_site (struct
    type t = Cv.t
    let normalize = Cv.normalize
  end) in
  ...
```

The inline module is a one-line shim. `With_site` is a functor that takes a `DATA_INJECTABLE` and returns one wrapping a `(t * Site.t)` pair, so the template can reference {% raw %}`{{ site.author }}` alongside `{{ experiences }}`{% endraw %}. `Cv` already has a `normalize`; the shim just promotes it into the right interface.

## Splitting bin and lib

By this point `bin/blog.ml` had crossed 400 lines and was carrying everything: `Site`, `Experience`, `Cv`, the validators, the normalizers, and the build pipeline. That's too much for one file, and most of it isn't really about *building this site* — it's about describing the data that lives in it. So I moved the data modules into a `lib/` folder and left `bin/blog.ml` with only what actually drives the build.

```
lib/
├── dune              ← (library (name blog_core) (libraries yocaml))
├── site.ml + .mli
├── experience.ml + .mli
└── cv.ml + .mli

bin/
├── dune              ← (executable (name blog) (libraries blog_core yocaml_yaml yocaml_markdown))
└── blog.ml           ← paths, fetch_experiences, create_cv, the program entry point
```

Three guidelines I followed when deciding what crossed the boundary:

- **Paths stay in `bin`.** They describe this site's filesystem layout (`content/articles`, `content/experiences`, `_site`), which isn't reusable.
- **The `.mli` files keep `t` abstract** wherever possible. `Experience.t` was the one exception — `bin` reads `start_date` to sort, so the signature exposes a `start_date : t -> Archetype.Datetime.t` accessor rather than the whole record. That way I can add a `team` or `company_logo` field later without breaking callers.
- **The library only depends on `yocaml`**, not `yocaml_yaml` or `yocaml_markdown`. Validation and normalization are pure data — no I/O, no parsing of any specific format. The `bin` layer chooses how to feed YAML into the validator and how to render markdown into HTML.

The result is a `blog.ml` that reads top-to-bottom as "here is how this site is built": the paths, the fetch tasks, the `create_*` actions, the `main`. Everything that answers "what is an experience?" or "what is a CV?" lives next door, in modules I could lift wholesale into another YOCaml project.

## What's next

The experience was smoother than I expected, but I have to be honest: I leaned heavily on existing YOCaml code and on an LLM to bridge the gaps in my OCaml. The result works and I understand why, but I couldn't yet read an unfamiliar OCaml file fluently. Before adding more features, I want to sit down with the syntax — functors, `let+`/`and+`, module signatures — until it reads as naturally as the TypeScript I write daily.

The other obvious next step is deployment. The site still only builds locally; a small GitHub Actions workflow running `dune build` and pushing `_site` to `gh-pages` would make adding a new experience a true one-file commit.

