# Notices

ThermophysicalDB.jl is released under the MIT license (see [LICENSE](LICENSE)). This file lists the third-party material that the package reads, mentions or was built from, and the notices that go with it.

## ThermoML Archive (NIST/TRC)

The first database supported by the package is the ThermoML Archive of the Thermodynamics Research Center (TRC) of the U.S. National Institute of Standards and Technology (NIST), published as the dataset [doi:10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422) under the terms described in the [NIST statement on copyright, fair use and licensing](https://www.nist.gov/open/license).

- **Not included.** This repository and the released package contain no file of the archive. The package downloads the archive from NIST to the computer of each user and checks it against the digest published by NIST. The test suite uses fictitious data only.
- **Permission of the publishers.** NIST states that the files of the archive are available with permission of the journal publishers. The package does not mirror or redistribute them. Anyone who redistributes data obtained through the package should first check that they are allowed to.
- **Statement requested by TRC.** Data distributed through the *Journal of Chemical & Engineering Data*, *The Journal of Chemical Thermodynamics*, *Fluid Phase Equilibria*, *Thermochimica Acta* and *International Journal of Thermophysics* ThermoML Archives.
- **Modified data.** Tables produced by the package (SI units, uncertainties restated at k = 2, selections) are modified forms of the published data. When they are shared, state that the data were modified, with the date and the nature of the changes, and acknowledge NIST as the source.
- **No evaluation.** NIST/TRC checked the values and metadata of the archive for completeness and accuracy of representation, but did not critically evaluate them, and the package does not either.
- **No warranty.** The data are provided by NIST as a public service, as they are. The package is provided under the MIT license without warranty of any kind.
- **No affiliation.** ThermophysicalDB.jl is an independent project. It is not affiliated with, sponsored or endorsed by NIST, TRC, IUPAC or the publishers of the journals. Their names are used only to identify the data source and the standard.

What to cite when you use the data:

1. The articles of the points you used. Each point carries the DOI of its article.
2. The archive as a dataset: ThermoML/Data Archive, NIST Thermodynamics Research Center, [doi:10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422).
3. The standard: M. Frenkel, R. D. Chirico, V. Diky, Q. Dong, K. N. Marsh, J. H. Dymond, W. A. Wakeham, S. E. Stein, E. Königsberger and A. R. H. Goodwin, "XML-based IUPAC standard for experimental, predicted, and critically evaluated thermodynamic property data storage and capture (ThermoML)", *Pure and Applied Chemistry* 78 (3), 541-612, 2006, [doi:10.1351/pac200678030541](https://doi.org/10.1351/pac200678030541).
4. This package, as described in [CITATION.cff](CITATION.cff).

## ThermoML standard and schema

The package reads files that follow ThermoML, an XML-based IUPAC standard for thermophysical and thermochemical property data. The schema (`ThermoML.xsd`) is distributed by NIST together with the archive; this repository does not include a copy of it.

## Project template and community files

- The package structure, configuration files and workflows were generated with [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl). See that repository for the terms of the template.
- `CODE_OF_CONDUCT.md` is based on the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1, which its authors release under the Creative Commons Attribution 4.0 International license.

## Dependencies

The package depends on other Julia packages (see `Project.toml`), and its documentation and tutorials on others (see `docs/Project.toml`), among them [Clapeyron.jl](https://github.com/ClapeyronThermo/Clapeyron.jl) and Makie. None of them is copied into this repository. Each one is distributed under its own license, which applies to it and not to this package.
