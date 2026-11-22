# Downloading with retries and fallbacks.
#
# NIST serves the archive through a redirect to a different backend, and some networks,
# proxies and servers refuse Julia's bundled libcurl there. Instead of failing on the first
# error, each attempt tries several independent ways of fetching the file, and the whole
# thing is repeated (with a pause) before giving up with an explanation of what to do.

const DOWNLOAD_USER_AGENT = "Mozilla/5.0 (compatible; ThermophysicalDB.jl; +https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl)"

"One way of fetching a file: `run(url, dest; progress, timeout)`, usable when `available()`."
struct DownloadStrategy
    name::String
    available::Function
    run::Function
end

"""
Raised when every attempt to download `url` failed. `failures` lists each failed try; the
message printed to the user says what can be done about it.
"""
struct DownloadError <: Exception
    url::String
    failures::Vector{String}
    help::Vector{String}
end

# The default advice is about the NIST archive; other downloads pass their own.
DownloadError(url, failures) = DownloadError(url, failures, String[])

function Base.showerror(io::IO, err::DownloadError)
    println(io, "DownloadError: could not download ", err.url)
    println(io, "Every attempt failed:")
    for failure in err.failures
        println(io, "  - ", failure)
    end
    println(io, "What you can do:")
    println(io, "  1. Check your internet connection, VPN or proxy (use the HTTPS_PROXY")
    println(io, "     environment variable if your network requires a proxy).")
    if isempty(err.help)
        println(
            io,
            "  2. Download the file in a browser from https://data.nist.gov/od/id/mds2-2422",
        )
        println(io, "     (ThermoML.vYYYY-MM-DD.tgz) and install it with")
        println(
            io,
            "     install_archive!(\"path/to/ThermoML.vYYYY-MM-DD.tgz\"), then call database().",
        )
    else
        foreach(line -> println(io, line), err.help)
    end
    print(
        io,
        isempty(err.help) ?
        "  3. Try again later: the NIST servers sometimes refuse requests temporarily." :
        "  3. Try again later: the server sometimes refuses requests temporarily.",
    )
    return nothing
end

# --- the individual ways of downloading -------------------------------------------------

function download_default(url, dest; progress, timeout)
    if progress
        Downloads.download(url, dest; timeout, progress = progress_printer(basename(dest)))
    else
        Downloads.download(url, dest; timeout)
    end
    return dest
end

# Some servers answer scripted clients differently from browsers.
function download_with_user_agent(url, dest; progress, timeout)
    headers = ["User-Agent" => DOWNLOAD_USER_AGENT]
    if progress
        Downloads.download(
            url,
            dest;
            headers,
            timeout,
            progress = progress_printer(basename(dest)),
        )
    else
        Downloads.download(url, dest; headers, timeout)
    end
    return dest
end

curl_executable() = Sys.which("curl")

# Seconds without any data after which `curl` gives up on a transfer. Julia's Downloads stops a
# stalled transfer by itself after 20 seconds, but `curl` waits for ever unless it is told.
const CURL_STALL_SECONDS = 30

# Arguments of `curl` for one download: a transfer that stalls is cancelled after
# `CURL_STALL_SECONDS` (less than 1 byte per second), and one that is still going after
# `timeout` seconds (when finite) is cancelled too. With `resume`, a file that is already
# there is continued from where it stopped (`-C -`) instead of fetched again.
function curl_arguments(; progress::Bool, timeout::Real, resume::Bool = false)
    args = [
        "-L",
        "--fail",
        "--http1.1",
        "--connect-timeout",
        "30",
        "--speed-limit",
        "1",
        "--speed-time",
        string(CURL_STALL_SECONDS),
        "-A",
        DOWNLOAD_USER_AGENT,
    ]
    append!(args, progress ? ["-#"] : ["-s", "-S"])
    resume && append!(args, ["-C", "-"])
    isfinite(timeout) && append!(args, ["--max-time", string(ceil(Int, timeout))])
    return args
end

# What `curl` received is kept in a file of its own (`curl_partial_path`), not in `dest`, so
# that the next try, in this call or in a later one, continues from there. That matters for
# an archive of about 190 MB behind a server that now and then stops sending: every try adds
# to what is already there. The file is moved to `dest` only when the transfer is complete,
# and removed when the server cannot continue it. The caller checks the digest of the
# archive, so a continued file that is not the published one is never installed.
const CURL_PARTIAL_SUFFIX = ".curl-part"

curl_partial_path(dest::AbstractString) = string(dest, CURL_PARTIAL_SUFFIX)

