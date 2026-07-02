---
title: "Building a Typesafe API in Scala with Tapir - Part 2: Serving Endpoints"
synopsis: From a pure description of an API to a running server. We wire Tapir endpoints to handlers backed by Cats Effect, run them on http4s, plug in bearer-token authentication, and generate the OpenAPI document from the very same definitions.
date: 2026-06-27
tags:
  - Scala
  - Functional Programming
  - Tapir
  - HTTP API
  - CRUD
---


## Introduction

In part 1 we wrote a complete, typed description of a CRUD API and saw the promise of [Tapir](https://tapir.softwaremill.com/): **an endpoint is a value**, a single description we can derive documentation, a client and a server from. In this part we cash that in. From the contract we defined, we implement handlers → auth → an http4s server → the OpenAPI document → a client, every step validated by the compiler against the types, so the implementation cannot drift from the contract. We lean on [Cats Effect](https://typelevel.org/cats-effect/) for IO, [http4s](https://http4s.org/) for the server, [doobie](https://typelevel.org/doobie/) over Postgres for persistence and [jwt-scala](https://jwt-scala.github.io/jwt-scala/) for the tokens to wire it all together.


## From an endpoint to a server endpoint

In part 1 we defined the endpoint as a value, for example the `get` endpoint has this signature:

```scala
val get: SecuredEndpoint[TaskId, GetError, Task, Any] = ...
```
where each type on the `SecuredEndpoint` defines what we have to implement for the handler. Because we previously defined `SecuredEndpoint` this way:

```scala
type SecuredEndpoint[INPUT, ERROR_OUTPUT, OUTPUT, -R] =
  Endpoint[String, INPUT, ERROR_OUTPUT, OUTPUT, R]
```

Reading off the type parameters, `INPUT = TaskId`, `ERROR_OUTPUT = GetError` and `OUTPUT = Task`. The leading `String` is the `SECURITY_INPUT`: the raw bearer token, which we resolve into an authenticated `User` before the handler runs. So the handler is a function shaped like this:

```scala
type GetHandler = User => TaskId => F[Either[GetError, Task]]
```
where **F** is the effect type we chose, here `IO`, giving `User => TaskId => IO[Either[GetError, Task]]`.

That signature is what makes the contract enforceable. `GetError` is the closed union from part 1:
```scala
type GetError = NotFound | Unauthorized | InternalServerError
```
so returning `Left(Conflict(...))` won't compile, because `Conflict` isn't one of those variants. Nor will `Right(taskId)`, because the success type is `Task`, not `TaskId`. The endpoint's type dictates exactly what the handler may return.

## The service: business logic, free of HTTP

Now we can dive into the domain logic of our system, so we create a new trait called `TaskService` where we include all the methods we want to expose through HTTP, because the handler of each endpoint expects:

```scala
type HandlerFunction[Input, Output, Error] = User => Input => IO[Either[Error, Output]]
```

so each function will look like:
```scala
def myHandler(user: User)(input: Input): IO[Either[Error, Output]] = ???
```

Here is how our trait will be defined:

```scala
trait TaskService {
  def get(user: User)(taskId: TaskId): IO[GetResult[Task]]
  def create(user: User)(task: CreateTask): IO[CreateResult[TaskCreated]]
  def update(user: User)(input: (TaskId, UpdateTask)): IO[UpdateResult[Task]]
  def delete(user: User)(taskId: TaskId): IO[DeleteResult[Unit]]
  def list(user: User)(filter: (Option[ProjectId], Option[TaskStatus])): IO[ListResult[List[Task]]]
}
```

We can see that for `get` we return `IO[GetResult[Task]]` (a type alias we will define in a moment) instead of `IO[GetResult[Option[Task]]]`, so the service will return an error if the task doesn't exist, because for now the only consumer of this method is the handler. Depending on our needs we could update this method to return an `Option` instead, or let the consumer of the method recover from the `NotFound` error to do whatever it wants, even if in terms of developer experience that is more cumbersome. Also, for `update` and `list` we have a tuple because it's the shape the handler expects, but it could be better to split the tuple into two named parameters, or just use the named tuples available since Scala 3.7.
Because we want all our endpoints to have a specific shape, we define a type alias for the result that for example looks like this for `GetResult`:

```scala
type GetResult[A] = Either[GetError, A]
```

And here is how it will be defined. Because the data is stored in a DB, we delegate the call to a repository, and as we said earlier the repository could return an `Option`, but the service adapts this response to send an error in the case of `None`:


```scala
object TaskService {

  private val entity = "task"

  def apply(repository: TaskRepository): TaskService = new TaskService {

    def get(user: User)(taskId: TaskId): IO[GetResult[Task]] =
      repository.find(taskId).map(_.toRight(notFound(entity, taskId.toString)))

    def create(user: User)(task: CreateTask): IO[CreateResult[TaskCreated]] =
      for {
        id <- IO.delay(TaskId(UUID.randomUUID()))
        _  <- repository.insert(Task(id, task.title, task.project, task.description, task.status))
      } yield Right(TaskCreated(id))

    def update(user: User)(input: (TaskId, UpdateTask)): IO[UpdateResult[Task]] =
      val (taskId, changes) = input
      val updated = Task(taskId, changes.title, changes.project, changes.description, changes.status)
      repository.update(updated).map {
        case true  => Right(updated)
        case false => Left(notFound(entity, taskId.toString))
      }

    def delete(user: User)(taskId: TaskId): IO[DeleteResult[Unit]] =
      repository.delete(taskId).map {
        case true  => Right(())
        case false => Left(notFound(entity, taskId.toString))
      }

    def list(user: User)(filter: (Option[ProjectId], Option[TaskStatus])): IO[ListResult[List[Task]]] =
      val (project, status) = filter
      repository.list(project, status).map(Right(_))
  }
}
```

## Persistence with doobie

Because the repository will have its own article, here is just a snippet showing what the trait looks like, so we can better understand how it's called in the service layer, and how we implement the `find` method. We use doobie to call PostgreSQL, where the connection, or the connection pool depending on what we choose, is internally the `Transactor[IO]`. We will dig into doobie, the `Meta`/`Read`/`Write` instances, fragments and the `Transactor` in part 3.

```scala
trait TaskRepository {
  def insert(task: Task): IO[Unit]
  def find(id: TaskId): IO[Option[Task]]
  def update(task: Task): IO[Boolean]
  def delete(id: TaskId): IO[Boolean]
  def list(project: Option[ProjectId], status: Option[TaskStatus]): IO[List[Task]]
}

object TaskRepository {

  def apply(xa: Transactor[IO]): TaskRepository = new TaskRepository {

    def find(id: TaskId): IO[Option[Task]] =
      sql"SELECT id, title, project, description, status FROM tasks WHERE id = $id"
        .query[Task]
        .option
        .transact(xa)

    // insert, update, delete, list ...
  }
}
```

And because we use an opaque type for `TaskId`, doobie needs to know how it should interpret it, so we define a `Meta[TaskId]` that describes the mapping doobie and the underlying JDBC driver will use.


```scala
object TaskId {
  given Schema[TaskId] = Schema.schemaForUUID
  given Codec[TaskId] = Codec.from(Decoder.decodeUUID, Encoder.encodeUUID)
  given TapirCodec[String, TaskId, TextPlain] = TapirCodec.uuid
  given Meta[TaskId] = Meta[UUID].imap(apply)(identity)
}
```

With this last given, the same opaque type now serves every layer: a `Schema` for the docs, a circe `Codec` for JSON, a Tapir `Codec` for the path and query, and a `Meta` for the database column. The value travels from the URL to the handler down to the SQL row without ever being a bare `UUID` or `String` in between.

## Authentication as a reusable seam

In part 1 we saw that `securityIn` set `SECURITY_INPUT = String`, which is a bare token, and that in our service layer we don't care about the token: we want the authenticated user instead, without having to manage anything around the token. Tapir allows us, when we describe a handler, to have a specific handler just for the security part. Our security handler will look like this:

```scala
type Security = String => IO[Either[Unauthorized, User]]
```
and to have something reusable across all of our codebase, we will define an extension method that will allow us, when we declare all of our handlers, to do

```scala
myEndpoint.authenticated.serverLogic(myHandler)
```
so here is the declaration of our extension method:

```scala
extension [INPUT, OUTPUT, E >: Unauthorized, R](e: Endpoint[String, INPUT, E, OUTPUT, R])
  def authenticated(using security: Security): PartialServerEndpoint[String, User, INPUT, E, OUTPUT, R, IO] =
    e.serverSecurityLogic(token => security(token).map(_.left.map(identity[E])))
```

It may not be that easy to read at first, so here is how it reads. We create an extension method parametrized by `INPUT` and `OUTPUT`, which are the input and output of our endpoint. Then comes the error type, `E >: Unauthorized`, which means our error union must contain `Unauthorized`: you literally cannot call `.authenticated` on an endpoint that hasn't declared the 401 it can now return. Finally `R` is the capabilities of the endpoint; in our case there are none, so it will be `Any`.

The method `authenticated` expects a `Security` handler, the one we defined earlier, and returns a `PartialServerEndpoint[String, User, INPUT, E, OUTPUT, R, IO]`. It is an endpoint where we have defined the security part but not the business part yet, hence the word `Partial`. The first two type parameters are the `SECURITY_INPUT` (`String`, the raw token) and the resolved principal (`User`), which `serverSecurityLogic` produces from that token. That resolved `User` is exactly what gets handed to the business handler next, which is why every `TaskService` method is curried as `(user)(input)`.

So far `Security` is just a type; the concrete implementation is `authenticate`, which decodes the bearer token, checks its signature, and resolves the `sub` claim back into a `User`:

```scala
def authenticate(token: String): IO[Either[Unauthorized, User]] =
  IO.delay(JwtCirce.decode(token, config.jwtSecret, Seq(Algorithm))).map {
    case Success(claim) =>
      claim.subject.filter(_.nonEmpty).toRight(unauthorized()).map(User.apply)
    case Failure(_) =>
      Left(unauthorized())
  }
```

Verification is stateless: it only checks the signature and the standard claims, with no database lookup, so a token stays valid until it expires. Notice its signature matches `Security` exactly, which is what lets us plug it in as the `given Security` later.


## Wiring the routes

And now all the effort we put into declaring everything earlier pays off, when we declare the server implementation of our endpoints:

```scala
final class Endpoints(service: TaskService)(using Security) {

  val routes: List[ServerEndpoint[Any, IO]] = List(
    EndpointDefinitions.create.authenticated.serverLogic(service.create),
    EndpointDefinitions.get.authenticated.serverLogic(service.get),
    EndpointDefinitions.update.authenticated.serverLogic(service.update),
    EndpointDefinitions.delete.authenticated.serverLogic(service.delete),
    EndpointDefinitions.list.authenticated.serverLogic(service.list)
  )
}
```
So it's fairly easy: for every endpoint we take the definition, call our extension method `.authenticated`, then hand it the matching handler with `.serverLogic(service.myHandler)`. The methods are passed by eta-expansion, as bare `service.create`, `service.get` and so on, not called. And this list compiles only because each service method already has the curried `(user)(input)` shape that `serverLogic` expects: a wrong error union, a wrong input tuple or the wrong currying would not compile. This is where all the type promises from part 1 get cashed in at once.

This class lives in the task package as `Endpoints`; the auth feature has its own `Endpoints` too. Later sections refer to them package-qualified as `TaskEndpoints` and `AuthEndpoints` to tell the two apart.

## The token endpoint

Every task endpoint demands a bearer token, so we need one endpoint that hands them out. This is the one public route in the whole API: no security input, no `.authenticated`, just credentials in the body. Its request is a user's email and password:

```scala
final case class TokenRequest(
    @description("Email identifying the user")
    @encodedExample("admin@gilwath.com")
    email: String,
    @description("The user's password")
    @encodedExample("admin")
    password: String
) derives Schema, CirceCodec.AsObject
```

And it will return a response with the token inside:

```scala
final case class TokenResponse(
    @description("Signed JWT bearer token to send in the Authorization header of subsequent requests")
    @encodedExample("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbkBnaWx3YXRoLmNvbSJ9.signature")
    token: String,
    @description("Number of seconds from issuance after which the token expires")
    @encodedExample("3600")
    expiresInSeconds: Long
) derives Schema, CirceCodec.AsObject
```

The endpoint definition itself is just another value, nothing new combinator-wise:

```scala
val createToken: Endpoint[Unit, TokenRequest, TokenError, TokenResponse, Any] =
  endpoint
    .in("api" / "v1" / "token")
    .name("createToken")
    .summary("Issue an access token")
    .description("Validates the supplied email and password and returns a signed JWT bearer token.")
    .tag("Authentication")
    .post
    .in(jsonBody[TokenRequest])
    .errorOut(oneOf[TokenError](oneOfUnauthorized, oneOfInternalServerError))
    .out(jsonBody[TokenResponse])
    .out(statusCode(StatusCode.Ok).description("Token issued"))
```

Now we can wire the logic that issues the token. We call `AuthService.issueToken`, which takes an email and password, validates them, and mints a token carrying the user's information; for this example we don't care how it's implemented, but you can imagine it looking up the user in the database and checking the password. Note that the route uses plain `serverLogic`, with no `.authenticated`, because this endpoint is public, unlike the task routes:

```scala
final class Endpoints(auth: AuthService) {

  private def issueToken(request: TokenRequest): IO[TokenResult[TokenResponse]] =
    auth.issueToken(Credentials(request.email, request.password)).map {
      _.map(token => TokenResponse(token.token, token.expiresInSeconds))
    }

  val routes: List[ServerEndpoint[Any, IO]] =
    List(EndpointDefinitions.createToken.serverLogic(issueToken))
}
```


## Running it on http4s

Now we can wire everything together into a server, using http4s. First we create a `routes` method that takes our `TaskService` and `AuthService` and returns an `HttpRoutes[IO]`. Nothing fancy: as we saw earlier, `TaskEndpoints` needs a `given Security` in scope, so we provide it with `given Security = auth.authenticate`, the verification method from the previous section. This is the moment the security seam resolves: the abstract `Security` type finally meets its concrete implementation. The rest is just calling Tapir's interpreter to produce the http4s routes.

```scala
private def routes(service: TaskService, auth: AuthService): HttpRoutes[IO] =
  given Security = auth.authenticate
  Http4sServerInterpreter[IO]().toRoutes(AuthEndpoints(auth).routes ++ TaskEndpoints(service).routes)
```

Then we declare the entry point as a `Main` object extending `IOApp`, the trait that lets us express our whole program as an `IO`. We build the http4s server with `EmberServerBuilder` and assemble the dependencies in a single `Resource` for-comprehension: the database connection pool, the seeded user, the services and the server itself. `Resource` is how Cats Effect manages things that must be acquired and later released, like a socket or a file handle, running the finalizer regardless of the outcome of the action. So every dependency is acquired on startup and released cleanly on shutdown, living exactly as long as the application does.

```scala
object Main extends IOApp {

  private def server(service: TaskService, auth: AuthService): Resource[IO, Server] =
    EmberServerBuilder
      .default[IO]
      .withHost(host"0.0.0.0")
      .withPort(port"8080")
      .withHttpApp(routes(service, auth).orNotFound)
      .build

  private def application: Resource[IO, Server] =
    val authConfig = AuthConfig.fromEnv(sys.env)
    for {
      xa <- Database.transactor(DbConfig.fromEnv(sys.env))
      users = UserRepository(xa)
      _ <- Resource.eval(UserRepository.seed(users, authConfig))
      auth = AuthService(users, authConfig)
      srv <- server(TaskService(TaskRepository(xa)), auth)
    } yield srv

  override def run(args: List[String]): IO[ExitCode] =
    application.use(_ => IO.never).as(ExitCode.Success)
}
```

Now it actually runs. Start Postgres with `docker compose up -d`, launch the app with `sbt run`, and the server listens on port 8080. We can then run a simple test with curl: get a token, then use it to create a task.

```bash
TOKEN=$(curl -s localhost:8080/api/v1/token \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@gilwath.com","password":"admin"}' | jq -r .token)

curl -s localhost:8080/api/v1/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Write part 2","project":"TSK","description":"Serve the endpoints","status":"InProgress"}'
```

The interesting part is what we did *not* write. Send a malformed `project` and you get a `400` before any handler runs, straight from the `ProjectId` codec we defined in part 1. Drop the `Authorization` header and you get a `401`, because the security stage runs first. None of this is handler code: it falls out of the descriptions.


## Generating the OpenAPI document

Tapir doesn't only let us create a server; as we saw in part 1, we can also generate the documentation from the same endpoints. We could add a dedicated main just to emit the OpenAPI, or generate it at runtime and let the server serve it. For our example we create a new main where we feed in everything needed to write the `openapi.yaml` file. The code is fairly simple: we aggregate all of our API definitions, the exact same values the server runs on, and hand them to `OpenAPIDocsInterpreter` to produce the document.

```scala
object GenerateOpenApiDocs extends IOApp {

  private val info = Info(
    title = "Tasks API",
    version = "1.0.0",
    description = Some("HTTP API for creating, retrieving, updating, deleting and listing tasks. ...")
  )

  override def run(args: List[String]): IO[ExitCode] =
    val output = Paths.get(args.headOption.getOrElse("openapi.yaml"))
    val endpoints = AuthEndpoints.all ++ TaskEndpoints.all
    val docs = OpenAPIDocsInterpreter().toOpenAPI(endpoints, info)
    IO.blocking(Files.writeString(output, docs.toYaml)).as(ExitCode.Success)
}
```
And we add a task to our sbt build so we can regenerate the document on demand:

```scala
generateOpenApiDocs := (Compile / runMain)
  .toTask(" com.gilwath.docs.GenerateOpenApiDocs")
  .value
```

Change an endpoint, run `sbt generateOpenApiDocs`, and the doc follows the code.

Here is a slice of the generated `openapi.yaml`, the `GET /api/v1/tasks/{task-id}` operation:

```yaml
/api/v1/tasks/{task-id}:
  get:
    tags:
    - Tasks
    summary: Get a task by id
    description: Retrieves a single task by its unique identifier.
    operationId: getTask
    parameters:
    - name: task-id
      in: path
      description: Unique identifier of the task
      required: true
      schema:
        type: string
        format: uuid
      example: 3f1c0d2a-9b6e-4c8a-bf2d-1e5a7c9d0b34
    responses:
      '200':
        description: The requested task
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Task'
      '404':
        description: not found
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/NotFound'
      '401':
        description: unauthorized
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Unauthorized'
    security:
    - httpAuth: []
```

Nothing here was written by hand. The path, the `uuid` format and its example, the `404`/`401` variants of `GetError` turned into documented responses, and the bearer auth surfacing as a `security` scheme all fall out of the endpoint value. The validation rules from part 1 come through too, so the `project` field in the referenced `Task` schema keeps its `pattern: ^[A-Z]{3,4}$` and `title` its `minLength`/`maxLength`. The document cannot lie about the API, because it is computed from the very same values the server runs.

## Deriving a type-safe client

And the final promise is to get the HTTP client for free from the same definitions. We hand the endpoint we want to call to `SttpClientInterpreter`, and it builds the request for us. Here we keep the client backend-agnostic: rather than returning a function that needs a backend, each method turns an endpoint into a plain [sttp](https://sttp.softwaremill.com/) `Request`, which the caller runs against whatever backend they have with `request.send(backend)`.

```scala
final class Client(baseUri: Uri) {

  private val interpreter = SttpClientInterpreter()

  def get(token: String, taskId: TaskId): Request[DecodeResult[GetResult[Task]], Any] =
    interpreter
      .toSecureRequest(EndpointDefinitions.get, Some(baseUri))
      .apply(token)
      .apply(taskId)
}
```

Because `get` is a secured endpoint, we use `.toSecureRequest`: the security input (the token) is supplied first, then the endpoint input (the task id). This mirrors the server exactly, where the security stage took the token before the handler saw the `TaskId`. The result type says the rest: `Request[DecodeResult[GetResult[Task]], Any]`. Sending it yields one of the endpoint's `GetResult` outcomes, the task or a decoded `NotFound | Unauthorized | InternalServerError`, wrapped in a `DecodeResult` that is a `Failure` only if the wire response can't be decoded against the contract at all. The client is checked against the same contract at compile time, so if the endpoint's input, output or error types change, both the server handler and every client call site stop compiling. No hand-written request building, no response parsing, no separate codegen step to rerun.


## What's next

What we saw here is close to what I write on a daily basis: basic Tapir, but not far from a real project. There is more to explore, and the next part is already decided. In this article doobie was a black box; part 3 opens it properly. We will look at the `Transactor` and the HikariCP connection pool as a `Resource`, the `Meta`/`Read`/`Write` instances and how the opaque types and the `TaskStatus` enum map to columns, the `sql` interpolator with its checked queries and `Fragment` composition for the dynamic `WHERE` in `list`, and how database outcomes map back to the domain. It completes the "one type, every layer" story the series has been telling: the same opaque types that gave us typed paths and typed JSON will give us typed columns, so a value is never a bare `String` or `UUID` from the URL all the way down to the row.

Beyond that, a few directions could each earn their own article, depending on interest. Tapir has a concept of **interceptors**, found in most HTTP server libraries, that runs arbitrary code before and after a request reaches an endpoint: logging, tracing with [OpenTelemetry](https://opentelemetry.io/), metrics, global error handling. Because endpoints are just values in a list, an interceptor applies to every one of them uniformly. There is **testing**, where Tapir's stub server interpreter lets us exercise the logic without opening a port, paired with the derived client for in-process round-trips, and [Testcontainers](https://testcontainers.com/) for the parts that need a real database. We could also **serve the docs** we generate, mounting [Swagger UI](https://swagger.io/tools/swagger-ui/) or [Redoc](https://redocly.com/redoc) at `/docs`. And there is auth hardening: bcrypt, asymmetric signing, the `Forbidden`/403 we defined but never used, the corners the demo cut on purpose.


## Conclusion

Part 1 turned an empty endpoint into five fully typed descriptions with no behavior at all. Part 2 added the behavior without ever restating the contract, and at every step the compiler checked that the two lined up:

- the handlers match the endpoints, because the endpoint's types dictate the handler's signature;
- auth attaches only where `Unauthorized` was declared, so you cannot bolt a 401 onto an endpoint that never promised one;
- the routes wire together only because the curried `(user)(input)` service shape mirrors Tapir's security-then-business staging;
- the OpenAPI document and the sttp client are computed from the very same values the server runs, so neither can drift from it.

That is the whole idea: the contract is written once, in types, and everything else is derived from it and checked by the compiler. The cheapest place to catch a mistake is the compiler, and here it does it for free.

The complete, runnable project is on [GitHub](https://github.com/bthuillier/tapir-cats-presentation).
