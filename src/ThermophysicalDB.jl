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
using Preferences: Preferences
using SHA: SHA
using TOML: TOML
using Tables: Tables
using Tar: Tar
using Unicode: Unicode
using Unitful: Unitful, @u_str

include("remote/datadir.jl")
include("remote/checksum.jl")
include("remote/releases.jl")
include("remote/manifest.jl")
include("remote/archive.jl")
include("remote/download.jl")
include("remote/install.jl")
include("remote/local.jl")
include("units/catalog.jl")
include("uncertainty/coverage.jl")
include("schema/pool.jl")
include("schema/tables.jl")
include("schema/dataset.jl")
include("schema/relations.jl")
include("query/select.jl")
include("parse/types.jl")
include("parse/article.jl")
include("parse/ingest.jl")
include("parse/build.jl")
include("query/table.jl")
include("store/serialize.jl")
include("store/cache.jl")
include("store/database.jl")
include("export/bibtex.jl")
include("export/summary.jl")
include("export/points.jl")

export DataView,
    bibtex,
    check_update,
    csv_table,
    database_dir,
    database,
    ensure_archive,
    export_points,
    install_archive!,
    latex_table,
    markdown_table,
    points,
    reference_summary,
    reset_database_dir!,
    set_database_dir!,
    table,
    update_database!,
    write_bibtex,
    write_references

end
