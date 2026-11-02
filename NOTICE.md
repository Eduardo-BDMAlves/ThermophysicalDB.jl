# Notices

ThermophysicalDB.jl is released under the MIT license (see [LICENSE](LICENSE)). This file lists the third-party material that the package reads, mentions or was built from, and the notices that go with it.

## ThermoML Archive (NIST/TRC)

The first database supported by the package is the ThermoML Archive of the Thermodynamics Research Center (TRC) of the U.S. National Institute of Standards and Technology (NIST), published as the dataset [doi:10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422) under the terms described in the [NIST statement on copyright, fair use and licensing](https://www.nist.gov/open/license).

- **Not included.** This repository and the released package contain no file of the archive. The package downloads the archive from NIST to the computer of each user and checks it against the digest published by NIST. The test suite uses fictitious data only.
- **Permission of the publishers.** NIST states that the files of the archive are available with permission of the journal publishers. The package does not mirror or redistribute them. Anyone who redistributes data obtained through the package should first check that they are allowed to.
- **Statement requested by TRC.** Data distributed through the *Journal of Chemical & Engineering Data*, *The Journal of Chemical Thermodynamics*, *Fluid Phase Equilibria*, *Thermochimica Acta* and *International Journal of Thermophysics* ThermoML Archives.
- **Modified data.** Tables produced by the package (SI units, uncertainties restated at k = 2, selections) are modified forms of the published data. When they are shared, state that the data were modified, with the date and the nature of the changes, and acknowledge NIST as the source.
- **No evaluation.** NIST/TRC checked the values and metadata of the archive for completeness and accuracy of representation, but did not critically evaluate them, and the package does not either.
- **No warranty.** The data are provided by NIST as a public service, as they are. The package is provided under the MIT license without warranty of any kind. The NIST statement, with its disclaimer and liability terms, is reproduced below.
- **No affiliation.** ThermophysicalDB.jl is an independent project. It is not affiliated with, sponsored or endorsed by NIST, TRC, IUPAC or the publishers of the journals. Their names are used only to identify the data source and the standard.

### NIST statement on the data

> This data/work was created by employees of the National Institute of Standards and Technology (NIST), an agency of the Federal Government. Pursuant to title 17 United States Code Section 105, works of NIST employees are not subject to copyright protection in the United States.  This data/work may be subject to foreign copyright.
>
> The data/work is provided by NIST as a public service and is expressly provided “AS IS.”
> NIST MAKES NO WARRANTY OF ANY KIND, EXPRESS, IMPLIED OR STATUTORY, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT AND DATA ACCURACY.
> NIST does not warrant or make any representations regarding the use of the data or the results thereof, including but not limited to the correctness, accuracy, reliability or usefulness of the data.
> NIST SHALL NOT BE LIABLE AND YOU HEREBY RELEASE NIST FROM LIABILITY FOR ANY INDIRECT, CONSEQUENTIAL, SPECIAL, OR INCIDENTAL DAMAGES (INCLUDING DAMAGES FOR LOSS OF BUSINESS PROFITS, BUSINESS INTERRUPTION, LOSS OF BUSINESS INFORMATION, AND THE LIKE), WHETHER ARISING IN TORT, CONTRACT, OR OTHERWISE, ARISING FROM OR RELATING TO THE DATA (OR THE USE OF OR INABILITY TO USE THIS DATA), EVEN IF NIST HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
>
> To the extent that NIST may hold copyright in countries other than the United States, you are hereby granted the non-exclusive irrevocable and unconditional right to print, publish, prepare derivative works and distribute the NIST data, in any medium, or authorize others to do so on your behalf, on a royalty-free basis throughout the world.
>
> You may improve, modify, and create derivative works of the data or any portion of the data, and you may copy and distribute such modifications or works. Modified works should carry a notice stating that you changed the data and should note the date and nature of any such change. Please explicitly acknowledge the National Institute of Standards and Technology as the source of the data:  Data citation recommendations are provided at <https://www.nist.gov/open/license>.
>
> Permission to use this data is contingent upon your acceptance of the terms of this agreement and upon your providing appropriate acknowledgments of NIST’s creation of the data/work.

Text of the statement for NIST data and works, as supplied by NIST/TRC for the ThermoML Archive and published in the section “Fair Use of Other NIST Data/Works” of the page [Copyright, Fair Use, and Licensing Statements](https://www.nist.gov/open/copyright-fair-use-and-licensing-statements-srd-data-software-and-technical-series-publications). Copied on 2026-10-31; reproduced without changes.

What to cite when you use the data:

1. The articles of the points you used. Each point carries the DOI of its article.
2. The archive as a dataset, in the form requested by NIST/TRC: D. Riccardi, A. Bazyleva, E. Paulechka, V. Diky, J. W. Magee, A. F. Kazakov, S. A. Townsend and C. D. Muzny, *ThermoML/Data Archive*, National Institute of Standards and Technology, 2021, [doi:10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422) (version 1.2, accessed on the date you downloaded the archive).
3. The article on the archive: D. Riccardi, Z. Trautt, A. Bazyleva, E. Paulechka, V. Diky, J. W. Magee, A. F. Kazakov, S. A. Townsend and C. D. Muzny, "Towards improved FAIRness of the ThermoML Archive", *Journal of Computational Chemistry* 43 (12), 879-887, 2022, [doi:10.1002/jcc.26842](https://doi.org/10.1002/jcc.26842).
4. The standard: M. Frenkel, R. D. Chirico, V. Diky, Q. Dong, K. N. Marsh, J. H. Dymond, W. A. Wakeham, S. E. Stein, E. Königsberger and A. R. H. Goodwin, "XML-based IUPAC standard for experimental, predicted, and critically evaluated thermodynamic property data storage and capture (ThermoML)", *Pure and Applied Chemistry* 78 (3), 541-612, 2006, [doi:10.1351/pac200678030541](https://doi.org/10.1351/pac200678030541).
5. This package, as described in [CITATION.cff](CITATION.cff).

## Compound identifiers (chemicals repository and PubChem)

The compound database (`compound_database()`) is built from lists of identifiers published in the repository [CalebBell/chemicals](https://github.com/CalebBell/chemicals), folder `chemicals/Identifiers`, at the commit `e79047588b30cfabc564c79fb26d760c746877d7`. According to the authors of that repository, the largest list is a database of metadata on about 70 000 chemicals from [PubChem](https://pubchem.ncbi.nlm.nih.gov); the other lists add inorganic compounds, cations, anions and further examples.

- **Not included.** This repository and the released package contain none of these lists. The package downloads them to the computer of each user, from that commit, and checks every file against its SHA-256 digest.
- **chemicals.** The repository is released under the MIT license, copyright (C) 2016-2021 Caleb Bell. The package reads its lists; it does not use its code.
- **PubChem.** The identifiers that originate in PubChem remain subject to the policies of PubChem and of the National Library of Medicine, and the sources that deposited the records may have terms of their own. Anyone who redistributes data obtained through the package should check them and credit PubChem as its policies ask.
- **No warranty and no affiliation.** The lists are used as they are published, without review: names, identifiers and molar masses may contain errors. ThermophysicalDB.jl is not affiliated with, sponsored or endorsed by the authors of chemicals, PubChem or the National Library of Medicine.

## ThermoML standard and schema

The package reads files that follow ThermoML, an XML-based IUPAC standard for thermophysical and thermochemical property data. The schema (`ThermoML.xsd`) is distributed by NIST together with the archive; this repository does not include a copy of it.

## Project template and community files

- The package structure, configuration files and workflows were generated with [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl). See that repository for the terms of the template.
- `CODE_OF_CONDUCT.md` is based on the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1, which its authors release under the Creative Commons Attribution 4.0 International license.

## Dependencies

The package depends on other Julia packages (see `Project.toml`), and its documentation and tutorials on others (see `docs/Project.toml`), among them [Clapeyron.jl](https://github.com/ClapeyronThermo/Clapeyron.jl) and Makie. None of them is copied into this repository. Each one is distributed under its own license, which applies to it and not to this package.
