# From a `FigureSpec` to Makie.

# The text of a label as Makie draws mathematics: LaTeX between dollar signs.
tex(s::AbstractString) = isempty(s) ? "" : LaTeXString(string('$', s, '$'))

# A colour given as text ("white", "#3347ff") or "none".
function color_of(text::AbstractString)
    text == "none" && return Makie.RGBAf(0, 0, 0, 0)
    return Makie.to_color(text)
end

# A colour of a category that is too light to be seen on a white page is darkened a little.
function visible_color(text::AbstractString)
    c = color_of(text)
    luminance = 0.2126 * Makie.red(c) + 0.7152 * Makie.green(c) + 0.0722 * Makie.blue(c)
    (text in ("white", "none") || luminance < 0.6) && return c
    k = 0.4 * (luminance - 0.6) / 0.4 + 0.15
    return Makie.RGBAf(
        (1 - k) * Makie.red(c),
        (1 - k) * Makie.green(c),
        (1 - k) * Makie.blue(c),
        Makie.alpha(c),
    )
end

# A colour map given as a name of a colour scheme (a trailing `_r` reverses it) or as colours.
function colormap_of(map::Symbol)
    name = String(map)
    endswith(name, "_r") && return Makie.cgrad(Symbol(name[1:(end-2)]); rev = true)
    return Makie.cgrad(map)
end
colormap_of(colors::AbstractVector{<:AbstractString}) = Makie.cgrad(color_of.(colors))

# The colours that a colour map gives to numbers in a range.
function mapped_colors(values::AbstractVector{Float64}, map, range)
    cg = map
    lo, hi = range
    span = hi == lo ? 1.0 : hi - lo
    return [Makie.RGBAf(cg[clamp((v - lo) / span, 0.0, 1.0)]) for v in values]
end

# The colour of a layer: one colour, or one for each point.
function layer_colors(layer::T.Layer, panel::T.PanelSpec, style::T.PlotStyle, n::Integer)
    c = layer.color
    if c === nothing
        return color_of(style.foreground), false
    elseif c isa AbstractString
        return visible_color(c), false
    end
    values = length(c) == n ? c : fill(c[1], n)
    range = panel.colorrange === nothing ? extrema(values) : panel.colorrange
    return mapped_colors(values, colormap_of(panel.colormap), range), true
end

with_alpha(c, a) =
    Makie.RGBAf(Makie.red(c), Makie.green(c), Makie.blue(c), a * Makie.alpha(c))
with_alpha(c::AbstractVector, a) = [with_alpha(x, a) for x in c]

