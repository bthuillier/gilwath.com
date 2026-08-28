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
  state       TEXT NOT NULL CHECK (state IN ('Waiting', 'InProgress', 'Done')),
  project     TEXT NOT NULL CHECK (project ~ '^[A-Z]{3}$')
);

CREATE INDEX tasks_state_idx   ON tasks (state);
CREATE INDEX tasks_project_idx ON tasks (project);
```

<!-- TODO(prose): the sample code adds a `project` field (3 uppercase letters, e.g. 'ABC')
     that did not exist in part 2. It powers the ?state=/?project= list filters and gives
     us a reason to show dynamic queries later. Introduce it here. -->


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

## Connecting to the database

In Scala, we need to create a transactor that will act as our connection to the DB. In our case the transactor will be backed by a Hikari pool, which allows us to not have to manage the connection pool and delegate it to Hikari. All the configuration will be retrieved through environment variables. When we build the transactor we get the type `Resource[IO, Transactor[IO]]`: this is a special structure in cats-effect that allows us to access a resource with the acquire and release pattern, and because it's in the main method of the app and we use `useForever`, the pool will be created once and when the application ends, the resource will be closed/released.

```scala
import cats.effect.{IO, Resource}
import doobie.Transactor
import doobie.hikari.HikariTransactor

private def env(name: String, default: String): String =
  sys.env.getOrElse(name, default)

private val transactor: Resource[IO, Transactor[IO]] = {
  val host     = env("DB_HOST", "localhost")
  val port     = env("DB_PORT", "5432")
  val user     = env("DB_USER", "tasks")
  val password = env("DB_PASSWORD", "tasks")
  val database = env("DB_NAME", "tasks")
  val jdbcUrl  = s"jdbc:postgresql://$host:$port/$database"

  HikariTransactor.newHikariTransactor[IO](
    driverClassName = "org.postgresql.Driver",
    url = jdbcUrl,
    user = user,
    pass = password,
    connectEC = scala.concurrent.ExecutionContext.global
  )
}

def run: IO[Nothing] = {
  val server: Resource[IO, Unit] = for {
    xa <- transactor
    taskService = PostgresTaskService(xa)
    _ <- EmberServerBuilder.default[IO]
      .withHost(ipv4"0.0.0.0")
      .withPort(httpPort)
      .withHttpApp(TaskRouter.routes(taskService))
      .build
  } yield ()

  server.useForever
}
```

In OCaml, we need to create a pool of connections that will act as our access to the DB. In our case the pool is required because Vif runs each request as a concurrent Miou fiber sharing the same store, and a single Caqti connection is not safe for concurrent use. All the configuration will be retrieved through the same environment variables, and used to build a connection URI: the `pgx` scheme tells Caqti to use the pure OCaml driver we saw earlier. When we create the pool we have to provide a switch: this is the counterpart of cats-effect's `Resource`, but instead of encoding the acquire and release pattern in a type, it is encoded in a lexical scope, and everything attached to the switch is released when we leave the scope of `Switch.run`.

```ocaml
let uri_of_env () =
  let get name default = Option.value ~default (Sys.getenv_opt name) in
  let host = get "DB_HOST" "localhost" in
  let port = get "DB_PORT" "5432" in
  let user = get "DB_USER" "tasks" in
  let password = get "DB_PASSWORD" "tasks" in
  let database = get "DB_NAME" "tasks" in
  Uri.make ~scheme:"pgx" ~userinfo:(user ^ ":" ^ password)
    ~host ~port:(int_of_string port) ~path:("/" ^ database) ()

module Pool = Caqti_miou_unix.Pool

type t = (Caqti_miou.connection, Caqti_error.t) Pool.t

(* Create the pool. The switch keeps it alive for the app's lifetime. *)
let connect_pool ~sw () : t =
  match Caqti_miou_unix.connect_pool ~sw (uri_of_env ()) with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)
