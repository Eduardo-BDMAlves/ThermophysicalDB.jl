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
end

function Base.showerror(io::IO, err::DownloadError)
    println(io, "DownloadError: could not download ", err.url)
    println(io, "Every attempt failed:")
    for failure in err.failures
        println(io, "  - ", failure)
    end
    println(io, "What you can do:")
    println(io, "  1. Check your internet connection, VPN or proxy (use the HTTPS_PROXY")
    println(io, "     environment variable if your network requires a proxy).")
    println(
        io,
        "  2. Download the file in a browser from https://data.nist.gov/od/id/mds2-2422",
    )
    println(io, "     (ThermoML.vYYYY-MM-DD.tgz) and install it with")
    println(
        io,
        "     install_archive!(\"path/to/ThermoML.vYYYY-MM-DD.tgz\"), then call database().",
    )
    print(
        io,
        "  3. Try again later: the NIST servers sometimes refuse requests temporarily.",
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

# The operating system's curl has its own TLS stack, proxy settings and certificate store
# (Schannel on Windows), which is what a browser-like environment relies on.
function download_with_curl(url, dest; progress, timeout)
    exe = curl_executable()
    exe === nothing && error("curl was not found on this system")
    args =
        ["-L", "--fail", "--http1.1", "--connect-timeout", "30", "-A", DOWNLOAD_USER_AGENT]
    append!(args, progress ? ["-#"] : ["-s", "-S"])
    isfinite(timeout) && append!(args, ["--max-time", string(ceil(Int, timeout))])
    run(Cmd([exe; args; "-o"; dest; url]))
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

"""
    download_file(url, dest; progress = true, timeout = Inf, attempts = 4) -> String

Download `url` into `dest`. Each of up to `attempts` rounds tries, in order, Julia's
Downloads, Downloads with a browser-style User-Agent, and the system `curl` when it exists;
the first that works wins. Between rounds it waits 2, 5 and 10 seconds and says why it is
retrying. When everything fails it throws a [`DownloadError`](@ref) that lists every
failure and what the user can do. A partial file is never left at `dest`.
"""
function download_file(
    url::AbstractString,
    dest::AbstractString;
    progress::Bool = true,
    timeout::Real = Inf,
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