function draw_layer!(ax, layer::T.Layer, panel::T.PanelSpec, style::T.PlotStyle)
    kind = layer.kind
    labelled = isempty(layer.label) ? () : (; label = tex_label(layer.label))
    if kind === :scatter
        c, _ = layer_colors(layer, panel, style, length(layer.x))
        size = layer.size > 0 ? layer.size : style.markersize
        if layer.filled
            Makie.scatter!(
                ax,
                layer.x,
                layer.y;
                color = with_alpha(c, layer.alpha),
                marker = layer.marker,
                markersize = size,
                strokewidth = 0,
                labelled...,
            )
        else
            Makie.scatter!(
                ax,
                layer.x,
                layer.y;
                color = Makie.RGBAf(0, 0, 0, 0),
                strokecolor = with_alpha(c, layer.alpha),
                strokewidth = 1.5,
                marker = layer.marker,
                markersize = size,
                labelled...,
            )
        end
    elseif kind === :lines
        c, _ = layer_colors(layer, panel, style, length(layer.x))
        c isa AbstractVector &&
            (c = length(c) == length(layer.x) ? c : fill(c[1], length(layer.x)))
        Makie.lines!(
            ax,
            layer.x,
            layer.y;
            color = with_alpha(c, layer.alpha),
            linewidth = layer.width > 0 ? layer.width : style.linewidth,
            linestyle = layer.linestyle,
            labelled...,
        )
    elseif kind === :band
        c, _ = layer_colors(layer, panel, style, length(layer.x))
        Makie.band!(
            ax,
            layer.x,
            layer.y .- layer.lower,
            layer.y .+ layer.upper;
            color = with_alpha(c, layer.alpha),
        )
    elseif kind === :errorbars
        c, _ = layer_colors(layer, panel, style, length(layer.x))
        Makie.errorbars!(
            ax,
            layer.x,
            layer.y,
            layer.lower,
            layer.upper;
            color = with_alpha(c, layer.alpha),
            linewidth = layer.width > 0 ? layer.width : 1.0,
            whiskerwidth = 0,
        )
    elseif kind === :polygon
        c, _ = layer_colors(layer, panel, style, length(layer.x))
        Makie.poly!(
            ax,
            Makie.Point2f.(layer.x, layer.y);
            color = with_alpha(c, layer.alpha),
            strokecolor = c,
            strokewidth = layer.width > 0 ? layer.width : 1.0,
        )
    elseif kind === :heatmap
        Makie.heatmap!(
            ax,
            layer.x,
            layer.y,
            layer.z;
            colormap = colormap_of(panel.colormap),
            colorrange = panel.colorrange,
            nan_color = Makie.RGBAf(0, 0, 0, 0),
        )
    elseif kind === :hline
        c, _ = layer_colors(layer, panel, style, 1)
        Makie.hlines!(
            ax,
            layer.y;
            color = with_alpha(c, layer.alpha),
            linestyle = layer.linestyle,
            linewidth = layer.width > 0 ? layer.width : 1.0,
        )
    elseif kind === :vline
        c, _ = layer_colors(layer, panel, style, 1)
        Makie.vlines!(
            ax,
            layer.x;
            color = with_alpha(c, layer.alpha),
            linestyle = layer.linestyle,
            linewidth = layer.width > 0 ? layer.width : 1.0,
        )
    else
        throw(ArgumentError("the layer kind $(repr(kind)) is not drawn"))
    end
    return nothing
end

# A legend entry is plain text unless it is an expression of mathematics (it starts with a
# backslash, like the bands of a parity plot).
tex_label(s::AbstractString) = startswith(s, "\\") ? tex(s) : String(s)

function axis_of(cell, panel::T.PanelSpec, style::T.PlotStyle)
    kwargs = Dict{Symbol,Any}(
        :xlabel => tex(panel.xlabel),
        :ylabel => tex(panel.ylabel),
        :title => panel.title,
        :xscale => panel.xscale === :log10 ? log10 : identity,
        :yscale => panel.yscale === :log10 ? log10 : identity,
    )
    panel.aspect_equal && (kwargs[:aspect] = Makie.DataAspect())
    ax = Makie.Axis(cell; kwargs...)
    if panel.xticks !== nothing
        ax.xticks = (panel.xticks[1], panel.xticks[2])
        ax.xticklabelrotation = pi / 6
    end
    return ax
end

# The theme of a style: the colours of text, axes and grid and the size of the text.
function theme_of(style::T.PlotStyle)
    fg = color_of(style.foreground)
    return Makie.Theme(;
        fontsize = style.fontsize,
        backgroundcolor = color_of(style.background),
        textcolor = fg,
        Axis = (
            backgroundcolor = Makie.RGBAf(0, 0, 0, 0),
            xgridvisible = false,
            ygridvisible = false,
            xticklabelcolor = fg,
            yticklabelcolor = fg,
            xlabelcolor = fg,
            ylabelcolor = fg,
            titlecolor = fg,
            xtickcolor = fg,
            ytickcolor = fg,
            bottomspinecolor = fg,
            leftspinecolor = fg,
            topspinecolor = fg,
            rightspinecolor = fg,
        ),
        Colorbar = (labelcolor = fg, ticklabelcolor = fg, tickcolor = fg, spinecolor = fg),
        Legend = (
            framevisible = false,
            labelcolor = fg,
            labelsize = max(style.fontsize - 2, 8),
            patchsize = (14, 14),
            backgroundcolor = Makie.RGBAf(0, 0, 0, 0),
        ),
    )
