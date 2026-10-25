```@meta
CurrentModule = ThermophysicalDB
```

# [Uncertainty](@id uncertainty)

An experimental value is only useful together with how well it is known. This page explains what the archive records, how ThermophysicalDB.jl restates it on a common basis, and how to use that basis to weight data from different laboratories.

The terms used here (standard and expanded uncertainty, coverage factor ``k``, level of confidence) follow the Guide to the expression of uncertainty in measurement [JCGM100](@cite); how ThermoML records them is described in [Chirico2003](@cite).

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

ρ = t.value
U = t.unc_k2
usable = isfinite.(U) .& (U .> zero(eltype(U)))

(points = length(ρ), with_uncertainty = count(usable))
```

The weighted mean follows from the weights, and so does its own uncertainty. For independent measurements with standard uncertainties ``u_i = U_i/2`` (since `unc_k2` is at ``k = 2``), the mean is ``\bar\rho = \sum w_i\rho_i / \sum w_i`` with ``w_i = 1/u_i^2``, and its standard uncertainty is ``u_{\bar\rho} = (\sum_i w_i)^{-1/2}``:

```@example unc
u = U[usable] ./ 2                                # standard uncertainties
w = 1 ./ u .^ 2
ρ_mean = sum(w .* ρ[usable]) / sum(w)
U_mean = 2 / sqrt(sum(w))                         # expanded, k = 2

(ρ_mean = uconvert(u"kg/m^3", ρ_mean), U_mean = uconvert(u"kg/m^3", U_mean))
```

```@example unc
d = 1e6 .* Float64.((ρ[usable] .- ρ_mean) ./ ρ_mean)       # deviation in ppm
dU = 1e6 .* Float64.(U[usable] ./ ρ_mean)                    # stated U(k = 2) in ppm
order = sortperm(d)

fig = Figure(size = (760, 520))
ax = Axis(
    fig[1, 1]; xlabel = "deviation from the weighted mean [ppm]", ylabel = "points, sorted",
    title = "Water density at 25 °C: stated uncertainty U(k = 2)",
)
vlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
errorbars!(ax, d[order], 1:length(order), dU[order]; direction = :x, color = (:gray, 0.55), whiskerwidth = 4)
scatter!(ax, d[order], 1:length(order); color = "#2fe0ff", markersize = 7)
fig
```

Since the bars are 95 % intervals, about one in twenty is expected to miss the zero line by chance. Many more than that means the stated uncertainties are optimistic.

## Parity with a reference equation

The comparison above uses the data themselves as reference. Over a range of temperatures a reference equation plays that role, and a parity plot shows every point against it. Both axes share the same limits, so the parity line is the exact diagonal, and the dashed curves mark deviations of 1 %, 5 % and 10 %. The bars are the expanded uncertainties (``k = 2``): the stated ``U`` of the experiment on ``y``, and that of the reference equation on ``x``. In the right panel each deviation is divided by the combined uncertainty ``\sqrt{U_\mathrm{exp}^2 + U_\mathrm{ref}^2}``: a point inside the band ``\pm 1`` agrees with the equation within the uncertainties of both.

```@example unc
using Clapeyron

vw = points(
    db; component = "water", exact = true, property = "Mass density",
    temperature = (0u"°C", 99u"°C"), pressure = (0.98u"atm", 1.02u"atm"),
)
tw = table(vw; unitful = true)

Tw = tw.temperature
ρw = tw.value
Uw = tw.unc_k2

model = IAPWS95()
by_temperature = Dict(Ti => mass_density(model, 1u"atm", Ti) for Ti in unique(Tw))
ρref = [by_temperature[Ti] for Ti in Tw]

relative_U_ref = 1e-5                    # expanded relative uncertainty of IAPWS-95 in the density of liquid water
Uref = relative_U_ref .* ρref

has_U = isfinite.(Uw) .& (Uw .> zero(eltype(Uw)))
Utotal = sqrt.(Uw .^ 2 .+ Uref .^ 2)
z = Float64.((ρw .- ρref) ./ Utotal)

x = ustrip.(u"kg/m^3", ρref)
y = ustrip.(u"kg/m^3", ρw)

# the same limits on both axes: the parity line is the exact diagonal
lo, hi = 0.88 * minimum(x), 1.12 * maximum(x)
line = [lo, hi]

fig = Figure(size = (1000, 520))
ax1 = Axis(
    fig[1, 1]; xlabel = "ρ IAPWS-95 [kg m⁻³]", ylabel = "ρ experimental [kg m⁻³]",
    title = "Parity plot", aspect = DataAspect(),
)
limits!(ax1, lo, hi, lo, hi)
for (δ, style) in ((0.01, :dash), (0.05, :dashdot), (0.10, :dot))
    lines!(ax1, line, (1 + δ) .* line; color = (:gray, 0.8), linestyle = style, label = "±$(round(Int, 100δ)) %")
    lines!(ax1, line, (1 - δ) .* line; color = (:gray, 0.8), linestyle = style)
