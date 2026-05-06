---
title: Building a CV page with YOCaml
synopsis: A retrospective of how I turned a folder of markdown files into a CV page — and the dead ends I hit along the way.
date: 2026-05-06
---

This blog is built with [YOCaml](https://github.com/xhtmlboi/yocaml), a static-site generator written in OCaml. The default setup gives you pages and articles. I wanted a third thing: a **CV page** that lists my professional experience, with each role sourced from its own markdown file so I can edit history without touching HTML.

This is the path I took, including a couple of detours I had to back out of. If you're building something similar, hopefully my dead ends save you a few minutes.

## What I started with

Out of the box, my generator handled two kinds of documents. They share a common pipeline: read a markdown file with YAML front matter, validate the front matter against an *archetype* (YOCaml's word for a metadata schema), render the body to HTML, and pour everything into a Jingoo template.

```ocaml
type document_kind =
  | Page
  | Article
```

A new constructor here means a new folder of markdown sources, a new template, and a new output path. My first instinct was to add `| Experience` and call it a day.

That instinct was wrong.

## First detour: experience-as-document

Adding `| Experience` produced a page per experience — `/experiences/conduktor.html`, `/experiences/talend.html`, and so on. Technically it worked. But each rendered page was a single experience floating in the layout, with no way to see them as a list. To get a CV out of it, I'd have needed a *second* mechanism — fetching the experiences and presenting them somewhere — which is exactly what I was trying to avoid.

The right model isn't *"experiences are documents"*. It's *"experiences are data, and the CV is the document"*. The CV has a body (some prose introducing me) and it carries a list of experiences. One page, one output, one template.

Once I framed it that way, the structure clicked into place. YOCaml's standard library already has the same shape: `Yocaml.Archetype.Articles` is a `Page` carrying a list of `Article`s, used to render the blog index. I just needed the same pattern for `Experience`s.

## Modelling Experience

An experience has a role, a company, a start date, and optionally an end date (when the end date is missing, the experience is current). The natural OCaml type:

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

The `let+ … and+` syntax composes independent validations — each field is checked on its own, and YOCaml accumulates errors rather than bailing on the first failure. That's nicer than I expected: editing two unrelated fields in the same file gives me both errors at once.

`normalize` is the mirror image — it turns a `t` back into the key-value pairs templates iterate over. The interesting bit is the `has_end_date` boolean:

```ocaml
"has_end_date", bool (Option.is_some end_date);
```

Jingoo's truthiness on `null` is awkward, so I expose an explicit flag rather than asking the template to check `end_date` directly. The same trick exists in YOCaml's standard archetypes — `has_synopsis`, `has_tags` — and once you see it once, it becomes the natural way to surface optionality across a template boundary.

## The Cv archetype

`Cv` is just a `Page` that also carries experiences. Each experience travels alongside its rendered HTML body — paired in a tuple rather than baked into the type:

```ocaml
type t =
  { page : Archetype.Page.t
  ; experiences : (Experience.t * string) list
  }
```

This pairing pattern was my **second detour**. My first attempt added a `body : string` field directly to `Experience.t`, initialized to `""` in `validate` and patched in later by the fetcher. It worked, but it lied: the type promised a body that the validator never produced. Rendering details (HTML output) had infected the data type.

The fix was looking at how `Yocaml.Archetype.Articles` does it. `Articles` doesn't store a URL on `Article.t`; it pairs `(Path.t, Article.t)` and merges the URL in at normalization time. Same pattern works for the experience body.

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

The body shows up in the template as {% raw %}`{{ experience.body }}`{% endraw %} — invisible to the OCaml type system but present where it matters.

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

By this point my `bin/blog.ml` had grown to about 400 lines, with `Site`, `Experience`, `Cv`, and the build pipeline all in the same file. I extracted the three data modules into a `lib/` folder.

```
lib/
├── dune              ← (library (name blog_core) (libraries yocaml))
├── site.ml + .mli
├── experience.ml + .mli
└── cv.ml + .mli
```

Three guidelines I followed:

- **Paths stay in `bin`.** They describe this site's filesystem layout, which isn't reusable.
- **The `.mli` files keep `t` abstract** wherever possible. `Experience.t` was the one exception — `bin` reads `start_date` to sort, so the `.mli` exposes a `start_date : t -> Archetype.Datetime.t` accessor rather than the whole record. That way I can add a `team` or `company_logo` field later without breaking callers.
- **The library only depends on `yocaml`**, not `yocaml_yaml` or `yocaml_markdown`. Validation and normalization are pure data — no I/O, no parsing of any specific format. The bin layer chooses how to feed YAML into the validator.

## What's left

What I have now is a CV page driven by a folder of markdown files. Adding a new role is one new file. Re-ordering them is automatic. The build refuses to ship if a date is malformed.

What I don't have yet, and might revisit:

- **Per-experience pages.** Right now each experience renders only inline on the CV. The same files could feed both views — same archetype, second build action.
- **A `team` and `company_logo` field.** The data exists in some of my markdown files but isn't captured by `Experience.t`, so it's silently dropped. A small extension when I want to surface it.
- **Education and skills sections.** Currently hardcoded prose in `cv.md`. If I find the structure useful enough to template, the same pattern applies — define an archetype, fetch a folder, normalize a list.

The shape of the system makes those changes obvious. That's the part I appreciated most about YOCaml: it's not a framework with opinions, it's a library with primitives. You build the structure you want, one `Action` at a time.
