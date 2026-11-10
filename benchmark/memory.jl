# What stays in memory after a database is loaded, for one revision of the package: the worker of
# `memory_report.jl`. Run it in a process of its own, so that the resident memory is the one of this
# revision alone:
#
#     julia --project=<environment with the package> benchmark/memory.jl <output.toml>
#
# BenchmarkTools measures what a call allocates; this measures what remains, table by table
# (`Base.summarysize`), and the resident memory of the whole process (Linux only; it includes
# Julia and the package, which are the same for the revisions that are compared, and memory that Julia
# keeps after freeing it, so the sizes of the tables are the number to look at).

using TOML: TOML
using ThermophysicalDB: ThermophysicalDB

include(joinpath(@__DIR__, "data.jl"))

const T = ThermophysicalDB

# The resident memory of this process in bytes, `NaN` when the system does not say.
function resident_bytes()
    file = "/proc/self/statm"
    isfile(file) || return NaN
    pages = parse(Int, split(read(file, String))[2])
    return Float64(pages * 4096)
end

function settle!()
    GC.gc()
    GC.gc()
    return nothing
end

function main(output::AbstractString)
    prepared = prepared_database(T)
    path = prepared.path
    settle!()

    db = T.Database([T.Member(BENCH_MEMBER; kind = :user, path)])
    member = only(T.members(db))
    settle!()
    after_open = resident_bytes()
    size_open = Base.summarysize(db)

    ds = T.member_dataset(member)
    settle!()
    after_load = resident_bytes()
    size_load = Base.summarysize(ds)

    # The tables that are read only when something asks for them.
    if isdefined(T, :load_lazy!) && isdefined(T, :LAZY_FIELDS)
        for name in T.LAZY_FIELDS
            T.load_lazy!(ds, name)
        end
    end
    settle!()
    after_all = resident_bytes()
    size_all = Base.summarysize(ds)

    tables = Dict{String,Int}()
    for name in fieldnames(typeof(ds))
        name === :lazy && continue
        tables[String(name)] = Base.summarysize(getfield(ds, name))
    end

    points = length(ds.measurements)
    summary = Dict{String,Any}(
        "points" => points,
        "file_bytes" => filesize(path),
        "database_open_bytes" => size_open,
        "dataset_loaded_bytes" => size_load,
        "dataset_all_bytes" => size_all,
        "bytes_per_point" => size_all / max(points, 1),
        "rss_open_bytes" => after_open,
        "rss_loaded_bytes" => after_load,
        "rss_all_bytes" => after_all,
        "rss_peak_bytes" => Float64(Sys.maxrss()),
        "julia" => string(VERSION),
        "scale" => string(bench_scale()),
    )
    open(output, "w") do io
        TOML.print(io, Dict("summary" => summary, "tables" => tables))
    end
    return nothing
end

main(isempty(ARGS) ? "memory.toml" : ARGS[1])
