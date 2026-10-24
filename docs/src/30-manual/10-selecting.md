```@meta
CurrentModule = ThermophysicalDB
```

# [Selecting points](@id selecting)

[`points`](@ref) is the single entry point for filtering. It takes a [`Dataset`](@ref) (what [`database`](@ref) returns) or an earlier selection, and returns a new selection: a [`DataView`](@ref).

```@setup sel
Main.DocsSetup.activate!()
```

```@example sel
using ThermophysicalDB, Unitful

db = database(progress = false)
```

## How a selection works

A `DataView` does not copy any data. It stores the *row numbers* of the measurements that matched and a reference to the dataset. Three consequences follow:

- Creating a selection is cheap, and so is keeping many of them around.
- Refining a selection scans only the rows that survived the previous filter.
- Nothing is converted or allocated per point until you ask for a [`table`](@ref).

Every keyword is optional, and keywords combine with AND. Calling `points` with no keyword selects everything:

```@example sel
everything = points(db)
length(everything)
```

## Components

`component` accepts a name, a molecular formula or an InChIKey. Names match any name recorded for the compound, ignoring case; formulas are case sensitive (`"CO"` and `"Co"` differ); InChIKeys ignore case.

```@example sel
a = points(db; component = "methane")
b = points(db; component = "CH4")
c = points(db; component = "VNWKTOKETHGBQD-UHFFFAOYSA-N")
length(a) == length(b) == length(c)
```

A list of components, together with `match` and `exact`, defines what kind of *system* qualifies:

| Keywords | A system qualifies if… | Example result |
| :-- | :-- | :-- |
| `component = "methane"` | it contains methane (alone or mixed) | methane and every mixture of methane |
| `component = [...]`, `match = :any` (default) | it contains **any** listed component | systems with methane or with ethane |
| `component = [...]`, `match = :all` | it contains **every** listed component | mixtures containing both |
| `component = [...]`, `exact = true` | it consists of **exactly** the listed components | the binary and nothing else |
| `component = "methane", exact = true` | it is the pure compound | pure methane |

`pure = true` keeps single-component systems and `pure = false` keeps mixtures, independent of which compounds they contain.

```@example sel
pure_methane = points(db; component = "methane", exact = true)
methane_mixtures = points(db; component = "methane", pure = false)
length(pure_methane), length(methane_mixtures)
```

## Properties

`property` takes a label, a regular expression, or a list of either. Labels are the property names of the archive without their unit (the unit is stored apart and shown in the `unit` column).

```@example sel
points(db; component = "water", exact = true, property = "Mass density") |> length
```

```@example sel
# every viscosity-like property, with a regular expression
points(db; component = "water", exact = true, property = r"[Vv]iscosity") |> length
```

```@example sel
# a list: either of the two
points(db; component = "water", exact = true, property = ["Mass density", "Speed of sound"]) |> length
```

To find out which properties exist for a substance, ask the table of its points:

```@example sel
unique(table(points(db; component = "water", exact = true)).property)
```

## Temperature and pressure

`temperature` and `pressure` take a `(low, high)` tuple, a range, or a single integer. Either side may be `nothing` to leave it open. Both bounds are inclusive.

| Form | Meaning |
| :-- | :-- |
| `(300, 350)` | 300 K ≤ T ≤ 350 K |
| `(300, nothing)` | T ≥ 300 K |
| `(nothing, 350)` | T ≤ 350 K |
| `300:350` | a range; its first and last values are the bounds |
| `300` | exactly 300 K (an integer) |

Plain numbers are kelvin and kilopascal, the units in which the conditions are stored. **Unitful quantities are converted**, so you can write the limits in the units you think in:

```@example sel
v = points(
    db;
    component = "water", exact = true, property = "Mass density",
    temperature = (20u"°C", 30u"°C"),
    pressure = (1u"atm", 2u"atm"),
)
length(v)
```

Quantities with the wrong dimension are refused (`temperature = (1u"m", 2u"m")` throws a `DimensionError`), and units are rejected where they make no sense, such as `year`.

!!! warning "Points without the condition are excluded"
    When you give a `temperature` or `pressure` filter, points that have no stated value for it are dropped, because they cannot be shown to satisfy the condition. A vapor-pressure point, for example, has a temperature but no pressure *condition*: its pressure is the measured value. Filtering such a selection by `pressure` would drop everything.

## References

The reference filters keep the points of matching publications.

| Keyword | Meaning |
| :-- | :-- |
| `doi = "10.1007/…"` | exactly that DOI (case-insensitive) |
| `author = "Patek"` | any author whose name contains the text (case-insensitive) |
| `source = "thermoml"` | the database the point came from |
| `year = 2005`, `year = (2000, 2010)` | publication year, with the same forms as above |

```@example sel
points(
    db; component = ["carbon dioxide", "methane"], match = :all, exact = true,
    author = "Patek",
) |> length
```

## Chaining

Because `points` accepts a selection, filters chain naturally and cost one scan of the survivors each:

```@example sel
water = points(db; component = "water", exact = true)
near_ambient = points(water; temperature = (15u"°C", 35u"°C"))
densities = points(near_ambient; property = "Mass density")

length(water), length(near_ambient), length(densities)
```

Putting the most selective filter first (usually the component) keeps the later scans short.

## A typo is never "no data"

A component or property that matches nothing raises an `ArgumentError` instead of returning an empty selection, so a misspelling is not mistaken for a gap in the literature:

```@example sel
try
    points(db; component = "hexnae")
catch err
    println(sprint(showerror, err))
end
```

An empty selection, on the other hand, is a legitimate result: it means the filters were valid and no point satisfied all of them.
