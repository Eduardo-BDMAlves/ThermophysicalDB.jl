"""
    ThermophysicalDB

Download, cache and query experimental thermophysical property data from public
databases, starting with the NIST/TRC ThermoML Archive.
"""
module ThermophysicalDB

using CodecZlib: GzipDecompressorStream
using Dates: Dates
using Downloads: Downloads
using Preferences: Preferences
using SHA: SHA
using TOML: TOML
using Tar: Tar

include("remote/datadir.jl")
include("remote/checksum.jl")
include("remote/releases.jl")
include("remote/manifest.jl")
include("remote/archive.jl")
include("remote/install.jl")
include("units/catalog.jl")
include("uncertainty/coverage.jl")
include("schema/pool.jl")
include("schema/tables.jl")
include("schema/dataset.jl")

export check_update,
    data_dir, ensure_archive, reset_data_dir!, set_data_dir!, update_database!

end
