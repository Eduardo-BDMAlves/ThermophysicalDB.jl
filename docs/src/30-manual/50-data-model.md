```@meta
CurrentModule = ThermophysicalDB
```

# [Data model](@id data_model)

You can use the package without ever looking at the internal layout. This page explains it because it determines what is fast, why selections cost almost nothing, and how other databases can be added later without changing the way you query.

## Relational tables, stored as columns

A [`Dataset`](@ref) is a small relational database held entirely in memory. Instead of one object per experimental point (millions of tiny objects), each table is a *struct of arrays*: one plain, contiguous vector per field. Relations between tables are `Int32` row numbers.

Three diagrams follow, each isolating one idea. They are drawn from the type definitions of the package, so the columns and their relations are those of the code. Every table has an implicit primary key (**PK**): the position of the row, an `Int32` where `0` means "absent". A foreign key (**FK**) is such a position in another table, and **UQ** marks the column that identifies a row by its content, which is how rows are deduplicated.

### From a value to its publication

A measurement knows its experiment, and an experiment knows its reference. Following the two arrows from any value gives the article it came from, with its DOI, authors and year. The `source` column of a reference names the database it was read from.

```@example datamodel
Main.SchemaDiagrams.provenance() # hide
```

### What a value refers to

A measurement points to a property, a pair of a label and a unit such as `("Mass density", "kg/m3")`. An experiment points to up to three compounds, one per component of the system, and says how the amount of each is expressed (`kinds`).

```@example datamodel
Main.SchemaDiagrams.meaning() # hide
```

### From an experiment to the purity of its samples

An experiment records, for each of its components, the sample that was measured. The sample table holds what the article says about it: where it came from (`origin`), its final and initial purity with the basis on which it is stated (`purity_kind`), the water content, the methods used to analyse and to purify it, and `purity_basis`, which classifies the final purity as stated by the supplier, measured, or estimated by the compiler of the data. The same information step by step, with the significant digits and the free-text descriptions, is in the purity step table. A component whose sample the article does not describe points to `0`, like any other absent value, and its purity is `NaN`. The ThermoML archive has no field for the name of the supplier: `supplier` is empty for its samples, and "Commercial source" in `origin` is what it says.

```@example datamodel
Main.SchemaDiagrams.purity() # hide
```

### How the columns are held

Each table is a *struct of arrays*, one contiguous vector per column, so a scan over one field reads memory in order. Repeated strings (database names, groups, methods, phases, composition kinds, the keys and texts of extra fields, and the origins, statuses, suppliers, analysis methods, purification methods, purposes and uncertainty methods of the samples and experiments, and the free-text methods) are interned in fifteen string pools; a column that refers to a pool holds the `Int32` position of the string, and comparing two strings is comparing two integers. The extra table is the one exception to the rule that a foreign key has a single target: its `row` refers to a row of the table named by `scope`.

```@example datamodel
Main.SchemaDiagrams.storage() # hide
```

| Table | One row per | Notes |
| :-- | :-- | :-- |
| [`ReferenceTable`](@ref) | publication | deduplicated by DOI; records which database it came from |
| [`CompoundTable`](@ref) | distinct chemical species | identity is the standard InChIKey, or the lower-cased first name when there is none |
| [`SampleTable`](@ref) | sample described in a publication | origin, final and initial purity, water, methods and a summary of how the purity is known |
| [`PurityStepTable`](@ref) | purification step of a sample | every purity and impurity the article states, with its digits and the free-text methods |
| [`PropertyTable`](@ref) | distinct (label, unit) pair | `("Mass density", "kg/m3")` |
| [`ExperimentTable`](@ref) | studied system in a publication | a reference plus up to three compounds, their samples, the purpose of the experiment, and how the amount of each component is expressed |
| [`MeasurementTable`](@ref) | measured value | the "long" format: one row per property value, with its conditions, uncertainty, and significant digits |
| [`ExtraTable`](@ref) | extra field | sparse key–value store for anything without a core column |

Repeated strings (database names, methods, phases, composition kinds) are *interned* in string pools and referred to by number, which keeps memory small and makes comparisons integer comparisons.

## Why long format

A mixture can have up to three components and any number of properties. In the long format, every measured value is one row that knows its experiment, its property, its conditions and its uncertainty. A system with three properties measured at the same state simply has three rows. This avoids a sparse wide table with a column per property, and it makes "all points of property X for compound Y" a single scan over two index columns.

## What a selection costs

[`points`](@ref) first resolves your text (compound names, property labels, DOIs) to *small masks* over the compound, property and reference tables, which have thousands of rows rather than millions. It then scans the measurements once, testing integers and floats against those masks and the temperature and pressure limits. The result is a vector of row numbers, the [`DataView`](@ref). Because it is only an index, refining it scans only the survivors.

## One schema for many databases

The core columns are the ThermoML model: conditions, uncertainty and the identity of the system. Whatever another database can express in those terms is converted into them, so all sources look the same to your queries and share compounds and properties. What does not fit goes into the [`ExtraTable`](@ref) as free key–value fields attached to a reference, compound, experiment or measurement, without changing the core. Every reference records its `source`, so the origin of any point is always known, and `points(...; source = "thermoml")` restricts a query to one database.

## Persistence

The cache is a flat dump of these arrays (see [Downloads, updates and cache](@ref updates)). Loading it rebuilds only the small lookup dictionaries; the large columns are read as they were written, which is why a later session is much faster than parsing the archive again. A schema version is stored with it, and an older cache is rebuilt automatically.
