# Repeated points between databases. The same measurement can be in two databases (the archive and
# the literature points of the user, say); `points(db; duplicate = false)` leaves out the copy of the
# database with the lower priority. Two points are the same when they come from the same work and
# agree in the conditions and the value (see `DuplicateRules`). A work is told by its DOI, or by its
# first author and year (and the title, when both have one): with no information on where a point
# comes from, two points are never taken for the same, however close they are. Points of one
# database are never compared with each other, and the archive is never changed.

# What tells a reference apart from another one.
struct WorkKey
    doi::String        # lower case, empty when there is none
    surname::String    # of the first author, normalised
    year::Int
    title::String      # normalised
    label::String      # to show: the DOI, or "Surname year"
end

function surname_of(author::AbstractString)
    s = strip(author)
    isempty(s) && return ""
    s = occursin(',', s) ? first(split(s, ',')) : last(split(s))
    return normalize_name(s)
end

function work_key(ds::Dataset, r::Integer)
    rf = ds.references
    doi = lowercase(strip(rf.doi[r]))
    authors = rf.authors[r]
    first_author = isempty(authors) ? "" : String(strip(first(authors)))
    year = Int(rf.year[r])
    label =
        !isempty(strip(rf.doi[r])) ? String(strip(rf.doi[r])) :
        isempty(first_author) ? "" :
        first(split(first_author, ',')) * (year > 0 ? " $year" : "")
    return WorkKey(doi, surname_of(first_author), year, normalize_name(rf.title[r]), label)
end

# Two titles are the same when one contains the other (a subtitle or a short form is still the same).
function titles_agree(a::AbstractString, b::AbstractString)
    (isempty(a) || isempty(b)) && return true
    return occursin(a, b) || occursin(b, a)
end

# Two DOIs decide by themselves; without one of them it takes the first author, the year, and the
# titles when both have one. No author or no year: not the same work.
function same_work(a::WorkKey, b::WorkKey)
    !isempty(a.doi) && !isempty(b.doi) && return a.doi == b.doi
    (isempty(a.surname) || isempty(b.surname) || a.year == 0 || b.year == 0) && return false
    (a.surname == b.surname && a.year == b.year) || return false
    return titles_agree(a.title, b.title)
end

# ----------------------------------------------------------------------------------
# One point, with what is compared, in the numbers of all the databases
# ----------------------------------------------------------------------------------

struct Point
    part::Int32                    # the position of its database in the selection (priority order)
    row::Int32
    comp::NTuple{3,Int32}          # global compounds, in ascending order, 0 when absent
    prop::Int32                    # global property
    temperature::Float64
    pressure::Float64
    value::Float64
    amount::NTuple{3,Float64}      # in the order of `comp`
    kind::NTuple{3,Int32}          # the scale of each amount, in the order of `comp`
end

struct ExperimentInfo
    comp::NTuple{3,Int32}
    order::NTuple{3,Int8}          # position of each sorted compound among the components
    kind::NTuple{3,Int32}
    ncomp::Int
end

function experiment_info(
    ds::Dataset,
    reg::Registry,
    m::Integer,
    e::Integer,
    kinds::Dict{String,Int32},
)
    ex = ds.experiments
    n = Int(ex.ncomp[e])
    global_ids = ntuple(i -> i <= n ? reg.compound[m][ex.components[i][e]] : Int32(0), 3)
    order = sortperm(collect(global_ids[1:n]))
    comp = ntuple(i -> i <= n ? global_ids[order[i]] : Int32(0), 3)
    kind_of(i) = begin
        id = ex.kinds[i][e]
        id == NO_ID && return Int32(0)
        get!(kinds, ds.kinds.strings[id], Int32(length(kinds) + 1))
    end
    kind = ntuple(i -> i <= n ? kind_of(order[i]) : Int32(0), 3)
    return ExperimentInfo(comp, ntuple(i -> i <= n ? Int8(order[i]) : Int8(0), 3), kind, n)
end

# ----------------------------------------------------------------------------------
# Comparing two points
# ----------------------------------------------------------------------------------

# A little room for the rounding of the subtraction: 293.15 and 293.25 are 0.1 K apart.
within(a::Float64, b::Float64, tol::Float64) =
    abs(a - b) <= tol + 8 * eps(max(abs(a), abs(b)))
