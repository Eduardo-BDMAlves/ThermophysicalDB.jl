# The synthetic database on disk, shared by the suite and by the report of retained memory.
#
# Building 200 thousand points takes some seconds and the file does not change while the schema does
# not, so the file is kept in a cache directory (`TDB_BENCH_CACHE`, which the workflow stores between
# runs). The name of its folder is a hash of what decides its content: the files of the schema, the
# file that writes the cache and the generator. Every revision that is measured therefore finds
# its own file: a revision with another structure builds a new one and never reads a file that was
# written by a different structure.

include(joinpath(@__DIR__, "synthetic.jl"))

using SHA: SHA
using .Synthetic: Synthetic

const BENCH_MEMBER = "bench"

"""
    data_key(package, scale) -> String

Name of the folder of the data of this revision of `package` at this `scale`.
"""
function data_key(package::Module, scale::Symbol)
    root = pkgdir(package)
    files = String[]
    schema = joinpath(root, "src", "schema")
    isdir(schema) &&
        append!(files, sort!(filter(endswith(".jl"), readdir(schema; join = true))))
    for file in
        (joinpath(root, "src", "store", "serialize.jl"), joinpath(@__DIR__, "synthetic.jl"))
        isfile(file) && push!(files, file)
    end
    digest = bytes2hex(SHA.sha1(reduce(vcat, read.(files))))
    return string(digest[1:12], "-", scale, "-julia", VERSION.major, ".", VERSION.minor)
end

cache_directory() = get(ENV, "TDB_BENCH_CACHE", joinpath(tempdir(), "tdb-bench-cache"))

"""
    bench_scale() -> Symbol

The size of the database: `small`, `medium` (default) or `full`, from `TDB_BENCH_SCALE`.
"""
function bench_scale()
    scale = Symbol(get(ENV, "TDB_BENCH_SCALE", "medium"))
    haskey(Synthetic.SCALES, scale) || error(
        "TDB_BENCH_SCALE must be one of $(join(keys(Synthetic.SCALES), ", ")), got $scale",
    )
    return scale
end

"""
    prepared_database(package; scale = bench_scale()) -> NamedTuple

The path of the synthetic database of this revision, built when it is not in the cache. Returns
`(; path, built, seconds)`; `seconds` is the time to build it (zero when it was in the cache).
"""
function prepared_database(package::Module; scale::Symbol = bench_scale())
    dir = joinpath(cache_directory(), data_key(package, scale))
    path = joinpath(dir, BENCH_MEMBER, "dataset.jld2")
    isfile(path) && return (; path, built = false, seconds = 0.0)
    rm(dir; recursive = true, force = true)
    mkpath(dir)
    seconds = @elapsed Synthetic.build(dir; scale, name = BENCH_MEMBER)
    return (; path, built = true, seconds)
end
