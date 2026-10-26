```@meta
CurrentModule = ThermophysicalDB
```

# [Detecting outliers](@id detecting_outliers)

[`find_outliers`](@ref) looks for measurements that are probably wrong. It works like [`points`](@ref): you hand it a selection, and it hands back selections, here three of them.

```julia
using ThermophysicalDB

db = database()
v = points(db; component = "water", exact = true, property = "Mass density")

kept, outliers, disputed = find_outliers(v)      # three DataViews
result = find_outliers(v)                        # or keep the whole result
reasons(result)                                  # why each point was excluded
diagnostics(result)                              # the numbers behind the trend tests
```

| View | Contains |
|---|---|
| `kept` | points with no sign of being wrong |
| `outliers` | points declared outliers, each with the reason |
| `disputed` | points that one analysis questions and the others do not support: neither confirmed nor cleared |

The three views partition the input and keep its order, so they can be passed to [`table`](@ref), [`export_points`](@ref) or any other function that takes a selection.

!!! warning "A point that is not flagged is not validated"
    The tests compare a point with its neighbors. A point with too few neighbors is **not tested**, and the result says how many these are (`result.counts.untested`). A flag is a reason to look at a point, not a verdict: the physics can change regime where the data are (see [Limitations](@ref outliers_limitations)), and the data of one publication are not independent of each other.

## What is checked, in order

1. **Physical rules.** Conditions that no real measurement can break. A point that fails is an outlier and takes no part in the next analyses.
2. **Trend along one axis.** Points of the same system, property and phase that share the other conditions are put in order along ``T``, ``P`` or composition. A window of neighboring points is fitted with a robust parabola, and each point is compared with the curve fitted *without it*.
3. **Joint surface.** When two or more axes vary (for instance ``T`` and ``P``), a quadratic surface with cross terms is fitted to the nearest points in all axes at once. It finds points that are consistent along each axis and inconsistent together, and, in a mixture, points that fit the mixture's own surface but not the neighboring compositions.

The distances of the points to their curves are then pooled and tested with the generalized ESD test, which finds several outliers at once.

## Stage 0: the physical rules

Only rules that follow from thermodynamic stability or from the definition of the quantity are used, so a point rejected here is wrong rather than merely unusual. Nothing is rejected for being large or small unless a ceiling is known: the ceilings are yours to give with `known_limits`.

```julia
find_outliers(v; known_limits = Dict("Mass density" => (0, 2500)))   # either side may be nothing
```

Properties are recognized by their ThermoML name (any case, unit ignored). The rules are:

