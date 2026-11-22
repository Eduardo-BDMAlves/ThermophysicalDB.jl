# The filters of `points` that look at one measurement beyond its experiment, its property and
# its conditions: phase, method, the kind of composition and the fraction of a compound, the
# value and the uncertainty. They are built once per call (a mask over a small pool, a list of
# limits for each property) so that a row costs a few array lookups; a call that does not use
# them pays one `nothing` test per row.

# ----------------------------------------------------------------------------------
# Text criteria: phase, method, xkind
# ----------------------------------------------------------------------------------

# A string is looked for inside the text (any case); a regular expression is matched; a list
# matches if any of its items does.
text_matcher(label::AbstractString) =
    (needle = lowercase(strip(label)); s -> occursin(needle, lowercase(s)))
text_matcher(pattern::Regex) = s -> occursin(pattern, s)
function text_matcher(list::AbstractVector)
    matchers = text_matcher.(list)
    return s -> any(m -> m(s), matchers)
end

# `nothing` without a criterion, else a mask over the identifiers of the pool, shifted by one:
# position `id + 1` is the answer for `id`, and position 1 is `NO_ID` (no text), which never matches.
function pool_mask(pool::StringPool, criterion, what::AbstractString)
    criterion === nothing && return nothing
    matcher = text_matcher(criterion)
    mask = falses(length(pool) + 1)
    for (i, text) in enumerate(pool.strings)
        mask[i+1] = matcher(text)
    end
    any(mask) || throw(ArgumentError("no $what matches $(repr(criterion))"))
    return mask
end

# ----------------------------------------------------------------------------------
# Fractions of a compound
# ----------------------------------------------------------------------------------

# One criterion on the amount of a compound: where it sits in each experiment (0 when it is not
# in it) and the limits.
struct FractionLimit
    position::Vector{UInt8}
    low::Float64
    high::Float64
end

fraction_items(item::Pair) = (item,)
fraction_items(items::AbstractVector{<:Pair}) = items
function fraction_items(other)
    throw(
        ArgumentError(
            "`fraction` is a pair such as \"methane\" => (0.2, 0.4), or a vector of them, got $other",
        ),
    )
end

function position_of(ex::ExperimentTable, group, e::Integer)
    for i = 1:Int(ex.ncomp[e])
        ex.components[i][e] in group && return UInt8(i)
    end
    return UInt8(0)
end

# Limits of a ratio (a fraction, a relative uncertainty): plain numbers, or quantities that are
# dimensionless, such as `2u"percent"` or `500u"ppm"`. A single number is the limit on both
# sides, like an integer in `bounds`.
const RATIO = UnitSpec("1", "1", "1")

ratio_limit(::Nothing, side::Float64) = side
function ratio_limit(x, ::Float64)
    return is_quantity(x) ? native_value(x, RATIO) : Float64(x)
end

function ratio_bounds(t::Tuple{Any,Any})
    low, high = ratio_limit(t[1], -Inf), ratio_limit(t[2], Inf)
    # Rounding noise of a converted quantity, as in `bounds`.
    is_quantity(t[1]) && (low = prevfloat(low, 4))
    is_quantity(t[2]) && (high = nextfloat(high, 4))
    return (low, high)
end
ratio_bounds(r::AbstractRange) = ratio_bounds((first(r), last(r)))
ratio_bounds(x::Real) = (Float64(x), Float64(x))
function ratio_bounds(x)
    throw(ArgumentError("expected a (low, high) tuple, a range or a number, got $x"))
end

function fraction_limits(ds::Dataset, fraction)
    fraction === nothing && return FractionLimit[]
    ex = ds.experiments
    limits = FractionLimit[]
    for (compound, range) in fraction_items(fraction)
        group = resolve_group(ds, compound)
        low, high = ratio_bounds(range)
        push!(
            limits,
            FractionLimit([position_of(ex, group, e) for e = 1:length(ex)], low, high),
        )
    end
    return limits
end

