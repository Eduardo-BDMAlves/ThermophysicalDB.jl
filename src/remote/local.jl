# Installing an archive the user already has (downloaded in a browser, copied from a
# colleague, obtained behind a network that blocks scripted downloads). It goes through the
# same verification and bookkeeping as a download, so everything else works unchanged.

const ARCHIVE_NAME_REGEX = r"^ThermoML\.v(\d{4}-\d{2}-\d{2})\.tgz$"

function archive_version(name::AbstractString)
    m = match(ARCHIVE_NAME_REGEX, name)
    return m === nothing ? nothing : String(m.captures[1])
end

# Digest to verify a local file against, in order: given explicitly, the `.sha256` file
# kept next to it, or the digest of a release this package knows.
function local_expected_sha256(path::AbstractString, name::AbstractString, given)
    given !== nothing && return parse_sha256(given)
    sidecar = path * ".sha256"
    isfile(sidecar) && return parse_sha256(read(sidecar, String))
    i = findfirst(r -> r.archive_name == name && r.sha256 !== nothing, BUILTIN_RELEASES)
    i === nothing || return BUILTIN_RELEASES[i].sha256
    throw(
        ArgumentError(
            "no SHA-256 to verify \"$name\" against; pass `sha256 = \"...\"` or keep " *
            "the .sha256 file next to the archive",
        ),
    )
end

"""
    install_archive!(path; version = nothing, sha256 = nothing, dir = thermoml_dir(),
                     keep_old = false) -> Manifest

Install a ThermoML archive that is already on disk, e.g. one downloaded in a browser from
<https://data.nist.gov/od/id/mds2-2422>. The file is verified against its SHA-256 (taken
from `sha256`, else from `path * ".sha256"`, else from the releases this package knows),
copied into the data directory and recorded, exactly like a download. Afterwards
[`database`](@ref) uses it.

`version` (`"2020-09-30"`) is read from a file name such as `ThermoML.v2020-09-30.tgz`
when not given. A file whose digest does not match is rejected and nothing is installed.
"""
function install_archive!(
    path::AbstractString;
    version::Union{Nothing,AbstractString} = nothing,
    sha256::Union{Nothing,AbstractString} = nothing,
    dir::AbstractString = thermoml_dir(),
    keep_old::Bool = false,
)::Manifest
    isfile(path) || throw(ArgumentError("no such file: $path"))
    name = basename(path)
    ver = version === nothing ? archive_version(name) : String(version)
    ver === nothing && throw(
        ArgumentError(
            "cannot read the version from \"$name\"; pass `version = \"YYYY-MM-DD\"`",
        ),
    )
    expected = lowercase(local_expected_sha256(path, name, sha256))
    verify_sha256(path, expected)

    mkpath(dir)
    archive_name = "ThermoML.v$ver.tgz"
    final = joinpath(dir, archive_name)
    if abspath(path) != abspath(final)
        part = final * ".part"
        try
            cp(path, part; force = true)
            mv(part, final; force = true)
        finally
            rm(part; force = true)
        end
    end
    previous = read_manifest(dir)
    manifest = Manifest(
        MANIFEST_FORMAT,
        ver,
        archive_name,
        expected,
        "local file: " * abspath(path),
        utc_timestamp(),
        Int(filesize(final)),
    )
    write_manifest(dir, manifest)
    if !keep_old && previous !== nothing && previous.archive_name != archive_name
        rm(joinpath(dir, previous.archive_name); force = true)
    end
    forget_database!()
    @info "Installed ThermoML archive $ver from a local file" path = abspath(path)
    return manifest
end
