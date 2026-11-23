# From a `FigureSpec` to Plots, as a recipe.

# The text of a label as Plots draws mathematics.
tex(s::AbstractString) = isempty(s) ? "" : LaTeXString(string('$', s, '$'))
tex_label(s::AbstractString) = startswith(s, "\\") ? tex(s) : String(s)

function color_of(text::AbstractString)
    text == "none" && return Plots.RGBA(0, 0, 0, 0)
    return Plots.plot_color(text)
end

# A colour of a category that is too light to be seen on a white page is darkened a little.
function visible_color(text::AbstractString)
    c = color_of(text)
    luminance = 0.2126 * Plots.red(c) + 0.7152 * Plots.green(c) + 0.0722 * Plots.blue(c)
    (text in ("white", "none") || luminance < 0.6) && return c
    k = (luminance - 0.6) + 0.15
    return Plots.RGBA(
        (1 - k) * Plots.red(c),
        (1 - k) * Plots.green(c),
        (1 - k) * Plots.blue(c),
        Plots.alpha(c),
    )
end

function gradient_of(map::Symbol)
    name = String(map)
    endswith(name, "_r") && return Plots.cgrad(Symbol(name[1:(end-2)]); rev = true)
    return Plots.cgrad(map)
end
gradient_of(colors::AbstractVector{<:AbstractString}) = Plots.cgrad(color_of.(colors))

function mapped_colors(values::AbstractVector{Float64}, gradient, range)
    lo, hi = range
    span = hi == lo ? 1.0 : hi - lo
    return [gradient[clamp((v - lo) / span, 0.0, 1.0)] for v in values]
end

# The colour of a layer: one colour, or one for each point.
function layer_colors(layer::T.Layer, panel::T.PanelSpec, style::T.PlotStyle, n::Integer)
    c = layer.color
    c === nothing && return color_of(style.foreground)
    c isa AbstractString && return visible_color(c)
    values = length(c) == n ? c : fill(c[1], n)
    range = panel.colorrange === nothing ? extrema(values) : panel.colorrange
    return mapped_colors(values, gradient_of(panel.colormap), range)
end

with_alpha(c, a) =
    Plots.RGBA(Plots.red(c), Plots.green(c), Plots.blue(c), a * Plots.alpha(c))
with_alpha(c::AbstractVector, a) = [with_alpha(x, a) for x in c]

# Centres of the cells that have `edges`.
centers(edges) = [(edges[i] + edges[i+1]) / 2 for i = 1:(length(edges)-1)]

# The range of the data of the other layers of a panel, for the lines that cross it.
function panel_span(panel::T.PanelSpec, kind::Symbol)
    values = Float64[]
    for l in panel.layers
        l.kind in (:hline, :vline) && continue
        append!(values, kind === :hline ? l.x : l.y)
    end
    finite = filter(isfinite, values)
    isempty(finite) && return (0.0, 1.0)
    return extrema(finite)
end

# The data and the attributes of the series that draws a layer.
function layer_series(layer::T.Layer, panel::T.PanelSpec, style::T.PlotStyle, span)
    attrs = Dict{Symbol,Any}(:label => isempty(layer.label) ? "" : tex_label(layer.label))
    kind = layer.kind
    x, y = layer.x, layer.y
    if kind === :scatter
        c = layer_colors(layer, panel, style, length(x))
        c = with_alpha(c, layer.alpha)
        attrs[:seriestype] = :scatter
        attrs[:marker] = layer.marker
        attrs[:markersize] = (layer.size > 0 ? layer.size : style.markersize) * 0.45
        if layer.filled
            attrs[:markercolor] = c
            attrs[:markerstrokewidth] = 0
        else
            attrs[:markercolor] = Plots.RGBA(0, 0, 0, 0)
            attrs[:markerstrokecolor] = c
            attrs[:markerstrokewidth] = 1.5
        end
    elseif kind === :lines
        c = layer_colors(layer, panel, style, length(x))
        c isa AbstractVector && (c = c[1])
        attrs[:seriestype] = :path
        attrs[:linecolor] = with_alpha(c, layer.alpha)
        attrs[:linewidth] = layer.width > 0 ? layer.width : style.linewidth
        attrs[:linestyle] = layer.linestyle
    elseif kind === :band
        c = layer_colors(layer, panel, style, length(x))
        attrs[:seriestype] = :path
        attrs[:ribbon] = (layer.lower, layer.upper)
        attrs[:fillalpha] = layer.alpha
        attrs[:fillcolor] = c
        attrs[:linewidth] = 0
        attrs[:linecolor] = Plots.RGBA(0, 0, 0, 0)
    elseif kind === :errorbars
        c = layer_colors(layer, panel, style, length(x))
        attrs[:seriestype] = :scatter
        attrs[:yerror] = (layer.lower, layer.upper)
        attrs[:markersize] = 0
        attrs[:markerstrokewidth] = 0
        attrs[:linecolor] = with_alpha(c, layer.alpha)
        attrs[:markerstrokecolor] = with_alpha(c, layer.alpha)
        attrs[:linewidth] = layer.width > 0 ? layer.width : 1.0
    elseif kind === :polygon
        c = layer_colors(layer, panel, style, length(x))
        attrs[:seriestype] = :shape
        attrs[:fillcolor] = with_alpha(c, layer.alpha)
        attrs[:linecolor] = c
        attrs[:linewidth] = layer.width > 0 ? layer.width : 1.0
    elseif kind === :heatmap
        attrs[:seriestype] = :heatmap
        attrs[:seriescolor] = gradient_of(panel.colormap)
        panel.colorrange === nothing || (attrs[:clims] = panel.colorrange)
        x, y = centers(layer.x), centers(layer.y)
        return x, y, permutedims(layer.z), attrs
    elseif kind === :hline
        c = layer_colors(layer, panel, style, 1)
        attrs[:seriestype] = :path
        attrs[:linecolor] = with_alpha(c, layer.alpha)
        attrs[:linestyle] = layer.linestyle
        attrs[:linewidth] = layer.width > 0 ? layer.width : 1.0
        xlo, xhi = span
        return [xlo, xhi], fill(layer.y[1], 2), nothing, attrs
    elseif kind === :vline
        c = layer_colors(layer, panel, style, 1)
        attrs[:seriestype] = :path
        attrs[:linecolor] = with_alpha(c, layer.alpha)
        attrs[:linestyle] = layer.linestyle
        attrs[:linewidth] = layer.width > 0 ? layer.width : 1.0
        ylo, yhi = span
        return fill(layer.x[1], 2), [ylo, yhi], nothing, attrs
    else
        throw(ArgumentError("the layer kind $(repr(kind)) is not drawn"))
    end
    return x, y, nothing, attrs
