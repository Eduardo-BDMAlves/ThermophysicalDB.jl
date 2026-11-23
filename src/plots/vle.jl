# Phase equilibrium figures: pressure, temperature and composition of mixtures (P-x-y, T-x-y,
# x-y) and the saturation line of a pure fluid.
#
# What the archive holds (a survey of 40 articles, see the design notes of the issue): an
# equilibrium point is spread over several rows of the table, and the rows say it in three ways.
#   * A bubble pressure: the property "Vapor or sublimation pressure" with the composition of
#     the liquid in `x1` and the temperature, and the vapour composition as a row of the
#     property "Mole fraction" with the same `x1` and temperature.
#   * A boiling temperature: "Boiling temperature at pressure P" with `x1` and the pressure,
#     and "Mole fraction" rows with the same `x1` and pressure for the vapour.
#   * Only compositions: "Mole fraction" rows without `x1`, at a temperature and a pressure,
#     whose phase says whether it is the liquid or the gas.
# The mole fraction is the one of the first component of the system.

const VLE_PROPERTIES =
    ("Vapor or sublimation pressure", "Boiling temperature at pressure", "Mole fraction")

"""
    EquilibriumPoints

The points of phase equilibrium of mixtures that [`equilibrium`](@ref) puts together from the
rows of a table: for each, the reference, the system, the temperature and the pressure (in the
units of the table, `NaN` when the point does not say) and the mole fraction of the first
component in the liquid (`x`) and in the vapour (`y`), `NaN` when it was not measured, and
`fixed`, the condition that the point holds fixed (`:temperature` for a bubble pressure,
`:pressure` for a boiling temperature, `:both` when both were set).
"""
struct EquilibriumPoints
    doi::Vector{String}
    year::Vector{Int16}
    components::Vector{String}
    temperature::Vector{Float64}
    pressure::Vector{Float64}
    x::Vector{Float64}
    y::Vector{Float64}
    fixed::Vector{Symbol}
end

Base.length(e::EquilibriumPoints) = length(e.x)

function from_kelvin(value::Real, unit::AbstractString)
    haskey(TEMPERATURE_TO_KELVIN, unit) ||
        throw(ArgumentError("cannot convert kelvin to the temperature unit $(repr(unit))"))
    a, b = TEMPERATURE_TO_KELVIN[unit]
    return (value - b) / a
end

# A temperature or a pressure from one unit to the unit of the table.
function convert_temperature(value::Real, from::AbstractString, to::AbstractString)
    from == to && return Float64(value)
    haskey(TEMPERATURE_TO_KELVIN, from) ||
        throw(ArgumentError("cannot convert the temperature unit $(repr(from))"))
    a, b = TEMPERATURE_TO_KELVIN[from]
    return from_kelvin(a * value + b, to)
end

function convert_pressure(value::Real, from::AbstractString, to::AbstractString)
    from == to && return Float64(value)
    (haskey(PRESSURE_TO_PASCAL, from) && haskey(PRESSURE_TO_PASCAL, to)) || throw(
        ArgumentError("cannot convert the pressure unit $(repr(from)) to $(repr(to))"),
    )
    return value * PRESSURE_TO_PASCAL[from] / PRESSURE_TO_PASCAL[to]
end

# Keys that match the values that two rows of the same point give (the conditions are text
# in the archive and are equal to the digits that were written).
round_key(v::Real, digits::Integer) = isfinite(v) ? round(v; digits) : NaN
function pressure_key(v::Real)
    isfinite(v) && v > 0 || return NaN
    return round(v; sigdigits = 4)
end