# `curl` exits with 33 when the server does not accept a range request, with 36 when the
# bytes it has do not fit the file of the server and with 22 when the server refuses the
# range (HTTP 416): the file that was there is of no use then.
function unusable_partial(err)
    err isa ProcessFailedException || return false
    return any(proc -> proc.exitcode in (22, 33, 36), err.procs)
end

# The operating system's curl has its own TLS stack, proxy settings and certificate store
# (Schannel on Windows), which is what a browser-like environment relies on.
function download_with_curl(url, dest; progress, timeout)
    exe = curl_executable()
    exe === nothing && error("curl was not found on this system")
    partial = curl_partial_path(dest)
    args = curl_arguments(; progress, timeout, resume = true)
    try
        run(Cmd([exe; args; "-o"; partial; url]))
    catch err
        unusable_partial(err) && rm(partial; force = true)
        rethrow()
    end
    mv(partial, dest; force = true)
    return dest
end

const DOWNLOAD_STRATEGIES = [
    DownloadStrategy("Julia Downloads", () -> true, download_default),
    DownloadStrategy(
        "Julia Downloads with a browser-style User-Agent",
        () -> true,
        download_with_user_agent,
    ),
    DownloadStrategy(
        "system curl",
        () -> curl_executable() !== nothing,
        download_with_curl,
    ),
]

# First line of an error, shortened, for the list of failures.
function brief_error(err)
    text = first(split(sprint(showerror, err), '\n'))
    return length(text) > 220 ? first(text, 219) * "…" : text
end

const DOWNLOAD_TIMEOUT_ENV = "THERMOPHYSICALDB_DOWNLOAD_TIMEOUT"

"""
    default_download_timeout() -> Float64

Seconds that one attempt of [`download_file`](@ref) may last: the number in the environment
variable `THERMOPHYSICALDB_DOWNLOAD_TIMEOUT`, or `Inf` (no limit) when it is not set. A value
that is not a positive number is ignored, with a warning.
"""
function default_download_timeout()::Float64
    text = strip(get(ENV, DOWNLOAD_TIMEOUT_ENV, ""))
    isempty(text) && return Inf
    seconds = tryparse(Float64, text)
    if seconds === nothing || !(seconds > 0)
        @warn "Ignoring $DOWNLOAD_TIMEOUT_ENV: it must be a positive number of seconds" value =
            text
        return Inf
    end
    return seconds
end

"""
    download_file(url, dest; progress = true, timeout = default_download_timeout(),
                  attempts = 4) -> String

Download `url` into `dest`. Each of up to `attempts` rounds tries, in order, Julia's
Downloads, Downloads with a browser-style User-Agent, and the system `curl` when it exists;
the first that works wins. Between rounds it waits 2, 5 and 10 seconds and says why it is
retrying. When everything fails it throws a [`DownloadError`](@ref) that lists every
failure and what the user can do. A partial file is never left at `dest`.

What the system `curl` had received when a try failed is kept next to `dest`
(`dest.curl-part`), and the next try of `curl` continues from there: a server that stops
sending now and then lets the download move forward, a few megabytes at a time, instead of
starting again from zero. A later call for the same `dest` continues too; the file is moved
into place when the transfer is complete and removed when the server cannot continue it.

A transfer that receives no data is cancelled (after 20 seconds by Julia's Downloads, after
30 by `curl`), so a server that accepts the connection and then stops sending cannot hold the
download for ever. `timeout` (seconds, for each try) also limits a transfer that keeps going
slowly; by default there is no such limit, or the number of seconds in the environment
variable `THERMOPHYSICALDB_DOWNLOAD_TIMEOUT`.
"""
function download_file(
    url::AbstractString,
    dest::AbstractString;
    progress::Bool = true,
    timeout::Real = default_download_timeout(),
    attempts::Integer = 4,
    strategies::AbstractVector{DownloadStrategy} = DOWNLOAD_STRATEGIES,
    pause = sleep,
    delays = (2, 5, 10),
)
    failures = String[]
    for attempt = 1:attempts
        for strategy in strategies
            strategy.available() || continue
            try
                rm(dest; force = true)
                strategy.run(url, dest; progress, timeout)
                return String(dest)
            catch err
                err isa InterruptException && rethrow()
                rm(dest; force = true)
                push!(failures, "attempt $attempt, $(strategy.name): $(brief_error(err))")
            end
        end
        if attempt < attempts
            wait_seconds = delays[min(attempt, length(delays))]
            @warn(
                "Download attempt $attempt of $attempts failed; retrying in $wait_seconds s",
                url,
                last_error = isempty(failures) ? "" : failures[end],
            )
            pause(wait_seconds)
        end
    end
    throw(DownloadError(String(url), failures))
end
