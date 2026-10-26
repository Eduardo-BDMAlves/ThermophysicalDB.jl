@testitem "least quantile of squares ignores the points that do not follow the parabola" tags =
    [:unit, :fast] begin
    using StableRNGs, Random
    T = ThermophysicalDB
    rng = StableRNG(1)
    t = collect(range(-1, 1; length = 9))
    y = 2 .+ 0.5t .- 0.3t .^ 2 .+ 0.01 .* randn(rng, 9)
    y[5] += 0.5
    u = fill(0.01, 9)
    mask, scale = T.lqs_parabola(t, y, u, 5, 2.5, 1.0)
    @test findall(.!mask) == [5]
    @test scale == 1.0
    # Two bad points of nine still leave a majority that agrees.
    y[2] -= 0.8
    mask2, _ = T.lqs_parabola(t, y, u, 5, 2.5, 1.0)
    @test findall(.!mask2) == [2, 5]
    # The result is deterministic and does not depend on the order of the points.
    p = randperm(rng, 9)
    mask3, _ = T.lqs_parabola(t[p], y[p], u[p], 5, 2.5, 1.0)
    @test sort(p[findall(.!mask3)]) == [2, 5]
    # Fewer than three distinct abscissae cannot define a parabola.
    @test T.lqs_parabola([0.0, 0.0, 1.0, 1.0], [1.0, 1, 2, 2], ones(4), 3, 2.5, 1.0) ===
          nothing
end

