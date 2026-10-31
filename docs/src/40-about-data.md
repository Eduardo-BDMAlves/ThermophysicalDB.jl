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

The archive is published as a dataset with the DOI [10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422) [riccardi2021thermoml](@cite), described in [riccardi2022towards](@cite), in the form of one compressed file that contains each article as an XML and a JSON file. This package downloads that file to your computer, checks it against the SHA-256 digest published by NIST, and reads the JSON files.

!!! info "The snapshot this version was developed against"
    The file `ThermoML.v2020-09-30.tgz` of the archive (a snapshot dated 2020-09-30; the dataset record has its own version number, used in the citation below): 11 923 articles, from which the package extracts 122 481 studied systems. The package asks NIST for the latest release each time you use it (see [Downloads, updates and cache](@ref updates)), so newer releases are picked up without a new version of the package.

## What this package does to the data

| Step | What happens |
| :-- | :-- |
| Download | The file is fetched from NIST and verified. The package never redistributes it. |
| Parsing | Every property value, with its conditions, composition and uncertainty, becomes one row of a table. Values are stored exactly as published. |
| Units | Conversions to SI or to Unitful are done on request, with exact factors. They are never applied silently. |
| Uncertainty | The published uncertainty is kept untouched; a second column restates it at ``k = 2`` using a documented rule. See [Uncertainty](@ref uncertainty). |
| Filtering | Only the filters that you give are applied. Outlier detection is an optional, separate step, implemented in this package and not endorsed by TRC/NIST; nothing is removed from the data unless you ask for it. |

!!! warning "Experimental data, as published"
    The archive is a collection of *published* experimental results. It is not a critically evaluated database: points from different articles can disagree, some are wrong, and the same measurement may appear in more than one article. Judging the quality of a point is your task, and the tutorials show ways to do it (for instance, [comparing water densities with a reference equation](@ref tutorial_water)).

## What is not included

- **Reaction data.** The archive also contains reaction and equilibrium-constant blocks; this version of the package reads property data of pure compounds and mixtures only.
- **Systems with more than three components.** The archive contains none.
- **Predicted and critically evaluated data.** ThermoML can store them, but this package is built for the experimental data of the archive.

## Terms of use and citation

The data are provided by NIST/TRC and come from published articles. Read the terms on the [dataset page of NIST](https://data.nist.gov/od/id/mds2-2422) and the [NIST statement on copyright, fair use and licensing](https://www.nist.gov/open/license) before reusing the data in your own work. This package is an independent open-source project: it is not a product of NIST, TRC, IUPAC or the journals, and it is not sponsored or endorsed by any of them.

!!! info "Permission of the publishers"
    NIST states that the files of the ThermoML Archive are available with permission of the journal publishers. For that reason this package does not contain, mirror or redistribute any file of the archive: every user downloads it directly from NIST, to their own computer. If you redistribute data obtained through this package, check first that you are allowed to.

!!! info "Statement requested by TRC"
    TRC asks that works which use ThermoML Archive data include a statement of the form *Data distributed through the [journal(s)] ThermoML Archive(s)*, naming the journals of the articles whose points were used, together with the citations listed below.

!!! info "NIST disclaimer and liability statement"
    <!-- Text collected on 2026-10-30 with a summarising tool. Replace it by the exact wording of the section "Fair Use of Other NIST Data/Works" of https://www.nist.gov/open/copyright-fair-use-and-licensing-statements-srd-data-software-and-technical-series-publications before the repository is made public. -->
    The data are provided by NIST as a public service and are expressly provided "AS IS".
    NIST MAKES NO WARRANTY OF ANY KIND, EXPRESS, IMPLIED OR STATUTORY, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT AND DATA ACCURACY.
    NIST does not warrant or make any representations regarding the use of the data or the results thereof.
    NIST SHALL NOT BE LIABLE AND YOU HEREBY RELEASE NIST FROM LIABILITY FOR ANY INDIRECT, CONSEQUENTIAL, SPECIAL, OR INCIDENTAL DAMAGES (INCLUDING DAMAGES FOR LOSS OF BUSINESS PROFITS, BUSINESS INTERRUPTION, LOSS OF BUSINESS INFORMATION, AND THE LIKE), WHETHER ARISING IN TORT, CONTRACT, OR OTHERWISE, ARISING FROM OR RELATING TO THE DATA (OR THE USE OF OR INABILITY TO USE THIS DATA), EVEN IF NIST HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
    Source: [NIST statement on copyright, fair use and licensing](https://www.nist.gov/open/copyright-fair-use-and-licensing-statements-srd-data-software-and-technical-series-publications).

!!! warning "Modified data and warranty"
    The tables produced by this package (values in SI units, uncertainties restated at ``k = 2``, selections and merges) are modified forms of the published data. When you share them, say that the data were modified, state the date and the nature of the changes, and acknowledge NIST as the source, as the NIST license asks for modified data. The package is provided under the MIT license without any warranty. NIST/TRC checked the values and metadata for completeness and accuracy of representation, but did not critically evaluate them, and this package does not either. You are responsible for checking the data before using them and for following the terms of NIST and of the publishers.

## The notice in your files

Everything the package writes from the archive carries the same notice, so that it travels with the data: the origin, the full citation of the dataset (version 1.2), that the data are modified and not evaluated or endorsed by NIST/TRC, that the original articles must be credited, and a link to the terms. It is the first line of a `.csv` (after `#`; read it with `header = 2`), a comment at the top of a `.tex`, the `origin` entry of a `.json`, the `origin` group of a `.jld2`, the `origin` sheet of a `.xlsx`, an `@comment` at the top of a `.bib`, and a comment at the top of the tables of [`reference_summary`](@ref) (`notice = false` leaves it out of those). The text is the same everywhere, because it is written in one place of the package:

```@example notice
using ThermophysicalDB
print(ThermophysicalDB.notice_text())
```

The same text, shortened, is logged once, when the archive is downloaded for the first time. Points that do not come from the archive (your own data) carry no notice.

A `.csv` or `.tex` of points holds the BibTeX key of each article, not its DOI. If you ask for `references = false` together with `reference = :key`, the `.bib` is not written and the DOI behind each key is lost, so the package warns you; use `reference = :doi` in that case.

When you publish results obtained with this package, please cite:

1. **The original articles of the points that you used.** Every point carries the DOI of its article in the `doi` column, so a list of references for any selection is one line:

   ```julia
   unique(table(selection).doi)
   ```

2. **The ThermoML Archive** as a dataset (DOI 10.18434/mds2-2422), in the form requested by NIST/TRC [riccardi2021thermoml](@cite). Replace the access date by the date on which you downloaded the archive.
3. **The article on the archive**: [riccardi2022towards](@cite).
4. **The ThermoML standard**: [frenkel2006xml](@cite).
5. **This package**, with the reference given in the [`CITATION.cff`](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/CITATION.cff) file of the repository.

## Further reading on ThermoML

- [frenkel2003thermoml](@cite): the first part of the ThermoML description, on experimental data.
- [chirico2003thermoml](@cite): the second part, on the way ThermoML records uncertainties.
- The [ThermoML home page](https://trc.nist.gov/ThermoML/) of NIST/TRC, which describes the standard, the schema and the participating journals.

The works cited on this page are listed in the [Bibliography](@ref bibliography).
