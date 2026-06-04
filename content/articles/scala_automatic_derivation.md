---
title: "Automatic Typeclass Derivation in Scala 3"
synopsis: Building a Debuggable typeclass from scratch and teaching the Scala 3 compiler to derive it for any case class or enum, using Mirror and inline metaprogramming.
date: 2026-06-04
tags:
  - Scala
  - Functional Programming
  - Metaprogramming
  - Typeclasses
---

## Introduction

In this article I will explain how you can leverage the automatic derivation of Scala 3 to build your own typeclass instances. Scala does have typeclasses, but they are not implemented the way Haskell does it: Haskell bakes typeclasses into the language as a first-class construct, whereas in Scala a typeclass is just a pattern built on top of `trait` and `given` instances. If anything, the Scala encoding is closer to OCaml's modular implicits, where instances are values you pass around (explicitly or implicitly) rather than a built-in language feature. But what is a typeclass in Scala? If we refer to the documentation:

> A type class is an abstract, parameterized type that lets you add new behavior to any closed data type without using sub-typing. If you are coming from Java, you can think of type classes as something like `java.util.Comparator[T]`.

A type class is useful in multiple use cases, for example:

 - Expressing how a type you don’t own (from the standard library or a third-party library) conforms to such behavior
 - Expressing such a behavior for multiple types without involving sub-typing relationships between those types

So in our example we have a case class and an enum defined here:
```scala
case class Person(name: String, age: Int)

enum Shape:
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
```

And we want a `debug` method that returns a string representation of this case class/enum like the example below, instead of the representation provided by the default `.toString` method. Note that the type name is lowercased in the output (`Person` becomes `person`, `Circle` becomes `circle`); we will handle that transformation later in the derivation.

```scala
Person("Alice", 30).debug          // person{name=Alice, age=30}
(Shape.Circle(1.5): Shape).debug   // circle{radius=1.5}
```

The goal is that we never have to hand-write a `Debuggable` instance for `Person` or `Shape`. Instead, we just add `derives Debuggable` to their definition and let the compiler generate the instance for us:

```scala
case class Person(name: String, age: Int) derives Debuggable

enum Shape derives Debuggable:
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
```

This is what "automatic derivation" means, and the rest of the article is about teaching the compiler how to do it.

## The typeclass

So we will create a trait `Debuggable[T]`, where `T` in our case will be `Person` or `Shape`. Here is how we define it:

```scala
trait Debuggable[T] {
  extension (x: T) def debug: String
}
```
As you can see we add `extension (x: T) def debug: String`. This is how we will be able to call a `.debug` method directly on our classes.

When we use automatic derivation in Scala, the compiler won't be able to generate instances automatically for some key primitive types like `String`, `Boolean` and `Int`, nor for conditional instances like `List`, `Map` and `Option`, because none of them expose a `Mirror` we can recurse into, so we will have to define these instances ourselves. For the primitive types we declare instances like this:

```scala
given Debuggable[Int] with
  extension (x: Int) def debug: String = x.toString

given Debuggable[String] with
  extension (x: String) def debug: String = x
// ... Byte, Short, Long, Float, Double, BigInt, BigDecimal, UUID likewise

```
and for type like List we will define instance conditioned by the availability of the instance of the type of the list using `given[T](using d: Debuggable[T])`
```scala
given [T](using d: Debuggable[T]): Debuggable[List[T]] with
  extension (x: List[T]) def debug: String =
    x.map(_.debug).mkString("[", ", ", "]")

given [T](using d: Debuggable[T]): Debuggable[Option[T]] with
  extension (x: Option[T]) def debug: String = x match
    case Some(v) => s"${v.debug}"
    case None    => "none"
```

## Now let's use `derives`

In Scala if we want to use the automatic derivation using `derives Debuggable` on our case class for example it's mean for the compiler that it will call to `Debuggable.derived[T]` given a `Mirror.Of[T]` where a `Mirror` in scala in the description of the type shape that could be either a `Mirror.Product` so case class, objects or enums case or `Mirror.Sum` so sealed class or traits with product children

```scala
inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] = ???
```

## `inline`: recursion that runs in the compiler

The `Mirror` gives us the shape of our type, but it gives it to us as *types*, not values. For `Person`, `m.MirroredElemTypes` is the tuple **type** `(String, Int)`, and `m.MirroredElemLabels` is `("name", "age")` (a tuple of singleton-string types). To actually build a `Debuggable[Person]` we need runtime values: one `Debuggable` instance per field, and the field names as ordinary `String`s. So we have to bridge the gap between the type level and the value level, and we do it at compile time.

This is what `inline` is for. An `inline def` is expanded by the compiler at the call site rather than being called at runtime, and inside one we get access to compile-time-only constructs. The key one here is `inline erasedValue[T]`: it conjures a fake value of type `T` that only exists so we can pattern-match on its type with an `inline match` — the compiler picks the branch by looking at the *static* type, and the fake value is never evaluated.