"""
    equilibrium(data) -> EquilibriumPoints

Put together the equilibrium points of mixtures from the rows of `data` (the properties `Vapor
or sublimation pressure`, `Boiling temperature at pressure P` and `Mole fraction`), as the
comments of `src/plots/vle.jl` describe. A row that finds no partner stays as a point of its own
(a bubble pressure without a vapour composition, a vapour composition without a pressure).
"""
function equilibrium(d::PlotData)
    c = parent(d.table)
    tunit, punit = temperature_unit(d), pressure_unit(d)
    doi, year, comps = c.doi, c.year, c.components
    n = length(d)
    prop = c.property
    role = fill(:none, n)
    for i = 1:n
        p = prop[i]
        if startswith(p, "Vapor or sublimation pressure") && isfinite(c.x1[i])
            role[i] = :bubble_p
        elseif startswith(p, "Boiling temperature at pressure") && isfinite(c.x1[i])
            role[i] = :boiling_t
        elseif p == "Mole fraction"
            role[i] =
                isfinite(c.x1[i]) ? :y_with_x :
                startswith(c.phase[i], "Liquid") ? :x_only :
                startswith(c.phase[i], "Gas") ? :y_only : :none
        end
    end
    isothermal = Dict{Tuple{String,String,Float64,Float64},Vector{Int}}()
    isobaric = Dict{Tuple{String,String,Float64,Float64},Vector{Int}}()
    for i = 1:n
        role[i] === :y_with_x || continue
        x = round_key(c.x1[i], 5)
        if isfinite(c.temperature[i])
            push!(
                get!(
                    isothermal,
                    (doi[i], comps[i], round_key(c.temperature[i], 2), x),
                    Int[],
                ),
                i,
            )
        end
        pk = pressure_key(c.pressure[i])
        isnan(pk) || push!(get!(isobaric, (doi[i], comps[i], pk, x), Int[]), i)
    end
    used = falses(n)
    out = (
        doi = String[],
        year = Int16[],
        components = String[],
        temperature = Float64[],
        pressure = Float64[],
        x = Float64[],
        y = Float64[],
        fixed = Symbol[],
    )
    function add!(i, T, p, x, y, fixed)
        push!(out.doi, doi[i])
        push!(out.year, year[i])
        push!(out.components, comps[i])
        push!(out.temperature, T)
        push!(out.pressure, p)
        push!(out.x, x)
        push!(out.y, y)
        return push!(out.fixed, fixed)
    end
    for i = 1:n
        if role[i] === :bubble_p
            T = c.temperature[i]
            p = convert_pressure(c.value[i], c.unit[i], punit)
            partners = get(
                isothermal,
                (doi[i], comps[i], round_key(T, 2), round_key(c.x1[i], 5)),
                Int[],
            )
            if isempty(partners)
                add!(i, T, p, c.x1[i], NaN, :temperature)
            else
                for j in partners
                    used[j] = true
                    add!(i, T, p, c.x1[i], c.value[j], :temperature)
                end
            end
        elseif role[i] === :boiling_t
            T = convert_temperature(c.value[i], c.unit[i], tunit)
            p = c.pressure[i]
            key = (doi[i], comps[i], pressure_key(p), round_key(c.x1[i], 5))
            partners = get(isobaric, key, Int[])
            if isempty(partners)
                add!(i, T, p, c.x1[i], NaN, :pressure)
            else
                for j in partners
                    used[j] = true
                    add!(i, T, p, c.x1[i], c.value[j], :pressure)
                end
            end
        end
    end
    # A vapour composition that no bubble point claimed.
    for i = 1:n
        if role[i] === :y_with_x && !used[i]
            T, p = c.temperature[i], c.pressure[i]
            fixed =
                isfinite(T) && isfinite(p) ? :both : isfinite(T) ? :temperature : :pressure
            add!(i, T, p, c.x1[i], c.value[i], fixed)
        end
    end
    # Compositions given with the temperature and the pressure only: liquid and gas at the same
    # conditions are one point, the others are half points.
    pending = Dict{Tuple{String,String,Float64,Float64},Tuple{Vector{Int},Vector{Int}}}()
    for i = 1:n
        (role[i] === :x_only || role[i] === :y_only) || continue
        key =
            (doi[i], comps[i], round_key(c.temperature[i], 2), pressure_key(c.pressure[i]))
        xs, ys = get!(pending, key, (Int[], Int[]))
        push!(role[i] === :x_only ? xs : ys, i)
    end
    for (_, (xs, ys)) in pending
        for k = 1:max(length(xs), length(ys))
            ix = k <= length(xs) ? xs[k] : 0
            iy = k <= length(ys) ? ys[k] : 0
            i = ix == 0 ? iy : ix
            add!(
                i,
                c.temperature[i],
                c.pressure[i],
                ix == 0 ? NaN : c.value[ix],
                iy == 0 ? NaN : c.value[iy],
                :both,
            )
        end
    end
    return EquilibriumPoints(
        out.doi,
        out.year,
        out.components,
        out.temperature,
        out.pressure,
        out.x,
        out.y,
        out.fixed,
    )
