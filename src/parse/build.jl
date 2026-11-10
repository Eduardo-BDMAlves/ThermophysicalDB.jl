# Growing a column with `push!` leaves spare capacity (the backing array can be 50 % larger
# than the data). A dataset that is built once and then only read gives that memory back.
shrink!(v::Vector) = (sizehint!(v, length(v); shrink = true); v)
shrink!(v::PooledFloats) = (shrink!(v.codes); shrink!(v.pool); v)
shrink!(::Any) = nothing

function shrink!(table::Union{MeasurementTable,ExtraTable,ConditionTable,UncertaintyTable})
    for name in fieldnames(typeof(table))
        value = getfield(table, name)
        value isa Tuple ? foreach(shrink!, value) : shrink!(value)
    end
    return table
end

"""
    compact!(ds::Dataset) -> ds

Release the spare capacity of the large columns (measurements, extras, conditions,
uncertainties) after the dataset is complete. The values do not change.
"""
function compact!(ds::Dataset)
    for table in (ds.measurements, ds.extras, ds.conditions, ds.uncertainties)
        shrink!(table)
    end
    return ds
end

"""
    build_dataset(archive; source = "thermoml", chunk_size = 128, progress = true)
        -> (dataset, report)

Parse every article of a ThermoML `.tgz` archive into a [`Dataset`](@ref). The archive is
streamed; articles are parsed in chunks, in parallel on all available threads (start
Julia with `-t auto`), and merged in file order, so the result does not depend on the
thread count. Articles that fail to parse are skipped and listed in `report.failed`.
"""
function build_dataset(
    archive::AbstractString;
    source::AbstractString = "thermoml",
    chunk_size::Integer = 128,
    progress::Bool = true,
)
    ds = Dataset()
    source_id = intern!(ds.sources, source)
    report = BuildReport()
    chunk = Tuple{String,Vector{UInt8}}[]
    next_report = 2000

    function flush!()
        isempty(chunk) && return nothing
        parsed = Vector{ParsedArticle}(undef, length(chunk))
        @sync for i in eachindex(chunk)
            Threads.@spawn parsed[i] = parse_article(chunk[i][1], chunk[i][2])
        end
        foreach(article -> ingest!(ds, article, source_id, report), parsed)
        empty!(chunk)
        if progress && report.articles >= next_report
            @info "Parsing ThermoML" articles = report.articles points = length(ds)
            next_report += 2000
        end
        return nothing
    end

    foreach_archive_entry(archive; suffix = ".json") do path, bytes
        push!(chunk, (String(path), bytes))
        length(chunk) >= chunk_size && flush!()
    end
    flush!()

    isempty(report.failed) || @warn(
        "$(length(report.failed)) articles could not be parsed and were skipped",
        examples = first(report.failed, 3),
    )
    isempty(report.skipped) || @info(
        "$(length(report.skipped)) systems were skipped",
        examples = first(report.skipped, 3),
    )
    report.reaction_blocks > 0 && @info(
        "ReactionData blocks are not supported yet and were ignored",
        blocks = report.reaction_blocks,
    )
    compact!(ds)
    validate(ds)
    return ds, report
end
