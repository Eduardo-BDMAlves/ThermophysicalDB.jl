# Sorting the points of a selection: by keywords of `table`, before the columns are built, or on
# a `PointTable` that already exists.
#
# The order is stable (equal keys keep the order they had) and the points without a value for a
# key (`NaN`, an empty text, an unknown year) always go last, whichever the direction. A sort by
# several keys is done key by key, from the last to the first, each time with a stable sort, so
# every pass is a plain `sortperm` of one column.

const SORT_DIRECTIONS = (:asc, :desc)

# Keys that are not a column of the table but are computed from columns.
const VIRTUAL_SORT_KEYS = (:relative_unc,)

# Keys that can be read from the data without building the table. The order of a column does not
# change with the conversion of its unit (the scale of a unit is positive), so they are sorted
# with the native numbers; `value`, `unc` and `unc_k2` use the same conversion as the table.
const PRESORT_KEYS = (
    :year,
    :doi,
    :source,
    :property,
    :method,
    :phase,
    :temperature,
    :pressure,
    :value,
    :unc,
    :unc_k,
    :unc_level,
    :unc_k2,
    :relative_unc,
)

# Columns where a number says "not given" instead of `NaN`.
const UNKNOWN_BELOW = (year = 1, digits = 0, temperature_digits = 0, pressure_digits = 0)

# Columns of values that are compared by their number only when the unit is the same.
const UNIT_DEPENDENT_KEYS = (:value, :unc, :unc_k2)

struct SortKey
    name::Symbol
    descending::Bool
end

# ----------------------------------------------------------------------------------
# What `by` accepts
# ----------------------------------------------------------------------------------

function sort_key(name::Symbol, rev::Bool)
    return SortKey(name, rev)
end

function sort_key(entry::Pair, rev::Bool)
    name, direction = first(entry), last(entry)
    name isa Symbol ||
        throw(ArgumentError("a sort key is a column name, got $(repr(name))"))
    direction in SORT_DIRECTIONS || throw(
        ArgumentError(
            "the direction of a sort key is :asc or :desc, got $(repr(direction))",
        ),
    )
    return SortKey(name, direction === :desc)
end

function sort_key(entry, ::Bool)
    throw(
        ArgumentError(
            "a sort key is a column name (:temperature) or a pair with a direction " *
            "(:temperature => :desc), got $(repr(entry))",
        ),
    )
end

# `by` is one key or a list of keys; `rev` is the direction of the keys given without one.
function sort_keys(by, rev::Bool)
    keys = if by isa Union{Symbol,Pair}
        [sort_key(by, rev)]
    elseif by isa Union{AbstractVector,Tuple}
        [sort_key(entry, rev) for entry in by]
    else
        throw(
            ArgumentError(
                "`sortby` is a column name, a pair or a list of them, got $(repr(by))",
            ),
        )
    end
    isempty(keys) && throw(ArgumentError("the list of sort keys is empty"))
    return keys
end

# ----------------------------------------------------------------------------------
# The sort
# ----------------------------------------------------------------------------------

# A point without a value for the key.
missing_entry(::Any) = false
missing_entry(x::Number) = isnan(x)
missing_entry(x::AbstractString) = isempty(x)

# One pass: the order of the entries of `perm` by `column`, stable, the missing ones last. The
# first pass (`perm === nothing`) of a column with nothing missing is one `sortperm`.
function order_pass(::Nothing, column::AbstractVector, descending::Bool)
    any(missing_entry, column) || return sortperm(column; rev = descending)
    return order_pass(collect(eachindex(column)), column, descending)
end

function order_pass(perm::Vector{Int}, column::AbstractVector, descending::Bool)
    present = Int[]
    absent = Int[]
    sizehint!(present, length(perm))
    @inbounds for i in perm
        push!(missing_entry(column[i]) ? absent : present, i)
    end
    order = sortperm(column[present]; rev = descending)
    result = present[order]
    append!(result, absent)
    return result
end

function sorted_order(columns, keys::Vector{SortKey})
    perm = nothing
    for j = length(keys):-1:1
        perm = order_pass(perm, columns[j], keys[j].descending)
    end
    return perm
end

