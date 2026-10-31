```@meta
CurrentModule = ThermophysicalDB
```

# [Experiment against equations of state](@id tutorial_eos)

An equation of state (EoS) is a model: it represents the thermodynamics of a fluid with a few parameters. Whether it is *good* is an empirical question, and the archive holds the experiments that answer it. This tutorial puts hexane data next to the predictions of four EoS from [Clapeyron.jl](https://github.com/ClapeyronThermo/Clapeyron.jl) [Walker2022](@cite):

| Model | Family | What it brings |
|:--|:--|:--|
| `SRK` | cubic (Soave–Redlich–Kwong [Soave1972](@cite)) | the same family as PR, a different attractive term |
| `PR` | cubic (Peng–Robinson [Peng1976](@cite)) | three parameters per fluid, fast |
| `tcPR` | cubic (Peng–Robinson with volume translation and a revised attractive term) | the PR equation with the liquid volume corrected by a shift |
| `PCSAFT` | SAFT (perturbed chain [Gross2001](@cite)) | molecular model with chain length, accurate for liquids |

The three cubic equations are cheap to evaluate and the SAFT one is the molecular reference for the liquid. `tcPR` shows what a *volume translation* does: the volume of the cubic equation is shifted by a constant, ``v = v_\mathrm{EoS} - c``. A constant shift leaves the equality of the chemical potentials of the two phases unchanged, so the translation alone does not touch the vapor pressure, while the liquid density, where the volume is small and the shift is a large fraction of it, can be corrected by several percent. `tcPR` also changes the temperature dependence of the attractive term, so its vapor pressure differs somewhat from that of `PR`; the comparison below shows both effects separately.

Cubic equations are built from the van der Waals idea: a repulsive volume term plus an attraction that grows with density. They are tuned to reproduce the critical point and the vapor pressure, and pay for it in the liquid volume, which is typically off by several percent. SAFT models treat the molecule as a chain of segments and account for its connectivity, which is why they can do much better in the liquid. The comparison below makes that difference visible.

```@setup eos
Main.DocsSetup.activate!()
```

## Models and a safe evaluator

All four models are built from a list of component names.

```@example eos
using ThermophysicalDB, CairoMakie, Unitful, Statistics
using Clapeyron

fluid = ["hexane"]
models = (
    SRK = SRK(fluid),
    PR = PR(fluid),
    tcPR = tcPR(fluid),
    PCSAFT = PCSAFT(fluid),
)
keys(models)
```

An EoS can fail to converge at a state point, especially near the critical point or in a metastable region. The helper below turns any failure into `NaN`, so one bad point never aborts a whole comparison. It also returns a vector of the same length as the data, which keeps the columns aligned with the table. If no point at all converges the helper warns, because a `NaN` column usually means a wrong call, not a hard state.

```@example eos
function predict(f, model, args...)
    raw = map(eachindex(first(args))) do i
        try
            f(model, (a[i] for a in args)...)
        catch
            missing
        end
    end
    first_ok = findfirst(!ismissing, raw)
    if first_ok === nothing
        @warn "No state point converged; check the arguments of the model call."
        return fill(NaN, length(raw))
    end
    failed = NaN * oneunit(raw[first_ok])
    return typeof(failed)[ismissing(r) ? failed : r for r in raw]
end

# a dimensionless quantity (any combination of units) as a plain number, for plotting and statistics
plain(x::Unitful.AbstractQuantity) = Float64(ustrip(uconvert(NoUnits, x)))
plain(x::Real) = Float64(x)

# average absolute relative deviation and bias, in percent, ignoring NaN
function summarize(dev)
    ok = filter(isfinite, dev)
    isempty(ok) && return (; n = 0, AARD = NaN * u"percent", bias = NaN * u"percent")
    return (; n = length(ok), AARD = round(100 * mean(abs, ok); digits = 4) * u"percent", bias = round(100 * mean(ok); digits = 4) * u"percent")
end
```

## Vapor pressure

The saturation pressure is a function of temperature alone, so each experimental point maps to one model call.

```@example eos
db = database(progress = false)

# the temperature window is part of the selection: a range where all four models are well defined
v = points(
    db; component = "hexane", exact = true, property = "Vapor or sublimation pressure",
    temperature = (230u"K", 500u"K"), pure = true
)
t = table(v; unitful = true)

T = t.temperature
p = t.value
year = Float64.(t.year)

psat(model, T) = Clapeyron.saturation_pressure(model, T)[1] * u"Pa"   # first entry is the pressure

pvap = map(models) do model
    predict(psat, model, T)
end

dev_p = map(pvap) do q
    plain.((q .- p) ./ p)
end

map(summarize, dev_p)
```

`saturation_pressure` returns the pressure and the two saturated volumes, and the first entry is all we need here. Each row of the printed table is a model; `AARD` is the mean absolute relative deviation and `bias` its signed mean. A positive bias means the model over-predicts the pressure.

```@example eos
fig = Figure(size = (900, 440))
ax1 = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "p [kPa]", yscale = log10, title = "Vapor pressure of hexane")
scatter!(ax1, ustrip.(u"K", T), ustrip.(u"kPa", p); color = "#e8ecff", markersize = 6, label = "ThermoML")
Ts = range(extrema(T)...; length = 80)
for (name, model) in pairs(models)
    lines!(ax1, ustrip.(u"K", Ts), ustrip.(u"kPa", predict(psat, model, Ts)); linewidth = 2.5, label = String(name))
end
axislegend(ax1; position = :lt)

ax2 = Axis(fig[1, 2]; xlabel = "T [K]", ylabel = "(p_EoS − p_exp)/p_exp [%]", title = "Relative deviation")
hlines!(ax2, [0.0]; color = "#e8ecff", linewidth = 1.5)
for (name, dev) in pairs(dev_p)
    scatter!(ax2, ustrip.(u"K", T), 100 .* dev; markersize = 5, label = String(name))
end
ylims!(ax2, -15.0, 15.0)
fig
```

Cubic equations are fitted to the vapor pressure, so they should do well here. Note that with this simple procedure, combined with the previous statistical analysis, one can evaluate the quality of each EoS at specific ranges of pressure and temperature.

## Liquid density

Density depends on two variables, so the selection needs a pressure. We take liquid points below the normal boiling point range, where the molar volume of the liquid is what the EoS has to get right.

```@example eos
vd = points(
    db; component = "hexane", exact = true, property = "Mass density",
    temperature = (250u"K", 420u"K"), pressure = (1u"kPa", 60u"MPa"),
    pure = true,
)
td = table(vd; unitful = true)

Td = td.temperature
pd = td.pressure
ρ = td.value
yd = Float64.(td.year)

liquid_density(model, P, T) = mass_density(model, P, T, phase = :liquid)

ρmodel = map(models) do model
    predict(liquid_density, model, pd, Td)
end
dev_ρ = map(ρmodel) do q
    plain.((q .- ρ) ./ ρ)
end

map(summarize, dev_ρ)
```

The molar mass converts the molar volume of the EoS to a mass density. We pass `phase = :liquid` so the solver looks for the liquid root of the volume equation instead of choosing one itself; a cubic equation can have three real roots in the two-phase region and the wrong one would be a silent error.

```@example eos
fig = Figure(size = (900, 440))
ax = Axis(fig[1, 1]; xlabel = "model", ylabel = "(ρ_EoS − ρ_exp)/ρ_exp [%]", title = "Liquid density of hexane")
labels = collect(keys(dev_ρ))
for (i, name) in enumerate(labels)
    d = filter(isfinite, Float64.(dev_ρ[name]))
    boxplot!(ax, fill(i, length(d)), d; color = (Main.DocsSetup.CYCLE[i], 0.7), show_outliers = false, width = 0.6)
end
ax.xticks = (1:length(labels), String.(labels))
hlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
fig
```

The expectation is a systematic offset of several percent for the cubic models and a much smaller one for the SAFT models. Whether the numbers confirm it is exactly what you read from the `AARD` and `bias` above.

## Where does a model fail? A field

Because the deviation depends on both variables, a map on the T–p plane is more informative than a table. The points are coloured with the cold-to-hot colormap of this documentation: blue where the model underestimates the density, red where it overestimates it, and white at exact agreement. The range is symmetric around zero so that the white midpoint is zero.

```@example eos
fig = Figure(size = (940, 420))
for (j, name) in enumerate((:PR, :PCSAFT))
    ax = Axis(fig[1, j]; xlabel = "T [K]", ylabel = j == 1 ? "p [MPa]" : "", title = String(name))
    sc = scatter!(
        ax, ustrip.(u"K", Td), ustrip.(u"MPa", pd); color = 100 .* dev_ρ[name], colorrange = (-8, 8), markersize = 8,
    )
    j == 2 && Colorbar(fig[1, 3], sc; label = "density deviation [%]")
end
fig
```

The structure of the map shows *where* the problem lives: whether it grows with pressure (compressibility of the liquid) or with temperature (approach to the critical point).

## Going further

- Add a model: `SAFTVRMie(fluid)`, for instance, goes into the `models` tuple and every cell of the page follows, at the cost of one more solution per state point (and of its compilation, which is the larger part for the SAFT models).
- Replace `"hexane"` with another fluid. Clapeyron looks the name up in its own parameter database, which may spell it differently from ThermoML; if the model constructor fails, try the common name or the CAS-style name it suggests in the error.
- Compare derived properties with `Clapeyron.speed_of_sound(model, p, T; phase = :liquid)` or `Clapeyron.isobaric_heat_capacity(model, p, T)`, selecting the matching property in [`points`](@ref).
- For mixtures, Clapeyron needs binary interaction parameters; models built from several names use the ones in its database when they exist.
- The `uncertainty` columns of [`table`](@ref) allow a weighted statistic: a deviation smaller than the stated expanded uncertainty is not a disagreement at all. See [Uncertainty](@ref uncertainty).

## Sources of the data

```@raw html
<details class="details custom-block"><summary>The articles behind the data of this page</summary>
```

```@example eos
Main.DocsCredits.credits(v, vd)
```

The articles of the whole documentation, with a download of the BibTeX file, are in [Data credits](@ref data_credits).

```@raw html
</details>
```
