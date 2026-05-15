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
