# Combining selections. A `DataView` is a dataset and the rows of it that were kept, so the union,
# the intersection and the difference of two selections of the same dataset are merges of two sorted
# lists of rows: linear in their length, nothing of the data is copied.

# The rows of a view as a strictly increasing list (a range or a vector): a selection made by
# `points` is already one, and a list that was given by hand is sorted and made unique.
function ordered_rows(rows::UnitRange{Int32})
    return rows
end
function ordered_rows(rows::Vector{Int32})
    strict = true
    for k = 1:(length(rows)-1)
        rows[k] < rows[k+1] || (strict = false; break)
    end
    return strict ? rows : unique!(sort(rows))
end

# `op` is :union, :intersect or :setdiff.
function merge_rows(op::Symbol, a::AbstractVector{Int32}, b::AbstractVector{Int32})
    na, nb = length(a), length(b)
    out = Int32[]
    sizehint!(out, op === :union ? na + nb : (op === :setdiff ? na : min(na, nb)))
    i = j = 1
    while i <= na && j <= nb
        x, y = a[i], b[j]
        if x < y
            op === :intersect || push!(out, x)
            i += 1
        elseif y < x
            op === :union && push!(out, y)
            j += 1
        else
            op === :setdiff || push!(out, x)
            i += 1
            j += 1
        end
    end
    if op !== :intersect
        while i <= na
            push!(out, a[i])
            i += 1
        end
    end
    if op === :union
        while j <= nb
            push!(out, b[j])
            j += 1
        end
    end
    return out
end

function combine_views(op::Symbol, a::DataView, b::DataView)
    a.dataset === b.dataset || throw(
        ArgumentError(
            "the two selections are of different datasets; only selections of the same dataset can be combined",
        ),
    )
    return DataView(a.dataset, merge_rows(op, ordered_rows(a.rows), ordered_rows(b.rows)))
end

function combine_views(op::Symbol, a::DatabaseView, b::DatabaseView)
    a.database === b.database || throw(
        ArgumentError(
            "the two selections are of different databases; only selections of the same database can be combined",
        ),
    )
    in_a = Dict(zip(a.index, a.parts))
    in_b = Dict(zip(b.index, b.parts))
    index, parts = Int[], DataView[]
    for m in sort!(collect(union(keys(in_a), keys(in_b))))
        pa, pb = get(in_a, m, nothing), get(in_b, m, nothing)
        part =
            pa === nothing ? (op === :union ? pb : nothing) :
            pb === nothing ? (op === :intersect ? nothing : pa) : combine_views(op, pa, pb)
        (part === nothing || isempty(part)) && continue
        push!(index, m)
        push!(parts, part)
    end
    return DatabaseView(a.database, index, parts)
end

function combine_views(
    ::Symbol,
    ::Union{DataView,DatabaseView},
    ::Union{DataView,DatabaseView},
)
    throw(
        ArgumentError(
            "a selection of one dataset (`DataView`) and a selection of a database (`DatabaseView`) cannot be combined; make both with `points` on the same kind of source",
        ),
    )
end

const Selection = Union{DataView,DatabaseView}

"""
    union(a, b; duplicate = false)
    a ∪ b

The points that are in the selection `a` or in `b`, each once. `a` and `b` are selections made with
[`points`](@ref) of the same dataset ([`DataView`](@ref)) or of the same database
([`DatabaseView`](@ref)), and the result is a selection like any other: [`points`](@ref) refines it,
[`table`](@ref) gives its columns. It is the way to put together data that one set of filters cannot
reach, such as the points of pure `n`-hexane and the points of mixtures that end at `x1 = 1`
([`pure_component`](@ref) does exactly that):

```julia
pure = points(db; component = "n-hexane", pure = true, property = "Thermal conductivity")
limit = points(db; component = "n-hexane", property = "Thermal conductivity",
               fraction = "n-hexane" => (0.9999, 1))
both = pure ∪ limit                       # the same as union(pure, limit)
points(both; temperature = (290, 310))    # and filter again
```

More than two selections are accepted, `union(a, b, c)`. The merge is linear in the number of
points and does not copy any data; the result is ordered by row. With selections of a database, the
points that two databases hold both are left out like [`points`](@ref) does (the one of the
database with the higher priority is kept): `duplicate = true` keeps them, and a
[`DuplicateRules`](@ref) chooses the tolerances. `∪` is typed `\\cup` and Tab. See also
`intersect` and `setdiff`.
"""
function Base.union(a::Selection, b::Selection; duplicate = false)
    result = combine_views(:union, a, b)
    return result isa DatabaseView ? apply_duplicate(result, duplicate) : result