# A warning when a comparison of numbers with different units is asked for: 1 kg/m3 is not
# smaller than 2 kPa. `distinct_units` is called only when it is needed.
function warn_if_mixed_units(keys::Vector{SortKey}, distinct_units)
    for key in keys
        key.name in (:property, :unit) && return nothing
        key.name in UNIT_DEPENDENT_KEYS || continue
        distinct_units() > 1 && @warn(
            "the points have properties with different units, so a sort by :$(key.name) " *
            "compares unlike numbers; put :property before it or use :relative_unc",
        )
        return nothing
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# A table that exists
# ----------------------------------------------------------------------------------

known_entries(column, limit::Integer) =
    Float64[x >= limit ? Float64(x) : NaN for x in column]

# Uncertainty over the size of the value, without a unit; the same sort key for any property.
function relative_uncertainty(t::PointTable)
    (haskey(t, :unc_k2) && haskey(t, :value)) ||
        throw(ArgumentError(":relative_unc needs the columns :unc_k2 and :value"))
    return map((u, v) -> u / abs(v), t.unc_k2, t.value)
end

function sort_column(t::PointTable, name::Symbol)
    name === :relative_unc && return relative_uncertainty(t)
    column = getproperty(t, name)
    limit = get(UNKNOWN_BELOW, name, nothing)
    return limit === nothing ? column : known_entries(column, limit)
end

function distinct_units(t::PointTable)
    haskey(t, :unit) || return 1
    return length(Set(t.unit))
end

"""
    sortperm(t::PointTable; by, rev = false) -> Vector{Int}

The order of the points of `t` for `sort(t; by, rev)`, without building the sorted table. `by` is
a column name (`:temperature`), a pair with a direction (`:unc_k2 => :desc`) or a list of them
(`[:property, :temperature]`); `rev` is the direction of the keys given without one. See `sort`.
"""
function Base.sortperm(t::PointTable; by, rev::Bool = false)
    keys = sort_keys(by, rev)
    columns = [sort_column(t, key.name) for key in keys]
    warn_if_mixed_units(keys, () -> distinct_units(t))
    return sorted_order(columns, keys)
end

"""
    sort(t::PointTable; by, rev = false) -> PointTable

A table with the points of `t` sorted by the keys `by`: a column name (`:temperature`), a pair
with a direction (`:unc_k2 => :desc`) or a list of them, where the first key is the most
important (`[:property, :temperature]`). `rev = true` reverses the keys given without a
direction. The sort is stable, and the points that have no value for a key (`NaN`, an empty
text, an unknown year or number of digits) go last, in both directions.

`:relative_unc` is a key that is not a column: `unc_k2 / abs(value)`, a number without a unit,
so it compares the uncertainty of points of different properties. Sorting by `:value`, `:unc` or
`:unc_k2` without `:property` before it gives a warning when the points have different units.

The table is not changed; [`sort!`](@ref Base.sort!(::ThermophysicalDB.PointTable)) sorts it in
place. To sort the selection before the columns are built, which needs less memory and time,
give `sortby` and `rev` to [`table`](@ref).

```julia
t = table(v)
sort(t; by = :temperature)
sort(t; by = [:property, :temperature => :desc])
sort(t; by = :relative_unc)[1:10]     # the ten points with the smallest relative uncertainty
```
"""
function Base.sort(t::PointTable; by, rev::Bool = false)
    perm = sortperm(t; by, rev)
    return with_columns(t, map(column -> column[perm], parent(t)))
end

# The entries of `column` in the order of `perm`, in place, through a buffer that the columns of
# the same type share.
function permute_column!(column::AbstractVector, perm::Vector{Int}, buffers::Dict)
    buffer = get!(() -> similar(column), buffers, typeof(column))::typeof(column)
    @inbounds for i in eachindex(perm)
        buffer[i] = column[perm[i]]
    end
    copyto!(column, buffer)
    return nothing
end

