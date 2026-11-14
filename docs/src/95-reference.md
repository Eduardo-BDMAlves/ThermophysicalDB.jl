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
sample_table
purity_step_table
condition_table
```

## Composition scales

```@docs
convert_composition
COMPOSITION_SCALES
CompositionConversion
```

## Several databases

```@docs
Database
Member
members
add_member!
remove_member!
member_dataset
DatabaseView
parts
add_database!
add_reference!
add_experiment!
add_measurement!
add_reference_data!
export_template
import_template
add_template_experiments!
TemplateData
TemplateExperiment
save_database
created_at
modified_at
set_priority!
databases_dir
resolve_compound
ReferenceRef
ExperimentRef
duplicates
conflicts
DuplicateRules
DuplicateReport
ThermophysicalDB.Registry
ThermophysicalDB.Catalog
ThermophysicalDB.loaded_tables
ThermophysicalDB.LAZY_FIELDS
```

## Compounds and their identifiers

```@docs
compound_database
lookup_compounds
compound_record
molar_mass
link_compounds
LinkedDatabase
forget_choices!
register_compound!
save_compounds
fetch_pubchem!
prefetch_compounds!
pubchem_rate!
ThermophysicalDB.PubChemError
ThermophysicalDB.CompoundRecords
ThermophysicalDB.CompoundLinks
CompoundDB
```

## Uncertainty terms of your data

```@docs
set_uncertainty!
UncertaintyTerm
uncertainty_table
expanded_uncertainty
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
Filter = x -> !any(y -> x === y, (ThermophysicalDB.Dataset, ThermophysicalDB.TemplateData, ThermophysicalDB.TemplateExperiment, ThermophysicalDB.CompoundMatches, ThermophysicalDB.CompoundLinks, ThermophysicalDB.CompoundRecords, ThermophysicalDB.PubChemError, ThermophysicalDB.ExportReport, ThermophysicalDB.ReferenceSummary, ThermophysicalDB.BibtexReport, ThermophysicalDB.OutlierResult, ThermophysicalDB.Registry, ThermophysicalDB.Catalog, ThermophysicalDB.loaded_tables, ThermophysicalDB.LAZY_FIELDS))
```