end

# The data of the colour bar: two invisible points that carry the colour scale.
function bar_series(bar::T.ColorbarSpec, anchor::T.Layer)
    x = isempty(anchor.x) ? 0.0 : anchor.x[1]
    y = isempty(anchor.y) ? 0.0 : anchor.y[1]
    attrs = Dict{Symbol,Any}(
        :seriestype => :scatter,
        :label => "",
        :markersize => 0,
        :markerstrokewidth => 0,
        :marker_z => collect(bar.limits),
        :clims => bar.limits,
        :seriescolor => gradient_of(bar.colormap),
        :colorbar => true,
        :colorbar_title => tex(bar.label),
    )
    return [x, x], [y, y], attrs
end

# The attributes of the subplot of a panel; Plots takes them from the last series of the subplot,
# so every series carries them.
function subplot_attributes(spec::T.FigureSpec, panel::T.PanelSpec)
    with_legend = panel.legend && any(l -> !isempty(l.label), panel.layers)
    a = Dict{Symbol,Any}(
        :xguide => tex(panel.xlabel),
        :yguide => tex(panel.ylabel),
        :title =>
            isempty(panel.tag) ? panel.title : string(panel.tag, ' ', panel.title),
        :titlelocation => :left,
        :xscale => panel.xscale === :log10 ? :log10 : :identity,
        :yscale => panel.yscale === :log10 ? :log10 : :identity,
        :legend =>
            with_legend ?
            (
                length(spec.panels) == 1 &&
                spec.colorbar === nothing &&
                panel.colorbar === nothing ? :outerright : :best
            ) : false,
        :legend_font_pointsize => 8,
        :background_color_legend => Plots.RGBA(1, 1, 1, 0),
        :foreground_color_legend => Plots.RGBA(0, 0, 0, 0),
        :colorbar => (panel.colorbar !== nothing || spec.colorbar !== nothing),
    )
    panel.aspect_equal && (a[:aspect_ratio] = :equal)
    if panel.limits !== nothing
        a[:xlims] = panel.limits[1:2]
        a[:ylims] = panel.limits[3:4]
    end
    if panel.xticks !== nothing
        a[:xticks] = (panel.xticks[1], panel.xticks[2])
        a[:xrotation] = 30
    end
    return a
end

@recipe function f(spec::T.FigureSpec)
    style = spec.style
    layout := (spec.nrows, spec.ncols)
    size := spec.size
    background_color := color_of(style.background)
    foreground_color := color_of(style.foreground)
    legend := false
    grid := false
    framestyle := :box
    tickfontsize := 8
    guidefontsize := 10
    titlefontsize := 10
    for (k, panel) in enumerate(spec.panels)
        sub = subplot_attributes(spec, panel)
        for (j, layer) in enumerate(panel.layers)
            @series begin
                subplot := k
                merge!(plotattributes, sub)
                x, y, z, attrs =
                    layer_series(layer, panel, style, panel_span(panel, layer.kind))
                merge!(plotattributes, attrs)
                z === nothing ? (y === nothing ? (x,) : (x, y)) : (x, y, z)
            end
        end
        bar = panel.colorbar === nothing ? spec.colorbar : panel.colorbar
        if bar !== nothing && !isempty(panel.layers)
            @series begin
                subplot := k
                x, y, attrs = bar_series(bar, first(panel.layers))
                merge!(plotattributes, sub)
                merge!(plotattributes, attrs)
                (x, y)
            end
        end
    end
    return nothing
end

# A recipe for the points: `plot(data; kind = :xpt, ...)` draws the figure that `kind` names
# (`:comparison`, `:isotherms`, `:isobars`, `:parity`, `:residuals`, `:xpt`, `:facets`,
# `:by_reference`); the other keywords are those of the figure.
const KINDS = (
    comparison = T.figure_comparison,
    isotherms = (d; kw...) -> T.figure_lines(d, :temperature; kw...),
    isobars = (d; kw...) -> T.figure_lines(d, :pressure; kw...),
    parity = T.figure_parity,
    residuals = T.figure_residuals,
    xpt = T.figure_xpt,
    facets = T.figure_facets,
    by_reference = (d; kw...) -> T.figure_facets(d; by = :reference, kw...),
)

@recipe function f(data::T.PlotData; kind = :xpt, options = NamedTuple())
    haskey(KINDS, kind) ||
        throw(ArgumentError("kind must be one of $(keys(KINDS)), got $(repr(kind))"))
    return KINDS[kind](data; options...)
end

function draw_figure(spec::T.FigureSpec)
    return Plots.plot(spec)
end

# The figures in a subplot are not offered: Plots draws a figure whole.
