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

## License

[MIT](LICENSE) — Benjamin Thuillier