| # | Rule | Properties | Why |
|---|---|---|---|
| 1 | ``T > 0`` | every point | The thermodynamic temperature is positive. |
| 2 | ``P \geq 0`` | every point | The tabulated pressure is absolute. |
| 3 | ``0 \leq x \leq 1`` and ``\sum x \leq 1`` | mole, mass and volume fractions, as a property or as the composition of a system | A fraction is a part of a whole. The sum tolerates `1e-6` for rounding. |
| 4 | strictly positive | mass density, amount density, specific volume, molar volume | A fluid has mass and occupies a volume. |
| 5 | strictly positive | molar, specific and per-volume heat capacity at constant ``P`` and at constant ``V`` | **Thermal stability.** The entropy is concave in the energy, so ``C_V = T(\partial S/\partial T)_V > 0``. Heat added must raise the temperature. |
| 6 | strictly positive | isothermal and adiabatic compressibility | **Mechanical stability.** The free energy is convex in the volume, so ``\kappa_T = -(1/V)(\partial V/\partial P)_T > 0``. Otherwise, compressing the fluid would lower the pressure and it would collapse. |
| 7 | strictly positive | speed of sound | ``c^2 = 1/(\rho \kappa_S)``|
| 8 | strictly positive | compressibility factor, critical compressibility factor | ``Z = P v / RT`` with ``P, v, T > 0``. |
| 9 | strictly positive | dynamic and kinematic viscosity, thermal conductivity, thermal diffusivity, self and binary diffusion coefficients | **Second law.** Friction, heat conduction and diffusion produce entropy, which cannot be negative. |
| 10 | strictly positive | surface tension, interfacial tension | With a negative value the interface would grow spontaneously until the phases dispersed. |
| 11 | strictly positive | vapor or sublimation pressure | A vapor in equilibrium has a positive pressure. |
| 12 | strictly positive | critical, triple, normal boiling, normal melting and eutectic temperatures; boiling temperature at a pressure; critical and triple-point pressures; critical density, molar volume and specific volume | Absolute temperatures, pressures and densities of a state of matter. |
| 13 | strictly positive | activity coefficients, fugacity, fugacity coefficient, Henry's law constants (three scales), equilibrium constants (four scales) | ``\gamma = a/x``, ``\varphi = f/(Py)`` and ``K = e^{-\Delta G^\circ/RT}`` are ratios or exponential of positive quantities. |
| 14 | ``\geq 0`` | electrical conductivity, molar conductivity | Zero for an insulator; negative would mean that a field drives charge against itself. |
| 15 | ``\geq 0`` | ionic strength (two bases), molality | Sums of squares of charges, and an amount per mass. |
| 16 | ``\geq 0`` | molar enthalpy and entropy of vaporization or sublimation | ``\Delta H = T \Delta V\, dP/dT``, with ``\Delta V > 0`` and ``dP/dT > 0``. Positive below the critical point, zero at it. |
| 17 | ``\geq 0`` | molar entropy | **Second law** Increase of Entropy is a requisite in increase of temperature. |
| 18 | ``C_p/C_V \geq 1`` | heat capacity ratio | ``C_p - C_V = T V \alpha^2/\kappa_T \geq 0``. |
| 19 | ``\geq 1`` | relative permittivity at zero frequency; refractive index (both entries) | The vacuum values: a material cannot polarize less than vacuum, and light travels slower in it. |
| 20 | user ceilings and floors | any property | `known_limits`. |

Values that are `NaN` or infinite are also rejected.

Properties for which no rule is applied, on purpose: heat capacity at saturation pressure (it can be negative close to the critical point), excess, partial and apparent properties, osmotic coefficient, enthalpies and entropies of reaction, solution, dilution, mixing and transition, heat capacity change at transition, thermal pressure coefficient, relative permittivity at other frequencies, and the molar enthalpy (it depends on the reference state). They can legitimately be negative or zero.

### Signs of derivatives

Some laws constrain not the value but the *slope*. They are not used to reject points, because the slope comes from a fit; they are reported in the `sign_test` column of [`diagnostics`](@ref) as `:consistent`, `:violation` or `:inconclusive` (the interval of `sign_sigma` standard errors includes zero):

| Along | Property | Expected slope | Why |
|---|---|---|---|
| ``P`` | mass density, amount density | ``\partial\rho/\partial P = \rho\kappa_T > 0`` | mechanical stability |
| ``P`` | specific volume, molar volume | ``\partial v/\partial P < 0`` | the same |
| ``T`` | vapor or sublimation pressure | ``dP/dT = \Delta H/(T\Delta V) > 0`` | Clausius–Clapeyron |
| ``T`` | molar enthalpy | ``(\partial H/\partial T)_P = C_p > 0`` | thermal stability |
| ``T`` | molar entropy | ``(\partial S/\partial T)_P = C_p/T > 0`` | thermal stability |

Nothing is imposed on ``\partial\rho/\partial T``: water is denser than ice and denser at 4 °C than at 0 °C.

### Rules between properties

Some criteria relate **two properties at the same state** and so cannot be tested on one property at a time: ``C_p > C_V``, ``\kappa_T > \kappa_S``, the identity ``c^2 = 1/(\rho\kappa_S)``, the agreement of ``dP/dT`` of the vapor pressure with ``\Delta H_\mathrm{vap}``, the Gibbs–Duhem relation and the Maxwell relations. They need an equation of state or a pairing of different properties and are planned for a later stage, not implemented here.

## Stage 1: a robust parabola in a small window

For every line of points, with the points ordered along the axis ``s`` and a window of 9 neighbors, the model is

