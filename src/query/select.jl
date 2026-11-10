"""
    DataView(dataset, rows)

A lazy selection of measurements: it stores only the row numbers (`rows`, positions in
`dataset.measurements`) and never copies values. Refine it with [`points`](@ref) and turn
it into columns with [`table`](@ref). Because a view is just an index vector, chaining
filters costs one scan of the rows that survived the previous one.
"""
struct DataView
    dataset::Dataset
    rows::Vector{Int32}
end

DataView(ds::Dataset) = DataView(ds, collect(Int32(1):Int32(length(ds.measurements))))

Base.length(view::DataView) = length(view.rows)
Base.isempty(view::DataView) = isempty(view.rows)

# ----------------------------------------------------------------------------------
# Range arguments
# ----------------------------------------------------------------------------------

# Native units of the conditions in the tables: temperature in K, pressure in kPa.
# A bound is a plain number in that unit or a quantity of a units package whose extension is
# loaded (see `units/backend.jl`), so 25u"°C" or 1u"atm" work with Unitful.
native(x::Real, ::Nothing) = Float64(x)
native(x, kind::QuantityKind) = native_value(x, kind)
function native(x, ::Nothing)
    throw(ArgumentError("units are not accepted here, got $x"))
end

# Inclusive bounds as Float64. `nothing` leaves a side open: `(300, nothing)` is T >= 300.
bounds(::Nothing, unit = nothing) = (-Inf, Inf)
bounds(x::Integer, unit = nothing) = (Float64(x), Float64(x))
bounds(r::AbstractRange, unit = nothing) = (native(first(r), unit), native(last(r), unit))
function bounds(t::Tuple{Any,Any}, unit = nothing)
    lo = t[1] === nothing ? -Inf : native(t[1], unit)
    hi = t[2] === nothing ? Inf : native(t[2], unit)
    # Converted quantities carry rounding noise (20 °C -> 293.15000000000003 K); a few
    # ulps of slack keep a point that sits exactly on a limit.
    is_quantity(t[1]) && (lo = prevfloat(lo, 4))
    is_quantity(t[2]) && (hi = nextfloat(hi, 4))
    return (lo, hi)
end
function bounds(x, unit = nothing)
    throw(ArgumentError("expected a (low, high) tuple, a range or an integer, got $x"))
end

# ----------------------------------------------------------------------------------
# Resolving user text to rows of the small tables
# ----------------------------------------------------------------------------------

# Compounds matching one user string: InChIKey (any case), molecular formula (exact,
# because "CO" and "Co" differ) or any recorded name (any case).
# One group of acceptable compound ids per requested component. A component is a name,
# formula or InChIKey (see `matching_compounds`), a compound id, or the result of
# `find_compounds` (every compound it lists counts as the same component).
function resolve_group(ds::Dataset, id::Integer)
    1 <= id <= length(ds.compounds) ||
        throw(ArgumentError("compound id $id is out of range 1:$(length(ds.compounds))"))
    return Int32[id]
end
resolve_group(ds::Dataset, text::AbstractString) = matching_compounds(ds, text)
function resolve_group(::Dataset, found::CompoundMatches)
    isempty(found.id) && throw(ArgumentError("no compound in the result of find_compounds"))
    return found.id
end

const ComponentSpec = Union{AbstractString,Integer,CompoundMatches}
resolve_components(ds::Dataset, one::ComponentSpec) = [resolve_group(ds, one)]
function resolve_components(ds::Dataset, list::AbstractVector)
    isempty(list) && throw(ArgumentError("component list is empty"))
    return [resolve_group(ds, item) for item in list]
end

function component_matches(
    ex::ExperimentTable,
    e::Integer,
    groups,
    match::Symbol,
    exact::Bool,
)
    n = Int(ex.ncomp[e])
    hits = 0
    for group in groups
        for i = 1:n
            if ex.components[i][e] in group
                hits += 1
                break
            end
        end
    end
    exact && return hits == length(groups) && n == length(groups)
    return match === :all ? hits == length(groups) : hits > 0
end

# `nothing` when no reference criterion was given, else a mask over the references.
function reference_mask(ds::Dataset, doi, author, source, year)
    all(isnothing, (doi, author, source, year)) && return nothing
    rf = ds.references
    mask = trues(length(rf))
    if doi !== nothing
        wanted = lowercase(doi)
        for r in eachindex(mask)
            mask[r] &= lowercase(rf.doi[r]) == wanted
        end
    end
    if author !== nothing
        needle = lowercase(author)
        for r in eachindex(mask)
            mask[r] &= any(a -> occursin(needle, lowercase(a)), rf.authors[r])
        end
    end
    if source !== nothing
        id = get(ds.sources.index, source, NO_ID)
        id == NO_ID && throw(ArgumentError("unknown source \"$source\""))
        mask .&= rf.source .== id
    end
    if year !== nothing
        lo, hi = bounds(year)
        for r in eachindex(mask)
            mask[r] &= lo <= rf.year[r] <= hi
        end
    end
    return mask
end

function experiment_mask(ds::Dataset, component, match, exact, pure, refs)
    ex = ds.experiments
    groups = component === nothing ? nothing : resolve_components(ds, component)
    mask = trues(length(ex))
    for e in eachindex(mask)
        ok = groups === nothing || component_matches(ex, e, groups, match, exact)
        ok = ok && (pure === nothing || (ex.ncomp[e] == 1) == pure)
        ok = ok && (refs === nothing || refs[ex.reference[e]])
        mask[e] = ok
    end
    return mask
