# Compares the results of `benchpkg` of two revisions and writes the Markdown of the comment of the
# pull request: for every benchmark the time and the memory that it allocates, the change of the
# second revision against the first, and a mark when the change is larger than the limit.
#
#     julia benchmark/compare.jl <directory with the results> <base revision> <head revision> \
#         [limit = 0.15] [base label] [head label]
#
# The files are the `results_<package>@<revision>.json` that `benchpkg --output-dir` writes. Time is
# the median of the samples (a runner of GitHub varies by some per cent, so only changes above the
# limit are marked); the allocated memory does not vary between runs. The Markdown goes to the
# standard output and, when `GITHUB_OUTPUT` is set, `regressions=<number>` is written to it.

using JSON3: JSON3
using Statistics: median
using Printf: @sprintf

const PACKAGE = "ThermophysicalDB"

# Every benchmark of a result file as `name => (; time, memory, allocs)`, the time in ns.
function load(directory, revision)
    file = joinpath(
        directory,
        string("results_", PACKAGE, "@", replace(revision, "/" => "_"), ".json"),
    )
    isfile(file) || error("results file not found: $file")
    data = open(file, "r") do io
        JSON3.read(io, Dict{String,Any})
    end
    found = Dict{String,NamedTuple}()
    flatten!(found, data, "")
    return found
end

function flatten!(found, node, prefix)
    if haskey(node, "times")
        times = Float64.(node["times"])
        found[prefix] = (;
            time = median(times),
            memory = Float64(get(node, "memory", NaN)),
            allocs = Float64(get(node, "allocs", NaN)),
        )
    elseif haskey(node, "data")
        for (key, value) in node["data"]
            flatten!(found, value, isempty(prefix) ? String(key) : string(prefix, "/", key))
        end
    end
    return found
end

function pretty_time(ns)
    isnan(ns) && return "n/a"
    ns < 1e3 && return @sprintf("%.3g ns", ns)
    ns < 1e6 && return @sprintf("%.3g μs", ns / 1e3)
    ns < 1e9 && return @sprintf("%.3g ms", ns / 1e6)
    return @sprintf("%.3g s", ns / 1e9)
end

function pretty_memory(bytes)
    isnan(bytes) && return "n/a"
    bytes < 1024 && return @sprintf("%.0f B", bytes)
    bytes < 1024^2 && return @sprintf("%.3g KiB", bytes / 1024)
    bytes < 1024^3 && return @sprintf("%.3g MiB", bytes / 1024^2)
    return @sprintf("%.3g GiB", bytes / 1024^3)
end

# The change as a ratio and a mark: ⚠️ slower or larger than the limit, ✅ faster or smaller.
function judge(base, head, limit)
    (isnan(base) || isnan(head) || base <= 0) && return (NaN, "")
    ratio = head / base
    mark = ratio > 1 + limit ? "⚠️" : ratio < 1 / (1 + limit) ? "✅" : ""
    return (ratio, mark)
end

format_ratio(ratio) = isnan(ratio) ? "" : @sprintf("%.2f", ratio)

function main(args)
    length(args) >= 3 ||
        error("usage: compare.jl <directory> <base revision> <head revision> [limit]")
    directory, base_rev, head_rev = args[1], args[2], args[3]
    limit = length(args) >= 4 ? parse(Float64, args[4]) : 0.15
    base_label = length(args) >= 5 ? args[5] : base_rev
    head_label = length(args) >= 6 ? args[6] : head_rev
    base, head = load(directory, base_rev), load(directory, head_rev)
    names = sort!(collect(union(keys(base), keys(head))))

    rows = String[]
    slower = larger = faster = smaller = 0
    for name in names
        b, h = get(base, name, nothing), get(head, name, nothing)
        if b === nothing || h === nothing
            where =
                b === nothing ? string("only in ", head_label) :
                string("only in ", base_label)
            push!(rows, string("| `", name, "` | | | | | | | ", where, " |"))
            continue
        end
        time_ratio, time_mark = judge(b.time, h.time, limit)
        memory_ratio, memory_mark = judge(b.memory, h.memory, limit)
        slower += time_mark == "⚠️"
        faster += time_mark == "✅"
        larger += memory_mark == "⚠️"
        smaller += memory_mark == "✅"
        push!(
            rows,
            string(
                "| `",
                name,
                "` | ",
                pretty_time(b.time),
                " | ",
                pretty_time(h.time),
                " | ",
                format_ratio(time_ratio),
                " ",
                time_mark,
                " | ",
                pretty_memory(b.memory),
                " | ",
                pretty_memory(h.memory),
                " | ",
                format_ratio(memory_ratio),
                " ",
                memory_mark,
                " | ",
                @sprintf("%.0f → %.0f", b.allocs, h.allocs),
                " |",
            ),
        )
    end

    percent = round(Int, 100 * limit)
    println("## Benchmark results")
    println()
    println(
        "Base: **",
        base_label,
        "**, this pull request: **",
        head_label,
        "**. Ratios are this pull request over the base; ⚠️ is more than ",
        percent,
        " % worse and ✅ more than ",
        percent,
        " % better.",
    )
    println()
    println("| | |")
    println("|---|---|")
    println("| Time | ", slower, " slower ⚠️, ", faster, " faster ✅ |")
    println("| Memory allocated | ", larger, " larger ⚠️, ", smaller, " smaller ✅ |")
    println()
    println("<details><summary>All benchmarks</summary>")
    println()
    println(
        "| Benchmark | Time (base) | Time (PR) | Time ratio | Memory (base) | Memory (PR) | Memory ratio | Allocations |",
    )
    println("|---|---:|---:|---:|---:|---:|---:|---:|")
    foreach(println, rows)
    println()
    println("</details>")

    output = get(ENV, "GITHUB_OUTPUT", "")
    isempty(output) || open(output, "a") do io
        println(io, "regressions=", slower + larger)
    end
    return nothing
end

main(ARGS)
