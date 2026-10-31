```@meta
CurrentModule = ThermophysicalDB
```

# [Exporting points](@id exporting_points)

[`export_points`](@ref) writes the points of a selection as a **directory of tables** that other programs can read. The first argument is the name of the directory, which is created if it does not exist, and `formats`, a tuple of symbols, chooses the files. The same selection becomes a spreadsheet, a table for a statistics package, a Markdown or LaTeX table for a text, or a file for another Julia session.

```julia
using ThermophysicalDB

db = database()
v = points(db; component = "water", exact = true, property = "Mass density")

export_points("data/water", v)                          # the default formats
export_points("data/water", v; formats = (:csv, :md))   # only these
export_points("data/water", v; formats = :thermoml)     # a subset in the ThermoML structure
```

| Format | File written |
|---|---|
| `:csv` | `water.csv`, one table; the unit of every column is in its header |
| `:md` | `water.md`, the same table as a Markdown (GitHub) table |
| `:tex` | `water.tex`, the same table as a LaTeX `longtable`, ready to include in a text |
| `:json` | `water.json`, one record per point |
| `:jld2` | `water.jld2`, the columns, the units and the references as Julia data |
| `:xlsx` | `water.xlsx`, one sheet per system, a `references` sheet and an `origin` sheet; written when XLSX.jl is loaded |
| `:thermoml` | `water.thermoml.json`, a subset of the ThermoML schema, for the selected points only |

The default is `(:csv, :md, :tex, :json, :jld2)`, and `:xlsx` joins it when the XLSX package is loaded (`using XLSX`). A [`DataView`](@ref) or the whole [`Dataset`](@ref) can be given. A format that is not in the table is an error, so a typo never silently writes something else.

!!! note "The path is a directory, not a file"
    The extension of the path does not choose the format any more. `export_points("data/water.csv", v)` is an error that tells you so, since it is most likely a mistake; use `export_points("data/water", v; formats = :csv)`. A directory whose name has a dot (`data/run.v2`) is written with a trailing slash: `"data/run.v2/"`.

## What a table contains

The tables hold **points and nothing else**. Each row is one measured value with the conditions it was measured at; what describes the article lives in the references table. The two are linked by the `reference` column, and you choose how it reads:

| `reference =` | The cell holds | Example |
|---|---|---|
| `:key` (default) | the BibTeX key, the same as in [`bibtex`](@ref) | `chirico2003thermoml` |
| `:text` | the citation written out | `Chirico et al. (2003)` |
| `:doi` | the DOI | `10.1016/S0021-9614(02)00306-7` |

The columns follow [`table`](@ref), with `reference` in place of `source`, `doi` and `year`. Each header carries its unit in square brackets:

```text
reference,components,xkind,property,temperature [K],pressure [kPa],x1 [-],value [kg/m3],unc [kg/m3],unc_level [-],unc_k2 [kg/m3]
moe1990density,water,Mole fraction,Mass density,293.15,101.325,1.0,998.0,0.1,0.95,0.1020…
```

- When the selection mixes properties, the value columns read `value [see unit]` and a `unit` column says which unit each row has.
- The composition columns `x1`, `x2` and `x3` carry the unit of the composition they express (`-` for fractions, `mol/kg` for a molality); `xkind` says which one it is, and if the selection mixes kinds the header reads `x1 [see xkind]`.
- What the references table already tells, and what is the same in every row, is not repeated. The `method` and the `phase` of each point are not written (the references table gives them per article); `components` is left out when the selection has one system, and `property` when it has one property. A selection with several systems or properties keeps those columns, since the rows could not be read without them. `details = true` writes all four, which is useful when a file is processed on its own, for instance to filter by phase in a spreadsheet.
- A column that is empty for the whole selection is left out too (a pure fluid has `x1` but no `x2`), and an empty cell is a missing value: nothing in a `.csv` or `.xlsx`, no member in a `.json` record.
- `units = :si` converts values, uncertainties and the pressure to SI, as in [`table`](@ref). `unc` is the uncertainty as the article reported it and `unc_k2` is restated at ``k = 2`` according to `policy`.

## The references table

