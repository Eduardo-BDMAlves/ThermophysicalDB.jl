```@meta
CurrentModule = ThermophysicalDB
```

# [Experiment against equations of state](@id tutorial_eos)

An equation of state (EoS) is a model: it closes the thermodynamics of a fluid with a few parameters. Whether it is *good* is an empirical question, and the archive holds the experiments that answer it. This tutorial puts hexane data next to the predictions of four EoS from [Clapeyron.jl](https://github.com/ClapeyronThermo/Clapeyron.jl):

| Model | Family | What it brings |
|:--|:--|:--|
| `PR` | cubic (Peng–Robinson) | two parameters per fluid, fast; known to be poor for liquid density |
| `SRK` | cubic (Soave–Redlich–Kwong) | the same family, a different attractive term |
| `PCSAFT` | SAFT (perturbed chain) | molecular model with chain length, accurate for liquids |
| `SAFTVRMie` | SAFT (variable range, Mie potential) | flexible repulsion and attraction, also predicts derivative properties |

Cubic equations are built from the van der Waals idea: a repulsive volume term plus an attraction that grows with density. They are tuned to reproduce the critical point and the vapor pressure, and pay for it in the liquid volume, which is typically off by several percent. SAFT models treat the molecule as a chain of segments and account for its connectivity, which is why they can do much better in the liquid. The comparison below makes that difference visible.

```@setup eos
Main.DocsSetup.activate!()
```

## Models and a safe evaluator

All four models are built from a list of component names. Clapeyron works in SI units (K, Pa, m³ per mole for a pure fluid), so predictions are compared with the data after converting the data, not the model.

```@example eos
using ThermophysicalDB, CairoMakie, Unitful, Statistics
using Clapeyron

fluid = ["hexane"]
models = (
    PR = PR(fluid),
    SRK = SRK(fluid),
    PCSAFT = PCSAFT(fluid),
    SAFTVRMie = SAFTVRMie(fluid),
)
keys(models)
```

An EoS can fail to converge at a state point, especially near the critical point or in a metastable region. The helper below turns any failure into `NaN`, so one bad point never aborts a whole comparison. It also returns a vector of the same length as the data, which keeps the columns aligned with the table.

```@example eos
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

# average absolute relative deviation (percent) and bias (percent), ignoring NaN
function summarize(dev)
    ok = filter(isfinite, dev)
    return (; n = length(ok), AARD = round(100 * mean(abs, ok); digits = 2), bias = round(100 * mean(ok); digits = 2))
end
```

## Vapor pressure

The saturation pressure is a function of temperature alone, so each experimental point maps to one model call. [`table`](@ref) with `unitful = true` gives the temperature in kelvin and the value in the unit of the source, which we convert to pascal.

```@example eos
db = database(progress = false)

v = points(db; component = "hexane", exact = true, property = "Vapor or sublimation pressure")
t = table(v; unitful = true)

T = ustrip.(u"K", t.temperature)
p = ustrip.(u"Pa", t.value)

# keep a range where all four models are well defined
use = 230 .< T .< 500
T, p = T[use], p[use]
year = Float64.(t.year)[use]

psat(model, T) = Clapeyron.saturation_pressure(model, T)[1]   # first entry is the pressure, Pa

pvap = map(models) do model
    predict(psat, model, T)
end

dev_p = map(pvap) do q
    (q .- p) ./ p
end

map(summarize, dev_p)
```

`saturation_pressure` returns the pressure and the two saturated volumes, and the first entry is all we need here. Each row of the printed table is a model; `AARD` is the mean absolute relative deviation and `bias` its signed mean. A positive bias means the model over-predicts the pressure.

```@example eos
fig = Figure(size = (900, 440))
ax1 = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "p [kPa]", yscale = log10, title = "Vapor pressure of hexane")
scatter!(ax1, T, p ./ 1e3; color = "#e8ecff", markersize = 6, label = "ThermoML")
Ts = range(extrema(T)...; length = 80)
for (name, model) in pairs(models)
    lines!(ax1, Ts, predict(psat, model, Ts) ./ 1e3; linewidth = 2.5, label = String(name))
end
axislegend(ax1; position = :lt)

ax2 = Axis(fig[1, 2]; xlabel = "T [K]", ylabel = "(p_EoS − p_exp)/p_exp [%]", title = "Relative deviation")
hlines!(ax2, [0.0]; color = "#e8ecff", linewidth = 1.5)
for (name, dev) in pairs(dev_p)
    scatter!(ax2, T, 100 .* dev; markersize = 5, label = String(name))
end
limits!(ax2, nothing, nothing, -15, 15)
fig
```

Cubic equations are fitted to the vapor pressure, so they should do well here. If a SAFT model is farther away, that is not a defect: its parameters were regressed on both the vapor pressure and the liquid density of many fluids, and the compromise shows.

## Liquid density

Density depends on two variables, so the selection needs a pressure. We take liquid points below the normal boiling point range, where the molar volume of the liquid is what the EoS has to get right.

```@example eos
vd = points(
    db; component = "hexane", exact = true, property = "Mass density",
    temperature = (250u"K", 420u"K"), pressure = (1u"kPa", 60u"MPa"),
)
td = table(vd; unitful = true)

Td = ustrip.(u"K", td.temperature)
pd = ustrip.(u"Pa", td.pressure)
ρ = ustrip.(u"kg/m^3", td.value)
yd = Float64.(td.year)

M = 0.086175    # kg/mol, molar mass of n-hexane

liquid_density(model, p, T) = M / Clapeyron.volume(model, p, T; phase = :liquid)

ρmodel = map(models) do model
    predict(liquid_density, model, pd, Td)
end
dev_ρ = map(ρmodel) do q
    (q .- ρ) ./ ρ
end

map(summarize, dev_ρ)
```

The molar mass converts the molar volume of the EoS to a mass density. We pass `phase = :liquid` so the solver looks for the liquid root of the volume equation instead of choosing one itself; a cubic equation can have three real roots in the two-phase region and the wrong one would be a silent error.

```@example eos
fig = Figure(size = (900, 440))
ax = Axis(fig[1, 1]; xlabel = "model", ylabel = "(ρ_EoS − ρ_exp)/ρ_exp [%]", title = "Liquid density of hexane")
labels = collect(keys(dev_ρ))
for (i, name) in enumerate(labels)
    d = filter(isfinite, 100 .* dev_ρ[name])
    boxplot!(ax, fill(i, length(d)), d; color = (Main.DocsSetup.CYCLE[i], 0.7), show_outliers = false, width = 0.6)
end
ax.xticks = (1:length(labels), String.(labels))
hlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
fig
```

The expectation is a systematic offset of several percent for the cubic models and a much smaller one for the SAFT models. Whether the numbers confirm it is exactly what you read from the `AARD` and `bias` above.

## Where does a model fail? A field

Because the deviation depends on both variables, a map on the T–p plane is more informative than a table. The points are coloured with the reversed `:managua` colormap, the default of this documentation for continuous data; the range is symmetric around zero so that white means exact agreement.

```@example eos
fig = Figure(size = (940, 420))
for (j, name) in enumerate((:PR, :PCSAFT))
    ax = Axis(fig[1, j]; xlabel = "T [K]", ylabel = j == 1 ? "p [MPa]" : "", title = String(name))
    sc = scatter!(
        ax, Td, pd ./ 1e6; color = 100 .* dev_ρ[name], colorrange = (-8, 8), markersize = 8,
    )
    j == 2 && Colorbar(fig[1, 3], sc; label = "density deviation [%]")
end
fig
```

The structure of the map shows *where* the problem lives: whether it grows with pressure (compressibility of the liquid) or with temperature (approach to the critical point).

## Which laboratories disagree with every model?

A deviation that is the same for all four models is more likely to come from the data than from the models. The median over the models points to the sources worth inspecting:

```@example eos
consensus = [median(filter(isfinite, [dev_ρ[k][i] for k in keys(dev_ρ)])) for i in eachindex(ρ)]

by_doi = Dict{String,Vector{Float64}}()
for (d, c) in zip(td.doi, consensus)
    isfinite(c) && push!(get!(by_doi, d, Float64[]), c)
end

ranked = sort(collect(by_doi); by = kv -> -abs(median(kv.second)))
[(doi = first(kv), n = length(last(kv)), median_deviation_percent = round(100 * median(last(kv)); digits = 2)) for kv in first(ranked, 5)]
```

## Going further

- Replace `"hexane"` with another fluid. Clapeyron looks the name up in its own parameter database, which may spell it differently from ThermoML; if the model constructor fails, try the common name or the CAS-style name it suggests in the error.
- Compare derived properties with `Clapeyron.speed_of_sound(model, p, T; phase = :liquid)` or `Clapeyron.isobaric_heat_capacity(model, p, T)`, selecting the matching property in [`points`](@ref).
- For mixtures, Clapeyron needs binary interaction parameters; models built from several names use the ones in its database when they exist.
- The `uncertainty` columns of [`table`](@ref) allow a weighted statistic: a deviation smaller than the stated expanded uncertainty is not a disagreement at all. See [Uncertainty](@ref uncertainty).