relative_within(a::Float64, b::Float64, tol::Float64) =
    abs(a - b) <= tol * max(abs(a), abs(b))

# `:duplicate`, `:conflict` or `nothing`, and the criteria that were left out because a side did not
# have them. The temperature of both is given and within the tolerance (the caller checks it).
function compare_points(a::Point, b::Point, n::Int, rules::DuplicateRules)
    value_close = relative_within(a.value, b.value, rules.value)
    ignored = 0x00
    pressure_close = true
    if isnan(a.pressure) || isnan(b.pressure)
        ignored |= 0x01
    else
        pressure_close = within(a.pressure, b.pressure, rules.pressure)
    end
    composition_close = true
    composition_exact = true
    composition_known = true
    for c = 1:n
        x, y = a.amount[c], b.amount[c]
        if isnan(x) || isnan(y)
            composition_exact &= isnan(x) && isnan(y)
            (isnan(x) && isnan(y)) || (ignored |= 0x02)
            continue
        end
        if a.kind[c] != b.kind[c]
            # Two scales cannot be compared without converting: not comparable, both are kept.
            composition_known = false
            break
        end
        composition_close &= relative_within(x, y, rules.composition)
        composition_exact &= x == y
    end
    composition_known || return (nothing, ignored)
    if value_close && pressure_close && composition_close
        return (:duplicate, ignored)
    end
    # Same temperature, pressure and composition (exactly) and a different value.
    if !value_close &&
       a.temperature == b.temperature &&
       isequal(a.pressure, b.pressure) &&
       composition_exact
        return (:conflict, ignored)
    end
    return (nothing, ignored)
end

function ignored_text(bits::UInt8)
    parts = String[]
    bits & 0x01 != 0 && push!(parts, "pressure")
    bits & 0x02 != 0 && push!(parts, "composition")
    return join(parts, ", ")
end

# ----------------------------------------------------------------------------------
# The search
# ----------------------------------------------------------------------------------

function compound_label(ds::Dataset, e::Integer)
    ex = ds.experiments
    names = String[]
    for i = 1:Int(ex.ncomp[e])
        c = ex.components[i][e]
        push!(
            names,
            isempty(ds.compounds.names[c]) ? ds.compounds.key[c] :
            first(ds.compounds.names[c]),
        )
    end
    return join(names, " + ")
end

# Union-find over the references that are selected, to put the ones of one work together.
function find_root!(parent::Vector{Int}, i::Int)
    while parent[i] != i
        parent[i] = parent[parent[i]]
        i = parent[i]
    end
    return i
end

function union!(parent::Vector{Int}, i::Int, j::Int)
    a, b = find_root!(parent, i), find_root!(parent, j)
    a == b || (parent[max(a, b)] = min(a, b))
    return nothing
end