A `.csv`, `.md` or `.tex` has no room for a second table, so with `references = true` (the default) the references are written next to each of them: `water_references.csv`, `water_references.md` and `water_references.tex`, with one row per article and property as in [`reference_summary`](@ref), and `water.bib`. The keys in the `reference` column are the keys of that file. The other formats carry the references themselves: the `references` sheet of an `.xlsx`, the `references` entry of a `.json` and the `references` group of a `.jld2`. Pass `references = false` to write the points only.

!!! warning "`references = false` with `reference = :key`"
    A `.csv`, `.md` or `.tex` then holds BibTeX keys and nothing to resolve them with, and the DOI of each article, which credits its authors, cannot be recovered from the files. [`export_points`](@ref) warns you. Keep `references = true`, or write the DOI (`reference = :doi`) or the citation (`reference = :text`) into the table. The `.xlsx`, `.json` and `.jld2` hold their references table inside the file and do not need the warning.

The BibTeX entries are fetched from the DOI resolver the first time, as in [`bibtex`](@ref), and cached; `online = false` uses only the cache and the archive, so the export works offline. `online`, `cache`, `refresh` and `progress` act as there.

### Citing the package

The `.bib` ends the credits with the entry of this package, so a paper that uses the export cites the software as well as the data: a comment asks you to cite it, and the entry follows. It is built from the `CITATION.cff` of the installed version, so it carries that version and, once the release has a DOI (Zenodo) or the file names an article of the package as its `preferred-citation`, the DOI and the article as a second entry, with no change on your side. No table mentions the package: it appears in the `.bib` only. `include_package = false` leaves it out.

## The files of a directory

```julia
export_points("data/Fluid", v)
# data/Fluid/Fluid.csv
# data/Fluid/Fluid.md
# data/Fluid/Fluid.tex
# data/Fluid/Fluid.json
# data/Fluid/Fluid.jld2
# data/Fluid/Fluid_references.csv
# data/Fluid/Fluid_references.md
# data/Fluid/Fluid_references.tex
# data/Fluid/Fluid.bib
```

All the files are built from the same selection and the same bibliography, so they agree: the same columns, the same units, the same keys. The references table is written in each table format that was chosen (`.csv`, `.md`, `.tex`), and the `.bib` always. Asking for `:xlsx` without loading XLSX.jl is an error that says what to load.

The returned [`ThermophysicalDB.ExportReport`](@ref) lists the files written and the number of points and articles. Nothing is written for an empty selection.

## Markdown

`name.md` is the points table in the format of GitHub, Quarto, Jupyter and Documenter: header, an alignment line (text columns to the left, numbers to the right) and one row per point, with the same columns and units as the `.csv`. A pipe inside a text is escaped. With `reference = :key` the reference column holds the BibTeX key, and `name_references.md` is the table of the articles, as [`markdown_table`](@ref) writes it. The notice is an HTML comment at the top, invisible when the page is rendered.

## LaTeX

`name.tex` is the points table as a `longtable` with `booktabs` rules (load `longtable` and `booktabs`), with the same columns and headers as the `.csv`. With `reference = :key` the reference column holds `\\cite{chirico2003thermoml}`, which resolves against the `name.bib` written with it; `reference = :text` writes the citation out instead. `name_references.tex` is the table of the articles, one row per article and property with the ranges of temperature and pressure and the uncertainty, as [`latex_table`](@ref) writes it, citing the same keys.

A worked example, with the output of every step, is the tutorial [Tables for a paper](@ref tutorial_export).

Exporting therefore gives, in one call, the raw points in several formats, the summary of what each article covers, and the bibliography: the data to process and the tables and references to include in a text.

## Where the data come from

When some of the points come from the ThermoML Archive, every file carries one notice, the same in all formats because the package writes it from a single place. It gives

- the origin: the archive, its address, the DOI of the dataset and the version of the archive on this computer;
- the full citation of the dataset (version 1.2);
- that the data are modified (reformatted, possibly converted to other units) and were not evaluated or endorsed by NIST/TRC;
- a reminder to credit the original article of each point, by its DOI, and the archive;
- the address of the terms of use;
- who exported the file and when.

