---
title: "Building a Typesafe API in Scala with Tapir - Part 1: Defining Endpoints"
synopsis: In the age of AI, expressive languages and libraries that provide compile-time guarantees matter more than ever, and that's exactly why Tapir and Scala shine.
date: 2026-06-16
tags:
  - Scala
  - Functional Programming
  - Tapir
  - HTTP API
  - CRUD
---

## Introduction

We are writing more code than ever, and increasingly we are not the ones typing it. AI assistants generate endpoints, request handlers and data models in seconds, which is great until you realize that something has to catch the mistakes they make at scale. The cheapest place to catch a mistake is the compiler: if a wrong type, a missing field or a malformed response can be turned into a compile error, it never reaches production, whether a human or a model wrote it. This is where expressive languages with strong compile-time guarantees stop being an academic preference and start being a practical safety net. Scala is one of those languages, and Tapir is a library that pushes those guarantees all the way to the edges of your API.

If you are coming from Java, TypeScript or Go, the way Tapir models an API will probably feel unusual at first. In most frameworks an endpoint is a function annotated with a route, and the request, the response and the documentation are loosely connected at best, often only at runtime. Tapir takes a different stance: **an endpoint is a value**. You describe what an endpoint expects and what it returns as a plain, typed Scala value, completely separate from the logic that handles it. From that single description Tapir can derive the server, the client and the OpenAPI documentation, and the compiler guarantees they all agree with each other.

In this first part we will focus on the foundation: how to describe endpoints with Tapir. We will start from the smallest possible endpoint and progressively add inputs, outputs and error types until we have a complete, typesafe CRUD API, without writing a single line of server logic yet. Along the way we will see how to make illegal values unrepresentable using opaque types, and how the schemas Tapir derives from them carry validation and documentation all the way to the generated OpenAPI spec. Wiring those endpoints to an actual HTTP server and generating the documentation from them will come in a later part.

The example we will build throughout this series is a small task tracker: a CRUD API over a `Task` resource, with bearer-token authentication and proper error responses. By the end of this part we will have described every operation of that API as a value.

## The smallest possible endpoint

Everything in Tapir starts from a single value: `endpoint`. It describes an endpoint with no method, no inputs, no outputs and no errors. On its own it is useless, but it is the building block we refine into everything else:

```scala
import sttp.tapir.*

val base = endpoint
```

The type of `endpoint` already tells the whole story:

```scala
Endpoint[Unit, Unit, Unit, Unit, Any]
```

Those five type parameters are the shape of every Tapir endpoint, and they are worth memorizing because they show up everywhere:

```scala
Endpoint[SECURITY_INPUT, INPUT, ERROR_OUTPUT, OUTPUT, REQUIREMENTS]
```

 - `SECURITY_INPUT`: what the endpoint needs to authenticate the caller (a bearer token, an API key, nothing).
 - `INPUT`: what a successful request carries (path segments, query params, headers, a body).
 - `ERROR_OUTPUT`: what the endpoint returns when something goes wrong.
 - `OUTPUT`: what it returns on success.
 - `REQUIREMENTS`: the capabilities the server interpreter must provide (streaming, websockets); `Any` means "no special requirement".

Every method we call below does one thing: it takes an `Endpoint` and returns a new `Endpoint` with one of those type parameters refined. Defining an endpoint is just building up that type, one combinator at a time.

## Inputs, methods and outputs

Let's give the endpoint something to do. We will describe `GET /api/v1/tasks/{task-id}`, which returns a single task. We add a path, an HTTP method, and an output:

```scala
import sttp.tapir.*
import sttp.tapir.json.circe.*

val getTask =
  endpoint
    .in("api" / "v1" / "tasks")   // a fixed path prefix
    .in(path[TaskId]("task-id"))  // a typed path parameter
    .get                          // the HTTP method
    .out(jsonBody[Task])          // the success response body, as JSON
```

The inferred type is now:

```scala
Endpoint[Unit, TaskId, Unit, Task, Any]
```

Two things happened. The `INPUT` parameter became `TaskId` because we declared a typed path segment, and the `OUTPUT` parameter became `Task` because we declared a JSON body. We never wrote a parser or a serializer: `path[TaskId]` and `jsonBody[Task]` carry everything Tapir needs to read a `TaskId` out of the URL and to write a `Task` as JSON. We will see in a moment where those capabilities come from.

