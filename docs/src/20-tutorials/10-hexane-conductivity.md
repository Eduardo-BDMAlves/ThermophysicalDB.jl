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

db = database(progress = false)
v = points(db; component = "hexane", exact = true, property = "Thermal conductivity")
```

`exact = true` asks for systems that consist of hexane and nothing else. Without it, a mixture such as hexane + heptane would also qualify, because by default a system matches if it *contains* any listed component.

## Unitful columns

Because the selection holds a single property, all its values share one unit, and [`table`](@ref) can return `Unitful` quantities. Converting to the units we want to plot is then explicit and cannot go wrong silently:

```@example hex
t = table(v; unitful = true)

T = ustrip.(u"K", t.temperature)
p = ustrip.(u"MPa", t.pressure)
λ = ustrip.(u"W/m/K", t.value)
U = ustrip.(u"W/m/K", t.unc_k2)    # expanded uncertainty restated at k = 2

(points = length(λ), articles = length(unique(t.doi)), phases = unique(t.phase))
```

!!! info "Why Unitful here and not always?"
    A `Vector{<:Quantity}` is fast only if every element has the same unit. `table(v; unitful = true)` therefore refuses a selection that mixes units (say, conductivity and density) and tells you to narrow it with `property`. Without `unitful`, you get plain `Float64` columns and a `unit` column of text, which is the right choice when you want to look at several properties at once.

## Conductivity against temperature

Colour shows the pressure of each point and the bars are the expanded uncertainty at ``k = 2``. Points without a stated pressure or uncertainty are simply not drawn in that layer.

```@example hex
has_p = isfinite.(p)
has_u = isfinite.(U)

fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "λ [W m⁻¹ K⁻¹]", title = "Hexane: λ(T, p)")
errorbars!(ax, T[has_u], λ[has_u], U[has_u]; color = (:gray, 0.45), whiskerwidth = 4)
sc = scatter!(ax, T[has_p], λ[has_p]; color = p[has_p], markersize = 8)
Colorbar(fig[1, 2], sc; label = "p [MPa]")
fig
```

What to look for: in the liquid, ``\lambda`` falls slowly as the temperature rises, because molecules move apart and exchange energy less efficiently; in a dilute gas the trend is reversed, since faster molecules carry more energy between collisions. The vertical spread at a given temperature is the pressure effect, which the next plot isolates.

## Conductivity against pressure

Compression packs molecules closer, so ``\lambda`` grows with ``p``, strongly in the liquid and weakly in a dilute gas. To see this we group the points into 10 K bins of temperature, which acts as a set of nominal isotherms:

```@example hex
bin = round.(Int, T ./ 10) .* 10
bins = sort(unique(bin[has_p]))
shade(i) = cgrad(:managua; rev = true)[(i - 1) / max(length(bins) - 1, 1)]

fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "p [MPa]", ylabel = "λ [W m⁻¹ K⁻¹]", title = "Nominal isotherms (10 K bins)")
for (i, b) in enumerate(bins)
    m = has_p .& (bin .== b)
    order = sortperm(p[m])
    scatterlines!(
        ax, p[m][order], λ[m][order];
        color = shade(i), label = "$b K", markersize = 6, linewidth = 1.4,
    )
end
Legend(fig[1, 2], ax, "T bin")
fig
```

## How good are the points?

The relative expanded uncertainty, ``U/\lambda``, summarises how well each laboratory claims to know its own number. The histogram counts points; its width tells you how much weight a fit should give to different articles.

```@example hex
relative = 100 .* U[has_u] ./ λ[has_u]

fig = Figure(size = (760, 360))
ax = Axis(
    fig[1, 1]; xlabel = "U(k = 2)/λ [%]", ylabel = "points",
    title = "Stated uncertainty of the hexane data",
)
hist!(ax, relative; bins = 30, color = ("#00e5ff", 0.85), strokewidth = 1, strokecolor = :white)
fig
```

## Where to go from here

- Fit a model with weights ``w_i = 1/U_i^2``: because `unc_k2` is on one common basis, the weights of different articles are comparable. See [Uncertainty](@ref uncertainty).
- Restrict the selection to one article with `doi = "…"` or to one laboratory with `author = "…"`. See [Selecting points](@ref selecting).