end

function Base.union(a::Selection, b::Selection, c::Selection, more::Selection...; kwargs...)
    return union(union(a, b; kwargs...), c, more...; kwargs...)
end

"""
    intersect(a, b)
    a ∩ b

The points that are in both selections `a` and `b` (see `union` for what a
selection is). It shows what two sets of filters have in common, for example which points of
one author are also in a temperature range, or which points two different searches found: the
overlap that a literature review has to count once.

```julia
by_author = points(db; component = "water", author = "silva")
in_range = points(db; component = "water", temperature = (280, 300))
common = by_author ∩ in_range            # the same as intersect(by_author, in_range)
```

More than two selections are accepted, `intersect(a, b, c)`. The result is a selection that can be
refined and tabulated, it keeps the order of the rows and does not copy any data. `∩` is typed
`\\cap` and Tab; it binds tighter than `∪`, so `a ∪ b ∩ c` is `a ∪ (b ∩ c)`.
"""
function Base.intersect(a::Selection, b::Selection)
    return combine_views(:intersect, a, b)
end

function Base.intersect(a::Selection, b::Selection, c::Selection, more::Selection...)
    return intersect(intersect(a, b), c, more...)
end

"""
    setdiff(a, b)

The points that are in the selection `a` and not in `b` (see `union` for what a selection
is). It leaves out of a search what
another one already holds, and tells where the points of a combined selection came from:

```julia
k = pure_component(db, "n-hexane")
from_mixtures = setdiff(k, points(db; component = "n-hexane", pure = true))
```

Julia has no symbol for it. The result is a selection that can be refined and tabulated; it
does not copy any data.
"""
function Base.setdiff(a::Selection, b::Selection)
    return combine_views(:setdiff, a, b)
end

# ----------------------------------------------------------------------------------
# The points of a pure compound, wherever the data were measured
# ----------------------------------------------------------------------------------

# The kinds of composition that are fractions (mole, mass), by the number the experiments keep.
function fraction_kind_mask(ds::Dataset)
    mask = falses(length(ds.kinds) + 1)
    for (i, text) in enumerate(ds.kinds.strings)
        mask[i+1] = occursin("fraction", lowercase(text))
    end
    return mask
end

# Whether the point `r`, of a system that holds the compound at `position`, is that compound alone:
# its amount is 1 within `tol`, or it is not given and the amounts of all the others are 0 within
# `tol` in total (a table of binary mixtures gives `x1` and ends at `x1 = 0`, the pure second
# compound). Only amounts that are fractions say anything about it.
function is_alone(
    ex::ExperimentTable,
    m::MeasurementTable,
    fractions::BitVector,
    e::Integer,
    r::Integer,
    position::Integer,
    tol::Float64,
)
    n = Int(ex.ncomp[e])
    amount = m.composition[position][r]
    if isfinite(amount)
        return fractions[ex.kinds[position][e]+1] && amount >= 1 - tol
    end
    total = 0.0
    for i = 1:n
        i == position && continue
        other = m.composition[i][r]
        (isfinite(other) && fractions[ex.kinds[i][e]+1]) || return false
        total += other
    end
    return n > 1 && total <= tol
end

function alone_rows(base::DataView, group, tol::Float64)
    ds = base.dataset
    ex, m = ds.experiments, ds.measurements
    fractions = fraction_kind_mask(ds)
    rows = Int32[]
    sizehint!(rows, min(length(base.rows), MAX_ROWS_HINT))
    for r in base.rows
        e = m.experiment[r]
        if ex.ncomp[e] == 1
            push!(rows, r)
        else
            position = Int(position_of(ex, group, e))
            position == 0 && continue
            is_alone(ex, m, fractions, e, r, position, tol) && push!(rows, r)
        end
    end
    return DataView(ds, rows)
end

const PURE_COMPONENT_RESERVED = (:pure, :exact, :match, :fraction, :xkind, :component)

