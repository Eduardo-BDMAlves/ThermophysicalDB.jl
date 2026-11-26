# Exports of a selection of several databases, and of the data of the user ("This work").
#
# A selection of one database that has no publication is exported by the functions of
# `DataView`. Otherwise the points of every part are written one after the other (the header
# once), the articles are the union of those of the parts (an article with the same DOI is one
# entry and has one key) and all the points of the databases of kind `:user` are one pseudo-reference:
# the publication, written as the label, as an `@unpublished` entry or as the article of its DOI
# (see `Publication`).

const BIBLIOGRAPHY_KEYWORDS = (
    :online,
    :cache,
    :refresh,
    :progress,
    :fetcher,
    :include_source,
    :include_package,
    :package_cff,
)

const CITE_CHOICES = (:auto, WORK_CITES...)

# The keywords of the bibliography on one side and all the others on the other.
function split_keywords(kwargs)
    bib = (; (k => v for (k, v) in kwargs if k in BIBLIOGRAPHY_KEYWORDS)...)
    rest = (; (k => v for (k, v) in kwargs if !(k in BIBLIOGRAPHY_KEYWORDS))...)
    return bib, rest
end

# How the data of the user are cited: the `cite` of the call, or the one of the publication.
function work_cite(pub::Union{Nothing,Publication}, cite::Symbol)
    cite in CITE_CHOICES ||
        throw(ArgumentError("cite must be one of $(CITE_CHOICES), got $(repr(cite))"))
    pub === nothing && return :label
    mode = cite === :auto ? pub.cite : cite
    mode === :published &&
        isempty(pub.doi) &&
        throw(
            ArgumentError(
                "cite = :published needs the DOI of the publication; set it with `set_publication!` " *
                "or use cite = :unpublished",
            ),
        )
    return mode
end

# Whether the selection needs the joint export: several databases, or data of the user that are
# to be called by the name of the publication.
function joint_selection(v::DatabaseView, this_work)
    length(v.parts) > 1 && return true
    work = work_scope(v, this_work; strict = true)
    return work !== nothing && any(any, work.masks)
end

# The reference of the points of `p` that stands for all of them in the references table.
function first_reference(p::DataView)
    ds = p.dataset
    m, ex = ds.measurements, ds.experiments
    for r in p.rows
        ref = ex.reference[m.experiment[r]]
        ref == NO_ID || return Int32(ref)
    end
    length(ds.references) > 0 && return Int32(1)
    throw(ArgumentError("the points of the user have no reference to stand for them"))
end

# The entry of the publication: `(entry, archive_only, conflicts, resolved)`. With `:label` the
# key is the label and the entry is never written; with `:unpublished` it is built from the fields
# of the publication; with `:published` it is the entry of the DOI completed with those fields.
function work_entry(
    pub::Publication,
    mode::Symbol;
    online::Bool,
    cache::Bool,
    refresh::Bool,
    fetcher,
)
    conflicts = @NamedTuple{doi::String, field::String, resolver::String, archive::String}[]
    mode === :label && return (
        BibEntry("unpublished", pub.label, ["note" => pub.label]),
        String[],
        conflicts,
        0,
    )
    fields = Pair{String,String}[]
    isempty(pub.authors) || push!(fields, "author" => join(pub.authors, " and "))
    isempty(pub.title) || push!(fields, "title" => pub.title)
    pub.year > 0 && push!(fields, "year" => string(pub.year))
    isempty(pub.doi) || push!(fields, "doi" => pub.doi)
    if mode === :unpublished
        note = join(filter(!isempty, (pub.journal, pub.note)), ", ")
        isempty(note) || push!(fields, "note" => note)
        return (BibEntry("unpublished", "", fields), String[], conflicts, 0)
    end
    isempty(pub.journal) || push!(fields, "journal" => pub.journal)
    archive = BibEntry(isempty(pub.journal) ? "misc" : "article", "", fields)
    text = fetch_entry_text(pub.doi; online, cache, refresh, fetcher)
    parsed = text === nothing ? nothing : parse_bibtex(text)
    parsed === nothing && return (archive, String[pub.doi], conflicts, 0)
    entry = merge_entries(clean_resolver_entry!(parsed), archive, pub.doi, conflicts)
    return (entry, String[], conflicts, 1)
end

# What the exports of a selection of several parts share: the bibliography of each part (with the
# same entries, and so the same keys) and the reference that stands for the points of the user.
struct SelectionBibliography
    parts::Vector{Bibliography}
    collapse::Vector{Union{Nothing,Int32}}
    total::Bibliography
    view::DatabaseView    # the selection with the points of the publication apart from the others
end

