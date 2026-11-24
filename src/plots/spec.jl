# A figure described without a plotting package: the layers of each panel, the labels, the
# colour bar. The builders of this package make a `FigureSpec`; the extension of a backend
# (Makie, Plots) draws it. What a figure shows is then tested without any backend.

"""
    Layer

One thing drawn in a panel. `kind` is one of `:scatter`, `:lines`, `:band` (between `y` and
`upper`), `:errorbars` (from `y - lower` to `y + upper`), `:polygon`, `:heatmap` (`x` and `y` are
the edges and `z` the matrix of values), `:hline`, `:vline` (at the values in `y` or `x`) and
`:text`. `color` is a colour (text), a vector of numbers that the colour map of the panel
turns into colours, or `nothing` (the colour of the style).
"""
Base.@kwdef struct Layer
    kind::Symbol
    x::Vector{Float64} = Float64[]
    y::Vector{Float64} = Float64[]
    lower::Vector{Float64} = Float64[]
    upper::Vector{Float64} = Float64[]
    z::Matrix{Float64} = zeros(0, 0)
    color::Union{Nothing,String,Vector{Float64}} = nothing
    marker::Symbol = :circle
    filled::Bool = true
    label::String = ""
    linestyle::Symbol = :solid
    alpha::Float64 = 1.0
    width::Float64 = 0.0
    size::Float64 = 0.0
    text::Vector{String} = String[]
end

Base.length(l::Layer) = length(l.x) == 0 ? length(l.y) : length(l.x)

"""
    ColorbarSpec(label, colormap, limits)

The colour bar of a panel: the LaTeX of its `label`, the colour map (a name or a vector of
colours) and the `(low, high)` of the values.
"""
struct ColorbarSpec
    label::String
    colormap::Union{Symbol,Vector{String}}
    limits::NTuple{2,Float64}
end

"""
    PanelSpec

An axes: its `layers`, the LaTeX of `xlabel` and `ylabel`, a `title` (empty by default), the
`tag` of the panel (`"(a)"`), the scales (`:linear`, `:log10`), `xticks` as `(positions, labels)`
for a categorical axis, the colour bar and whether it has a legend; `frame = false` hides the axes, ticks and labels (a ternary diagram). `colorrange` is the range
of the values that the numeric colours of its layers use and `limits` the `(xlow, xhigh,
ylow, yhigh)` of the axes when they are not those of the layers.
"""
Base.@kwdef struct PanelSpec
    layers::Vector{Layer} = Layer[]
    xlabel::String = ""
    ylabel::String = ""
    title::String = ""
    tag::String = ""
    xscale::Symbol = :linear
    yscale::Symbol = :linear
    xticks::Union{Nothing,Tuple{Vector{Float64},Vector{String}}} = nothing
    colorbar::Union{Nothing,ColorbarSpec} = nothing
    legend::Bool = true
    aspect_equal::Bool = false
    frame::Bool = true
    colormap::Union{Symbol,Vector{String}} = SEQUENTIAL_COLORMAP
    colorrange::Union{Nothing,NTuple{2,Float64}} = nothing
    limits::Union{Nothing,NTuple{4,Float64}} = nothing
end

"""
    FigureSpec

The description of a figure: `panels` in a grid of `nrows` by `ncols` (row by row), the `style`,
the relative `heights` of the rows, the `size` in pixels, `sharex` (the panels of a column
share the x axis) and `colorbar`, the one colour bar that the panels share (the panels then have
none of their own). Draw it with [`render`](@ref).
"""
Base.@kwdef struct FigureSpec
    panels::Vector{PanelSpec}
    nrows::Int = 1
    ncols::Int = 1
    style::PlotStyle = PlotStyle()
    heights::Vector{Float64} = Float64[]
    size::Tuple{Int,Int} = (640, 480)
    sharex::Bool = false
    colorbar::Union{Nothing,ColorbarSpec} = nothing
end

"""
    resize(figure::FigureSpec, size) -> FigureSpec

The same figure with another `size`, the width and the height in pixels.
"""
function resize(f::FigureSpec, size)
    (size isa Tuple || size isa AbstractVector) && length(size) == 2 && all(>(0), size) ||
        throw(
            ArgumentError(
                "`size` is the width and the height in pixels, such as (800, 500)",
            ),
        )
    return FigureSpec(
        f.panels,
        f.nrows,
        f.ncols,
        f.style,
        f.heights,
        (round(Int, size[1]), round(Int, size[2])),
        f.sharex,
        f.colorbar,
    )
end

function Base.show(io::IO, f::FigureSpec)
    layers = sum(p -> length(p.layers), f.panels; init = 0)
    return print(
        io,
        "FigureSpec(",
        length(f.panels),
        " panel",
        length(f.panels) == 1 ? "" : "s",
        ", ",
        layers,
        " layers)",
    )
end

# ----------------------------------------------------------------------------------
# Backends
# ----------------------------------------------------------------------------------

const BACKENDS = Dict{Symbol,Function}()

"""
    register_backend!(name, draw)

Register the function that draws a [`FigureSpec`](@ref) with a plotting package: the
extensions of Makie (`:makie`) and Plots (`:plots`) call it when they are loaded. `draw` takes
the specification and returns the figure of the package.
"""
function register_backend!(name::Symbol, draw::Function)
    name in PLOT_BACKENDS_KNOWN || throw(ArgumentError("unknown backend $(repr(name))"))
    BACKENDS[name] = draw
    return nothing
end

"""
    render(spec::FigureSpec; backend = nothing)

Draw a figure with a backend: the one given, the one of [`plot_defaults`](@ref) or the only one
that is loaded (`using CairoMakie`, `using Plots`).
"""
function render(spec::FigureSpec; backend::Union{Nothing,Symbol} = nothing)
    name = backend === nothing ? plot_defaults().backend : backend
    if name === nothing
        loaded = collect(keys(BACKENDS))
        isempty(loaded) && throw(
            ArgumentError(
                "no plotting package is loaded: run `using CairoMakie` (or GLMakie, WGLMakie) or `using Plots` first",
            ),
        )
        length(loaded) == 1 || throw(
            ArgumentError(
                "both backends are loaded ($(sort(loaded))): choose with `backend = :makie` or `:plots`, or set `plot_defaults(backend = ...)`",
            ),
        )
        name = only(loaded)
    end
    haskey(BACKENDS, name) || throw(
        ArgumentError(
            "the backend $(repr(name)) is not loaded: run `using $(name === :makie ? "CairoMakie" : "Plots")`",
        ),
    )
    return BACKENDS[name](spec)
end