@testitem "the weighted refit gives standardized deleted residuals" tags = [:unit, :fast] begin
    using StableRNGs, LinearAlgebra
    T = ThermophysicalDB
    rng = StableRNG(2)
    t = collect(range(-1, 1; length = 11))
    X = hcat(ones(11), t, t .^ 2)
    y = 1 .+ 2t .- t .^ 2 .+ 0.02 .* randn(rng, 11)
    u = fill(0.02, 11)
    # With every point in the consensus, z is the externally studentized residual: check it
    # against an explicit leave-one-out fit.
    all_in = trues(11)
    fit = T.refit_window(X, y, u, all_in, true)
    @test fit.phi ≥ 1.0
    for i in (1, 6, 11)
        keep = setdiff(1:11, i)
        W = Diagonal(1 ./ u[keep] .^ 2)
        A = X[keep, :]' * W * X[keep, :]
        beta = A \ (X[keep, :]' * W * y[keep])
        predicted = X[i, :]' * beta
        variance = u[i]^2 + X[i, :]' * inv(A) * X[i, :]
        loo = (y[i] - predicted) / sqrt(variance)
        # Same quantity up to the scale factor and the use of the full-fit leverage.
        @test fit.z[i] * fit.phi ≈ loo rtol = 1e-6
    end
    # A point outside the consensus is judged against the fit that never saw it.
    y[4] += 0.5
    mask = trues(11)
    mask[4] = false
    out = T.refit_window(X, y, u, mask, true)
    @test abs(out.z[4]) > 10
    @test isnan(out.h[4]) && all(isfinite, out.h[mask])
    # Too few inliers for the model.
    @test T.refit_window(X, y, u, falses(11), true) === nothing
    few = falses(11)
    few[1:3] .= true
    @test T.refit_window(X, y, u, few, true) === nothing
end

@testitem "a missing uncertainty is replaced by the median of the known ones" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    u, known = T.fill_missing_uncertainty([0.1, NaN, 0.3, 0.2])
    @test known && u == [0.1, 0.2, 0.3, 0.2]
    u, known = T.fill_missing_uncertainty([NaN, NaN, 0.0])
    @test !known && u == ones(3)
    u, known = T.fill_missing_uncertainty([0.5, 0.5])
    @test known && u == [0.5, 0.5]
end

@testitem "a window whose points are almost collinear is rejected, not trusted" tags =
    [:unit, :fast] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(3)
    # Twenty points on one line in the plane, two off it by a hair: the cross and the
    # quadratic terms are determined by rounding noise only.
    n = 22
    x1 = vcat(collect(range(0, 1; length = 20)), [0.5, 0.6])
    x2 = vcat(zeros(20), [1e-9, 2e-9])
    X = zeros(n, 6)
    terms = T.quadratic_terms(2)
    for i = 1:n
        T.quadratic_row!(view(X, i, :), [x1[i], x2[i]], terms)
    end
    y = 1 .+ x1 .+ 0.01 .* randn(rng, n)
    @test T.refit_window(X, y, fill(0.01, n), trues(n), true) === nothing
    # The same number of well-spread points is fine.
    z1, z2 = rand(rng, n), rand(rng, n)
    for i = 1:n
        T.quadratic_row!(view(X, i, :), [z1[i], z2[i]], terms)
    end
    @test T.refit_window(X, 1 .+ z1 .+ z2, fill(0.01, n), trues(n), true) !== nothing
end

@testitem "coordinate transformations follow the physics of the property" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ys = [1.0, 2.0, 3.0]
    p = [100.0, 2000.0, 40000.0]
    choose(spec, label, phase = "Liquid", y = ys, pressure = p) =
        T.choose_transformation(spec, label, phase, y, pressure)
    # Density: nothing is transformed.
    @test choose(:auto, "Mass density") == T.Transformation(false, false, false)
    # Transport and vapor-pressure properties are fitted as logarithms against 1/T.
    @test choose(:auto, "Viscosity") == T.Transformation(true, true, false)
    @test choose(:auto, "Vapor or sublimation pressure") ==
          T.Transformation(true, true, false)
    @test choose(:auto, "Thermal diffusivity").log_response
    # ln P only for the gas power laws, and only in a gas.
    @test choose(:auto, "Kinematic viscosity", "Gas") == T.Transformation(true, true, true)
    @test !choose(:auto, "Kinematic viscosity", "Liquid").log_P
    @test !choose(:auto, "Viscosity", "Gas").log_P
    # A logarithm needs positive values.
    @test choose(:auto, "Viscosity", "Gas", [1.0, -2.0, 3.0]) ==
          T.Transformation(false, false, false)
    @test !choose(:auto, "Kinematic viscosity", "Gas", ys, [0.0, 10.0, 20.0]).log_P
    # Overrides.
    @test choose(:none, "Viscosity") == T.Transformation(false, false, false)
    @test choose((response = :log,), "Mass density") == T.Transformation(true, true, false)
    @test choose((P = :log,), "Mass density").log_P
    @test choose((response = :identity,), "Viscosity") ==
          T.Transformation(false, false, false)
    @test choose((T = :inverse,), "Mass density").inverse_T
    @test_throws ArgumentError choose((response = :sqrt,), "Mass density")
    @test_throws ArgumentError choose((T = :log,), "Mass density")
    @test_throws ArgumentError choose((P = :inverse,), "Mass density")
    # Chain rule factors.
    tr = T.Transformation(true, true, true)
    @test T.axis_derivative(tr, 1, 300.0) ≈ -1 / 300.0^2
    @test T.axis_derivative(tr, 2, 100.0) ≈ 0.01
    @test T.axis_derivative(tr, 3, 0.4) == 1
    @test T.forward_axis(tr, 1, 250.0) ≈ 0.004
    @test T.backward_response(tr, T.forward_response(tr, 7.5)) ≈ 7.5
    @test T.describe(tr) == "ln(y), 1/T, ln(P)"
    @test T.describe(T.Transformation(false, false, false)) == "identity"
end

@testitem "single-linkage clustering of states follows the tolerances" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    tol = T.Tolerance((;))
    # Columns: T, P, x1, x2. Three isobars (101.3, 101.0 and 5000 kPa) in temperature.
    coord = [
        300.0 101.325 NaN NaN
        310.0 101.0 NaN NaN
        320.0 101.3 NaN NaN
        300.0 5000.0 NaN NaN
        310.0 5030.0 NaN NaN
        330.0 20000.0 NaN NaN
    ]
    groups = T.cluster_states(coord, collect(1:6), [2], tol)
    @test sort([sort(g) for g in groups]) == [[1, 2, 3], [4, 5], [6]]
    # No other axis: one line.
    @test T.cluster_states(coord, collect(1:6), Int[], tol) == [collect(1:6)]
    # Chaining: each step is within tolerance, so the whole drift stays together.
    drift = [300.0 NaN NaN NaN; 300.08 NaN NaN NaN; 300.16 NaN NaN NaN; 305.0 NaN NaN NaN]
    @test sort([sort(g) for g in T.cluster_states(drift, collect(1:4), [1], tol)]) == [[1, 2, 3], [4]]
    @test T.count_distinct(tol, 1, [300.0, 300.05, 300.5]) == 2
    @test T.same_state(tol, 2, 100.0, 100.9) && !T.same_state(tol, 2, 100.0, 102.0)
    @test_throws ArgumentError T.Tolerance((T = -1.0,))
    @test_throws ArgumentError T.Tolerance((Q = 1.0,))
end

@testitem "sign rules and unit hints" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.sign_rule("Mass density") == 1 && T.sign_rule("Amount density") == 1
    @test T.sign_rule("Molar volume") == -1 && T.sign_rule("Specific volume") == -1
    @test T.sign_rule("Viscosity") == 0
    # Along temperature.
    @test T.sign_rule("Vapor or sublimation pressure, kPa", 1) == 1
    @test T.sign_rule("Molar enthalpy, kJ/mol", 1) == 1 &&
          T.sign_rule("Molar entropy", 1) == 1
    @test T.sign_rule("Mass density", 1) == 0 &&
          T.sign_rule("Vapor or sublimation pressure", 2) == 0
    @test T.sign_verdict(1, 0.5, 0.1, 2.0) == :consistent
    @test T.sign_verdict(1, -0.5, 0.1, 2.0) == :violation
    @test T.sign_verdict(1, 0.1, 0.1, 2.0) == :inconclusive
    @test T.sign_verdict(-1, -0.5, 0.1, 2.0) == :consistent
    @test T.sign_verdict(-1, 0.5, 0.1, 2.0) == :violation
    @test T.sign_verdict(0, 1.0, 0.1, 2.0) == :not_applicable
    @test T.sign_verdict(1, NaN, 0.1, 2.0) == :not_applicable
    @test occursin("10^2", T.unit_hint(100.0, 1.0))
    @test occursin("10^-3", T.unit_hint(0.001, 1.0))
    @test occursin("°C/K", T.unit_hint(573.15, 300.0))
    @test T.unit_hint(1.05, 1.0) == ""
    @test T.unit_hint(-3.0, 1.0) == ""
end
