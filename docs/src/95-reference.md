```@meta
CurrentModule = ThermophysicalDB
```

# [API reference](@id reference)

Everything exported by ThermophysicalDB.jl, grouped by purpose. The functions of the last section are not exported and are subject to change; they are documented for contributors.

## Getting the database

```@docs
ThermophysicalDB
```

```@docs
database
check_update
update_database!
ensure_archive
install_archive!
```

## Where the data are stored

```@docs
database_dir
set_database_dir!
reset_database_dir!
```

## Selecting and extracting points

```@docs
points
mixture
find_compounds
ThermophysicalDB.CompoundMatches
DataView
table
```

## Exporting points

```@docs
export_points
ThermophysicalDB.ExportReport
```

## References of a selection

```@docs
bibtex
write_bibtex
reference_summary
latex_table
markdown_table
csv_table
write_references
ThermophysicalDB.ReferenceSummary
ThermophysicalDB.BibtexReport
```

## Detecting outliers

```@docs
find_outliers
reasons
diagnostics
esd
ThermophysicalDB.esd_critical_values
ThermophysicalDB.OutlierResult
```

## The dataset

```@docs
Dataset
```

## Internals

These docstrings document the implementation. They are not part of the public interface and may change in any release.

```@autodocs
Modules = [ThermophysicalDB]
Public = false
Filter = x -> x !== ThermophysicalDB.Dataset
```
