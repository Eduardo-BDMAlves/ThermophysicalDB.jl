const MIN_PROGRESS_BYTES = 1_048_576  # do not report progress for tiny files

function progress_printer(label::AbstractString)
    last_bucket = Ref(-1)
    return function (total::Integer, now::Integer)
        total < MIN_PROGRESS_BYTES && return nothing
        bucket = div(div(100 * now, total), 10)
        if bucket != last_bucket[]
            last_bucket[] = bucket
            @info "Downloading $label: $(10 * bucket)%"
        end
        return nothing
    end
end

"""
    download_file(url, dest; progress = true, timeout = Inf) -> String

Download `url` into `dest` with Downloads.jl. With `progress = true`, a message is logged
every 10 % for files larger than 1 MiB.
"""
function download_file(
    url::AbstractString,
    dest::AbstractString;
    progress::Bool = true,
    timeout::Real = Inf,
)
    if progress
        Downloads.download(url, dest; timeout, progress = progress_printer(basename(dest)))
    else
        Downloads.download(url, dest; timeout)
    end
    return dest
end

# Digest of the archive to install: the one NIST publishes next to it. Built-in releases
# carry a copy, used when the digest file cannot be fetched.
function resolve_sha256(release::Release, download)::String
    tmp = tempname()
    try
        download(release.sha256_url, tmp)
        published = parse_sha256(read(tmp, String))
        if release.sha256 !== nothing && published != release.sha256
            @warn "Published SHA-256 differs from the built-in one; using it" version =
                release.version
        end
        return published
    catch err
        err isa InterruptException && rethrow()
        release.sha256 === nothing && rethrow()
        @warn "Could not fetch the SHA-256 digest; using the built-in value" version =
            release.version
        return release.sha256
    finally
        rm(tmp; force = true)
    end
end

"""
    install_release(release; dir = thermoml_dir(), download = download_file,
                    keep_old = false) -> Manifest

Download `release` into `dir`, verify its SHA-256 digest and record it in the manifest.
The archive is first written to a `.part` file and only moved into place after the digest
matches, and the manifest is written last, so an interrupted or corrupted download never
looks like a valid installation. Archives of other versions are deleted afterwards unless
`keep_old = true`.

`download(url, dest)` can be replaced, e.g. in tests.
"""
function install_release(
    release::Release;
    dir::AbstractString = thermoml_dir(),
    download = download_file,
    keep_old::Bool = false,
)::Manifest
    mkpath(dir)
    expected = resolve_sha256(release, download)
    final = joinpath(dir, release.archive_name)
    part = final * ".part"
    @info "Downloading ThermoML archive $(release.version) from NIST"
    try
        download(release.archive_url, part)
        verify_sha256(part, expected)
        mv(part, final; force = true)
    finally
        rm(part; force = true)
    end
    previous = read_manifest(dir)
    manifest = Manifest(
        MANIFEST_FORMAT,
        release.version,
        release.archive_name,
        expected,
        release.archive_url,
        utc_timestamp(),
        Int(filesize(final)),
    )
    write_manifest(dir, manifest)
    if !keep_old && previous !== nothing && previous.archive_name != manifest.archive_name
        rm(joinpath(dir, previous.archive_name); force = true)
    end
    return manifest
end

# The manifest, provided the archive it describes is really there.
function installed_manifest(dir::AbstractString)::Union{Nothing,Manifest}
    manifest = read_manifest(dir)
    manifest === nothing && return nothing
    path = joinpath(dir, manifest.archive_name)
    if !isfile(path) || filesize(path) != manifest.size_bytes
        @warn "Manifest and archive on disk disagree; ignoring the local copy" path
        return nothing
    end
    return manifest
end

"""
    UpdateStatus

Result of [`check_update`](@ref).

# Fields

  - `state`: `:not_installed`, `:up_to_date`, `:update_available` or `:unknown` (the
    remote could not be queried and nothing newer is known).
  - `installed`: the local [`Manifest`](@ref), or `nothing`.
  - `latest`: the most recent [`Release`](@ref) known.
  - `source`: `:remote` if `latest` came from NIST, `:builtin` if NIST was unreachable.
  - `reason`: why NIST could not be queried (empty when `source == :remote`).
"""
struct UpdateStatus
    state::Symbol
    installed::Union{Nothing,Manifest}
    latest::Release
    source::Symbol
    reason::String
end

"""
    check_update(; dir = thermoml_dir()) -> UpdateStatus

Compare the local archive with the latest one published by NIST. Never throws because of
network problems: when NIST cannot be reached the built-in release list is used and
`source` is `:builtin`.
"""
function check_update(; dir::AbstractString = thermoml_dir(), fetch = fetch_latest_release)
    installed = installed_manifest(dir)
    latest, source, reason = try
        fetch(), :remote, ""
    catch err
        err isa InterruptException && rethrow()
        builtin_latest(), :builtin, sprint(showerror, err)
    end
    state = if installed === nothing
        :not_installed
    elseif latest.version > installed.version
        :update_available
    elseif source === :remote
        :up_to_date
    else
        :unknown
    end
    return UpdateStatus(state, installed, latest, source, reason)
end

"""
    ensure_archive(; update = :notify, dir = thermoml_dir()) -> Manifest

Make sure a verified ThermoML archive is available locally and return its manifest (see
[`archive_path`](@ref) for the file). If nothing is installed, the latest archive is
downloaded. Otherwise `update` decides what happens when NIST has a newer one:

  - `:notify` (default): keep using the local archive and log a warning;
  - `:install`: download and switch to the newer archive;
  - `:never`: do not even contact NIST.
"""
function ensure_archive(;
    update::Symbol = :notify,
    dir::AbstractString = thermoml_dir(),
    fetch = fetch_latest_release,
    download = download_file,
)::Manifest
    update in (:notify, :install, :never) ||
        throw(ArgumentError("`update` must be :notify, :install or :never, got :$update"))
    installed = installed_manifest(dir)
    update === :never && installed !== nothing && return installed
    status = check_update(; dir, fetch)
    if status.state === :not_installed
        return install_release(status.latest; dir, download)
    elseif status.state === :update_available
        update === :install && return install_release(status.latest; dir, download)
        installed_version = status.installed.version
        latest_version = status.latest.version
        @warn(
            "Newer ThermoML archive available; run `update_database!()`",
            installed_version,
            latest_version,
        )
    elseif status.state === :unknown
        @debug "Could not check for ThermoML updates" reason = status.reason
    end
    return installed::Manifest
end

"""
    update_database!(; dir = thermoml_dir()) -> Manifest

Install the latest ThermoML archive if the local one is missing or outdated; otherwise
leave things as they are. Returns the manifest of the archive in use.
"""
function update_database!(;
    dir::AbstractString = thermoml_dir(),
    fetch = fetch_latest_release,
    download = download_file,
)::Manifest
    status = check_update(; dir, fetch)
    if status.state === :not_installed || status.state === :update_available
        return install_release(status.latest; dir, download)
    end
    if status.state === :up_to_date
        @info "ThermoML archive is up to date" version = status.installed.version
    else
        @info "Could not reach NIST; keeping the local archive" reason = status.reason
    end
    return status.installed::Manifest
end
