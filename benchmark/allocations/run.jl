# The study of allocations of ThermophysicalDB.jl: how much memory every feature allocates, where,
# and whether the results are still the same after a change.
#
#     julia --project=benchmark/allocations benchmark/allocations/run.jl [option=value ...]
#
# Options (all optional):
#   data=synthetic|real   the synthetic database of the benchmarks (default) or the archive that is
#                         installed on this computer (`database()`; the real numbers)
#   scale=small|medium|full
#                         the size of the synthetic database (default small)
#   pressure=SECONDS      seconds of calls for the share of time in the garbage collector (default 2)
#   only=REGEX            only the scenarios whose name ("group/name") matches
#   lines=true|false      allocation sites by line of the package with Profile.Allocs (default true)
#   jet=true|false        optimization analysis of JET: runtime dispatch (default false)
#   repeats=N             measured runs per scenario (default: the one of the scenario)
#   save=FILE             write the fingerprints of the results here (default: in the output folder)
#   check=FILE            compare the fingerprints with the ones saved before and report any
#                         difference; the exit status is 1 when a result changed
#   out=FOLDER            where the files go (default benchmark/results/allocations/<data>-<time>)
#   list=true             only list the scenarios
#
# The first time, `julia --project=benchmark/allocations -e 'using Pkg; Pkg.instantiate()'`.
# To prove that a change did not change the data: run once before the change with
# `save=before.tsv`, make the change, run again with `check=before.tsv` (same data, same scale).

using JET: JET
include(joinpath(@__DIR__, "harness.jl"))
using .AllocStudy: AllocStudy, SCENARIOS, measure, allocation_sites
using Printf: @printf
using Dates: Dates
include(joinpath(@__DIR__, "context.jl"))
include(joinpath(@__DIR__, "scenarios.jl"))
include(joinpath(@__DIR__, "report.jl"))

function parse_options(args)
    options = Dict{String,String}()
    for a in args
        occursin('=', a) || error("an option is written key=value, got \"$a\"")
        key, value = split(a, '='; limit = 2)
        options[String(key)] = String(value)
    end
    known = (
        "data",
        "scale",
        "only",
        "lines",
        "jet",
        "repeats",
        "save",
        "check",
        "out",
        "list",
        "pressure",
    )
    for k in keys(options)
        k in known || error("unknown option \"$k\"; the options are $(join(known, ", "))")
    end
    return options
end

flag(options, key, default) =
    lowercase(get(options, key, string(default))) in ("true", "1", "yes")

# The optimization analysis of JET for what a scenario runs.
function optimization(s, ctx)
    state = s.setup(ctx)
    result = JET.report_opt(s.run, Tuple{typeof(state)}; target_modules = (T,))
    text = sprint(io -> show(io, MIME("text/plain"), result))
    return (; reports = length(JET.get_reports(result)), text)
end

