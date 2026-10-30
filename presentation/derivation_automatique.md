---
title: "La dérivation automatique de typeclasses en Scala 3"
subtitle: "Construire une typeclass `Debuggable` et apprendre au compilateur à la dériver"
author: Benjamin Thuillier
lang: fr
---

# Qui suis-je ?

Benjamin Thuillier, Senior Software Engineer chez **Conduktor**

- Une quinzaine d'années de Scala, souvent autour de Kafka
- Ad tech (Teads, TabMo), plateformes data (iAdvize, Talend), aujourd'hui gouvernance Kafka chez Conduktor
- J'écris sur la programmation fonctionnelle : gilwath.com

::: notes
[0:30, ~45 s]
Rester bref. Conduktor : produit de gouvernance autour de Kafka, en Scala.
:::

# Au programme

1. C'est quoi une typeclass en Scala ?
2. La typeclass `Debuggable` et ses instances de base
3. `derives` et `Mirror`
4. `inline` : de la récursion qui tourne dans le compilateur
5. `summonFrom` : trouver une instance, ou la dériver
6. Assembler `derived` : produits et sommes
7. Bonus : un interpolateur `debug"..."`
8. Dans la vraie vie : Circe

::: notes
[1:15, ~15 s]
:::

# C'est quoi une typeclass ?

> Une type class est un type abstrait et paramétré qui permet d'ajouter un nouveau comportement à n'importe quel type fermé sans passer par le sous-typage. Si vous venez de Java, pensez à `java.util.Comparator[T]`.
>
> (documentation Scala)

- Haskell : construction native du langage
- Scala : un **pattern** basé sur `trait` + instances `given`
- Plus proche des *modular implicits* d'OCaml : les instances sont des valeurs qu'on passe (explicitement ou implicitement)

::: notes
[1:30, ~1 min 30]
Insister sur le fait qu'en Scala ce n'est pas une feature du langage, c'est un pattern.
:::

# À quoi ça sert ?

- Décrire comment un type **qu'on ne possède pas** (bibliothèque standard, lib tierce) se conforme à un comportement
- Donner un comportement à **plusieurs types** sans relation de sous-typage entre eux

::: notes
[3:00, ~30 s]
:::

# Dans la stdlib : `Ordering`

```scala
// dans List : def sorted[B >: A](implicit ord: Ordering[B]): List[A]
List(3, 1, 2).sorted   // List(1, 2, 3), grâce au given Ordering[Int]

case class Person(name: String, age: Int)
List(Person("Alice", 30), Person("Bob", 25)).sorted
// erreur : No given instance of type Ordering[B] was found

given Ordering[Person] = Ordering.by(_.age)
List(Person("Alice", 30), Person("Bob", 25)).sorted
// List(Person(Bob,25), Person(Alice,30))
```

::: notes
[3:30, ~1 min 30]
Ordering est la typeclass la plus connue de la stdlib, et elle étend justement java.util.Comparator (le lien avec la citation).
`sorted` ne demande pas que Person hérite de quoi que ce soit : il demande une instance Ordering[Person].
Sans instance : erreur de compilation. On en fournit une avec un `given`, et `sorted` marche. Person ne sait toujours rien du tri.
:::

# Dans l'écosystème Scala

| Typeclass | Bibliothèque | Pour quoi faire |
|---|---|---|
| `Encoder[T]` / `Decoder[T]` | Circe | Sérialiser / désérialiser en JSON |
| `Show[T]`, `Eq[T]` | Cats | Affichage et égalité typés |
| `Functor[F]`, `Monad[F]` | Cats | Abstraire sur `Option`, `List`, `IO`... |
| `Read[T]` / `Write[T]` | Doobie | Lire / écrire une ligne SQL |

Point commun : les instances sont fournies par la lib ou dérivées, rarement écrites à la main.

