---
title: "Discovering OCaml as a Scala Developer Part 2: Building a CRUD HTTP API"
synopsis: Building the same small Tasks CRUD API in both Scala and OCaml, and comparing the experience side by side.
date: 2026-05-28
---

## Introduction

In the [first part](/articles/from_scala_to_ocaml_part1.html), we compared the tooling around both languages: how to install a compiler, how to manage dependencies, and how to bootstrap a "hello world" project. We saw that Scala typically relies on a combination of SDKMAN, coursier and sbt (or one of its alternatives), while OCaml leans on a simpler pair: OPAM for everything version- and dependency-related, and Dune for the build. Once you accept that OPAM plays the role SDKMAN or nvm plays in other ecosystems, the experience ends up feeling surprisingly close on both sides.

Now that we know how to start a project, it is time to actually build something. In this second part, we are going to implement the same small CRUD HTTP API in both languages, against a shared OpenAPI contract. The API manages a list of `Task`s — each with an id, a name, a description and a state (`Waiting`, `InProgress` or `Done`) — and exposes the usual endpoints to list, create, fetch, update and delete them. Data lives in memory; the goal is not to build a real service but to compare how each ecosystem handles HTTP routing, JSON encoding/decoding, error responses, and overall code organisation.

We will go through the libraries used on each side later in the article. Both projects live side by side in the same repository so we can compare them endpoint by endpoint.

## The API at a glance

Before jumping into code, here is a quick visual overview of what we are going to build. A `Task` is a small record with an id, a name, a description and a state that can be one of `Waiting`, `InProgress` or `Done`. On the wire, a single task looks like this:

```json
{
  "id": "8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8",
  "name": "Write part 2",
  "description": "Build the same CRUD API in Scala and OCaml",
  "state": "InProgress"
}
```

When creating or updating a task, the client sends the same shape *without* the `id` — the server generates the id on creation and returns it:

```json
// request body
{
  "name": "Write part 2",
  "description": "Build the same CRUD API in Scala and OCaml",
  "state": "Waiting"
}

// response body for POST /tasks
{ "id": "8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8" }
```

And errors all share the same simple shape:

```json
{ "message": "task 8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8 not found" }
```

The routes themselves are the usual CRUD suspects, with their main success responses:

```
  METHOD   PATH               BODY        →  RESPONSE
  ──────   ────               ────           ────────
  GET      /tasks             —           →  200  [Task, ...]
  POST     /tasks             TaskInput   →  201  { id }
  GET      /tasks/{id}        —           →  200  Task
  POST     /tasks/{id}        TaskInput   →  200  (updated)
  DELETE   /tasks/{id}        —           →  204  (deleted)
```

The non-happy paths are the ones you would expect: `400` for a malformed JSON body, `404` when the id does not exist, and `409` on the rare case where a generated id collides with an existing one. The whole contract is described once in an OpenAPI file shared by both projects, so the two implementations stay honest about speaking exactly the same protocol.

## Choosing the libraries

