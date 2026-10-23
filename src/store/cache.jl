# On-disk cache of the parsed Dataset, next to the ThermoML archive it came from.
#
#   dataset.jld2   the columns (written first, to a .part file, then moved into place)
#   dataset.toml   small description written LAST: its presence marks a complete cache,
#                  and it records which archive (SHA-256) and schema version produced it

const CACHE_FORMAT = "thermophysicaldb-cache"

cache_data_path(dir::AbstractString) = joinpath(dir, "dataset.jld2")
cache_meta_path(dir::AbstractString) = joinpath(dir, "dataset.toml")

function write_cache(dir::AbstractString, ds::Dataset, manifest::Manifest)
    mkpath(dir)
    data = cache_data_path(dir)
    part = data * ".part"
    # An old description must not vouch for data that is being replaced.
    rm(cache_meta_path(dir); force = true)
    try
        JLD2.jldopen(part, "w") do file
            write_dataset((key, value) -> (file[key] = value; nothing), ds)
        end
        mv(part, data; force = true)
    finally
        rm(part; force = true)
    end
    meta = Dict{String,Any}(
        "format" => CACHE_FORMAT,
        "schema_version" => SCHEMA_VERSION,
        "archive_sha256" => manifest.sha256,
        "archive_version" => manifest.version,
        "built_at" => utc_timestamp(),
        "measurements" => length(ds),
        "references" => length(ds.references),
        "compounds" => length(ds.compounds),
        "size_bytes" => Int(filesize(data)),
    )
    tmp = cache_meta_path(dir) * ".tmp"
    open(io -> TOML.print(io, meta), tmp, "w")
    mv(tmp, cache_meta_path(dir); force = true)
    return meta
end

"""
    read_cache(dir, manifest) -> Union{Dataset, Nothing}

The cached dataset if it was built from the archive described by `manifest` with the
current schema version, otherwise `nothing`. An unreadable cache gives a warning and
`nothing`, never an error: the caller just rebuilds.
"""
function read_cache(dir::AbstractString, manifest::Manifest)
    data, meta_path = cache_data_path(dir), cache_meta_path(dir)
    (isfile(data) && isfile(meta_path)) || return nothing
    meta = try
        TOML.parsefile(meta_path)
    catch
        return nothing
    end
    (
        get(meta, "format", "") == CACHE_FORMAT &&
        get(meta, "schema_version", -1) == SCHEMA_VERSION &&
        get(meta, "archive_sha256", "") == manifest.sha256
    ) || return nothing
    try
        return JLD2.jldopen(data, "r") do file
            restore_dataset(key -> file[key])
        end
    catch err
        err isa InterruptException && rethrow()
        @warn "The cached database could not be read and will be rebuilt" reason =
            sprint(showerror, err)
        return nothing
    end
end