end

colorbar_of(cell, bar::T.ColorbarSpec; kwargs...) = Makie.Colorbar(
    cell;
    colormap = colormap_of(bar.colormap),
    limits = bar.limits,
    label = tex(bar.label),
    kwargs...,
)

# One legend for the figure, outside the axes: each label once, with the marker or the line that
# the layer has (a layer that is coloured by a number is drawn in the colour of the text).
function draw_legend!(cell, entries, style::T.PlotStyle)
    elements = Any[]
    labels = Any[]
    seen = Set{String}()
    for (layer, panel) in entries
        layer.label in seen && continue
        push!(seen, layer.label)
        color =
            layer.color isa AbstractString ? visible_color(layer.color) :
            color_of(style.foreground)
        if layer.kind === :scatter
            push!(
                elements,
                Makie.MarkerElement(;
                    marker = layer.marker,
                    color = layer.filled ? color : Makie.RGBAf(0, 0, 0, 0),
                    strokecolor = color,
                    strokewidth = layer.filled ? 0 : 1.5,
                    markersize = 10,
                ),
            )
        else
            push!(
                elements,
                Makie.LineElement(; color, linestyle = layer.linestyle, linewidth = 2),
            )
        end
        push!(labels, tex_label(layer.label))
    end
    Makie.Legend(cell, elements, labels; valign = :top, tellheight = false)
    return nothing
end

"""
Draw the panels of `spec` in the layout of `position` (a position of a `Figure`, or a
`GridLayout`); returns the axes.
"""
function draw_into!(position, spec::T.FigureSpec)
    style = spec.style
    layout = Makie.GridLayout(position)
    axes = Makie.Axis[]
    entries = Tuple{T.Layer,T.PanelSpec}[]
    for (k, panel) in enumerate(spec.panels)
        row, col = fldmod1(k, spec.ncols)
        inner = Makie.GridLayout(layout[row, col])
        ax = axis_of(inner[1, 1], panel, style)
        for layer in panel.layers
            draw_layer!(ax, layer, panel, style)
        end
        if panel.limits !== nothing
            xlo, xhi, ylo, yhi = panel.limits
            Makie.limits!(ax, xlo, xhi, ylo, yhi)
        end
        if !isempty(panel.tag)
            Makie.Label(
                inner[1, 1, Makie.TopLeft()],
                panel.tag;
                font = :bold,
                padding = (0, 0, 4, 0),
                halign = :left,
            )
        end
        if panel.colorbar !== nothing
            colorbar_of(inner[1, 2], panel.colorbar)
        end
        if panel.legend
            for layer in panel.layers
                isempty(layer.label) || push!(entries, (layer, panel))
            end
        end
        push!(axes, ax)
    end
    if spec.sharex && spec.ncols == 1 && length(axes) > 1
        Makie.linkxaxes!(axes...)
        for ax in axes[1:(end-1)]
            Makie.hidexdecorations!(ax; grid = false, ticks = false)
        end
    end
    if length(spec.heights) == spec.nrows
        for (i, h) in enumerate(spec.heights)
            Makie.rowsize!(layout, i, Makie.Auto(h))
        end
    end
    legend_column = spec.ncols + 1
    if !isempty(entries)
        draw_legend!(layout[1:spec.nrows, legend_column], entries, style)
        legend_column += 1
    end
    spec.colorbar === nothing ||
        colorbar_of(layout[1:spec.nrows, legend_column], spec.colorbar)
    return axes
end

function draw_figure(spec::T.FigureSpec)
    fig = Makie.with_theme(theme_of(spec.style)) do
        f = Makie.Figure(; size = spec.size)
        draw_into!(f[1, 1], spec)
        f
    end
    return fig
end
