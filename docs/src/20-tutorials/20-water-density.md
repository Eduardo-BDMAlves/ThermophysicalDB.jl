```@meta
CurrentModule = ThermophysicalDB
```

# [Water density against the Kell equation](@id tutorial_water)

Liquid water has more experimental density data than almost any other substance in the archive: hundreds of articles, measured with very different instruments over many decades. That makes it the ideal case to show how filtering with everyday units works and how to judge a literature data set against a reference equation.

The reference here is the correlation of Kell (1975) for air-free water at 1 atm, valid from 0 to 150 °C:

```math
\rho(T) = \frac{999.83952 + 16.945176\,T - 7.9870401\times10^{-3}\,T^2 - 46.170461\times10^{-6}\,T^3 + 105.56302\times10^{-9}\,T^4 - 280.54253\times10^{-12}\,T^5}{1 + 16.879850\times10^{-3}\,T}\ \mathrm{kg\,m^{-3}}
```

with ``T`` in °C (here, and in the plots of this page, ``T`` is the Celsius temperature; elsewhere in the documentation it is in kelvin).

```@setup water
Main.DocsSetup.activate!()
```

## Select in °C and atm

Limits can be written with Unitful units. They are converted to the units the data use (K and kPa), so you never convert by hand:

```@example water
using ThermophysicalDB, CairoMakie, Unitful, Statistics

db = database(progress = false)
v = points(
    db;
    component = "water", exact = true,
    property = "Mass density",
    temperature = (0u"°C", 100u"°C"),
    pressure = (0.98u"atm", 1.02u"atm"),
)
```

Two details of that call are worth knowing. The pressure window matters because Kell's equation is a 1 atm equation; a window of ±2 % of an atmosphere changes the density of water by only about one part per million (its isothermal compressibility is of the order of ``4.5\times10^{-10}\ \mathrm{Pa^{-1}}``), so the comparison stays fair. And a point with no stated pressure is excluded whenever a pressure filter is given, since it cannot be shown to satisfy the condition.

## The columns we need

```@example water
t = table(v; unitful = true)

Tc = ustrip.(u"°C", t.temperature)
ρ = ustrip.(u"kg/m^3", t.value)
year = Float64.(t.year)

kell(tc) = evalpoly(tc, (999.83952, 16.945176, -7.9870401e-3, -46.170461e-6, 105.56302e-9, -280.54253e-12)) /
           (1 + 16.879850e-3 * tc)

(points = length(ρ), articles = length(unique(t.doi)))
```

## The anomaly of water

Plotted on this scale, the experimental points fall on the curve and the maximum of density near 4 °C is visible. It exists because two effects compete: the open, hydrogen-bonded structure of cold water collapses as it warms (density rises), while ordinary thermal expansion pushes the other way.

```@example water
fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "T [°C]", ylabel = "ρ [kg m⁻³]", title = "Density of liquid water at 1 atm")
sc = scatter!(ax, Tc, ρ; color = year, markersize = 7)
tt = range(0, 100; length = 400)
lines!(ax, tt, kell.(tt); color = "#e8ecff", linewidth = 2, label = "Kell (1975)")
Colorbar(fig[1, 2], sc; label = "year of publication")
axislegend(ax; position = :rt)
fig
```

## Residuals: how far is each laboratory?

The relative deviation from the equation, in parts per million, shows what the previous plot hides. Points outside the displayed window are counted, not drawn.

```@example water
res = 1e6 .* (ρ .- kell.(Tc)) ./ kell.(Tc)
window = 600
outside = count(>(window), abs.(res))

fig = Figure(size = (760, 460))
ax = Axis(
    fig[1, 1]; xlabel = "T [°C]", ylabel = "(ρ − ρ_Kell)/ρ_Kell [ppm]",
    title = "Deviation from Kell ($(outside) points outside ±$(window) ppm)",
    limits = (nothing, (-window, window)),
)
hlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
sc = scatter!(ax, Tc, res; color = year, markersize = 7)
Colorbar(fig[1, 2], sc; label = "year of publication")
fig
```

## Has the data improved with time?

Grouping the residuals by five-year periods summarises the scatter of each era. Boxes show the quartiles and the line the median; outliers are hidden.

```@example water
period = 5 .* (t.year .÷ 5)
periods = sort(unique(period))
slot = [findfirst(==(q), periods) for q in period]

fig = Figure(size = (760, 420))
ax = Axis(
    fig[1, 1]; xlabel = "five-year period", ylabel = "(ρ − ρ_Kell)/ρ_Kell [ppm]",
    xticks = (1:length(periods), string.(periods)), xticklabelrotation = π / 4,
    title = "Scatter of water-density data by period",
)
boxplot!(ax, slot, res; color = ("#ff2bd6", 0.7), show_outliers = false)
fig
```

## Who measured it?

The `doi` column ties every point to its article, so listing the most productive sources takes a few lines:

```@example water
counts = Dict{String,Int}()
for d in t.doi
    counts[d] = get(counts, d, 0) + 1
end
first(sort(collect(counts); by = last, rev = true), 8)
```

To work with a single article, pass its DOI back to [`points`](@ref): `points(v; doi = "10.…")`.