On the Scala side, the ecosystem for building HTTP APIs is quite large, and there are several good options. For the HTTP server, the main choices are:
- [http4s](https://http4s.org/): a purely functional library that integrates well with cats-effect and fs2. It has a nice DSL for defining routes and handling requests.
- [pekko-http](https://pekko.apache.org/docs/pekko-http/current/): a high-performance library that is part of the Pekko ecosystem (formerly Akka). It has a more traditional API and is known for its scalability and robustness.
- [play](https://www.playframework.com/): a full-stack web framework that includes everything you need to build a web application, from routing to templating to ORM.
- [tapir](https://tapir.softwaremill.com/en/latest/): a library that lets you define your HTTP API with a DSL, and from that definition derive the server routes, the OpenAPI documentation, and even the client code. The backend and JSON libraries are pluggable and support most of the popular ones, including http4s and circe. It's my go-to for building HTTP APIs.

For this example I will go with http4s: it is one of the simplest options, and its style (a small set of combinators rather than a full framework) feels close enough to what we will use on the OCaml side that the comparison stays fair. If you are new to Scala and want to explore other options, tapir is a great choice. For JSON I will use [circe](https://circe.github.io/circe/), which is the one I'm most used to and pairs naturally with http4s through [http4s-circe](https://http4s.org/v1/docs/json.html).

On the OCaml side, the ecosystem is a bit smaller, but there are still good options for doing HTTP APIs:
- [Opium](https://github.com/rgrinberg/opium): a lightweight web framework inspired by Ruby's Sinatra. It provides a simple DSL for defining routes and handling requests, making it easy to get started with HTTP APIs in OCaml.
- [Dream](https://github.com/aantron/dream): a modern web framework that emphasizes simplicity and performance. It has a clean API and supports features like WebSockets, making it a good choice for building real-time applications.
- [Vif](https://github.com/robur-coop/vif): a simple HTTP server for OCaml 5, with a focus on being easy to use and understand. It has a minimal API and is designed for small to medium-sized applications.

To pick an HTTP library on the OCaml side I asked [@xvw](https://github.com/xvw) for advice, and he recommended trying Vif together with [jsont](https://erratique.ch/software/jsont) for JSON. Vif is small and unopinionated, which means the routing and JSON code stay visible in our own files rather than hidden behind framework magic — exactly what we want for a side-by-side comparison. So I will go with Vif and jsont for the OCaml side.

## Modeling the domain

Before getting to the HTTP layer, we need to model our domain: the data types themselves and how they are encoded to JSON.

In Scala we can define `Task` as a case class (what other languages would call a record or a struct) and use circe's automatic derivation to get JSON encoding and decoding for free:

```scala
import java.util.UUID
import io.circe.Codec
import io.circe.derivation.Configuration
import io.circe.derivation.ConfiguredEnumCodec

case class Task(id: UUID, name: String, description: String, state: State) derives Codec.AsObject
case class TaskInput(name: String, description: String, state: State) derives Codec.AsObject

enum State {
  case Waiting
  case InProgress
  case Done
}

object State {
  given Configuration = Configuration.default
  given Codec[State] = ConfiguredEnumCodec.derived
}
```

The `derives Codec.AsObject` clause on each case class is all we need to get a circe `Encoder` and `Decoder`: the compiler walks the fields, finds a codec for each one, and stitches them together at compile time. For `State`, which is a Scala 3 `enum` (a closed set of cases — what other languages call a sum type or tagged union), we ask for a `ConfiguredEnumCodec`, which encodes each case as its name (`"Waiting"`, `"InProgress"`, `"Done"`) — exactly matching the JSON shape we showed earlier.

On the OCaml side, we put the domain in a small library, with a `.mli` interface file that declares what the module exposes and a `.ml` file that implements it. Anything not listed in the `.mli` is private. Scala has no direct equivalent: visibility is controlled inline with `private`/`protected`.

Here is the interface, `lib/Tasks.mli`:

```ocaml
type task_status = Waiting | InProgress | Done

type task =
  { id: Uuidm.t
  ; name: string
  ; description: string
  ; state: task_status }

type task_input =
  { name: string
  ; description: string
  ; state: task_status }

val with_id : task_input -> Uuidm.t -> task

val jsont : task Jsont.t
val task_input_jsont : task_input Jsont.t
val uuid_jsont : Uuidm.t Jsont.t
```

The records and variant map one-to-one to the Scala `case class`es and `enum` above. OCaml has no UUID type in its stdlib, so we pull in [uuidm](https://erratique.ch/software/uuidm) for `Uuidm.t`. `with_id` builds a `task` from a `task_input` and a generated id, which the create endpoint will need.

The three values at the bottom are jsont codecs: a `'a Jsont.t` is a *value* that describes how to encode and decode an `'a` to and from JSON. Unlike circe, jsont has no derivation — we build the description by hand, in `lib/Tasks.ml`:

```ocaml
let task_status_to_string = function
  | Waiting    -> "Waiting"
  | InProgress -> "InProgress"
  | Done       -> "Done"

let task_status_from_string = function
  | "Waiting"    -> Ok Waiting
  | "InProgress" -> Ok InProgress
  | "Done"       -> Ok Done
  | s            -> Error (Printf.sprintf "invalid task_status: %S" s)

let task_status_jsont =
  Jsont.of_of_string
    ~kind:"task_status"
    ~enc:task_status_to_string
    task_status_from_string

let uuid_jsont =
  Jsont.of_of_string
    ~kind:"uuid"
    ~enc:Uuidm.to_string
    (fun s ->
      match Uuidm.of_string s with
      | Some u -> Ok u
      | None   -> Error (Printf.sprintf "invalid UUID: %S" s))

let jsont =
  let open Jsont in
  let id          = Object.mem "id"          uuid_jsont        ~enc:(fun (t : task) -> t.id) in
  let name        = Object.mem "name"        string            ~enc:(fun (t : task) -> t.name) in
  let description = Object.mem "description" string            ~enc:(fun (t : task) -> t.description) in
  let state       = Object.mem "state"       task_status_jsont ~enc:(fun (t : task) -> t.state) in
  let fn id name description state : task = { id; name; description; state } in
  Object.map fn |> id |> name |> description |> state |> Object.finish
```

For `task_status` and `Uuidm.t`, `Jsont.of_of_string` is enough: a function to string, a function back, and we get a codec that encodes the value as a JSON string. For the record, each `Object.mem` describes one field — its JSON key, its codec, and how to read it out — and we assemble them with `Object.map fn |> id |> name |> ...`. The pipe order matters: fields reach `fn` in the order they are piped. `task_input_jsont` (omitted) follows the same pattern without the `id` field.

This is clearly more code than the Scala version: every field name, codec and accessor is spelled out. The upside is that the JSON shape is fully explicit — changing a key or the encoding of `state` is a one-line edit right where the codec lives, with no derivation magic to chase. For a domain this size that trade-off is fine; for a larger one it would get repetitive. There is an experimental ppx, [ppx_deriving_jsont](https://github.com/voodoos/ppx_deriving_jsont), that aims to generate `Jsont.t` values from a type definition. A *ppx* is OCaml's preprocessor extension mechanism: a small program that rewrites the syntax tree at compile time, used to add things like `[@@deriving show]` annotations to a type. It is the closest OCaml equivalent to a Scala 3 macro or `derives` clause.


## Service layer

With the domain defined, we can move on to the service layer. To mirror the API contract from earlier, we need the following functions:

```
create : Task             -> Result<(), AlreadyExists>
list   : ()               -> List<Task>
get    : UUID             -> Option<Task>
update : Task             -> Result<(), NotFound>
delete : UUID             -> Boolean       // true if something was removed
```

A few things to note about this little signature:
- `create` and `update` can fail in a structured way: `create` if the id already exists, `update` if it does not — so they return a `Result` (an `Either`) rather than just a value.
- `get` returns an `Option` because "not found" is an expected outcome of a lookup, not an error.
- `delete` returns a boolean rather than a `Result`: the handler will turn `false` into a `404`. Returning `Result<(), NotFound>` would work just as well; the choice is mostly stylistic.
- `list` is total: an empty list is a perfectly valid answer.

For both implementations we want to avoid pulling in external dependencies, so the data lives in memory in a simple mutable map. We will also ignore any concurrency issues that come with that for now.

On the Scala side it is straightforward: a `scala.collection.mutable.Map` wrapped in a `TaskService` class.

```scala
import java.util.UUID
import cats.effect.IO

final case class AlreadyExists(id: UUID) extends RuntimeException(s"task $id already exists")
final case class NotFoundError(id: UUID) extends RuntimeException(s"task $id not found")

class TaskService {

  val data: scala.collection.mutable.Map[UUID, Task] =
    scala.collection.mutable.Map[UUID, Task]()

  def create(task: Task): IO[Unit] = data.get(task.id) match {
    case Some(_) => IO.raiseError(AlreadyExists(task.id))
    case None    => IO(data += (task.id -> task)).void
  }

  def list: IO[List[Task]] = IO(data.values.toList)

  def get(id: UUID): IO[Option[Task]] = IO(data.get(id))

  def update(task: Task): IO[Unit] = data.get(task.id) match {
    case None    => IO.raiseError(NotFoundError(task.id))
    case Some(_) => IO(data.update(task.id, task)).void
  }

  def delete(id: UUID): IO[Boolean] = IO {
    data.remove(id).fold(false)(_ => true)
  }
}
```

A few things diverge from the pseudo-signatures we sketched. First, every method is wrapped in cats-effect's `IO[_]`: even though the underlying map operations are synchronous, http4s expects handlers that produce `IO`, so it is more uniform to expose the service that way from the start. Second, the structured failures (`AlreadyExists`, `NotFoundError`) are not returned as `Either` values but raised as typed exceptions inside the `IO` via `IO.raiseError`. The handler will recover from them with `.recoverWith` and turn each one into the right HTTP status. We could return `IO[Either[Error, Unit]]` instead, but that would mean stacking two effects (`IO` *and* `Either`) and reaching for a *monad transformer* like `EitherT` to keep `for`-comprehensions readable — extra machinery we don't really need here, so we keep things simple by letting `IO` carry the failure on its own.

On the OCaml side, we do the same thing with the standard library's `Hashtbl`, exposed through a `Service` submodule of `Tasks`. The interface in `lib/Tasks.mli` declares the operations we want:

```ocaml
type error =
  | Already_exists of Uuidm.t
  | Not_found of Uuidm.t

module Service : sig
  type t

  val create : int -> t
  val add    : t -> task -> (unit, error) result
  val list   : t -> task list
  val get    : t -> Uuidm.t -> task option
  val delete : t -> Uuidm.t -> bool
  val update : t -> task -> (unit, error) result
end
```

And the implementation in `lib/Tasks.ml`:

```ocaml
type error =
  | Already_exists of Uuidm.t
  | Not_found of Uuidm.t

module Service = struct
  type t = (Uuidm.t, task) Hashtbl.t

  let create capacity = Hashtbl.create capacity

  let add store (task : task) : (unit, error) result =
    if Hashtbl.mem store task.id then Error (Already_exists task.id)
    else begin
      Hashtbl.add store task.id task;
      Ok ()
    end

  let list store : task list =
    Hashtbl.fold (fun _ v acc -> v :: acc) store []

  let get store id : task option =
    Hashtbl.find_opt store id

  let delete store id : bool =
    let existed = Hashtbl.mem store id in
    if existed then Hashtbl.remove store id;
    existed

  let update store (task : task) : (unit, error) result =
    if Hashtbl.mem store task.id then begin
      Hashtbl.replace store task.id task;
      Ok ()
    end
    else Error (Not_found task.id)
end
```

Two points worth flagging. The OCaml version stays synchronous: no `IO` wrapper, no monad to thread through. And the structured failures are returned directly as `(unit, error) result` values, the same algebraic data type we used for `task_status`, so no `Either` vs `IO` tension and no monad transformer in sight.

One more detail to notice in the `.mli`: `type t` is declared without an implementation. The `.ml` says `type t = (Uuidm.t, task) Hashtbl.t`, but callers never see that. To them, `Service.t` is *abstract*: they can hold one and call the functions on it, nothing more. Swapping the `Hashtbl` for a real database connection would not require any change outside this module. Scala has no direct language-level equivalent; the closest is sealing the implementation behind a trait and only exposing that trait, which is several extra moving parts for the same effect.

## Routing and handlers

With the domain and the service in place, all that is left is the HTTP layer: parse the URL, decode the body when there is one, call the service, and turn the result into a response. This is where the two ecosystems feel the most different in style, even though the shape of the code is similar.

On the Scala side, http4s exposes a small DSL where routes are a partial function from `Request` to `IO[Response]`. We define them in `TaskRouter.scala`:

```scala
import java.util.UUID
import org.http4s.*
import org.http4s.dsl.io.*
import org.http4s.circe.*
import org.http4s.circe.CirceEntityEncoder.*
import cats.effect.IO
import io.circe.Codec

object TaskRouter {

  case class ErrorResponse(message: String) derives Codec.AsObject
  case class IdResponse(id: UUID) derives Codec.AsObject

  given EntityDecoder[IO, TaskInput] = jsonOf[IO, TaskInput]

  def routes(taskService: TaskService) = HttpRoutes.of[IO] {
    case req @ POST -> Root / "tasks" =>
      req.as[TaskInput].flatMap { input =>
        val id = UUID.randomUUID()
        val task = Task(id, input.name, input.description, input.state)
        taskService.create(task) *> Created(IdResponse(id))
      }.recoverWith {
        case AlreadyExists(id)  => Conflict(ErrorResponse(s"task $id already exists"))
        case m: MessageFailure  => BadRequest(ErrorResponse(m.getMessage))
      }

    case GET -> Root / "tasks" =>
      taskService.list.flatMap(Ok(_))

    case GET -> Root / "tasks" / UUIDVar(id) =>
      taskService.get(id).flatMap {
        case Some(task) => Ok(task)
        case None       => NotFound(ErrorResponse(s"task $id not found"))
      }

    case req @ POST -> Root / "tasks" / UUIDVar(id) =>
      req.as[TaskInput].flatMap { input =>
        val task = Task(id, input.name, input.description, input.state)
        taskService.update(task) *> Ok()
      }.recoverWith {
        case NotFoundError(id) => NotFound(ErrorResponse(s"task $id not found"))
        case m: MessageFailure => BadRequest(ErrorResponse(m.getMessage))
      }

    case DELETE -> Root / "tasks" / UUIDVar(id) =>
      taskService.delete(id).flatMap { deleted =>
        if (deleted) NoContent() else NotFound(ErrorResponse(s"task $id not found"))
      }
  }.orNotFound
}
```

The router is one big partial function that pattern-matches method and path, with extractors like `Root`, `/`, `UUIDVar` doing the parsing. The `given EntityDecoder` plugs circe in so `req.as[TaskInput]` can parse the body, and the imported `CirceEntityEncoder.*` makes `Ok(task)` work in the other direction.

Service failures surface as exceptions inside `IO` and are caught with `.recoverWith`: our typed domain errors map to `409`/`404`, and http4s' own `MessageFailure` (raised when the body fails to parse) maps to `400`. `.orNotFound` turns the partial function into a total `HttpApp`.

Wiring everything up lives in `Server.scala`, with [Ember](https://http4s.org/v1/docs/integrations.html#ember) as the underlying HTTP server:

```scala
object Server {
  given LoggerFactory[IO] = NoOpFactory[IO]

  def run: IO[Nothing] = {
    val taskService = TaskService()
    EmberServerBuilder.default[IO]
      .withHost(ipv4"0.0.0.0")
      .withPort(port"8080")
      .withHttpApp(TaskRouter.routes(taskService))
      .build
      .useForever
  }
}
```

`Main.scala` calls `Server.run.unsafeRunSync()` to actually start the program. `unsafe` is the cats-effect convention for the single point where a pure `IO` value gets executed.

On the OCaml side, the equivalent lives in `bin/main.ml`. Vif's routing is built from typed URI combinators rather than a pattern match, so the path is parsed and the handler signature is checked at the same time:

```ocaml
open Ocaml_play

let cfg = Vif.config (Unix.ADDR_INET (Unix.inet_addr_loopback, 8080))

let rstate = Random.State.make_self_init ()
let gen_uuid () = Uuidm.v4_gen rstate ()

type api_error = { message: string }
let api_error_jsont =
  let open Jsont in
  let message = Object.mem "message" string ~enc:(fun (e : api_error) -> e.message) in
  let fn message : api_error = { message } in
  Object.map fn |> message |> Object.finish

type id_response = { id: Uuidm.t }
let id_response_jsont =
  let open Jsont in
  let id = Object.mem "id" Tasks.uuid_jsont ~enc:(fun (r : id_response) -> r.id) in
  let fn id : id_response = { id } in
  Object.map fn |> id |> Object.finish

let respond_empty status =
  let open Vif.Response.Syntax in
  let* () = Vif.Response.empty in
  Vif.Response.respond status

let respond_error req status message =
  let open Vif.Response.Syntax in
  let* () = Vif.Response.with_json req api_error_jsont { message } in
  Vif.Response.respond status

let uuid_atom =
  let inj s = match Uuidm.of_string s with
    | Some u -> u
    | None   -> raise Exit
  in
  Vif.Uri.conv inj Uuidm.to_string (Vif.Uri.string `Path)

let with_json_body req k =
  match Vif.Request.of_json req with
  | Error (`Msg msg) -> respond_error req `Bad_request msg
  | Ok value         -> k value

let handle_service_result req ~ok = function
  | Ok ()                          -> respond_empty ok
  | Error (Tasks.Already_exists id) ->
    respond_error req `Conflict (Printf.sprintf "task %s already exists" (Uuidm.to_string id))
  | Error (Tasks.Not_found id) ->
    respond_error req `Not_found (Printf.sprintf "task %s not found" (Uuidm.to_string id))

let list_tasks req _server store =
  let open Vif.Response.Syntax in
  let tasks = Tasks.Service.list store in
  let* () = Vif.Response.with_json req (Jsont.list Tasks.jsont) tasks in
  Vif.Response.respond `OK

let get_task req uuid _server store =
  let open Vif.Response.Syntax in
  match Tasks.Service.get store uuid with
  | None      -> respond_error req `Not_found (Printf.sprintf "task %s not found" (Uuidm.to_string uuid))
  | Some task ->
    let* () = Vif.Response.with_json req Tasks.jsont task in
    Vif.Response.respond `OK

let create_task req _server store =
  let open Vif.Response.Syntax in
  with_json_body req @@ fun (input : Tasks.task_input) ->
  let id = gen_uuid () in
  let task = Tasks.with_id input id in
  match Tasks.Service.add store task with
  | Ok () ->
    let* () = Vif.Response.with_json req id_response_jsont { id } in
    Vif.Response.respond `Created
  | Error e -> handle_service_result req ~ok:`Created (Error e)

let update_task req uuid _server store =
  with_json_body req @@ fun (input : Tasks.task_input) ->
  let task = Tasks.with_id input uuid in
  Tasks.Service.update store task |> handle_service_result req ~ok:`OK

let delete_task req uuid _server store =
  if Tasks.Service.delete store uuid then respond_empty `No_content
  else respond_error req `Not_found (Printf.sprintf "task %s not found" (Uuidm.to_string uuid))

let routes =
  let open Vif.Uri in
  let open Vif.Route in
  let open Vif.Type in
  [ post   (json_encoding Tasks.task_input_jsont) (rel / "tasks" /?? nil)                   --> create_task
  ; get    (rel / "tasks" /?? nil)                                                          --> list_tasks
  ; get    (rel / "tasks" /% uuid_atom /?? nil)                                             --> get_task
  ; post   (json_encoding Tasks.task_input_jsont) (rel / "tasks" /% uuid_atom /?? nil)      --> update_task
  ; delete (rel / "tasks" /% uuid_atom /?? nil)                                             --> delete_task
  ]

let () =
  Miou_unix.run @@ fun () ->
  let store = Tasks.Service.create 16 in
  Vif.run ~cfg routes store
```

There is more ceremony than on the Scala side, but the parts line up. Routes are values: each entry combines a method, a URI pattern built from `rel`, `/`, `/%` and `uuid_atom`, and a handler joined with `-->`. The URI combinators are typed, so `rel / "tasks" /% uuid_atom /?? nil` already promises the handler a `Uuidm.t`, no `UUIDVar`-style extractor in the body. 

JSON stays explicit too: `Vif.Request.of_json` returns a plain `result`, which we wrap in `with_json_body` so each handler only sees the happy path. On the way out, `Vif.Response.with_json` writes the body and `Vif.Response.respond` sets the status. The `let* ()` from `Vif.Response.Syntax` plays the role of a `for`-comprehension.

Error handling mirrors the service layer: where Scala catches exceptions with `.recoverWith`, OCaml pattern-matches on the `result`. `handle_service_result` is the single place where service errors meet HTTP statuses.

The entry point boots [Miou](https://github.com/robur-coop/miou) via `Miou_unix.run`. Miou is OCaml 5's effect-based cooperative scheduler; Vif uses it to serve concurrent connections while keeping the handlers themselves looking synchronous, so no `IO` wrapper leaks into our code.

Same five endpoints, same JSON shapes, same status codes on both sides. The Scala version reads like one declarative block; the OCaml version splits into small named handlers plus a route list, a bit more upfront but each handler is easy to read in isolation.

## Conclusion

Building the same five-endpoint API on both sides was a good way to feel out the OCaml ecosystem next to one I already know.

What I liked on the OCaml side, first, was the language itself. Type inference is excellent: in Scala you often have to annotate types outside of method bodies, while `bin/main.ml` has essentially no annotations and still reads clearly. I also liked that functions are naturally curried: partially applying one is just leaving off the last arguments, which is exactly what `handle_service_result req ~ok:`OK` does. Currying is doable in Scala too, but the ergonomics around it are a little bit meh — you reach for multiple parameter lists, explicit `_` placeholders or eta-expansion, and it never feels as effortless. I also enjoyed how `.mli` files made `Service.t` abstract for free, and how staying synchronous spared us any monad-transformer wrangling. Vif is more verbose and less mature than http4s, but easy to extend (the small `uuid_atom` combinator is a good example), and jsont is very explicit but pleasant to work with.

What I missed from Scala was mostly comfort: circe's `derives` saves a lot of boilerplate, http4s' pattern-matching DSL is hard to beat for readability, and the ecosystem around HTTP APIs is broader and more mature.

A natural next step is to swap the in-memory map for a real database, which is where the abstract `Service.t` starts to pay off. That will be for another part.

## Acknowledgements

A big thank you again to [@xvw](https://github.com/xvw) for pointing me at Vif and jsont, and for the OCaml guidance along the way.