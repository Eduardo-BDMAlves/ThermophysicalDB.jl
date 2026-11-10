# A table in Markdown with what stays in memory after loading the synthetic database, for several
# revisions of the package side by side, the first one being the base of the comparison:
#
#     julia benchmark/memory_report.jl base=/path/to/base head=/path/to/head
#
# Every argument is `label=path of a checkout of the package`. The size of the database comes from
# `TDB_BENCH_SCALE` and its stored file from `TDB_BENCH_CACHE` (see `data.jl`).

using Pkg: Pkg
using TOML: TOML
using Printf: @sprintf

const WORKER = joinpath(@__DIR__, "memory.jl")

# One revision: an environment of its own with the package, the worker in a fresh process.
function measure(label::AbstractString, checkout::AbstractString)
    try
        return measure_unchecked(checkout)
    catch err
        err isa InterruptException && rethrow()
        @warn "The memory of this revision could not be measured" label reason =
            sprint(showerror, err)
        return unavailable()
    end
end

# What the report shows for a revision that could not be measured.
function unavailable()
    keys_ = (
        "points",
        "file_bytes",
        "database_open_bytes",
        "dataset_loaded_bytes",
        "dataset_all_bytes",
        "bytes_per_point",
        "rss_open_bytes",
        "rss_loaded_bytes",
        "rss_all_bytes",
        "rss_peak_bytes",
    )
    return Dict{String,Any}(
        "summary" => Dict{String,Any}(k => NaN for k in keys_),
        "tables" => Dict{String,Any}(),
    )
end

function measure_unchecked(checkout::AbstractString)
    env = mktempdir()
    output = joinpath(env, "memory.toml")
    old = Base.active_project()
    try
        Pkg.activate(env; io = devnull)
        Pkg.develop(; path = checkout, io = devnull)
        Pkg.add(["SHA", "Random", "TOML"]; io = devnull)
        Pkg.instantiate(; io = devnull)
    finally
        Pkg.activate(old; io = devnull)
    end
    run(`$(Base.julia_cmd()) --project=$env $WORKER $output`)
    return TOML.parsefile(output)
end

function megabytes(x)
    return isnan(x) ? "n/a" : @sprintf("%.1f MB", x / 1e6)
end

function change(base, other)
    (isnan(base) || base == 0) && return ""
    return @sprintf(" (%+.1f %%)", 100 * (other / base - 1))
end

# A row: the name, the value of every revision and the change of the others against the first.
function row(name, values, format)
    cells = [format(values[1])]
    for v in values[2:end]
        push!(cells, format(v) * change(values[1], v))
    end
    return string("| ", name, " | ", join(cells, " | "), " |")
end

function report(labels, results)
    out = String[]
    header = string("| | ", join(labels, " | "), " |")
    rule = string("|---|", join(fill("---:", length(labels)), "|"), "|")
    summary_rows = (
        ("Points", "points", x -> isnan(x) ? "n/a" : string(round(Int, x))),
        ("File on disk", "file_bytes", megabytes),
        ("Database open (registry only)", "database_open_bytes", megabytes),
        ("Dataset right after loading", "dataset_loaded_bytes", megabytes),
        ("Dataset with every table read", "dataset_all_bytes", megabytes),
        (
            "Bytes per point (everything read)",
            "bytes_per_point",
            x -> isnan(x) ? "n/a" : @sprintf("%.0f B", x),
        ),
        ("Process, database open", "rss_open_bytes", megabytes),
        ("Process, dataset loaded", "rss_loaded_bytes", megabytes),
        ("Process, every table read", "rss_all_bytes", megabytes),
        ("Process, peak", "rss_peak_bytes", megabytes),
    )
    push!(out, "### Memory that stays after loading the database", "", header, rule)
    for (name, key, format) in summary_rows
        values = [Float64(r["summary"][key]) for r in results]
        push!(out, row(name, values, format))
    end
    names = sort(unique(vcat((collect(keys(r["tables"])) for r in results)...)))
    push!(
        out,
        "",
        "<details><summary>Size of every table (<code>Base.summarysize</code>)</summary>",
        "",
    )
    push!(out, header, rule)
    for name in names
        values = [Float64(get(r["tables"], name, NaN)) for r in results]
        push!(out, row(name, values, megabytes))
    end
    push!(out, "", "</details>", "")
    return join(out, "\n")
end

function main(args)
    isempty(args) &&
        error("give at least one label=path, e.g. base=/path/base head=/path/head")
    labels = String[]
    results = Dict{String,Any}[]
    for arg in args
        label, path = split(arg, '='; limit = 2)
        push!(labels, label)
        push!(results, measure(label, abspath(path)))
    end
    println(report(labels, results))
    return nothing
end

main(ARGS)
