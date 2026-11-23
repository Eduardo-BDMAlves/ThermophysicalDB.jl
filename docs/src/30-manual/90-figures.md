```@meta
CurrentModule = ThermophysicalDB
```

# [Figures](@id manual_figures)

The package draws the figures that are made over and over when experiments are compared with each other and with models: values and deviations, isotherms, parity plots, distributions of the deviations, the plane of temperature and pressure that the data cover. The figures are built without any plotting package (a [`FigureSpec`](@ref) that says what is on each panel) and drawn by an extension, so you choose the package: [Makie](https://docs.makie.org) (`using CairoMakie`, `GLMakie` or `WGLMakie`) or [Plots](https://docs.juliaplots.org) (`using Plots`). With both loaded, say which one with `backend = :makie` or `backend = :plots`, or once with `plot_defaults(backend = :makie)`.

```@setup figures
Main.DocsSetup.activate!()
using ThermophysicalDB, CairoMakie, Unitful, Statistics
import Plots
plot_defaults(backend = :makie, style = :neon)
```

| Function | What it shows |
|:--|:--|
| [`plot_comparison`](@ref) | values and, below, the deviations of a model |
| [`plot_isotherms`](@ref), [`plot_isobars`](@ref) | a line for each temperature or pressure, coloured by it |
| [`plot_parity`](@ref) | calculated against experimental, with bands of deviation |
| [`plot_residuals`](@ref) | distribution of the deviations of each reference |
| [`plot_xpt`](@ref) | where the data are in temperature and pressure |
| [`plot_facets`](@ref), [`plot_by_reference`](@ref) | one panel for each property, or for each reference |
| [`plot_pxy`](@ref), [`plot_txy`](@ref), [`plot_xy`](@ref), [`plot_saturation`](@ref) | vapour–liquid equilibrium and saturation |
| [`plot_deviation_map`](@ref), [`plot_excess`](@ref), [`plot_ternary`](@ref), [`plot_years`](@ref) | deviation in the plane of two conditions, excess properties, three components, points by year |

Every figure of this page is also in the [gallery](@ref figure_gallery), drawn with both packages.

## Data and a model

[`plotdata`](@ref) prepares the points once, with the units that the axes will show, and every figure takes it. The model here is the formula of Kell for the density of water at 1 atm (``t`` in °C), so that nothing else has to be installed; a model is a function of the conditions in SI, `model(p, T)` (`p` in Pa, `T` in K), that returns the value in the unit of the data. Clapeyron.jl models are used the same way.

```@example figures
db = database(progress = false)

d = plotdata(
    db;
    component = "water",
    pure = true,
    exact = true,
    property = "Mass density",
    temperature = (0u"°C", 99u"°C"),
    pressure = (0.98u"atm", 1.02u"atm"),
    temperature_unit = "degC",
)

function kell(p, T)
    t = T - 273.15
    num = 999.83952 + 16.945176t - 7.9870401e-3t^2 - 46.170461e-6t^3 +
          105.56302e-9t^4 - 280.54253e-12t^5
    return num / (1 + 16.879850e-3t)
end
d
```

## Units of the axes and of the colour bars

The units are chosen where the data are prepared, and the axes, the colour bars and the labels follow. Give them to [`plotdata`](@ref) (`temperature_unit`, `pressure_unit`, `unit` for the value) or, when a figure takes a selection, as `xunit`, `yunit` and `cunit` (the colour) of the figure. They are text (`"degC"`, `"MPa"`, `"mPa s"`) or a unit of [Unitful.jl](https://github.com/JuliaPhysics/Unitful.jl) or [FlexUnits.jl](https://github.com/Deduction42/FlexUnits.jl), and the conversion is exact in either case. The quantities of [DynamicQuantities.jl](https://github.com/SymbolicML/DynamicQuantities.jl) keep no text of their units (everything is stored in SI), so for that package give the unit as text. A model always receives SI, whatever the units of the figure.

```@example figures
plot_xpt(
    db;
    component = "water",
    pure = true,
    exact = true,
    property = "Mass density",
    phase = "Liquid",
    xunit = u"°C",         # the same as "degC"
    yunit = "MPa",
    cunit = u"g/cm^3",     # the colour bar, converted as well
    style = :default,
    marker_by = nothing,
)
```

## Values and deviations

The markers tell the references apart (filled shapes first, then open ones), the line is the model, and the lower panel is the relative deviation in percent with the uncertainty of each point as a thin bar. The axis labels are LaTeX with the symbol of the property and the unit in square brackets; `unitformat = :round`, `:slash` or a function changes that.

```@example figures
plot_comparison(d; model = kell, marker_by = :year_group)
```

Other deviations are one keyword away: `deviation = :log`, `:smape`, `:smae`, `:srl` or `:absolute`, `deviation_unit = :ppm`, and `absolute_value = true` for the absolute value of any of them. See [`DeviationSpec`](@ref).

## Parity and the distribution of the deviations

```@example figures
plot_parity(d; model = kell, bands = [0.1, 0.5, 1])
```

A violin shows the shape of the distribution of each reference, with its points and its quartiles inside. A reference with fewer than 10 points has no violin (a density of so few points says nothing) and gets a box with its points; `kind = :box` and `kind = :both` draw boxes.

```@example figures
plot_residuals(d; model = kell, by = :year_group)
```

## Where the data are

The plane of temperature and pressure of all the liquid density of water, coloured by the value. The colour map is the one of the package for continuous values, `managua_r` (cold to hot), in its *default* style; the figures above use the style `:neon` of this documentation. `colormap = :name` takes any map of ColorSchemes.jl.

```@example figures
liquid = plotdata(
    db;
    component = "water",
    pure = true,
    exact = true,
    property = "Mass density",
    phase = "Liquid",
    temperature_unit = "degC",
    pressure_unit = "MPa",
)
plot_xpt(liquid; style = :default, marker_by = nothing)
```

Counting the points in each cell shows where the literature is dense and where it is not:

```@example figures
plot_xpt(liquid; color = :count, style = :default)
```

## Isotherms, facets

Isotherms are grouped by temperature (within `tol`) and coloured by it:

```@example figures
isotherms = plotdata(
    db;
    component = "water",
    pure = true,
    exact = true,
    property = "Mass density",
    temperature = (10u"°C", 60u"°C"),
    pressure = (0.1u"MPa", 100u"MPa"),
    pressure_unit = "MPa",
    temperature_unit = "degC",
)
plot_isotherms(isotherms; marker_by = nothing, style = :default)
```

Several properties make a grid of panels, each in its own unit, tagged (a), (b), ... and with no titles; `plot_by_reference` makes one panel for each reference of one property.

```@example figures
plot_facets(
    db;
    component = "water",
    pure = true,
    exact = true,
    property = ["Mass density", "Speed of sound", "Viscosity"],
    pressure = (0.98u"atm", 1.02u"atm"),
    marker_by = nothing,
)
```

## Mixtures and saturation

The vapour–liquid equilibrium of a binary is drawn from the rows of the archive that give the bubble pressure (or the boiling temperature) and the compositions; `equilibrium` joins them by reference, temperature (or pressure) and liquid composition, so a point has its vapour composition when the reference reports it. `plot_pxy` makes a panel for each isotherm (filled markers for the bubble curve `x`, open ones for the dew curve `y`), `plot_txy` one for each isobar, and `plot_xy` draws the vapour against the liquid composition, coloured by temperature.

```@example figures
vle = plotdata(
    db;
    component = ["ethanol", "water"],
    exact = true,
    pressure_unit = "kPa",
    temperature_unit = "K",
)
plot_pxy(vle; maxpanels = 3, style = :default)
```

```@example figures
plot_xy(vle; style = :default)
```

`plot_saturation` shows the density of the liquid (filled) and of the gas (open) against the temperature, with a star for the critical point of each reference, and the vapour pressure as `ln p` against `1000 / T`, where the Clausius–Clapeyron relation makes a nearly straight line:

```@example figures
sat = plotdata(db; component = "water", pure = true, exact = true, temperature_unit = "K")
plot_saturation(sat; style = :default)
```

## Composition and the literature

`plot_excess` draws one panel for each property against the mole fraction of the first component, with every reference in its own marker (it is made for the excess properties of mixtures, and any property of a binary can be drawn this way; the first component is the one that each article lists first, so look at the `components` column when articles order them differently); `plot_years` counts the points of each year of publication and their cumulative number. `plot_deviation_map` colours the points in the plane of two conditions by the deviation of a model, and `plot_ternary` draws a system of three components in a triangle.

```@example figures
binary = plotdata(
    db;
    component = ["ethanol", "water"],
    match = :all,
    exact = true,
    property = ["Viscosity", "Mass density"],
    temperature = (15u"°C", 45u"°C"),
    temperature_unit = "K",
)
plot_excess(binary; color = :temperature, style = :default)
```

```@example figures
plot_years(binary; style = :default)
```

A system of three components is drawn in a triangle. The data below are synthetic (a density that changes smoothly with the composition), because ternary systems are few in the archive:

```@example figures
# Synthetic compositions of three components (the archive's ternary systems are few and
# sparse), to show the diagram: a density that changes smoothly with the composition.
n = 90
a = [(i * 0.6180339887) % 1 for i in 1:n]
b = [(1 - a[i]) * ((i * 0.7548776662) % 1) for i in 1:n]
ternary = plotdata(
    ThermophysicalDB.PointTable(
        (;
            source = fill("synthetic", n), doi = repeat(["10.0/a", "10.0/b", "10.0/c"], n ÷ 3),
            year = fill(Int16(2020), n), components = fill("water + ethanol + glycerol", n),
            xkind = fill("Mole fraction", n), property = fill("Mass density", n),
            method = fill("", n), phase = fill("Liquid", n), temperature = fill(298.15, n),
            pressure = fill(101.325, n), x1 = a, x2 = b, x3 = 1 .- a .- b,
            value = 800 .+ 300 .* a .+ 80 .* (1 .- a .- b), unit = fill("kg/m3", n),
            unc_k2 = fill(NaN, n),
        ),
        "K", "kPa",
    ),
)
plot_ternary(ternary; style = :default)
```

## Your own layout and the other package

In Makie the figures also fill a position of a layout of yours, with the same keywords: `plot_comparison!(fig[1, 1], d; model = kell)`.

```@example figures
fig = Figure(size = (900, 420))
plot_parity!(fig[1, 1], d; model = kell, bands = [0.5, 1])
plot_residuals!(fig[1, 2], d; model = kell)
fig
```

The same figure with Plots (the GR backend), by name or as a recipe: `plot(d; kind = :parity, options = (model = kell,))` draws a figure of `kind` with [`plot_*`](@ref plot_parity) keywords in `options`.

```@example figures
Plots.gr()
plot_comparison(d; model = kell, backend = :plots)
```

## Styles, labels and defaults

A [`PlotStyle`](@ref) (`plot_style(:default)`, `plot_style(:neon)`) sets colours, markers and sizes; `plot_defaults(...; persist = true)` sets the defaults for this session and keeps them for the next ones. The symbol of a property that has none (or that you want written another way) is set with [`register_symbol!`](@ref).