```math
y_i = \beta_0 + \beta_1 s_i + \beta_2 s_i^2 + \varepsilon_i, \qquad \varepsilon_i \sim \mathcal{N}\!\left(0,\ (\varphi u_i)^2\right)
```

| Symbol | Meaning |
|---|---|
| ``y_i`` | measured value (or its logarithm, see below) |
| ``s_i`` | coordinate along the axis (or its inverse for ``T``, see below) |
| ``\beta_j`` | coefficients of the local parabola |
| ``u_i`` | standard uncertainty declared for the point, brought to a common basis by `policy` |
| ``\varphi`` | scale factor: how much larger the real scatter is than the declared uncertainty |
| ``\varepsilon_i`` | random error |

**Why a parabola.** A property is a smooth function of ``T`` and ``P``; over a few points a straight line misses the curvature and a higher degree follows the noise. The parabola also gives the first and second derivatives, which are reported as diagnostics.

**Why robust.** An ordinary fit is pulled towards the outlier it should reveal. The consensus of a window is found by exhaustive least quantile of squares ([Rousseeuw1984](@cite), [RousseeuwLeroy1987](@cite)): the parabola through *every* triple of points is tried and the one for which 60 % of the window fits best (`consensus_fraction`) wins. It is the same idea as RANSAC ([Fischler1981](@cite)) but tries all the triples instead of random ones, so it is deterministic and, with 9 points, cheap. The consensus is then refitted by weighted least squares, ``W = \mathrm{diag}(1/u_i^2)``, and points are added or removed until the set is stable.

**The statistic.** The distance of point ``i`` to the curve fitted without it, in units of the expected scatter, is its standardized deleted residual

```math
z_i = \frac{e_i}{\varphi\, u_i \sqrt{1 - h_i}} \quad (\text{point in the consensus}), \qquad
z_i = \frac{e_i}{\varphi \sqrt{u_i^2 + \mathbf{x}_i^{\mathsf{T}} A^{-1} \mathbf{x}_i}} \quad (\text{point outside it}),
```

with ``e_i = y_i - \mathbf{x}_i^{\mathsf{T}}\hat\beta``, ``\mathbf{x}_i = (1, s_i, s_i^2)``, ``A = X^{\mathsf{T}} W X`` and leverage ``h_i = \mathbf{x}_i^{\mathsf{T}} A^{-1} \mathbf{x}_i / u_i^2`` ([Cook1977](@cite), [Belsley1980](@cite)). A point with high leverage pulls the curve towards itself, which is why its residual is divided by ``\sqrt{1-h_i}``, and a point left out of the fit pays the uncertainty of the extrapolation.

**Uncertainties decide the tolerance.** A point with a small ``u_i`` is held to a tighter curve than one with a large ``u_i``, which is how accurate data weigh more. When a window has no declared uncertainty, the median of the known ones is used; when none is known, ``u = 1`` and ``\varphi`` is estimated from the scatter alone. When uncertainties are known, ``\varphi \geq 1``: data are never assumed better than their authors said.

**Sources are compared with each other.** Points of different articles and methods share a line if they are the same property, system and phase under the same other conditions. This is the point of the analysis: a source that disagrees with several others is the outlier.

**Which points share a line.** Points belong to the same line when the other varying axes agree within `tolerance`: 0.1 K for ``T``, 1 % of the value for ``P`` and ``10^{-3}`` for compositions. Lines shorter than `min_points = 7`, or windows with fewer than 4 distinct values, are not tested.

**Coordinates.** The fit is made in the coordinates in which the property is smooth (`transform = :auto`):

| Property | Response | ``T`` | ``P`` |
|---|---|---|---|
| Viscosity, vapor or sublimation pressure, diffusion coefficients and diffusivity, Henry's constants (when all values are positive) | ``\ln y`` | ``1/T`` | ``P`` |
| the same, kinematic viscosity or diffusivity of a gas | ``\ln y`` | ``1/T`` | ``\ln P`` (``\nu \propto 1/P``) |
| everything else | ``y`` | ``T`` | ``P`` |

