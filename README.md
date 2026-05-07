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

## OG image

The social-preview image is rasterized from `assets/og-default.svg` to
`_www/images/og-default.png` at build time via `rsvg-convert` (see
`bin/blog.ml`). The Yocaml cache only re-runs the conversion when the SVG
changes.

`librsvg` must be on `PATH`:

```sh
brew install librsvg          # macOS
apt-get install librsvg2-bin  # Debian/Ubuntu (CI)
```

## License

[MIT](LICENSE) — Benjamin Thuillier
