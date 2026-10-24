```@meta
CurrentModule = ThermophysicalDB
```

# [Data model](@id data_model)

You can use the package without ever looking at the internal layout. This page explains it because it determines what is fast, why selections cost almost nothing, and how other databases can be added later without changing the way you query.

## Relational tables, stored as columns

A [`Dataset`](@ref) is a small relational database held entirely in memory. Instead of one object per experimental point (millions of tiny objects), each table is a *struct of arrays*: one plain, contiguous vector per field. Relations between tables are `Int32` row numbers.

```@raw html
<div style="margin: 18px 0">
<svg viewBox="0 0 800 470" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Relational layout of the dataset" style="width:100%;max-width:800px;font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif">
<defs>
<marker id="arr-00e5ff" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#00e5ff"/></marker>
<marker id="arr-39ff88" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#39ff88"/></marker>
<marker id="arr-9b5cff" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#9b5cff"/></marker>
<marker id="arr-ff8a00" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#ff8a00"/></marker>
<marker id="arr-ff2bd6" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#ff2bd6"/></marker>
<marker id="arr-ffe600" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#ffe600"/></marker>
</defs>
<rect x="20" y="20" width="210" height="118" rx="14" fill="#00e5ff" fill-opacity="0.13" stroke="#00e5ff" stroke-width="2"/>
<rect x="20" y="20" width="210" height="34" rx="14" fill="#00e5ff" fill-opacity="0.9"/>
<rect x="20" y="40" width="210" height="14" fill="#00e5ff" fill-opacity="0.9"/>
<text x="125.0" y="43" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">references</text>
<text x="34" y="76" font-size="13.5" fill="currentColor">doi, title, journal, year</text>
<text x="34" y="95" font-size="13.5" fill="currentColor">authors, volume, pages</text>
<text x="34" y="114" font-size="13.5" fill="currentColor">source  → pool</text>
<rect x="20" y="222" width="210" height="118" rx="14" fill="#39ff88" fill-opacity="0.13" stroke="#39ff88" stroke-width="2"/>
<rect x="20" y="222" width="210" height="34" rx="14" fill="#39ff88" fill-opacity="0.9"/>
<rect x="20" y="242" width="210" height="14" fill="#39ff88" fill-opacity="0.9"/>
<text x="125.0" y="245" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">compounds</text>
<text x="34" y="278" font-size="13.5" fill="currentColor">inchikey (identity), inchi</text>
<text x="34" y="297" font-size="13.5" fill="currentColor">formula</text>
<text x="34" y="316" font-size="13.5" fill="currentColor">names</text>
<rect x="285" y="100" width="230" height="140" rx="14" fill="#9b5cff" fill-opacity="0.13" stroke="#9b5cff" stroke-width="2"/>
<rect x="285" y="100" width="230" height="34" rx="14" fill="#9b5cff" fill-opacity="0.9"/>
<rect x="285" y="120" width="230" height="14" fill="#9b5cff" fill-opacity="0.9"/>
<text x="400.0" y="123" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">experiments</text>
<text x="299" y="156" font-size="13.5" fill="currentColor">reference  → references</text>
<text x="299" y="175" font-size="13.5" fill="currentColor">components[1..3] → compounds</text>
<text x="299" y="194" font-size="13.5" fill="currentColor">kinds[1..3] (composition)</text>
<text x="299" y="213" font-size="13.5" fill="currentColor">ncomp, number</text>
<rect x="570" y="20" width="210" height="98" rx="14" fill="#ff8a00" fill-opacity="0.13" stroke="#ff8a00" stroke-width="2"/>
<rect x="570" y="20" width="210" height="34" rx="14" fill="#ff8a00" fill-opacity="0.9"/>
<rect x="570" y="40" width="210" height="14" fill="#ff8a00" fill-opacity="0.9"/>
<text x="675.0" y="43" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">properties</text>
<text x="584" y="76" font-size="13.5" fill="currentColor">label, unit</text>
<text x="584" y="95" font-size="13.5" fill="currentColor">group  → pool</text>
<text x="584" y="114" font-size="13.5" fill="currentColor">one row per (label, unit)</text>
<rect x="570" y="168" width="210" height="170" rx="14" fill="#ff2bd6" fill-opacity="0.13" stroke="#ff2bd6" stroke-width="2"/>
<rect x="570" y="168" width="210" height="34" rx="14" fill="#ff2bd6" fill-opacity="0.9"/>
<rect x="570" y="188" width="210" height="14" fill="#ff2bd6" fill-opacity="0.9"/>
<text x="675.0" y="191" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">measurements</text>
<text x="584" y="224" font-size="13.5" fill="currentColor">experiment, property</text>
<text x="584" y="243" font-size="13.5" fill="currentColor">value, unc, unc_k, unc_level</text>
<text x="584" y="262" font-size="13.5" fill="currentColor">temperature, pressure</text>
<text x="584" y="281" font-size="13.5" fill="currentColor">composition[1..3]</text>
<text x="584" y="300" font-size="13.5" fill="currentColor">method, phase  → pool</text>
<rect x="300" y="300" width="200" height="80" rx="14" fill="#ffe600" fill-opacity="0.13" stroke="#ffe600" stroke-width="2"/>
<rect x="300" y="300" width="200" height="34" rx="14" fill="#ffe600" fill-opacity="0.9"/>
<rect x="300" y="320" width="200" height="14" fill="#ffe600" fill-opacity="0.9"/>
<text x="400.0" y="323" text-anchor="middle" font-size="16" font-weight="700" fill="#06070d">extras</text>
<text x="314" y="356" font-size="13.5" fill="currentColor">scope, row, key</text>
<text x="314" y="375" font-size="13.5" fill="currentColor">number or text</text>
<line x1="285" y1="140" x2="232" y2="90" stroke="#00e5ff" stroke-width="2.4" marker-end="url(#arr-00e5ff)"/>
<text x="250" y="104" text-anchor="middle" font-size="12.5" font-style="italic" fill="currentColor" fill-opacity="0.8">reference</text>
<line x1="285" y1="205" x2="232" y2="262" stroke="#39ff88" stroke-width="2.4" marker-end="url(#arr-39ff88)"/>
<text x="248" y="248" text-anchor="middle" font-size="12.5" font-style="italic" fill="currentColor" fill-opacity="0.8">components</text>
<line x1="570" y1="230" x2="517" y2="200" stroke="#9b5cff" stroke-width="2.4" marker-end="url(#arr-9b5cff)"/>
<text x="538" y="198" text-anchor="middle" font-size="12.5" font-style="italic" fill="currentColor" fill-opacity="0.8">experiment</text>
<line x1="675" y1="168" x2="675" y2="120" stroke="#ff8a00" stroke-width="2.4" marker-end="url(#arr-ff8a00)"/>
<text x="715" y="146" text-anchor="middle" font-size="12.5" font-style="italic" fill="currentColor" fill-opacity="0.8">property</text>
<line x1="400" y1="340" x2="400" y2="242" stroke="#ffe600" stroke-width="2.4" marker-end="url(#arr-ffe600)"/>
<text x="412" y="285" font-size="12.5" font-style="italic" fill="currentColor" fill-opacity="0.8">any row of any table</text>
<rect x="20" y="404" width="760" height="48" rx="12" fill="#8b93a1" fill-opacity="0.14" stroke="#8b93a1" stroke-width="1.5" stroke-dasharray="6 5"/>
<text x="400" y="424" text-anchor="middle" font-size="14" font-weight="700" fill="currentColor">string pools</text>
<text x="400" y="443" text-anchor="middle" font-size="13" fill="currentColor" fill-opacity="0.85">sources · groups · methods · phases · composition kinds · extra keys · extra texts</text>
</svg>
</div>
```

| Table | One row per | Notes |
| :-- | :-- | :-- |
| [`ReferenceTable`](@ref) | publication | deduplicated by DOI; records which database it came from |
| [`CompoundTable`](@ref) | distinct chemical species | identity is the standard InChIKey, or the lower-cased first name when there is none |
| [`PropertyTable`](@ref) | distinct (label, unit) pair | `("Mass density", "kg/m3")` |
| [`ExperimentTable`](@ref) | studied system in a publication | a reference plus up to three compounds, and how the amount of each is expressed |
| [`MeasurementTable`](@ref) | measured value | the "long" format: one row per property value, with its conditions and uncertainty |
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
