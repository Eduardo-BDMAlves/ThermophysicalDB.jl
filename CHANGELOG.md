# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

- Initial release
- Added `export_points`, which writes the points of a selection to `.csv`, `.xlsx` (through the XLSX package extension), `.json`, `.jld2` and a ThermoML-format subset, chosen by the extension of the path, or to a directory holding all of them
- Added NOTICE.md, legal notices in the README and in the documentation, and the data source references in CITATION.cff
- Added `find_outliers`, which splits a selection into kept points, outliers and disputed points with the reason for each (physical rules, local parabolas along each axis, a joint surface when several axes vary, and the generalized ESD test), plus `reasons`, `diagnostics` and `esd`; see the manual page "Detecting outliers"
- Test fixtures use fictitious bibliographic data

<!-- Links -->

[keep a changelog]: https://keepachangelog.com/en/1.1.0/
[semantic versioning]: https://semver.org/spec/v2.0.0.html

<!-- Versions -->

[unreleased]: https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/compare/v0.1.0...HEAD
