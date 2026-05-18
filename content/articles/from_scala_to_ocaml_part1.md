---
title: "Discovering OCaml as a Scala Developer Part 1: The Journey Begins"
synopsis: As a Scala developer, I will document my journey of learning OCaml and how it compares to Scala
date: 2026-05-30
---

## Introduction

Thanks to @xvw for introducing me to OCaml, and because this blog use an OCaml static site generator name YOCaml, I thought that trying to learn more about OCaml will be a good idea, and also a good way to share my experience with other people that want to learn OCaml.

In this first part, I will talk briefly about how to built a project with the two languages, but firstly let's talk about the two languages and their ecosystem, it will mostly paraphrasing their respective website and also their wikipedia page.

## Scala

Scala is a general-purpose programming language that supports both object-oriented and functional programming paradigms. At start it was designed to kind of be a better Java, but now it has evolved to be a language that can be used for a wide range of applications, even if the main target is the JVM, and Scala is defacto compatible with Java and Java libraries, scala can also target Javascript with Scala.js and native code using LLVM with Scala Native. Scala is known for it's powerful type system and the creators of scala take a lot of inspiration from Haskell but also from other languages like OCaml. We are currently at Scala 3, which is a major release that brings a lot of new features and improvements to the language, but also a new syntax that is more concise and easier to read.

## OCaml

OCaml is a general-purpose programming language that supports functional, imperative, and object-oriented programming paradigms. It is a statically typed language with type inference, which means that the compiler can automatically deduce the types of expressions without requiring explicit type annotations. OCaml is known for its powerful type system, which includes features such as algebraic data types, pattern matching, and higher-order functions. OCaml is also known for its performance, as it compiles to native code and has a garbage collector that can be tuned for low-latency applications. OCaml has a strong ecosystem of libraries and tools, including the OPAM package manager and the Dune build system.

## Build system and package manager

Both Scala and OCaml have their own build systems and package managers. On the Scala side, several build tools coexist: sbt, mill, gradle, maven, and also scala-cli, which has been integrated into the language since a minor version of Scala 3. In OCaml, the package manager and the build system are clearly separated: OPAM handles dependencies, while Dune takes care of building. OPAM also lets you easily manage your OCaml versions alongside your dependencies, whereas in a Scala project you typically need a separate tool like SDKMAN to manage your Java version, with dependencies being handled by the build system: which most of the time delegates to coursier under the hood.

```
     SCALA                              OCAML
     ─────                              ─────

┌──────────┐                      ┌──────────┐
│  SDKMAN  │ (JVM versions)       │          │
└──────────┘                      │          │
┌──────────┐                      │   OPAM   │ (everything:
│ coursier │ (deps resolution)    │          │  versions +
└──────────┘                      │          │  deps +
┌──────────┐                      │          │  installation)
│   sbt    │ (build)              └──────────┘
└──────────┘                      ┌──────────┐
                                  │   Dune   │ (build)
                                  └──────────┘

3 tools, overlapping roles        2 tools, clean separation
sbt orchestrates everything       OPAM and Dune cooperate
                                  via generated .opam files
```

## Now creating a simple hellow world with both languages

in both languages, you can create a project with a simple command, for Scala you can use scala seed project with sbt like this
```bash
sbt new scala/scala3.g8
A template to demonstrate a minimal Scala 3 application

name [Scala 3 Project Template]: scala-play
```
and you will have a simple project made by sbt, with a sbt file that will look like this
```scala
val scala3Version = "3.8.3"

lazy val root = project
  .in(file("."))
  .settings(
    name := "scala-play",
    version := "0.1.0-SNAPSHOT",

    scalaVersion := scala3Version,

    libraryDependencies += "org.scalameta" %% "munit" % "1.3.0" % Test
  )
```
and a simple main located at `src/main/scala/Main.scala` file that will look like this 
```scala
@main def hello(): Unit =
  println("Hello world!")
  println(msg)

def msg = "I was compiled by Scala 3. :)"
```
and if you want to run it, you can simply run the command `sbt run` and you will see the output of the program.


and for OCAML, you can use dune to create a simple project like this, you can if you want use opam to fix which version of OCaml you want to use like this

```bash
opam switch create ocaml-5.4.0 5.4.0 // or if you already have it installed
opam switch ocaml-5.4.0 // switch to the version you want to use
eval $(opam env) // will set the environment variables for the version you just switched to
opam install dune // install dune if you don't have it already for the ocaml version you just switched to
```

and then you can create a simple dune project like this
```bash
dune init proj ocaml-play
```
and you will have a simple project made by dune, with a dune file that will look like this

```lisp
(lang dune 3.22)

(name ocaml-play)

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Author Name <author@example.com>")

(maintainers "Maintainer Name <maintainer@example.com>")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name ocaml-play)
 (synopsis "A short synopsis")
 (description "A longer description")
 (depends ocaml)
 (tags
  ("add topics" "to describe" your project)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
```
and a simple main located at `src/main.ml` file that will look like this
```ocaml
let () = print_endline "Hello, World!"
```
and if you want to run it, you can simply run the command `dune exec ./src/main.exe` and you will see the output of the program.


So now we have finished the introduction, the next part will be about how to create a simple/CRUD http api with some in memory data.