function check_pure_component(component, tol, kwargs)
    for key in keys(kwargs)
        key in PURE_COMPONENT_RESERVED && throw(
            ArgumentError(
                "pure_component decides $key itself; the other keywords of `points` (property, temperature, ...) are accepted",
            ),
        )
    end
    (
        component isa AbstractString ||
        component isa Integer ||
        component isa CompoundMatches
    ) || throw(ArgumentError("give one compound (a name, a formula, an InChIKey...)"))
    (isfinite(tol) && 0 <= tol < 0.5) ||
        throw(ArgumentError("tol is a fraction between 0 and 0.5, got $tol"))
    return nothing
end

"""
    pure_component(source, component; tol = 1e-4, kwargs...) -> DataView or DatabaseView

All the points of `component` alone, wherever they were measured: the systems of one component
(`points(source; component, pure = true)`) and the points of mixtures in which the compound is the
whole system, which is how many articles report the pure compound, as the end of a table of
compositions. A point of a mixture is of the compound alone when

- the amount of the compound is a fraction (mole fraction, mass fraction) of at least `1 - tol`,
  wherever the compound sits in the system (`x1`, `x2` or `x3`), or
- the amount of the compound is not given, and the amounts of all the other components, which
  are fractions, are given and add up to at most `tol` (the table has `x1` and ends at `x1 = 0`:
  the other compound is pure).

Amounts that are not fractions (molality, concentrations) never qualify, and a point whose
composition is not enough to tell is left out. The result is one selection, without the points that
two databases hold both (and that were entered twice in one), as [`points`](@ref) leaves them out;
with a `Database`, `duplicate = true` keeps them. Every other keyword of [`points`](@ref)
(`property`, `temperature`, `doi`, ...) refines the result.

```julia
k = pure_component(db, "n-hexane"; property = "Thermal conductivity")
only_mixtures = setdiff(k, points(db; component = "n-hexane", pure = true))   # where it came from
```
"""
function pure_component(
    source::Union{Dataset,DataView},
    component;
    tol::Real = 1e-4,
    kwargs...,
)
    check_pure_component(component, tol, kwargs)
    view = source isa Dataset ? DataView(source) : source
    base = points(view; component, kwargs...)
    return alone_rows(base, resolve_group(view.dataset, component), Float64(tol))
end

function pure_component(
    source::Union{Database,DatabaseView},
    component;
    tol::Real = 1e-4,
    duplicate = false,
    choose = :ask,
    online::Bool = false,
    input::IO = stdin,
    output::IO = stdout,
    kwargs...,
)
    check_pure_component(component, tol, kwargs)
    db = source isa Database ? source : source.database
    resolved, _ = resolve_inputs(db, component, nothing, choose, input, output, online)
    base = points(
        source;
        component = resolved,
        duplicate = true,
        choose,
        online,
        input,
        output,
        kwargs...,
    )
    index, parts = Int[], DataView[]
    for (m, part) in zip(base.index, base.parts)
        _, local_component = member_components(db.registry, m, resolved, :any, false)
        found = alone_rows(part, resolve_group(part.dataset, local_component), Float64(tol))
        isempty(found) && continue
        push!(index, m)
        push!(parts, found)
    end
    return apply_duplicate(DatabaseView(db, index, parts), duplicate)
end

# ----------------------------------------------------------------------------------
# How several selections overlap
# ----------------------------------------------------------------------------------

const MAX_OVERLAP_SETS = 16

"""
    Overlap

The result of [`overlap`](@ref): one row for each group of points that are in exactly the same
selections, with the columns `region` (the text that names the selections), `sets` (a matrix of
`Bool`, a row for each region and a column for each selection: `names` tells which), `points` and
`references` (how many of each the region has), and `selections`, the points of each region as a
[`DataView`](@ref) or [`DatabaseView`](@ref). `ov[i]` and `ov["a ∩ b"]` give the selection of one
region, and `length(ov)` is the number of regions that are not empty.
"""
struct Overlap{S<:Union{DataView,DatabaseView}}
    names::Vector{String}
    sizes::Vector{Int}
    region::Vector{String}
    sets::Matrix{Bool}
    points::Vector{Int}
    references::Vector{Int}
    selections::Vector{S}
end