"""
    find_repeats(db, index, parts, rules) -> (report, removed)

The pairs of repeated points and conflicts between the `parts` of a selection (a `DataView` of each
database of `index`, in the order of priority), and for each part the rows that are repeated of a
database that wins. Only the references that are in two parts are looked at, and only their points.
"""
function find_repeats(
    db::Database,
    index::AbstractVector{<:Integer},
    parts::AbstractVector{DataView},
    rules::DuplicateRules,
)
    np = length(parts)
    removed = [Set{Int32}() for _ = 1:np]
    report = DuplicateReport(rules)
    np < 2 && return (report, removed)
    reg = db.registry

    # The references that the selected points belong to, with what tells them apart.
    entries = Tuple{Int,Int32,WorkKey}[]    # (part, reference, key)
    slot = [Dict{Int32,Int}() for _ = 1:np]
    for (p, view) in enumerate(parts)
        ds = view.dataset
        m, ex = ds.measurements, ds.experiments
        seen = falses(length(ds.references))
        for r in view.rows
            seen[ex.reference[m.experiment[r]]] = true
        end
        for ref in findall(seen)
            push!(entries, (p, Int32(ref), work_key(ds, ref)))
            slot[p][Int32(ref)] = length(entries)
        end
    end

    # Put the references of one work together: the same DOI, or the same author and year when one
    # of them has no DOI. References of the same database are never put together by a pair.
    parent = collect(1:length(entries))
    by_doi = Dict{String,Vector{Int}}()
    by_author = Dict{Tuple{String,Int},Vector{Int}}()
    for (i, (_, _, key)) in enumerate(entries)
        isempty(key.doi) || push!(get!(Vector{Int}, by_doi, key.doi), i)
        if !isempty(key.surname) && key.year > 0
            push!(get!(Vector{Int}, by_author, (key.surname, key.year)), i)
        end
    end
    for list in values(by_doi), a = 1:length(list), b = (a+1):length(list)
        entries[list[a]][1] != entries[list[b]][1] && union!(parent, list[a], list[b])
    end
    for list in values(by_author), a = 1:length(list), b = (a+1):length(list)
        i, j = list[a], list[b]
        entries[i][1] == entries[j][1] && continue
        same_work(entries[i][3], entries[j][3]) && union!(parent, i, j)
    end
    group_parts = Dict{Int,Set{Int}}()
    for (i, (p, _, _)) in enumerate(entries)
        push!(get!(Set{Int}, group_parts, find_root!(parent, i)), p)
    end
    shared = Set(root for (root, ps) in group_parts if length(ps) > 1)
    isempty(shared) && return (report, removed)
    group_id = Dict(root => g for (g, root) in enumerate(sort!(collect(shared))))
    ngroups = length(group_id)

    # The points of those works, with what is compared.
    kinds = Dict{String,Int32}()
    groups = [Point[] for _ = 1:ngroups]
    how = fill(:doi, ngroups)
    label = fill("", ngroups)
    for (i, (_, _, key)) in enumerate(entries)
        g = get(group_id, find_root!(parent, i), 0)
        g == 0 && continue
        isempty(key.doi) && (how[g] = :authors)
        isempty(label[g]) && (label[g] = key.label)
    end
    skipped = 0
    for (p, view) in enumerate(parts)
        ds = view.dataset
        m, ex = ds.measurements, ds.experiments
        mi = index[p]
        infos = Dict{Int32,ExperimentInfo}()
        for r in view.rows
            e = m.experiment[r]
            ref = ex.reference[e]
            i = get(slot[p], ref, 0)
            i == 0 && continue
            g = get(group_id, find_root!(parent, i), 0)
            g == 0 && continue
            if isnan(m.temperature[r])
                skipped += 1
                continue
            end
            info = get!(infos, e) do
                experiment_info(ds, reg, mi, e, kinds)
            end
            amount =
                ntuple(c -> c <= info.ncomp ? m.composition[Int(info.order[c])][r] : NaN, 3)
            push!(
                groups[g],
                Point(
                    p,
                    r,
                    info.comp,
                    reg.property[mi][Int(m.property[r])],
                    m.temperature[r],
                    m.pressure[r],
                    m.value[r],
                    amount,
                    info.kind,
                ),
            )
        end
    end

    compared = 0
    names = [db.members[i].name for i in index]
    for g = 1:ngroups
        pts = groups[g]
        sort!(pts; by = x -> (x.comp, x.prop, x.temperature))
        n = length(pts)
        compared += n
        a = 1
        while a <= n
            # The block of one system and property.
            z = a
            while z < n && pts[z+1].comp == pts[a].comp && pts[z+1].prop == pts[a].prop
                z += 1
            end
            ncomp = count(!=(0), pts[a].comp)
            for i = a:z
                pa = pts[i]
                for j = (i+1):z
                    pb = pts[j]
                    pb.temperature - pa.temperature >
                    rules.temperature + 8 * eps(pb.temperature) && break
                    pa.part == pb.part && continue
                    kind, ignored = compare_points(pa, pb, ncomp, rules)
                    kind === nothing && continue
                    # The first of the pair is the one of the database that wins.
                    first_pt, other = pa.part < pb.part ? (pa, pb) : (pb, pa)
                    kind === :duplicate && push!(removed[other.part], other.row)
                    ds_first = parts[first_pt.part].dataset
                    prop = reg.property_keys[first_pt.prop]
                    push!(report.kind, kind)
                    push!(report.work, label[g])
                    push!(report.how, how[g])
                    push!(
                        report.property,
                        isempty(prop[2]) ? prop[1] : prop[1] * ", " * prop[2],
                    )
                    push!(
                        report.compounds,
                        compound_label(
                            ds_first,
                            ds_first.measurements.experiment[first_pt.row],
                        ),
                    )
                    push!(report.database, names[first_pt.part])
                    push!(report.row, first_pt.row)
                    push!(report.value, first_pt.value)
                    push!(report.temperature, first_pt.temperature)
                    push!(report.pressure, first_pt.pressure)
                    push!(report.other_database, names[other.part])
                    push!(report.other_row, other.row)
                    push!(report.other_value, other.value)
                    push!(report.other_temperature, other.temperature)
                    push!(report.other_pressure, other.pressure)
                    push!(report.ignored, ignored_text(ignored))
                end
            end
            a = z + 1
        end
    end
    full = DuplicateReport(
        rules,
        report.kind,
        report.work,
        report.how,
        report.property,
        report.compounds,
        report.database,
        report.row,
        report.value,
        report.temperature,
        report.pressure,
        report.other_database,
        report.other_row,
        report.other_value,
        report.other_temperature,
        report.other_pressure,
        report.ignored,
        ngroups,
        compared,
        skipped,
    )
    return (full, removed)
