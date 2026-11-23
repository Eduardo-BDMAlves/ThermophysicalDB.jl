# The second cycle of figures: the deviation in the plane of two conditions, the excess
# properties against the composition, the ternary diagram and the points of each year. All are
# made of the layers of the first cycle (and `:text`), so both backends draw them.

# ----------------------------------------------------------------------------------
# Deviation in the plane of the conditions
# ----------------------------------------------------------------------------------

function figure_deviation_map(
    data;
    model = nothing,
    args::Tuple = (:pressure, :temperature),
    x::Symbol = :temperature,
    y::Symbol = :pressure,
    xunit = nothing,
    yunit = nothing,
    deviation = nothing,
    deviation_unit = nothing,
    absolute_value::Bool = false,
    alpha::Real = 0.01,
    epsilon::Real = 1.0e-4,
    limit::Union{Nothing,Real} = nothing,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    d = prepare_data(data, unit_keywords(x => xunit, y => yunit); filters...)
    o = resolve_options(; opts...)
    property = only_property(d)
    spec = deviation_spec_of(deviation, deviation_unit, absolute_value; alpha, epsilon)
    xs = variable_values(d, x)
    ys = variable_values(d, y)
    values = Float64.(column(d, :value))
    calc = calculated(d, model, args)
    dev = deviation!(Vector{Float64}(undef, length(d)), values, calc, spec)
    finite = [v for v in dev if isfinite(v)]
    isempty(finite) && throw(ArgumentError("the deviation has no finite values"))
    # The map is centred on zero unless the deviation is an absolute value.
    top = limit === nothing ? maximum(abs, finite) : Float64(limit)
    top = top > 0 ? top : 1.0
    range = absolute_value ? (0.0, top) : (-top, top)
    colormap = absolute_value ? o.style.colormap : o.style.diverging
    groups = point_groups(d, o.marker_by)
    layers = group_layers(o.style, groups, xs, ys; color = dev)
    label = deviation_label(
        spec,
        symbol_of(property),
        value_unit(d, property);
        format = o.format,
    )
    panel = PanelSpec(;
        layers,
        xlabel = variable_label(d, x; format = o.format),
        ylabel = variable_label(d, y; format = o.format),
        colorbar = ColorbarSpec(label, colormap, range),
        colormap,
        colorrange = range,
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (680, 480))
end

# ----------------------------------------------------------------------------------
# Excess properties against the composition
# ----------------------------------------------------------------------------------

# One panel for each property, with the mole fraction of the first component on the x axis; the
# points of every reference are in the panel (a line at zero shows where the excess changes sign).
function figure_excess(data; x::Symbol = :x1, kwargs...)
    return figure_facets(data; x, kwargs...)
end

# ----------------------------------------------------------------------------------
# Ternary diagram
# ----------------------------------------------------------------------------------

const SQRT3_2 = sqrt(3) / 2

# The point of the triangle with the vertices (0, 0), (1, 0) and (1/2, sqrt(3)/2) for the
# fractions `a`, `b`, `c` of the three components (the vertex of the first component is the
# lower left one, the second the lower right and the third the top).
ternary_xy(b::Real, c::Real) = (b + c / 2, c * SQRT3_2)

function figure_ternary(
    data;
    color::Symbol = :value,
    components::Union{Nothing,AbstractString} = nothing,
    grid::Integer = 5,
    cunit = nothing,
    kwargs...,
)
    opts, filters = split_options(kwargs)
    d = prepare_data(data, unit_keywords(color => cunit); filters...)
    o = resolve_options(; opts...)
    names = column(d, :components)
    system = if components === nothing
        counts = Dict{String,Int}()
        for n in names
            counts[String(n)] = get(counts, String(n), 0) + 1
        end
        isempty(counts) && throw(ArgumentError("there are no points"))
        first(sort!(collect(counts); by = last, rev = true))[1]
    else
        String(components)
    end
    rows = findall(==(system), [String(n) for n in names])
    isempty(rows) && throw(ArgumentError("no point has the components $(repr(system))"))
    parts = String.(strip.(split(system, '+')))
    length(parts) == 3 || throw(
        ArgumentError(
            "a ternary diagram needs a system of 3 components; $(repr(system)) has $(length(parts)). Select one with `component = [...], exact = true`",
        ),
    )
    sub = length(rows) == length(d) ? d : subset_data(d, rows_mask(rows, length(d)))
    x1 = Float64.(column(sub, :x1))
    x2 = Float64.(column(sub, :x2))
    x3 = Float64.(column(sub, :x3))
    # The third fraction that the data do not give is what is left.
    for i in eachindex(x3)
        isfinite(x3[i]) || (x3[i] = 1 - x1[i] - x2[i])
    end
    keep =
        findall(i -> isfinite(x1[i]) && isfinite(x2[i]) && isfinite(x3[i]), eachindex(x1))
    isempty(keep) && throw(ArgumentError("the points have no compositions"))
    xy = [ternary_xy(x2[i], x3[i]) for i in keep]
    xs = first.(xy)
    ys = last.(xy)

    fg = o.style.foreground
    layers = Layer[]
    n = max(Int(grid), 1)
    for k = 1:(n-1)
        t = k / n
        # Lines of constant fraction of each component.
        for (p, q) in (
            (ternary_xy(1 - t, 0.0), ternary_xy(0.0, 1 - t)),
            (ternary_xy(t, 0.0), ternary_xy(t, 1 - t)),
            (ternary_xy(0.0, t), ternary_xy(1 - t, t)),
        )
            push!(
                layers,
                Layer(;
                    kind = :lines,
                    x = [p[1], q[1]],
                    y = [p[2], q[2]],
                    color = fg,
                    alpha = 0.18,
                    width = 0.8,
                ),
            )
        end
    end
    push!(
        layers,
        Layer(;
            kind = :lines,
            x = [0.0, 1.0, 0.5, 0.0],
            y = [0.0, 0.0, SQRT3_2, 0.0],
            color = fg,
            width = 1.2,
        ),
    )
    # The ticks along the edges: the fraction of the second component on the bottom edge, of the
    # third on the right edge and of the first on the left edge.
    tx = Float64[]
    ty = Float64[]
    tt = String[]
    for k = 1:(n-1)
        t = k / n
        label = string(round(t; digits = 2))
        p = ternary_xy(t, 0.0)
        push!(tx, p[1])
        push!(ty, p[2] - 0.04)
        push!(tt, label)
        p = ternary_xy(1 - t, t)
        push!(tx, p[1] + 0.045)
        push!(ty, p[2] + 0.02)
        push!(tt, label)
        p = ternary_xy(0.0, 1 - t)
        push!(tx, p[1] - 0.045)
        push!(ty, p[2] + 0.02)
        push!(tt, label)
    end
    push!(layers, Layer(; kind = :text, x = tx, y = ty, text = tt, alpha = 0.7))
    push!(
        layers,
        Layer(;
            kind = :text,
            x = [-0.02, 1.02, 0.5],
            y = [-0.07, -0.07, SQRT3_2 + 0.06],
            text = parts,
            size = o.style.fontsize,
        ),
    )

    cs = variable_values(sub, color)[keep]
    finite = [v for v in cs if isfinite(v)]
    isempty(finite) &&
        throw(ArgumentError("the variable $(repr(color)) has no finite values"))
    limits = extrema(finite)
    limits = limits[1] == limits[2] ? (limits[1] - 1, limits[2] + 1) : limits
    keep_data =
        length(keep) == length(sub) ? sub : subset_data(sub, rows_mask(keep, length(sub)))
    groups = point_groups(keep_data, o.marker_by)
    append!(layers, group_layers(o.style, groups, xs, ys; color = cs))
    panel = PanelSpec(;
        layers,
        colorbar = ColorbarSpec(
            variable_label(sub, color; format = o.format),
            o.style.colormap,
            Float64.(limits),
        ),
        colormap = o.style.colormap,
        colorrange = Float64.(limits),
        aspect_equal = true,
        frame = false,
        limits = (-0.12, 1.12, -0.12, SQRT3_2 + 0.12),
    )
    return FigureSpec(; panels = [panel], style = o.style, size = (640, 560))
end

# ----------------------------------------------------------------------------------
# Points of each year
# ----------------------------------------------------------------------------------

# The outline of the bars of a histogram of unit width centred on each year.
function bars_outline(years::Vector{Float64}, counts::Vector{Float64})
    x = Float64[years[1]-0.4]
    y = Float64[0.0]
    for (t, c) in zip(years, counts)
        append!(x, (t - 0.4, t + 0.4))
        append!(y, (c, c))
    end
    push!(x, years[end] + 0.4)
    push!(y, 0.0)
    return x, y
end

function figure_years(data; cumulative::Bool = true, panel_labels = :auto, kwargs...)
    opts, filters = split_options(kwargs)
    d = prepare_data(data, NamedTuple(); filters...)
    o = resolve_options(; opts...)
    year = column(d, :year)
    known = sort!(Float64[y for y in year if y > 0])
    isempty(known) && throw(ArgumentError("the points have no year"))
    years = collect(minimum(known):maximum(known))
    counts = zeros(length(years))
    for y in known
        counts[Int(y-years[1])+1] += 1
    end
    bx, by = bars_outline(years, counts)
    panels = [
        PanelSpec(;
            layers = [
                Layer(;
                    kind = :polygon,
                    x = bx,
                    y = by,
                    color = o.style.palette[1],
                    alpha = 0.6,
                    width = 1.0,
                ),
            ],
            xlabel = variable_label(d, :year; format = o.format),
            ylabel = roman_text("points"),
            legend = false,
            colormap = o.style.colormap,
        ),
    ]
    if cumulative
        push!(
            panels,
            PanelSpec(;
                layers = [
                    Layer(;
                        kind = :lines,
                        x = years,
                        y = cumsum(counts),
                        color = o.style.palette[min(2, end)],
                        width = 2.0,
                    ),
                ],
                xlabel = variable_label(d, :year; format = o.format),
                ylabel = roman_text("cumulative points"),
                legend = false,
                colormap = o.style.colormap,
            ),
        )
    end
    tags = panel_tags(length(panels), panel_labels, length(panels) > 1)
    panels = [with_tag(p, tags[i]) for (i, p) in enumerate(panels)]
    return FigureSpec(;
        panels,
        nrows = 1,
        ncols = length(panels),
        style = o.style,
        size = (length(panels) == 1 ? 600 : 1000, 420),
    )
end