Base.length(ov::Overlap) = length(ov.region)
Base.getindex(ov::Overlap, i::Integer) = ov.selections[i]
function Base.getindex(ov::Overlap, region::AbstractString)
    i = findfirst(==(region), ov.region)
    i === nothing && throw(
        ArgumentError(
            "no region \"$region\"; the regions are $(join(repr.(ov.region), ", "))",
        ),
    )
    return ov.selections[i]
end
Base.firstindex(::Overlap) = 1
Base.lastindex(ov::Overlap) = length(ov)
Base.iterate(ov::Overlap, i::Int = 1) = i > length(ov) ? nothing : (ov.selections[i], i + 1)

function Base.show(io::IO, ::MIME"text/plain", ov::Overlap)
    total = sum(ov.points; init = 0)
    println(io, "Overlap of ", length(ov.names), " selections: ", total, " points")
    for (name, size) in zip(ov.names, ov.sizes)
        println(io, "  ", rpad(name, 24), size, " points")
    end
    isempty(ov) && return nothing
    println(io, "\nPoints that are in exactly:")
    width = max(maximum(length, ov.region), 6)
    println(io, "  ", rpad("", width), lpad("points", 10), lpad("references", 12))
    for i in eachindex(ov.region)
        println(
            io,
            "  ",
            rpad(ov.region[i], width),
            lpad(ov.points[i], 10),
            lpad(ov.references[i], 12),
        )
    end
    return nothing
end
Base.isempty(ov::Overlap) = isempty(ov.region)
Base.show(io::IO, ov::Overlap) =
    print(io, "Overlap(", join(ov.names, ", "), "; ", length(ov), " regions)")

# The rows of each list placed by the selections that hold them: a table from the set of selections
# (one bit each) to the rows that are in exactly those, in the order of the dataset.
function split_regions(ds::Dataset, lists::Vector{Vector{Int32}})
    owner = zeros(UInt16, length(ds.measurements))
    for (s, rows) in enumerate(lists)
        bit = UInt16(1) << (s - 1)
        for r in rows
            owner[r] |= bit
        end
    end
    buckets = Dict{UInt16,Vector{Int32}}()
    for (s, rows) in enumerate(lists)
        earlier = (UInt16(1) << (s - 1)) - UInt16(1)
        for r in rows
            mask = owner[r]
            iszero(mask & earlier) || continue    # an earlier selection placed it
            push!(get!(Vector{Int32}, buckets, mask), r)
        end
    end
    return buckets
end

function count_references(ds::Dataset, rows::AbstractVector{Int32})
    ex, m = ds.experiments, ds.measurements
    seen = falses(length(ds.references))
    count = 0
    for r in rows
        ref = ex.reference[m.experiment[r]]
        if !seen[ref]
            seen[ref] = true
            count += 1
        end
    end
    return count
end

function region_label(names::Vector{String}, mask::UInt16)
    chosen = [names[s] for s in eachindex(names) if !iszero(mask & (UInt16(1) << (s - 1)))]
    return length(chosen) == 1 ? "only " * chosen[1] : join(chosen, " ∩ ")
end

# Regions in the order: only one selection, then two, ... and by selection within the same size.
function ordered_masks(masks)
    return sort!(collect(masks); by = m -> (count_ones(m), m))
end

function overlap_names(names, n::Integer)
    names === nothing && return string.(1:n)
    list = String.(collect(names))
    length(list) == n || throw(ArgumentError("$(length(list)) names for $n selections"))
    allunique(list) || throw(ArgumentError("the names of the selections must be different"))
    return list
end

function check_overlap(selections)
    n = length(selections)
    n >= 2 || throw(ArgumentError("overlap needs at least two selections"))
    n <= MAX_OVERLAP_SETS || throw(
        ArgumentError(
            "overlap takes up to $MAX_OVERLAP_SETS selections, got $n (the regions grow as 2^n)",
        ),
    )
    return n
end

function build_overlap(
    names::Vector{String},
    sizes::Vector{Int},
    masks::Vector{UInt16},
    selections::Vector{S},
    points::Vector{Int},
    references::Vector{Int},
) where {S}
    n = length(names)
    sets = [!iszero(mask & (UInt16(1) << (s - 1))) for mask in masks, s = 1:n]
    return Overlap{S}(
        names,
        sizes,
        [region_label(names, mask) for mask in masks],
        sets,
        points,
        references,
        selections,
    )
end