::: notes
[5:00, ~1 min]
Circe : on y reviendra à la fin, c'est exactement la technique du talk.
Cats : Show est très proche de notre Debuggable. Functor/Monad montrent qu'une typeclass peut aussi porter sur un constructeur de type F[_].
Doobie : les instances Read/Write pour une case class sont dérivées à partir de celles de ses colonnes.
Transition : ici on a écrit l'instance à la main. Le reste du talk : la faire écrire par le compilateur.
:::

# Notre exemple

```scala
case class Person(name: String, age: Int)

enum Shape:
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
```

On veut une méthode `debug` plutôt que le `.toString` par défaut :

```scala
Person("Alice", 30).debug          // person{name=Alice, age=30}
(Shape.Circle(1.5): Shape).debug   // circle{radius=1.5}
```

::: notes
[6:00, ~1 min]
Noter que le nom du type est en minuscules (Person devient person). On traitera ça plus tard.
:::

# L'objectif : ne jamais écrire d'instance à la main

```scala
case class Person(name: String, age: Int) derives Debuggable

enum Shape derives Debuggable:
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
```

C'est ça, la **dérivation automatique**. Le reste du talk : apprendre au compilateur à le faire.

::: notes
[7:00, ~30 s]
:::

# La typeclass

```scala
trait Debuggable[T] {
  extension (x: T) def debug: String
}
```

- `T` sera `Person`, `Shape`, ...
- l'`extension` permet d'appeler `.debug` directement sur la valeur

::: notes
[7:30, ~30 s]
:::

# Les instances de base

Pas de `Mirror` pour les primitives : on les écrit nous-mêmes.

```scala
given Debuggable[Int] with
  extension (x: Int) def debug: String = x.toString

given Debuggable[String] with
  extension (x: String) def debug: String = x
// ... Byte, Short, Long, Float, Double, BigInt, BigDecimal, UUID
```

::: notes
[8:00, ~45 s]
Les primitives n'ont pas de Mirror, le compilateur ne peut donc rien dériver pour elles.
:::

# Les instances conditionnelles

Une instance pour `List[T]` **si** il en existe une pour `T` :

```scala
given [T](using d: Debuggable[T]): Debuggable[List[T]] with
  extension (x: List[T]) def debug: String =
    x.map(_.debug).mkString("[", ", ", "]")

given [T](using d: Debuggable[T]): Debuggable[Option[T]] with
  extension (x: Option[T]) def debug: String = x match
    case Some(v) => s"${v.debug}"
    case None    => "none"
```

::: notes
[8:45, ~1 min]
Attention : List et Option ont bien un Mirror (ce sont des sommes). Mais la version dérivée afficherait leur structure interne : some{value=1}, ::{head=1, next=...}. On écrit donc ces instances à la main, et comme summonFrom essaie d'abord les given existants, ce sont elles qui sont choisies. Map, elle, n'a pas de Mirror.
:::

# Que fait `derives` ?

`derives Debuggable` demande au compilateur d'appeler :

```scala
inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] = ???
```

Un `Mirror` décrit la **forme** d'un type :

| | Quoi |
|---|---|
| `Mirror.Product` | case class, object, cas d'enum |
| `Mirror.Sum` | sealed class / trait, enum |

::: notes
[9:45, ~1 min]
:::

# Ce que le `Mirror` nous donne pour `Person`

| Membre | Valeur (au niveau des **types**) |
|---|---|
| `m.MirroredElemTypes` | `(String, Int)` |
| `m.MirroredElemLabels` | `("name", "age")` |
| `m.MirroredLabel` | `"Person"` |

Problème : ce sont des **types**, pas des valeurs.

Il nous faut : une `List[Debuggable[?]]` et une `List[String]`.

::: notes
[10:45, ~1 min 15]
MirroredElemLabels est un tuple de types singleton string. Il faut faire le pont entre niveau type et niveau valeur, et on le fait à la compilation.
:::

# `inline` : de la récursion dans le compilateur

- Une `inline def` est **expansée** au site d'appel, pas appelée au runtime
- `erasedValue[T]` : une fausse valeur de type `T`, jamais évaluée
- `inline match` : le compilateur choisit la branche selon le type **statique**

::: notes
[12:00, ~45 s]
:::

