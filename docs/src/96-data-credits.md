```@meta
CurrentModule = ThermophysicalDB
```

# [Data credits](@id data_credits)

The examples of this documentation run on the ThermoML Archive of NIST/TRC, and every point they use was measured and published by the authors of an article. This page lists those articles: the ones behind the selections of every page that shows data, with the number of points taken from each. It is written by the build of the site from what the examples selected, so it follows them when a page changes or the archive is updated.

The terms of use of the data, and how to cite the dataset itself, are in [About the data](@ref 40-about-data). The articles should be credited whenever their data are used, and the BibTeX file below is made for that:

```@raw html
<p><a class="tdb-download" href="data-credits.bib" download>Download the BibTeX file (data-credits.bib)</a></p>
```

The file is the one [`bibtex`](@ref) writes for these selections: the entry that the DOI resolver delivers for each article, completed with what only the archive has, followed by the entries that credit the archive and the ThermoML standard, and the notice of the data as a comment. An article whose DOI cannot be resolved is written from the metadata of the archive alone.

```@example credits
Main.DocsCredits.credits_page()
```
