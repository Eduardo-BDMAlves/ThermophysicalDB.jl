```@meta
CurrentModule = ThermophysicalDB
```

# [Tables for a paper: exporting points and references](@id tutorial_export)

A paper that uses published measurements needs three things: a table that says **which articles** the data come from, a table of **the points** themselves, and a bibliography whose keys both tables cite. This tutorial produces the three from one selection, with no hand typing, and ends with the files ready to include in a LaTeX document.

The selection is the thermal conductivity of liquid toluene. The thermal conductivity, ``\lambda``, is the constant of Fourier's law, ``\mathbf{q} = -\lambda \nabla T``: the heat flux that a temperature gradient drives through the fluid. We keep the three most recent articles that measured it.

## Select the three most recent articles

```@example export
using ThermophysicalDB, Markdown

db = database()
v = points(db; component = "toluene", exact = true, property = "Thermal conductivity")

# One summary row per article, ordered by year: the last three DOIs are the most recent.
dois = unique(reference_summary(v; online = false, cache = false, progress = false).doi)[(end - 2):end]
selection = DataView(v.dataset, sort!(reduce(vcat, [points(v; doi = doi).rows for doi in dois])))
length(selection.rows)
```

Each article is picked with the `doi` filter of [`points`](@ref), and the three selections are joined into one [`DataView`](@ref).

## The table of references

[`reference_summary`](@ref) condenses the selection into one row per article and property: how many points, the range of temperature and pressure, the method and the uncertainty. [`markdown_table`](@ref) turns it into a table for a README or a report:

```@example export
refs = reference_summary(selection; progress = false)
Markdown.parse(markdown_table(refs; notice = false))
```

The method is abbreviated by its initials, and a note under the table explains the abbreviation. The same summary as LaTeX is a `longtable` with `booktabs` rules. The first column holds `\cite{key}`, with the keys of the `.bib` written below:

```@example export
print(latex_table(refs; notice = false))
```

[`csv_table`](@ref) writes the same summary for a spreadsheet.

## The table of points

[`export_points`](@ref) writes the points. Its first argument is a directory, created if needed, and `formats` chooses the files; the references table and the `.bib` are written next to them:

```@example export
dir = mktempdir()
report = export_points(
    joinpath(dir, "toluene"), selection;
    formats = (:csv, :md, :tex), progress = false,
)
report
```

The table of points holds only what is specific to each point: the article (`reference`, the same key as in the references table), the conditions, the value and its uncertainty. What the references table already says, or what is the same in every row, is not repeated: the method and the phase of the article, the system when the selection has a single one (here toluene) and the property when it has a single one. `details = true` writes those columns too, for example to filter the points in a spreadsheet; a selection with several systems or properties keeps the columns that tell them apart.

Every header carries its unit in brackets. This is the LaTeX version, ready for `\input{}`:

```@example export
tex = read(joinpath(dir, "toluene", "toluene.tex"), String)
println(join(split(tex, '\n')[2:min(end, 22)], '\n'))
```

The first line, left out of the listing, is the notice of the next section. The Markdown version, for a README or a notebook, has the same columns and renders as a table; its notice is an HTML comment, so it is not shown:

```@example export
md = readlines(joinpath(dir, "toluene", "toluene.md"))
Markdown.parse(join(md[findfirst(startswith("|"), md):min(end, findfirst(startswith("|"), md) + 6)], '\n'))
```

The CSV version has the same columns; its first line is also the notice, so a reader that expects the header on the first line skips it (`header = 2` in CSV.jl):

```@example export
csv = readlines(joinpath(dir, "toluene", "toluene.csv"))
println(join(csv[2:min(end, 7)], '\n'))
```

## The complete `.bib`

The `.bib` holds the entry of every article of the selection, the entries that credit the ThermoML Archive and the ThermoML standard, the entry of this package after a comment that asks you to cite it, and the notice as a BibTeX comment. This is the whole file:

```@example export
print(read(joinpath(dir, "toluene", "toluene.bib"), String))
```

For each article the entry delivered by the DOI resolver is compared with the metadata stored in the archive. The resolver wins where both have a field and the archive fills the gaps; without a network connection the entries come from the archive alone. A key is the surname of the first author, the year and the first word of the title, in lower case (`zeng2019` followed by that word), the form a reference manager generates; `a`, `b`, ... are added when two articles give the same key.

## Use it in a LaTeX document

The keys are those of the `.bib` and of the `reference` column, so the text cites them as they are. This document is written with the keys of the three articles of this selection:

```@example export
cites = join(unique(refs.key), ",")
println("""
\\documentclass{article}
\\usepackage{booktabs, longtable}
\\begin{document}
Thermal conductivity of liquid toluene~\\cite{$cites}.

\\input{toluene_references.tex}   % the table of references
\\input{toluene.tex}              % the table of points

\\bibliographystyle{unsrt}
\\bibliography{toluene}
\\end{document}""")
```

## The notice

The data of this tutorial come from one database, the NIST/TRC ThermoML Archive, and the files carry the notice of that database: where the data come from, how to cite the dataset, that the data were reformatted, and that the articles should be credited. It is the first line of the `.csv` and `.tex` (after `#` and `%`), a comment at the top of the `.bib` and of the tables of references, the `origin` entry of a `.json`, the `origin` group of a `.jld2` and the `origin` sheet of a `.xlsx`:

```@example export
print(ThermophysicalDB.notice_text())
```

The notice belongs to the database, not to the package: it is the one of the ThermoML Archive, the only database supported so far, and the data of another database that comes with its own notice would add its lines here. The table functions take `notice = false` for a table that goes onto a slide, as in the listings above.

## Where to go from here

- [`write_references`](@ref) writes the `.bib`, `.tex`, `.md` and `.csv` of the references in one call.
- Excel (`using XLSX` adds the workbook to the default formats), JSON, JLD2 and a ThermoML subset (`formats = :thermoml`) are in [Exporting points](@ref exporting_points); the options of the references are in [Exporting the references](@ref exporting_references).
- Remove suspect points before exporting with [`find_outliers`](@ref): its `kept` view goes straight into `export_points`.