function selection_bibliography(
    v::DatabaseView;
    this_work = :auto,
    cite::Symbol = :auto,
    online::Bool = true,
    cache::Bool = true,
    refresh::Bool = false,
    progress::Bool = true,
    fetcher = default_fetcher,
    include_source::Bool = true,
    include_package::Bool = true,
    package_cff::Union{Nothing,AbstractString} = nothing,
)
    work = work_scope(v, this_work; strict = true)
    pub = work === nothing ? nothing : work.publication
    mode = work_cite(pub, cite)
    view, isuser = split_work(v, work)
    n = length(view.parts)
    collapse = Vector{Union{Nothing,Int32}}(nothing, n)
    ids = Vector{Vector{Int}}(undef, n)
    entries = Vector{Vector{BibEntry}}(undef, n)
    archive_only = String[]
    conflicts = @NamedTuple{doi::String, field::String, resolver::String, archive::String}[]
    resolved = 0
    articles = 0

    pool = BibEntry[]
    by_doi = Dict{String,BibEntry}()
    function pooled(e::BibEntry)
        doi = lowercase(something(field_value(e, "doi"), ""))
        isempty(doi) && return (push!(pool, e); e)
        return get!(by_doi, doi) do
            push!(pool, e)
            e
        end
    end

    work = nothing
    for (k, p) in enumerate(view.parts)
        if pub isa Publication && isuser[k]
            collapse[k] = first_reference(p)
            if work === nothing
                entry, only_archive, found, ok =
                    work_entry(pub, mode; online, cache, refresh, fetcher)
                append!(archive_only, only_archive)
                append!(conflicts, found)
                resolved += ok
                articles += mode === :label ? 0 : 1
                work = mode === :label ? entry : pooled(entry)
            end
            ids[k] = Int[collapse[k]]
            entries[k] = BibEntry[work]
        elseif isempty(p)
            ids[k] = Int[]
            entries[k] = BibEntry[]
        else
            r = resolve_entries(p; online, cache, refresh, progress, fetcher)
            ids[k] = r.ids
            entries[k] = BibEntry[pooled(e) for e in r.entries]
            append!(archive_only, r.archive_only)
            append!(conflicts, r.conflicts)
            resolved += r.resolved
            articles += length(r.ids)
        end
    end

    sources = include_source ? source_entries() : BibEntry[]
    package = include_package ? package_entries(package_cff) : BibEntry[]
    reserved = Set{String}(e.key for e in Iterators.flatten((sources, package)))
    mode === :label && work !== nothing && push!(reserved, work.key)
    assign_keys!(pool, reserved)
    uncited = mode === :label && work !== nothing ? String[work.key] : String[]
    all_entries = copy(pool)
    mode === :label && work !== nothing && push!(all_entries, work)

    report = BibtexReport(articles, resolved, unique(archive_only), conflicts)
    from = any(from_archive, view.parts)
    total = Bibliography(Int[], all_entries, sources, package, report, from, uncited)
    parts = Bibliography[
        Bibliography(
            ids[k],
            entries[k],
            sources,
            package,
            report,
            from_archive(view.parts[k]),
            uncited,
        ) for k = 1:n
    ]
    return SelectionBibliography(parts, collapse, total, view)
end

# ----------------------------------------------------------------------------------
# The references table of several parts
# ----------------------------------------------------------------------------------

const SUMMARY_SUM = (:n_points, :n_uncertainty)
const SUMMARY_MIN = (:T_min, :p_min, :purity_min)
const SUMMARY_MAX = (:T_max, :p_max, :purity_max)
const SUMMARY_MEAN = (:unc_abs, :unc_rel)
const SUMMARY_JOIN = (
    :system,
    :method,
    :method_full,
    :phase,
    :purity,
    :purity_basis,
    :purity_method,
    :purification,
    :sample_source,
    :supplier,
)

function finite_extreme(f, values)
    kept = filter(isfinite, values)
    return isempty(kept) ? NaN : f(kept)
end

# One row from the rows `idx` of the columns `c` that describe the same (article, property).
# The uncertainty of the new row is the mean of theirs, weighted by the points that state one.
function merge_rows(c::NamedTuple, idx::Vector{Int})
    i = first(idx)
    length(idx) == 1 && return map(col -> col[i], c)
    weights = Float64[c.n_uncertainty[j] for j in idx]
    function weighted(col)
        s = t = 0.0
        for (j, w) in zip(idx, weights)
            x = col[j]
            (isnan(x) || w == 0) && continue
            s += w * x
            t += w
        end
        return t == 0 ? NaN : s / t
    end
    return NamedTuple{keys(c)}(
        map(keys(c)) do name
            col = c[name]
            if name in SUMMARY_SUM
                sum(col[j] for j in idx)
            elseif name in SUMMARY_MIN
                finite_extreme(minimum, [col[j] for j in idx])
            elseif name in SUMMARY_MAX
                finite_extreme(maximum, [col[j] for j in idx])
            elseif name in SUMMARY_MEAN
                weighted(col)
            elseif name in SUMMARY_JOIN
                join(
                    unique(
                        reduce(
                            vcat,
                            [filter(!isempty, split(col[j], "; ")) for j in idx];
                            init = SubString{String}[],
                        ),
                    ),
                    "; ",
                )
            else
                col[i]
            end
        end,
    )
