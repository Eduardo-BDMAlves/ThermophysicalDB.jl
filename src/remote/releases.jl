"""
    Release

One published version of the ThermoML archive.

# Fields

  - `version`: ISO date taken from the archive name, e.g. `"2020-09-30"`.
  - `archive_name`: file name of the `.tgz`.
  - `archive_url`: where the `.tgz` can be downloaded.
  - `sha256_url`: where its SHA-256 digest is published.
  - `sha256`: digest known in advance (built-in releases only), otherwise `nothing`.
"""
struct Release
    version::String
    archive_name::String
    archive_url::String
    sha256_url::String
    sha256::Union{Nothing,String}
end

"""
    NoReleaseError(attempts)

Thrown when none of the metadata endpoints yields a ThermoML archive release.
"""
struct NoReleaseError <: Exception
    attempts::Vector{String}
end

function Base.showerror(io::IO, err::NoReleaseError)
    print(io, "could not determine the latest ThermoML archive release:")
    for attempt in err.attempts
        print(io, "\n  - ", attempt)
    end
    return nothing
end

const NIST_ARCHIVE_BASE_URL = "https://data.nist.gov/od/ds/mds2-2422/"

# Endpoints of the NIST dataset record (DOI 10.18434/mds2-2422), tried in order.
const METADATA_URLS = (
    "https://data.nist.gov/od/id/ark:/88434/mds2-2422",
    "https://data.nist.gov/od/id/mds2-2422",
)

# Releases known when this version of the package was written, oldest first. They are the
# fallback when the NIST metadata cannot be reached.
const BUILTIN_RELEASES = (
    Release(
        "2020-09-30",
        "ThermoML.v2020-09-30.tgz",
        NIST_ARCHIVE_BASE_URL * "ThermoML.v2020-09-30.tgz",
        NIST_ARCHIVE_BASE_URL * "ThermoML.v2020-09-30.tgz.sha256",
        "231161b5e443dc1ae0e5da8429d86a88474cb722016e5b790817bb31c58d7ec2",
    ),
)

builtin_latest() = last(BUILTIN_RELEASES)

# Matches archive links such as https://.../ThermoML.v2020-09-30.tgz but not the
# neighbouring ".tgz.sha256" links (the digest URL is derived from the archive URL).
const RELEASE_URL_REGEX =
    r"https://[^\s\"'<>\\]*?/ThermoML\.v(\d{4}-\d{2}-\d{2})\.tgz(?![\w.])"

"""
    parse_releases(text) -> Vector{Release}

Find every ThermoML archive link in `text` (a JSON or HTML response; JSON-escaped slashes
are handled) and return one [`Release`](@ref) per version, oldest first. The metadata
schema is deliberately not parsed: only the archive naming convention is relied upon.
"""
function parse_releases(text::AbstractString)::Vector{Release}
    normalized = replace(text, "\\/" => "/")
    found = Dict{String,Release}()
    for m in eachmatch(RELEASE_URL_REGEX, normalized)
        version = String(m.captures[1])
        url = String(m.match)
        found[version] =
            Release(version, "ThermoML.v$(version).tgz", url, url * ".sha256", nothing)
    end
    return sort!(collect(values(found)); by = release -> release.version)
end

function http_get_text(url::AbstractString; timeout::Real = 10)::String
    io = IOBuffer()
    Downloads.download(url, io; headers = ["Accept" => "application/json"], timeout)
    return String(take!(io))
end

"""
    fetch_latest_release(; urls = METADATA_URLS, timeout = 10) -> Release

Ask NIST which ThermoML archive is the most recent. Every endpoint in `urls` is tried in
turn; throws [`NoReleaseError`](@ref) listing the failures if none works. The short
`timeout` (seconds) keeps the check from stalling when the machine is offline.
"""
function fetch_latest_release(;
    urls = METADATA_URLS,
    timeout::Real = 10,
    get_text = http_get_text,
)::Release
    attempts = String[]
    for url in urls
        try
            releases = parse_releases(get_text(url; timeout))
            isempty(releases) || return last(releases)
            push!(attempts, "$url: no archive link found in the response")
        catch err
            err isa InterruptException && rethrow()
            push!(attempts, "$url: " * sprint(showerror, err))
        end
    end
    throw(NoReleaseError(attempts))
end
