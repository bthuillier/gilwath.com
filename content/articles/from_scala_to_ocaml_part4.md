---
title: "Discovering OCaml as a Scala Developer Part 4: Testing against a real PostgreSQL"
synopsis: Writing integration tests for our task store against a real PostgreSQL database, with MUnit and Testcontainers on one side and Alcotest and testcontainers-ocaml on the other
date: 2026-11-05
tags:
  - OCaml
  - Scala
  - Functional Programming
  - HTTP API
  - CRUD
  - SQL
  - Testing
---

## Introduction

In the [previous part](/articles/from_scala_to_ocaml_part3.html), we compared how we work with a SQL database (PostgreSQL) in Scala and OCaml. The Scala side had better ergonomics, but doing SQL with OCaml was not that complicated. Since we chose libraries that let us write plain SQL, the code ended up looking very similar on both sides, apart from the mapping to and from SQL types.

Since the beginning of this series we haven't written a single test. To stay close to what a real project looks like, we will now see how the two languages compare when testing against an external system, in our case a real PostgreSQL database running alongside our tests. We will only test the store layer, since that is where we talk to PostgreSQL.

## What we want from our tests

For the purpose of this article, here is what we want from our tests:

- Having a real PostgreSQL, ideally running inside a container, something that could be easily reproduced by a CI
- Being able to easily load the real schema
- Being sure that every test runs in isolation, without any test impacting another
- Having everything set up inside the tests, meaning that we won't have to start the PostgreSQL server before running the tests
- Being sure that even if the tests fail, PostgreSQL is properly cleaned up at the end

## Choosing the libraries

