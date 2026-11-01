```@meta
CurrentModule = ThermophysicalDB
```

# [Tables, units and Unitful](@id tables_units)

A selection becomes data you can compute with in two steps: [`table`](@ref) turns it into columns, and the unit options decide how those columns express the numbers.

```@setup tab
Main.DocsSetup.activate!()
```

```@example tab
using ThermophysicalDB, Unitful, DataFrames

db = database(progress = false)
v = points(db; component = "water", exact = true, property = "Vapor or sublimation pressure",
           temperature = (20u"°C", 30u"°C"))
```

## Columns

`table(v)` returns a `NamedTuple` whose fields are plain vectors of equal length: one row per point.

```@example tab
t = table(v)
keys(t)
```

| Column | Type | Meaning |
| :-- | :-- | :-- |
| `source`, `doi` | `String` | database and article the point comes from |
| `year` | `Int16` | publication year |
| `components`, `xkind` | `String` | the system, as `"a + b"`, and the kind of composition (`"Mole fraction"`, `"Molality, mol/kg"`, …) |
| `property`, `method`, `phase` | `String` | what was measured, the experimental method and the phase |
| `temperature`, `pressure` | `Float64` | state conditions, in K and kPa (Pa with `units = :si`) |
| `x1`, `x2`, `x3` | `Float64` | composition of each component, in the order of `components` |
| `value`, `unit` | `Float64`, `String` | the measured value and its unit |
| `unc`, `unc_k`, `unc_level` | `Float64` | uncertainty as published, its coverage factor and its level of confidence (as a fraction) |
| `unc_k2` | `Float64` | expanded uncertainty restated at ``k = 2`` |

An absent number is always `NaN`, never `missing`, so every numeric column stays a dense `Vector{Float64}` and arithmetic and plotting need no special handling. Use `isfinite` to keep the points that have a value:

```@example tab
count(isfinite, t.unc_k2), length(t.unc_k2)
```

## Native units or SI

By default `value`, `unc`, `unc_k2` and `pressure` are reported in the unit of the source, written in the `unit` column. This is lossless and mirrors the publication. With `units = :si`, they are converted to the coherent SI unit of the same dimension:

```@example tab
native = table(v)
si = table(v; units = :si)

(native = (native.value[1], native.unit[1]), si = (si.value[1], si.unit[1]))
```

Temperatures are always kelvin, and compositions are never converted: `xkind` tells you what they express.

## Unitful columns

With `unitful = true`, the columns `temperature`, `pressure`, `value`, `unc` and `unc_k2` hold `Unitful` quantities, so units travel with the numbers:

```@example tab
tu = table(v; unitful = true)

uconvert.(u"°C", tu.temperature[1:3]), uconvert.(u"mbar", tu.value[1:3])
```

Vectors of quantities are fast only when every element has the same type, which means the same unit. That is why `unitful = true` requires a selection with a single unit and tells you how to fix one that has several:

```@example tab
mixed = points(db; component = "water", exact = true, property = ["Mass density", "Viscosity"],
               temperature = (20u"°C", 30u"°C"))
try
    table(mixed; unitful = true)
catch err
    println(sprint(showerror, err))
end
```

Narrow the selection by `property`, or leave `unitful` off and use the `unit` column, which handles any mixture of properties.

## What the source says about the data

`table(v; details = true)` adds to every point what the article states about it, with the same convention for what it does not state (`NaN`, `""` or `-1`):

| Column | Content |
|---|---|
| `purity1`, `purity2`, `purity3` | final purity of the sample of each component, as a fraction |
| `purity_kind1`, ... | the basis of that purity: `mass`, `mole`, `volume` or `unspecified` |
| `purity_basis1`, ... | `supplier`, `measured` or `estimated` |
| `purpose` | purpose of the experiment, as the article declares it |
| `unc_method` | how the uncertainty was evaluated |
| `digits`, `temperature_digits`, `pressure_digits` | significant digits the article gave (`-1` when not given) |

The samples themselves, one row each, and their purification steps are available as tables with [`sample_table`](@ref) and [`purity_step_table`](@ref); both accept a dataset or a selection.

## Tables.jl

A `DataView` is itself a [Tables.jl](https://tables.juliadata.org) source, and `table` returns a Tables.jl column table, so anything in the ecosystem accepts them directly:

```@example tab
df = DataFrame(v)
first(df[:, [:components, :property, :temperature, :value, :unit]], 4)
```

```julia
using CSV
CSV.write("water_vapor_pressure.csv", v)          # a selection is a table
CSV.write("water_si.csv", table(v; units = :si))  # so is the NamedTuple
```

## Sources of the data

```@raw html
<details class="details custom-block"><summary>The articles behind the data of this page</summary>
```

```@example tab
Main.DocsCredits.credits(v, mixed)
```

The articles of the whole documentation, with a download of the BibTeX file, are in [Data credits](@ref data_credits).

```@raw html
</details>
```
