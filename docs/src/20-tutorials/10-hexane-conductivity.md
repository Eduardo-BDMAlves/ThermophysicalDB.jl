```@meta
CurrentModule = ThermophysicalDB
```

# [Thermal conductivity of hexane](@id tutorial_hexane)

Thermal conductivity, ``\lambda``, is the proportionality constant of Fourier's law: the heat flux is ``\mathbf{q} = -\lambda \nabla T``. It is the property that the transient hot-wire method measures, and it depends on both temperature and pressure. In this tutorial we take every thermal-conductivity point of pure hexane in the archive and look at it from three angles: against temperature, against pressure, and through its uncertainty.

```@setup hex
Main.DocsSetup.activate!()
```

## Select the points

```@example hex
using ThermophysicalDB, CairoMakie, Unitful

db = database()
v = points(db; component = "hexane", exact = true, property = "Thermal conductivity")
```

`exact = true` asks for systems that consist of hexane and nothing else. Without it, a mixture such as hexane + heptane would also qualify, because by default a system matches if it *contains* any listed component.

## Unitful columns

The columns of [`table`](@ref) are quantities:

```@example hex
t = table(v; unitful = true)

T = t.temperature
p = t.pressure
λ = t.value
U = t.unc_k2    # expanded uncertainty restated at k = 2

(points = length(λ), articles = length(unique(t.doi)), phases = unique(t.phase))
```

## Conductivity against temperature

Colour shows the pressure of each point on a logarithmic-like scale (most points are at low pressure, so a linear scale would hide the high-pressure ones) and the bars are the expanded uncertainty at ``k = 2``. Points without a stated pressure or uncertainty are simply not drawn in that layer.

```@example hex
has_p = isfinite.(p)
has_u = isfinite.(U)
shown = has_u .& has_p

fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "λ [W m⁻¹ K⁻¹]", title = "Hexane: λ(T, p)")
errorbars!(
    ax, ustrip.(u"K", T[shown]), ustrip.(u"W/m/K", λ[shown]), ustrip.(u"W/m/K", U[shown]);
    color = (:gray, 0.45), whiskerwidth = 4,
)
order = findall(shown)
order = order[sortperm(p[order])]    # high pressures are drawn last, on top of the crowd at low pressure
sc = scatter!(
    ax, ustrip.(u"K", T[order]), ustrip.(u"W/m/K", λ[order]);
    color = ustrip.(u"MPa", p[order]), colorscale = Makie.pseudolog10, marker = :diamond, markersize = 9,
)
Colorbar(fig[1, 2], sc; label = "p [MPa]", ticks = [0, 1, 10, 50])
fig
```

What to look for: in the liquid, ``\lambda`` falls slowly as the temperature rises, because molecules move apart and exchange energy less efficiently; in a dilute gas the trend is reversed, since faster molecules carry more energy between collisions. The vertical spread at a given temperature is the pressure effect, which the next plot isolates.

## Conductivity against pressure

Compression packs molecules closer, so ``\lambda`` grows with ``p``, strongly in the liquid and weakly in a dilute gas. To see this we group the points into 50 K bins of temperature, which acts as a set of nominal isotherms:

```@example hex
bin = round.(Int, T ./ 50u"K") .* 50
bins = sort(unique(bin[has_p]))
shade(i) = Main.DocsSetup.FIELD[(i - 1) / max(length(bins) - 1, 1)]

fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "p [MPa]", ylabel = "λ [W m⁻¹ K⁻¹]", title = "Nominal isotherms (50 K bins)")
for (i, b) in enumerate(bins)
    m = has_p .& (bin .== b)
    order = sortperm(p[m])
    scatterlines!(
        ax, ustrip.(u"MPa", p[m][order]), ustrip.(u"W/m/K", λ[m][order]);
        color = shade(i), label = "$b K", markersize = 6, linewidth = 1.4,
    )
end
Legend(fig[1, 2], ax, "T bin")
fig
```

## How good are the points?

The relative expanded uncertainty, ``U/\lambda``, summarises how well each laboratory claims to know its own number. The histogram counts points; its width tells you how much weight a fit should give to different articles.

```@example hex
relative = 100 .* Float64.(U[has_u] ./ λ[has_u])

fig = Figure(size = (760, 360))
ax = Axis(
    fig[1, 1]; xlabel = "U(k = 2)/λ [%]", ylabel = "points",
    title = "Stated uncertainty of the hexane data",
)
hist!(ax, relative; bins = 30, color = ("#2fe0ff", 0.85), strokewidth = 1, strokecolor = :white)
fig
```

## Where to go from here

- Fit a model with weights ``w_i = 1/U_i^2``: because `unc_k2` is on one common basis, the weights of different articles are comparable. See [Uncertainty](@ref uncertainty).
- Restrict the selection to one article with `doi = "…"` or to one laboratory with `author = "…"`. See [Selecting points](@ref selecting).
