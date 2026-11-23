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
    elseif kind === :text
        c = layer_colors(layer, panel, style, 1)
        c isa AbstractVector && (c = c[1])
        size =
            max(5, round(Int, (layer.size > 0 ? layer.size : style.fontsize * 0.8) * 0.65))
        attrs[:seriestype] = :scatter
        attrs[:markersize] = 0
        attrs[:markerstrokewidth] = 0
        attrs[:markeralpha] = 0
        attrs[:label] = ""
        attrs[:series_annotations] =
            [Plots.text(s, size, with_alpha(c, layer.alpha)) for s in layer.text]
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
    panel.frame || (a[:framestyle] = :none)
    if panel.limits !== nothing
        any(isnan, panel.limits[1:2]) || (a[:xlims] = panel.limits[1:2])
        any(isnan, panel.limits[3:4]) || (a[:ylims] = panel.limits[3:4])
    end
    if panel.xticks !== nothing
        a[:xticks] = (panel.xticks[1], panel.xticks[2])
        a[:xrotation] = 30
    end
    return a
end

# The entries of the legends of all the panels, once each: (label, layer).
function legend_entries(spec::T.FigureSpec)
    seen = Set{String}()
    entries = Tuple{String,T.Layer}[]
    for panel in spec.panels, layer in panel.layers
        isempty(layer.label) && continue
        layer.label in seen && continue
        push!(seen, layer.label)
        push!(entries, (layer.label, layer))
    end
    return entries
end

# More entries than this have no room inside a panel: they go to a panel of their own, at the right.
const MAX_INNER_LEGEND = 6

# The share of the width that a shared legend takes: the pixels that the builders reserve for it.
legend_width(spec::T.FigureSpec) = clamp(T.LEGEND_PIXELS / spec.size[1], 0.2, 0.35)

@recipe function f(spec::T.FigureSpec)
    style = spec.style
    entries = legend_entries(spec)
    shared = length(entries) > MAX_INNER_LEGEND && any(p -> p.legend, spec.panels)
    nr, nc = spec.nrows, spec.ncols
    # With a shared legend the grid has one more column; panel i is at (row, column) of the old one.
    slot(i) = shared ? ((i - 1) ÷ nc) * (nc + 1) + (i - 1) % nc + 1 : i
    if shared
        lw = legend_width(spec)
        layout := Plots.grid(nr, nc + 1; widths = vcat(fill((1 - lw) / nc, nc), lw))
        size := spec.size
    else
        if length(spec.heights) == nr
            layout := Plots.grid(nr, nc; heights = spec.heights ./ sum(spec.heights))
        else
            layout := (nr, nc)
        end
        size := spec.size
    end
    background_color := color_of(style.background)
    foreground_color := color_of(style.foreground)
    legend := false
    grid := false
    framestyle := :box
    tickfontsize := 8
    guidefontsize := 10
    titlefontsize := 10
    left_margin := 6 * Plots.mm
    bottom_margin := 4 * Plots.mm
    right_margin := 3 * Plots.mm
    for (k, panel) in enumerate(spec.panels)
        sub = subplot_attributes(spec, panel)
        shared && (sub[:legend] = false)
        for (j, layer) in enumerate(panel.layers)
            @series begin
                subplot := slot(k)
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
                subplot := slot(k)
                x, y, attrs = bar_series(bar, first(panel.layers))
                merge!(plotattributes, sub)
                merge!(plotattributes, attrs)
                (x, y)
            end
        end
    end
    if shared
        used = Set(slot(k) for k in eachindex(spec.panels))
        blank = Dict{Symbol,Any}(
            :framestyle => :none,
            :legend => false,
            :xlims => (1, 2),
            :ylims => (1, 2),
            :colorbar => false,
            :label => "",
        )
        # The empty places of the grid and the first place of the last column, for the legend.
        for position = 1:(nr*(nc+1))
            position in used && continue
            col = (position - 1) % (nc + 1) + 1
            (col == nc + 1 && position == nc + 1) && continue
            @series begin
                subplot := position
                merge!(plotattributes, blank)
                seriestype := :scatter
                markersize := 0
                ([0.0], [0.0])
            end
        end
        for (label, layer) in entries
            @series begin
                subplot := nc + 1
                merge!(plotattributes, blank)
                plotattributes[:legend] = :left
                plotattributes[:legend_font_pointsize] = 7
                plotattributes[:foreground_color_legend] = Plots.RGBA(0, 0, 0, 0)
                plotattributes[:background_color_legend] = Plots.RGBA(0, 0, 0, 0)
                plotattributes[:label] = tex_label(label)
                c =
                    layer.color isa AbstractString ? visible_color(layer.color) :
                    color_of(style.foreground)
                if layer.kind === :scatter
                    seriestype := :scatter
                    marker := layer.marker
                    markersize := 4
                    if layer.filled
                        markercolor := c
                        markerstrokewidth := 0
                    else
                        markercolor := Plots.RGBA(0, 0, 0, 0)
                        markerstrokecolor := c
                        markerstrokewidth := 1.2
                    end
                else
                    seriestype := :path
                    linecolor := c
                    linewidth := layer.width > 0 ? layer.width : style.linewidth
                    linestyle := layer.linestyle
                end
                ([0.0], [0.0])
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
    pxy = (d; kw...) -> T.figure_vle(d, :temperature; kw...),
    txy = (d; kw...) -> T.figure_vle(d, :pressure; kw...),
    xy = T.figure_xy,
    saturation = T.figure_saturation,
    deviation_map = T.figure_deviation_map,
    excess = T.figure_excess,
    ternary = T.figure_ternary,
    years = T.figure_years,
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
