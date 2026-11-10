```@meta
CurrentModule = ThermophysicalDB
```

# [Adding your own data](@id tutorial_own_data)

The NIST archive is read-only: you never change it. Points from an article that is not in it, and the points you measured yourself, go into **databases of your own**, which are searched together with the archive as if they were one (see [Several databases that look like one](@ref updates)). This tutorial adds two hypothetical sets of data, in two ways:

1. **Programmatically**, building the data step by step with the objects of the package: a [`ReferenceRef`](@ref) (the article or the notebook), an [`ExperimentRef`](@ref) (one system measured) and the points.
2. **With a spreadsheet**: the package writes an Excel template, you fill it in and the package reads it back. Two filled examples are ready to download: [`example-literature.xlsx`](../assets/example-literature.xlsx) and [`example-own-measurements.xlsx`](../assets/example-own-measurements.xlsx).

```@setup own
Main.DocsSetup.activate!()
```

## Two kinds of database

A database of your own has a *kind* that says what it holds:

| Kind | For | Priority when the same point is in two databases |
| :-- | :-- | :-- |
| `:literature` | points taken from published work that the archive lacks | lower |
| `:user` (default) | your own measurements | higher |

The kind is not decoration: it travels with every point, so later you can ask for the literature only, or for your own bench against everything else.

```@example own
using ThermophysicalDB

# `database()` returns one object that every page of a session shares, so this tutorial works on a
# private database that holds the same archive and nothing else: the databases it adds stay here.
archive = first(m for m in members(database()) if m.kind === :thermoml)
db = ThermophysicalDB.Database([archive])
root = mktempdir()   # the databases of this tutorial live in a temporary folder

add_database!(db, "papers"; kind = :literature, dir = root)
add_database!(db, "my_lab"; dir = root)   # kind = :user is the default
members(db)
```

## A point from the literature, step by step

Take a hypothetical article that measured the **volumetric heat capacity at constant pressure**, ``c_p^V = \rho\, c_p`` in J K⁻¹ cm⁻³, of ethanol + water mixtures at 101.325 kPa. It is the heat that one cubic centimetre of the liquid absorbs per kelvin, and it is what a calorimeter that fills a cell of fixed volume (such as a micro DSC) measures directly: the cell holds a volume, not a mass, so the quantity is ``C_p / V`` and no density is needed. To get the specific heat capacity ``c_p`` (J K⁻¹ kg⁻¹) you divide by the density of the same sample at the same ``T`` and ``P``, which is why the two properties are different entries in ThermoML. The composition is a **mass fraction**, ``w_i = m_i / m_{\text{total}}``: it is what you get by weighing the components, and it does not depend on temperature.

All the numbers of this tutorial are invented to show the mechanics: they come from no article and no laboratory.

### 1. The reference

The reference is the work the points come from. [`add_reference!`](@ref) returns a [`ReferenceRef`](@ref), a small handle that the next step needs:

```@example own
ref = add_reference!(
    db;
    database = "papers",
    doi = "10.5555/example.2026.001",
    title = "Volumetric heat capacity of ethanol + water mixtures (hypothetical example)",
    journal = "Journal of Hypothetical Data",
    year = 2026,
    volume = "12",
    pages = "100-108",
    authors = ["Silva, A.", "Souza, B."],
)
```

### 2. The experiment

An experiment is one *system*: a list of components and the scale in which their amounts are given. Components are recognised by name, CAS number or InChIKey, through the compound database of the package, so that `"water"` here is the same compound as `"water"` in the archive and the two sets of points meet in one search:

```@example own
experiment = add_experiment!(
    ref;
    components = ["water", "ethanol"],
    composition_scale = :mass_fraction,
    purpose = "Heat capacity of ethanol + water",
)
```

`composition` lists one amount for each component, in the order of `components`, and `NaN` for the ones you do not give. Here the article gives the mass fraction of ethanol, the *second* component, and the first follows from ``w_1 = 1 - w_2``; so the entry for water is `NaN`. In general a system of ``N`` components has ``N - 1`` free amounts.

### 3. The points

[`add_measurement!`](@ref) adds one point. Temperature and pressure may be text with a unit or plain numbers (K and kPa). Every uncertainty states its **coverage factor** ``k``, which says how it was obtained: a standard uncertainty is ``k = 1`` (about 68 % of the values for a normal distribution) and ``k = 2`` gives about 95 %. Without it, two sources that both say "1 %" cannot be compared.