end

# The data of a figure of equilibrium: the selection with the properties that make the points.
function vle_data(data, units::NamedTuple; filters...)
    if !(data isa PlotData || data isa PointTable)
        filters =
            haskey(filters, :property) ? filters :
            (; filters..., property = collect(VLE_PROPERTIES))
    end
    return prepare_data(data, units; filters...)
end

# A number with the digits that matter (the mean of the values of a section).
function compact_number(v::Real)
    r = round(v; sigdigits = 6)
    return isinteger(r) ? string(Int(r)) : string(r)
end

# The label of the composition axis.
const COMPOSITION_LABEL = raw"x_1,\,y_1"

# The sections of the data at a fixed temperature (`by = :temperature`) or pressure.
function sections(e::EquilibriumPoints, by::Symbol, tol, wanted)
    cond = by === :temperature ? e.temperature : e.pressure
    idx = [i for i in eachindex(cond) if isfinite(cond[i]) && e.fixed[i] in (by, :both)]
    values = by === :temperature ? cond[idx] : log.(max.(cond[idx], floatmin()))
    groups = cluster_values(values, tol)
    sections = [idx[g] for g in groups]
    if wanted !== nothing
        targets = wanted isa Real ? [wanted] : collect(wanted)
        keep = Vector{Int}[]
        for s in sections
            m = sum(cond[s]) / length(s)
            any(
                t -> by === :temperature ? abs(m - t) <= tol : abs(log(m / t)) <= tol,
                targets,
            ) && push!(keep, s)
        end
        sections = keep
    end
    return sections
end

function reference_groups(e::EquilibriumPoints, rows::Vector{Int}, style::PlotStyle)
    labels = [isempty(e.doi[i]) ? string(e.year[i]) : e.doi[i] for i in rows]
    names = sort(unique(labels))
    return [
        (name, rows[findall(==(name), labels)], group_marker(style, k)...) for
        (k, name) in enumerate(names)
    ]
end

# The curve of a model for a section: the bubble line and the dew line over the composition.
function equilibrium_curve(model, fixed::Real, by::Symbol, d::PlotData, points::Integer)
    tunit, punit = temperature_unit(d), pressure_unit(d)
    fixed_si = if by === :temperature
        a, b = TEMPERATURE_TO_KELVIN[tunit]
        a * fixed + b
    else
        fixed * PRESSURE_TO_PASCAL[punit]
    end
    xs = collect(range(0.0, 1.0; length = points))
    bubble = fill(NaN, points)
    dew = fill(NaN, points)
    ys = fill(NaN, points)
    for (k, x) in enumerate(xs)
        result = try
            model(fixed_si, x)
        catch err
            err isa DomainError ? nothing : rethrow()
        end
        result === nothing && continue
        value, y = result
        value =
            by === :temperature ? value / PRESSURE_TO_PASCAL[punit] :
            from_kelvin(value, tunit)
        bubble[k] = value
        dew[k] = value
        ys[k] = y
    end
    return xs, ys, bubble
end

