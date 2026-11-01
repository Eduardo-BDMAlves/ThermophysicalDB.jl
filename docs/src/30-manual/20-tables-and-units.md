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

With `quantities = Unitful` (the module of the package, loaded with `using Unitful`), the columns `temperature`, `pressure`, `value`, `unc` and `unc_k2` hold `Unitful` quantities, so units travel with the numbers:

```@example tab
tu = table(v; quantities = Unitful)

uconvert.(u"°C", tu.temperature[1:3]), uconvert.(u"mbar", tu.value[1:3])
```

Vectors of quantities are fast only when every element has the same type, which means the same unit. That is why `quantities = Unitful` requires a selection with a single unit and tells you how to fix one that has several:

```@example tab
mixed = points(db; component = "water", exact = true, property = ["Mass density", "Viscosity"],
               temperature = (20u"°C", 30u"°C"))
try
    table(mixed; quantities = Unitful)
catch err
    println(sprint(showerror, err))
end
```

Narrow the selection by `property`, or leave `unitful` off and use the `unit` column, which handles any mixture of properties.

## Exact conversions

The package converts units on its own for the names of temperature and pressure (`reference_summary`) and for the unit catalog (`units = :si`). Nothing there is a typed-in decimal: each unit is written from its definition with rational numbers, so the inch is ``254/10\,000`` m, the pound is ``45\,359\,237/10^8`` kg, the standard gravity is ``980\,665/10^5`` m/s², and the psi is the pound-force per square inch derived from them, ``8\,896\,443\,230\,521/1\,290\,320\,000`` Pa. The rankine is exactly ``5/9`` K and the fahrenheit scale is the rankine scale shifted by 459.67 °R.

Conversions between units, such as °R to °F to °C to K, are composed in rationals, and the constants are rounded to `Float64` once, at the end. The result is the correctly rounded value of the exact conversion and no error accumulates along the chain. An arithmetic overflow throws an error and never gives a wrong number.

On a column the conversion is one pass over the data: the identity is a copy, a change of scale is a multiplication, and a scale with an offset (°C, °F) is one fused multiply-add. A difference of two values (an uncertainty) uses only the scale. After that, any other change of unit is left to the units package you use.

## Another unit for a property

`unit` gives the value and its uncertainties in a unit of your choice, as long as it measures the same quantity and the selection has a single unit:

```julia
v = points(ds; property = "Thermal conductivity", component = "methane")
t = table(v; unit = "mW/m/K")
t = table(v; unit = "Btu/hr/ft/degF")      # engineering units
t = table(v; unit = u"mW/m/K")             # a unit object of Unitful: the columns are quantities
```

As text, the unit is read by the exact parser of the package. It understands the SI prefixes (`mbar`, `kJ/mol`, `cP`, `mmol/L`), products and quotients, integer powers (`m2`, `ft2`) and the symbols `Pa`, `bar`, `atm`, `torr`, `mmHg`, `psi`, `inch`/`in`, `ft`, `yd`, `lb`, `lbf`, `min`, `h`/`hr`, `day`, `L`, `gal`, `P`, `St`, `cal` (thermochemical, 4.184 J), `cal_IT` (4.1868 J) and `Btu` (International Table Btu, 1055.05585262 J; `Btu_th` is the thermochemical one). The dimensions are compared first, so `"kPa"` for a conductivity is an error, and a string with the wrong dimension is reported with both units.

Inside a compound unit, `degC`, `degF`, `degR` and `Ra` are temperature intervals (1 K, 5/9 K), because a conductivity per degree has no offset. As the unit of a property in kelvin, `degC` and `degF` are refused: their offset belongs to temperatures, not to properties.

A unit object is converted by its package, which returns the factor once (Unitful gives an exact rational when it can); the conversion of the column is then the same single pass.

## Temperature and pressure in other units

`temperature_unit` and `pressure_unit` do the same for the columns `temperature` and `pressure`:

```julia
table(v; temperature_unit = "degC", pressure_unit = "bar")
table(v; temperature_unit = u"°F", pressure_unit = u"psi")     # Unitful quantities
```

A temperature scale with an offset is converted as ``y = a x + b`` with exact constants (``-273.15`` for degC, ``5/9`` and ``45967/180`` for degF), and every other temperature or pressure unit, however prefixed or composed (`"mK"`, `"mbar"`, `"N/m2"`, `"lbf/in2"`), is a change of scale. `pressure_unit` cannot be combined with `units = :si`.

## Who converts: this package or yours

When you give a unit object of Unitful (or another package), the package asks it for its text, for example `"mW m^-1 K^-1"`, and reads it with the exact parser. If every symbol is known, the conversion is done here with rational arithmetic, in one pass over the column, and your package only receives the converted numbers with the unit attached. If a symbol is not known (`erg`, `dyn`, ...), your package computes the factor or converts the numbers itself, and the result is as exact as that package is. DynamicQuantities and FlexUnits store quantities in SI and do not keep the written unit, so they always take the second path.

## What you give is converted the same way

A limit of `points`, a value or an uncertainty with a unit, and the units of `reference_summary` follow the same rule as the tables. The package asks the quantity for its unit as text and, if every symbol is known, converts the number here: the number is taken as the exact rational that the float is, the conversion is exact, and the result is rounded once. Only a unit with a symbol that is not known is converted by your package. So `77.0u"°F"` is 298.15 K and `1.0u"psi"` is exactly the correctly rounded kilopascal, not the value of Unitful's own approximation.

The names of a scale are aliases: `°C`, `degC` and `℃` are the same definition, as are `°F`, `degF` and `℉`, and `°R`, `degR`, `Ra`. A property that is a temperature (a critical temperature in kelvin, for example) can be asked in `degC` or `degF` with `unit`: the value gets the offset and the uncertainty only the scale, since an uncertainty of 0.01 °C is 0.01 K.

A quantity of the wrong dimension, such as `1u"m"` for a temperature, is an `ArgumentError` for every package of units.

## Other unit packages

`quantities` chooses the package that builds the columns, and the package must be loaded (the extension is activated by loading it):

```julia
using ThermophysicalDB, DynamicQuantities
t = table(v; quantities = DynamicQuantities)
```

| Package | Value of `quantities` | Notes |
|---|---|---|
| [Unitful.jl](https://github.com/JuliaPhysics/Unitful.jl) | `Unitful` | the unit is part of the type, so a column is as compact as a `Vector{Float64}` |
| [DynamicQuantities.jl](https://github.com/SymbolicML/DynamicQuantities.jl) | `DynamicQuantities` | the unit is a value, and the quantities are converted to SI when they are built |
| [FlexUnits.jl](https://github.com/Deltares/FlexUnits.jl) | `FlexUnits` | experimental; the quantities are converted to SI when they are built |

The data are stored as `Float64` in the units of the archive (K, kPa and the unit of each property); quantities exist only at the boundary of the package, when you give a limit and when you ask for a table. The limits of `points` and the units of `reference_summary` accept the quantities of any loaded package.

An uncertainty is an interval, not a point of a scale: ``0.01\,^\circ\mathrm{C}`` is ``0.01\,\mathrm{K}``. DynamicQuantities has no affine units, and FlexUnits applies the offset when the quantity is built, so write a temperature difference in K with these two.

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