end
lines!(ax1, line, line; color = "#e8ecff", linewidth = 1.5, label = "parity")
errorbars!(ax1, x, y, ustrip.(u"kg/m^3", Uref); direction = :x, color = (:gray, 0.45), whiskerwidth = 4)
errorbars!(ax1, x[has_U], y[has_U], ustrip.(u"kg/m^3", Uw[has_U]); color = (:gray, 0.45), whiskerwidth = 4)
scatter!(ax1, x, y; color = ("#2fe0ff", 0.7), markersize = 7)
axislegend(ax1; position = :lt)

ax2 = Axis(
    fig[1, 2]; xlabel = "T [°C]", ylabel = "(ρ − ρ_IAPWS-95)/U",
    title = "Deviation in units of the combined uncertainty",
)
hlines!(ax2, [-1.0, 1.0]; color = (:gray, 0.8), linestyle = :dash)
hlines!(ax2, [0.0]; color = "#e8ecff", linewidth = 1.5)
scatter!(ax2, ustrip.(u"°C", Tw[has_U]), z[has_U]; color = ("#ffb000", 0.8), markersize = 7)
fig
```

The share of points inside the band is a direct measure of how realistic the stated uncertainties are:

```@example unc
(with_uncertainty = count(has_U), inside_band = count(abs.(z[has_U]) .<= 1))
```

### Reading the two panels

The panels answer different questions, and neither contradicts the other.

- **Parity plot.** Its axes span hundreds of kg m⁻³ so that the 10 % curves fit, while the data lie in a band of about 40 kg m⁻³ and differ from the equation by tens of ppm at most. A deviation of that size is far smaller than a marker, so almost every point sits on the diagonal. The plot shows that the data are correct to well within 1 %, and nothing finer than that.
- **Normalized deviation.** Densimeters used for water usually state an uncertainty of a few ppm. Dividing a deviation of tens of ppm by such a small ``U`` gives values of 5, 20 or more, so this panel judges each point against the precision its authors claim for it.

Of the points that state an uncertainty, about nine in ten fall inside ``\pm 1``. For intervals at the 95 % level about nineteen in twenty would be expected, so the stated uncertainties are realistic as a whole and slightly optimistic. The points far outside the band are concentrated near 25 °C, where most articles measured, and have usual suspects: a typing or unit error, water that was not degassed or whose isotopic composition differs from the reference (the equation describes VSMOW), and temperatures on an older scale than ITS-90, which alone shifts the density by tens of ppm. They are worth inspecting by DOI with `points(vw; doi = "…")`.

The assumed uncertainty of the equation sets a floor to the combined ``U``. Where an experiment states less than ``10^{-5}\rho``, the width of the band is decided by `relative_U_ref` and not by the experiment.

## Choosing the policy

Pick `:nominal` (the default) when you want the conventional reading of 95 % as ``k = 2``, which is what the original authors almost certainly meant. Pick `:normal` when you want the strictly normal-theory factor ``1.96``. The effect is a uniform 2 % scale on the affected uncertainties:

```@example unc
nominal = table(v; policy = :nominal).unc_k2
normal = table(v; policy = :normal).unc_k2

extrema(filter(isfinite, normal ./ nominal))
```

The output is the smallest and the largest ratio between the two versions of `unc_k2`, point by point. Both numbers are equal to ``2/1.95996 \approx 1.0204``, and this is the expected result, not a coincidence of the two policies. A source that states an expanded uncertainty at the 95 % level has to be restated at ``k = 2``. With `:nominal` the 95 % level is taken as ``k = 2`` already, so the value is kept. With `:normal` the coverage factor is 1.95996, and the value is multiplied by ``2/1.95996``, which makes it 2 % larger. Equal minimum and maximum mean that every point with a finite uncertainty in this selection was stated at the 95 % level, so all of them change by the same factor. A selection that mixed levels would show a minimum of 1 (sources that state ``k = 2`` directly, which no policy changes) and a maximum of 1.0204.

Two conclusions follow. First, the choice is a uniform scale of 2 % on the affected points: the weights ``1/U_i^2`` of a weighted mean change by the same factor, so which points weigh more than others, and the weighted mean itself, do not change. Second, it matters only for the absolute size of the uncertainty of a derived quantity (the ``U`` of the weighted mean, or the share of points inside the band of the previous section), and the difference of 2 % is small next to the scatter between laboratories.