The article also states the uncertainty of the *conditions*, which matters because the heat capacity depends on them: ``u(T)``, ``u(P)`` and ``u(w)`` go in `unc_temperature`, `unc_pressure` and `unc_composition`. A plain number is a standard uncertainty; [`UncertaintyTerm`](@ref) states the coverage, and a text such as `"0.02 degC"` is a difference. Here all are expanded uncertainties with ``k = 2``:

```@example own
for (w, temperature, c) in (
    (0.2, "15 degC", 3.99),
    (0.2, "25 degC", 4.02),
    (0.4, "15 degC", 3.58),
    (0.4, "25 degC", 3.62),
)
    add_measurement!(
        experiment;
        property = "Heat capacity at constant pressure per volume",
        unit = "J/K/cm3",
        value = c,
        unc = 0.015 * c,                                        # 1.5 % of the value
        unc_k = 2,
        temperature,
        pressure = "101.325 kPa",
        composition = [NaN, w],
        unc_temperature = UncertaintyTerm("0.02 degC"; k = 2),
        unc_pressure = UncertaintyTerm(0.5; k = 2),             # kPa
        unc_composition = [NaN, UncertaintyTerm(0.0005; k = 2)],
        phase = "Liquid",
        method = "Differential scanning calorimetry",
    )
end
```

The unit is converted once, when the point is added: the database keeps the property in J K⁻¹ m⁻³ (the unit of ThermoML), so 3.99 J K⁻¹ cm⁻³ is stored as 3.99 × 10⁶ J K⁻¹ m⁻³. The points are already in the joined view, with the name of the database as a column:

```@example own
literature = points(db; source = "papers")
table(literature)
```

`source` is the name of the database that holds the reference. If you also give a `component` (or a property or limits) that the database does not have, the answer is that the source exists but nothing in it matches, not that the source is unknown.

The uncertainties of the conditions are in the uncertainty table, one row per term, with the coverage and how each was obtained (given, or derived: the combined standard uncertainty is ``u = U/k``):

```@example own
uncertainty_table(only(parts(literature)))
```

### The same, in one call

When you have the whole article at hand, [`add_reference_data!`](@ref) takes it in one piece. Everything is checked *before* anything is added, so a mistake in the fifth experiment leaves the database as it was, and `dry_run = true` does only the check:

```julia
add_reference_data!(
    db;
    database = "papers",
    reference = (doi = "10.5555/example.2026.002", authors = ["Lima, C."], year = 2026),
    experiments = [
        (
            components = ["water", "ethanol"],
            composition_scale = :mass_fraction,
            property = "Heat capacity at constant pressure per volume", unit = "J/K/cm3",
            temperature = [288.15, 298.15], pressure = 101.325,
            x2 = [0.3, 0.3], value = [3.78, 3.81],
            unc_temperature = 0.01, unc_x2 = "0.1 %",
        ),
    ],
)
```

A column is a vector with one entry per point or a single value repeated; the first form above is the same thing written point by point.

### A percentage of a temperature

An uncertainty can be written as a percentage of the value, `"0.01 %"`. For a temperature that needs a rule, because the zero of °C and °F is not the absolute zero: 1 % of 25 °C is 0.25 K, but 1 % of 298.15 K is 2.98 K. The package always takes the percentage of the temperature in the **absolute** scale (K, or °R for °F, which is the same fraction), whatever unit you wrote the temperature in:

```@example own
e = add_experiment!(ref; components = ["ethanol"])
add_measurement!(e; property = "Heat capacity at constant pressure per volume", unit = "J/K/cm3",
                 value = 1.92, temperature = "25 degC", unc_temperature = "0.01 %")
pure = only(parts(points(db; source = "papers", component = "ethanol", exact = true)))
uncertainty_table(pure)
```

That is 0.01 % of 298.15 K, 0.0298 K, and not 0.01 % of 25 K. An absolute uncertainty with a unit is a difference instead, so `"0.05 degC"` is 0.05 K and `"0.09 degF"` is 0.05 K. The rule is part of the uncertainty documentation: [A percentage of a temperature is taken of the absolute scale](@ref).

## Your own measurements

Your bench data go the same way, into the `my_lab` database. The difference is in what you know about them: you know how the sample was made and what the instrument can do, so you can state the uncertainty yourself. The volumetric heat capacity of ethanol at three temperatures, with an expanded relative uncertainty of 1 % (``k = 2``) and the uncertainty of the thermometer:

