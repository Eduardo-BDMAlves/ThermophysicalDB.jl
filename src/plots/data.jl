# The data of the figures: the columns of a selection are built once, and the figures take what
# they need from them (without copying the vectors), evaluating the models once.

"""
    PlotData

The points of a selection prepared for the figures, from [`plotdata`](@ref): a
[`PointTable`](@ref) (`table`), the calculated values (`calc`, when they were given) and the
values that the models gave, which are kept so that a model runs once for each set of
conditions. Every `plot_*` function takes one, or builds it from a selection.
"""
struct PlotData
    table::PointTable
    calc::Union{Nothing,Vector{Float64}}
    cache::Dict{Any,Vector{Float64}}
end

PlotData(t::PointTable, calc = nothing) = PlotData(
    t,
    calc === nothing ? nothing : Vector{Float64}(calc),
    Dict{Any,Vector{Float64}}(),
)

Base.length(d::PlotData) = length(d.table)
Base.parent(d::PlotData) = d.table
Base.show(io::IO, d::PlotData) = print(
    io,
    "PlotData(",
    length(d),
    " points, ",
    join(unique(parent(d.table).property), "; "),
    ")",
)

# The columns of the table, which are not copied.
column(d::PlotData, name::Symbol) = parent(d.table)[name]
temperature_unit(d::PlotData) = getfield(d.table, :temperature_unit)
pressure_unit(d::PlotData) = getfield(d.table, :pressure_unit)

"""
    properties(data::PlotData) -> Vector{String}

The properties of the points, in the order in which they first appear.
"""
properties(d::PlotData) = unique(column(d, :property))

# The name of the only property of the data.
function only_property(d::PlotData)
    names = properties(d)
    length(names) == 1 || throw(
        ArgumentError(
            "this figure shows one property and the data have $(length(names)): $(join(names, "; ")). Select one with `property = ...`, or use `plot_facets`",
        ),
    )
    return names[1]
end

# The unit of the values of a property, as the table gives it.
function value_unit(d::PlotData, property::AbstractString)
    i = findfirst(==(property), column(d, :property))
    i === nothing && return ""
    return column(d, :unit)[i]
end

# A unit given to a figure, as text: a text or a symbol stays, a unit of Unitful or FlexUnits is
# written as text that the exact parser reads (so the axes and the colour bars are converted
# exactly, as with text), and the quantities of DynamicQuantities, which keep no unit
# (everything is stored in SI), are asked for as text.
plot_unit(::Nothing) = nothing
plot_unit(unit::AbstractString) = String(unit)
plot_unit(unit::Symbol) = String(unit)
function plot_unit(unit)
    backend = backend_of(unit)
    text = plot_unit_text(backend, unit)
    text === nothing && throw(
        ArgumentError(
            "a unit of $(parentmodule(typeof(unit))) cannot be used for an axis because the package keeps no text of its units (it stores SI); give the unit as text, for example \"MPa\" or \"kg/m3\"",
        ),
    )
    return text
end
plot_unit_text(backend, unit) = unit_text(backend, unit)

"""
    plotdata(source; property, ..., unit, temperature_unit, pressure_unit, calc = nothing,
             sortby = [:doi, :temperature]) -> PlotData

Prepare the points for the figures. `source` is a selection ([`DataView`](@ref), a
[`Database`](@ref) view, a dataset) or a [`PointTable`](@ref); the keywords of [`points`](@ref)
(`component`, `property`, `temperature`, `doi`, ...) filter it first, and `unit`,
`temperature_unit` and `pressure_unit` are the ones of [`table`](@ref) (exact, without floating
point error): text (`"MPa"`, `"degC"`, `"mPa s"`), or a unit of Unitful or FlexUnits, which is
read as text; the columns of a figure are always plain numbers. `calc` is a vector of calculated values in the unit of the table, one per point,
for a figure to compare with. Building it once and giving it to several figures saves the
work of the table.
"""
function plotdata(
    source;
    unit = nothing,
    temperature_unit = nothing,
    pressure_unit = nothing,
    calc = nothing,
    sortby = [:doi, :temperature],
    kwargs...,
)
    source isa PlotData && return source
    unit = plot_unit(unit)
    temperature_unit = plot_unit(temperature_unit)
    pressure_unit = plot_unit(pressure_unit)
    if source isa PointTable
        isempty(kwargs) || throw(
            ArgumentError(
                "a table cannot be filtered with $(keys(kwargs)); select with `points` first",
            ),
        )
        return PlotData(source, calc)
    end
    view = isempty(kwargs) ? source : points(source; kwargs...)
    t = table(view; unit, temperature_unit, pressure_unit, sortby)
    return PlotData(t, calc)
