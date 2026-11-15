# The table that `table` returns: columns, indexing like a data frame, iteration by rows and a
# summary when it is shown.

"""
    PointTable

The result of [`table`](@ref): the columns of a selection, one point per row, with the access of
a data frame. It wraps a `NamedTuple` of plain vectors (`parent(t)` gives it back), so
`t.temperature`, `keys(t)`, `DataFrame(t)` and every [Tables.jl](https://tables.juliadata.org)
consumer work, and nothing is copied until an index asks for a part.

```julia
t = table(v)
t[:temperature]            # the column itself (not a copy), as `t.temperature`
t[3]                       # the third row: a NamedTuple with every column
t[3, :temperature]         # the third temperature; also `t[:temperature, 3]`
t[3, 2]                    # row 3, the second column (by position)
t[1:5]                     # a PointTable with the first five rows
t[1:5, :temperature]       # the first five temperatures (a new vector)
t[1:5, [:temperature, :value]]   # a PointTable with those rows and columns
t[[:temperature, :value]]  # a PointTable with those columns
t[t.temperature .> 300]    # rows chosen by a Bool vector
for row in t
    @show row.temperature, row.value
end
```

`size(t)` is `(points, columns)` and `length(t)` the number of points. Iterating gives the rows
as `NamedTuple`s. A column is returned as the vector the table holds, so changing it changes the
table; asking for rows (a range, a vector, a mask, `:`) gives a copy. An index outside the
table is a `BoundsError`; a column that does not exist is an `ArgumentError` that lists the
columns.

Showing the table prints a summary (number of points, references, years, systems, ranges of the
conditions and of the values of each property) computed at that moment from the columns, then
the first points.
"""
struct PointTable{NT<:NamedTuple}
    columns::NT
    temperature_unit::String
    pressure_unit::String
    function PointTable(
        columns::NT,
        temperature_unit::AbstractString = "K",
        pressure_unit::AbstractString = "kPa",
    ) where {NT<:NamedTuple}
        allequal(map(length, values(columns))) ||
            throw(ArgumentError("the columns of a table must have the same length"))
        return new{NT}(columns, String(temperature_unit), String(pressure_unit))
    end
end

# The columns, as the `NamedTuple` the table was built from.
Base.parent(t::PointTable) = getfield(t, :columns)

nrows(t::PointTable) = isempty(parent(t)) ? 0 : length(first(parent(t)))
ncols(t::PointTable) = length(parent(t))

# The same units for the table made of some of the rows or columns of `t`.
with_columns(t::PointTable, columns::NamedTuple) =
    PointTable(columns, getfield(t, :temperature_unit), getfield(t, :pressure_unit))

# ----------------------------------------------------------------------------------
# Names and sizes
# ----------------------------------------------------------------------------------

# Two tables are equal when they have the same columns and units.
same_units(a::PointTable, b::PointTable) =
    getfield(a, :temperature_unit) == getfield(b, :temperature_unit) &&
    getfield(a, :pressure_unit) == getfield(b, :pressure_unit)
Base.:(==)(a::PointTable, b::PointTable) = parent(a) == parent(b) && same_units(a, b)
Base.isequal(a::PointTable, b::PointTable) =
    isequal(parent(a), parent(b)) && same_units(a, b)
Base.hash(t::PointTable, h::UInt) = hash(
    parent(t),
    hash(getfield(t, :temperature_unit), hash(getfield(t, :pressure_unit), h)),
)

Base.keys(t::PointTable) = keys(parent(t))
Base.propertynames(t::PointTable, private::Bool = false) = keys(parent(t))
Base.haskey(t::PointTable, name::Symbol) = haskey(parent(t), name)
Base.size(t::PointTable) = (nrows(t), ncols(t))
Base.size(t::PointTable, d::Integer) =
    d == 1 ? nrows(t) :
    d == 2 ? ncols(t) : d > 2 ? 1 : throw(ArgumentError("dimension must be >= 1"))
Base.length(t::PointTable) = nrows(t)
Base.isempty(t::PointTable) = nrows(t) == 0
Base.firstindex(::PointTable) = 1
Base.lastindex(t::PointTable) = nrows(t)
Base.lastindex(t::PointTable, d::Integer) = size(t, d)

function unknown_column(t::PointTable, name::Symbol)
    text = String(name)
    close = [
        String(k) for k in keys(t) if occursin(text, String(k)) ||
            occursin(String(k), text) ||
            startswith(String(k), first(text, 1))
    ]
    shown = isempty(close) ? [String(k) for k in keys(t)] : close
    return ArgumentError(
        "the table has no column :$name; " *
        (isempty(close) ? "the columns are " : "close names are ") *
        join(map(s -> ":" * s, shown), ", "),
    )
end

@inline function Base.getproperty(t::PointTable, name::Symbol)
    columns = parent(t)
    haskey(columns, name) || throw(unknown_column(t, name))
    return getfield(columns, name)
end