```

Because `Switch.run` wraps `Vif.run` in the main function of the app, the pool will be created once and stay alive for the application's lifetime, and when the server stops the connections will be closed/released.

```ocaml
let () =
  Miou_unix.run @@ fun () ->
  (* Switch.run provides a live switch that keeps the connection pool alive
     for the server's lifetime (released when Vif.run returns). *)
  Caqti_miou.Switch.run @@ fun sw ->
  let pool = Db.connect_pool ~sw () in
  let store = Store.of_postgres pool in
  Vif.run ~cfg routes store
```

## Mapping rows to the domain

Because we decided to encode the column `state` as plain **TEXT**, we have to build the mapping in our code from and to the database encoding.

In Doobie the solution is simple, we just have to define a `given` `Meta` for our type. A `Meta` is a typeclass that allows us to make the mapping: we start with `Meta[String]`, since that is how it's stored in the database, and call the method `tiemap`, which allows us to provide the two methods for the mapping, `String => Either[String, State]` and `State => String`. The from-DB method returns an `Either` to allow us to handle bad values, in our case an unknown state.

For the full row, Doobie relies on typeclass derivation: the `Read` typeclass describes how to read a row into a value, and `Read.derived` builds the instance for `Task` from the `Meta` of each of its fields. Doobie is also able to derive it automatically at each query site without this line, but explicit derivation is often the better practice: the instance is created once, and compile times and error messages stay under control.

```scala
// The `state` column is a plain TEXT column, so we map the Scala `State`
// enum to/from a String on top of the built-in Meta[String].
given Meta[State] =
  Meta[String].tiemap(s => State.fromString(s).toRight(s"unknown task state: $s"))(_.toString)

// Derive the row mapping for Task once here, instead of relying on doobie's
// automatic derivation at every query site.
given Read[Task] = Read.derived
```

In Caqti, there is a bit more work to do. The mapping is built with the `Row_type` module (aliased as `Rt` below): we call `Rt.custom`, which plays the same role as `tiemap`, we start from `Rt.string`, since that is how it's stored in the database, and we provide the two functions `~encode` and `~decode`, both returning a `result` to allow us to handle bad values. Note that we also have to define a mapping for the `id` column, because Caqti has no built-in type for UUIDs, whereas Doobie gets one from the JDBC driver.

The real difference with Scala shows up for the full row: what took a single `Read.derived` line in Scala has to be spelled out with `product` and one `proj` (projection) per field. Each `proj` pairs a column type with the accessor that reads the field, and the `intro` function rebuilds the record from the decoded columns. One last detail: these combinators come from `Caqti_template`, the new query API of Caqti, which is still marked as unstable, hence the `[@@@alert]` line to silence the warning.

```ocaml
(* Caqti_template is a preview API; silence its instability alert. *)
[@@@alert "-caqti_unstable"]

module Rt = Caqti_template.Row_type

let uuid : Uuidm.t Rt.t =
  Rt.custom
    ~encode:(fun u -> Ok (Uuidm.to_string u))
    ~decode:(fun s ->
      match Uuidm.of_string s with
      | Some u -> Ok u
      | None -> Error (Printf.sprintf "invalid UUID: %S" s))
    Rt.string

let task_status : Tasks.task_status Rt.t =
  Rt.custom
    ~encode:(fun s -> Ok (Tasks.task_status_to_string s))
    ~decode:Tasks.task_status_from_string
    Rt.string

(* A full task row: (id, name, description, state, project). *)
let task : Tasks.task Rt.t =
  let open Rt in
  let intro id name description state project : (Tasks.task, string) result =
    Ok { Tasks.id; name; description; state; project }
  in
  product intro
    @@ proj uuid        (fun (t : Tasks.task) -> t.id)
    @@ proj string      (fun (t : Tasks.task) -> t.name)
    @@ proj string      (fun (t : Tasks.task) -> t.description)
    @@ proj task_status (fun (t : Tasks.task) -> t.state)
    @@ proj string      (fun (t : Tasks.task) -> t.project)
    @@ proj_end
```

## Writing the queries

<!-- TODO(prose): Doobie's sql/fr interpolators vs Caqti's typed request combinators
     (`-->.` exec, `-->?` zero-or-one, `-->*` many). The list endpoint is the interesting
     contrast: Doobie composes fragments dynamically with whereAndOpt, while with Caqti we
     keep four static prepared statements and pick one at runtime. -->

```scala
case class TaskFilter(state: Option[State] = None, project: Option[String] = None)

private def insert(task: Task): Update0 =
  sql"""
    INSERT INTO tasks (id, name, description, state, project)
    VALUES (${task.id}, ${task.name}, ${task.description}, ${task.state}, ${task.project})
  """.update

private def updateStmt(task: Task): Update0 =
  sql"""
    UPDATE tasks
    SET name = ${task.name}, description = ${task.description},
        state = ${task.state}, project = ${task.project}
    WHERE id = ${task.id}
  """.update

private def deleteStmt(id: UUID): Update0 =
  sql"DELETE FROM tasks WHERE id = $id".update

private def selectById(id: UUID): Query0[Task] =
  sql"SELECT id, name, description, state, project FROM tasks WHERE id = $id".query[Task]

private val selectBase: Fragment =
  fr"SELECT id, name, description, state, project FROM tasks"

private def selectWhere(filter: TaskFilter): Query0[Task] = {
  val conditions: List[Fragment] = List(
    filter.state.map(s => fr"state = $s"),
    filter.project.map(p => fr"project = $p")
  ).flatten
  // whereAndOpt(List[Fragment]) emits nothing when the list is empty.
  (selectBase ++ Fragments.whereAndOpt(conditions)).query[Task]
}
```

```ocaml
module Q = struct
  open Caqti_template.Create

  (* The `id` column is UUID but our Caqti `uuid` type binds as text (pgx has no
     native uuid parameter), so every bound id is cast with `?::uuid`. *)
  let insert =
    static T.(task -->. unit)
      "INSERT INTO tasks (id, name, description, state, project) \
       VALUES (?::uuid, ?, ?, ?, ?)"

  (* Update takes (name, description, state, project, id). *)
  let update =
    static T.(t5 string string task_status string uuid -->. unit)
      "UPDATE tasks \
       SET name = ?, description = ?, state = ?, project = ? \
       WHERE id = ?::uuid"

  let delete =
    static T.(uuid -->. unit)
      "DELETE FROM tasks WHERE id = ?::uuid"

  let select_by_id =
    static T.(uuid -->? task)
      "SELECT id, name, description, state, project FROM tasks WHERE id = ?::uuid"

  (* Four list variants so every query stays statically typed and prepared. *)
  let select_all =
    static T.(unit -->* task)
      "SELECT id, name, description, state, project FROM tasks"

  let select_by_state =
    static T.(task_status -->* task)
      "SELECT id, name, description, state, project FROM tasks WHERE state = ?"

  let select_by_project =
    static T.(string -->* task)
      "SELECT id, name, description, state, project FROM tasks WHERE project = ?"

  let select_by_state_project =
    static T.(t2 task_status string -->* task)
      "SELECT id, name, description, state, project FROM tasks \
       WHERE state = ? AND project = ?"
end
```

## Service layer

<!-- TODO(prose): the service keeps the same interface as part 2, only the implementation
     changes. Points worth making: transact(xa) vs Pool.use / with_conn; mapping the Postgres
     unique_violation to AlreadyExists on both sides (SQLState "23505" vs Caqti_error.cause);
     update relies on the affected row count in Doobie, but pgx does not report row counts so
     the OCaml side does a SELECT first on the same connection. -->

```scala
class PostgresTaskService(xa: Transactor[IO]) extends TaskService {

  // SQLSTATE 23505 = unique_violation
  private val UniqueViolation = "23505"

  def create(task: Task): IO[Unit] =
    insert(task).run
      .transact(xa)
      .void
      .adaptError {
        case e: java.sql.SQLException if e.getSQLState == UniqueViolation =>
          AlreadyExists(task.id)
      }

  def list(filter: TaskFilter): IO[List[Task]] =
    selectWhere(filter).to[List].transact(xa)

  def get(id: UUID): IO[Option[Task]] =
    selectById(id).option.transact(xa)

  def update(task: Task): IO[Unit] =
    updateStmt(task).run.transact(xa).flatMap {
      case 0 => IO.raiseError(NotFoundError(task.id))
      case _ => IO.unit
    }

  def delete(id: UUID): IO[Boolean] =
    deleteStmt(id).run.transact(xa).map(_ > 0)
}
```

```ocaml
(* Raise a Caqti query error as an exception (turned into a 500 by Vif). *)
let fail err = raise (Caqti_error.Exn (err :> Caqti_error.t))

(* Borrow a connection from the pool for [f]. *)
let with_conn (pool : t) f =
  Caqti_miou.or_fail (Pool.use (fun conn -> Ok (f conn)) pool)

let add (pool : t) (task : Tasks.task) : (unit, Tasks.error) result =
  with_conn pool @@ fun (module Db : Caqti_miou.CONNECTION) ->
  match Db.exec Q.insert task with
  | Ok () -> Ok ()
  | Error (`Request_failed _ | `Response_failed _ as err)
    when Caqti_error.cause err = `Unique_violation ->
    Error (Tasks.Already_exists task.id)
  | Error err -> fail err

let list ?state ?project (pool : t) : Tasks.task list =
  with_conn pool @@ fun (module Db : Caqti_miou.CONNECTION) ->
  let result =
    match state, project with
    | None, None -> Db.collect_list Q.select_all ()
    | Some s, None -> Db.collect_list Q.select_by_state s
    | None, Some p -> Db.collect_list Q.select_by_project p
    | Some s, Some p -> Db.collect_list Q.select_by_state_project (s, p)
  in
  Caqti_miou.or_fail result

(* Find a task on an already-borrowed connection. *)
let find_conn (module Db : Caqti_miou.CONNECTION) id : Tasks.task option =
  Caqti_miou.or_fail (Db.find_opt Q.select_by_id id)

let get (pool : t) id : Tasks.task option =
  with_conn pool @@ fun conn -> find_conn conn id

(* pgx does not report affected row counts, so existence is checked with a
   prior SELECT on the same connection. *)
let delete (pool : t) id : bool =
  with_conn pool @@ fun ((module Db : Caqti_miou.CONNECTION) as conn) ->
  match find_conn conn id with
  | None -> false
  | Some _ -> Caqti_miou.or_fail (Db.exec Q.delete id); true

let update (pool : t) (task : Tasks.task) : (unit, Tasks.error) result =
  with_conn pool @@ fun ((module Db : Caqti_miou.CONNECTION) as conn) ->
  match find_conn conn task.id with
  | None -> Error (Tasks.Not_found task.id)
  | Some _ ->
    Caqti_miou.or_fail
      (Db.exec Q.update
         (task.name, task.description, task.state, task.project, task.id));
    Ok ()
``` 