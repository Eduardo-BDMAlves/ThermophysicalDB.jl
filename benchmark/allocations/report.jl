# What the study writes: a table of everything measured (CSV), the report in Markdown, the
# fingerprints of the results and the comparison of the fingerprints with a saved run.

using Dates: Dates
using Printf: @sprintf

"What came out of one scenario."
struct Outcome
    scenario::AllocStudy.Scenario
    measurement::Union{Nothing,AllocStudy.Measurement}
    error::String                                  # why it was left out ("" when it ran)
    sites::Vector{AllocStudy.Site}
    jet::Union{Nothing,NamedTuple{(:reports, :text),Tuple{Int,String}}}
end

name_of(o::Outcome) = string(o.scenario.group, "/", o.scenario.name)

function bytes_text(b::Real)
    isfinite(b) || return "-"
    b < 1024 && return @sprintf("%.0f B", b)
    b < 1024^2 && return @sprintf("%.1f KiB", b / 1024)
    b < 1024^3 && return @sprintf("%.1f MiB", b / 1024^2)
    return @sprintf("%.2f GiB", b / 1024^3)
end

function time_text(s::Real)
    s < 1e-3 && return @sprintf("%.1f µs", s * 1e6)
    s < 1 && return @sprintf("%.2f ms", s * 1e3)
    return @sprintf("%.2f s", s)
end

ratio_text(x::Real) = isfinite(x) ? @sprintf("%.1f", x) : "-"

# ----------------------------------------------------------------------------------
# CSV
# ----------------------------------------------------------------------------------

csv_field(x) =
    occursin(r"[,\"\n]", string(x)) ? string('"', replace(string(x), "\"" => "\"\""), '"') :
    string(x)

function write_summary_csv(path, outcomes)
    open(path, "w") do io
        println(
            io,
            "scenario,status,seconds,bytes,allocations,gc_share,gc_after_seconds,output_bytes,items,",
            "bytes_per_item,amplification,fingerprint,stable,jet_reports,reason",
        )
        for o in outcomes
            m = o.measurement
            if m === nothing
                println(
                    io,
                    csv_field(name_of(o)),
                    ",left out,,,,,,,,,,,,,",
                    csv_field(o.error),
                )
                continue
            end
            per_item = m.items > 1 ? m.bytes / m.items : NaN
            amplification = m.output_bytes >= 1024 ? m.bytes / m.output_bytes : NaN
            println(
                io,
                join(
                    (
                        csv_field(name_of(o)),
                        "ok",
                        m.seconds,
                        m.bytes,
                        m.allocations,
                        m.gc_share,
                        m.gc_after,
                        m.output_bytes,
                        m.items,
                        per_item,
                        amplification,
                        m.fingerprint.hash,
                        m.stable,
                        o.jet === nothing ? "" : o.jet.reports,
                        "",
                    ),
                    ",",
                ),
            )
        end
    end
    return path
end

function write_sites_csv(path, outcomes)
    open(path, "w") do io
        println(io, "scenario,file,line,function,type,bytes,allocations")
        for o in outcomes, s in o.sites
            println(
                io,
                join(
                    (
                        csv_field(name_of(o)),
                        csv_field(s.file),
                        s.line,
                        csv_field(s.func),
                        csv_field(s.type),
                        round(Int, s.bytes),
                        round(Int, s.count),
                    ),
                    ",",
                ),
            )
        end
    end
    return path
end

# ----------------------------------------------------------------------------------
# Fingerprints
# ----------------------------------------------------------------------------------

function write_fingerprints(path, label, outcomes)
    open(path, "w") do io
        println(io, "# data\t", label)
        println(io, "# scenario\thash\titems\tfloats\ttotal\tweighted\tstable")
        for o in outcomes
            m = o.measurement
            m === nothing && continue
            f = m.fingerprint
            println(
                io,
                join(
                    (
                        name_of(o),
                        f.hash,
                        f.items,
                        f.floats,
                        repr(f.total),
                        repr(f.weighted),
                        m.stable,
                    ),
                    "\t",
                ),
            )
        end
    end
    return path
end

function read_fingerprints(path)
    label = ""
    table = Dict{
        String,
        NamedTuple{
            (:hash, :items, :floats, :total, :weighted, :stable),
            Tuple{String,Int,Int,Float64,Float64,Bool},
        },
    }()
    for line in eachline(path)
        if startswith(line, "# data\t")
            label = String(split(line, '\t')[2])
        elseif !startswith(line, "#") && !isempty(line)
            f = split(line, '\t')
            table[String(f[1])] = (
                hash = String(f[2]),
                items = parse(Int, f[3]),
                floats = parse(Int, f[4]),
                total = parse(Float64, f[5]),
                weighted = parse(Float64, f[6]),
                stable = parse(Bool, f[7]),
            )
        end
    end
    return label, table
