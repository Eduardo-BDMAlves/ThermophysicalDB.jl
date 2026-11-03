```@meta
CurrentModule = ThermophysicalDB
```

# [Compounds and their identifiers](@id compounds)

The ThermoML Archive names its compounds as each article did, and a few of them have no InChIKey at all. The compound database is a second, separate table that knows every way of naming a compound: all its names, its CAS number, its PubChem CID, its formula, its molar mass, its SMILES, its InChI and its InChIKey. It lets you find a compound from any of them, links the compounds of the archive to it, and is the place to complete what an article left out.

Nothing here changes the ThermoML data. The archive stays exactly as NIST publishes it, and when the two disagree both are shown and you choose.

## Two databases

The package keeps two databases, side by side and never mixed:

| Database | What it holds | Where it comes from | Can you change it? |
| :-- | :-- | :-- | :-- |
| the **thermophysical database** (`database()`) | the experimental points: properties, conditions, uncertainties, samples, references | the ThermoML Archive of NIST/TRC | no, it is the reference; you only add your own points as another source |
| the **compound database** (`compound_database()`) | the nomenclature and the base properties of the compounds: every name, CAS number, PubChem CID, formula, molar mass, SMILES, InChI and InChIKey | lists derived from PubChem, fixed at one commit | the lists are never touched; the compounds you add or complete with [`register_compound!`](@ref) go to a separate file of your own (`custom.jld2`) and are loaded together with the lists, as one database |

What you add is kept apart on your computer and never written into the lists or into the archive: `register_compound!` changes the database in the session, and [`save_compounds`](@ref) writes only the compounds you added or changed to `custom.jld2`. Every call of `compound_database()` reads the lists and then lays that file over them, so the variable you work with is a single database. [`link_compounds`](@ref) joins the two in a [`LinkedDatabase`](@ref). The join only records which compound of the compound database describes each compound of the archive; it never renames, merges or corrects anything in the archive. Where the two disagree you see both and you choose.

## Getting it

```julia
cdb = compound_database()
```