end

# Property criteria: a label (any case), a regular expression or a list of either.
property_matcher(label::AbstractString) = p -> lowercase(p) == lowercase(strip(label))
property_matcher(pattern::Regex) = p -> occursin(pattern, p)
function property_matcher(list::AbstractVector)
    matchers = property_matcher.(list)
    return p -> any(m -> m(p), matchers)
end

function property_mask(ds::Dataset, property)
    property === nothing && return trues(length(ds.properties))
    matcher = property_matcher(property)
    mask = BitVector(map(matcher, ds.properties.label))
    any(mask) || throw(ArgumentError("no property matches $(repr(property))"))
    return mask
end

# ----------------------------------------------------------------------------------
# The public filter
# ----------------------------------------------------------------------------------

find_compounds(view::DataView, text::AbstractString; kwargs...) =
    find_compounds(view.dataset, text; kwargs...)

"""
    points(dataset_or_view; kwargs...) -> DataView

Select experimental points. Every keyword is optional and they combine with AND; calling
it on a [`DataView`](@ref) refines that view, so filters can be chained.

- `component`: a name, formula or InChIKey, or a vector of them. Names are matched
  loosely (case, accents, hyphens and spaces are ignored, so `"iso-butane"` finds
  `"isobutane"`; see [`find_compounds`](@ref)); a compound id or the result of
  [`find_compounds`](@ref) is accepted too. With `match = :any`
  (default) a system qualifies if it contains any of them, with `match = :all` if it
  contains all of them. `exact = true` requires the system to consist of exactly the
  listed components (`component = "methane", exact = true` is pure methane).
- `pure`: `true` for single-component systems, `false` for mixtures.
- `property`: a label such as `"Mass density"` (any case), a `Regex`, or a vector.
- `temperature`, `pressure`: `(low, high)`; `nothing` leaves a side open. Plain numbers are
  in K and kPa; Unitful quantities are converted, e.g. `temperature = (20u"°C", 40u"°C")`
  and `pressure = (1u"atm", 2u"atm")`. Points without that condition are excluded when
  the filter is given.
- `doi`, `author` (substring, any case), `source` (e.g. `"thermoml"`), `year`.

A component or property that matches nothing throws an `ArgumentError`, so a typo is
never mistaken for "no data".

Given a [`LinkedDatabase`](@ref) (see [`link_compounds`](@ref)) instead of the dataset, a
component can also be a synonym, a CAS number, a PubChem CID, an InChI or a SMILES, and an
ambiguous text is resolved by asking the user (keyword `choose`).
"""
points(ds::Dataset; kwargs...) = points(DataView(ds); kwargs...)

function points(
    view::DataView;
    component = nothing,
    match::Symbol = :any,
    exact::Bool = false,
    pure::Union{Nothing,Bool} = nothing,
    property = nothing,
    temperature = nothing,
    pressure = nothing,
    doi = nothing,
    author = nothing,
    source = nothing,
    year = nothing,
)
    match in (:any, :all) || throw(ArgumentError("match must be :any or :all, got :$match"))
    ds = view.dataset
    m = ds.measurements
    refs = reference_mask(ds, doi, author, source, year)
    experiment_ok = experiment_mask(ds, component, match, exact, pure, refs)
    property_ok = property_mask(ds, property)
    check_T = temperature !== nothing
    check_P = pressure !== nothing
    tlo, thi = bounds(temperature, NativeTemperature())
    plo, phi = bounds(pressure, NativePressure())
    rows = Int32[]
    sizehint!(rows, length(view.rows))
    for r in view.rows
        experiment_ok[m.experiment[r]] || continue
        property_ok[m.property[r]] || continue
        check_T && !(tlo <= m.temperature[r] <= thi) && continue
        check_P && !(plo <= m.pressure[r] <= phi) && continue
        push!(rows, r)
    end
    return DataView(ds, rows)
end

"""
    mixture(dataset_or_view, components...; exact = true, kwargs...) -> DataView

Points of the systems made of the given components, in any order: `mixture(db, "nitrogen",
"isobutane")` is the binary nitrogen + isobutane. It is
`points(db; component = [components...], match = :all, exact = true, kwargs...)`, so
components are matched loosely (see [`find_compounds`](@ref)) and every other keyword of
[`points`](@ref) (`property`, `temperature`, ...) can be added. With `exact = false` systems
that contain further components are included.

When nothing is found, a message tells whether the components do occur together with
others, so an empty result can be told apart from a too strict one.
"""
function mixture(source, components...; exact::Bool = true, kwargs...)
    length(components) >= 2 ||
        throw(ArgumentError("a mixture needs at least two components"))
    wanted = collect(components)
    found = points(source; component = wanted, match = :all, exact, kwargs...)
    if isempty(found) && exact
        wider = points(source; component = wanted, match = :all, kwargs...)
        if isempty(wider)
            @info "no system contains all of these components with the given filters" components
        else
            @info "no system consists of exactly these components; $(length(wider)) points belong to systems that also contain others (use exact = false)" components
        end
    end
    return found
end
