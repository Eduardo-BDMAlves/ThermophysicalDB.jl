```@meta
CurrentModule = ThermophysicalDB
```

# [Bibliography](@id bibliography)

The works cited in this documentation. Each page cites them with the key of the entry, for example `[Walker2022](@cite)`: the sources of the data and the articles about them are written in the `CITATION.cff` of the package, and the rest of the literature in `docs/src/refs-literature.bib`. The experimental data themselves come from the ThermoML Archive of NIST/TRC and from the articles it indexes; see [About the data](@ref 40-about-data).

```@bibliography
```

## State of the references

The references of `CITATION.cff` are checked every time this documentation is built, so a wrong key, a missing field or a record that disagrees with its DOI shows up here. The check has two parts:

- **The file itself.** Every reference has a title, authors, a year, a DOI when it is an article, `keywords`, and an `abbreviation` that is the key the pattern of the reference manager gives (surname of the first author, year and first word of the title, in lower case). Problems are listed as `problem:`.
- **A second source.** The record of each article is requested from the DOI resolver and compared with the file: authors, title, year, volume and pages. Differences are listed as conflicts. A year that differs by one with the same volume and pages is a `note`: the DOI record gives the date of online publication and the citation the date of the issue. The ThermoML Archive is a dataset and is not compared, since its DOI record does not list the authors.

An article whose record could not be fetched is listed as `unresolved` with the reason, and counts as a failure: a check that could not ask the resolver has not checked anything.

```@example check
using ThermophysicalDB
ThermophysicalDB.check_references()
```

[`ThermophysicalDB.check_references`](@ref) is run the same way from a Julia session after editing `CITATION.cff`.
