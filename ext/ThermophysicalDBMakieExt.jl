module ThermophysicalDBMakieExt

# Draws the figures of ThermophysicalDB with Makie (CairoMakie, GLMakie, WGLMakie): the
# description of a figure (`FigureSpec`) becomes a `Figure`, or fills a position of a layout of
# the user's figure.

using LaTeXStrings: LaTeXString
using Makie: Makie
using ThermophysicalDB: ThermophysicalDB

const T = ThermophysicalDB

include("makie/draw.jl")

# The figures in a position of a layout: `plot_comparison!(fig[1, 2], data; ...)`.
const POSITION = Union{Makie.GridPosition,Makie.GridSubposition,Makie.GridLayout}

T.plot_comparison!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_comparison(data; kwargs...))
T.plot_isotherms!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_lines(data, :temperature; kwargs...))
T.plot_isobars!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_lines(data, :pressure; kwargs...))
T.plot_parity!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_parity(data; kwargs...))
T.plot_residuals!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_residuals(data; kwargs...))
T.plot_xpt!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_xpt(data; kwargs...))
T.plot_facets!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_facets(data; kwargs...))
T.plot_by_reference!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_facets(data; by = :reference, kwargs...))

T.plot_pxy!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_vle(data, :temperature; kwargs...))
T.plot_txy!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_vle(data, :pressure; kwargs...))
T.plot_xy!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_xy(data; kwargs...))
T.plot_deviation_map!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_deviation_map(data; kwargs...))
T.plot_excess!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_excess(data; kwargs...))
T.plot_ternary!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_ternary(data; kwargs...))
T.plot_years!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_years(data; kwargs...))
T.plot_saturation!(position::POSITION, data; kwargs...) =
    draw_into!(position, T.figure_saturation(data; kwargs...))

function __init__()
    T.register_backend!(:makie, draw_figure)
    return nothing
end

end