end

"""
    compare_fingerprints(saved, outcomes) -> Vector{Pair{String,Symbol}}

For every scenario: `:same` (the result is identical bit by bit), `:rounding` (it differs but the
sums, plain and weighted by position, agree to 1e-12 and nothing else differs: a change in the last digits), `:changed` (the data are different), `:unstable`
(the result is not the same between two runs, so it cannot be compared), `:new` (not in the saved
run).
"""
function compare_fingerprints(saved, outcomes)
    states = Pair{String,Symbol}[]
    for o in outcomes
        m = o.measurement
        m === nothing && continue
        name = name_of(o)
        f = m.fingerprint
        old = get(saved, name, nothing)
        state = if old === nothing
            :new
        elseif !m.stable || !old.stable
            :unstable
        elseif f.hash == old.hash
            :same
        elseif f.items == old.items &&
               f.floats == old.floats &&
               f.floats > 0 &&
               isapprox(f.total, old.total; rtol = 1e-12, atol = 1e-300) &&
               isapprox(f.weighted, old.weighted; rtol = 1e-12, atol = 1e-300)
            :rounding
        else
            :changed
        end
        push!(states, name => state)
    end
    return states
end

# ----------------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------------

function machine_text()
    cpu = try
        first(Sys.cpu_info()).model
    catch
        string(Sys.CPU_NAME)
    end
    return string(
        "Julia ",
        VERSION,
        ", ",
        Sys.MACHINE,
        ", ",
        cpu,
        ", ",
        Threads.nthreads(),
        " thread(s), ",
        bytes_text(Sys.total_memory()),
        " of memory",
    )
end

function git_revision(root)
    try
        rev = readchomp(pipeline(`git -C $root rev-parse --short HEAD`; stderr = devnull))
        dirty =
            !isempty(
                readchomp(pipeline(`git -C $root status --porcelain`; stderr = devnull)),
            )
        return dirty ? string(rev, " (with uncommitted changes)") : rev
    catch
        return "unknown"
    end
end

function markdown_row(cells)
    return string("| ", join(cells, " | "), " |")
end

