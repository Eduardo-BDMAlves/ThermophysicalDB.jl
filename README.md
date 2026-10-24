# ThermophysicalDB

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://eduardo-bdmalves.github.io/ThermophysicalDB.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://eduardo-bdmalves.github.io/ThermophysicalDB.jl/dev)
[![Test workflow status](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/Eduardo-BDMAlves/ThermophysicalDB.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Eduardo-BDMAlves/ThermophysicalDB.jl)
[![Lint workflow Status](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![DOI](https://zenodo.org/badge/DOI/FIXME)](https://doi.org/FIXME)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![All Contributors](https://img.shields.io/github/all-contributors/Eduardo-BDMAlves/ThermophysicalDB.jl?labelColor=5e1ec7&color=c0ffee&style=flat-square)](#contributors)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

## Data source

ThermophysicalDB.jl reads the **ThermoML Archive**, the experimental thermophysical property database of the Thermodynamics Research Center (TRC) at NIST, built on the IUPAC ThermoML standard ([dataset DOI 10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422)). The data are theirs and the authors' of the original articles; this package is an independent project that downloads, reads and filters them. The aim is to bring several experimental databases under one interface, starting with this one.

Data distributed through the *Journal of Chemical & Engineering Data*, *The Journal of Chemical Thermodynamics*, *Fluid Phase Equilibria*, *Thermochimica Acta* and *International Journal of Thermophysics* ThermoML Archives. NIST states that these files are available with permission of the journal publishers, so this package does not contain or redistribute any of them: it downloads the archive directly from NIST to your computer. It is an independent project, not affiliated with, sponsored or endorsed by NIST, TRC, IUPAC or the publishers, and it comes with no warranty. See [NOTICE.md](NOTICE.md) and the [About the data](docs/src/40-about-data.md) page for the terms, the citations and the notice that applies to modified data.

## How to Cite

If you use ThermophysicalDB.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/CITATION.cff).

## Contributing

If you want to make contributions of any kind, please first that a look into our [contributing guide directly on GitHub](docs/src/90-contributing.md) or the [contributing page on the website](https://eduardo-bdmalves.github.io/ThermophysicalDB.jl/dev/90-contributing/)

---

### Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
