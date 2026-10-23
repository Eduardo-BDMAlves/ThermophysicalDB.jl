const MANIFEST_FORMAT = 1
const MANIFEST_FILENAME = "manifest.toml"

"""
    Manifest

Record of the archive installed in the local cache, stored as `manifest.toml` next to it.
It is written last, so a manifest on disk always describes a verified, complete archive.
"""
struct Manifest
    format::Int
    version::String
    archive_name::String
    sha256::String
    source_url::String
    retrieved_at::String
    size_bytes::Int
end

function Base.:(==)(a::Manifest, b::Manifest)
    return a.format == b.format &&
           a.version == b.version &&
           a.archive_name == b.archive_name &&
           a.sha256 == b.sha256 &&
           a.source_url == b.source_url &&
           a.retrieved_at == b.retrieved_at &&
           a.size_bytes == b.size_bytes
end

manifest_path(dir::AbstractString) = joinpath(dir, MANIFEST_FILENAME)

"""
    archive_path(manifest; dir = thermoml_dir()) -> String

Absolute path of the archive described by `manifest`.
"""
archive_path(manifest::Manifest; dir::AbstractString = thermoml_dir()) =
    joinpath(dir, manifest.archive_name)

utc_timestamp() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

function write_manifest(dir::AbstractString, manifest::Manifest)
    path = manifest_path(dir)
    tmp = path * ".tmp"
    data = Dict{String,Any}(
        "format" => manifest.format,
        "version" => manifest.version,
        "archive_name" => manifest.archive_name,
        "sha256" => manifest.sha256,
        "source_url" => manifest.source_url,
        "retrieved_at" => manifest.retrieved_at,
        "size_bytes" => manifest.size_bytes,
    )
    open(io -> TOML.print(io, data; sorted = true), tmp, "w")
    mv(tmp, path; force = true)
    return path
end

"""
    read_manifest(dir) -> Union{Nothing,Manifest}

Read the manifest stored in `dir`. Returns `nothing` when it is absent, unreadable, of an
unknown format, or names an archive outside `dir`.
"""
function read_manifest(dir::AbstractString)::Union{Nothing,Manifest}
    path = manifest_path(dir)
    isfile(path) || return nothing
    parsed = TOML.tryparsefile(path)
    if parsed isa TOML.ParserError
        @warn "Ignoring unreadable manifest" path
        return nothing
    end
    try
        get(parsed, "format", nothing) == MANIFEST_FORMAT || return nothing
        name = parsed["archive_name"]
        name == basename(name) || return nothing
        return Manifest(
            MANIFEST_FORMAT,
            parsed["version"],
            name,
            parsed["sha256"],
            parsed["source_url"],
            parsed["retrieved_at"],
            Int(parsed["size_bytes"]),
        )
    catch err
        err isa InterruptException && rethrow()
        @warn "Ignoring malformed manifest" path
        return nothing
    end
end