end

# The references tables of the parts as one: the rows of the same article and property are one.
function merge_summaries(summaries::Vector{ReferenceSummary}, bib::Bibliography)
    first_summary = summaries[1]
    columns = [getfield(s, :columns) for s in summaries]
    names = keys(columns[1])
    joined = NamedTuple{names}(map(k -> reduce(vcat, (c[k] for c in columns)), names))
    groups = Dict{Tuple{String,String,String},Vector{Int}}()
    order = Tuple{String,String,String}[]
    for i in eachindex(joined.key)
        key = (joined.key[i], joined.property[i], joined.unit[i])
        push!(get!(groups, key) do
            push!(order, key)
            Int[]
        end, i)
    end
    rows = [merge_rows(joined, groups[k]) for k in order]
    perm = sortperm([(r.year, r.month, lowercase(r.key), r.property) for r in rows])
    sorted = rows[perm]
    merged = NamedTuple{names}(Tuple([r[k] for r in sorted] for k in names))
    legend = Dict{String,String}()
    for s in summaries, (k, x) in getfield(s, :legend)
        get!(legend, k, x)
    end
    return ReferenceSummary(
        merged,
        sort!(collect(legend); by = first),
        getfield(first_summary, :temperature_unit),
        getfield(first_summary, :pressure_unit),
        getfield(first_summary, :statistic),
        bib,
    )
end

"""
    reference_summary(view::DatabaseView; this_work = :auto, cite = :auto, kwargs...)

The references table of a selection of a [`Database`](@ref), with the arguments of
[`reference_summary`](@ref) for a `DataView`. The articles of all the databases are one list: an
article that two of them hold (the same DOI) is one row. The points of the databases of kind
`:user` are one row for each property, whatever the references they have, and that row is the
[`Publication`](@ref) of the database: its `key` is the label ("This work", with `cite = :label`),
the key of the `@unpublished` entry (`:unpublished`) or the key of the article of the DOI
(`:published`). `cite = :auto` is the one of the publication; `this_work = false` ignores the
publication and keeps the references of the data as they are.
"""
function reference_summary(
    v::DatabaseView;
    this_work = :auto,
    cite::Symbol = :auto,
    kwargs...,
)
    bib, rest = split_keywords(kwargs)
    if !joint_selection(v, this_work)
        work_cite(nothing, cite)
        return reference_summary(sole_part(v); bib..., rest...)
    end
    sel = selection_bibliography(v; this_work, cite, bib...)
    summaries = ReferenceSummary[
        reference_summary(
            p;
            bibliography = sel.parts[k],
            collapse = sel.collapse[k],
            rest...,
        ) for (k, p) in enumerate(sel.view.parts) if !isempty(p)
    ]
    return merge_summaries(summaries, sel.total)
end

function build_bibliography(
    v::DatabaseView;
    this_work = :auto,
    cite::Symbol = :auto,
    kwargs...,
)
    bib, rest = split_keywords(kwargs)
    if !joint_selection(v, this_work)
        work_cite(nothing, cite)
        return build_bibliography(sole_part(v); bib..., rest...)
    end
    isempty(rest) || throw(ArgumentError("unknown keywords $(join(keys(rest), ", "))"))
    total = selection_bibliography(v; this_work, cite, bib...).total
    return (render_bibliography(total), total.report)
end

"""
    bibtex(view::DatabaseView; this_work = :auto, cite = :auto, kwargs...) -> String

The BibTeX of the articles of a selection of a [`Database`](@ref), as [`bibtex`](@ref) of a
`DataView` does, for all the databases at once: each article is one entry and has one key. The data
of the user are not an article, and the entry that stands for them depends on `cite` (see
[`Publication`](@ref)): none with `:label` (the work that is being written is not cited by itself),
an `@unpublished` entry with `:unpublished` (for reports) and the entry of the DOI, completed with
the fields of the publication, with `:published`.
"""
bibtex(v::DatabaseView; kwargs...) = first(build_bibliography(v; kwargs...))

function write_bibtex(path::AbstractString, v::DatabaseView; kwargs...)
    text, report = build_bibliography(v; kwargs...)
    write(path, text)
    return report