`.in(...)` composes. Each call appends to the input, and Tapir tracks the combined type for us. If an endpoint declares two path parameters and a query, the `INPUT` becomes a tuple of all three, in order. This is why you almost never pass the wrong argument to a handler: the handler's signature has to match the `INPUT` type exactly, or it does not compile.

## The resource: what is a task?

Before going further, let's pin down what a task actually is, since it is the resource every endpoint revolves around. It is a plain case class:

```scala
final case class Task(
    id: TaskId,
    title: Title,
    project: ProjectId,
    description: String,
    status: TaskStatus
) derives Schema, CirceCodec.AsObject
```

What stands out is that almost none of the fields are primitive types. The id is a `TaskId`, not a `UUID`; the title is a `Title`, not a `String`; the project is a `ProjectId`. Only `description` is a bare `String`, because any text is acceptable there. The status is an enum:

```scala
enum TaskStatus {
  case Backlog, Ready, InProgress, InReview, Done, Canceled, Duplicate
}
```

The `derives Schema, CirceCodec.AsObject` clause asks the compiler to generate the JSON codec and the documentation schema for the whole class, by combining the instances of each field's type. (`CirceCodec` is an alias for circe's `Codec`; the next section explains why we alias it.) That is why the field types matter so much: a `Schema` and a `Codec` for `Task` only exist if every field has them. The next section is about defining those field types so that they are not just distinct names, but values that cannot be invalid in the first place.

## Making illegal values unrepresentable

Notice that the path parameter is `path[TaskId]`, not `path[String]` or `path[UUID]`. This is deliberate, and it is where Scala starts pulling its weight.

A `TaskId` is not a `String` or a raw `UUID`; it is its own type. We define it as an **opaque type**, which gives us a distinct compile-time type that erases to `UUID` at runtime, so there is no wrapper allocation.

Before the code, a word on a naming clash you will hit immediately. We need two different `Codec` types here: circe's, which handles JSON, and Tapir's, which handles plain-text contexts like path segments. Both are called `Codec`, so importing both unqualified is ambiguous. We disambiguate them at the import site with aliases, and use those names everywhere after:

```scala
import java.util.UUID
import io.circe.{Codec as CirceCodec, Decoder, Encoder}
import sttp.tapir.{Codec as TapirCodec, Schema}
import sttp.tapir.CodecFormat.TextPlain

opaque type TaskId = UUID
object TaskId {
  def apply(id: UUID): TaskId = id

  given Schema[TaskId] = Schema.schemaForUUID
  given CirceCodec[TaskId] = CirceCodec.from(Decoder.decodeUUID, Encoder.encodeUUID)
  given TapirCodec[String, TaskId, TextPlain] = TapirCodec.uuid
}
```

The payoff is that a `TaskId` can never be confused with a `ProjectId` or an arbitrary string, even though both are "just a UUID" or "just a string" underneath. A function expecting a `TaskId` will reject a `ProjectId` at compile time. The `given` instances are how Tapir knows what to do with the type:

 - `Schema[TaskId]` describes its shape for documentation and validation.
 - `CirceCodec[TaskId]` handles JSON.
 - `TapirCodec[String, TaskId, TextPlain]` handles plain-text contexts like path segments and query parameters, which is exactly what `path[TaskId]` needs.

Some types are more than just a distinct name: they have rules. A project id is always three or four uppercase letters, and a task title is a non-blank string of at most 100 characters. We encode those rules in the constructor so that an invalid value cannot exist, and we put the same rule in the `Schema` so it shows up in the documentation and is enforced when decoding:

```scala
opaque type ProjectId = String
object ProjectId {
  private val pattern = "^[A-Z]{3,4}$".r

  def from(value: String): Either[String, ProjectId] =
    if (pattern.matches(value)) Right(value)
    else Left(s"'$value' is not a valid project id: expected 3-4 uppercase letters")

  extension (p: ProjectId) def value: String = p

  given schema: Schema[ProjectId] =
    Schema.schemaForString
      .description("Project identifier: 3-4 uppercase letters")
      .validate(Validator.pattern("^[A-Z]{3,4}$"))

  // decode by running `from`, so a bad value is rejected before it ever reaches your code
  given TapirCodec[String, ProjectId, TextPlain] =
    TapirCodec.string.mapEither(from)(_.value).schema(schema)
}
```