See [About the data](@ref 40-about-data) for what to cite. Points that come from elsewhere, such as your own data, carry no notice. The notice sits where each format can hold it without disturbing the table:

| Format | Where |
|---|---|
| `.csv` | the first line, starting with `#`, before the headers |
| `.tex` | the first line, a `%` comment |
| `.md` | an HTML comment (`<!-- ... -->`) before the table |
| `.xlsx` | a separate sheet called `origin` |
| `.json` | the first entry of the top-level object, `origin` |
| `.jld2` | the `origin` group |
| `name.bib`, `name_references.csv`, `name_references.tex` | see [Exporting the references](@ref exporting_references) |

To read a `.csv` skip that line:

```julia
using CSV, DataFrames
df = CSV.read("data/water/water.csv", DataFrame; comment = "#")
```

## Excel

Writing `.xlsx` files uses [XLSX.jl](https://github.com/JuliaData/XLSX.jl), which is loaded on demand: install it once and load it before exporting.

```julia
using XLSX
export_points("data/water", v)                          # the workbook comes with the others
export_points("data/water", v; formats = :xlsx)         # or alone
```

By default each system gets its own sheet, named after its components and shortened to the 31 characters Excel allows (`water`, `carbon dioxide + methane`); a sheet holds up to 1,048,575 points. `sheets = :single` puts all the points in one sheet called `points`. Within a sheet, columns that are empty for that system are left out, so a pure fluid has no `x2`.

## JSON

The default `.json` has one record per point, so each point can be read on its own:

```json
{
  "origin": { "data_origin": "NIST/TRC ThermoML Archive", "...": "..." },
  "metadata": { "format": "ThermophysicalDB points", "version": 1, "points": 2, "...": "..." },
  "units": { "temperature": "K", "pressure": "kPa", "value": "kg/m3", "...": "..." },
  "points": [
    {"reference": "moe1990density", "components": "water", "property": "Mass density", "temperature": 293.15, "pressure": 101.325, "x": [1.0], "value": 998.0, "unit": "kg/m3", "unc": 0.1, "unc_k2": 0.102},
    {"...": "..."}
  ],
  "references": { "temperature_unit": "K", "pressure_unit": "MPa", "rows": [ {"key": "moe1990density", "...": "..."} ] }
}
```

The composition of a point is the array `x`, with one entry per component in the order of `components`. Values that are not finite are not written.

### In the ThermoML format

`formats = :thermoml` writes the selected points in the structure of the archive's own files instead: one object per article with its `Citation`, its `Compound`s and the `PureOrMixtureData` that hold **only the selected points**. It is a subset, so what the package does not keep is absent, and the units are those of the archive whatever `units` says. Because the structure is the one the package reads, such a file can be read back with the same parser.

```julia
export_points("data/water", v; formats = :thermoml)   # data/water/water.thermoml.json
```

This layout needs neither the references nor the network. Compounds are numbered within each article, as in the archive, and every point is one row of `NumValues`. Properties whose name the archive writes with a presentation (a ratio or a difference to a reference state) keep that qualifier in `ePropName`. A composition without a known kind cannot be typed in ThermoML and is not written.

## Julia

A `.jld2` holds each column of the table as `points/<name>`, the units as `units/<name>`, the headers as `metadata/headers`, the references as `references/<column>` and the origin note as `origin/<entry>`. Values are plain numbers; the units are text.

```julia
using JLD2
jldopen("data/water/water.jld2") do file
    T = file["points/temperature"]
    ρ = file["points/value"]
    file["units/value"]       # "kg/m3"
end
```

## Choosing a format

| If you want to | Use |
|---|---|
| open the data in a spreadsheet, with one sheet per system | `.xlsx` |
| load them in R, Python, Julia or Matlab | `.csv` (a plain table) or `.json` |
| keep every number exactly and reload it quickly in Julia | `.jld2` |
| hand the data to something that reads ThermoML | `.thermoml.json` |
| paste the table in a README, a Quarto or a Jupyter text | `.md` |
| give a colleague everything | the default directory |

Numbers are written with the shortest text that reads back exactly the same `Float64`, in `.csv` and `.json` as well.