@inline function column(t::PointTable, name::Symbol)
    columns = parent(t)
    haskey(columns, name) || throw(unknown_column(t, name))
    return getfield(columns, name)
end

function column(t::PointTable, j::Integer)
    1 <= j <= ncols(t) || throw(BoundsError(t, (:, j)))
    return parent(t)[j]
end

# ----------------------------------------------------------------------------------
# Rows
# ----------------------------------------------------------------------------------

# The row `i` as a `NamedTuple`.
@inline function row(t::PointTable, i::Integer)
    1 <= i <= nrows(t) || throw(BoundsError(t, i))
    return map(c -> @inbounds(c[i]), parent(t))
end

# The rows asked for as something every column accepts, checked once for the whole table.
function row_selector(t::PointTable, rows::AbstractVector{<:Integer})
    n = nrows(t)
    if eltype(rows) === Bool
        length(rows) == n || throw(
            DimensionMismatch("the mask has $(length(rows)) entries, the table $n points"),
        )
        return rows
    end
    ok =
        rows isa AbstractUnitRange ?
        isempty(rows) || (first(rows) >= 1 && last(rows) <= n) : all(i -> 1 <= i <= n, rows)
    ok || throw(BoundsError(t, rows))
    return rows
end
row_selector(t::PointTable, ::Colon) = Base.OneTo(nrows(t))

Base.eltype(::Type{PointTable{NT}}) where {NT} =
    NamedTuple{fieldnames(NT),Tuple{map(eltype, fieldtypes(NT))...}}
Base.IteratorSize(::Type{<:PointTable}) = Base.HasLength()

function Base.iterate(t::PointTable, i::Int = 1)
    i > nrows(t) && return nothing
    return (row(t, i), i + 1)
end

# ----------------------------------------------------------------------------------
# Indexing
# ----------------------------------------------------------------------------------

const RowIndices = Union{AbstractVector{<:Integer},Colon}

# One argument: a column, a row, some rows or some columns.
Base.getindex(t::PointTable, name::Symbol) = column(t, name)
Base.getindex(t::PointTable, i::Integer) = row(t, i)

function Base.getindex(t::PointTable, rows::AbstractVector{<:Integer})
    selector = row_selector(t, rows)
    return with_columns(t, map(c -> c[selector], parent(t)))
end

function Base.getindex(t::PointTable, names::AbstractVector{Symbol})
    foreach(name -> column(t, name), names)
    return with_columns(
        t,
        NamedTuple{Tuple(names)}(map(name -> column(t, name), Tuple(names))),
    )
end

# Two arguments: (row, column) as in a data frame, and (column, row) as the other way round.
Base.getindex(t::PointTable, i::Integer, name::Symbol) = column(t, name)[checked_row(t, i)]
Base.getindex(t::PointTable, name::Symbol, i::Integer) = column(t, name)[checked_row(t, i)]
Base.getindex(t::PointTable, i::Integer, j::Integer) = column(t, j)[checked_row(t, i)]
Base.getindex(t::PointTable, i::Integer, ::Colon) = row(t, i)

function checked_row(t::PointTable, i::Integer)
    1 <= i <= nrows(t) || throw(BoundsError(t, i))
    return i
end

Base.getindex(t::PointTable, rows::RowIndices, name::Symbol) =
    column(t, name)[row_selector(t, rows)]
Base.getindex(t::PointTable, name::Symbol, rows::AbstractVector{<:Integer}) =
    column(t, name)[row_selector(t, rows)]
Base.getindex(t::PointTable, rows::RowIndices, j::Integer) =
    column(t, j)[row_selector(t, rows)]

function Base.getindex(t::PointTable, rows::RowIndices, names::AbstractVector{Symbol})
    selector = row_selector(t, rows)
    selected =
        NamedTuple{Tuple(names)}(map(name -> column(t, name)[selector], Tuple(names)))
    return with_columns(t, selected)
end

# ----------------------------------------------------------------------------------
# Tables.jl
# ----------------------------------------------------------------------------------

Tables.istable(::Type{<:PointTable}) = true
Tables.columnaccess(::Type{<:PointTable}) = true
Tables.columns(t::PointTable) = parent(t)
Tables.schema(t::PointTable) = Tables.schema(parent(t))

# ----------------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------------

# The smallest and largest finite entries of a column of numbers or quantities, and how many
# there are; `nothing` when there is none.
function finite_range(values)
    lo = hi = nothing
    count = 0
    for v in values
        isfinite(v) || continue
        count += 1
        if lo === nothing
            lo = hi = v
        else
            v < lo && (lo = v)
            v > hi && (hi = v)
        end
    end
    return lo === nothing ? nothing : (lo, hi, count)
end

range_text(::Nothing) = ""
function range_text(range)
    lo, hi, _ = range
    return lo == hi ? display_cell(lo) : display_cell(lo) * " – " * display_cell(hi)
end