`transform = :none` or a `NamedTuple` (`response`, `T`, `P`) overrides this. The slope and curvature in `diagnostics` are converted back to the units of the property (slope) or left in the transformed units (curvature); the `transform` column says which.

## Stage 2: the joint surface

When two or more axes vary, each with at least 3 distinct values, the model is the full quadratic in the varying axes, with cross terms: with ``d`` axes, ``p = (d+1)(d+2)/2`` coefficients (6 for ``T`` and ``P``, 10 for three axes). Its window is the ``4p`` nearest points (`neighbors`) in axes scaled by their range, and the same ``z_i`` is computed. Windows whose design is nearly collinear (variance inflation factor above ``10^6``, [Belsley1980](@cite)) are discarded, because their coefficients would be rounding errors. The cross term ``\partial^2 y/\partial T\partial P`` is reported on the `:joint` rows of `diagnostics`.

This stage is the expensive one, so it is organized to spend effort only where it can change the result:

1. **Tiles.** Points that sit close together (the same cell of a grid over the scaled coordinates, at most `tile = 3` of them) share one window and one fit; each member gets its own deleted residual from it, exactly as the points of a line window do in stage 1. The neighbors come from the grid, not from a search through the whole subgroup, so the cost grows with the number of points, not with its square. `tile = 1` fits every point on its own.
2. **Screening.** Every tile is first fitted with a cheap robust procedure: least squares, discard what lies beyond `inlier_threshold` robust standard deviations (MAD of the residuals), and reweigh until the set is stable. A tile with no point beyond `screening * inlier_threshold` (0.7 × 2.5) keeps this result. The tiles with a suspicious point, and the tiles of the closest neighbors of every point beyond `inlier_threshold` (a cluster of wrong values can hide from a cheap fit), go to step 3.
3. **Least quantile of squares.** The consensus of those tiles is found with the least quantile of squares fit ([Rousseeuw1984](@cite), [RousseeuwLeroy1987](@cite)), as for the parabolas but over `20p` subsets of ``p`` points instead of all of them, refined by concentration steps (refit on the points closest to the current surface, which cannot make their fit worse). The subsets come from a small counter-based generator seeded by `seed` and the number of the tile, so the choice is **deterministic**: it does not change with the number of threads or between runs. It replaces the RANSAC with a ladder of scales that earlier versions used, which repeated a randomized search about seven times per point.

`screening = 0` runs step 3 on every tile, the slowest and most conservative setting.

For a mixture, a pure substance is the end of the composition axis, so a point of a mixture is compared with its neighbors in ``(T, P, x)``, and a wrong value of the pure fluid shows up as a surface that bends towards it.

## The ESD test on the distances

The ``z`` values of a subgroup are pooled and tested with the generalized extreme studentized deviate (ESD) test ([Rosner1983](@cite)). It looks for up to ``r`` outliers. For ``i = 1, \dots, r``,

```math
R_i = \max_j \frac{\left|x_j - \bar{x}_i\right|}{s_i}, \qquad
\lambda_i = \frac{(n-i)\, t_{p,\,n-i-1}}{\sqrt{\left(n-i-1+t_{p,\,n-i-1}^2\right)(n-i+1)}}, \qquad
p = 1 - \frac{\alpha}{2(n-i+1)},
```

where ``\bar{x}_i`` and ``s_i`` are the mean and standard deviation of the ``n-i+1`` values still in the sample, the farthest value is removed after each step, and the number of outliers is the largest ``i`` with ``R_i > \lambda_i``.

| Symbol | Meaning |
|---|---|
| ``n`` | number of values pooled |
| ``r`` | most outliers looked for (`max_outliers`; default 10 % of the values) |
| ``R_i`` | largest standardized distance among the values still in the sample at step ``i`` |
| ``\lambda_i`` | critical value of step ``i`` |
| ``t_{p,\nu}`` | quantile ``p`` of Student's ``t`` with ``\nu`` degrees of freedom |
| ``\alpha`` | probability of flagging something in a sample with no outlier (`level`) |

