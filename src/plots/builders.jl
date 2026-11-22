# What each figure is made of. The builders return a `FigureSpec` (no plotting package needed);
# the `plot_*` functions of the next file draw it with a backend.

const MAX_UNCERTAINTY_BARS = 300

# ----------------------------------------------------------------------------------
# Options shared by the figures
# ----------------------------------------------------------------------------------

# The units that the keywords of the axes ask for, as the keywords of `plotdata`.
function unit_keywords(pairs...)
    kw = Dict{Symbol,Any}()
    for (variable, unit) in pairs
        unit === nothing && continue
        key =
            variable === :temperature ? :temperature_unit :
            variable === :pressure ? :pressure_unit :
            variable in (:value, :calc) ? :unit :
            throw(
                ArgumentError(
                    "a unit was given for $(repr(variable)), which has none to change",
                ),
            )
        haskey(kw, key) &&
            kw[key] != unit &&
            throw(
                ArgumentError(
                    "two different units for the same quantity: $(kw[key]) and $unit",
                ),
            )
        kw[key] = unit
    end
    return NamedTuple(kw)
end

# The data of a figure: the given `PlotData`, or the selection prepared with the units that the
# axes ask for.
function prepare_data(data, units::NamedTuple; filters...)
    if data isa PlotData
        (isempty(units) && isempty(filters)) || throw(
            ArgumentError(
                "units and filters belong to `plotdata`; give them there, or give the selection to the figure",
            ),
        )
        return data
    end
    return plotdata(data; units..., filters...)
end

# The options that every figure resolves against the defaults of the session.
function resolve_options(;
    style = nothing,
    colormap = nothing,
    unitformat = nothing,
    uncertainty = nothing,
    marker_by = :default,
)
    s = resolve_style(style, colormap)
    defaults = plot_defaults()
    format =
        unitformat === nothing ?
        (s.unitformat === :square ? defaults.unitformat : s.unitformat) : unitformat
    mode = uncertainty === nothing ? defaults.uncertainty : uncertainty
    mode in UNCERTAINTY_MODES || throw(
        ArgumentError("uncertainty must be one of $(UNCERTAINTY_MODES), got $(repr(mode))"),
    )
    by = marker_by === :default ? defaults.marker_by : marker_by
    by in MARKER_BY ||
        throw(ArgumentError("marker_by must be one of $(MARKER_BY), got $(repr(by))"))
    return (; style = s, format, uncertainty = mode, marker_by = by)
end

# The tags "(a)", "(b)", ... of the panels: `setting` is `:auto` (`auto` says whether to have
# them), `true`, `false` or a vector of texts.
function panel_tags(n::Integer, setting, auto::Bool)
    setting isa AbstractVector && return String.(setting)
    on = setting === :auto ? auto : Bool(setting)
    return [on ? string('(', Char('a' + (i - 1) % 26), ')') : "" for i = 1:n]
end

function with_tag(p::PanelSpec, tag::AbstractString)
    return PanelSpec(;
        (f => getfield(p, f) for f in fieldnames(PanelSpec) if f !== :tag)...,
        tag = String(tag),
    )
end

# Scatter layers, one per group of points, each with its marker.
function group_layers(
    style::PlotStyle,
    groups::Vector{PointGroup},
    x::AbstractVector{Float64},
    y::AbstractVector{Float64};
    color = nothing,
)
    layers = Layer[]
    for (k, g) in enumerate(groups)
        marker, filled = group_marker(style, k)
        c = if color === nothing
            style.palette[1]
        elseif color isa AbstractString
            String(color)
        else
            Float64.(color[g.rows])
        end
        push!(
            layers,
            Layer(;
                kind = :scatter,
                x = x[g.rows],
                y = y[g.rows],
                color = c,
                marker,
                filled,
                label = g.label,
                size = style.markersize,
            ),
        )
    end
    return layers
end

# The line of a model through its values: the points in the order of x, once for each x.
function model_line(
    x::AbstractVector{Float64},
    y::AbstractVector{Float64};
    color,
    label = "",
    linestyle = :solid,
    width = 2.0,
)
    keep = [i for i in eachindex(x) if isfinite(x[i]) && isfinite(y[i])]
    order = keep[sortperm(x[keep])]
    return Layer(;
        kind = :lines,
        x = x[order],
        y = y[order],
        color,
        label,
        linestyle,
        width,
    )