"""
    figure_vle(data, by; ...) -> FigureSpec

The sections of phase equilibrium of a mixture: `by = :temperature` gives P-x-y diagrams (one
panel for each isotherm), `by = :pressure` T-x-y diagrams (one for each isobar). See
[`plot_pxy`](@ref) and [`plot_txy`](@ref).
"""
function figure_vle(
    data,
    by::Symbol;
    at = nothing,
    tol::Union{Nothing,Real} = nothing,
    model = nothing,
    maxpanels::Integer = 6,
    ncols::Union{Nothing,Integer} = nothing,
    xunit = nothing,
    yunit = nothing,
    panel_labels = :auto,
    curve_points::Integer = 101,
    kwargs...,
)
    by in (:temperature, :pressure) ||
        throw(ArgumentError("sections are by :temperature or :pressure"))
    opts, filters = split_options(kwargs)
    dep = by === :temperature ? :pressure : :temperature
    d = vle_data(data, unit_keywords(by => xunit, dep => yunit); filters...)
    o = resolve_options(; opts...)
    e = equilibrium(d)
    length(e) == 0 && throw(
        ArgumentError(
            "no equilibrium points were found in the data: they need the properties $(join(VLE_PROPERTIES, ", "))",
        ),
    )
    tolerance = tol === nothing ? (by === :temperature ? 0.5 : 0.01) : tol
    secs = sections(e, by, tolerance, at)
    isempty(secs) && throw(ArgumentError("no section of the data is at $(at)"))
    if length(secs) > maxpanels
        at === nothing || throw(
            ArgumentError(
                "`at` selects $(length(secs)) sections; give fewer or raise `maxpanels` (now $maxpanels)",
            ),
        )
        # Without `at`, the sections with most points are drawn, in the order of their condition.
        total = length(secs)
        richest = sort!(sortperm(length.(secs); rev = true)[1:maxpanels])
        secs = secs[richest]
        @info "the data have $total sections; the $maxpanels with most points are drawn (choose with `at = ...` or raise `maxpanels`)"
    end
    cond = by === :temperature ? e.temperature : e.pressure
    value = by === :temperature ? e.pressure : e.temperature
    panels = PanelSpec[]
    for rows in secs
        layers = Layer[]
        level = sum(cond[rows]) / length(rows)
        for (name, r, marker, filled) in reference_groups(e, rows, o.style)
            for (xs, ys, isbubble) in ((e.x, value, true), (e.y, value, false))
                keep = [i for i in r if isfinite(xs[i]) && isfinite(ys[i])]
                isempty(keep) && continue
                push!(
                    layers,
                    Layer(;
                        kind = :scatter,
                        x = xs[keep],
                        y = ys[keep],
                        color = o.style.palette[1],
                        marker,
                        filled = isbubble,
                        label = isbubble ? name : "",
                        size = o.style.markersize,
                    ),
                )
            end
        end
        if model !== nothing
            xs, ys, vs = equilibrium_curve(model, level, by, d, curve_points)
            color = o.style.palette[min(5, end)]
            push!(layers, model_line(xs, vs; color, label = "model"))
            push!(layers, model_line(ys, vs; color, linestyle = :dash))
        end
        push!(
            layers,
            Layer(;
                kind = :scatter,
                x = [NaN],
                y = [NaN],
                color = o.style.foreground,
                filled = true,
                label = "bubble (x)",
            ),
        )
        push!(
            layers,
            Layer(;
                kind = :scatter,
                x = [NaN],
                y = [NaN],
                color = o.style.foreground,
                filled = false,
                label = "dew (y)",
            ),
        )
        unit = by === :temperature ? temperature_unit(d) : pressure_unit(d)
        label = by === :temperature ? "T" : "p"
        push!(
            panels,
            PanelSpec(;
                layers,
                xlabel = COMPOSITION_LABEL,
                ylabel = variable_label(d, dep; format = o.format),
                title = string(label, " = ", compact_number(level), ' ', unit),
                limits = (0.0, 1.0, NaN, NaN),
                colormap = o.style.colormap,
            ),
        )
    end
    n = length(panels)
    nc = ncols === nothing ? min(3, n) : min(Int(ncols), n)
    tags = panel_tags(n, panel_labels, n > 1)
    panels = [with_tag(p, tags[i]) for (i, p) in enumerate(panels)]
    return FigureSpec(;
        panels,
        nrows = cld(n, nc),
        ncols = nc,
        style = o.style,
        size = grid_size(nc, cld(n, nc); legend = true),
    )
end

