"""
    ThermophysicalDB

Download, cache and query experimental thermophysical property data from public
databases, starting with the NIST/TRC ThermoML Archive.
"""
module ThermophysicalDB

using CodecZlib: GzipDecompressorStream
using Dates: Dates
using DOI2BibTeX: DOI2BibTeX
using Downloads: Downloads
using JLD2: JLD2
using JSON: JSON
using LinearAlgebra: I, Symmetric, cholesky!, issuccess, lu
using Preferences: Preferences
using SHA: SHA
using SpecialFunctions: SpecialFunctions
using TOML: TOML
using Tables: Tables
using Tar: Tar
using Unicode: Unicode
using YAML: YAML

include("remote/datadir.jl")
include("remote/checksum.jl")
include("remote/releases.jl")
include("remote/manifest.jl")
include("remote/archive.jl")
include("remote/download.jl")
include("remote/install.jl")
include("remote/local.jl")
include("units/exact.jl")
include("units/catalog.jl")
include("units/backend.jl")
include("uncertainty/coverage.jl")
include("schema/pool.jl")
include("schema/tables.jl")
include("schema/dataset.jl")
include("schema/relations.jl")
include("query/compounds.jl")
include("query/select.jl")
include("parse/types.jl")
include("parse/purity.jl")
include("parse/article.jl")
include("parse/ingest.jl")
include("parse/build.jl")
include("query/table.jl")
include("uncertainty/budget.jl")
include("store/serialize.jl")
include("store/cache.jl")
include("store/database.jl")
include("compounds/seed.jl")
include("compounds/table.jl")
include("compounds/store.jl")
include("compounds/pubchem.jl")
include("compounds/link.jl")
include("compounds/linked.jl")
include("references.jl")
include("notice.jl")
include("export/bibtex.jl")
include("export/citation.jl")
include("export/check.jl")
include("export/purity.jl")
include("export/summary.jl")
include("export/points.jl")
include("export/thermoml.jl")
include("export/conditions.jl")
include("outliers/stats.jl")
include("outliers/esd.jl")
include("outliers/physical.jl")
include("outliers/polyfit.jl")
include("outliers/prepare.jl")
include("outliers/trend.jl")
include("outliers/surface.jl")
include("outliers/detect.jl")
include("outliers/pipeline.jl")
include("precompile.jl")

export CompoundDB,
    LinkedDatabase,
    DataView,
    UncertaintyTerm,
    bibtex,
    check_update,
    compound_database,
    compound_record,
    condition_table,
    csv_table,
    database_dir,
    database,
    diagnostics,
    ensure_archive,
    esd,
    expanded_uncertainty,
    export_points,
    fetch_pubchem!,
    find_compounds,
    find_outliers,
    forget_choices!,
    install_archive!,
    latex_table,
    link_compounds,
    lookup_compounds,
    markdown_table,
    mixture,
    points,
    prefetch_compounds!,
    pubchem_rate!,
    purity_step_table,
    reasons,
    register_compound!,
    reference_summary,
    reset_database_dir!,
    sample_table,
    save_compounds,
    set_database_dir!,
    set_uncertainty!,
    table,
    uncertainty_table,
    update_database!,
    write_bibtex,
    write_references

end