# The experiments that qualify by the compounds of `fraction` and by the kind of composition
# (`xkind`): the amount of a compound is read as that kind, so the kind of the compound is the one
# that counts; without a compound, any kind of the system. `nothing` when neither is given.
function composition_mask(ds::Dataset, limits, xkind)
    kind_ok = pool_mask(ds.kinds, xkind, "xkind")
    (isempty(limits) && kind_ok === nothing) && return nothing
    ex = ds.experiments
    mask = trues(length(ex))
    for e in eachindex(mask)
        for limit in limits
            mask[e] &= !iszero(limit.position[e])
        end
        kind_ok === nothing || (mask[e] &= kind_of_system_ok(ex, e, limits, kind_ok))
    end
    return mask
end

function kind_of_system_ok(ex::ExperimentTable, e::Integer, limits, kind_ok)
    isempty(limits) && return any(i -> kind_ok[ex.kinds[i][e]+1], 1:Int(ex.ncomp[e]))
    return all(limits) do limit
        position = limit.position[e]
        !iszero(position) && kind_ok[ex.kinds[position][e]+1]
    end
end

# ----------------------------------------------------------------------------------
# Value and uncertainty
# ----------------------------------------------------------------------------------

# The limits of a value or of an uncertainty as native numbers for each property, so that a row
# is compared as stored. A plain number is in the native unit of every property. A quantity of
# a units package, or a plain number with `unit` (text), is converted for each property whose unit
# has the same dimension; the other properties get NaN limits, which no value satisfies. The
# uncertainty is a difference, so its conversion has no offset.
struct PropertyLimits
    low::Vector{Float64}
    high::Vector{Float64}
end

function limit_in_native(x, side::Float64, spec, unit, difference::Bool)
    x === nothing && return side
    if unit === nothing && x isa Real
        return Float64(x)
    end
    spec === nothing && return NaN
    try
        if unit !== nothing
            affine = quantity_affine(spec, unit)
            affine === nothing && return NaN
            f = FloatAffine(affine)
            return difference ? Float64(x) * f.scale : f(Float64(x))
        end
        return difference ? native_difference(x, spec) : native_value(x, spec)
    catch err
        err isa ArgumentError || rethrow()
        return NaN
    end
end

function unit_text_of(unit)
    unit === nothing && return nothing
    unit isa Union{AbstractString,Symbol} && return String(unit)
    text = unit_text(backend_of(unit), unit)
    text === nothing && throw(ArgumentError("cannot read $unit as a unit"))
    return text
end

function property_limits(ds::Dataset, limit, unit, difference::Bool)
    limit === nothing && return nothing
    low, high = quantity_bounds(limit)
    quantity = is_quantity(low) || is_quantity(high)
    (unit !== nothing && quantity) &&
        throw(ArgumentError("give the limits as quantities or give `unit`, not both"))
    text = unit_text_of(unit)
    n = length(ds.properties)
    lows, highs = Vector{Float64}(undef, n), Vector{Float64}(undef, n)
    for p = 1:n
        spec = unit_spec(ds.properties.unit[p])
        lows[p] = limit_in_native(low, -Inf, spec, text, difference)
        highs[p] = limit_in_native(high, Inf, spec, text, difference)
    end
    # Rounding noise of a converted quantity, as in `bounds`.
    is_quantity(low) && (lows .= prevfloat.(lows, 4))
    is_quantity(high) && (highs .= nextfloat.(highs, 4))
    n > 0 &&
        !any(p -> !isnan(lows[p]) && !isnan(highs[p]), 1:n) &&
        throw(ArgumentError("no property has the dimension of the limits $(repr(limit))"))
    return PropertyLimits(lows, highs)
end

# (low, high) as given: either side may be `nothing` and a number or a quantity; a single
# number or a range is accepted like in `bounds`.
quantity_bounds(t::Tuple{Any,Any}) = (t[1], t[2])
quantity_bounds(r::AbstractRange) = (first(r), last(r))
quantity_bounds(x::Real) = (x, x)
function quantity_bounds(x)
    throw(ArgumentError("expected a (low, high) tuple, a range or a number, got $x"))
end

@inline within(l::PropertyLimits, p::Integer, x::Float64) = l.low[p] <= x <= l.high[p]