"""
    figure_xy(data; color, ...) -> FigureSpec

The composition of the vapour against the one of the liquid, with the diagonal, the points
coloured by the temperature (or the pressure). See [`plot_xy`](@ref).
"""
function figure_xy(data; color::Symbol = :auto, cunit = nothing, kwargs...)
    opts, filters = split_options(kwargs)
    d = vle_data(
        data,
        (color === :auto ? unit_keywords() : unit_keywords(color => cunit));
        filters...,
    )
    o = resolve_options(; opts...)
    e = equilibrium(d)
    keep = [i for i in eachindex(e.x) if isfinite(e.x[i]) && isfinite(e.y[i])]
    isempty(keep) && throw(
        ArgumentError("no point has both the composition of the liquid and of the vapour"),
    )
    var = color
    if var === :auto
        spread(v) =
            (f = filter(isfinite, v[keep]); isempty(f) ? 0.0 : maximum(f) - minimum(f))
        var = spread(e.temperature) > 0 ? :temperature : :pressure
    end
    cs = var === :temperature ? e.temperature : e.pressure
    ys = e.y
    xs = e.x
    sub = (doi = e.doi[keep], year = e.year[keep])
    labels =
        [isempty(sub.doi[k]) ? string(sub.year[k]) : sub.doi[k] for k in eachindex(keep)]
    names = sort(unique(labels))
    layers = Layer[Layer(;
        kind = :lines,
        x = [0.0, 1.0],
        y = [0.0, 1.0],
        color = o.style.foreground,
        width = 1.0,
    ),]
    finite = [cs[i] for i in keep if isfinite(cs[i])]
    colored = !isempty(finite)
    for (k, name) in enumerate(names)
        rows = keep[findall(==(name), labels)]
        marker, filled = group_marker(o.style, k)
        push!(
            layers,
            Layer(;
                kind = :scatter,
                x = xs[rows],
                y = ys[rows],
                color = colored ?
                        Float64[isfinite(cs[i]) ? cs[i] : first(finite) for i in rows] :
                        o.style.palette[1],
                marker,
                filled,
                label = name,
                size = o.style.markersize,
            ),
        )
    end
    limits = colored ? extrema(finite) : (0.0, 1.0)
    limits = limits[1] == limits[2] ? (limits[1] - 1, limits[2] + 1) : limits
    colorbar =
        colored ?
        ColorbarSpec(
            variable_label(d, var; format = o.format),
            o.style.colormap,
            Float64.(limits),
        ) : nothing
    panel = PanelSpec(;
        layers,
        xlabel = "x_1",
        ylabel = "y_1",
        aspect_equal = true,
        colorbar,
        colormap = o.style.colormap,
        colorrange = colored ? Float64.(limits) : nothing,
        limits = (0.0, 1.0, 0.0, 1.0),
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (620, 560))
end

# ----------------------------------------------------------------------------------
# Saturation line of a pure fluid
# ----------------------------------------------------------------------------------

# The rows of a property (the name starts with `prefix`), without the ones with a pressure
# when `saturated` (a point without a pressure is at saturation).
function rows_of(d::PlotData, prefix::AbstractString)
    return findall(p -> startswith(p, prefix), column(d, :property))
end

# The critical point of each reference: its temperature with its density (or pressure), taken
# in the order in which the reference gives them.
function critical_pairs(
    d::PlotData,
    first_prefix::AbstractString,
    second_prefix::AbstractString,
)
    doi = column(d, :doi)
    a = rows_of(d, first_prefix)
    b = rows_of(d, second_prefix)
    pairs = Tuple{Int,Int}[]
    for key in unique(doi[a])
        ra = [i for i in a if doi[i] == key]
        rb = [i for i in b if doi[i] == key]
        isempty(rb) && continue
        if length(ra) == length(rb)
            append!(pairs, zip(ra, rb))
        else
            push!(pairs, (ra[1], rb[1]))
        end
    end
    return pairs
end