The constructor returns `Either[String, ProjectId]` rather than a `ProjectId`, which means the only way to obtain one is to go through the validation. The Tapir codec is built with `mapEither(from)`, so when a request arrives with `project=abc`, Tapir runs `from`, gets a `Left`, and turns it into a `400 Bad Request` before your handler is ever called. The validity of a `ProjectId` is guaranteed by construction, so the rest of the codebase never has to check it again. This is the "make illegal states unrepresentable" idea applied at the very edge of the system, where the untrusted input comes in.

## Modeling errors as data

So far our endpoints can only succeed. Real endpoints fail, and Tapir makes you describe how. The `ERROR_OUTPUT` type parameter is where the failure modes live, and the trick is that they are just data, the same as the success output.

We start by modeling each failure as a case class, paired with the status code it maps to:

```scala
final case class NotFound(entity: String, id: String, message: String) derives Schema, CirceCodec.AsObject
val oneOfNotFound =
  oneOfVariant(statusCode(StatusCode.NotFound).and(jsonBody[NotFound]))

final case class BadRequest(field: String, message: String) derives Schema, CirceCodec.AsObject
val oneOfBadRequest =
  oneOfVariant(statusCode(StatusCode.BadRequest).and(jsonBody[BadRequest]))

final case class Unauthorized(message: String) derives Schema, CirceCodec.AsObject
val oneOfUnauthorized =
  oneOfVariant(statusCode(StatusCode.Unauthorized).and(jsonBody[Unauthorized]))

final case class InternalServerError(message: String) derives Schema, CirceCodec.AsObject
val oneOfInternalServerError =
  oneOfVariant(statusCode(StatusCode.InternalServerError).and(jsonBody[InternalServerError]))
```

Each `oneOfVariant` pairs an error body with a status code. The `derives Schema, CirceCodec.AsObject` clause asks the compiler to generate the JSON codec and the schema for free, the same automatic derivation we covered in the [typeclass derivation article](/articles/scala_automatic_derivation).

Now, which errors can a given operation actually produce? A read can fail with `NotFound`, but never with `Conflict`; a create can hit a `Conflict`, but never a `NotFound`. Scala 3 lets us express that precisely with a **union type**, listing exactly the failures an operation admits:

```scala
type GetError    = NotFound | Unauthorized | InternalServerError
type CreateError = BadRequest | Conflict | Unauthorized | InternalServerError
type UpdateError = NotFound | BadRequest | Unauthorized | InternalServerError
type DeleteError = NotFound | Unauthorized | InternalServerError
type ListError   = BadRequest | Unauthorized | InternalServerError
```

This is more than documentation. When we later write a handler for the get endpoint, its error channel has type `GetError`, so returning a `Conflict` from it simply will not compile. The set of failures is part of the endpoint's type, and the compiler holds us to it.

We attach the error union to an endpoint with `errorOut` and a `oneOf`, which lists the variants Tapir should consider:

```scala
val getTask =
  endpoint
    .in("api" / "v1" / "tasks")
    .in(path[TaskId]("task-id"))
    .get
    .errorOut(oneOf[GetError](oneOfNotFound, oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[Task])
```

The type is now `Endpoint[Unit, TaskId, GetError, Task, Any]`. Every piece of the contract, the input, the success output, and the full set of error outputs, lives in that one type.

## Authentication and a shared base

Every task operation in our API requires a bearer token, sits under the same `/api/v1/tasks` prefix, and is grouped under the same documentation tag. Rather than repeat that on every endpoint, we capture it once in a base value and refine from there:

```scala
val basePath = "api" / "v1" / "tasks"

val baseSecureEndpoint =
  endpoint
    .in(basePath)
    .securityIn(auth.bearer[String]())  // sets SECURITY_INPUT to String
    .tag("Tasks")                       // groups operations in the docs
```

`securityIn` populates the first type parameter, `SECURITY_INPUT`, separately from the regular input. Tapir keeps authentication inputs distinct from business inputs on purpose: a server interpreter runs the security logic first and only calls your handler if it succeeds. We will use that separation in the next part when we attach the actual authentication logic. For now it is enough that the requirement is recorded in the type.

To keep the per-endpoint definitions readable, we give the refined endpoint type an alias:

```scala
type SecuredEndpoint[INPUT, ERROR_OUTPUT, OUTPUT, -R] =
  Endpoint[String, INPUT, ERROR_OUTPUT, OUTPUT, R]
```

## Putting it together: the full CRUD API

With the base endpoint, the validated types and the error model in place, each operation is a short, declarative description. Here is the complete set.

Create takes a JSON body and returns the id of the new task with a `201`:

