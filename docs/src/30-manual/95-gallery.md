```@meta
CurrentModule = ThermophysicalDB
```

# [Gallery of figures](@id figure_gallery)

Every figure of the package, drawn with [CairoMakie](https://docs.makie.org) and with [Plots](https://docs.juliaplots.org) (GR) from the same selection and the same options, so the two can be compared. The style is `:neon` (the colours of this site, for a dark panel); `style = :default` uses the scientific colour maps of the package (`managua_r` for continuous values, `vik` for deviations, `batlowS` for categories) and is the one to publish with on a white page. How each figure is read, the units of the axes and the options are in the [figures manual](@ref manual_figures).

```@setup gallery
Main.DocsSetup.activate!()
using ThermophysicalDB, CairoMakie, Unitful
import Plots
plot_defaults(style = :neon)

db = database(progress = false)

# The formula of Kell for the density of water at 1 atm (t in °C): a model of the conditions in SI.
function kell(p, T)
    t = T - 273.15
    num = 999.83952 + 16.945176t - 7.9870401e-3t^2 - 46.170461e-6t^3 +
          105.56302e-9t^4 - 280.54253e-12t^5
    return num / (1 + 16.879850e-3t)
end

d = plotdata(
    db;
    component = "water", pure = true, exact = true,
    property = "Mass density",
    temperature = (0u"°C", 99u"°C"), pressure = (0.98u"atm", 1.02u"atm"),
    temperature_unit = "degC",
)
liquid = plotdata(
    db;
    component = "water", pure = true, exact = true,
    property = "Mass density", phase = "Liquid",
    temperature_unit = "degC", pressure_unit = "MPa",
)
isotherms = plotdata(
    db;
    component = "water", pure = true, exact = true,
    property = "Mass density",
    temperature = (10u"°C", 60u"°C"), pressure = (0.1u"MPa", 100u"MPa"),
    temperature_unit = "degC", pressure_unit = "MPa",
)
many = plotdata(
    db;
    component = "water", pure = true, exact = true,
    property = ["Mass density", "Speed of sound", "Viscosity"],
    pressure = (0.98u"atm", 1.02u"atm"),
)
vle = plotdata(db; component = ["ethanol", "water"], exact = true, pressure_unit = "kPa", temperature_unit = "K")
sat = plotdata(db; component = "water", pure = true, exact = true, temperature_unit = "K")
excess = plotdata(
    db;
    component = ["ethanol", "water"], exact = true,
    property = r"[Ee]xcess (molar )?volume", temperature_unit = "K", pressure_unit = "kPa",
)
```

## Values and deviations

`plot_comparison`: the values of a property with a model, and below the deviations.

With CairoMakie:

```@example gallery
plot_comparison(d; model = kell, marker_by = :year_group, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_comparison(d; model = kell, marker_by = :year_group, backend = :plots)
```

## Parity

`plot_parity`: calculated against experimental, with bands of deviation.

With CairoMakie:

```@example gallery
plot_parity(d; model = kell, bands = [0.1, 0.5, 1], backend = :makie)
```

With Plots (GR):

```@example gallery
plot_parity(d; model = kell, bands = [0.1, 0.5, 1], backend = :plots)
```

## Distribution of the deviations

`plot_residuals`: a violin for each group, with its points and quartiles.

With CairoMakie:

```@example gallery
plot_residuals(d; model = kell, by = :year_group, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_residuals(d; model = kell, by = :year_group, backend = :plots)
```

## Deviation in the plane of the conditions

`plot_deviation_map`: each point coloured by the deviation of the model, with a colour map centred on zero.

With CairoMakie:

```@example gallery
plot_deviation_map(d; model = kell, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_deviation_map(d; model = kell, backend = :plots)
```

## Where the data are

`plot_xpt`: the plane of temperature and pressure, coloured by the value or by the number of points.

With CairoMakie:

```@example gallery
plot_xpt(liquid; marker_by = nothing, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_xpt(liquid; marker_by = nothing, backend = :plots)
```

## Isotherms

`plot_isotherms` (and `plot_isobars`): one line for each temperature, coloured by it.

With CairoMakie:

```@example gallery
plot_isotherms(isotherms; marker_by = nothing, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_isotherms(isotherms; marker_by = nothing, backend = :plots)
```

## Several properties

`plot_facets` and `plot_by_reference`: a panel for each property or reference.

With CairoMakie:

```@example gallery
plot_facets(many; marker_by = nothing, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_facets(many; marker_by = nothing, backend = :plots)
```

## Vapour–liquid equilibrium

`plot_pxy` (and `plot_txy`): a panel for each isotherm, filled for the bubble curve and open for the dew curve; `plot_xy` draws the vapour against the liquid composition.

With CairoMakie:

```@example gallery
plot_pxy(vle; maxpanels = 3, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_pxy(vle; maxpanels = 3, backend = :plots)
```

With CairoMakie:

```@example gallery
plot_xy(vle, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_xy(vle, backend = :plots)
```

## Saturation

`plot_saturation`: the densities of the two phases with the critical points, and the vapour pressure against `1000 / T`.

With CairoMakie:

```@example gallery
plot_saturation(sat, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_saturation(sat, backend = :plots)
```

## Excess properties

`plot_excess`: the excess properties against the composition, with every reference.

With CairoMakie:

```@example gallery
plot_excess(excess; color = :temperature, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_excess(excess; color = :temperature, backend = :plots)
```

## Literature by year

`plot_years`: the points of each year and the cumulative number.

With CairoMakie:

```@example gallery
plot_years(excess, backend = :makie)
```

With Plots (GR):

```@example gallery
plot_years(excess, backend = :plots)
```
