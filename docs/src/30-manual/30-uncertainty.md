```@meta
CurrentModule = ThermophysicalDB
```

# [Uncertainty](@id uncertainty)

An experimental value is only useful together with how well it is known. This page explains what the archive records, how ThermophysicalDB.jl restates it on a common basis, and how to use that basis to weight data from different laboratories.

```@setup unc
Main.DocsSetup.activate!()
```

## Standard and expanded uncertainty

A *standard uncertainty* ``u`` is the estimated standard deviation of a measured value. Laboratories usually publish an *expanded uncertainty*,

```math
U = k\,u,
```

where the **coverage factor** ``k`` widens the interval so that it contains the true value with a stated probability, the **level of confidence** ``p``. Two publications can both say "uncertainty 0.5 %" and mean different things: one may report ``U`` with ``k = 2`` (about 95 %), another with ``k = 1`` (about 68 %). Comparing, or weighting, them without bringing them to one basis would be an error of a factor of two.

## What the archive stores

In the archive snapshot used by this package, every uncertainty is an *expanded combined uncertainty* ``U`` accompanied by a level of confidence for the property (stored as a percentage, almost always 95 %). A coverage factor ``k`` is not always stated. ThermophysicalDB.jl keeps exactly what was published, and adds one derived column:

| Column | Content |
| :-- | :-- |
| `unc` | the uncertainty ``U`` as published, in the unit of `value` |
| `unc_k` | the coverage factor ``k`` given by the source, or `NaN` |
| `unc_level` | the level of confidence ``p`` as a **fraction** (0.95, not 95), or `NaN` |
| `unc_k2` | ``U`` restated at ``k = 2``, or `NaN` when that cannot be done without inventing data |

Nothing is overwritten and the derived column is computed on demand, so changing the rule never leaves stale numbers on disk.

## How `unc_k2` is derived

For every point, in this order:

1. If the source gave a coverage factor, ``U_{k=2} = U \cdot 2/k``. No assumption is needed.
2. Otherwise, if it gave a level of confidence, ``k`` follows from the level through the `policy` (below), and ``U_{k=2} = U \cdot 2/k``.
3. Otherwise there is no basis to rescale, and the result is `NaN`.

A level of confidence does not determine ``k`` by itself: that requires assuming a distribution. For a normal distribution, ``k`` is the two-sided quantile ``z_p``; by the convention of the *Guide to the Expression of Uncertainty in Measurement*, 95 % is expressed with the round value ``k = 2``. The two readings differ by about 2 %, so both are available through the keyword `policy` of [`table`](@ref):

| Level ``p`` | `policy = :nominal` (default) | `policy = :normal` |
| --: | --: | --: |
| 0.6827 | 1 | 1 |
| 0.90 | 1.6449 | 1.6449 |
| 0.95 | **2** | **1.9600** |
| 0.9545 | 2 | 2 |
| 0.99 | 2.5758 | 2.5758 |
| 0.9973 | 3 | 3 |

Only these levels are accepted. For any other level the package does not guess: `unc_k2` is `NaN` for those points, and a single warning counts how many there were.

```@example unc
using ThermophysicalDB, CairoMakie, Unitful, Statistics

ThermophysicalDB.coverage_factor(0.95), ThermophysicalDB.coverage_factor(0.95; policy = :normal)
```

## Weighting data from many laboratories

Data from different sources can be combined by weighting each point with the inverse of its variance. Because `unc_k2` puts every point on the same ``k``, weights proportional to ``1/U_i^2`` are comparable between articles. As an example, take the density of pure water at 25 °C and 1 atm:

```@example unc
db = database(progress = false)
v = points(
    db; component = "water", exact = true, property = "Mass density",
    temperature = (24.95u"°C", 25.05u"°C"), pressure = (0.98u"atm", 1.02u"atm"),
)
t = table(v; unitful = true)

ρ = ustrip.(u"kg/m^3", t.value)
U = ustrip.(u"kg/m^3", t.unc_k2)
usable = isfinite.(U) .& (U .> 0)

(points = length(ρ), with_uncertainty = count(usable))
```

The weighted mean follows from the weights, and so does its own uncertainty. For independent measurements with standard uncertainties ``u_i = U_i/2`` (since `unc_k2` is at ``k = 2``), the mean is ``\bar\rho = \sum w_i\rho_i / \sum w_i`` with ``w_i = 1/u_i^2``, and its standard uncertainty is ``u_{\bar\rho} = (\sum_i w_i)^{-1/2}``:

```@example unc
u = U[usable] ./ 2                                # standard uncertainties
w = 1 ./ u .^ 2
ρ_mean = sum(w .* ρ[usable]) / sum(w)
U_mean = 2 / sqrt(sum(w))                         # expanded, k = 2

# Birge ratio: observed scatter against the scatter the stated uncertainties predict
birge = sqrt(sum(w .* (ρ[usable] .- ρ_mean) .^ 2) / (count(usable) - 1))

(ρ_mean = ρ_mean, U_mean = U_mean, birge = birge)
```

A Birge ratio near 1 says the laboratories agree within their stated uncertainties. A value well above 1 says the data scatter more than the uncertainties claim: the uncertainties are optimistic, or some points carry systematic errors. In that case the formal ``U`` of the mean is too small, and a careful analysis inflates it (for example by multiplying by the Birge ratio) or drops outliers.

```@example unc
d = 1e6 .* (ρ[usable] .- ρ_mean) ./ ρ_mean       # deviation in ppm
dU = 1e6 .* U[usable] ./ ρ_mean                    # stated U(k = 2) in ppm
order = sortperm(d)

fig = Figure(size = (760, 520))
ax = Axis(
    fig[1, 1]; xlabel = "deviation from the weighted mean [ppm]", ylabel = "points, sorted",
    title = "Water density at 25 °C: stated uncertainty U(k = 2)",
)
vlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
errorbars!(ax, d[order], 1:length(order), dU[order]; direction = :x, color = (:gray, 0.55), whiskerwidth = 4)
scatter!(ax, d[order], 1:length(order); color = "#00e5ff", markersize = 7)
fig
```

Since the bars are 95 % intervals, about one in twenty is expected to miss the zero line by chance. Many more than that means the stated uncertainties are optimistic.

## Choosing the policy

Pick `:nominal` (the default) when you want the conventional reading of 95 % as ``k = 2``, which is what the original authors almost certainly meant. Pick `:normal` when you want the strictly normal-theory factor ``1.96``. The effect is a uniform 2 % scale on the affected uncertainties:

```@example unc
nominal = table(v; policy = :nominal).unc_k2
normal = table(v; policy = :normal).unc_k2

extrema(filter(isfinite, normal ./ nominal))
```

A constant factor does not change which points weigh more than others, only the absolute size of the uncertainty of derived quantities.