# The groups of equal text of a column, in order of first appearance, with their sizes. The text
# of consecutive points of one system or property is usually the same string object, which
# skips the hashing.
function count_groups(column::AbstractVector{String})
    index = Dict{String,Int}()
    names = String[]
    counts = Int[]
    last_text = ""
    last_group = 0
    for text in column
        if last_group != 0 && text === last_text
            counts[last_group] += 1
            continue
        end
        group = get!(index, text) do
            push!(names, text)
            push!(counts, 0)
            length(names)
        end
        counts[group] += 1
        last_text = text
        last_group = group
    end
    return names, counts
end

# The ranges of `value` for every pair of property and unit.
function value_groups(t::PointTable)
    properties, units, values = t.property, t.unit, t.value
    index = Dict{Tuple{String,String},Int}()
    names = Tuple{String,String}[]
    counts = Int[]
    ranges = Any[]
    last_property = ""
    last_unit = ""
    last_group = 0
    for i in eachindex(values)
        group = last_group
        if last_group == 0 || properties[i] !== last_property || units[i] !== last_unit
            key = (properties[i], units[i])
            group = get!(index, key) do
                push!(names, key)
                push!(counts, 0)
                push!(ranges, nothing)
                length(names)
            end
            last_property, last_unit, last_group = properties[i], units[i], group
        end
        counts[group] += 1
        v = values[i]
        isfinite(v) || continue
        range = ranges[group]
        ranges[group] =
            range === nothing ? (v, v, 1) :
            (v < range[1] ? v : range[1], v > range[2] ? v : range[2], range[3] + 1)
    end
    return names, counts, ranges
end

const SUMMARY_GROUPS = 6

function print_summary(io::IO, t::PointTable)
    n = nrows(t)
    println(io, "PointTable: ", n, " points × ", ncols(t), " columns")
    n == 0 && return nothing
    lines = Pair{String,String}[]
    if haskey(t, :doi)
        dois = Set{String}()
        last = ""
        for doi in t.doi
            doi === last && continue
            push!(dois, doi)
            last = doi
        end
        years = haskey(t, :year) ? finite_range(y for y in t.year if y > 0) : nothing
        text = string(length(dois), " (distinct DOIs)")
        if years !== nothing
            text *=
                years[1] == years[2] ? ", published in $(years[1])" :
                ", published $(years[1])–$(years[2])"
        end
        push!(lines, "references" => text)
    end
    if haskey(t, :database)
        names, counts = count_groups(t.database)
        push!(
            lines,
            "databases" => join(("$name ($c)" for (name, c) in zip(names, counts)), ", "),
        )
    end
    if haskey(t, :components)
        names, counts = count_groups(t.components)
        order = sortperm(counts; rev = true)
        shown = ["$(names[k]) ($(counts[k]))" for k in first(order, SUMMARY_GROUPS)]
        more = length(order) - length(shown)
        push!(
            lines,
            "systems" => "$(join(shown, ", "))$(more > 0 ? ", … and $more more" : "")",
        )
    end
    for (name, label) in (
        (:temperature, "T [" * getfield(t, :temperature_unit) * "]"),
        (:pressure, "p [" * getfield(t, :pressure_unit) * "]"),
        (:x1, "x1"),
        (:x2, "x2"),
        (:x3, "x3"),
    )
        haskey(t, name) || continue
        text = range_text(finite_range(column(t, name)))
        isempty(text) || push!(lines, label => text)
    end
    width = maximum(length ∘ first, lines; init = 0)
    for (label, text) in lines
        println(io, "  ", rpad(label, width), "  ", text)
    end
    if haskey(t, :value) && haskey(t, :property) && haskey(t, :unit)
        names, counts, ranges = value_groups(t)
        order = sortperm(counts; rev = true)
        println(io, "  values by property and unit:")
        shown = first(order, SUMMARY_GROUPS)
        property_width = maximum(k -> length(display_cell(names[k][1])), shown)
        unit_width = maximum(k -> length(names[k][2]), shown)
        count_width = maximum(k -> length(string(counts[k])), shown)
        for k in shown
            property, unit = names[k]
            println(
                io,
                "    ",
                rpad(display_cell(property), property_width),
                "  [",
                rpad(unit * "]", unit_width + 1),
                "  ",
                lpad(counts[k], count_width),
                counts[k] == 1 ? " point   " : " points  ",
                range_text(ranges[k]),
            )
        end
        more = length(order) - SUMMARY_GROUPS
        more > 0 && println(io, "    … and ", more, " more")
    end
    return nothing
end

function Base.show(io::IO, t::PointTable)
    return print(io, "PointTable(", nrows(t), " points × ", ncols(t), " columns)")
end

function Base.show(io::IO, ::MIME"text/plain", t::PointTable; maxrows::Int = 8)
    print_summary(io, t)
    n = nrows(t)
    n == 0 && return nothing
    shown = min(n, maxrows)
    println(io)
    print_points(io, t, shown, n - shown)
    return nothing
end
