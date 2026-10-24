```@meta
CurrentModule = ThermophysicalDB
```

# [Getting started](@id 10-getting-started)

This page takes you from an empty Julia environment to a plotted selection of experimental points.

## Installation

ThermophysicalDB.jl requires Julia 1.10 or later. Until the package is registered in the General registry, install it from GitHub:

```julia-repl
pkg> add https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl
```

To follow the plotting examples you also want a plotting package. The tutorials of this site use [CairoMakie](https://docs.makie.org/stable/) and [Unitful](https://painterqubits.github.io/Unitful.jl/stable/):

```julia-repl
pkg> add CairoMakie Unitful
```

!!! tip "Start Julia with several threads"
    Parsing the archive for the first time runs in parallel. `julia -t auto` uses every core of your machine and makes that first build noticeably faster. Later sessions load the binary cache and do not parse anything.

## Build the database

```@setup gs
Main.DocsSetup.activate!()
```

Everything starts with one call:

```@example gs
using ThermophysicalDB

db = database(progress = false)
```

What that call does depends on what is already on your machine:

| Situation | What `database()` does |
| :-- | :-- |
| First use ever | Downloads the ThermoML Archive from NIST (about 190 MB), verifies its SHA-256 digest, parses the 11 923 articles, and writes a binary cache next to the archive. This takes a few minutes. |
| Later sessions | Checks whether NIST published a newer archive (it warns you if so, see [Updates](@ref updates)), then loads the binary cache, which is much faster than parsing. |
| Same session | Returns the object it already built, immediately. |

The result is a [`Dataset`](@ref): the whole archive in memory, organised as a few relational tables (see the [data model](@ref data_model)). You rarely touch it directly; you hand it to [`points`](@ref).

!!! info "Where do the files go?"
    `data_dir()` tells you. On Windows it is `%LOCALAPPDATA%\ThermophysicalDB`, on macOS `~/Library/Application Support/ThermophysicalDB` and on Linux `~/.local/share/ThermophysicalDB`. You can move it with [`set_data_dir!`](@ref) or with the environment variable `THERMOPHYSICALDB_DATA_DIR`.

## Select points

[`points`](@ref) returns a lazy selection. Every keyword is optional and they combine with AND:

```@example gs
v = points(
    db;
    component = "ethanol", exact = true,      # pure ethanol, not mixtures that contain it
    property = "Viscosity",
    temperature = (20, 30) .+ 273.15,         # plain numbers are kelvin
)
```

The printed table shows the first rows. The selection itself stores only row numbers, so refining it is cheap:

```@example gs
v2 = points(v; year = (2000, nothing))   # only articles from 2000 on
length(v), length(v2)
```

The [manual page on selecting points](@ref selecting) lists every filter, including limits written with Unitful units.

## Get the columns

[`table`](@ref) materialises a selection as a `NamedTuple` of columns, one entry per field:

```@example gs
t = table(v2)
keys(t)
```

| Column | Meaning |
| :-- | :-- |
| `source`, `doi`, `year` | Where the point comes from: the database, the DOI of the article and its year. |
| `components`, `xkind` | The system (`"ethanol + water"`) and what `x1, x2, x3` express (`"Mole fraction"`, …). |
| `property`, `method`, `phase` | What was measured, how, and in which phase. |
| `temperature`, `pressure` | Conditions, in K and kPa (kPa becomes Pa with `units = :si`). `NaN` when the source gives none. |
| `x1`, `x2`, `x3` | Composition of the components, in the order of `components`. `NaN` where a component does not exist. |
| `value`, `unit` | The measured value and its unit. |
| `unc`, `unc_k`, `unc_level` | The uncertainty exactly as published: value, coverage factor and level of confidence (when given). |
| `unc_k2` | The expanded uncertainty restated at ``k = 2`` (see [Uncertainty](@ref uncertainty)). |

Each column is a plain `Vector`, so plotting, statistics and fitting need no conversion:

```@example gs
using Statistics
mean(t.value), extrema(t.temperature)
```

## Plot it

```@example gs
using CairoMakie

fig = Figure(size = (720, 420))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "η [mPa s]", title = "Viscosity of ethanol")
scatter!(ax, t.temperature, t.value .* 1e3; markersize = 10)
fig
```

!!! tip "Next steps"
    - The [tutorials](20-tutorials/10-hexane-conductivity.md) walk through complete analyses with real data.
    - The [manual](30-manual/10-selecting.md) documents every function and the reasoning behind its behaviour.
    - If the download does not work on your network, see [Downloads, updates and cache](@ref updates).