function write_report(path, outcomes; label, options, comparison = nothing, started)
    ran = filter(o -> o.measurement !== nothing, outcomes)
    left_out = filter(o -> o.measurement === nothing, outcomes)
    states = comparison === nothing ? Dict{String,Symbol}() : Dict(comparison)
    open(path, "w") do io
        println(io, "# Allocation study of ThermophysicalDB.jl\n")
        println(io, "- Data: ", label)
        println(io, "- Machine: ", machine_text())
        println(io, "- Package revision: ", git_revision(pkgdir(T)))
        println(
            io,
            "- Started: ",
            Dates.format(started, "yyyy-mm-dd HH:MM:SS"),
            " (local time)",
        )
        println(io, "- Options: ", options)
        println(
            io,
            "- Scenarios: ",
            length(ran),
            " measured, ",
            length(left_out),
            " left out\n",
        )
        println(
            io,
            "How to read it: *allocated* is every byte requested during one call (the smallest of ",
            "the runs; it does not vary between runs); *output* is the size of what the call ",
            "returns; *amplification* is allocated / output, so a value near 1 means that the call ",
            "allocates little more than its result and a large one means temporary memory that a ",
            "change of code may remove. *Per item* is the allocated bytes per point (or element) ",
            "returned. Both are left out (`-`) when the call returns a single value or less than 1 KiB.\n",
        )

        println(io, "## Everything measured, by allocated bytes\n")
        println(
            io,
            markdown_row((
                "scenario",
                "time",
                "allocated",
                "allocations",
                "GC (steady)",
                "collect after",
                "output",
                "amplification",
                "per item",
                "result",
            )),
        )
        println(
            io,
            markdown_row((
                "---",
                "---:",
                "---:",
                "---:",
                "---:",
                "---:",
                "---:",
                "---:",
                "---:",
                ":--",
            )),
        )
        for o in sort(ran; by = o -> -o.measurement.bytes)
            m = o.measurement
            gc = @sprintf("%.0f %%", 100 * m.gc_share)
            per_item = m.items > 1 ? bytes_text(m.bytes / m.items) : "-"
            amplification =
                m.output_bytes >= 1024 ? ratio_text(m.bytes / m.output_bytes) : "-"
            state = get(states, name_of(o), nothing)
            result = if state === nothing
                m.stable ? "stable" : "varies between runs"
            else
                string(state)
            end
            println(
                io,
                markdown_row((
                    name_of(o),
                    time_text(m.seconds),
                    bytes_text(m.bytes),
                    m.allocations,
                    gc,
                    time_text(m.gc_after),
                    bytes_text(m.output_bytes),
                    amplification,
                    per_item,
                    result,
                )),
            )
        end

        if comparison !== nothing
            println(io, "\n## Integrity of the results against the saved run\n")
            counts = Dict{Symbol,Int}()
            for (_, s) in comparison
                counts[s] = get(counts, s, 0) + 1
            end
            println(
                io,
                join(("`$k`: $v" for (k, v) in sort!(collect(counts); by = first)), ", "),
                "\n",
            )
            changed = [n for (n, s) in comparison if s === :changed]
            rounding = [n for (n, s) in comparison if s === :rounding]
            isempty(changed) || println(
                io,
                "**The data changed in:**\n",
                join(("- $n" for n in changed), "\n"),
                "\n",
            )
            isempty(rounding) || println(
                io,
                "Differ only in the last digits (the sums, plain and position-weighted, agree to 1e-12) in:\n",
                join(("- $n" for n in rounding), "\n"),
                "\n",
            )
        end

        sites = filter(o -> !isempty(o.sites), outcomes)
        if !isempty(sites)
            println(io, "\n## Where the allocations come from\n")
            println(
                io,
                "The lines of the package that allocate, summed over the scenarios that were ",
                "profiled (bytes are estimates for the scenarios that allocate hundreds of MiB, ",
                "where only a fraction of the allocations is recorded). The `scenarios` column is ",
                "how many scenarios pass through the line.\n",
            )
            total = Dict{Tuple{String,Int,String},Tuple{Float64,Float64,Set{String}}}()
            for o in sites, s in o.sites
                key = (s.file, s.line, s.func)
                b, c, names = get(total, key, (0.0, 0.0, Set{String}()))
                push!(names, name_of(o))
                total[key] = (b + s.bytes, c + s.count, names)
            end
            ranking = sort!(collect(total); by = p -> -p.second[1])
            println(
                io,
                markdown_row(("line", "function", "allocated", "allocations", "scenarios")),
            )
            println(io, markdown_row((":--", ":--", "---:", "---:", "---:")))
            for ((file, line, func), (b, c, names)) in first(ranking, 40)
                println(
                    io,
                    markdown_row((
                        string("`", file, ":", line, "`"),
                        string("`", func, "`"),
                        bytes_text(b),
                        round(Int, c),
                        length(names),
                    )),
                )
            end
            println(io, "\n### Scenario by scenario\n")
            for o in sort(sites; by = o -> -o.measurement.bytes)
                println(
                    io,
                    "**",
                    name_of(o),
                    "** (",
                    bytes_text(o.measurement.bytes),
                    ")\n",
                )
                println(
                    io,
                    markdown_row(("line", "function", "type", "allocated", "allocations")),
                )
                println(io, markdown_row((":--", ":--", ":--", "---:", "---:")))
                for s in first(o.sites, 6)
                    println(
                        io,
                        markdown_row((
                            string("`", s.file, ":", s.line, "`"),
                            string("`", s.func, "`"),
                            string("`", s.type, "`"),
                            bytes_text(s.bytes),
                            round(Int, s.count),
                        )),
                    )
                end
                println(io)
            end
        end

        jets = filter(o -> o.jet !== nothing, outcomes)
        if !isempty(jets)
            println(io, "\n## Type stability (JET, optimization analysis)\n")
            println(
                io,
                "Runtime dispatch and unresolved types found in the code of the package, by ",
                "scenario. The full text is in `jet.txt`.\n",
            )
            println(io, markdown_row(("scenario", "reports")))
            println(io, markdown_row((":--", "---:")))
            for o in sort(jets; by = o -> -o.jet.reports)
                println(io, markdown_row((name_of(o), o.jet.reports)))
            end
        end

        if !isempty(left_out)
            println(io, "\n## Left out\n")
            for o in left_out
                println(io, "- `", name_of(o), "`: ", first(split(o.error, '\n')))
            end
        end
    end
    return path
end

function write_jet(path, outcomes)
    open(path, "w") do io
        for o in outcomes
            o.jet === nothing && continue
            println(io, "="^80)
            println(io, name_of(o), ": ", o.jet.reports, " report(s)")
            println(io, "="^80)
            println(io, o.jet.text)
        end
    end
    return path
end