function overlap_views(names, views::Vector{DataView})
    n = check_overlap(views)
    ds = views[1].dataset
    all(v -> v.dataset === ds, views) || throw(
        ArgumentError(
            "the selections are of different datasets; only selections of the same dataset can be compared",
        ),
    )
    lists = [Vector{Int32}(collect(ordered_rows(v.rows))) for v in views]
    buckets = split_regions(ds, lists)
    masks = ordered_masks(keys(buckets))
    found = [DataView(ds, buckets[mask]) for mask in masks]
    return build_overlap(
        overlap_names(names, n),
        length.(lists),
        masks,
        found,
        [length(v) for v in found],
        [count_references(ds, v.rows) for v in found],
    )
end

function overlap_views(names, views::Vector{DatabaseView})
    n = check_overlap(views)
    db = views[1].database
    all(v -> v.database === db, views) || throw(
        ArgumentError(
            "the selections are of different databases; only selections of the same database can be compared",
        ),
    )
    members = sort!(collect(union(Set{Int}(), (Set(v.index) for v in views)...)))
    per_member = Dict{Int,Dict{UInt16,Vector{Int32}}}()
    datasets = Dict{Int,Dataset}()
    sizes = zeros(Int, n)
    for m in members
        lists = Vector{Vector{Int32}}(undef, n)
        for (s, v) in enumerate(views)
            i = findfirst(==(m), v.index)
            if i === nothing
                lists[s] = Int32[]
            else
                datasets[m] = v.parts[i].dataset
                lists[s] = Vector{Int32}(collect(ordered_rows(v.parts[i].rows)))
            end
            sizes[s] += length(lists[s])
        end
        per_member[m] = split_regions(datasets[m], lists)
    end
    masks = ordered_masks(union(Set{UInt16}(), (keys(b) for b in values(per_member))...))
    found = DatabaseView[]
    points, references = Int[], Int[]
    for mask in masks
        index, parts = Int[], DataView[]
        refs = 0
        for m in members
            rows = get(per_member[m], mask, nothing)
            rows === nothing && continue
            push!(index, m)
            push!(parts, DataView(datasets[m], rows))
            refs += count_references(datasets[m], rows)
        end
        push!(found, DatabaseView(db, index, parts))
        push!(points, sum(length, parts))
        push!(references, refs)
    end
    return build_overlap(overlap_names(names, n), sizes, masks, found, points, references)
end

"""
    overlap(a, b, more...; names = nothing) -> Overlap
    overlap(:name_a => a, :name_b => b, ...) -> Overlap

How several selections made with [`points`](@ref) share their points. The selections are of the
same dataset ([`DataView`](@ref)) or of the same database ([`DatabaseView`](@ref)), at least two and
up to $(MAX_OVERLAP_SETS). The answer has a row for each group of points that are in exactly the same
selections (only `a`, `a` and `b` but not `c`, all three, ...), with how many points and how many
references the group has, and the points of each group as a selection that can be refined with
[`points`](@ref) or tabulated with [`table`](@ref). Regions without points are left out.

A point is the same point when it is the same row of the database; the points that two databases
both hold are different rows (see [`duplicates`](@ref) for those). A selection of a database counts
its references by database.

```julia
ov = overlap(
    :hexane_papers => points(db; component = "n-hexane", author = "silva"),
    :infrared => points(db; component = "n-hexane", method = "infrared"),
    :high_pressure => points(db; component = "n-hexane", pressure = (10_000, nothing)),
)
ov                              # the table of regions
table(ov["infrared ∩ high_pressure"])   # the points of one region
ov[1]                           # the points that only the first selection has
```

It is one pass over the points of the selections, whatever their number, instead of the
`2^n - 1` combinations of `union`, `intersect` and `setdiff` that the same table
would need.
"""
function overlap(selections::Selection...; names = nothing)
    list = Selection[selections...]
    all(v -> v isa DataView, list) && return overlap_views(names, DataView[list...])
    all(v -> v isa DatabaseView, list) && return overlap_views(names, DatabaseView[list...])
    throw(
        ArgumentError(
            "a selection of one dataset (`DataView`) and a selection of a database (`DatabaseView`) cannot be compared; make all with `points` on the same kind of source",
        ),
    )
end

function overlap(first::Pair, more::Pair...)
    pairs = [first, more...]
    return overlap(
        (p.second for p in pairs)...;
        names = [String(string(p.first)) for p in pairs],
    )
end