end

# ----------------------------------------------------------------------------------
# What the user calls
# ----------------------------------------------------------------------------------

duplicate_rules(::Bool) = DEFAULT_DUPLICATE_RULES
duplicate_rules(rules::DuplicateRules) = rules
function duplicate_rules(x)
    throw(
        ArgumentError(
            "duplicate must be true (keep every point), false (leave out the repeated ones) or a DuplicateRules, got $(repr(x))",
        ),
    )
end

# The selection without the points that another database holds too (the one with the higher
# priority is kept), with the report that says which ones they are.
function leave_out_repeats(v::DatabaseView, rules::DuplicateRules)
    length(v.parts) < 2 && return v
    report, removed = find_repeats(v.database, v.index, v.parts, rules)
    index, parts = Int[], DataView[]
    for (i, part, gone) in zip(v.index, v.parts, removed)
        rows = isempty(gone) ? part.rows : Int32[r for r in part.rows if r ∉ gone]
        isempty(rows) && continue
        push!(index, i)
        push!(parts, DataView(part.dataset, rows))
    end
    return DatabaseView(v.database, index, parts, report)
end

function apply_duplicate(v::DatabaseView, duplicate)
    duplicate === true && return v
    return leave_out_repeats(v, duplicate_rules(duplicate))
end

function report_of(v::DatabaseView, rules)
    rules === nothing && v.repeats !== nothing && return v.repeats
    found, _ = find_repeats(
        v.database,
        v.index,
        v.parts,
        rules === nothing ? DEFAULT_DUPLICATE_RULES : rules,
    )
    return found
end

"""
    duplicates(view; rules = nothing) -> DuplicateReport
    duplicates(db; rules = nothing, kwargs...) -> DuplicateReport

The points of a selection that two databases hold both, as pairs: the point of the database that
wins and the other one. A selection made with `points(db; duplicate = false)` gives the report that
left them out, with the points that are gone; `kwargs` are those of [`points`](@ref).

Two points are the same when

1. they come from the same work: the DOI is the same, or, when one reference has no DOI, the first
   author and the year are (and the titles agree when both have one). When nothing tells where a
   point comes from it is never taken for a repeated one, however close it is to another;
2. they are of the same compounds and property, the temperatures are within `rules.temperature`
   (0.1 K) and the values within `rules.value` (0.1 %);
3. the pressures are within `rules.pressure` (0.01 bar) and the amounts of the components within
   `rules.composition`. **A pressure or an amount that one of the points does not have is not
   compared**: if the temperature and the value agree, the points are the same. When the amounts
   are written in different scales they are not compared and both points are kept.

A point without temperature is never compared. Points of one database are never repeats of each
other, and no database is changed. See [`DuplicateRules`](@ref) and [`conflicts`](@ref).
"""
function duplicates(v::DatabaseView; rules::Union{Nothing,DuplicateRules} = nothing)
    r = report_of(v, rules)
    return select_pairs(r, findall(==(:duplicate), r.kind))
end

duplicates(db::Database; rules::Union{Nothing,DuplicateRules} = nothing, kwargs...) =
    duplicates(points(db; kwargs...); rules)

