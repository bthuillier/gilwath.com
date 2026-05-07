# blog

My first personal blog using [YOCaml](https://github.com/xvw/yocaml), an OCaml static site generator.

## Requirements

- OCaml `>= 5.3.0`
- [opam](https://opam.ocaml.org/)
- [dune](https://dune.build/) `>= 3.20`

## Setup

Create a local switch and install dependencies:

```sh
opam switch create . 5.3.0 --deps-only --with-dev-setup
eval $(opam env)
```

## Build

```sh
dune build
```

## Run

```sh
dune exec blog
```

## Project layout

```
.
├── assets/
│   ├── css/         # stylesheets
│   ├── images/      # static images
│   └── templates/   # page templates
├── content/
│   ├── articles/    # blog posts
│   └── pages/       # standalone pages
├── bin/
│   ├── blog.ml      # entry point
│   └── dune
├── blog.opam
└── dune-project
```

## Refreshing the OG image

The social-preview image lives at `assets/images/og-default.png` and is
hand-rendered from `assets/og-default.svg`. To regenerate it after editing the
SVG (requires `librsvg`):

```sh
brew install librsvg   # one-time
rsvg-convert -w 1200 -h 630 assets/og-default.svg -o assets/images/og-default.png
```

CI just copies the committed PNG; the conversion is a local step.

## License

[MIT](LICENSE) — Benjamin Thuillier