```@example own
notebook = add_reference!(
    db;
    database = "my_lab",
    title = "Laboratory measurements of ethanol (example)",
    year = 2026,
    authors = ["Alves, E."],
)

ethanol = add_experiment!(notebook; components = ["ethanol"])

for (T, c) in ((303.15, 1.95), (313.15, 1.97), (323.15, 1.99))
    add_measurement!(
        ethanol;
        property = "Heat capacity at constant pressure per volume",
        unit = "J/K/cm3",
        value = c,
        temperature = T,
        pressure = 101.325,
        unc = "1 %",                                  # of the value, in the unit of the value
        unc_k = 2,
        unc_temperature = UncertaintyTerm(0.05; k = 2),   # K
        method = "Micro DSC",
    )
end

table(points(db; source = "my_lab"))
```

The values are hypothetical. The heat capacity of a liquid grows slowly with temperature, because more modes of motion (rotations and internal vibrations of the molecules) become available to store the energy that is added; so the three numbers going up is a quick sanity check on what you typed, and a decrease would deserve a second look.

### Saving

Everything so far is in memory. [`save_database`](@ref) writes a database of your own to its folder, and it is read again, with no download, the next time you call [`database`](@ref) with the same folders:

```@example own
save_database(db, "my_lab")
```

## With a spreadsheet

Typing points one by one is fine for ten points and tedious for ten thousand. The same two steps, with an Excel file instead of code, come with the extension that loads when you load `XLSX`:

```@example own
using XLSX   # loading it activates the spreadsheet functions

template = joinpath(root, "template.xlsx")
export_template(db, template; experiments = 2)
isfile(template)
```

The file has these sheets:

| Sheet | What you fill in |
| :-- | :-- |
| `Guide` | nothing: it explains the colours and lists your databases and the properties you can use |
| `Reference` | the target database, its kind (Literature or User), the DOI, the authors, the title and the compounds |
| `EXP-1`, `EXP-2`... | one experiment each: name, property, phase, method, components, composition scale, and below it the **units** and the **uncertainty type** (absolute or relative in %) of each column |
| `PTS-1`, `PTS-2`... | the points of the experiment: the amounts, `T`, `P`, the value and the uncertainty of each (`u(x)`, `u(T)`, `u(P)`, `u(value)`), one point per row (up to 200). Under each header, `u given as` chooses *absolute* or *relative (%)* and `k` is the coverage factor of that column |

Only the input cells (the colours are explained in the `Guide`) are for you; the rest is protected. Property, method, phase, sample source, supplier, purity analysis, purification, units and scale are menus: the values that your databases already use come first (most used first), followed by generic choices, so a new point most likely joins what is already there. Method and supplier also accept your own text. Open `template.xlsx`, fill it in and save, or start from one of the examples:

- [`example-literature.xlsx`](../assets/example-literature.xlsx): the hypothetical article above plus a pure-water experiment (nine points), target `literature`, temperatures in K with `u(T)`, `u(P)` and `u(w)` as expanded uncertainties (``k = 2``).
- [`example-own-measurements.xlsx`](../assets/example-own-measurements.xlsx): the volumetric heat capacity of ethanol and of water (a check of the instrument), temperatures in °C (six points), target `my_lab`. The ethanol sheet gives `u(T)` in °C, which is a difference; the water sheet gives `u(T)` and `u(P)` as relative (`%`), which the package takes of the value in K and kPa.

### Check before importing

[`import_template`](@ref) with `only_check = true` reads the file and reports every problem, with the cell it is in, **without adding anything**, not even the database named in the file. A file with a wrong date, an unknown unit and a missing component gives all three at once, not one per attempt. The report also says whether the data could be written as a valid ThermoML file and, when they cannot, which criteria fail (the criteria are in the tables at the end of this page):

```@example own
example = pkgdir(ThermophysicalDB, "docs", "src", "assets", "example-literature.xlsx")

report = import_template(db, example; only_check = true)
(
    ok = report.ok,
    imported = report.imported,
    points = report.points,
    problems = report.problems,
    thermoml_compatible = report.thermoml_compatible,
    thermoml_failures = report.thermoml_failures,
)
```

`ok = true` means that the file can be imported, not that it was: `imported` is `false` here, and `points(db; source = "literature")` would still say that no such database exists.

### Import

When the report is clean, the same call without `only_check` adds the points, and its result has the same `thermoml_compatible` and `thermoml_failures`, with `imported = true`. The database comes from the sheet `Reference` (it is created if it does not exist yet), and the second file goes into a different one, so a single call can also take several files:

```@example own
result = import_template(db, example; warn_duplicates = false)
result.points
```

```@example own
own = pkgdir(ThermophysicalDB, "docs", "src", "assets", "example-own-measurements.xlsx")
import_template(db, own; warn_duplicates = false).points
```

```@example own
points(db; source = "my_lab")
```

### Repeated points