**Why this test.** The test of Grubbs ([Grubbs1969](@cite)) looks for one outlier, and two outliers hide each other: both inflate ``s``, so neither stands out. The ESD test removes the farthest value and repeats, and it needs only ``r`` as an upper limit, not the exact number. At ``i = 1`` it is Grubbs's test.

**Critical values.** They come from the closed formula above; nothing is simulated, so they are reproducible and cost a few evaluations of Student's ``t`` quantile. The formula is exact for ``i = 1`` and, in simulations of the whole procedure on normal samples, keeps the false-alarm probability within a few percent of ``\alpha`` from ``n \approx 50``. It treats the steps as separate tests, though, and for small samples with several steps it is anticonservative (up to twice the nominal rate: about 10 % instead of 5 % at ``n = 8`` and ``r = 3``).

By default (`critical = :auto`), the formula is therefore used at the level ``\alpha / (1 + 3(r-1)/n)``, which does nothing for ``r = 1`` and little for ``r \ll n``, and brings the simulated false-alarm rate between 0.5 and 1.25 times ``\alpha`` for the combinations tried (``n \leq 1000``, ``r \leq n/4``, ``\alpha`` from 0.05 to 0.0005). `critical = :rosner` is the plain formula. The level is shared among the tests of a subgroup (each axis and the joint surface). A point is also never flagged with ``|z| \leq`` `inlier_threshold` (2.5), however small ``\lambda_i`` is.

### The eight-point example

Eight densities, in kg/m³: 99.9, 100.1, 100.2, 100.2, 100.3, 100.4, 100.5 and 103.0. Is 103.0 an outlier?

| Method | Result | Verdict |
|---|---|---|
| Mean ``\pm`` 3 s | ``\bar x = 100.575``, ``s = 0.9968``; ``z = 2.43 < 3`` | misses it: no sample of ``n`` values can have ``z`` above ``(n-1)/\sqrt n = 2.47`` |
| Tukey's fences | quartiles 100.15 and 100.45, fences 99.70 and 100.90 | flags 103.0 |
| Median and MAD ([Leys2013](@cite)) | median 100.25, MAD 0.15; modified ``z = 0.6745 \times 2.75/0.15 = 12.4 > 3.5`` | flags 103.0 |
| Dixon's ``Q`` | ``(103.0 - 100.5)/(103.0 - 99.9) = 0.806``, against a tabulated 95 % value of about 0.53 for ``n = 8`` | flags 103.0 |
| Chauvenet | expected number of points that far: ``8 \times 0.015 = 0.12 < 0.5`` | flags 103.0 |
| ESD, ``r = 2`` | ``R_1 = 2.433 > \lambda_1 = 2.19`` (closed form 2.127); after removing it ``R_2 = 1.663 < \lambda_2 = 2.03`` | **one outlier**, 103.0 |

The statistics of the table are computed by the test suite (the tabulated Dixon value is not).

## From tests to categories

A point is classified by the first rule that applies:

1. A failed physical rule makes it an `:outlier` (`code = :physical_rule`).
2. If at least 3 points of the same publication in a window deviate, 75 % or more of them on the same side and beyond the threshold, and other publications are present, they are a **systematic offset of the source**: `:disputed` with `code = :source_offset` (`:outlier` with `source_offset = :outlier`). An offset is a property of the whole series, not of a point.
3. A point flagged by the ESD test along one axis is an `:outlier` (`code = :trend_1d`).
4. A point flagged only by the joint surface is `:disputed` (`code = :joint_surface`): it is odd in the larger space, but its line has not confirmed it.

The trend reasons carry a hint when the deviation is a power of ten (a unit slip) or 273.15 (a Celsius–kelvin slip).

## What the tables contain

