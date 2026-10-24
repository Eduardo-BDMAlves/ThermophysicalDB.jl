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

## The catalog of units

The archive uses a closed set of units. All of them are known to the package, which converts them to SI and to Unitful. A property without a unit in its name (a refractive index, a ratio) is dimensionless and has an empty `unit`.

| Native unit (`unit` column) | Unitful | SI unit (`units = :si`) | Factor to SI |
| :-- | :-- | :-- | --: |
| `K` | `K` | `K` | 1 |
| `kPa` | `kPa` | `Pa` | 1000 |
| `kg/m3` | `kg/m^3` | `kg/m^3` | 1 |
| `Pa*s` | `Pa*s` | `Pa*s` | 1 |
| `m/s` | `m/s` | `m/s` | 1 |
| `N/m` | `N/m` | `N/m` | 1 |
| `S/m` | `S/m` | `S/m` | 1 |
| `m2/s` | `m^2/s` | `m^2/s` | 1 |
| `W/m/K` | `W/m/K` | `W/m/K` | 1 |
| `kJ/mol` | `kJ/mol` | `J/mol` | 1000 |
| `J/K/mol` | `J/K/mol` | `J/K/mol` | 1 |
| `J/K/kg` | `J/K/kg` | `J/K/kg` | 1 |
| `J/K/m3` | `J/K/m^3` | `J/K/m^3` | 1 |
| `m3/mol` | `m^3/mol` | `m^3/mol` | 1 |
| `m3/kg` | `m^3/kg` | `m^3/kg` | 1 |
| `m6/mol2` | `m^6/mol^2` | `m^6/mol^2` | 1 |
| `mol/kg` | `mol/kg` | `mol/kg` | 1 |
| `mol/m3` | `mol/m^3` | `mol/m^3` | 1 |
| `mol/dm3` | `mol/dm^3` | `mol/m^3` | 1000 |
| `S*m2/mol` | `S*m^2/mol` | `S*m^2/mol` | 1 |
| `1/K` | `K^-1` | `K^-1` | 1 |
| `1/kPa` | `kPa^-1` | `Pa^-1` | 0.001 |
| `kPa/K` | `kPa/K` | `Pa/K` | 1000 |
| `K/kPa` | `K/kPa` | `K/Pa` | 0.001 |
| `kPa*kg/mol` | `kPa*kg/mol` | `Pa*kg/mol` | 1000 |
| `kPa*dm3/mol` | `kPa*dm^3/mol` | `Pa*m^3/mol` | 1 |

Conversions are purely multiplicative, since temperatures in the archive are always kelvin. If the archive ever introduces a unit that is not in this catalog, `units = :si` leaves that property in its native unit, and `unitful = true` raises an error instead of guessing.