Armed with that, `summonAll` walks a tuple type recursively, exactly like you would walk a list at runtime, except the recursion happens during compilation:

```scala
inline def summonAll[T <: Tuple]: List[Debuggable[?]] =
  inline erasedValue[T] match
    case _: EmptyTuple   => Nil
    case _: (head *: tail) => deriveOrSummon[head] :: summonAll[tail]
```

The two cases match the two shapes a tuple type can have: `EmptyTuple` (the empty tuple, our base case) and `head *: tail` (a non-empty tuple, where `head` is the first element type and `tail` is the rest). For each `head` we find or derive a `Debuggable[head]` (more on `deriveOrSummon` in the next section) and prepend it, then recurse on `tail`. For `Person`'s `(String, Int)` this expands, at compile time, into `deriveOrSummon[String] :: deriveOrSummon[Int] :: Nil`.

`labelsOf` uses the same recursion to collect the field names, but instead of `erasedValue` it uses `constValue` for the head:

```scala
inline def labelsOf[T <: Tuple]: List[String] =
  inline erasedValue[T] match
    case _: EmptyTuple   => Nil
    case _: (head *: tail) => constValue[head].asInstanceOf[String] :: labelsOf[tail]
```

Here each `head` is a *singleton-string type* like `"name"` (the type, not the value). `constValue[head]` is the compile-time function that lifts such a singleton type back into the runtime `String` `"name"`. So for `Person` this produces the list `List("name", "age")`. We now have everything we need as plain values: a `List[Debuggable[?]]` and a `List[String]`.

## `summonFrom`: find an instance, or derive one

Back in `summonAll` we called `deriveOrSummon[head]` for each field type rather than simply summoning an existing instance. Why? Because not every field type has a hand-written `given`. A `Person` field of type `String` does (we wrote it in the base cases), but if `Person` had a field of type `Address`, there would be no `Debuggable[Address]` lying around — we would need to derive one. The same is true for the children of a sum type: each case of an `enum` is its own product that nobody wrote an instance for.

`summonFrom` handles both situations. It is an inline conditional that tries each branch at compile time and keeps the first one that type-checks:

```scala
inline def deriveOrSummon[T]: Debuggable[T] =
  scala.compiletime.summonFrom {
    case d: Debuggable[T] => d
    case m: Mirror.Of[T]  => derived[T](using m)
  }
```