"""
    figure_saturation(data; density = "Mass density", ...) -> FigureSpec

The saturation line of a pure fluid: the densities of the liquid and of the gas against the
temperature (the points that state no pressure, which are at saturation; liquid filled, gas
open), with the critical point of each reference as a star; and, beside it, the vapour
pressure against the inverse of the temperature, with the critical points as stars too. See
[`plot_saturation`](@ref).
"""
function figure_saturation(
    data;
    density::AbstractString = "Mass density",
    pressure::AbstractString = "Vapor or sublimation pressure",
    saturated_only::Bool = true,
    xunit = nothing,
    panel_labels = :auto,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    if !(data isa PlotData || data isa PointTable) && !haskey(filters, :property)
        filters = (;
            filters...,
            property = [
                density,
                pressure,
                "Critical temperature",
                "Critical density",
                "Critical pressure",
            ],
        )
    end
    d = prepare_data(data, unit_keywords(:temperature => xunit); filters...)
    o = resolve_options(; opts...)
    c = parent(d.table)
    tunit, punit = temperature_unit(d), pressure_unit(d)
    style = o.style
    dens = [
        i for i in rows_of(d, density) if
        isfinite(c.temperature[i]) && (!saturated_only || !isfinite(c.pressure[i]))
    ]
    liquid = [i for i in dens if startswith(c.phase[i], "Liquid")]
    gas = [i for i in dens if startswith(c.phase[i], "Gas")]
    layers_rho = Layer[]
    dunit = isempty(dens) ? "" : c.unit[dens[1]]
    for (rows, filled, label) in ((liquid, true, "liquid"), (gas, false, "gas"))
        isempty(rows) && continue
        push!(
            layers_rho,
            Layer(;
                kind = :scatter,
                x = Float64.(c.temperature[rows]),
                y = Float64.(c.value[rows]),
                color = style.palette[1],
                marker = :circle,
                filled,
                label,
                size = style.markersize,
            ),
        )
    end
    psat = [
        i for i in rows_of(d, pressure) if
        isfinite(c.temperature[i]) && c.temperature[i] > 0 && c.value[i] > 0
    ]
    layers_p = Layer[]
    if !isempty(psat)
        inv_t = [
            1000.0 / (
                TEMPERATURE_TO_KELVIN[tunit][1] * c.temperature[i] +
                TEMPERATURE_TO_KELVIN[tunit][2]
            ) for i in psat
        ]
        pv = [convert_pressure(c.value[i], c.unit[i], punit) for i in psat]
        push!(
            layers_p,
            Layer(;
                kind = :scatter,
                x = inv_t,
                y = pv,
                color = style.palette[1],
                marker = :circle,
                filled = true,
                label = "vapour pressure",
                size = style.markersize,
            ),
        )
    end
    # The critical points: one colour and one entry of the legend for each reference.
    labels = reference_labels(d)
    tc_rho = critical_pairs(d, "Critical temperature", "Critical density")
    tc_p = critical_pairs(d, "Critical temperature", "Critical pressure")
    names =
        sort(unique(vcat([labels[i] for (i, _) in tc_rho], [labels[i] for (i, _) in tc_p])))
    for (k, name) in enumerate(names)
        color = style.palette[mod1(k + 1, length(style.palette))]
        first = true
        for (pairs, layers, yconv, xconv) in (
            (tc_rho, layers_rho, j -> Float64(c.value[j]), t -> t),
            (
                tc_p,
                layers_p,
                j -> convert_pressure(c.value[j], c.unit[j], punit),
                t ->
                    1000.0 /
                    (TEMPERATURE_TO_KELVIN[tunit][1] * t + TEMPERATURE_TO_KELVIN[tunit][2]),
            ),
        )
            sel = [(i, j) for (i, j) in pairs if labels[i] == name]
            isempty(sel) && continue
            push!(
                layers,
                Layer(;
                    kind = :scatter,
                    x = [
                        xconv(
                            Float64(c.value[i]) |>
                            v -> convert_temperature(v, c.unit[i], tunit),
                        ) for (i, _) in sel
                    ],
                    y = [yconv(j) for (_, j) in sel],
                    color,
                    marker = :star5,
                    filled = true,
                    label = first ? name : "",
                    size = style.markersize * 1.8,
                ),
            )
            first = false
        end
    end
    isempty(layers_rho) &&
        isempty(layers_p) &&
        throw(
            ArgumentError(
                "no saturation data were found: the data need densities without a pressure, vapour pressures or critical points",
            ),
        )
    panels = PanelSpec[]
    isempty(layers_rho) || push!(
        panels,
        PanelSpec(;
            layers = layers_rho,
            xlabel = axis_label("T", tunit; format = o.format),
            ylabel = property_label(density, dunit; format = o.format),
            colormap = style.colormap,
        ),
    )
    isempty(layers_p) || push!(
        panels,
        PanelSpec(;
            layers = layers_p,
            xlabel = raw"1000\,/\,T\;[\mathrm{K}^{-1}]",
            ylabel = property_label(
                "Vapor or sublimation pressure",
                punit;
                format = o.format,
            ),
            yscale = :log10,
            legend = isempty(layers_rho),
            colormap = style.colormap,
        ),
    )
    n = length(panels)
    tags = panel_tags(n, panel_labels, n > 1)
    panels = [with_tag(p, tags[i]) for (i, p) in enumerate(panels)]
    return FigureSpec(;
        panels,
        nrows = 1,
        ncols = n,
        style,
        size = (480 * n + LEGEND_PIXELS, 420),
    )
end