end

# The part of the data in a mask (a table with those rows, the calculated values of them).
function subset_data(d::PlotData, mask::AbstractVector{Bool})
    t = d.table[mask]
    return PlotData(t, d.calc === nothing ? nothing : d.calc[mask])
end

# One data set per property, for the facets.
function split_properties(d::PlotData)
    col = column(d, :property)
    return [(name, subset_data(d, col .== name)) for name in unique(col)]
end

# ----------------------------------------------------------------------------------
# Conditions in the units that a model takes: K for temperature, Pa for pressure
# ----------------------------------------------------------------------------------

const TEMPERATURE_TO_KELVIN = Dict{String,Tuple{Float64,Float64}}(
    "K" => (1.0, 0.0),
    "degC" => (1.0, 273.15),
    "°C" => (1.0, 273.15),
    "degF" => (5 / 9, 459.67 * 5 / 9),
    "°F" => (5 / 9, 459.67 * 5 / 9),
    "degR" => (5 / 9, 0.0),
)
const PRESSURE_TO_PASCAL = Dict{String,Float64}(
    "Pa" => 1.0,
    "kPa" => 1.0e3,
    "MPa" => 1.0e6,
    "GPa" => 1.0e9,
    "bar" => 1.0e5,
    "mbar" => 1.0e2,
    "atm" => 101325.0,
    "psi" => 6894.757293168361,
    "mmHg" => 133.322387415,
    "torr" => 133.322368421,
)

function conditions_si(d::PlotData, name::Symbol)
    if name === :temperature
        unit = temperature_unit(d)
        haskey(TEMPERATURE_TO_KELVIN, unit) || throw(
            ArgumentError(
                "cannot convert the temperature unit $(repr(unit)) to kelvin for the model",
            ),
        )
        a, b = TEMPERATURE_TO_KELVIN[unit]
        return a .* column(d, :temperature) .+ b
    elseif name === :pressure
        unit = pressure_unit(d)
        haskey(PRESSURE_TO_PASCAL, unit) || throw(
            ArgumentError(
                "cannot convert the pressure unit $(repr(unit)) to pascal for the model",
            ),
        )
        return PRESSURE_TO_PASCAL[unit] .* column(d, :pressure)
    elseif name in (:x1, :x2, :x3)
        return column(d, name)
    end
    throw(
        ArgumentError(
            "a model argument is :temperature (K), :pressure (Pa), :x1, :x2 or :x3, got $(repr(name))",
        ),
    )
end

"""
    model_values(data, model; args = (:pressure, :temperature)) -> Vector{Float64}

The values that `model` gives at the conditions of the points: `model(args...)` for each point,
with `:temperature` in kelvin, `:pressure` in pascal and `:x1`, `:x2`, `:x3` as they are in the
table (`model(p, T)` is the default; `args = (:temperature,)` is `model(T)` for a property on
the saturation line, `(:temperature, :x1)` is `model(T, x)`). It must return the value in the
unit of the points. The values are kept in the data: the same model with the same arguments
runs once. A `DomainError` is a `NaN` (a model that is not defined at a point), any other error
goes up.
"""
function model_values(d::PlotData, model; args::Tuple = (:pressure, :temperature))
    return get!(d.cache, (model, args)) do
        columns = map(a -> conditions_si(d, a), args)
        out = Vector{Float64}(undef, length(d))
        for i in eachindex(out)
            out[i] = try
                Float64(model(map(c -> c[i], columns)...))
            catch err
                err isa DomainError ? NaN : rethrow()
            end
        end
        out
    end
end

# The calculated values of the figure: those of `model`, or the ones given to `plotdata`.
function calculated(d::PlotData, model, args)
    model === nothing || return model_values(d, model; args)
    d.calc === nothing && throw(
        ArgumentError(
            "this figure compares with a model: give `model = f` or `calc = ...` (in `plotdata`)",
        ),
    )
    return d.calc
