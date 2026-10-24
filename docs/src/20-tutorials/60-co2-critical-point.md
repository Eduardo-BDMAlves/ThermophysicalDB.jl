```@meta
CurrentModule = ThermophysicalDB
```

# [Carbon dioxide near the critical point](@id tutorial_co2)

Carbon dioxide is the fluid where an equation of state is tested hardest. Its critical point is within reach of a laboratory (``T_\mathrm{c} \approx 304.1`` K, ``p_\mathrm{c} \approx 7.38`` MPa, ``\rho_\mathrm{c} \approx 468`` kg m⁻³), it matters for carbon capture and storage, and the region around it is where simple models fail in a way that is easy to see.

Physics first. Along the vapor–liquid coexistence curve the two phases become more alike as ``T`` rises, until at ``T_\mathrm{c}`` they are the same phase. Two consequences matter here:

- **The coexistence curve is flat at the top.** Near ``T_\mathrm{c}`` the density difference follows ``\rho_\mathrm{l} - \rho_\mathrm{v} \propto (T_\mathrm{c} - T)^{\beta}``. Real fluids have ``\beta \approx 0.33``; any analytical equation of state, cubic or molecular, is a mean-field theory and gives ``\beta = 1/2``. The model curve is therefore too narrow near the top and too wide away from it.
- **Response functions diverge.** The isothermal compressibility ``\kappa_T = -\frac{1}{V}\left(\frac{\partial V}{\partial p}\right)_T`` grows without bound at the critical point, because at constant temperature a tiny pressure change moves the fluid between liquid-like and vapor-like densities. A density measured at a given ``(T, p)`` near the critical point is thus extremely sensitive to errors in either variable, in the experiment and in the model.

The models below are the four of the [previous tutorial](@ref tutorial_eos) plus a multiparameter reference equation (`GERG2008`), which for carbon dioxide is accurate to a small fraction of a percent in density away from the critical point and is used here as the yardstick.

```@setup co2
Main.DocsSetup.activate!()
```

## Data and models

```@example co2
using ThermophysicalDB, CairoMakie, Unitful, Statistics
using Clapeyron

db = database(progress = false)

fluid = ["carbon dioxide"]
models = (
    PR = PR(fluid),
    SRK = SRK(fluid),
    PCSAFT = PCSAFT(fluid),
    SAFTVRMie = SAFTVRMie(fluid),
    GERG2008 = GERG2008(fluid),
)

M = 0.0440095    # kg/mol, molar mass of carbon dioxide

# One fixed colour per model, used in every figure of this page. The reference
# equation is drawn in white, the experimental points in grey-blue.
palette = (PR = "#00e5ff", SRK = "#ff2bd6", PCSAFT = "#b8ff00", SAFTVRMie = "#ff8a00", GERG2008 = "#e8ecff")
keys(models)
```

A model that does not converge at a state point returns `NaN` through this helper, so a single failure never aborts a comparison. `summarize` reports the mean absolute relative deviation (AARD) and the signed mean (bias), in percent.

```@example co2
function predict(f, model, args...)
    out = Vector{Float64}(undef, length(first(args)))
    for i in eachindex(out)
        out[i] = try
            Float64(f(model, (a[i] for a in args)...))
        catch
            NaN
        end
    end
    return out
end

function summarize(dev)
    ok = filter(isfinite, dev)
    isempty(ok) && return (; n = 0, AARD = NaN, bias = NaN)
    return (; n = length(ok), AARD = round(100 * mean(abs, ok); digits = 2), bias = round(100 * mean(ok); digits = 2))
end
```

## The critical point predicted by each model

Every model has its own critical point, found from the condition that the first and second derivatives of pressure with respect to volume vanish. The pure-fluid parameters of cubic equations are *built* from the real critical point, whereas SAFT parameters are fitted to saturation data far from it, so the SAFT critical temperatures drift upward. This is the known overestimate of the critical temperature of mean-field SAFT models:

```@example co2
crit = map(crit_pure, models)    # (Tc, pc, Vc) of each model, SI units

[
    (model = name, Tc = round(c[1]; digits = 2), pc = round(c[2] / 1e6; digits = 3), ρc = round(M / c[3]; digits = 1))
    for (name, c) in pairs(crit)
]
```

Temperatures are in K, pressures in MPa and densities in kg m⁻³. Because `GERG2008` reproduces the real critical point, its values are taken as the reference one:

```@example co2
Tref, pref, _ = crit.GERG2008
(Tref = Tref, pref = pref / 1e6)
```

## Critical constants in the archive

The archive also stores critical constants that authors reported for carbon dioxide, as properties of their own (critical temperature, pressure and density). They are measured or evaluated values from different articles, so they differ from one another, and each one is tied to its article by the DOI. Collecting them by DOI lets us pair the values of the same article:

```@example co2
function critical_values(property, unit)
    v = try
        points(db; component = "carbon dioxide", exact = true, property)
    catch
        return Dict{String,Float64}()
    end
    t = table(v; unitful = true)
    return Dict(zip(t.doi, ustrip.(unit, t.value)))
end

Tc_db = critical_values("Critical temperature", u"K")
pc_db = critical_values("Critical pressure", u"MPa")
ρc_db = critical_values("Critical density", u"kg/m^3")

(Tc = sort(collect(values(Tc_db))), pc = sort(collect(values(pc_db))), ρc = sort(collect(values(ρc_db))))
```

Temperatures are in K, pressures in MPa and densities in kg m⁻³. Their scatter is the uncertainty with which the critical point of a real fluid is known, even for a substance as well studied as this one.

## Vapor pressure up to the critical temperature

```@example co2
v = points(db; component = "carbon dioxide", exact = true, property = "Vapor or sublimation pressure")
t = table(v; unitful = true)

T = ustrip.(u"K", t.temperature)
p = ustrip.(u"Pa", t.value)

use = (240 .< T .< Tref)
T, p = T[use], p[use]
year = Float64.(t.year)[use]

psat(model, T) = Clapeyron.saturation_pressure(model, T)[1]

dev_p = map(models) do model
    (predict(psat, model, T) .- p) ./ p
end

(points = length(p), table = map(summarize, dev_p))
```

Points between a model's own critical temperature and the real one (for the models whose ``T_\mathrm{c}`` is lower) have no saturation state in that model and are `NaN`; they are left out of the statistics, which `n` makes visible.

```@example co2
fig = Figure(size = (900, 440))
ax1 = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "p [MPa]", title = "Vapor pressure of carbon dioxide")
scatter!(ax1, T, p ./ 1e6; color = "#9aa3c7", markersize = 6, label = "ThermoML")
for (name, model) in pairs(models)
    Ts = range(240, 0.9995 * crit[name][1]; length = 100)
    lines!(ax1, Ts, predict(psat, model, Ts) ./ 1e6; color = palette[name], linewidth = 2.5, label = String(name))
end
vlines!(ax1, [Tref]; color = (:gray, 0.8), linestyle = :dash)
axislegend(ax1; position = :lt)

ax2 = Axis(fig[1, 2]; xlabel = "T [K]", ylabel = "(p_EoS − p_exp)/p_exp [%]", title = "Deviation")
hlines!(ax2, [0.0]; color = "#e8ecff", linewidth = 1.5)
for (name, dev) in pairs(dev_p)
    scatter!(ax2, T, 100 .* dev; color = palette[name], markersize = 5, label = String(name))
end
vlines!(ax2, [Tref]; color = (:gray, 0.8), linestyle = :dash)
limits!(ax2, nothing, nothing, -10, 10)
fig
```

The dashed line is the reference critical temperature. Cubic equations, anchored to the critical point, are close to the data right up to it. SAFT models, which place their critical point higher, show a growing deviation as ``T`` approaches ``T_\mathrm{c}``.

## The coexistence curve

Density is the property in which the mean-field behaviour shows. The lines below are the saturated liquid and vapor densities of each model, computed from the saturation volumes; the points are the experimental densities in the same region (state points at any pressure, drawn as translucent circles so that dense groups look darker).

```@example co2
vd = points(
    db; component = "carbon dioxide", exact = true, property = "Mass density",
    temperature = (270u"K", 340u"K"), pressure = (1u"MPa", 25u"MPa"),
)
td = table(vd; unitful = true)

Td = ustrip.(u"K", td.temperature)
pd = ustrip.(u"Pa", td.pressure)
ρ = ustrip.(u"kg/m^3", td.value)

function coexistence(model, Ts)
    ρl = fill(NaN, length(Ts))
    ρv = fill(NaN, length(Ts))
    for (i, T) in enumerate(Ts)
        try
            _, vl, vv = Clapeyron.saturation_pressure(model, T)
            ρl[i], ρv[i] = M / vl, M / vv
        catch
        end
    end
    return ρl, ρv
end

(points = length(ρ), articles = length(unique(td.doi)))
```