# `summonAll` : parcourir un tuple de types

```scala
inline def summonAll[T <: Tuple]: List[Debuggable[?]] =
  inline erasedValue[T] match
    case _: EmptyTuple   => Nil
    case _: (head *: tail) => deriveOrSummon[head] :: summonAll[tail]
```

Pour `(String, Int)`, à la compilation :

```scala
deriveOrSummon[String] :: deriveOrSummon[Int] :: Nil
```

::: notes
[12:45, ~1 min 30]
Exactement comme parcourir une liste au runtime, sauf que la récursion a lieu pendant la compilation.
Deux formes de tuple : EmptyTuple (cas de base) et head *: tail.
:::

# `labelsOf` : des types singleton aux `String`

```scala
inline def labelsOf[T <: Tuple]: List[String] =
  inline erasedValue[T] match
    case _: EmptyTuple   => Nil
    case _: (head *: tail) => constValue[head].asInstanceOf[String] :: labelsOf[tail]
```

- `head` est un type singleton comme `"name"`
- `constValue[head]` le ramène à la valeur `"name"`
- Résultat pour `Person` : `List("name", "age")`

::: notes
[14:15, ~1 min]
:::

# `summonFrom` : trouver ou dériver

```scala
inline def deriveOrSummon[T]: Debuggable[T] =
  scala.compiletime.summonFrom {
    case d: Debuggable[T] => d
    case m: Mirror.Of[T]  => derived[T](using m)
  }
```

1. Une instance existe ? On la prend.
2. Sinon, `T` a un `Mirror` ? On la dérive.

Dérivation **récursive** (un `Address` dans `Person`) et **transparente**.

::: notes
[15:15, ~1 min 30]
Pourquoi ne pas juste summon ? Parce que tous les types n'ont pas de given écrit à la main : un champ Address, ou les cas d'un enum, chacun est un produit pour lequel personne n'a écrit d'instance.
summonFrom garde la première branche qui type-check.
Types récursifs : cette version naïve ne les gère pas, mais en rendant l'évaluation des instances paresseuse (lazy), on supporterait la récursivité.
:::

# Assembler `derived`

```scala
inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] =
  val instances = summonAll[m.MirroredElemTypes]
  val labels    = labelsOf[m.MirroredElemLabels]
  val typeName  = constValue[m.MirroredLabel]
  inline m match
    case _: Mirror.ProductOf[T] => productDebuggable(typeName, labels, instances)
    case s: Mirror.SumOf[T]     => sumDebuggable(instances, s)
```

`inline match` : choix à la compilation, la branche inutile disparaît.

::: notes
[16:45, ~1 min 15]
Pas de test de type au runtime.
:::

# Les produits

```scala
private def productDebuggable[T](
    typeName: String, labels: List[String],
    instances: List[Debuggable[?]]
): Debuggable[T] = new Debuggable[T] {
  private val prefix = s"${toSnakeCase(typeName)}{"
  extension (x: T) def debug: String =
    val fields = x.asInstanceOf[Product].productIterator.toList
    val parts = fields.lazyZip(instances).lazyZip(labels).map { (value, inst, label) =>
      s"$label=${inst.asInstanceOf[Debuggable[Any]].debug(value)}"
    }
    parts.mkString(prefix, ", ", "}")
}
```

::: notes
[18:00, ~1 min 30]
Le préfixe est calculé une seule fois, à la construction de l'instance.
instances et labels s'alignent par position avec les champs. productIterator donne les valeurs au runtime.
Les asInstanceOf ont l'air dangereux mais ne le sont pas : summonAll a déjà vérifié à la compilation que chaque instance correspond au champ à la même position.
:::

# Les sommes

```scala
private def sumDebuggable[T](
    instances: List[Debuggable[?]], s: Mirror.SumOf[T]
): Debuggable[T] = new Debuggable[T] {
  private val byOrdinal = instances.toVector
  extension (x: T) def debug: String =
    val ord = s.ordinal(x)
    byOrdinal(ord).asInstanceOf[Debuggable[Any]].debug(x)
}
```