"""
    conflicts(view; rules = nothing) -> DuplicateReport
    conflicts(db; rules = nothing, kwargs...) -> DuplicateReport

The points of two databases that come from the same work, with exactly the same temperature,
pressure and composition, and a different value (beyond `rules.value`): the work reports two values
for one state, or two databases disagree on it. Both points are always kept, even with
`duplicate = false`: look at them with this report and choose. Points of one database are not
compared with each other. See [`duplicates`](@ref) for how a work is told.
"""
function conflicts(v::DatabaseView; rules::Union{Nothing,DuplicateRules} = nothing)
    r = report_of(v, rules)
    return select_pairs(r, findall(==(:conflict), r.kind))
end

conflicts(db::Database; rules::Union{Nothing,DuplicateRules} = nothing, kwargs...) =
    conflicts(points(db; kwargs...); rules)

# ----------------------------------------------------------------------------------
# The notice of the data that were just added
# ----------------------------------------------------------------------------------

# The references of `ds` that are the work `key`.
function references_of_work(ds::Dataset, key::WorkKey)
    found = Int32[]
    rf = ds.references
    for r in eachindex(rf.doi)
        if !isempty(key.doi) && !isempty(rf.doi[r])
            lowercase(strip(rf.doi[r])) == key.doi && push!(found, Int32(r))
        elseif key.year > 0 && rf.year[r] == key.year && same_work(key, work_key(ds, r))
            push!(found, Int32(r))
        end
    end
    return found
end

function rows_of_references(ds::Dataset, refs)
    wanted = falses(length(ds.references))
    wanted[refs] .= true
    m, ex = ds.measurements, ds.experiments
    return Int32[r for r = 1:length(m) if wanted[ex.reference[m.experiment[r]]]]
end

# How to see the points of a work in every database, as text of a call.
function work_filter_text(ds::Dataset, ref::Integer)
    rf = ds.references
    if !isempty(strip(rf.doi[ref]))
        return "doi = \"$(strip(rf.doi[ref]))\""
    end
    author = isempty(rf.authors[ref]) ? "" : first(split(first(rf.authors[ref]), ','))
    return "author = \"$author\", year = $(rf.year[ref])"
end

# After the data of a reference were added to `member`: the same work in the other databases, how
# many of the new points repeat theirs and how to see both. A notice only, nothing is left out.
function notify_repeats(
    db::Database,
    member::Member,
    ref::Integer,
    added::Integer,
    rules::DuplicateRules = DEFAULT_DUPLICATE_RULES,
)
    ds = member_dataset(member)
    key = work_key(ds, ref)
    mine = rows_of_references(ds, [ref])
    isempty(mine) && return nothing
    index, parts, where = Int[], DataView[], String[]
    for (i, other) in enumerate(db.members)
        if other === member
            push!(index, i)
            push!(parts, DataView(ds, mine))
            continue
        end
        other_ds = member_dataset(other)
        refs = references_of_work(other_ds, key)
        isempty(refs) && continue
        rows = rows_of_references(other_ds, refs)
        isempty(rows) && continue
        push!(index, i)
        push!(parts, DataView(other_ds, rows))
        push!(where, "\"$(other.name)\" ($(length(rows)) points)")
    end
    isempty(where) && return nothing
    report, _ = find_repeats(db, index, parts, rules)
    # How many of the new points are in a repeated pair, whichever side they are on.
    mine_rows = Set{Int32}()
    for k in eachindex(report.kind)
        report.kind[k] === :duplicate || continue
        report.database[k] == member.name && push!(mine_rows, report.row[k])
        report.other_database[k] == member.name && push!(mine_rows, report.other_row[k])
    end
    n_conflicts = count(==(:conflict), report.kind)
    filter = work_filter_text(ds, ref)
    work = isempty(key.label) ? "reference $ref" : key.label
    @warn "The data of this work are also in $(join(where, ", ")); nothing was removed or changed" work added_points =
        added repeated_points = length(mine_rows) conflicts = n_conflicts see_both = "points(db; $filter)" one_copy = "points(db; $filter, duplicate = false)" pairs = "duplicates(db; $filter)" disagreements = "conflicts(db; $filter)"
    return nothing
end
