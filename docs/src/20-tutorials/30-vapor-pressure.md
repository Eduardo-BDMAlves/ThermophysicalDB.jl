```@meta
CurrentModule = ThermophysicalDB
```

# [Vapor pressure and Clausius–Clapeyron](@id tutorial_vapor)

At equilibrium between a liquid and its vapor, the pressure is fixed by the temperature. The slope of that curve is not arbitrary: the **Clapeyron equation** ties it to the enthalpy of vaporization,

```math
\frac{\mathrm{d}p}{\mathrm{d}T} = \frac{\Delta H_\mathrm{vap}}{T\,\Delta V}
```

where ``\Delta V`` is the volume change on vaporization. Far from the critical point the liquid volume is negligible against the vapor volume, and if the vapor behaves as an ideal gas, ``\Delta V \approx RT/p``. Substituting gives the **Clausius–Clapeyron equation**,

```math
\frac{\mathrm{d}\ln p}{\mathrm{d}(1/T)} = -\frac{\Delta H_\mathrm{vap}}{R}
```

so a plot of ``\ln p`` against ``1/T`` is close to a straight line whose slope is ``-\Delta H_\mathrm{vap}/R``. In this tutorial we test that with the vapor-pressure points of ethanol and extract enthalpies of vaporization from them.

```@setup vap
Main.DocsSetup.activate!()
```

## Select the points

Here the pressure is the *measured property*, and temperature is the condition, so only a `property` filter is needed:

```@example vap
using ThermophysicalDB, CairoMakie, Unitful, Statistics

db = database(progress = false)
v = points(db; component = "ethanol", exact = true, property = "Vapor or sublimation pressure")
```

```@example vap
t = table(v; unitful = true)

T = ustrip.(u"K", t.temperature)
p = ustrip.(u"kPa", t.value)
year = Float64.(t.year)

(points = length(p), articles = length(unique(t.doi)), T_range = extrema(T))
```

The label of this property covers both vaporization and sublimation. If you need to keep one equilibrium only, the `phase` column says which one each point belongs to (`unique(t.phase)` lists the values present).

## The vapor-pressure curve

On a logarithmic axis the curve spans orders of magnitude, from the triple-point region to near the critical temperature:

```@example vap
fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "p [kPa]", yscale = log10, title = "Vapor pressure of ethanol")
sc = scatter!(ax, T, p; color = year, markersize = 7)
hlines!(ax, [101.325]; color = (:gray, 0.8), linestyle = :dash)
text!(ax, minimum(T), 101.325; text = "1 atm", align = (:left, :bottom), color = :gray)
Colorbar(fig[1, 2], sc; label = "year of publication")
fig
```

## Clausius–Clapeyron coordinates

Plotting ``\ln p`` against ``1000/T`` straightens the curve. The line is a least-squares fit over the whole range, and the enthalpy follows from its slope. Because the fit pretends ``\Delta H_\mathrm{vap}`` is constant, the number is an *average* over the range, not a value at a particular temperature:

```@example vap
x = 1000 ./ T          # 1000 K / T, so the slope is per 1000 K⁻¹
y = log.(p)            # p in kPa

slope = cov(x, y) / var(x)
intercept = mean(y) - slope * mean(x)

R = 8.314462618e-3     # kJ mol⁻¹ K⁻¹
mean_enthalpy = -R * 1000 * slope
round(mean_enthalpy; digits = 2)    # kJ/mol, averaged over the whole range
```

```@example vap
fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "1/T [10⁻³ K⁻¹]", ylabel = "ln p  [p in kPa]", title = "Clausius–Clapeyron plot")
sc = scatter!(ax, x, y; color = year, markersize = 7)
xs = range(extrema(x)...; length = 50)
lines!(ax, xs, intercept .+ slope .* xs; color = "#e8ecff", linewidth = 2, label = "linear fit")
Colorbar(fig[1, 2], sc; label = "year of publication")
axislegend(ax; position = :rt)
fig
```

## A check: the normal boiling point

The normal boiling point is the temperature at which the vapor pressure equals 1 atm. A short local fit around that pressure gives it directly from the data, which you can compare with the tabulated value of about 351.4 K:

```@example vap
target = log(101.325)
near = abs.(y .- target) .< 0.15
local_slope = cov(x[near], y[near]) / var(x[near])
local_intercept = mean(y[near]) - local_slope * mean(x[near])

boiling_point = 1000 / ((target - local_intercept) / local_slope)
(points_used = count(near), T_boiling = round(boiling_point; digits = 2))
```

## The enthalpy is not constant

Real enthalpies of vaporization fall as the temperature rises and vanish at the critical point, where liquid and vapor become identical. The Clausius–Clapeyron assumptions also degrade near the critical point, so the estimates below describe the *apparent* enthalpy ``-R\,\mathrm{d}\ln p/\mathrm{d}(1/T)``. Fitting a line in a sliding 30 K window shows the trend:

```@example vap
centers = range(ceil(minimum(T)), floor(maximum(T)); step = 10)
estimate = Tuple{Float64,Float64}[]
for c in centers
    window = abs.(T .- c) .<= 15
    count(window) >= 8 || continue
    spread = var(x[window])
    spread > 0 || continue
    s = cov(x[window], y[window]) / spread
    push!(estimate, (c, -R * 1000 * s))
end

fig = Figure(size = (760, 420))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "apparent ΔH_vap [kJ mol⁻¹]", title = "Apparent enthalpy of vaporization of ethanol")
scatterlines!(ax, first.(estimate), last.(estimate); color = "#ff8a00", linewidth = 2.5, markersize = 10)
hlines!(ax, [mean_enthalpy]; color = (:gray, 0.8), linestyle = :dash)
text!(ax, first(first(estimate)), mean_enthalpy; text = "whole-range average", align = (:left, :bottom), color = :gray)
fig
```

Windows with fewer than eight points are skipped, so the curve may have gaps where the literature is thin. Those gaps are precisely what a coverage analysis of the archive would flag.
