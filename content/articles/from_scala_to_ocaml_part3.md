---
title: "Discovering OCaml as a Scala Developer Part 3: Serving data with SQL Database (Postgresql)"
synopsis: Using a SQL Database to serve the data for our CRUD API
date: 2026-08-27
tags:
  - OCaml
  - Scala
  - Functional Programming
  - HTTP API
  - CRUD
  - SQL
---

## Introduction

In the [previous part](/articles/from_scala_to_ocaml_part2.html), we compared how we build a CRUD HTTP API with Scala and OCaml, and saw how close the two languages could be. That was not a surprise, since Scala took a lot of inspiration from OCaml in its design. We also discovered that the OCaml ecosystem for building HTTP APIs is a little less mature. There are many reasons for this, but I think it is mostly because OCaml doesn't benefit from a wider ecosystem the way Scala benefits from the Java ecosystem.

To get closer to what a service could look like in a real use case, we will now explore how OCaml can interact with a SQL database and how it compares against Scala. We will use PostgreSQL for that, but we could use any other SQL database for our example, since we won't rely on any PostgreSQL-specific feature.

## SQL Schema

To keep things simple, here is how the SQL table for our `tasks` will look like:

```sql
CREATE TABLE tasks (
  id          UUID PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL,
  state       TEXT NOT NULL CHECK (state IN ('Waiting', 'InProgress', 'Done'))
);
```

It's basically a one-to-one mapping of the `Task` struct we defined in part 2. The `id` field becomes our primary key, while `name` and `description` stay as `TEXT NOT NULL` because we defined them as non-optional `string`. For the `state`, we also use a `TEXT NOT NULL`, but with a `CHECK (state IN ('Waiting', 'InProgress', 'Done'))` constraint instead of an `ENUM`. PostgreSQL enums are harder to change over time: you can add a value, but you can't remove, rename or reorder existing ones without recreating the type, whereas a `CHECK` constraint is just a one-line edit.

## Choosing the libraries

On the Scala side, the ecosystem for SQL libraries is wide, and it could be even wider if we take a look at the whole JVM ecosystem, but in our case we will focus on libraries that target the Scala language:
- [Skunk](https://typelevel.org/skunk/): a purely functional library powered by cats-effect and fs2, and because it doesn't rely on JDBC it targets only PostgreSQL with its own driver implementation
- [Kyo-SQL](https://github.com/getkyo/kyo/blob/main/kyo-sql/README.md): same as Skunk but instead of cats-effect it is based on the Kyo ecosystem
- [ZIO-Quill](https://zio.dev/zio-quill/): a compile-time query generation library where queries look like Scala collection code, queries are checked and generated at compile time, it is based on the ZIO ecosystem
- [Slick](https://scala-slick.org/): one of the historical libraries to access SQL databases, you create queries with a collection-like API against table definitions, there is also support to write raw SQL queries instead
- [Doobie](https://typelevel.org/doobie/): a purely functional library powered by cats-effect, it is not an ORM of any sort, it provides a functional way to interact with JDBC and allows users to write SQL queries in an efficient way

For this example I will go with Doobie: firstly it is maybe just a matter of taste, but when I want to access a SQL database I prefer to write SQL queries directly, also because we are already in the cats-effect ecosystem Doobie seems to be a natural choice. I discarded Skunk because it is Postgres only, but the two libraries are really close since they share the same author. It doesn't mean that the other choices are necessarily bad choices, but they fit our example less.

On the OCaml side, the list is shorter, but there are still several options:
- [Caqti](https://github.com/paurkedal/ocaml-caqti): the de facto standard library to access SQL databases in OCaml. It is backend-agnostic (drivers exist for PostgreSQL, MySQL/MariaDB and SQLite) and provides a typed interface to write SQL queries. It also supports several concurrency models: blocking, Lwt, Async, Eio and, more recently, Miou
- [postgresql-ocaml](https://github.com/mmottl/postgresql-ocaml): low-level bindings to the libpq C library, so it is Postgres only and quite close to the wire
- [pgx](https://github.com/arenadotio/pgx): a pure OCaml PostgreSQL client that doesn't rely on C bindings, with Lwt, Async and Unix variants
- [petrol](https://github.com/gopiandcode/petrol): a high-level query builder built on top of Caqti, where queries are written with typed combinators instead of raw SQL
- [ppx_rapper](https://github.com/roddyyaga/ppx_rapper): a syntax extension on top of Caqti that lets you write raw SQL queries with typed parameters, close in spirit to Doobie's `sql` interpolator

For the OCaml side I will go with Caqti: it is the most widely used option, and since we used Vif in part 2, which is built on top of the Miou scheduler, the recently added Miou support in Caqti (`caqti-miou`) makes it a natural fit. Vif even ships examples using Caqti. 