[`reasons`](@ref) has one row per reason, with the point's position (`index`, `measurement`), `category`, `code`, `axis`, the ESD `statistic`, `critical` and `rank`, ``z``, the value the local fit predicts (`reference_value`) and the `deviation` from it, a `detail` in words, and the columns of [`table`](@ref) that identify the point. [`diagnostics`](@ref) has one row per point and analysis with ``z``, the window size, the number of points in agreement, ``\varphi``, the slope and curvature with their standard errors, the influence of the point on the slope (a DFBETAS-like measure), the `sign_test`, the cross term, and whether ESD flagged it. The slope and curvature are **diagnostics**, not tests: a high curvature, a large ``\varphi`` or a high influence tell you the data are hard to judge there.

## [Limitations](@id outliers_limitations)

- **The physics can change regime.** A local parabola assumes the property is smooth. It is not at the triple point (the kink between sublimation and vaporization of CO₂), in the critical region (thermal diffusivity, heat capacities, compressibility), or where a phase boundary is crossed within a line. Points on both sides of such a place can be flagged without being wrong. Look at the curvature and ``\varphi`` of the neighbors, and select one phase at a time.
- **Not flagged is not validated.** See the counts of `untested` and `single_source`: a point checked only against its own publication has been checked for noise, not for bias.
- **Correlated data.** Points of one publication are not independent of each other, which the statistics assume. That is why a systematic offset has its own category.
- **Scale of the scatter.** With honest declared uncertainties the false-alarm rate is low (in simulations of clean data with 1 point in 1000 flagged). When the real scatter is larger than the declared uncertainty, or no uncertainty is declared, the scatter is estimated from windows of 9 points; that estimate is optimistic and more clean points are flagged (about 6 % with noise three times the declared uncertainty, about 8 % without uncertainties). Prefer data with declared uncertainties for the analysis, and treat flags in noisy data as candidates.
- **Rules between properties** (``C_p > C_V``, ``\kappa_T > \kappa_S``, ...) are not applied; see above.
- **The statistics assume nothing about the model of the fluid.** There is no equation of state here: the curve is local. Using an equation of state to judge all properties at once is a later step.

## Keywords and defaults

| Keyword | Default | Meaning |
|---|---|---|
| `physical`, `trend`, `joint` | `true` | switch each analysis on or off |
| `window` | 9 | points per local parabola (at least 5) |
| `min_points` | 7 | shortest line that is analyzed |
| `neighbors` | `nothing` | points per surface window (``4p``) |
| `consensus_fraction` | 0.6 | fraction of a window that must agree with the curve |
| `inlier_threshold` | 2.5 | distance, in units of scatter, beyond which a point is not part of the curve |
| `level` | 0.05 | probability of flagging anything in a set with no outlier |
| `max_outliers` | `nothing` | count or fraction (default 10 %) of points looked for per test |
| `critical` | `:auto` | `:rosner` for the plain formula, without the small-sample correction |
| `transform` | `:auto` | coordinates of the fit |
| `tolerance` | `(T = 0.1, P = 0.01, x = 1e-3)` | differences below which two states are the same |
| `policy` | `:nominal` | basis of the declared uncertainties, as in [`table`](@ref) |
| `known_limits` | `nothing` | `Dict` from property label to `(low, high)` |
| `source_offset` | `:disputed` | or `:outlier` |
| `sign_sigma` | 2.0 | standard errors in the sign test |
| `tile` | 3 | points that share one surface fit (1: each on its own) |
| `screening` | 0.7 | fraction of `inlier_threshold` above which a tile gets the consensus fit (0: all) |
| `seed` | 1 | seed of the subsets of the consensus fit |
| `max_joint_points` | 250 000 | the surface stage is skipped for a larger subgroup |

The result does not depend on the number of threads or on how many times it is run: the consensus is exhaustive in one dimension, the subsets of the surface stage come from a deterministic generator seeded by `seed` and the number of the tile, and the critical values are closed formulas.

## References

[Rosner1983](@cite) for the ESD test, [Grubbs1969](@cite) for its first step, [Rousseeuw1984](@cite) and [RousseeuwLeroy1987](@cite) for the least quantile of squares, [Cook1977](@cite) and [Belsley1980](@cite) for leverage, influence and collinear, [Leys2013](@cite) for the median absolute deviation, [Callen1985](@cite) for the stability conditions. The full entries are in the [Bibliography](@ref bibliography).