end

# ----------------------------------------------------------------------------------
# Groups of points that a marker tells apart
# ----------------------------------------------------------------------------------

"""
    PointGroup

The label of a group of points and their positions in the data.
"""
struct PointGroup
    label::String
    rows::Vector{Int}
end

const MARKER_BY = (:reference, :method, :phase, :year_group, nothing)

# The text that tells apart the references: the DOI, or the year when there is none.
function reference_labels(d::PlotData)
    doi = column(d, :doi)
    year = column(d, :year)
    return [isempty(doi[i]) ? string(year[i]) : string(doi[i]) for i = 1:length(d)]
end

"""
    point_groups(data, by; maxgroups = 20) -> Vector{PointGroup}

Group the points as `by` says: `:reference` (the DOI), `:method`, `:phase`, `:year_group` (by
decade) or `nothing` (one group). The groups come ordered by their label; when there are more
than `maxgroups`, the largest `maxgroups - 1` stay and the others are put together as
`"others"`.
"""
function point_groups(d::PlotData, by; maxgroups::Integer = 20)
    by in MARKER_BY || throw(
        ArgumentError(
            "marker_by must be one of $(filter(!isnothing, collect(MARKER_BY))) or nothing, got $(repr(by))",
        ),
    )
    n = length(d)
    keys_ = if by === nothing
        fill("", n)
    elseif by === :reference
        reference_labels(d)
    elseif by === :year_group
        [string(10 * (Int(y) ÷ 10), "s") for y in column(d, :year)]
    else
        String[isempty(v) ? "(none)" : String(v) for v in column(d, by)]
    end
    index = Dict{String,Vector{Int}}()
    for i = 1:n
        push!(get!(index, keys_[i], Int[]), i)
    end
    groups = [PointGroup(k, v) for (k, v) in index]
    if length(groups) > maxgroups
        sort!(groups; by = g -> -length(g.rows))
        rest = reduce(vcat, (g.rows for g in groups[maxgroups:end]))
        sort!(rest)
        groups = vcat(groups[1:(maxgroups-1)], [PointGroup("others", rest)])
        sort!(groups; by = g -> g.label == "others" ? "￿" : g.label)
    else
        sort!(groups; by = g -> g.label)
    end
    return groups
end

# The marker of the k-th group: the shapes of the style, filled and then open.
function group_marker(style::PlotStyle, k::Integer)
    n = length(style.markers)
    return (style.markers[mod1(k, n)], k <= n)
end

# Values that are the same up to a tolerance, as a vector of the groups they make (for the
# isotherms: temperatures that differ by less than `tol`).
function cluster_values(values::AbstractVector{<:Real}, tol::Real)
    order = sortperm(values)
    groups = Vector{Vector{Int}}()
    last = NaN
    for i in order
        v = values[i]
        isfinite(v) || continue
        if isempty(groups) || v - last > tol
            push!(groups, Int[])
        end
        push!(groups[end], i)
        last = v
    end
    return groups
end

# ----------------------------------------------------------------------------------
# Labels of what is on the axes
# ----------------------------------------------------------------------------------

const VARIABLE_SYMBOLS = Dict{Symbol,String}(
    :temperature => "T",
    :pressure => "p",
    :x1 => "x_1",
    :x2 => "x_2",
    :x3 => "x_3",
    :year => raw"\mathrm{year}",
)

# The label of a variable of the table on an axis.
function variable_label(d::PlotData, name::Symbol; format = :square)
    if name === :value
        property = only_property(d)
        return property_label(property, value_unit(d, property); format)
    elseif name === :temperature
        return axis_label("T", temperature_unit(d); format)
    elseif name === :pressure
        return axis_label("p", pressure_unit(d); format)
    elseif haskey(VARIABLE_SYMBOLS, name)
        return VARIABLE_SYMBOLS[name]
    end
    return roman_text(String(name))
end

# The values of a variable of the table as numbers.
function variable_values(d::PlotData, name::Symbol)
    name === :calc && throw(ArgumentError(":calc needs a model"))
    return Float64.(column(d, name))
end
