```@meta
CurrentModule = ThermophysicalDB
```

# [About the data](@id 40-about-data)

ThermophysicalDB.jl is a *reader*: it does not contain any data of its own.

!!! info "Credit"
    All the data accessed through this package are the work of others. The experimental values are published by the authors of the original articles. They are collected, standardised and distributed by the Thermodynamics Research Center (TRC) of the U.S. National Institute of Standards and Technology (NIST) as the **ThermoML Archive**, using the **ThermoML** standard developed by IUPAC and NIST/TRC. This package only downloads, reads and filters that archive.

The purpose of the package is to bring several experimental thermophysical databases under one interface. For now the only database supported is the ThermoML Archive. This page says where its data come from, what has and has not been done to them, and how to cite them.

## The ThermoML Archive

The first database supported is the **ThermoML Archive** of the Thermodynamics Research Center (TRC) at the U.S. National Institute of Standards and Technology (NIST). ThermoML is an IUPAC standard in XML for storing experimental thermophysical and thermochemical property data. The archive holds the data tables of articles published in the journals that take part in the project (the *Journal of Chemical & Engineering Data*, the *Journal of Chemical Thermodynamics*, *Fluid Phase Equilibria*, *Thermochimica Acta* and the *International Journal of Thermophysics*).

The archive is published as a dataset with the DOI [10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422), in the form of one compressed file that contains each article as an XML and a JSON file. This package downloads that file to your computer, checks it against the SHA-256 digest published by NIST, and reads the JSON files.

!!! info "The snapshot this version was developed against"
    Version `2020-09-30` of the archive: 11 923 articles, from which the package extracts 122 481 studied systems. The package asks NIST for the latest release each time you use it (see [Downloads, updates and cache](@ref updates)), so newer releases are picked up without a new version of the package.

## What this package does to the data

| Step | What happens |
| :-- | :-- |
| Download | The file is fetched from NIST and verified. The package never redistributes it. |
| Parsing | Every property value, with its conditions, composition and uncertainty, becomes one row of a table. Values are stored exactly as published. |
| Units | Conversions to SI or to Unitful are done on request, with exact factors. They are never applied silently. |
| Uncertainty | The published uncertainty is kept untouched; a second column restates it at ``k = 2`` using a documented rule. See [Uncertainty](@ref uncertainty). |
| Filtering | Only the filters that you give are applied. There is no outlier removal, no averaging and no selection of "recommended" values. |

!!! warning "Experimental data, as published"
    The archive is a collection of *published* experimental results. It is not a critically evaluated database: points from different articles can disagree, some are wrong, and the same measurement may appear in more than one article. Judging the quality of a point is your task, and the tutorials show ways to do it (for instance, [comparing water densities with a reference equation](@ref tutorial_water)).

## What is not included

- **Reaction data.** The archive also contains reaction and equilibrium-constant blocks; this version of the package reads property data of pure compounds and mixtures only.
- **Systems with more than three components.** The archive contains none.
- **Predicted and critically evaluated data.** ThermoML can store them, but this package is built for the experimental data of the archive.

## Terms of use and citation

The data are provided by NIST/TRC and come from published articles. Read the terms on the [dataset page of NIST](https://data.nist.gov/od/id/mds2-2422) before reusing the data in your own work, and note that this package is an independent open-source project, not a product of NIST or TRC.

When you publish results obtained with this package, please cite:

1. **The original articles of the points that you used.** Every point carries the DOI of its article in the `doi` column, so a list of references for any selection is one line:

   ```julia
   unique(table(selection).doi)
   ```

2. **The ThermoML Archive** as a dataset (DOI 10.18434/mds2-2422), in the form recommended on its page.
3. **The ThermoML standard**: M. Frenkel *et al.*, "XML-based IUPAC standard for experimental, predicted, and critically evaluated thermodynamic property data storage and capture (ThermoML)", *Pure and Applied Chemistry* **78** (2006) 541–612.
4. **This package**, with the reference given in the [`CITATION.cff`](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/CITATION.cff) file of the repository.

## Further reading on ThermoML

- R. D. Chirico, M. Frenkel, V. V. Diky, K. N. Marsh, R. C. Wilhoit, "ThermoML: An XML-based approach for storage and exchange of experimental and critically evaluated thermophysical and thermochemical property data. 1. Experimental data", *Journal of Chemical & Engineering Data* **48** (2003) 1344–1359.
- M. Frenkel, R. D. Chirico, V. V. Diky, K. N. Marsh, J. H. Dymond, W. A. Wakeham, "ThermoML: An XML-based approach for storage and exchange of experimental and critically evaluated thermophysical and thermochemical property data. 2. Uncertainties", *Journal of Chemical & Engineering Data* **48** (2003) 2–13.
- The [ThermoML home page](https://trc.nist.gov/ThermoML/) of NIST/TRC, which describes the standard, the schema and the participating journals.