function main(args)
    options = parse_options(args)
    started = Dates.now()
    data = Symbol(get(options, "data", "synthetic"))
    data in (:synthetic, :real) || error("data must be synthetic or real")
    pattern = Regex(get(options, "only", ""))
    selected = filter(s -> occursin(pattern, string(s.group, "/", s.name)), SCENARIOS)
    if flag(options, "list", false)
        foreach(s -> println(s.group, "/", s.name), selected)
        return 0
    end
    want_lines = flag(options, "lines", true)
    want_jet = flag(options, "jet", false)

    scale = Symbol(get(options, "scale", "small"))
    AllocStudy.PRESSURE_SECONDS[] = parse(Float64, get(options, "pressure", "2"))
    @info "Preparing the data" data scale
    ctx = data === :synthetic ? synthetic_context(scale) : real_context()
    @info "Data ready" label = ctx.label

    outcomes = Outcome[]
    println("\nscenario                                                   time   allocated")
    for s in selected
        name = string(s.group, "/", s.name)
        if s.requires === :synthetic && ctx.kind !== :synthetic
            push!(
                outcomes,
                Outcome(
                    s,
                    nothing,
                    "needs the synthetic database",
                    AllocStudy.Site[],
                    nothing,
                ),
            )
            continue
        end
        if haskey(options, "repeats")
            s = AllocStudy.Scenario(
                s.group,
                s.name,
                s.requires,
                s.setup,
                s.run,
                s.fingerprint,
                s.output,
                parse(Int, options["repeats"]),
            )
        end
        try
            m = measure(s, ctx)
            push!(outcomes, Outcome(s, m, "", AllocStudy.Site[], nothing))
            @printf("%-52s %10s %12s\n", name, time_text(m.seconds), bytes_text(m.bytes))
        catch err
            err isa InterruptException && rethrow()
            reason = sprint(showerror, err)
            push!(outcomes, Outcome(s, nothing, reason, AllocStudy.Site[], nothing))
            @printf("%-52s left out: %s\n", name, first(split(reason, '\n')))
        end
    end

    roots = (joinpath(pkgdir(T), "src"), joinpath(pkgdir(T), "ext"))
    if want_lines
        println("\nAllocation sites by line")
        for (i, o) in enumerate(outcomes)
            (o.measurement === nothing || o.measurement.bytes < 256 * 1024) && continue
            try
                sites = allocation_sites(o.scenario, ctx, roots, o.measurement.bytes)
                outcomes[i] = Outcome(o.scenario, o.measurement, "", sites, o.jet)
                println("  ", name_of(o), ": ", length(sites), " site(s)")
            catch err
                err isa InterruptException && rethrow()
                @warn "Allocation sites failed" scenario = name_of(o) reason =
                    sprint(showerror, err)
            end
        end
    end
    if want_jet
        println("\nOptimization analysis (JET)")
        for (i, o) in enumerate(outcomes)
            o.measurement === nothing && continue
            try
                jet = optimization(o.scenario, ctx)
                outcomes[i] = Outcome(o.scenario, o.measurement, "", outcomes[i].sites, jet)
                println("  ", name_of(o), ": ", jet.reports, " report(s)")
            catch err
                err isa InterruptException && rethrow()
                @warn "JET failed" scenario = name_of(o) reason = sprint(showerror, err)
            end
        end
    end

    stamp = Dates.format(started, "yyyymmdd-HHMMSS")
    folder = get(
        options,
        "out",
        joinpath(dirname(@__DIR__), "results", "allocations", string(data, "-", stamp)),
    )
    mkpath(folder)
    comparison = nothing
    if haskey(options, "check")
        saved_label, saved = read_fingerprints(options["check"])
        saved_label == ctx.label || @warn(
            "the saved fingerprints are from other data",
            saved = saved_label,
            now = ctx.label,
        )
        comparison = compare_fingerprints(saved, outcomes)
    end
    write_summary_csv(joinpath(folder, "summary.csv"), outcomes)
    write_sites_csv(joinpath(folder, "sites.csv"), outcomes)
    save = get(options, "save", joinpath(folder, "fingerprints.tsv"))
    write_fingerprints(save, ctx.label, outcomes)
    want_jet && write_jet(joinpath(folder, "jet.txt"), outcomes)
    write_report(
        joinpath(folder, "report.md"),
        outcomes;
        label = ctx.label,
        options = isempty(args) ? "(defaults)" : join(args, " "),
        comparison,
        started,
    )
    println("\nFiles in ", folder)
    println("  report.md  summary.csv  sites.csv  ", basename(save))
    if comparison !== nothing
        changed = [n for (n, s) in comparison if s === :changed]
        if !isempty(changed)
            println("\nTHE DATA CHANGED in:")
            foreach(n -> println("  ", n), changed)
            return 1
        end
        println("\nIntegrity: no result changed.")
    end
    return 0
end

exit(main(ARGS))
