# The figures that the user asks for: each builds its `FigureSpec` and draws it with the backend
# that is loaded (the extension of Makie or of Plots). `backend = :makie | :plots` chooses one
# when both are loaded, and `spec = true` returns the description of the figure instead.

const PLOT_COMMON = """
`data` is a selection (a view of a database or of a dataset, filtered with the keywords of
[`points`](@ref): `component`, `property`, `temperature`, `doi`, ...), a [`PlotData`](@ref) from
[`plotdata`](@ref) or a [`PointTable`](@ref). `xunit`, `yunit` and `cunit` are the units of
the axes and of the colour (text such as `"MPa"`, or a unit of a units package), applied
exactly by [`table`](@ref). `style` is a [`PlotStyle`](@ref) or `:default` / `:neon`,
`colormap` the name of a colour scheme, `unitformat` one of `:square`, `:round`, `:slash` or a
function (see [`axis_label`](@ref)), `marker_by` what the markers tell apart (`:reference`,
`:method`, `:phase`, `:year_group`, `nothing`), `uncertainty` (`:auto`, `:bars`, `:band`,
`:none`), `backend` the plotting package and `spec = true` the [`FigureSpec`](@ref) without
drawing it. The defaults are those of [`plot_defaults`](@ref).
"""

function draw(builder, args...; backend = nothing, spec::Bool = false, kwargs...)
    figure = builder(args...; kwargs...)
    return spec ? figure : render(figure; backend)
end

"""
    plot_comparison(data; model, x = :temperature, deviation = :relative, ...)

The values of one property with a model, and below the deviations of the model from the data.
`model` is a function of the conditions in SI (`model(p, T)` with `p` in Pa and `T` in K by
default; `args = (:temperature,)` gives `model(T)`, `args = (:temperature, :x1)` gives
`model(T, x)`) that returns the value in the unit of the data, or the calculated values can be
given to [`plotdata`](@ref) as `calc`. `deviation` is one of $(DEVIATION_KINDS) (see
[`DeviationSpec`](@ref); `deviation_unit`, `absolute_value`, `alpha` and `epsilon` are its
options). The points of the deviation panel show their uncertainty as `uncertainty` says.

$PLOT_COMMON
"""
plot_comparison(data; kwargs...) = draw(figure_comparison, data; kwargs...)

"""
    plot_isotherms(data; x = :pressure, model = nothing, tol = nothing, ...)

The property against `x` with one line for each temperature (within `tol`, 0.5 in the unit of the
temperature), coloured by the temperature, with a colour bar. A model, when given, is drawn for
each isotherm.

$PLOT_COMMON
"""
plot_isotherms(data; kwargs...) =
    draw((d; kw...) -> figure_lines(d, :temperature; kw...), data; kwargs...)

"""
    plot_isobars(data; x = :temperature, model = nothing, tol = nothing, ...)

The property against `x` with one line for each pressure (within a relative `tol`, 1 % by
default), coloured by the pressure, with a colour bar.

$PLOT_COMMON
"""
plot_isobars(data; kwargs...) =
    draw((d; kw...) -> figure_lines(d, :pressure; kw...), data; kwargs...)

"""
    plot_parity(data; model, bands = [1, 5, 10], ...)

The calculated value against the experimental one, with the line of equality and the bands of
relative deviation `bands` (in percent, any list).

$PLOT_COMMON
"""
plot_parity(data; kwargs...) = draw(figure_parity, data; kwargs...)

"""
    plot_residuals(data; model, by = :reference, kind = :violin, ...)

The distribution of the deviations of each group of points: `kind = :violin` (with the points
and the quartiles inside), `:box` or `:both`. A group with few points (fewer than $MIN_POINTS_VIOLIN)
gets a box with its points in place of a violin.

$PLOT_COMMON
"""
plot_residuals(data; kwargs...) = draw(figure_residuals, data; kwargs...)

"""
    plot_xpt(data; color = :value, highlight = nothing, ...)

The plane of temperature and pressure of the points, coloured by the value of the property;
`color = :count` counts the points in each cell, and `highlight` (a DOI or a list of them, a
`Regex` or a function) draws the points of those references as stars ("This work").

$PLOT_COMMON
"""
plot_xpt(data; kwargs...) = draw(figure_xpt, data; kwargs...)

"""
    plot_facets(data; by = :property, x = :temperature, color = nothing, ...)

A panel for each property (or, with `by = :reference`, `:method` or `:phase`, for each group of
one property), tagged (a), (b), ... ; with `color` one colour bar serves all of them.

$PLOT_COMMON
"""
plot_facets(data; kwargs...) = draw(figure_facets, data; kwargs...)

"""
    plot_by_reference(data; x = :temperature, color = nothing, ...)

One panel for each reference of one property; [`plot_facets`](@ref) with `by = :reference`.

$PLOT_COMMON
"""
plot_by_reference(data; kwargs...) = draw(figure_facets, data; by = :reference, kwargs...)