# The uncertainty at k = 2 of a row is `unc` times a factor that depends only on its coverage
# factor `k` or, without one, on its level of confidence: both are pooled, so the factors are
# computed once for the pool (see `k2_uncertainty`).
struct K2Factors
    k::Vector{Float64}
    level::Vector{Float64}
end

function K2Factors(m::MeasurementTable, policy::Symbol)
    k = Float64[2 / x for x in m.unc_k.pool]
    level = Float64[
        try
            expanded_uncertainty_k2(1.0, x; policy)
        catch err
            err isa ArgumentError || rethrow()
            NaN
        end for x in m.unc_level.pool
    ]
    return K2Factors(k, level)
end

# NaN when the row has no uncertainty or it cannot be taken to k = 2 without inventing data.
@inline function uncertainty_k2(f::K2Factors, m::MeasurementTable, r::Integer)
    unc = m.unc[r]
    isnan(unc) && return NaN
    kc = m.unc_k.codes[r]
    iszero(kc) || return unc * f.k[kc]
    lc = m.unc_level.codes[r]
    iszero(lc) && return NaN
    return unc * f.level[lc]
end

# ----------------------------------------------------------------------------------
# Everything in one place
# ----------------------------------------------------------------------------------

struct ExtraFilters
    phase::Union{Nothing,BitVector}
    method::Union{Nothing,BitVector}
    fractions::Vector{FractionLimit}
    value::Union{Nothing,PropertyLimits}
    uncertainty::Union{Nothing,PropertyLimits}
    relative::Union{Nothing,Tuple{Float64,Float64}}
    k2::Union{Nothing,K2Factors}
end

# `nothing` when no keyword of these filters was given.
function extra_filters(
    ds::Dataset,
    phase,
    method,
    fraction_list,
    value,
    uncertainty,
    relative,
    unit,
    policy,
)
    phase_ok = pool_mask(ds.phases, phase, "phase")
    method_ok = pool_mask(ds.methods, method, "method")
    value_limits = property_limits(ds, value, unit, false)
    uncertainty_limits = property_limits(ds, uncertainty, unit, true)
    relative_limits = relative === nothing ? nothing : ratio_bounds(relative)
    needs_k2 = uncertainty_limits !== nothing || relative_limits !== nothing
    factors = needs_k2 ? K2Factors(ds.measurements, policy) : nothing
    all(
            isnothing,
            (phase_ok, method_ok, value_limits, uncertainty_limits, relative_limits),
        ) &&
        isempty(fraction_list) &&
        return nothing
    return ExtraFilters(
        phase_ok,
        method_ok,
        fraction_list,
        value_limits,
        uncertainty_limits,
        relative_limits,
        factors,
    )
end

@inline function extra_ok(f::ExtraFilters, m::MeasurementTable, r::Integer)
    f.phase === nothing || f.phase[Int(m.phase[r])+1] || return false
    f.method === nothing || f.method[Int(m.method[r])+1] || return false
    p = m.property[r]
    f.value === nothing || within(f.value, p, m.value[r]) || return false
    return extra_uncertainty_ok(f, m, r, p) && fractions_ok(f.fractions, m, r)
end

@inline function extra_uncertainty_ok(f::ExtraFilters, m::MeasurementTable, r::Integer, p)
    f.k2 === nothing && return true
    u2 = uncertainty_k2(f.k2, m, r)
    f.uncertainty === nothing || within(f.uncertainty, p, u2) || return false
    f.relative === nothing && return true
    relative = u2 / abs(m.value[r])
    return f.relative[1] <= relative <= f.relative[2]
end

@inline function fractions_ok(
    limits::Vector{FractionLimit},
    m::MeasurementTable,
    r::Integer,
)
    isempty(limits) && return true
    e = m.experiment[r]
    for limit in limits
        x = m.composition[limit.position[e]][r]
        limit.low <= x <= limit.high || return false
    end
    return true
end

# ----------------------------------------------------------------------------------
# Which phases and methods there are
# ----------------------------------------------------------------------------------

# Points of each identifier of a pool (position `id + 1`), over the rows of a selection.
function pool_counts(pool::StringPool, codes, rows)
    counts = zeros(Int, length(pool) + 1)
    for r in rows
        counts[Int(codes[r])+1] += 1
    end
    return counts
