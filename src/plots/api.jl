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

"""
    plot_pxy(data; at = nothing, model = nothing, ...)

Pressure against composition of a mixture at constant temperature (P-x-y): one panel for each
isotherm (temperatures within `tol`, 0.5 in the unit of the temperature; `at = 298.15` or a list
chooses some). The liquid composition (bubble line) is drawn with filled markers and the vapour
one (dew line) with open markers, the shape telling the reference. The mole fraction is the one
of the first component. `data` is a selection of one mixture (the properties of the equilibrium
are chosen for you) or a [`PlotData`](@ref) with them; the rows of the archive that make a point
are put together by `equilibrium` ([`EquilibriumPoints`](@ref)).

A `model` is `model(T, x)` in SI (`T` in K, `x` the liquid mole fraction of the first
component) that returns `(p, y)`, the bubble pressure in Pa and the vapour composition, as the
bubble-point functions of Clapeyron.jl give; it draws the bubble line (continuous) and the dew
line (dashed).

$PLOT_COMMON
"""
plot_pxy(data; kwargs...) =
    draw((d; kw...) -> figure_vle(d, :temperature; kw...), data; kwargs...)

"""
    plot_txy(data; at = nothing, model = nothing, ...)

Temperature against composition at constant pressure (T-x-y), one panel for each isobar
(pressures within a relative `tol`, 1 % by default); like [`plot_pxy`](@ref). `model(p, x)`
returns `(T, y)` with `p` in Pa and `T` in K.

$PLOT_COMMON
"""
plot_txy(data; kwargs...) =
    draw((d; kw...) -> figure_vle(d, :pressure; kw...), data; kwargs...)

"""
    plot_xy(data; color = :auto, ...)

The composition of the vapour against the one of the liquid, with the diagonal; the points are
coloured by the temperature or the pressure (`color`, whichever varies when `:auto`).

$PLOT_COMMON
"""
plot_xy(data; kwargs...) = draw(figure_xy, data; kwargs...)

"""
    plot_saturation(data; density = "Mass density", ...)

The saturation line of a pure fluid: the density of the liquid (filled) and of the gas (open)
against the temperature, for the points that state no pressure (they are at saturation;
`saturated_only = false` takes all), with the critical point of each reference as a star, and
beside it the vapour pressure against `1000 / T` with the critical pressures as stars.

$PLOT_COMMON
"""
plot_saturation(data; kwargs...) = draw(figure_saturation, data; kwargs...)

"""
    plot_deviation_map(data; model, x = :temperature, y = :pressure, deviation = :relative, ...)

The deviation of a model from the data in the plane of two conditions: each point is coloured by
its deviation, with a colour map centred on zero (`vik`) whose range is the largest deviation
(`limit` sets it). It shows where in temperature and pressure a model is good. The
options of the deviation are those of [`plot_comparison`](@ref); with `absolute_value = true`
the map starts at zero.

$PLOT_COMMON
"""
plot_deviation_map(data; kwargs...) = draw(figure_deviation_map, data; kwargs...)

"""
    plot_excess(data; fraction_of = nothing, xkind = "Mole fraction", color = nothing, ...)

The excess properties of a mixture against its composition: one panel for each property (select
them with `property = [...]`, as in `property = ["Excess molar volume", "Excess molar enthalpy"]`),
the x axis being the fraction of one component (`fraction_of`, the first component of the most
frequent system by default; the articles list the components in their own order, so it is taken
from `x1`, `x2` or `x3` as each system has it) and only the points whose composition is of the kind
`xkind` (`nothing` keeps all),
with the points of every reference, each with its marker. `color = :temperature` colours them
by temperature; it is [`plot_facets`](@ref) with the mole fraction on the x axis.

$PLOT_COMMON
"""
plot_excess(data; kwargs...) = draw(figure_excess, data; kwargs...)

"""
    plot_ternary(data; color = :value, components = nothing, grid = 5, ...)

A system of three components in a triangle (the first component at the lower left, the second at
the lower right and the third at the top), the points coloured by `color`. The compositions are
the mole fractions `x1`, `x2` and `x3` (the one that is not given is what is left to 1). With
several systems in the selection the most frequent is drawn, or the one that `components`
names, as the points give it (`"A + B + C"`).

$PLOT_COMMON
"""
plot_ternary(data; kwargs...) = draw(figure_ternary, data; kwargs...)

"""
    plot_years(data; cumulative = true, ...)

The number of points of each year of publication, and beside it the cumulative number: the growth
of the literature on what was selected. Points of an unknown year are left out.

$PLOT_COMMON
"""
plot_years(data; kwargs...) = draw(figure_years, data; kwargs...)

# The same figures in a position of a layout of your own (Makie): `plot_comparison!(fig[1, 2], data;
# ...)`. The methods are in the extension of Makie.
for name in (
    :plot_comparison!,
    :plot_isotherms!,
    :plot_isobars!,
    :plot_parity!,
    :plot_residuals!,
    :plot_xpt!,
    :plot_facets!,
    :plot_by_reference!,
    :plot_pxy!,
    :plot_txy!,
    :plot_xy!,
    :plot_saturation!,
    :plot_deviation_map!,
    :plot_excess!,
    :plot_ternary!,
    :plot_years!,
)
    @eval begin
        """
            $($(string(name)))(position, data; kwargs...) -> Vector{Axis}

        The figure of [`$($(string(name)[1:(end-1)]))`](@ref) drawn in a position of a Makie layout
        (`fig[1, 2]`, a `GridLayout`), so that several figures share one `Figure`; it takes the
        same keywords and returns the axes. It needs Makie (`using CairoMakie`).
        """
        function $name end
    end
end
