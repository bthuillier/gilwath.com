---
title: "La dérivation automatique de typeclasses en Scala 3"
subtitle: "Construire une typeclass `Debuggable` et apprendre au compilateur à la dériver"
author: Benjamin Thuillier
lang: fr
---

# Qui suis-je ?

- Benjamin Thuillier
- Senior Software Engineer chez [Conduktor](https://conduktor.io)
- [gilwath.com](https://gilwath.com)
- [@gilwath.com](https://bsky.app/profile/gilwath.com) sur Bluesky

::: notes
[0:30, ~45 s]
Rester bref. 15 ans de Scala, souvent autour de Kafka. Ad tech (Teads, TabMo), plateformes data (iAdvize, Talend), aujourd'hui gouvernance Kafka chez Conduktor, en Scala.
J'écris sur la programmation fonctionnelle sur gilwath.com.
:::

# Au programme

1. C'est quoi une typeclass en Scala ?
2. La typeclass `Debuggable` et ses instances de base
3. `derives` et `Mirror`
4. `inline` : de la récursion qui tourne dans le compilateur
5. `summonFrom` : trouver une instance, ou la dériver
6. Assembler `derived` : produits et sommes
7. Bonus : un interpolateur `debug"..."`
8. Démo
9. Dans la vraie vie : Circe

::: notes
[1:15, ~15 s]
:::

# C'est quoi une typeclass ?

> Un type abstrait et paramétré qui ajoute un comportement à n'importe quel type, sans sous-typage. Pensez à `java.util.Comparator[T]`.
>
> (d'après la documentation Scala)

- Polymorphisme **ad hoc** : un comportement par type
- Haskell : mot-clé `class`
- Rust : `trait` + `impl Trait for Type`
- Scala : un simple `trait`, outillé par `given`, `using`, `derives`

::: notes
[1:30, ~1 min 30]
Rust : les traits sont des typeclasses. Différence avec Scala : une seule instance par type dans tout le programme (cohérence, orphan rule), alors qu'en Scala les given sont des valeurs choisies selon la portée. `#[derive(Debug)]` est l'équivalent Rust de `derives`, mais via une macro.
Proche des modular implicits (proposition pour OCaml) : les instances sont des valeurs qu'on passe, explicitement ou implicitement.
Nuance : en Haskell, `class` est une construction du langage. En Scala, la typeclass elle-même est un trait ordinaire (un encodage), mais Scala 3 fournit tout l'outillage autour : given/using, context bounds, et `derives`, le sujet du talk.
Ad hoc vs paramétrique (Strachey, 1967) : length[A] marche pareil pour tout A, debug fait autre chose pour chaque type. Les typeclasses viennent de Wadler & Blott, "How to make ad-hoc polymorphism less ad hoc" (1989).
:::

# À quoi ça sert ?

- Ajouter un comportement à un type **qu'on ne possède pas** (stdlib, lib tierce)
- Le partager entre **plusieurs types** sans lien de sous-typage

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
Transition : ici on a écrit l'instance à la main. Le reste du talk : la faire écrire par le compilateur.
:::

# Dans l'écosystème Scala

| Typeclass | Bibliothèque | Pour quoi faire |
|---|---|---|
| `Encoder[T]` / `Decoder[T]` | Circe | Sérialiser / désérialiser en JSON |
| `Show[T]`, `Eq[T]` | Cats | Affichage et égalité typés |
| `Read[T]` / `Write[T]` | Doobie | Lire / écrire une ligne SQL |

Instances fournies par la lib, ou dérivées.

::: notes
[5:00, ~1 min]
Circe : on y reviendra à la fin, c'est exactement la technique du talk.
Cats : Show est très proche de notre Debuggable. Cats a aussi Functor/Monad : une typeclass peut porter sur un constructeur de type F[_].
Doobie : les instances Read/Write pour une case class sont dérivées à partir de celles de ses colonnes.
:::

# L'objectif : une ligne, zéro instance écrite

```scala
case class Person(name: String, age: Int) derives Debuggable

enum Shape derives Debuggable:
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
```

```scala
Person("Alice", 30).debug   // person{name=Alice, age=30}
Shape.Circle(1.5).debug     // circle{radius=1.5}
Shape.Dot.debug             // dot{}
```

::: notes
[6:00, ~1 min 30]
Notre exemple : une case class et un enum. On veut une méthode debug plutôt que le toString par défaut.
C'est ça, la dérivation automatique : on ajoute `derives Debuggable`, sans écrire d'instance. Le reste du talk : apprendre au compilateur à le faire.
Noter que le nom du type est en minuscules (Person devient person). On traitera ça plus tard.
:::

# La typeclass

```scala
trait Debuggable[T]:
  extension (x: T) def debug: String
```

`extension` : on appelle `.debug` directement sur la valeur.

::: notes
[7:30, ~30 s]
T sera Person, Shape, ...
:::

# Les instances de base

Les primitives : écrites à la main.

```scala
given Debuggable[Int] with
  extension (x: Int) def debug: String = x.toString

given Debuggable[String] with
  extension (x: String) def debug: String = x
// ... Byte, Short, Long, Float, Double, BigInt, BigDecimal, UUID
```

::: notes
[8:00, ~45 s]
Les primitives n'ont pas de Mirror (on voit ce que c'est juste après), le compilateur ne peut donc rien dériver pour elles.
:::

# Les instances conditionnelles

Une instance pour `List[T]` **s'il** en existe une pour `T` :

```scala
given [T](using d: Debuggable[T]): Debuggable[List[T]] with
  extension (x: List[T]) def debug: String =
    x.map(_.debug).mkString("[", ", ", "]")

given [T](using d: Debuggable[T]): Debuggable[Option[T]] with
  extension (x: Option[T]) def debug: String = x match
    case Some(v) => v.debug
    case None    => "none"
```

::: notes
[8:45, ~1 min]
On les écrit à la main pour contrôler l'affichage. On verra avec summonFrom pourquoi elles l'emportent sur une version dérivée.
:::

# Que fait `derives` ?

`derives Debuggable` demande au compilateur d'appeler :

```scala
object Debuggable:
  inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] = ???
```

Un `Mirror` décrit la **forme** d'un type :

| Mirror | Pour quels types |
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

Ce sont des **types**. Il nous faut des valeurs : `List[Debuggable[?]]`, `List[String]`.

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
    case _: EmptyTuple     => Nil
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
    case _: EmptyTuple     => Nil
    case _: (head *: tail) => constValue[head].asInstanceOf[String] :: labelsOf[tail]
```

`constValue[head]` : du type singleton `"name"` à la valeur `"name"`.

::: notes
[14:15, ~1 min]
head est un type singleton comme "name". Résultat pour Person : List("name", "age").
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

Dérivation **récursive** et **transparente**.

::: notes
[15:15, ~1 min 30]
Pourquoi ne pas juste summon ? Parce que tous les types n'ont pas de given écrit à la main : un champ Address, ou les cas d'un enum, chacun est un produit pour lequel personne n'a écrit d'instance.
summonFrom garde la première branche qui type-check.
C'est pour ça que nos instances List et Option l'emportent : elles ont un Mirror (ce sont des sommes), mais la version dérivée afficherait leur structure interne (some{value=1}, ::{head=1, next=...}). Map, elle, n'a pas de Mirror.
Types récursifs : cette version naïve ne les gère pas, mais en rendant l'évaluation des instances paresseuse (lazy), on supporterait la récursivité.
:::

# Assembler `derived`

```scala
inline def derived[T](using m: Mirror.Of[T]): Debuggable[T] =
  // (String, Int) -> List(Debuggable[String], Debuggable[Int])
  val instances = summonAll[m.MirroredElemTypes]
  inline m match
    case p: Mirror.ProductOf[T] =>
      // ("name", "age") -> List("name", "age")
      val labels   = labelsOf[p.MirroredElemLabels]
      // "Person" -> "Person"
      val typeName = constValue[p.MirroredLabel]
      productDebuggable(typeName, labels, instances)
    case s: Mirror.SumOf[T] => sumDebuggable(instances, s)
```

`inline match` : choix à la compilation, la branche inutile disparaît.

::: notes
[16:45, ~1 min 15]
Pas de test de type au runtime.
Une somme n'a besoin que des instances : labels et typeName ne sont calculés que dans la branche produit. (L'article les calcule encore avant le match, sans conséquence : une petite liste inutile, construite une seule fois.)
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
toSnakeCase : Person devient person, HTTPServer devient http_server. Pas le sujet, le code est dans l'article.
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

`ordinal(x)` donne le cas, et on délègue à son instance (un **produit** dérivé).

::: notes
[19:30, ~1 min]
Aucune logique d'affichage ici.
Vector pour un accès en temps constant par ordinal (une List serait parcourue à chaque appel).
Un Shape EST un Circle, un Rectangle ou un Dot. C'est la récursion de deriveOrSummon qui paie.
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
debug"user=$alice, shape=$shape"
// affiche : user=person{name=Alice, age=30}, shape=circle{radius=1.5}
```

::: notes
[20:30, ~1 min 30]
Côté appelant, il faut import scala.language.implicitConversions.
Un interpolateur = une extension sur StringContext. Les interpolateurs standards appellent toString, donc on pré-rend chaque argument via Debuggable.
L'interpolateur fait directement le println : pas besoin d'écrire println(debug"...").
Pas d'instance Debuggable[T] : erreur de compilation directement sur le $arg fautif.
:::

# Démo

```bash
scala https://gist.github.com/bthuillier/4f65135b17bd41f41adcb862ef6fd223
```

::: notes
[22:00, ~3 min]
Montrer : Person, Shape, un champ imbriqué (Test contient un TestValue), puis retirer une instance pour montrer l'erreur de compilation.
:::

# Dans la vraie vie : Circe

| Nous | Circe |
|---|---|
| `labelsOf` | `summonLabels` |
| `summonAll` | `summonEncoders` / `summonDecoders` |
| `deriveOrSummon` | `summonEncoder` / `summonDecoder` |
| `inline match` sur `Mirror` | dispatch `Mirror.SumOf` / `Mirror.ProductOf` |

Même `Mirror`, même récursion, type de sortie différent (`String` vs AST JSON).

::: notes
[25:00, ~1 min]
C'est exactement la technique de Circe pour dériver les encoders / decoders JSON.
Source : modules/core/shared/src/main/scala-3/io/circe/derivation/package.scala
:::

# À retenir

- **`Mirror`** : la forme d'un type à la compilation (labels, types, nom ; produit ou somme)
- **`inline`** (`erasedValue`, `constValue`, `inline match`) : pont entre niveau type et niveau valeur
- **`summonFrom`** : rend la dérivation récursive

Pas de magie : du code ordinaire, exécuté à la compilation.

::: notes
[26:00, ~1 min]
:::

# Merci ! Questions ?

- Article : [*Automatic Typeclass Derivation in Scala 3*](https://gilwath.com/articles/scala_automatic_derivation.html)
- Code : [gist.github.com/bthuillier/4f65135b…](https://gist.github.com/bthuillier/4f65135b17bd41f41adcb862ef6fd223)

![](qr-gist.svg){width=220}

::: notes
[27:00, ~3 min de questions]
:::

<!--
Rendu reveal.js :
pandoc derivation_automatique.md -t revealjs -s --embed-resources --css reveal.css -V theme=white -V width=1280 -V height=720 -V margin=0 -V center=false -V transition=none -V slideNumber=true -V hash=true -V controls=false -o derivation_automatique.html

Présenter (touche s : vue présentateur avec notes et chrono) :
open -a "Google Chrome" derivation_automatique.html

PDF des notes (secours) :
pandoc derivation_automatique.md -s --embed-resources --css notes.css -o /tmp/notes.html
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --no-pdf-header-footer --print-to-pdf=notes.pdf /tmp/notes.html

Notes du slide titre :
[0:00, ~30 s]
Se présenter. Annoncer le fil rouge : on part d'un trait vide et on finit avec `derives Debuggable` sur n'importe quelle case class ou enum.
-->