- `ordinal(x)` : quel cas est `x`
- Aucune logique d'affichage : on délègue à l'instance du cas (elle-même un **produit** dérivé)

::: notes
[19:30, ~1 min]
Vector pour un accès en temps constant par ordinal (une List serait parcourue à chaque appel).
Un Shape EST un Circle, un Rectangle ou un Dot. C'est la récursion de deriveOrSummon qui paie.
:::

# Détour cosmétique : snake_case

`Person` → `person`, `HTTPServer` → `http_server`

```scala
private def toSnakeCase(name: String): String =
  s" $name ".sliding(3).flatMap { window =>
    val prev = window.charAt(0); val c = window.charAt(1); val next = window.charAt(2)
    val boundary = c.isUpper &&
      (prev.isLower || prev.isDigit || (prev.isUpper && next.isLower))
    (if boundary then "_" else "") + c.toLower
  }.mkString
```

::: notes
[20:30, ~30 s]
Passer vite, ce n'est pas le sujet.
:::

# Bonus : un interpolateur `debug"..."`

```scala
case class DebugArg(rendered: String)

object DebugArg:
  given convert[T](using d: Debuggable[T]): Conversion[T, DebugArg] with
    def apply(x: T): DebugArg = DebugArg(x.debug)

extension (sc: StringContext)
  def debug(args: DebugArg*): Unit = println(sc.s(args.map(_.rendered)*))
```

```scala
import scala.language.implicitConversions

debug"user=$alice, shape=$shape"
// affiche : user=person{name=Alice, age=30}, shape=circle{radius=1.5}
```

::: notes
[21:00, ~1 min 30]
Un interpolateur = une extension sur StringContext. Les interpolateurs standards appellent toString, donc on pré-rend chaque argument via Debuggable.
L'interpolateur fait directement le println : pas besoin d'écrire println(debug"...").
Pas d'instance Debuggable[T] : erreur de compilation directement sur le $arg fautif.
:::

# Démo

```bash
scala https://gist.github.com/bthuillier/4f65135b17bd41f41adcb862ef6fd223
```

::: notes
[22:30, ~2 min 30]
Montrer : Person, Shape, un champ imbriqué (Address), puis retirer une instance pour montrer l'erreur de compilation.
:::

# Dans la vraie vie : Circe

C'est exactement la technique de **Circe** pour dériver les encoders / decoders JSON.

| Nous | Circe |
|---|---|
| `labelsOf` | `summonLabels` |
| `summonAll` | `summonEncoders` / `summonDecoders` |
| `deriveOrSummon` | `summonEncoder` / `summonDecoder` |
| `inline match` sur `Mirror` | dispatch `Mirror.SumOf` / `Mirror.ProductOf` |

Même `Mirror`, même récursion, type de sortie différent (`String` vs AST JSON).

::: notes
[25:00, ~1 min]
Source : modules/core/shared/src/main/scala-3/io/circe/derivation/package.scala
:::

# À retenir

- **`Mirror`** : la forme d'un type à la compilation (labels, types, nom ; produit ou somme)
- **`inline`** (`erasedValue`, `constValue`, `inline match`) : pont entre niveau type et niveau valeur
- **`summonFrom`** : rend la dérivation récursive

La dérivation automatique en Scala 3, ce n'est pas de la magie : c'est du code ordinaire qui s'exécute à la compilation.

::: notes
[26:00, ~1 min]
:::

# Merci ! Questions ?

- Article : *Automatic Typeclass Derivation in Scala 3*
- Code : gist.github.com/bthuillier/4f65135b17bd41f41adcb862ef6fd223

::: notes
[27:00, ~3 min de questions]
:::

<!--
Rendu :
pandoc derivation_automatique.md -t dzslides -s --embed-resources --css slides.css -o derivation_automatique.html

Notes du slide titre :
[0:00, ~30 s]
Se présenter. Annoncer le fil rouge : on part d'un trait vide et on finit avec `derives Debuggable` sur n'importe quelle case class ou enum.
-->