end

# The uncertainty of the points as the deviation panel shows it.
function deviation_uncertainty(spec::DeviationSpec, d::PlotData)
    spec.kind in (:relative, :absolute) || return nothing
    u = Float64.(column(d, :unc_k2))
    spec.kind === :absolute && return u
    v = abs.(Float64.(column(d, :value)))
    factor = unit_factor(spec)
    return @. factor * u / v
end

function uncertainty_layers(
    mode::Symbol,
    x::Vector{Float64},
    y::Vector{Float64},
    u,
    style::PlotStyle,
)
    (mode === :none || u === nothing) && return Layer[]
    keep = [i for i in eachindex(x) if isfinite(x[i]) && isfinite(y[i]) && isfinite(u[i])]
    isempty(keep) && return Layer[]
    mode === :auto && (mode = length(keep) <= MAX_UNCERTAINTY_BARS ? :bars : :band)
    if mode === :bars
        return [
            Layer(;
                kind = :errorbars,
                x = x[keep],
                y = y[keep],
                lower = u[keep],
                upper = u[keep],
                color = style.foreground == "none" ? "#9aa3c7" : "#8c8c8c",
                width = 1.0,
                alpha = 0.7,
            ),
        ]
    end
    # An envelope with the median uncertainty, around zero.
    m = sort(u[keep])[(length(keep)+1)÷2]
    lo, hi = extrema(x[keep])
    return [
        Layer(;
            kind = :band,
            x = [lo, hi],
            y = [0.0, 0.0],
            lower = [m, m],
            upper = [m, m],
            color = "#8c8c8c",
            alpha = 0.25,
        ),
    ]
end

function deviation_spec_of(
    deviation,
    deviation_unit,
    absolute_value;
    alpha = 0.01,
    epsilon = 1.0e-4,
)
    defaults = plot_defaults()
    kind = deviation === nothing ? defaults.deviation : deviation
    unit = deviation_unit === nothing ? defaults.deviation_unit : deviation_unit
    return DeviationSpec(kind; unit, absolute_value, alpha, epsilon)
end

# The symbol of the property of the data, or its name in roman type.
function symbol_of(property::AbstractString)
    s = property_symbol(property)
    return s === nothing ? roman_text(property) : s
end

# ----------------------------------------------------------------------------------
# Comparison with a model: values and deviations
# ----------------------------------------------------------------------------------