end

function write_references(
    prefix::AbstractString,
    v::DatabaseView;
    formats = (:bib, :tex, :md, :csv),
    table = (;),
    kwargs...,
)
    return write_summary_files(prefix, reference_summary(v; kwargs...), formats, table)
end

# ----------------------------------------------------------------------------------
# The points of several parts
# ----------------------------------------------------------------------------------

function joint_export_data(v::DatabaseView, sel::SelectionBibliography; kwargs...)
    reference = get(kwargs, :reference, :key)
    units = get(kwargs, :units, :native)
    details = get(kwargs, :details, false)
    composition = get(kwargs, :composition, nothing)
    rest = (;
        (
            k => x for
            (k, x) in kwargs if !(k in (:reference, :units, :details, :composition))
        )...
    )
    heads = [
        export_head(
            p;
            reference,
            units,
            composition,
            bibliography = sel.parts[k],
            collapse = sel.collapse[k],
            rest...,
        ) for (k, p) in enumerate(sel.view.parts) if !isempty(p)
    ]
    tables = [parent(h.t) for h in heads]
    names = keys(tables[1])
    t = NamedTuple{names}(map(k -> reduce(vcat, (x[k] for x in tables)), names))
    terms = Dict{Int,Vector{Any}}()
    offset = 0
    for h in heads
        for (i, x) in h.terms
            terms[offset+i] = x
        end
        offset += length(h.reference_column)
    end
    origins = filter(!isnothing, [h.origin for h in heads])
    summary = merge_summaries(ReferenceSummary[h.summary for h in heads], sel.total)
    return assemble_export_data(
        t,
        reduce(vcat, (h.reference_column for h in heads)),
        reduce(vcat, (h.ncomp for h in heads)),
        heads[1].x_units,
        summary,
        isempty(origins) ? nothing : first(origins),
        terms;
        reference,
        units,
        details,
        composition,
    )
end

"""
    export_points(directory, view::DatabaseView; this_work = :auto, cite = :auto, kwargs...)

[`export_points`](@ref) for a selection of a [`Database`](@ref): the points of the databases are
written one after the other in each file (the header once), the references are the union of
those of the databases and the `.bib` has each article once. The ThermoML formats (`:thermoml`,
`:thermoml_xml`) are for one database and are refused.

The points of the databases of kind `:user` are referred to as their [`Publication`](@ref) says
(`cite`, which a call can change): `:label` writes "This work" in the `reference` column and
leaves them out of the `.bib` (for a paper that publishes those data), `:unpublished` writes the
key of an `@unpublished` entry (for a report) and `:published` the key of the article of the DOI.
`this_work = false` ignores the publication and keeps the references of the data as they are.
"""
function export_points(
    path::AbstractString,
    v::DatabaseView;
    formats = nothing,
    sheets::Symbol = :system,
    references::Bool = true,
    this_work = :auto,
    cite::Symbol = :auto,
    kwargs...,
)
    bib, rest = split_keywords(kwargs)
    if !joint_selection(v, this_work)
        work_cite(nothing, cite)
        return export_points(
            path,
            sole_part(v);
            formats,
            sheets,
            references,
            bib...,
            rest...,
        )
    end
    sheets in SHEET_LAYOUTS ||
        throw(ArgumentError("sheets must be one of $(SHEET_LAYOUTS), got :$sheets"))
    length(v) == 0 && throw(ArgumentError("the selection has no points to export"))
    directory = export_directory(path)
    chosen = export_formats(formats)
    any(in((:thermoml, :thermoml_xml)), chosen) && throw(
        ArgumentError(
            "the ThermoML formats are for the points of one database; export each part " *
            "with `parts(view)`",
        ),
    )
    reference = get(rest, :reference, :key)
    if !references && reference === :key && any(f -> f in (:csv, :md, :tex), chosen)
        @warn(
            "references = false with reference = :key: the files hold BibTeX keys but no " *
            "`.bib` is written, so the DOI of each article cannot be recovered from them. " *
            "Use `reference = :doi` or keep `references = true`."
        )
    end
    sel = selection_bibliography(v; this_work, cite, bib...)
    data = joint_export_data(v, sel; rest...)

    mkpath(directory)
    name = basename(directory)
    files = String[]
    for format in chosen
        file = joinpath(directory, name * file_extension(format))
        write_point_file(format, file, data, sel.view.parts[1]; sheets)
        push!(files, file)
    end
    references &&
        append!(files, write_reference_files(joinpath(directory, name), data, chosen))
    cited = count(e -> !(e.key in sel.total.uncited), sel.total.entries)
    return ExportReport(files, length(v), cited, sel.total.report)
end
