```@meta
CurrentModule = ThermophysicalDB
```

# [Selecting points](@id selecting)

[`points`](@ref) is the single entry point for filtering. It takes a [`Database`](@ref) (what [`database`](@ref) returns) or an earlier selection, and returns a new selection: a [`DatabaseView`](@ref), with a [`DataView`](@ref) for each database that has points ([`parts`](@ref)); with one database it is used as that `DataView`.

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

`component` accepts a name, a molecular formula, an InChIKey, a compound id or the result of [`find_compounds`](@ref). Names match any name recorded for the compound and are compared loosely: case, accents, hyphens and spaces are ignored (`"Iso-Butane"` is `"isobutane"`), `"n-hexane"` also finds `"hexane"`, and a few abbreviations and alternative spellings (`"IPA"`, `"sulphur"`) are understood. Formulas are case sensitive (`"CO"` and `"Co"` differ) and a formula can be shared by several compounds (`"C4H10"` is butane and isobutane); InChIKeys ignore case.

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

### Looking the compounds up first

The safest way to select a system is to look the compounds up and pass their ids. [`find_compounds`](@ref) lists what a text refers to, with the number of measurements of each compound, so the spelling that has data is obvious:

```@example sel
find_compounds(db, "methane"; limit = 3)
```

```@example sel
ch4 = find_compounds(db, "methane").id[1]
co2 = find_compounds(db, "carbon dioxide").id[1]
length(points(db; component = [ch4, co2], match = :all, exact = true))
```

[`mixture`](@ref) is the short form for a system made of exactly the given components, in any order: `mixture(db, "methane", "carbon dioxide")`. When a name matches nothing, the error suggests the closest names.

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

## Phase, method, composition, value and uncertainty

These filters look at one measurement instead of one experiment. They combine with the others by AND, like everything in `points`.

| Keyword | Meaning |
| :-- | :-- |
| `phase = "liquid"`, `method = "hot-wire"` | text that the phase or the method contains (any case), a `Regex`, or a vector; a point that states none is excluded |
| `fraction = "methane" => (0.2, 0.4)` | the amount of that compound, wherever it sits in the system; the same forms of limits as `temperature`, and a single number |
| `xkind = "mole"` | the kind of composition the source used (text, `Regex` or vector) |
| `value = (low, high)` | limits on the value, in the native unit of each property |
| `uncertainty = (low, high)` | limits on the uncertainty at ``k = 2``, in the same unit as `value` |
| `relative_uncertainty = (nothing, 0.01)` | the uncertainty at ``k = 2`` divided by the absolute value, so it works for any property; it may be written as `(nothing, 1u"percent")` or in `u"ppm"` (also the limits of `fraction`) |

[`phases`](@ref) and [`measurement_methods`](@ref) list what the data of a selection (or of a database) have, with the number of points, the most frequent first. A phase or a method that matches nothing is an `ArgumentError`, like a property.

```@example sel
water = points(db; component = "water", exact = true, property = "Mass density")
first(phases(water).phase, 3), first(measurement_methods(water).method, 3)
```

```@example sel
liquid = points(water; phase = "liquid")
accurate = points(liquid; relative_uncertainty = (nothing, 1.0e-4))
length(water), length(liquid), length(accurate)
```

The fractions are those of the source, and a compound has a different position (`x1`, `x2`) in each system, so `fraction` finds it by name. `xkind` makes sure that the numbers are of the scale you mean:

```@example sel
binary = points(db; component = ["carbon dioxide", "methane"], match = :all, exact = true)
length(points(binary; xkind = "mole", fraction = "methane" => (0.4, 0.6)))
```

`value` and `uncertainty` are plain numbers in the native unit of every property, so give them with one `property` or with properties that share a unit. With `unit`, or with quantities, the limits are converted for each property of that dimension and the properties of another one are left out:

```@example sel
length(points(water; value = (0.9, 1.1), unit = "g/cm3")), length(points(water; value = (900, 1100) .* u"kg/m^3"))
```

!!! note "Points without the field are excluded"
    As with `temperature` and `pressure`, a point that states no phase, no method or no uncertainty cannot be shown to satisfy the filter on it, so it is not selected. An uncertainty that cannot be taken to ``k = 2`` without inventing data (a level of confidence the package does not know) is treated as missing; see `policy` in [`table`](@ref).

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
