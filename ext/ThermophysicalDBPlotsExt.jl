module ThermophysicalDBPlotsExt

# Draws the figures of ThermophysicalDB with Plots, through a recipe: `plot(spec)` draws a
# `FigureSpec` and `plot(data; kind = :xpt, ...)` the figure that `kind` names.

using LaTeXStrings: LaTeXString
using Plots: Plots
using RecipesBase: RecipesBase, @recipe, @series
using ThermophysicalDB: ThermophysicalDB

const T = ThermophysicalDB

include("plots/draw.jl")

function __init__()
    T.register_backend!(:plots, draw_figure)
    return nothing
end

end