The example file describes the very article that was typed in by hand at the start, so those points are now in two databases, `papers` and `literature`. Nothing is removed or changed when this happens: [`duplicates`](@ref) lists the pairs, [`conflicts`](@ref) those that disagree beyond their uncertainties, and a selection keeps one copy of each by default (`duplicate = true` shows them all). Importing the same file again does the same: the points enter the database, and the later copy is left out of the selections.

```@example own
duplicates(db)
```

A few things the template accepts and checks:

- the composition scales *Mole fraction*, *Mass fraction*, *Molality* and *Amount concentration*, and the unit chosen for the amounts must belong to the scale (mol/kg for a molality, not mol/L);
- a **relative** uncertainty (%) is turned into an absolute one with the value of each point, and the coverage factor goes with it; for `u(T)` the percentage is taken of the temperature in K (also when the column is in °C or °F), see [A percentage of a temperature is taken of the absolute scale](@ref);
- an **absolute** `u(T)` or `u(P)` is a difference in the unit of its column (0.05 degC is 0.05 K), and an absolute `u(x)` is in the unit of the amounts;
- several files of the same work (the same DOI, or the same first author and year) are joined into one reference: the compounds are matched by name and the experiments are put one after the other.

!!! warning "Not stored yet"
    The note column, the sample data of the `Reference` sheet (purity, supplier...) and the "where in the article" fields are read but **not stored yet**. The import says so with a warning and in `result.ignored`; nothing is lost silently.

## What a reference needs

There are two levels, and they are different questions. The first is what the **package** needs to store a reference: when something here is missing the import refuses and lists the cell, and nothing is added. The second is what **ThermoML** needs to write the same data as a valid ThermoML file: the package stores the data anyway, and the report lists what fails in `thermoml_failures`, so you can fix it now or later. Both apply to the spreadsheet and to the functions (`add_reference!`, `add_experiment!`, `add_measurement!`, `add_reference_data!`).

### Required to add a reference to a database

| Item | Where in the sheet | Rule |
| :-- | :-- | :-- |
| Database | `Reference!C5` (or `database = ...`) | A name that starts with a letter or a digit and has letters, digits, `_`, `.`, `-` or a space; it is created if it does not exist; `thermoml` is the archive's. |
| Kind of data | `Reference!C6` | `Literature` or `User`; it must be the kind of a database that already exists. |
| Identification of the work | `Reference!C9:C12` | The DOI, or the authors, or the title (at least one). |
| Year | `Reference!C14` | Required when there is no DOI; a whole number between 1500 and 2200. |
| Experiments | `EXP-n`, `PTS-n` | At least one experiment with at least one point; each has a name (`EXP-n!C5`) and the property (`C6`). |
| Components | `EXP-n!C12:E12` | From 1 to 3, filled from the first cell on, each one listed in the compounds of the `Reference` sheet (once) and identified by InChIKey, CAS number or exact name in the compound database. |
| Composition scale | `EXP-n!C15` | Needed for a mixture: mole fraction, mass fraction, molality or amount concentration; the unit of the amounts has to belong to the scale (mol/kg for a molality, not mol/L). |
| Value of each point | `PTS-n`, `value` | A finite number, in the unit of its column; a relative uncertainty needs it as a number. |
| Temperature and pressure | `PTS-n`, `T`, `P` | Optional; if given, ``T > 0`` K and an absolute ``P \ge 0`` (a gauge pressure is refused). |
| Uncertainties | `PTS-n`, `u(...)` | Optional; if given, a number that is not negative, with its `k` (row 7) as a number greater than zero. |

### Required by ThermoML (reported in `thermoml_failures`)

| Criterion | Rule | Why |
| :-- | :-- | :-- |
| Citation | The DOI, or the authors, the title and the year | The ThermoML citation has to identify the work; the file of an article is named by its DOI. |
| Property | A name in the ThermoML list (as the archive writes it; the sheet `Properties` shows them) | The schema accepts only the names of its list, each with its unit; the package converts the unit. |
| Phase | One of the ThermoML phases (`Liquid`, `Gas`, `Crystal`, `Glass`, `Solution`, `Ideal gas`...) or empty | The schema enumerates the phases. |
| Composition of a mixture | In every point, the ``N - 1`` amounts of a system of ``N`` components | Without the composition the state of the mixture is not defined. |
| Coverage of an uncertainty | A coverage factor ``k`` or a level of confidence with every uncertainty of the value | An expanded uncertainty is meaningless without how it was expanded. |

The package derives the rest when it writes the file, so you do not have to give it: the number of significant digits of every value (counted from the number as written), the free text `method not stated` when the method is empty, the compound numbers of the file, and the units of the schema.