end

function count_table(name::Symbol, pool::StringPool, counts::AbstractVector{<:Integer})
    order = [i for i in eachindex(pool.strings) if counts[i+1] > 0]
    sort!(order; by = i -> (-counts[i+1], pool.strings[i]))
    return NamedTuple{(name, :points)}((
        pool.strings[order],
        Int[counts[i+1] for i in order],
    ))
end

"""
    phases(source) -> NamedTuple

The phases that the points of a dataset, a selection ([`DataView`](@ref), [`DatabaseView`](@ref))
or a database have, as the columns `phase` and `points` (how many points state it), the most
frequent first. The text of a phase is what the keyword `phase` of [`points`](@ref) looks for;
points that state no phase are not counted.
"""
phases(view::DataView) = count_table(
    :phase,
    view.dataset.phases,
    pool_counts(view.dataset.phases, view.dataset.measurements.phase, view.rows),
)
phases(ds::Dataset) = phases(DataView(ds))

"""
    measurement_methods(source) -> NamedTuple

The measurement methods that the points of a dataset, a selection or a database have, as the
columns `method` and `points`, the most frequent first. The text of a method is what the keyword
`method` of [`points`](@ref) looks for; points that state no method are not counted. It is
not called `methods` because `Base.methods` already is.
"""
measurement_methods(view::DataView) = count_table(
    :method,
    view.dataset.methods,
    pool_counts(view.dataset.methods, view.dataset.measurements.method, view.rows),
)
measurement_methods(ds::Dataset) = measurement_methods(DataView(ds))

# What `measured_properties(...; search)` looks for in the label of a property: text that the
# label contains (any case), a regular expression, a predicate of the label, or a list of any.
search_matcher(text::AbstractString) =
    (needle = lowercase(strip(text)); p -> occursin(needle, lowercase(p)))
search_matcher(pattern::Regex) = p -> occursin(pattern, p)
search_matcher(predicate::Function) = p -> predicate(p)::Bool
function search_matcher(list::AbstractVector)
    matchers = search_matcher.(list)
    return p -> any(m -> m(p), matchers)
end

"""
    measured_properties(source; search = nothing) -> NamedTuple

The properties that the points of a dataset, a selection ([`DataView`](@ref),
[`DatabaseView`](@ref)) or a database have, as the columns `property` (the label that the
keyword `property` of [`points`](@ref) takes) and `points` (how many points have it), the most
frequent first. It lists names, not points.

`search` keeps the properties whose label matches: text that the label contains (any case:
`"critical"`), a `Regex`, a function of the label that returns `true` or `false`, or a vector of
any of these (a property is kept when any of them matches). A search that matches nothing gives
empty columns.

The column `property`, or the result itself, can be given to `points` to select all of them at
once:

```julia
critical = measured_properties(db; search = "critical")
points(db; component = "water", exact = true, property = critical.property)
points(db; property = critical)                  # the same
```
"""
function measured_properties(view::DataView; search = nothing)
    ds = view.dataset
    labels = ds.properties.label
    counts = zeros(Int, length(labels))
    codes = ds.measurements.property
    for r in view.rows
        counts[Int(codes[r])] += 1
    end
    keep = search === nothing ? Returns(true) : search_matcher(search)
    order = [i for i in eachindex(labels) if counts[i] > 0 && keep(labels[i])]
    sort!(order; by = i -> (-counts[i], labels[i]))
    return (
        property = String[labels[i] for i in order],
        points = Int[counts[i] for i in order],
    )
end
measured_properties(ds::Dataset; search = nothing) =
    measured_properties(DataView(ds); search)

# Several datasets have pools of their own: the counts are added by text.
function joined_count_table(name::Symbol, tables)
    totals = Dict{String,Int}()
    for t in tables, (text, n) in zip(first(t), last(t))
        totals[text] = get(totals, text, 0) + n
    end
    texts = sort!(collect(keys(totals)); by = s -> (-totals[s], s))
    return NamedTuple{(name, :points)}((texts, Int[totals[s] for s in texts]))
end