```scala
val create: SecuredEndpoint[CreateTask, CreateError, TaskCreated, Any] =
  baseSecureEndpoint
    .name("createTask")
    .summary("Create a task")
    .post
    .in(jsonBody[CreateTask])
    .errorOut(oneOf[CreateError](oneOfBadRequest, oneOfConflict, oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[TaskCreated])
    .out(statusCode(StatusCode.Created))
```

Get reads a single task by its path id:

```scala
val get: SecuredEndpoint[TaskId, GetError, Task, Any] =
  baseSecureEndpoint
    .name("getTask")
    .summary("Get a task by id")
    .in(path[TaskId]("task-id"))
    .get
    .errorOut(oneOf[GetError](oneOfNotFound, oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[Task])
    .out(statusCode(StatusCode.Ok))
```

Update combines a path id and a JSON body, so its `INPUT` is the tuple `(TaskId, UpdateTask)`:

```scala
val update: SecuredEndpoint[(TaskId, UpdateTask), UpdateError, Task, Any] =
  baseSecureEndpoint
    .name("updateTask")
    .summary("Update a task")
    .in(path[TaskId]("task-id"))
    .put
    .in(jsonBody[UpdateTask])
    .errorOut(oneOf[UpdateError](oneOfNotFound, oneOfBadRequest, oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[Task])
    .out(statusCode(StatusCode.Ok))
```

Delete has no success body, only a `204`:

```scala
val delete: SecuredEndpoint[TaskId, DeleteError, Unit, Any] =
  baseSecureEndpoint
    .name("deleteTask")
    .summary("Delete a task")
    .in(path[TaskId]("task-id"))
    .delete
    .errorOut(oneOf[DeleteError](oneOfNotFound, oneOfUnauthorized, oneOfInternalServerError))
    .out(statusCode(StatusCode.NoContent))
```

List takes two optional query parameters and returns a list of tasks. Because they are `Option`, omitting them is valid, and the `INPUT` is `(Option[ProjectId], Option[TaskStatus])`:

```scala
val list: SecuredEndpoint[(Option[ProjectId], Option[TaskStatus]), ListError, List[Task], Any] =
  baseSecureEndpoint
    .name("listTasks")
    .summary("List tasks")
    .get
    .in(query[Option[ProjectId]]("project"))
    .in(query[Option[TaskStatus]]("status"))
    .errorOut(oneOf[ListError](oneOfBadRequest, oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[List[Task]])
    .out(statusCode(StatusCode.Ok))
```

Finally we collect them, which is the single list a server or a docs generator will consume in the next part:

```scala
val all = List(create, get, update, delete, list)
```

That is the entire API, described as five values. There is not a single line of routing, parsing, serialization or validation logic in it, yet the contract is complete and fully typed: the inputs, the outputs, the errors and the security requirement are all encoded in the types, and the compiler will reject any handler that does not honor them.

## Adding documentation

Because an endpoint is a value, documentation is not a separate annotation layer that can drift from the code: it is more data attached to the same description. We have already seen `.summary` and `.description` on the operations; the fields of our case classes can carry the same metadata through schema annotations:

```scala
final case class CreateTask(
    @description("Short, human-readable title of the task")
    @encodedExample("Implement task filtering")
    title: Title,
    @description("Project the task belongs to")
    @encodedExample("TSK")
    project: ProjectId,
    @description("Detailed description of what the task involves")
    description: String,
    @description("Initial status of the task")
    status: TaskStatus
) derives Schema, CirceCodec.AsObject
```

These annotations feed the derived `Schema`, and since the OpenAPI document is generated from those same schemas, the descriptions, examples and the validation rules we baked into `ProjectId` and `Title` all surface in the spec automatically. The documentation cannot describe a field that does not exist, or claim a type the code does not actually accept, because it is computed from the very values that define the endpoints. That single-source-of-truth property is the whole reason to model an endpoint as a value, and it is what we will cash in when we generate the server and the OpenAPI document in the next part.

## What's next

We now have a complete, typesafe description of our task API, built entirely from values and types, with validation and documentation carried by the types themselves. We have written no server, no handlers and no JSON plumbing, yet nothing about the contract is left implicit.

In the next part we will give these endpoints a life: connecting them to handlers backed by Cats Effect, running them on an http4s server, wiring up the authentication we hinted at, and generating the OpenAPI document from the very same definitions. Because the contract already lives in the types, the compiler will be the one making sure our implementation actually matches the API we just designed.