```@example co2
fig = Figure(size = (1000, 520))
ax = Axis(
    fig[1, 1]; xlabel = "ρ [kg m⁻³]", ylabel = "T [K]",
    title = "Coexistence curve of carbon dioxide",
)
for (name, model) in pairs(models)
    Ts = range(250, 0.9995 * crit[name][1]; length = 150)
    ρl, ρv = coexistence(model, Ts)
    # liquid and vapor branches share one colour; only one carries the legend entry
    lines!(ax, ρl, Ts; color = palette[name], linewidth = name == :GERG2008 ? 3.5 : 2.5, label = String(name))
    lines!(ax, ρv, Ts; color = palette[name], linewidth = name == :GERG2008 ? 3.5 : 2.5)
end
hlines!(ax, [Tref]; color = (:gray, 0.8), linestyle = :dash)
# critical constants of the archive: stars where an article gives both Tc and ρc; a mark on
# the right edge for a Tc alone and on the bottom edge for a ρc alone
both = sort!(collect(intersect(keys(Tc_db), keys(ρc_db))))
only_T = sort!(collect(setdiff(keys(Tc_db), both)))
only_ρ = sort!(collect(setdiff(keys(ρc_db), both)))
xmax, ymin = 1250.0, 245.0
star = (color = "#ffe600", strokecolor = "#ffe600", strokewidth = 2, markersize = 18)
isempty(both) || scatter!(
    ax, Float64[ρc_db[d] for d in both], Float64[Tc_db[d] for d in both];
    marker = :star5, markersize = 20, color = "#ffe600", strokecolor = "#090b17", strokewidth = 1,
    label = "ThermoML critical point ($(length(both)))",
)
isempty(only_T) || scatter!(
    ax, fill(xmax, length(only_T)), Float64[Tc_db[d] for d in only_T];
    marker = :hline, star..., label = "ThermoML Tc alone ($(length(only_T)))",
)
isempty(only_ρ) || scatter!(
    ax, Float64[ρc_db[d] for d in only_ρ], fill(ymin, length(only_ρ));
    marker = :vline, star..., label = "ThermoML ρc alone ($(length(only_ρ)))",
)
# translucent, outlined markers: dense groups look darker and every point stays visible
scatter!(
    ax, ρ, Td;
    color = ("#9aa3c7", 0.35), strokecolor = "#9aa3c7", strokewidth = 1, markersize = 9,
    label = "ThermoML ($(length(ρ)) points)",
)
limits!(ax, 0, xmax + 20, ymin - 5, nothing)
Legend(fig[1, 2], ax)
fig
```

With the reference equation as a guide, look at the top of each curve. The cubic and SAFT curves are too wide near ``T_\mathrm{c}``, and the SAFT ones end at a temperature higher than the real one. Each colour is one model and both of its branches share it, the white line being the reference equation. Points above the dashed line are supercritical: they belong to no coexistence curve, and the isobars that cross them are where the compressibility diverges. A point to the left or right of the dome at a given temperature is a compressed liquid or a vapor at a pressure other than the saturation pressure.

## A map of the deviation in the T–p plane

Density at given ``T`` and ``p`` (the quantity a densimeter measures) does not need the saturation curve: the model volume at that state point is enough. For supercritical states there is a single root, so the default phase detection is used instead of forcing the liquid root. The map shows the relative deviation of each model, with the reversed `:managua` colormap and a range that is symmetric about zero, so that white means agreement. The yellow stars are the critical points reported in the archive (the pairs of critical temperature and pressure of the same article).

```@example co2
density(model, p, T) = M / Clapeyron.volume(model, p, T)

ρmodel = map(models) do model
    predict(density, model, pd, Td)
end
dev_ρ = map(ρmodel) do q
    (q .- ρ) ./ ρ
end

near = abs.(Td .- Tref) .<= 10          # within 10 K of the reference critical temperature
(all = map(summarize, dev_ρ), near = map(d -> summarize(d[near]), dev_ρ))
```

```@example co2
fig = Figure(size = (940, 760))
# critical points of the archive: (T, p) pairs of the same article
Tpc = [(Tc_db[d], pc_db[d]) for d in sort!(collect(intersect(keys(Tc_db), keys(pc_db))))]

scatters = []
for (k, (name, dev)) in enumerate(pairs(dev_ρ))
    k > 4 && break
    ax = Axis(
        fig[fld1(k, 2), mod1(k, 2)];
        xlabel = fld1(k, 2) == 2 ? "T [K]" : "", ylabel = mod1(k, 2) == 1 ? "p [MPa]" : "", title = String(name),
    )
    push!(scatters, scatter!(ax, Td, pd ./ 1e6; color = 100 .* dev, colorrange = (-10, 10), markersize = 7))
    isempty(Tpc) || scatter!(
        ax, first.(Tpc), last.(Tpc);
        marker = :star5, markersize = 18, color = "#ffe600", strokecolor = "#090b17", strokewidth = 1,
    )
end
Colorbar(fig[1:2, 3], first(scatters); label = "(ρ_EoS − ρ_exp)/ρ_exp [%]")
fig
```