"""
    figure_comparison(data; x = :temperature, model, args, deviation, ...) -> FigureSpec

The two panels that compare the data with a model: the values (points by reference, the line of
the model) and, below, the deviations of the model. See [`plot_comparison`](@ref).
"""
function figure_comparison(
    data;
    x::Symbol = :temperature,
    model = nothing,
    args::Tuple = (:pressure, :temperature),
    xunit = nothing,
    yunit = nothing,
    deviation = nothing,
    deviation_unit = nothing,
    absolute_value::Bool = false,
    alpha::Real = 0.01,
    epsilon::Real = 1.0e-4,
    panel_labels = :auto,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    d = prepare_data(data, unit_keywords(x => xunit, :value => yunit); filters...)
    o = resolve_options(; opts...)
    property = only_property(d)
    spec = deviation_spec_of(deviation, deviation_unit, absolute_value; alpha, epsilon)
    xs = variable_values(d, x)
    ys = Float64.(column(d, :value))
    calc = calculated(d, model, args)
    dev = deviation!(Vector{Float64}(undef, length(d)), ys, calc, spec)
    groups = point_groups(d, o.marker_by)
    symbol = symbol_of(property)
    unit = value_unit(d, property)

    top = group_layers(o.style, groups, xs, ys)
    pushfirst!(
        top,
        model_line(
            xs,
            calc;
            color = o.style.palette[min(5, end)],
            label = model === nothing ? "calc" : "model",
        ),
    )
    bottom = group_layers(o.style, groups, xs, dev)
    pushfirst!(
        bottom,
        Layer(;
            kind = :hline,
            y = [0.0],
            color = o.style.foreground,
            linestyle = :dash,
            width = 1.0,
        ),
    )
    append!(
        bottom,
        uncertainty_layers(o.uncertainty, xs, dev, deviation_uncertainty(spec, d), o.style),
    )

    xlabel = variable_label(d, x; format = o.format)
    panels = [
        PanelSpec(;
            layers = top,
            ylabel = property_label(property, unit; format = o.format),
            colormap = o.style.colormap,
        ),
        PanelSpec(;
            layers = bottom,
            xlabel,
            ylabel = deviation_label(spec, symbol, unit; format = o.format),
            legend = false,
            colormap = o.style.colormap,
        ),
    ]
    tags = panel_tags(2, panel_labels, false)
    panels = [with_tag(p, tags[i]) for (i, p) in enumerate(panels)]
    return FigureSpec(;
        panels,
        nrows = 2,
        ncols = 1,
        style = o.style,
        heights = [3.0, 2.0],
        size = (640, 640),
        sharex = true,
    )
end

# The keywords that are options of the figure and the ones that filter the selection.
const OPTION_KEYS = (:style, :colormap, :unitformat, :uncertainty, :marker_by)
function split_options(kwargs)
    opts = Dict{Symbol,Any}()
    filters = Dict{Symbol,Any}()
    for (k, v) in kwargs
        (k in OPTION_KEYS ? opts : filters)[k] = v
    end
    return NamedTuple(opts), NamedTuple(filters)
end

# ----------------------------------------------------------------------------------
# Isotherms and isobars
# ----------------------------------------------------------------------------------

"""
    figure_lines(data, by; x, model, tol, ...) -> FigureSpec

A line of the property for each value of the condition `by` (`:temperature` for isotherms,
`:pressure` for isobars) with the colour telling the value; used by [`plot_isotherms`](@ref) and
[`plot_isobars`](@ref).
"""
function figure_lines(
    data,
    by::Symbol;
    x::Symbol = by === :temperature ? :pressure : :temperature,
    model = nothing,
    args::Tuple = (:pressure, :temperature),
    tol::Union{Nothing,Real} = nothing,
    xunit = nothing,
    yunit = nothing,
    cunit = nothing,
    xscale::Symbol = :linear,
    kwargs...,
)
    by in (:temperature, :pressure) || throw(
        ArgumentError("lines are drawn for :temperature or :pressure, got $(repr(by))"),
    )
    x === by && throw(
        ArgumentError("the x axis cannot be the condition that tells the lines apart"),
    )
    opts, filters = split_options(kwargs)
    d = prepare_data(
        data,
        unit_keywords(x => xunit, :value => yunit, by => cunit);
        filters...,
    )
    o = resolve_options(; opts...)
    property = only_property(d)
    cond = variable_values(d, by)
    xs = variable_values(d, x)
    ys = Float64.(column(d, :value))
    # Points of the same condition: temperatures within `tol`, pressures within a relative `tol`.
    clusters = if by === :temperature
        cluster_values(cond, tol === nothing ? 0.5 : tol)
    else
        cluster_values(log.(max.(cond, floatmin())), tol === nothing ? 0.01 : tol)
    end
    isempty(clusters) && throw(ArgumentError("there are no points with a value of $by"))
    level = fill(NaN, length(d))
    for c in clusters
        m = sum(cond[c]) / length(c)
        level[c] .= m
    end
    keep = findall(isfinite, level)
    sub = keep == 1:length(d) ? d : subset(d, [isfinite(l) for l in level])
    cond_keep = level[keep]
    groups = point_groups(sub, o.marker_by)
    layers = group_layers(o.style, groups, xs[keep], ys[keep]; color = cond_keep)
    if model !== nothing
        calc = model_values(sub, model; args)
        for c in clusters
            rows = [findfirst(==(i), keep) for i in c]
            push!(
                layers,
                model_line(
                    xs[keep][rows],
                    calc[rows];
                    color = Float64[level[c[1]]],
                    width = o.style.linewidth,
                ),
            )
        end
    end
    limits = extrema(cond_keep)
    limits = limits[1] == limits[2] ? (limits[1] - 1, limits[2] + 1) : limits
    colorbar = ColorbarSpec(
        variable_label(d, by; format = o.format),
        o.style.colormap,
        Float64.(limits),
    )
    panel = PanelSpec(;
        layers,
        xlabel = variable_label(d, x; format = o.format),
        ylabel = property_label(property, value_unit(d, property); format = o.format),
        xscale,
        colorbar,
        colormap = o.style.colormap,
        colorrange = Float64.(limits),
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (680, 480))
end

# ----------------------------------------------------------------------------------
# Parity
# ----------------------------------------------------------------------------------

"""
    figure_parity(data; model, bands = [1, 5, 10], ...) -> FigureSpec

The calculated value against the experimental one, with the line of equality and bands of
relative deviation (in percent). See [`plot_parity`](@ref).
"""
function figure_parity(
    data;
    model = nothing,
    args::Tuple = (:pressure, :temperature),
    bands::AbstractVector{<:Real} = [1, 5, 10],
    yunit = nothing,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    d = prepare_data(data, unit_keywords(:value => yunit); filters...)
    o = resolve_options(; opts...)
    property = only_property(d)
    unit = value_unit(d, property)
    ys = Float64.(column(d, :value))
    calc = calculated(d, model, args)
    groups = point_groups(d, o.marker_by)
    layers = group_layers(o.style, groups, calc, ys)
    finite = [v for v in vcat(calc, ys) if isfinite(v)]
    isempty(finite) && throw(ArgumentError("there are no finite values to compare"))
    lo, hi = extrema(finite)
    span = [lo, hi]
    pushfirst!(
        layers,
        Layer(; kind = :lines, x = span, y = span, color = o.style.foreground, width = 1.5),
    )
    for (k, b) in enumerate(sort(unique(Float64.(bands))))
        f = b / 100
        for s in (-1, 1)
            pushfirst!(
                layers,
                Layer(;
                    kind = :lines,
                    x = span,
                    y = span .* (1 + s * f),
                    color = o.style.foreground,
                    linestyle = :dash,
                    width = 1.0,
                    alpha = 0.6,
                    label = s == 1 ? string("\\pm ", b, raw"\,\%") : "",
                ),
            )
        end
    end
    symbol = symbol_of(property)
    panel = PanelSpec(;
        layers,
        xlabel = axis_label(string(symbol, raw"_{\mathrm{calc}}"), unit; format = o.format),
        ylabel = axis_label(string(symbol, raw"_{\mathrm{exp}}"), unit; format = o.format),
        aspect_equal = true,
        colormap = o.style.colormap,
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (560, 560))
end

# ----------------------------------------------------------------------------------
# Residuals: violin and box
# ----------------------------------------------------------------------------------

const MIN_POINTS_VIOLIN = 10

# Closed polygon of a violin at position `center`, `width` the half-width of the widest part.
function violin_polygon(center::Real, profile, width::Real)
    y = profile.y
    xs = vcat(
        center .+ width .* profile.density,
        center .- width .* reverse(profile.density),
    )
    ys = vcat(y, reverse(y))
    return Float64.(xs), Float64.(ys)
end

# The box of the quartiles with whiskers at the last point within 1.5 interquartile ranges.
function box_layers(center::Real, values::Vector{Float64}, half::Real, color::String)
    _, q1, med, q3, _ = quartiles(values)
    iqr = q3 - q1
    inside = [v for v in values if isfinite(v) && q1 - 1.5 * iqr <= v <= q3 + 1.5 * iqr]
    lo, hi = isempty(inside) ? (q1, q3) : extrema(inside)
    box = Layer(;
        kind = :polygon,
        x = [center - half, center + half, center + half, center - half],
        y = [q1, q1, q3, q3],
        color,
        alpha = 0.35,
        width = 1.5,
    )
    median_line = Layer(;
        kind = :lines,
        x = [center - half, center + half],
        y = [med, med],
        color,
        width = 2.5,
    )
    whiskers = [
        Layer(; kind = :lines, x = [center, center], y = [q3, hi], color, width = 1.5),
        Layer(; kind = :lines, x = [center, center], y = [lo, q1], color, width = 1.5),
    ]
    return Layer[box, median_line, whiskers...]
end

# The violin with its quartiles inside: the interquartile line and the median.
function violin_layers(center::Real, values::Vector{Float64}, color::String; width = 0.4)
    profile = density_profile(values)
    xs, ys = violin_polygon(center, profile, width)
    _, q1, med, q3, _ = quartiles(values)
    return Layer[
        Layer(; kind = :polygon, x = xs, y = ys, color, alpha = 0.3, width = 1.0),
        Layer(; kind = :lines, x = [center, center], y = [q1, q3], color, width = 4.0),
        Layer(;
            kind = :scatter,
            x = [center],
            y = [med],
            color = "white",
            marker = :circle,
            size = 6.0,
        ),
    ]
end

# Points spread across the width of a group in a way that does not change with the run.
jitter(i::Integer, width::Real) = (mod(i * 0.6180339887498949, 1.0) - 0.5) * width

"""
    figure_residuals(data; by = :reference, kind = :violin, model, deviation, ...) -> FigureSpec

The distribution of the deviations of each group of points (a reference by default): violins
with the points and their quartiles, boxes, or both. A group with fewer than
$MIN_POINTS_VIOLIN points has no violin (a density of so few points says nothing): it gets a
box with the points. See [`plot_residuals`](@ref).
"""
function figure_residuals(
    data;
    by::Symbol = :reference,
    kind::Symbol = :violin,
    model = nothing,
    args::Tuple = (:pressure, :temperature),
    deviation = nothing,
    deviation_unit = nothing,
    absolute_value::Bool = false,
    alpha::Real = 0.01,
    epsilon::Real = 1.0e-4,
    show_points::Bool = true,
    kwargs...,
)
    kind in (:violin, :box, :both) ||
        throw(ArgumentError("kind must be :violin, :box or :both, got $(repr(kind))"))
    opts, filters = split_options(kwargs)
    d = prepare_data(data, NamedTuple(); filters...)
    o = resolve_options(; opts...)
    property = only_property(d)
    unit = value_unit(d, property)
    spec = deviation_spec_of(deviation, deviation_unit, absolute_value; alpha, epsilon)
    ys = Float64.(column(d, :value))
    calc = calculated(d, model, args)
    dev = deviation!(Vector{Float64}(undef, length(d)), ys, calc, spec)
    groups = point_groups(d, by)
    layers = Layer[spec.kind === :smape ?
          Layer(; kind = :hline, y = [0.0], color = o.style.foreground, alpha = 0.0) :
          Layer(;
        kind = :hline,
        y = [0.0],
        color = o.style.foreground,
        linestyle = :dash,
        width = 1.0,
    )]
    for (k, g) in enumerate(groups)
        values = [v for v in dev[g.rows] if isfinite(v)]
        isempty(values) && continue
        color = o.style.palette[mod1(k, length(o.style.palette))]
        if length(values) >= MIN_POINTS_VIOLIN && kind !== :box
            append!(layers, violin_layers(k, values, color))
            kind === :both && append!(layers, box_layers(k, values, 0.08, color))
        else
            append!(layers, box_layers(k, values, 0.25, color))
        end
        if show_points
            marker, filled = group_marker(o.style, k)
            push!(
                layers,
                Layer(;
                    kind = :scatter,
                    x = [k + jitter(i, 0.3) for i in eachindex(values)],
                    y = values,
                    color,
                    marker,
                    filled,
                    size = max(o.style.markersize - 3, 3.0),
                    alpha = 0.7,
                    label = g.label,
                ),
            )
        end
    end
    symbol = symbol_of(property)
    panel = PanelSpec(;
        layers,
        ylabel = deviation_label(spec, symbol, unit; format = o.format),
        xticks = (Float64.(1:length(groups)), [g.label for g in groups]),
        legend = false,
        colormap = o.style.colormap,
    )
    return FigureSpec(;
        panels = [panel],
        style = o.style,
        size = (max(480, 90 * length(groups) + 160), 480),
    )
end

# ----------------------------------------------------------------------------------
# Where the data are: the plane of temperature and pressure
# ----------------------------------------------------------------------------------

"""
    figure_xpt(data; color = :value, highlight = nothing, bins = (30, 30), ...) -> FigureSpec

The plane of temperature and pressure of the points, with the colour telling the value of the
property (or another variable of the table), or with `color = :count` the number of points in
each cell. `highlight` (a DOI, a `Regex`, a vector of them or a function of the DOI) draws the
points of those references as stars, labelled `highlight_label` ("This work"). See
[`plot_xpt`](@ref).
"""
function figure_xpt(
    data;
    x::Symbol = :temperature,
    y::Symbol = :pressure,
    color::Symbol = :value,
    highlight = nothing,
    highlight_label::AbstractString = "This work",
    bins::NTuple{2,Int} = (30, 30),
    xunit = nothing,
    yunit = nothing,
    cunit = nothing,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    d = prepare_data(
        data,
        unit_keywords(x => xunit, y => yunit, color => cunit);
        filters...,
    )
    o = resolve_options(; opts...)
    xs = variable_values(d, x)
    ys = variable_values(d, y)
    xlabel = variable_label(d, x; format = o.format)
    ylabel = variable_label(d, y; format = o.format)
    if color === :count
        return xpt_counts(d, xs, ys, xlabel, ylabel, bins, o)
    end
    cs = variable_values(d, color)
    mask = highlight === nothing ? falses(length(d)) : highlight_mask(d, highlight)
    base = findall(.!mask)
    layers = Layer[]
    if !isempty(base)
        sub = length(base) == length(d) ? d : subset(d, .!mask)
        groups = point_groups(sub, o.marker_by)
        append!(layers, group_layers(o.style, groups, xs[base], ys[base]; color = cs[base]))
    end
    star = findall(mask)
    if !isempty(star)
        push!(
            layers,
            Layer(;
                kind = :scatter,
                x = xs[star],
                y = ys[star],
                color = cs[star],
                marker = :star5,
                filled = true,
                label = String(highlight_label),
                size = o.style.markersize * 1.8,
            ),
        )
    end
    finite = [v for v in cs if isfinite(v)]
    isempty(finite) &&
        throw(ArgumentError("the variable $(repr(color)) has no finite values"))
    limits = extrema(finite)
    limits = limits[1] == limits[2] ? (limits[1] - 1, limits[2] + 1) : limits
    colorbar = ColorbarSpec(
        variable_label(d, color; format = o.format),
        o.style.colormap,
        Float64.(limits),
    )
    panel = PanelSpec(;
        layers,
        xlabel,
        ylabel,
        colorbar,
        colormap = o.style.colormap,
        colorrange = Float64.(limits),
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (680, 480))
end

# Which points belong to the references to highlight.
function highlight_mask(d::PlotData, highlight)
    labels = reference_labels(d)
    test = if highlight isa Function
        highlight
    elseif highlight isa Regex
        s -> occursin(highlight, s)
    elseif highlight isa AbstractString
        s -> s == highlight
    else
        wanted = Set(String.(highlight))
        s -> s in wanted
    end
    return BitVector([Bool(test(l)) for l in labels])
end

function xpt_counts(d, xs, ys, xlabel, ylabel, bins, o)
    all(isfinite, xs) && all(isfinite, ys) || (
        keep = [i for i in eachindex(xs) if isfinite(xs[i]) && isfinite(ys[i])];
        xs = xs[keep];
        ys = ys[keep]
    )
    isempty(xs) && throw(ArgumentError("there are no points to count"))
    nx, ny = bins
    x0, x1 = extrema(xs)
    y0, y1 = extrema(ys)
    x1 == x0 && (x1 = x0 + 1)
    y1 == y0 && (y1 = y0 + 1)
    xe = collect(range(x0, x1; length = nx + 1))
    ye = collect(range(y0, y1; length = ny + 1))
    counts = zeros(nx, ny)
    for i in eachindex(xs)
        ix = min(nx, 1 + floor(Int, (xs[i] - x0) / (x1 - x0) * nx))
        iy = min(ny, 1 + floor(Int, (ys[i] - y0) / (y1 - y0) * ny))
        counts[ix, iy] += 1
    end
    z = replace(counts, 0.0 => NaN)
    limits = (1.0, maximum(counts))
    limits = limits[1] == limits[2] ? (0.0, limits[2]) : limits
    layer = Layer(; kind = :heatmap, x = xe, y = ye, z)
    colorbar = ColorbarSpec(raw"\mathrm{points}", o.style.counts, limits)
    panel = PanelSpec(;
        layers = [layer],
        xlabel,
        ylabel,
        colorbar,
        legend = false,
        colormap = o.style.counts,
        colorrange = limits,
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (680, 480))
end

# ----------------------------------------------------------------------------------
# Facets: one panel per property or per group
# ----------------------------------------------------------------------------------

"""
    figure_facets(data; by = :property, x = :temperature, color = nothing, ncols, ...) -> FigureSpec

A grid of panels of the value against `x`, one for each property (`by = :property`, each with
its own unit) or for each reference, method or phase of one property. With `color` (a variable of
the table, `:pressure` for instance) the points are coloured and there is one colour bar for
all the panels. The panels are tagged (a), (b), ... See [`plot_facets`](@ref) and
[`plot_by_reference`](@ref).
"""
function figure_facets(
    data;
    by::Symbol = :property,
    x::Symbol = :temperature,
    color::Union{Nothing,Symbol} = nothing,
    ncols::Union{Nothing,Integer} = nothing,
    maxpanels::Integer = 12,
    xunit = nothing,
    cunit = nothing,
    panel_labels = :auto,
    kwargs...,
)
    by in (:property, :reference, :method, :phase) || throw(
        ArgumentError(
            "facets are made by :property, :reference, :method or :phase, got $(repr(by))",
        ),
    )
    opts, filters = split_options(kwargs)
    d = prepare_data(data, unit_keywords(x => xunit, color => cunit); filters...)
    marker_by = get(opts, :marker_by, :default)
    o = resolve_options(; opts...)
    # The pieces: (label, data).
    pieces = if by === :property
        split_properties(d)
    else
        only_property(d)
        [
            (g.label, subset(d, [i in Set(g.rows) for i = 1:length(d)])) for
            g in point_groups(d, by; maxgroups = maxpanels)
        ]
    end
    length(pieces) <= maxpanels || throw(
        ArgumentError(
            "there are $(length(pieces)) panels; select fewer properties or raise `maxpanels` (now $maxpanels)",
        ),
    )
    inner_by =
        marker_by === :default ? (by === :property ? o.marker_by : nothing) : o.marker_by
    all_color = color === nothing ? Float64[] : variable_values(d, color)
    limits = if color === nothing
        nothing
    else
        finite = [v for v in all_color if isfinite(v)]
        isempty(finite) ? nothing :
        (extrema(finite) |> e -> e[1] == e[2] ? (e[1] - 1, e[2] + 1) : e)
    end
    panels = PanelSpec[]
    for (label, piece) in pieces
        property = only_property(piece)
        xs = variable_values(piece, x)
        ys = Float64.(column(piece, :value))
        groups = point_groups(piece, inner_by)
        cs = color === nothing ? nothing : variable_values(piece, color)
        layers = group_layers(o.style, groups, xs, ys; color = cs)
        push!(
            panels,
            PanelSpec(;
                layers,
                xlabel = variable_label(piece, x; format = o.format),
                ylabel = property_label(
                    property,
                    value_unit(piece, property);
                    format = o.format,
                ),
                title = by === :property ? "" : label,
                legend = inner_by !== nothing,
                colormap = o.style.colormap,
                colorrange = limits === nothing ? nothing : Float64.(limits),
            ),
        )
    end
    n = length(panels)
    nc = ncols === nothing ? min(3, n) : min(Int(ncols), n)
    nr = cld(n, nc)
    tags = panel_tags(n, panel_labels, n > 1)
    panels = [with_tag(p, tags[i]) for (i, p) in enumerate(panels)]
    colorbar =
        limits === nothing ? nothing :
        ColorbarSpec(
            variable_label(d, color; format = o.format),
            o.style.colormap,
            Float64.(limits),
        )
    return FigureSpec(;
        panels,
        nrows = nr,
        ncols = nc,
        style = o.style,
        colorbar,
        size = (340 * nc + (colorbar === nothing ? 0 : 80), 300 * nr),
    )
end