If a `Debuggable[T]` is already in scope, use it. Otherwise, if `T` has a `Mirror` (i.e. it is a case class or enum), derive an instance recursively by calling `derived[T]`. This is the step that makes derivation both *recursive* (a `Person` containing an `Address` derives the `Address` instance on the way) and *transparent* (you don't have to manually provide instances for nested types).

## Putting `derived` together

Now we can write the real `derived`, the function `derives Debuggable` desugars to. It pulls together the three pieces we extracted from the `Mirror` and then dispatches on the kind of type we are dealing with:

```scala
inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] =
  val instances = summonAll[m.MirroredElemTypes]
  val labels    = labelsOf[m.MirroredElemLabels]
  val typeName  = constValue[m.MirroredLabel]
  inline m match
    case p: Mirror.ProductOf[T] => productDebuggable(typeName, labels, instances, p)
    case s: Mirror.SumOf[T]     => sumDebuggable(instances, s)
```

The first three lines collect, as runtime values, the per-element `Debuggable` instances (`summonAll`), the element labels (`labelsOf`), and the type's own name (`constValue[m.MirroredLabel]`, e.g. `"Person"`). The `inline match` then dispatches on the **static type** of the mirror: a `Mirror.ProductOf` means a case class, so we build a product instance; a `Mirror.SumOf` means an enum or sealed hierarchy, so we build a sum instance. Because the match is `inline`, the compiler picks the branch at compile time based on the mirror's type — there is no runtime type check, and the unused branch is discarded entirely.

### Products

A product is the easy case. The `instances` and `labels` lists we built line up positionally with the fields of the case class: the first instance and first label belong to the first field, and so on. At runtime we can read the field values through `productIterator`, since every case class is a `Product`. We then zip the three lists together and render each field as `label=value`, wrapping the whole thing in `typeName{...}`:

```scala
private def productDebuggable[T](
    typeName: String, labels: List[String],
    instances: List[Debuggable[?]], p: Mirror.ProductOf[T]
): Debuggable[T] = new Debuggable[T] {
  extension (x: T) def debug: String =
    val fields = x.asInstanceOf[Product].productIterator.toList
    val parts = fields.lazyZip(instances).lazyZip(labels).map { (value, inst, label) =>
      s"$label=${inst.asInstanceOf[Debuggable[Any]].debug(value)}"
    }
    parts.mkString(s"${toSnakeCase(typeName)}{", ", ", "}")
}
```

The `asInstanceOf` casts look unsafe but are not: `summonAll` already type-checked, at compile time, that the instance at each position matches the field at that position, so erasing the types to `Any`/`Debuggable[Any]` for the runtime zip is sound. The `toSnakeCase(typeName)` call is what turns `Person` into `person` in the output; we will write it in a moment.

### Sums

A sum is the type-level "or": a `Shape` *is* a `Circle`, a `Rectangle`, or a `Dot`. Here `instances` holds one `Debuggable` per case, in declaration order. The mirror gives us `ordinal(x)`, which tells us which case the value `x` actually is, as an index into that list. So all we have to do is dispatch to the matching child instance:

```scala
private def sumDebuggable[T](
    instances: List[Debuggable[?]], s: Mirror.SumOf[T]
): Debuggable[T] = new Debuggable[T] {
  extension (x: T) def debug: String =
    val ord = s.ordinal(x)
    instances(ord).asInstanceOf[Debuggable[Any]].debug(x)
}
```

Notice there is no rendering logic here at all. The child instance for, say, `Circle` is itself a derived *product*, so it already knows how to print `circle{radius=1.5}`. The sum case just forwards to it. This is the recursion from `deriveOrSummon` paying off: the enum's instance is built out of its children's instances.

## A cosmetic detour: snake_case names

Finally, `toSnakeCase` turns the type name into its output form (`Person` → `person`, `HTTPServer` → `http_server`):

```scala
private def toSnakeCase(name: String): String =
  s" $name ".sliding(3).flatMap { window =>
    val prev = window.charAt(0); val c = window.charAt(1); val next = window.charAt(2)
    val boundary = c.isUpper && (prev.isLower || prev.isDigit || (prev.isUpper && next.isLower))
    (if boundary then "_" else "") + c.toLower
  }.mkString
```

## Bonus: a `debug"..."` string interpolator

As a bonus, we can build a `debug"..."` interpolator that renders each `$arg` through its `Debuggable` instead of `toString`, with no macro. Building our own interpolator in Scala means adding an extension method to `StringContext`. The catch is that the standard interpolator methods just call `toString` on their arguments, so we first need to pre-render each argument through its `Debuggable` and hand the resulting strings over. We capture that rendered string in a small case class `DebugArg`:

```scala
case class DebugArg(rendered: String)
```

where `rendered` is the result of calling `.debug` on the argument. We then define a converter that turns any `T` that has a `Debuggable[T]` instance into a `DebugArg`:

```scala
object DebugArg:
  given convert[T](using d: Debuggable[T]): Conversion[T, DebugArg] with
    def apply(x: T): DebugArg = DebugArg(x.debug)
```

Because this is an implicit `Conversion`, we need to enable the feature at the call site with `import scala.language.implicitConversions`. With a missing `Debuggable[T]`, the conversion fails to apply and we get a compile error right at the offending `$arg`.

Now we can create the interpolator itself, which just delegates to the standard `s` interpolator after pre-rendering each argument:

```scala
extension (sc: StringContext)
  def debug(args: DebugArg*): String = sc.s(args.map(_.rendered)*)
```

And here it is in action:

```scala
import scala.language.implicitConversions

val alice = Person("Alice", 30)
val shape: Shape = Shape.Circle(1.5)

debug"user=$alice, shape=$shape"
// user=person{name=Alice, age=30}, shape=circle{radius=1.5}
```


## Wrapping up

Let's recap what we built. Starting from nothing but a `Debuggable[T]` trait, we taught the Scala 3 compiler to generate an instance for any case class or enum through a single `derives Debuggable` clause. The whole mechanism rests on a handful of pieces:

- **`Mirror`** gives us the shape of a type at compile time (its field labels, field types, and its own name) and lets us distinguish a `Mirror.Product` (case class) from a `Mirror.Sum` (enum or sealed hierarchy).
- **`inline` metaprogramming** (`erasedValue`, `constValue`, `inline match`) bridges the type level and the value level, turning those compile-time types into the runtime `List[Debuggable[?]]` and `List[String]` we actually need.
- **`summonFrom`** makes derivation recursive: each field is either summoned from an existing instance or derived on the spot, so nested types and enum cases are handled without us writing a line for them.

This is not just a toy. It is exactly the technique that libraries like [Circe](https://circe.github.io/circe/) use to derive JSON encoders and decoders for your types. The only real difference is that our `debug` produces a `String`, whereas a JSON codec produces a JSON AST: same `Mirror`, same recursion, different output type. You can see this for yourself in Circe's [Scala 3 derivation source](https://github.com/circe/circe/blob/series/0.14.x/modules/core/shared/src/main/scala-3/io/circe/derivation/package.scala), where `summonLabels`, `summonEncoder`/`summonDecoder` and the `Mirror.SumOf`/`Mirror.ProductOf` dispatch map almost one-to-one onto the `labelsOf`, `summonAll` and `inline match` we wrote here. We also saw, as a bonus, how to write a custom string interpolator by adding an extension method to `StringContext`.

If you take one thing away from this article, let it be that automatic derivation in Scala 3 is not compiler magic. It is ordinary code that happens to run at compile time, and now you can write it yourself.