"""
    sort!(t::PointTable; by, rev = false) -> PointTable

Sorts the points of `t` in place, with the keys of [`sort`](@ref Base.sort(::ThermophysicalDB.PointTable)),
and returns `t`. It needs the order (8 bytes a point) and one spare column at a time instead of a
copy of the whole table, so it is the way to sort a table of millions of points.

It changes the columns of the table, which are the vectors that `t.temperature` returns, so a
column that you took from it is sorted too, and so is every other table that shares the column
(`t[[:temperature, :value]]` does; `t[1:10]` and `sort(t; by)` copy). The data of the database
are not touched: `table` copies them into columns of its own. A column that cannot be changed
(a range, for a table made by hand) is an `ArgumentError` before anything is moved.

```julia
t = table(v)
sort!(t; by = [:property, :temperature])
```
"""
function Base.sort!(t::PointTable; by, rev::Bool = false)
    columns = parent(t)
    for (name, column) in pairs(columns)
        Base.ismutable(column) || throw(
            ArgumentError(
                "the column :$name cannot be changed in place; use `sort(t; by)`",
            ),
        )
    end
    perm = sortperm(t; by, rev)
    buffers = Dict{DataType,Any}()
    foreach(column -> permute_column!(column, perm, buffers), columns)
    return t
end

# ----------------------------------------------------------------------------------
# Before the table is built
# ----------------------------------------------------------------------------------

# The keys of the whole selection can be read from the data.
presortable(keys::Vector{SortKey}) = all(key -> key.name in PRESORT_KEYS, keys)

# The numbers of the table for `rows` and one key, computed as `table` does. `factor`, `offset`
# and `pressure_factor` are the conversions of the properties and of the pressure.
function presort_column(name::Symbol, ds, rows, factor, offset, pressure_factor, policy)
    m, ex, rf, pr = ds.measurements, ds.experiments, ds.references, ds.properties
    reference(r) = ex.reference[m.experiment[r]]
    name === :temperature && return Float64[m.temperature[r] for r in rows]
    name === :pressure && return Float64[
        pressure_factor == 1.0 ? m.pressure[r] :
        clean_float(m.pressure[r] * pressure_factor) for r in rows
    ]
    name === :year &&
        return Float64[(y = rf.year[reference(r)]; y >= 1 ? Float64(y) : NaN) for r in rows]
    name === :doi && return String[rf.doi[reference(r)] for r in rows]
    name === :source &&
        return String[pool_string(ds.sources, rf.source[reference(r)]) for r in rows]
    name === :property && return String[pr.label[m.property[r]] for r in rows]
    name === :method && return String[pool_string(ds.methods, m.method[r]) for r in rows]
    name === :phase && return String[pool_string(ds.phases, m.phase[r]) for r in rows]
    name === :unc_k && return Float64[m.unc_k[r] for r in rows]
    name === :unc_level && return Float64[m.unc_level[r] for r in rows]
    n = length(rows)
    out = Vector{Float64}(undef, n)
    for (i, r) in enumerate(rows)
        p = m.property[r]
        f = factor[p]
        o = offset[p]
        if name === :value
            out[i] = scaled_value(m.value[r], f, o)
        elseif name === :unc
            out[i] = f == 1.0 ? m.unc[r] : clean_float(m.unc[r] * f)
        else
            u2, _ = k2_uncertainty(m.unc[r], m.unc_k[r], m.unc_level[r], policy)
            u2 = f == 1.0 ? u2 : clean_float(u2 * f)
            out[i] = name === :unc_k2 ? u2 : u2 / abs(scaled_value(m.value[r], f, o))
        end
    end
    return out
end

# The number of different units of the points of `rows`, after the conversions of `table`.
function distinct_units(ds::Dataset, rows, unit_of)
    seen = falses(length(unit_of))
    m = ds.measurements
    for r in rows
        seen[m.property[r]] = true
    end
    return length(Set(unit_of[seen]))
end

# The rows of `view` in the order of the keys, as a vector. The `DataView` made of them is not in
# the ascending order that the set operations need, so it only goes to `table`.
function presorted_rows(
    view::DataView,
    keys::Vector{SortKey},
    factor,
    offset,
    unit_of,
    pressure_factor,
    policy,
)
    ds, rows = view.dataset, view.rows
    warn_if_mixed_units(keys, () -> distinct_units(ds, rows, unit_of))
    columns = [
        presort_column(key.name, ds, rows, factor, offset, pressure_factor, policy) for
        key in keys
    ]
    perm = sorted_order(columns, keys)
    return Vector{Int32}(rows[perm])
end

# The table that `table` ends with: sorted now, unless the rows were sorted before.
finish_sort(t::PointTable, ::Nothing, ::Bool, ::Bool) = t
finish_sort(t::PointTable, by, rev::Bool, presorted::Bool) =
    presorted ? t : sort(t; by, rev)