On the Scala side, we have a lot of possibilities, and depending on the period, a different one was the default choice:
- [MUnit](https://scalameta.org/munit/): a small framework built on JUnit, with good failure output and integrations for cats-effect and Testcontainers
- [ScalaTest](https://www.scalatest.org/): the historical one, several testing styles in one library, by far the most widely used
- [Weaver](https://typelevel.org/weaver-test/): built for cats-effect from the start, runs test cases in parallel by default
- [specs2](https://etorreborre.github.io/specs2/): specification-style testing, also one of the historical options
- [ZIO Test](https://zio.dev/reference/test/): the ZIO ecosystem's own framework, where tests are themselves ZIO effects

For this example we will use MUnit because it is now the default choice, and it is present in a lot of Scala templates to start a new project.

On the OCaml side, I don't really know the ecosystem, but here is what I could find:
- [Alcotest](https://github.com/mirage/alcotest): a lightweight framework with colourful output, the closest thing OCaml has to a default choice
- [OUnit2](https://github.com/gildor478/ounit): the older xUnit-style framework, still around and still maintained
- [Testo](https://github.com/mjambon/testo): a more recent framework inspired by Alcotest and pytest, adding snapshots, parallel runs and expected failures
- [ppx_inline_test](https://github.com/janestreet/ppx_inline_test) and [ppx_expect](https://github.com/janestreet/ppx_expect): Jane Street's syntax extensions to write tests next to the code they test, with a promote workflow on top of dune
- [QCheck](https://github.com/c-cube/qcheck): property-based testing, the counterpart of ScalaCheck, with an Alcotest integration

Alcotest seems to be the default choice, so we will stick to it.

And for the container part:
- [testcontainers-scala](https://github.com/testcontainers/testcontainers-scala): a Scala wrapper over Testcontainers for Java, with modules for PostgreSQL and a few dozen other services, and integrations for MUnit and ScalaTest
- [testcontainers-ocaml](https://github.com/benodiwal/testcontainers-ocaml): released on opam in February 2026 (version 0.1.0), currently incubating under the Testcontainers organisation, built on Lwt
- [docker-api](https://github.com/Chris00/ocaml-docker): OCaml bindings to the Docker Remote API version 1.29, low level and not test oriented

On the Scala/JVM side, the choice is clear. On the OCaml side, testcontainers-ocaml is still very young and built on Lwt while our application runs on Miou, but it has a PostgreSQL module, so we will give it a try.

There is one more change on the OCaml side, and this time it is not about tests. In part 3 we used Caqti with the pgx driver, a PostgreSQL client written in pure OCaml. While writing the tests against a fresh container, I discovered that pgx doesn't support scram-sha-256, the default authentication method since PostgreSQL 14, and the connection fails with `Pgx: SASL Credential authentication not supported`. The only workaround is to configure PostgreSQL to fall back to md5.

And pgx doesn't seem to be maintained anymore: there is an [open issue](https://github.com/arenadotio/pgx/issues/123) about it since 2022 and the [repository](https://github.com/arenadotio/pgx) is archived. Even the Caqti README marks the pgx driver as experimental, so we switch to `caqti-driver-postgresql`, the other PostgreSQL driver of Caqti, based on libpq, the official C client library of PostgreSQL. Thanks to Caqti, the change is small: the URI scheme goes from `pgx://` to `postgresql://` and the dune dependency changes, the rest of the code stays the same. The trade-off is that we lose the pure OCaml client and need libpq installed on the machine.

Here is how we set up the dependencies in Scala:

```scala
val munitTest = Seq(
  "org.scalameta" %% "munit" % "1.3.0" % Test,
  // lets a test body return IO[Unit] instead of calling unsafeRunSync everywhere
  "org.typelevel" %% "munit-cats-effect" % "2.2.0" % Test
)

val testcontainersVersion = "0.44.1"

val testcontainers = Seq(
  "com.dimafeng" %% "testcontainers-scala-munit"      % testcontainersVersion % Test,
  "com.dimafeng" %% "testcontainers-scala-postgresql" % testcontainersVersion % Test
)
```

On the OCaml side, we install libpq, then Alcotest, testcontainers-ocaml and the new driver with opam. On macOS, libpq is not linked by Homebrew, so the opam package needs `pg_config` and the pkg-config file to be found explicitly:

```sh
brew install libpq
export PATH="$(brew --prefix libpq)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install alcotest testcontainers-postgres caqti-driver-postgresql
```

and add the dependencies to the test's dune file:

```dune
(test
 (name test_ocaml_play)
 ; caqti-driver-postgresql is linked here too, so the postgresql:// scheme resolves at runtime.
 (libraries
  ocaml_play alcotest fmt unix uuidm uri
  caqti caqti-miou caqti-miou.unix caqti-driver-postgresql
  lwt lwt.unix testcontainers testcontainers-postgres))
```

## Starting a PostgreSQL container

In Scala it is really simple, because we use Testcontainers. Our test suite just has to extend the `TestContainerForAll` trait, which starts the container declared in `containerDef` before running the suite and stops it after. There is also a `TestContainerForEach` trait that starts one container per test case, but in our case one container for the whole suite is enough, and it avoids paying the PostgreSQL startup time for every test.

Then we have to declare which container we want to use. Testcontainers already provides a definition for a PostgreSQL container, so we just have to set the parameters we need:
- the Docker image we want to use, in our case PostgreSQL 16, but we could use any PostgreSQL image
- the name of the database, and the user and password we want
- the schema script that will be run when the container starts, to create all the tables we need

```scala
class PostgresTaskServiceSuite extends CatsEffectSuite with TestContainerForAll {

  // initScriptPath is resolved on the test classpath, where build.sbt puts db/init.
  override val containerDef: PostgreSQLContainer.Def = PostgreSQLContainer.Def(
    dockerImageName = DockerImageName.parse("postgres:16-alpine"),
    databaseName = "tasks",
    username = "tasks",
    password = "tasks",
    commonJdbcParams = JdbcDatabaseContainer.CommonParams(initScriptPath = Some("01_schema.sql"))
  )

  // ...
}
```

And that's all. Choosing a free port on the host, waiting for PostgreSQL to be ready and removing the container at the end are all handled by Testcontainers.

On the OCaml side, we use testcontainers-ocaml. It already provides a PostgreSQL module, `Postgres_container`, where we set the image, the database, the user and the password, and it waits for PostgreSQL to be ready before giving us the container. But it is not as simple as it seems: on its first start, the official image runs a temporary server, listening only on a local socket, to create the database and run the init scripts, then restarts. So the first "database system is ready to accept connections" in the log is a false positive, and if we try to connect at that time we won't be able to. The module waits for the second one, which is exactly what the Testcontainers PostgreSQL module does on the Scala side.

We still have to add one thing on top of it. The module has a `with_init_script` function, but in version 0.1.0 it is ignored, so we mount the `db/init` folder ourselves. To find it we need `schema_dir`: dune runs the tests from a directory inside `_build`, and `db/init` lives above the dune project, so we walk up the directories until we find it:

```ocaml
open Testcontainers
module Postgres = Testcontainers_postgres.Postgres_container

let user = "tasks"
let password = "tasks"
let database = "tasks"

(* The tests run from a directory inside _build, and db/init lives above the dune
   project, so we walk up until we find the schema the application uses. *)
let rec find_up name dir =
  let candidate = Filename.concat dir name in
  if Sys.file_exists candidate then candidate
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then failwith ("cannot find " ^ name)
    else find_up name parent

let schema_dir () =
  Filename.dirname (find_up "db/init/01_schema.sql" (Sys.getcwd ()))

let request () =
  Postgres.create ()
  |> Postgres.with_image "postgres:16-alpine"
  |> Postgres.with_database database
  |> Postgres.with_username user
  |> Postgres.with_password password
  |> Postgres.to_request
  (* Postgres.with_init_script is ignored in 0.1.0, so we mount the very same
     schema file the application runs against ourselves. *)
  |> Container_request.with_mount
       (Volume.bind ~mode:Volume.ReadOnly ~host:(schema_dir ())
          ~container:"/docker-entrypoint-initdb.d" ())
```

The library is built on Lwt while the rest of our code runs on Miou. In our case it is not really a problem: the container is started before the Miou scheduler and stopped after it, so `start` and `stop` each run their own `Lwt_main.run`, and the two never run at the same time. The last function builds the URI of the PostgreSQL server so the tests can connect to it:

```ocaml
type t = {container: Container.t; port: int}

let start () =
  Lwt_main.run
    (let open Lwt.Syntax in
     let* container = Container.start (request ()) in
     let* port = Container.mapped_port container (Port.tcp 5432) in
     Lwt.return {container; port})

let stop t = Lwt_main.run (Container.terminate t.container)

let uri t =
  Uri.make ~scheme:"postgresql"
    ~userinfo:(user ^ ":" ^ password)
    ~host:"127.0.0.1" ~port:t.port ~path:("/" ^ database) ()
```

## Loading the schema and connecting

Before writing any test, both sides need the schema loaded in the database and a way to connect to the container.

For the schema, the goal was to use the same `db/init/01_schema.sql` file the application runs against, not a copy. On the Scala side, `initScriptPath` is resolved as a resource on the test classpath, so we just have to add the `db/init` folder to the test resources with one line in `build.sbt`. Testcontainers then runs the script over JDBC once the container is started, before any test runs:

```scala
Test / unmanagedResourceDirectories += baseDirectory.value / ".." / "db" / "init"
```

On the OCaml side, we already did it in the previous section: the folder is mounted in `/docker-entrypoint-initdb.d`, so the official image applies the script itself on its first boot. The mechanism is different, but both sides read the same file.

For the connection, both sides had the same problem. In Scala, the application builds its transactor in `Server`, as a private value that reads the database configuration from environment variables. The test suite cannot reuse it, so it builds its own `HikariTransactor` from the container's `jdbcUrl`, as we will see in the next section. In OCaml, `Db.connect_pool` only knew how to build the URI from environment variables, so it gained an optional `?uri` argument:

```diff
-let connect_pool ~sw () : t =
-  match Caqti_miou_unix.connect_pool ~sw (uri_of_env ()) with
+let connect_pool ~sw ?(uri = uri_of_env ()) () : t =
+  match Caqti_miou_unix.connect_pool ~sw uri with
```

The default value keeps the old behaviour, so the call site in `bin/main.ml` doesn't change, and the tests pass the URI of the container instead.

I think this is a small design lesson that has nothing to do with the language: configuration read from the environment deep inside a module is what makes it hard to test, and both of our implementations had it.

## Wiring it into the test suite

On the Scala side, `TestContainerForAll` starts the container in `beforeAll`. Then `ResourceSuiteLocalFixture` from munit-cats-effect turns our transactor resource, backed by a Hikari connection pool, into a suite-local fixture: it is allocated once and released with the suite. Fixtures are allocated after `beforeAll`, so the container is already running and reading its `jdbcUrl` inside the resource is safe. Worth noting, it is the same kind of cats-effect `Resource` we used in part 3 to run the application, nothing had to be adapted.

```scala
// One pool for the whole suite, torn down with it. The container is already
// started when the fixture is allocated, so reading jdbcUrl here is safe.
private val transactor = ResourceSuiteLocalFixture(
  "transactor",
  for {
    url <- Resource.eval(IO(withContainers(_.jdbcUrl)))
    xa <- HikariTransactor.newHikariTransactor[IO](
      driverClassName = "org.postgresql.Driver",
      url = url,
      user = "tasks",
      pass = "tasks",
      connectEC = scala.concurrent.ExecutionContext.global
    )
  } yield xa
)

override def munitFixtures = List(transactor)

private def service: TaskService = PostgresTaskService(transactor())
```

On the OCaml side, we don't have fixtures, but the equivalent is a stack of scopes in the main function. It reads top-down in the order things start: the container, then the Miou scheduler with `Miou_unix.run`, then the pool lifetime with `Caqti_miou.Switch.run`, and finally the tests. When we leave them, they are released in reverse order, the pool first and the container last.

The `~and_exit:false` argument is the important part. By default, `Alcotest.run` terminates the process itself with `exit`, which skips the `Fun.protect` finaliser and leaves the container running after a failing test. So we ask Alcotest not to exit, catch `Alcotest.Test_error` and return the status ourselves. Also, testcontainers-ocaml doesn't have a Ryuk reaper, so if the process is killed the container stays up, which won't happen on the Scala side.

```ocaml
let () =
  let container = Pg_container.start () in
  let status =
    Fun.protect
      ~finally:(fun () -> Pg_container.stop container)
      (fun () ->
        Miou_unix.run @@ fun () ->
        Caqti_miou.Switch.run @@ fun sw ->
        let pool = Db.connect_pool ~sw ~uri:(Pg_container.uri container) () in
        (* Alcotest.run exits the process by default, which would skip the
           finaliser above and leave the container running. *)
        match Alcotest.run ~and_exit:false "ocaml-play" (suite pool) with
        | () -> 0
        | exception Alcotest.Test_error -> 1)
  in
  exit status
```

## Keeping each test isolated

Because we decided to use only one database shared by every test, we have to empty the table we act on before each test. In a real world case we could do something more elaborate depending on our use case: one schema or one database per test or per suite, or even one container per test. There are a lot of possibilities, each with its own trade-off between test isolation and test performance.

In Scala, cleaning up the table before each test is just an override of `beforeEach` that truncates it. Since `beforeEach` returns `Unit`, this is the one place where we still need `unsafeRunSync`:

```scala
// The container is shared, so every test starts from an empty table.
override def beforeEach(context: BeforeEach): Unit =
  sql"TRUNCATE TABLE tasks".update.run.transact(transactor()).void.unsafeRunSync()
```

In OCaml, Alcotest has no `beforeEach` hook at all: a test is just a named function. So we create a `with_clean_db` function that truncates the table and then runs the test body, and a small `test` helper that builds the Alcotest test case with its body wrapped in `with_clean_db`. Where MUnit gives us a method to override, Alcotest gives us a function to compose. It is not worse, just more explicit:

```ocaml
let truncate =
  let open Caqti.Templater in
  static T.(unit -->. unit) "TRUNCATE TABLE tasks"

(* Alcotest has no beforeEach hook, so each test body is wrapped by hand. *)
let with_clean_db pool f () =
  Db.with_conn pool (fun (module Conn : Caqti_miou.CONNECTION) ->
      Caqti_miou.or_fail (Conn.exec truncate ()));
  f pool

let test pool name f = Alcotest.test_case name `Quick (with_clean_db pool f)
```

## Writing the tests

After all this ceremony to prepare our tests, it's time to write the real test cases. This is where the two solutions differ the most: Alcotest needs a printer and an equality function for every type we want to check, and we have to provide them ourselves. `Alcotest.testable` takes a `Fmt.t` and an equality function, so for a task we write the printer `pp_task` and combine it with `( = )` into the testable `task_t`. We do the same for our errors with `error_t`, and `unit_or_error` is the testable for what `Db.add` and `Db.update` return. It's a bit of boilerplate, which is why it was worth mentioning:

```ocaml
(* Alcotest needs a printer and an equality function for every type it
   compares. There is no derived show here, so both are written by hand. *)

let pp_status ppf s = Fmt.string ppf (Tasks.task_status_to_string s)

let pp_task ppf (t : Tasks.task) =
  Fmt.pf ppf "@[<hov 1>{ id = %s;@ name = %S;@ description = %S;@ state = %a;@ project = %S }@]"
    (Uuidm.to_string t.id) t.name t.description pp_status t.state t.project

let task_t = Alcotest.testable pp_task ( = )

let pp_error ppf (e : Tasks.error) =
  match e with
  | Tasks.Already_exists id -> Fmt.pf ppf "Already_exists %s" (Uuidm.to_string id)
  | Tasks.Not_found id -> Fmt.pf ppf "Not_found %s" (Uuidm.to_string id)

let error_t = Alcotest.testable pp_error ( = )

let unit_or_error = Alcotest.result Alcotest.unit error_t
```

In Scala it's really simple: we define each test by calling the MUnit function `test` with a name and the body of the test. Thanks to munit-cats-effect the body can return an `IO`, so the for-comprehension is the test. We just call `assertEquals` for each check, and if anything fails it displays the diff automatically. Since a `SELECT` gives no guarantee about the order of the rows, we sort the lists by name before comparing them:

```scala
test("create then get returns the task") {
  val t = service
  val task1 = task()
  for {
    _ <- t.create(task1)
    found <- t.get(task1.id)
  } yield assertEquals(found, Some(task1))
}

test("list filters on state and project") {
  val t = service
  val waiting = task("a", State.Waiting, "ABC")
  val done = task("b", State.Done, "ABC")
  val other = task("c", State.Done, "XYZ")
  for {
    _ <- t.create(waiting)
    _ <- t.create(done)
    _ <- t.create(other)
    byState <- t.list(TaskFilter(state = Some(State.Done)))
    byProject <- t.list(TaskFilter(project = Some("ABC")))
    byBoth <- t.list(TaskFilter(state = Some(State.Done), project = Some("ABC")))
  } yield {
    assertEquals(byState.sortBy(_.name), List(done, other))
    assertEquals(byProject.sortBy(_.name), List(waiting, done))
    assertEquals(byBoth, List(done))
  }
}
```

In OCaml it's a little bit different: instead of defining each test in the body of a class, we define a list of groups. Each group is a tuple with a name and a list of tests, and each test is built with the `test` helper we defined previously, which takes our connection pool, the name of the test and its body. Each assertion is a call to `Alcotest.check` with:
- the testable, so how to print and compare the value
- the name of the check
- the expected value

and then the value we want to check. Be careful, the order is the opposite of MUnit, where `assertEquals` takes the obtained value first. As in Scala, `by_name` sorts the lists before comparing them:

```ocaml
let suite pool =
  [ ( "crud"
    , [ test pool "create then get returns the task" (fun pool ->
            let t = sample () in
            Alcotest.(check unit_or_error) "create" (Ok ()) (Db.add pool t);
            Alcotest.(check (option task_t)) "get" (Some t) (Db.get pool t.id)) ] )
  ; ( "list"
    , [ test pool "filters on state and project" (fun pool ->
            let waiting = sample ~name:"a" ~state:Tasks.Waiting ~project:"ABC" () in
            let done_ = sample ~name:"b" ~state:Tasks.Done ~project:"ABC" () in
            let other = sample ~name:"c" ~state:Tasks.Done ~project:"XYZ" () in
            List.iter (fun t -> ignore (Db.add pool t)) [waiting; done_; other];
            Alcotest.(check (list task_t))
              "by state" [done_; other]
              (by_name (Db.list ~state:Tasks.Done pool));
            Alcotest.(check (list task_t))
              "by project" [waiting; done_]
              (by_name (Db.list ~project:"ABC" pool));
            Alcotest.(check (list task_t))
              "by both" [done_]
              (by_name (Db.list ~state:Tasks.Done ~project:"ABC" pool))) ] ) ]
```

## Testing the error cases

In the previous section we covered the happy path, but now we want to test the error cases coming from the database: `Already_exists` when the database returns a real unique violation on the primary key, and `Not_found` from a real missing row. These are exactly the cases a mock cannot cover, and in part 3 they were where the Scala and OCaml solutions differed the most: in Scala we match the SQLSTATE `23505` by hand, while in OCaml Caqti directly gives us `` `Unique_violation ``. And since pgx did not report the number of affected rows, the OCaml side checks that the task exists with a preliminary SELECT. With the libpq driver we could now use the affected rows count, but we keep the code from part 3 as it is: the tests are here to check the behaviour, whatever the implementation.

In Scala our errors are exceptions raised inside the `IO`, so to get the error back instead of the success we call `.intercept[TypeOfOurError]` on our `IO`, an extension provided by munit-cats-effect. Then we can do our assertion on the error as we did previously for the success case. We could also call `.attempt` to turn our `IO[A]` into an `IO[Either[Throwable, A]]` and compare it to a `Left`, but the error type would still be a `Throwable`, not our domain error:

```scala
test("create twice with the same id fails with AlreadyExists") {
  val t = service
  val task1 = task()
  for {
    _ <- t.create(task1)
    error <- t.create(task1).intercept[AlreadyExists]
  } yield assertEquals(error.id, task1.id)
}

test("update on an unknown id fails with NotFoundError") {
  val missing = task()
  service.update(missing).intercept[NotFoundError].map(e => assertEquals(e.id, missing.id))
}
```

In OCaml it's not really different, but because our functions return a `result`, the error is just a value: we only have to check the result against an expected `Error (Tasks.Already_exists t.id)`. This is where the `error_t` testable we wrote in the previous section pays off, and it's one of the reasons I prefer returning errors rather than raising them: the test is an ordinary equality and needs no support from the framework:

```ocaml
test pool "create twice with the same id fails with Already_exists" (fun pool ->
    let t = sample () in
    Alcotest.(check unit_or_error) "first" (Ok ()) (Db.add pool t);
    Alcotest.(check unit_or_error)
      "second"
      (Error (Tasks.Already_exists t.id))
      (Db.add pool t));

test pool "update on an unknown id fails with Not_found" (fun pool ->
    let t = sample () in
    Alcotest.(check unit_or_error)
      "update"
      (Error (Tasks.Not_found t.id))
      (Db.update pool t))
```

## Running them

Running the tests in Scala with sbt is fairly easy, you just have to run `sbt test` and you will have everything running with a recap of it, when everything is green, there is not much to be displayed, just all the test classes evaluated, the number of tests and the duration of the run:

```sh
$ sbt test
Test run PostgresTaskServiceSuite started
PostgresTaskServiceSuite: finished 4.404s
Test run PostgresTaskServiceSuite finished: 0 failed, 0 ignored, 8 total 4.409s
[info] Passed: Total 8, Failed 0, Errors 0, Passed 8
```

When there is a failure there is a little bit more to display, MUnit will display where the assertion failed, and the diff between what we obtained and what we expected:

```sh
$ sbt test
Test run PostgresTaskServiceSuite started
==> X PostgresTaskServiceSuite.update replaces the stored task 0.034s munit.ComparisonFailException: src/test/scala/PostgresTaskServiceSuite.scala:122
121:      found <- t.get(task1.id)
122:    } yield assertEquals(found, Some(task1))
123:  }
values are not the same
=> Obtained
Some(
  value = Task(
    id = e7d50b2f-64ed-4cc7-8cd4-0d352d15f49c,
    name = "renamed",
    description = "description of write the tests",
    state = Done(),
    project = "ABC"
  )
)
=> Diff (- expected, + obtained)
     id = e7d50b2f-64ed-4cc7-8cd4-0d352d15f49c,
-    name = "write the tests",
+    name = "renamed",
     description = "description of write the tests",
-    state = Waiting(),
+    state = Done(),
     project = "ABC"
    at munit.FunSuite.assertEquals(FunSuite.scala:12)
    at PostgresTaskServiceSuite...(PostgresTaskServiceSuite.scala:122)
    ...
PostgresTaskServiceSuite: finished 2.4s
Test run PostgresTaskServiceSuite finished: 1 failed, 0 ignored, 8 total 2.405s
[error] Failed: Total 8, Failed 1, Errors 0, Passed 7
[error] Failed tests:
[error] 	PostgresTaskServiceSuite
[error] (Test / test) sbt.TestsFailedException: Tests unsuccessful
```

In OCaml we run `dune test`, but with a small subtlety: dune only runs the tests again if something changed since the last run, so a second `dune test` in a row does nothing at all and returns instantly. For integration tests that depend on something outside of our code, like a database, it's not what we want, so we add `-f` to force the run. When everything is green, Alcotest displays every test with its group and its index, the duration and the number of tests run:

```sh
$ dune test -f
Testing `ocaml-play'.
This run has ID `WFJKY5UZ'.

  [OK]          crud          0   create then get returns the task.
  [OK]          crud          1   get on an unknown id returns None.
  [OK]          crud          2   create twice with the same id fails with Al...
  [OK]          crud          3   update replaces the stored task.
  [OK]          crud          4   update on an unknown id fails with Not_found.
  [OK]          crud          5   delete returns true once and false afterwards.
  [OK]          list          0   without filter returns every task.
  [OK]          list          1   filters on state and project.

Full test results in `.../_build/_tests/ocaml-play'.
Test Successful in 0.088s. 8 tests run.
```

When there is a failure, Alcotest marks the failing test in the list and then displays the details: every check that passed before the failing one, using the names we gave to each `Alcotest.check`, and the expected and received values, printed with our `pp_task`. There is no diff, so it's up to us to spot the difference, and the full output of the failing test is saved in a file under `_build`:

```sh
$ dune test -f
Testing `ocaml-play'.
This run has ID `5AB6UN0S'.

  [OK]          crud          0   create then get returns the task.
  [OK]          crud          1   get on an unknown id returns None.
  [OK]          crud          2   create twice with the same id fails with Al...
> [FAIL]        crud          3   update replaces the stored task.
  [OK]          crud          4   update on an unknown id fails with Not_found.
  [OK]          crud          5   delete returns true once and false afterwards.
  [OK]          list          0   without filter returns every task.
  [OK]          list          1   filters on state and project.

┌──────────────────────────────────────────────────────────────────────────────┐
│ [FAIL]        crud          3   update replaces the stored task.             │
└──────────────────────────────────────────────────────────────────────────────┘
ASSERT create
ASSERT update
ASSERT get
FAIL get

   Expected: `Some
                { id = 54b47847-d0f7-40db-9b92-803642ae69f6;
                 name = "write the tests";
                 description = "description of write the tests";
                 state = Waiting; project = "ABC" }'

   Received: `Some
                { id = 54b47847-d0f7-40db-9b92-803642ae69f6;
                 name = "renamed";
                 description = "description of write the tests";
                 state = Done; project = "ABC" }'

Logs saved to `.../_build/_tests/ocaml-play/crud.003.output'.

Full test results in `.../_build/_tests/ocaml-play'.
1 failure! in 0.082s. 8 tests run.
```

## Conclusion

Writing integration tests against a real PostgreSQL on both sides gives a more mixed answer than the previous parts, because the test framework and the container setup don't end up in the same place.

On the test framework side, OCaml holds up well, and for once it's even simpler than Scala. Alcotest is smaller than MUnit and gives us less, there are no hooks and we have to write a printer for every type we check, but thanks to Miou's direct style the effects never reach our tests: there is no equivalent of munit-cats-effect to add, no `IO` in the signature of our tests, a test is just a function returning `unit`. After three articles where the OCaml side was usually the more verbose one, it's nice to see it the other way around. And since our errors are returned as values instead of being raised, testing the error cases is just another equality check.

On the container side, the gap is smaller than I expected but it's still there. With testcontainers-scala it's two dependencies and a few lines of code. testcontainers-ocaml exists and does the hard part for us, but it's still a 0.1.0: the init script option is ignored so we mount the schema ourselves, there is no Ryuk reaper, and it brings Lwt into a Miou application. On top of that we had to work around Alcotest calling `exit` to make sure the container is stopped after a failure. The tests also showed us that pgx, the driver we chose in part 3, doesn't support the default authentication of PostgreSQL 14+ and is no longer maintained, which pushed us to the libpq driver.

None of this is a missing capability though: OCaml can test against a real PostgreSQL the same way Scala does, it just asks for a bit more work for now, and testcontainers-ocaml will only get better.

For now there is no part 5 planned, this one may well be the last of the series. If I ever come back to it, there are still plenty of things worth comparing between the two languages.
