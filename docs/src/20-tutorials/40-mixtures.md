```@meta
CurrentModule = ThermophysicalDB
```

# [Binary mixtures](@id tutorial_mixtures)

A mixture is rarely the average of its pure components. The difference is captured by **excess properties**: the value of a property for the real mixture minus the value of an ideal mixture of the same composition. Two classics are the viscosity deviation and the excess volume,

```math
\Delta\eta = \eta - \sum_i x_i\,\eta_i, \qquad
V^\mathrm{E} = \frac{\sum_i x_i M_i}{\rho} - \sum_i x_i\,\frac{M_i}{\rho_i},
```

where ``x_i`` are mole fractions, ``M_i`` molar masses, ``\eta_i`` and ``\rho_i`` the properties of the pure components at the same temperature and pressure as the mixture. A nonzero excess volume means the molecules pack differently in the mixture than in the pure liquids, which is a direct signature of the intermolecular forces.

Ethanol + water is the textbook case: both liquids form hydrogen bonds, and they bond with each other. In this tutorial we assemble both excess properties at 25 °C from the archive, using the mixture data and the pure-component data that the same database holds.

```@setup mix
Main.DocsSetup.activate!()
```

## Selecting a binary system

`component` accepts a list. With `match = :all` a system must contain every listed component, and `exact = true` on top of that requires it to contain *nothing else*, so the result is precisely the binary ethanol + water:

```@example mix
using ThermophysicalDB, CairoMakie, Unitful, Statistics

db = database(progress = false)

# 25 °C, with a tolerance of 0.05 K: temperatures in the archive are rounded differently
window = (24.95u"°C", 25.05u"°C")

mixture(property) = points(
    db; component = ["ethanol", "water"], match = :all, exact = true,
    property, temperature = window,
)
pure(name, property) = points(
    db; component = name, exact = true, property, temperature = window,
)

mixture("Viscosity")
```

## Composition needs care

A mixture point carries the compositions `x1, x2, x3` of its components *in the order of the `components` column*, and `xkind` says what they express. The same system can therefore appear as `"ethanol + water"` in one article and as `"water + ethanol"` in another, and some articles give mass fractions instead of mole fractions. Look before you plot:

```@example mix
tv = table(mixture("Viscosity"); unitful = true)

(
    points = length(tv.value),
    articles = length(unique(tv.doi)),
    orders = unique(tv.components),
    composition = unique(tv.xkind),
)
```

We keep mole-fraction points only, and take the ethanol fraction from whichever of `x1`, `x2` belongs to ethanol:

```@example mix
ethanol_fraction(t) = ifelse.(startswith.(t.components, "ethanol"), t.x1, t.x2)

keep = (tv.xkind .== "Mole fraction") .& isfinite.(ethanol_fraction(tv))
x = ethanol_fraction(tv)[keep]
η = ustrip.(u"mPa*s", tv.value)[keep]
year = Float64.(tv.year)[keep]

length(x)
```

## Viscosity against composition

The pure end members come from the same database, so mixture and references share the same sources of error (and any tendency of a laboratory to over- or under-estimate). Medians guard against a stray point:

```@example mix
pure_median(name, property, unit) = median(ustrip.(unit, table(pure(name, property); unitful = true).value))

η_ethanol = pure_median("ethanol", "Viscosity", u"mPa*s")
η_water = pure_median("water", "Viscosity", u"mPa*s")
(η_ethanol = η_ethanol, η_water = η_water)
```

```@example mix
Δη = η .- (x .* η_ethanol .+ (1 .- x) .* η_water)

fig = Figure(size = (900, 420))
ax1 = Axis(fig[1, 1]; xlabel = "x ethanol", ylabel = "η [mPa s]", title = "Viscosity at 25 °C")
sc = scatter!(ax1, x, η; color = year, markersize = 9)
hlines!(ax1, [η_ethanol, η_water]; color = (:gray, 0.7), linestyle = :dash)

ax2 = Axis(fig[1, 2]; xlabel = "x ethanol", ylabel = "Δη [mPa s]", title = "Viscosity deviation")
hlines!(ax2, [0.0]; color = "#e8ecff", linewidth = 1.5)
scatter!(ax2, x, Δη; color = year, markersize = 9)
Colorbar(fig[1, 3], sc; label = "year of publication")
fig
```

The viscosity of the mixture rises above *both* pure components at intermediate compositions: the ideal mixture would stay between them. The positive deviation is commonly attributed to the hydrogen-bonded structures that water and ethanol build together, which hinder molecular motion more than either liquid's own network.

## Excess volume

The density data give the second signature. We turn each mixture density into a molar volume with the molar masses of the pure components, and subtract the ideal molar volume built from the pure densities:

```@example mix
M_ethanol = 46.068     # g/mol
M_water = 18.015       # g/mol

td = table(mixture("Mass density"); unitful = true)
use = (td.xkind .== "Mole fraction") .& isfinite.(ethanol_fraction(td))

xd = ethanol_fraction(td)[use]
ρ = ustrip.(u"g/cm^3", td.value)[use]            # g/cm³, so V is in cm³/mol
yd = Float64.(td.year)[use]

ρ_ethanol = pure_median("ethanol", "Mass density", u"g/cm^3")
ρ_water = pure_median("water", "Mass density", u"g/cm^3")

V = (xd .* M_ethanol .+ (1 .- xd) .* M_water) ./ ρ
V_ideal = xd .* (M_ethanol / ρ_ethanol) .+ (1 .- xd) .* (M_water / ρ_water)
VE = V .- V_ideal

(points = length(xd), articles = length(unique(td.doi)))
```

```@example mix
fig = Figure(size = (760, 440))
ax = Axis(fig[1, 1]; xlabel = "x ethanol", ylabel = "Vᴱ [cm³ mol⁻¹]", title = "Excess molar volume of ethanol + water at 25 °C")
hlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
sc = scatter!(ax, xd, VE; color = yd, markersize = 8)
Colorbar(fig[1, 2], sc; label = "year of publication")
fig
```

The excess volume is negative: the mixture is *denser* than the ideal mixture. This contraction is commonly explained by water molecules fitting into the open structure of hydrogen-bonded ethanol, together with strong hydrogen bonds between unlike molecules. This is the contraction that makes 50 mL of ethanol and 50 mL of water add up to less than 100 mL.

## Variations to try

- Change the temperature window to see how both excess properties move with temperature.
- Replace the pair: `["methanol", "water"]` or `["propan-2-ol", "water"]` are well covered in the archive.
- Colour the points by article (`tv.doi`) to spot laboratories whose mixture data are systematically offset.