The figure shows the first four models. `GERG2008`, the reference equation, is in the table above: its deviation is small everywhere except in a narrow band around the critical point, where the data themselves are the less reliable part of the comparison (see below).

## Other properties near the critical point

The archive holds more than densities. Which properties does it have for carbon dioxide close to the critical point? A count answers that, with a window of 10 K around the critical temperature and 5 to 12 MPa:

```@example co2
window = (Tref - 10, Tref + 10) .* u"K"
pwindow = (5u"MPa", 12u"MPa")

function coverage(property)
    v = try
        points(db; component = "carbon dioxide", exact = true, property, temperature = window, pressure = pwindow)
    catch
        return (; property, points = 0, articles = 0)
    end
    t = table(v)
    return (; property, points = length(t.value), articles = length(unique(t.doi)))
end

coverage.([
    "Mass density", "Speed of sound", "Thermal conductivity", "Thermal diffusivity",
    "Viscosity", "Heat capacity at constant pressure",
])
```

A property that the archive does not have for this compound shows `points = 0`. The archive can only offer what was published. In the snapshot of 2020-09-30 this compound has no heat-capacity property at all, so the divergence of ``c_p`` at the critical point cannot be seen here. Thermal conductivity, which also grows near the critical point, comes from a single article, and the speed of sound, which has a minimum there, from two. Where points exist they can be drawn like any other property:

```@example co2
fig = Figure(size = (980, 420))
scatters = []
for (j, (property, label, unit)) in enumerate((
    ("Thermal conductivity", "λ [W m⁻¹ K⁻¹]", u"W/m/K"),
    ("Speed of sound", "w [m s⁻¹]", u"m/s"),
))
    ax = Axis(fig[1, j]; xlabel = "p [MPa]", ylabel = label, title = property)
    v = try
        points(db; component = "carbon dioxide", exact = true, property, temperature = (270u"K", 340u"K"), pressure = (1u"MPa", 25u"MPa"))
    catch
        nothing
    end
    isnothing(v) && continue
    t = table(v; unitful = true)
    isempty(t.value) && continue
    push!(scatters, scatter!(
        ax, ustrip.(u"MPa", t.pressure), ustrip.(unit, t.value);
        color = ustrip.(u"K", t.temperature), colorrange = (270, 340),
        strokecolor = "#e8ecff", strokewidth = 0.6, markersize = 9,
    ))
    vlines!(ax, [pref / 1e6]; color = (:gray, 0.8), linestyle = :dash)
end
isempty(scatters) || Colorbar(fig[1, 3], first(scatters); label = "T [K]")
fig
```

The pressure is on the horizontal axis and the temperature is the colour, so isotherms appear as lines of one colour; the dashed line is the critical pressure of the reference equation. If a panel is empty, there are no points of that property in the window. That is itself the result: this is the kind of gap that a coverage analysis of the archive is meant to find.

## Reading the result

- **Near-critical scatter is not only the model.** At ``T_\mathrm{c}``, ``\kappa_T`` diverges, so an error of 10 mK in temperature or 10 kPa in pressure changes the density by several percent. Large deviations close to the star may be experimental uncertainty in the state point, not in the density.
- **Mean-field models cannot do better.** Even a perfect set of parameters leaves the exponent ``\beta = 1/2``. A crossover treatment, which switches from the analytical equation to the scaling behaviour near the critical point, is needed to follow the experiment inside the critical region.
- **Use the uncertainty columns.** `table` gives the uncertainty of each value in `unc_k2`. Comparing the deviation with it, point by point, separates real model failures from measurements that are within their own uncertainty.

## Variations to try

- Change the fluid: `"propane"` or `"methane"` have well-covered critical regions in the archive.
- Narrow the pressure window to isobars around ``p_\mathrm{c}`` and plot density against temperature to see the steepest part of the transition.
- The reference equation can also be the one built into Clapeyron from CoolProp (`using CoolProp` and `SingleFluid("carbon dioxide")`), whose carbon dioxide equation is that of Span and Wagner; it is not used here to keep the documentation environment small.

## References

- R. Span, W. Wagner, "A new equation of state for carbon dioxide covering the fluid region from the triple-point temperature to 1100 K at pressures up to 800 MPa", *Journal of Physical and Chemical Reference Data* **25** (1996) 1509–1596.
- O. Kunz, W. Wagner, "The GERG-2008 wide-range equation of state for natural gases and other mixtures: an expansion of GERG-2004", *Journal of Chemical & Engineering Data* **57** (2012) 3032–3091.
- The experimental data come from the ThermoML Archive of NIST/TRC and the articles it indexes; see [About the data](@ref 40-about-data).
