```@meta
CurrentModule = ThermophysicalDB
```

# [Exporting the references](@id exporting_references)

Every measurement in the database belongs to a published article. This page shows how to export the articles behind a selection, as BibTeX entries and as a summary table. [`bibtex`](@ref) returns the BibTeX entries of all the articles behind a selection, and [`write_bibtex`](@ref) writes them to a file:

```julia
using ThermophysicalDB

db = database()
v = points(db; component = "water", exact = true, property = "Mass density")

report = write_bibtex("water.bib", v)
```

A [`DataView`](@ref) (the result of [`points`](@ref)) or the whole [`Dataset`](@ref) can be given. Each article appears once, however many points it contributes.

## Where an entry comes from

Two sources describe an article, and both are used:

1. **The DOI.** The entry is requested from the DOI resolver (with DOI2BibTeX.jl), which returns the publisher's own record, with the journal title abbreviated.
2. **The archive.** The ThermoML Archive stores the authors, title, journal, year, volume, pages and DOI of each article.

The two are compared field by field. The DOI entry is the one written. A field that only the archive has is added to it. When both have a field and the values differ (compared without case, accents or punctuation, so `541-612` and `541--612` agree), the entry from the DOI is kept and the disagreement is recorded in the report. An article whose DOI cannot be resolved, or that has none, is written from the archive alone.

```julia
report                  # counts: articles, resolved, written from the archive alone
report.conflicts        # (doi, field, resolver, archive) for every disagreement
report.archive_only     # DOIs (or titles) that could not be resolved
```

## Keys

The key of an entry is the surname of its first author, without accents, followed by the year: `Chirico2003`, and `Muller2013` for Müller. When two entries share a surname and a year, both get the suffixes `a`, `b`, `c`, ... in the order of their DOI, so the keys do not depend on the order of the points: `Chirico2003a`, `Chirico2003b`. An entry without a year uses the surname alone. Two entries for the ThermoML Archive (`ThermoMLArchive`) and for the standard (`ThermoMLStandard`) are always added, so the data are credited wherever the file goes; pass `include_source = false` to leave them out.

## The cache and the network

The entries delivered by the DOI resolver are kept in the `bibtex` folder of [`database_dir`](@ref), one file per DOI, so each article is requested only once. The requests are made a few at a time.

| Keyword | Default | Effect |
|---|---|---|
| `online` | `true` | `false` uses only the cache and the archive, with no network at all |
| `cache` | `true` | keep and reuse the entries in the data directory |
| `refresh` | `false` | ignore the cache and request every DOI again |
| `include_source` | `true` | add the entries for the ThermoML Archive and the standard |
| `progress` | `true` | print the number of DOIs fetched |

## A table of the articles

A bibliography says which articles were used, not what each one measured. [`reference_summary`](@ref) condenses a selection into a table with **one row per article and property**: an article that measured two properties has two rows.

```julia
articles = reference_summary(v)                      # K and MPa by default
articles = reference_summary(v; temperature_unit = u"°C", pressure_unit = u"kPa")
```

| Column | Content |
|---|---|
| `key`, `doi`, `year`, `month`, `citation` | the article, with the key of the BibTeX export and `Author et al. (year)` |
| `property`, `unit`, `system`, `method`, `phase` | what was measured, in which system and phase, and how |
| `n_points`, `n_uncertainty` | points, and how many of them state an uncertainty |
| `T_min`, `T_max`, `p_min`, `p_max` | ranges of the conditions, in the units you choose |
| `unc_abs`, `unc_rel` | expanded uncertainty at ``k = 2``: absolute, in the unit of the property, and relative in percent |

The summary is a Tables.jl table (`DataFrame(articles)` works) and prints as a table in the REPL.

- **Units.** `temperature_unit` and `pressure_unit` accept any Unitful temperature or pressure unit, including `u"°C"` and `u"bar"`. The database keeps K and kPa; the conversion is applied to the limits of each range only.
- **Uncertainty.** The value of a row is the median over the points that state an uncertainty (`statistic = :median`, the default, which is not thrown off by an outlier or by a property that passes near zero); `statistic = :mean` gives the mean. Points without an uncertainty are not counted in it.
- **Methods.** A method name longer than `method_length` characters (24 by default) is replaced by its initials, `Vibrating tube method` becoming `VTM`; two different names with the same initials are numbered (`VTM`, `VTM2`). The note that explains them is part of the LaTeX and Markdown output.
- **Order.** By year, from the oldest to the newest; within a year, by month when the DOI entry has one, otherwise alphabetically by key.

## LaTeX, Markdown and CSV

```julia
write("water.tex", latex_table(articles))
write("water.md", markdown_table(articles))
write("water.csv", csv_table(articles))
```

[`latex_table`](@ref) writes a `longtable` with `booktabs` rules (load both packages). The first column holds `\cite{key}` with the keys of the BibTeX export, so the table and the `.bib` agree; `reference = :text` writes `Author et al. (year)` instead. The property and the system columns appear only when they vary within the table. Choose the columns, and the number of significant digits, with keywords:

```julia
latex_table(articles; columns = [:reference, :method, :points, :temperature, :pressure, :uncertainty],
            digits = 5, label = "tab:water")
```

[`write_references`](@ref) writes the BibTeX file and the tables in one call, from the same summary, so they cannot disagree:

```julia
write_references("water", v; pressure_unit = u"kPa", statistic = :mean)
# water.bib  water.tex  water.md  water.csv   (choose with formats = (:bib, :tex))
```

!!! note "Credit"
    The metadata come from the DOI resolver and from the ThermoML Archive. Check an entry against the article before relying on a volume, a page number or a journal abbreviation in a publication.