The first call downloads six lists of identifiers (about 47 MB) from a fixed commit of the [chemicals](https://github.com/CalebBell/chemicals) repository, checks each file against its SHA-256 digest, parses them and saves a binary cache (about 52 MB). Later calls read the cache and never use the network. The lists hold about 76 000 compounds: the largest part comes from PubChem, according to the authors of the repository, and the others add salts and hydrates, the ions of brines (`Na+`, `Cl-`, `Ca+2`) and compounds that the PubChem list lacks (`cesium formate`). See the [notices](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/NOTICE.md) for the origin and the terms.

The files live in `compounds/` inside the [data directory](@ref updates):

| File | Content |
| :-- | :-- |
| `seed/*.tsv` | the downloaded lists, verified against their digests |
| `seed.jld2`, `seed.toml` | the parsed lists, and a description written last (the commit and the digests they were built from) |
| `custom.jld2` | the compounds that you added or changed |

If the download fails, the error says where to get the files in a browser; copy them with the same names into `compounds/seed/` and call `compound_database()` again. Files with the right digest are used as they are. The commit is fixed, so everybody who installs the same version of the package gets the same lists. `rebuild = true` ignores the cache and parses the lists again.

## Looking a compound up

[`lookup_compounds`](@ref) takes a name or any identifier:

```julia
lookup_compounds(cdb, "7732-18-5")              # CAS number
lookup_compounds(cdb, "XLYOFNOQVPJJNP-UHFFFAOYSA-N")  # InChIKey (case does not matter)
lookup_compounds(cdb, "962")                    # PubChem CID
lookup_compounds(cdb, "InChI=1S/H2O/h1H2")      # InChI
lookup_compounds(cdb, "cesium formate")         # a name, any spelling
lookup_compounds(cdb, "H2O")                    # a formula, as the lists write it
lookup_compounds(cdb, "CO"; by = :smiles)       # a SMILES must be declared
```

With the default `by = :auto` the kind is recognised from how the text is written: an InChIKey, a CAS number, a text that starts with `InChI=` or `SMILES=`. Anything else is tried as a name, then as a CID (only digits), then as a formula. A SMILES cannot be told from a name by looking at it (`"CO"` is carbon monoxide as a formula and methanol as a SMILES), so it needs `by = :smiles` or the prefix `SMILES=`. The `match` column of the result says which kind matched.

Names follow the rules of [`find_compounds`](@ref): case, accents, hyphens and spaces are ignored, `"n-hexane"` also finds `"hexane"` and the usual alternative spellings are understood. When a name finds nothing, close names are listed (`:contains`, `:similar`); an identifier that finds nothing returns nothing, never a guess.

SMILES and formulas are compared **as written**. A valid SMILES written in another way than the lists use it, or a formula with the elements in another order, does not match; no structure is parsed. [`compound_record`](@ref) returns everything known about one compound, including all its names.

The first search by name in a session builds an index of the names (about three seconds and 250 MB of memory for the whole database, measured on the 2026 lists); the searches by identifier and the later ones are instant.

## Linking it to the archive

[`link_compounds`](@ref) matches every compound of the archive with the database:

```julia
db = database()
linked = link_compounds(db, cdb)
linked.links          # the table of links
```

The InChIKey is tried first, then the InChI, then the names. `linked.links` has one row for each pair (compound of the archive, compound of the database that may describe it), and says how reliable the pair is:

| Column | Meaning |
| :-- | :-- |
| `via` | `:inchikey` or `:inchi` (the same species), `:name` (a name matched) or `:none` |
| `candidates` | how many rows the compound has; more than one means you have to choose |
| `formula_check` | the formulas compared by their elements: `:same`, `:different`, `:unknown` |
| `inchi_check` | the InChIs compared: `:same`, `:stereo` (the same skeleton with other stereochemistry or isotopes), `:different`, `:unknown` |

A link through the InChIKey or the InChI is the same species. **A link through a name is only a lead**: names are shared between species. In the archive of 2020-09-30, `"sulfur"` leads to hydrogen sulfide, `"(E)-3-hexene"` to `cis-3-hexene` and a hydrate to its anhydrous salt. Trust a `:name` link only when `formula_check` and `inchi_check` are `:same`; `:stereo` and `:different` mean a related compound, not the same one. `link_compounds(db, cdb; by_name = false)` links by InChIKey and InChI only. The archive is never changed, and nothing is disambiguated in it.

On that archive (8 526 compounds, 8 517 of them with an InChIKey), 4 363 were found by InChIKey, 293 only by name and 3 870 were not found, and the compounds found account for 87 % of the appearances of a component in a measurement. The compounds that are missing are, above all, ionic liquids and uncommon organic compounds that the lists do not cover, and some of them, such as 1-butyl-3-methylimidazolium tetrafluoroborate, are among the most measured. The measurement was made on that date and changes with the archive and the lists.

[`find_compounds`](@ref) understands the database too, when you give it as the second argument, or the linked database as the first:

```julia
find_compounds(db, cdb, "7732-18-5")   # water in the archive, from its CAS number
find_compounds(linked, "oxidane")      # the same, from a synonym that no article used
```

The ThermoML compounds with the same InChIKey as any compound the text identifies are found first. A compound of the archive that has no InChIKey is reached only through its own names, so nothing is guessed.

## Searching the archive with any name

A [`LinkedDatabase`](@ref) takes the place of the archive in [`points`](@ref) and [`mixture`](@ref), and a compound can be named by anything either database knows:

```julia
points(linked; component = "oxidane", property = "Mass density")   # a synonym
points(linked; component = "7732-18-5", temperature = (280, 300))  # a CAS number
mixture(linked, "7732-18-5", "64-17-5")                            # water + ethanol
```

The result is an ordinary [`DataView`](@ref) of the archive, so everything else works on it as before. Because a view does not remember the compound database, refine it with the names that the archive itself uses.

### When a name is ambiguous

A text that leads to one compound of the archive is used as it is. A text that leads to several is not guessed: a formula such as `"C4H10"` belongs to two isomers, and a name can be used for different species. The candidates are listed, with their formula, InChIKey, CAS number, other names and number of points, ordered by number of points and then by name, so the same number means the same compound every time on the same data:

```text
"C4H10" matches 2 compounds of the dataset:
  1. n-butane  |  C4H10  |  IJDNQMDRQITEOD-UHFFFAOYSA-N  |  CAS 106-97-8  |  5 points
  2. isobutane  |  C4H10  |  NNPPMTNAJDCUHE-UHFFFAOYSA-N  |  CAS 75-28-5  |  1 points
Which one? (1-2, a for all of them, q to cancel):
```

Answer with the number, `a` for all of them (they then count as the same component, as in `points(db; component = "C4H10")`), or `q` to cancel. An invalid answer is asked again. A text with no exact candidate but close ones (a misspelling) is listed in the same way, without the `a` option: a close name is never taken without your answer.

The keyword `choose` of `points` and `mixture` controls this:

| `choose` | Behavior |
| :-- | :-- |
| `:ask` (default) | asks in the terminal when the session is interactive (`isinteractive()` is `true`, as in the REPL and in VS Code); otherwise throws an `ArgumentError` that lists the candidates, because a script that nobody watches must not choose |
| `:error` | never asks; throws the same error |
| `:all` | takes every exact candidate; a text with only close candidates is still refused |
| `Dict("butane" => 2, "C4H10" => :all)` | an answer prepared for each text, by the number the menu shows, so a script does not stop; a text that is not in the dictionary is handled as with `:ask` |

The question is read from `input` and written to `output` (`stdin` and `stdout` by default), which is how it is tested. The answers you give are kept in `linked.choices` and used again for the same text during the session; [`forget_choices!`](@ref) clears them. Nothing is written to disk, and the archive is never changed.

## Adding your own compounds

[`register_compound!`](@ref) adds a compound that the lists lack, or completes one they have. What you give replaces what the row had, and your first name becomes its main name:

```julia
register_compound!(cdb;
    names = ["cesium formate", "caesium formate"],
    inchikey = "WLHQEXWBUBNKIO-UHFFFAOYSA-N",
    cas = "3495-36-1",
    molar_mass = 177.92,          # g/mol, for example from the certificate of the supplier
)
save_compounds(cdb)               # without this, the compound exists only in this session
```

By default `register_compound!` changes the database only in the session, so that nothing is written to your disk without you asking. Pass `save = true` to write at once, in the same call:

```julia
register_compound!(cdb; names = ["cesium formate"], molar_mass = 177.92, save = true)
```

With `save = true` all the compounds that are yours (this one and the ones added before in the session) are written to `custom.jld2`, in the folder the database was loaded from, or in `dir = "..."` if you give one. The lists are never written to.

A compound needs an InChIKey or a name. The rows you added or changed are marked (`custom`) and kept in `custom.jld2`; they are laid over the lists again every time the database loads, so a new version of the lists does not remove them. A molar mass that you give is the one the conversions of concentration will use first.

## Limits

- The lists come from a third party and are fixed at one commit; they are not updated by the package. A new commit comes with a new version of ThermophysicalDB.jl.
- Names are ambiguous, identifiers are exact: prefer the InChIKey and check the `formula_check` and `inchi_check` of a link made through a name.
- The molar mass of a row is that of the entry as the lists describe it. A hydrate and its anhydrous salt are different entries; choose the one that your sample is, or give the molar mass yourself.
- Searching PubChem for the compounds that are missing is not part of this version.
