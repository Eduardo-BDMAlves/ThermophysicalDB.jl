# The eight densities of the manual (kg/m³). Seven agree to a few tenths and the last one,
# 103.0, is suspicious. Every classical rule is computed by hand here, so that the numbers
# printed in the documentation are checked by the test suite.
@testmodule EightPoints begin
    const values = [99.9, 100.1, 100.2, 100.2, 100.3, 100.4, 100.5, 103.0]
end

@testitem "descriptive statistics of the eight-point example" setup = [EightPoints] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    y = EightPoints.values
    m, s = T.mean_and_sd(y)
    @test m ≈ 100.575
    @test s ≈ 0.99678 atol = 1e-5
    z = (103.0 - m) / s
    @test z ≈ 2.4328 atol = 1e-4
    # No sample of n values can have a z-score above (n - 1) / sqrt(n): a fixed cutoff of
    # 3 can never flag anything in a sample of eight.
    @test z < (length(y) - 1) / sqrt(length(y))
    @test (length(y) - 1) / sqrt(length(y)) ≈ 2.4749 atol = 1e-4
    # Tukey's fences, with the quartiles taken as the medians of the two halves.
    sorted = sort(y)
    q1 = T.median_value(sorted[1:4])
    q3 = T.median_value(sorted[5:8])
    @test (q1, q3) == (100.15, 100.45)
    iqr = q3 - q1
    @test iqr ≈ 0.30 atol = 1e-12
    @test q1 - 1.5iqr ≈ 99.70 atol = 1e-12
    @test q3 + 1.5iqr ≈ 100.90 atol = 1e-12
    @test 103.0 > q3 + 1.5iqr
    # Median, MAD and modified z-scores.
    @test T.median_value(y) ≈ 100.25
    @test T.median_abs_deviation(y) ≈ 0.15 atol = 1e-12
    M = T.modified_zscores(y)
    @test M[end] ≈ 0.6745 * 2.75 / 0.15 atol = 5e-3
    @test M[end] > 3.5
    @test sort(abs.(M))[end-1] ≈ 1.5 atol = 0.1
    # Dixon's Q for the largest value: gap over range.
    @test (103.0 - 100.5) / (103.0 - 99.9) ≈ 0.8065 atol = 1e-4
    # Chauvenet: expected number of points as far from the mean as the suspect one.
    tail = 2 * T.normal_cdf(-z)
    @test length(y) * tail < 0.5
    @test length(y) * tail ≈ 0.12 atol = 0.005
end

@testitem "modified z-scores fall back to the mean absolute deviation" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    # More than half of the values equal: the MAD is zero.
    y = [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 9.0]
    @test T.median_abs_deviation(y) == 0
    M = T.modified_zscores(y)
    @test all(M[1:6] .== 0)
    @test M[7] > 3.5
    @test all(T.modified_zscores(fill(2.0, 5)) .== 0)
    @test T.median_value(Float64[]) |> isnan
    @test isnan(T.mean_and_sd([1.0])[2])
end

@testitem "distribution helpers match published values" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.normal_quantile(0.975) ≈ 1.959963984540054
    @test T.normal_cdf(1.959963984540054) ≈ 0.975
    # Student t percentage points: t(0.975, 10) = 2.2281 and t(0.995, 5) = 4.0321.
    @test T.student_t_upper_quantile(0.025, 10) ≈ 2.2281388519649385
    @test T.student_t_upper_quantile(0.005, 5) ≈ 4.032142983557536
    @test_throws ArgumentError T.normal_quantile(1.0)
    @test_throws ArgumentError T.student_t_upper_quantile(0.7, 5)
    @test_throws ArgumentError T.student_t_upper_quantile(0.1, 0)
end

@testitem "the first Rosner critical value is the critical value of Grubbs' test" setup =
    [EightPoints] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    # Grubbs' two-sided 5 % critical value for n = 8 is 2.1266 (tables of Grubbs, 1969).
    @test T.rosner_lambda(8, 1, 0.05) ≈ 2.1266 atol = 1e-4
    y = EightPoints.values
    m, s = T.mean_and_sd(y)
    G = maximum(abs.(y .- m)) / s
    @test G > T.rosner_lambda(8, 1, 0.05)
    # Larger samples need larger critical values, smaller levels too.
    @test T.rosner_lambda(30, 1, 0.05) > T.rosner_lambda(8, 1, 0.05)
    @test T.rosner_lambda(8, 1, 0.01) > T.rosner_lambda(8, 1, 0.05)
    @test_throws ArgumentError T.rosner_lambda(8, 7, 0.05)
    @test_throws ArgumentError T.rosner_lambda(8, 1, 1.5)
end

@testitem "generalized ESD flags only the suspect point of the eight-point example" setup =
    [EightPoints] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    y = EightPoints.values
    result = T.esd(y; max_outliers = 2)
    @test result.n == 8 && result.max_outliers == 2
    @test result.count == 1
    @test T.declared(result) == [8]
    @test result.statistic[1] ≈ 2.4328 atol = 1e-4
    @test result.statistic[1] > result.critical[1]
    # After removing 103.0 the largest remaining distance is well inside the second limit.
    @test result.statistic[2] < result.critical[2]
    @test result.order[1] == 8
    # The first limit is Grubbs' (the correction for the second step raises it slightly).
    @test T.esd(y; max_outliers = 2, critical = :rosner).count == 1
    @test result.critical[1] ≥ T.rosner_lambda(8, 1, 0.05) - 0.01
    # A fraction of the sample gives the same upper limit as the equivalent count.
    @test T.esd(y; max_outliers = 0.25).max_outliers == 2
    # The default is a tenth of the sample, at least one.
    @test T.esd(y).max_outliers == 1
    @test_throws ArgumentError T.esd([1.0, 2.0])
    @test_throws ArgumentError T.esd([1.0, 2.0, NaN, 4.0])
    @test_throws ArgumentError T.esd(y; max_outliers = 0)
    @test_throws ArgumentError T.esd(y; critical = :other)
end

@testitem "generalized ESD finds two outliers that mask each other" tags = [:unit, :fast] begin
    using StableRNGs, Random
    T = ThermophysicalDB
    rng = StableRNG(1)
    y = vcat(randn(rng, 14), [4.4, 4.9])
    # With r = 1 the second outlier inflates the standard deviation and hides the first.
    @test T.esd(y; max_outliers = 1).count == 0
    found = T.esd(y; max_outliers = 4)
    @test found.count == 2
    @test sort(T.declared(found)) == [15, 16]
    # Sorting the data must not change what is found.
    p = randperm(rng, 16)
    again = T.esd(y[p]; max_outliers = 4)
    @test sort(p[T.declared(again)]) == [15, 16]
end

@testitem "ESD removal sequence agrees with a direct computation" tags = [:unit, :fast] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(5)
    z = randn(rng, 40)
    z[7] = 5.0
    z[19] = -4.0
    order, statistic = T.esd_removal_sequence(z, 5)
    left = collect(1:40)
    for i = 1:5
        mean_i = sum(z[left]) / length(left)
        sd_i = sqrt(sum((z[left] .- mean_i) .^ 2) / (length(left) - 1))
        deviations = abs.(z[left] .- mean_i)
        k = argmax(deviations)
        @test order[i] == left[k]
        @test statistic[i] ≈ deviations[k] / sd_i
        deleteat!(left, k)
    end
    @test order[1] == 7
    @test_throws ArgumentError T.esd_removal_sequence(z, 39)
end

@testitem "critical values are closed formulas: reproducible, monotone and calibrated" tags =
    [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    # Exact for the first step: Grubbs' limits, whatever the correction (it needs r > 1).
    @test T.esd_critical_values(8, 1, 0.05) ≈ [2.1266] atol = 1e-4
    @test T.esd_critical_values(8, 1, 0.05) ==
          T.esd_critical_values(8, 1, 0.05; method = :rosner)
    # Nothing is random: same call, same numbers, and no simulation state is kept.
    @test T.esd_critical_values(30, 3, 0.05) == T.esd_critical_values(30, 3, 0.05)
    # The correction raises the limits (it only ever makes the test more cautious) and fades
    # as the sample grows.
    plain = T.esd_critical_values(12, 3, 0.05; method = :rosner)
    safe = T.esd_critical_values(12, 3, 0.05)
    @test all(safe .> plain)
    far = T.esd_critical_values(5000, 3, 0.05)
    @test maximum(far .- T.esd_critical_values(5000, 3, 0.05; method = :rosner)) < 0.002
    # Smaller levels and larger samples need larger limits.
    @test all(T.esd_critical_values(30, 3, 0.01) .> T.esd_critical_values(30, 3, 0.05))
    @test all(T.esd_critical_values(300, 3, 0.05) .> T.esd_critical_values(30, 3, 0.05))
    # Declaring anything in a clean normal sample happens at most about as often as the
    # level says, also for small samples with several steps, where the plain formula does not.
    rng = StableRNG(9)
    function alarms(n, r, method)
        count(1:3000) do _
            T.esd(randn(rng, n); max_outliers = r, critical = method).count > 0
        end / 3000
    end
    @test alarms(10, 3, :auto) < 0.075
    @test alarms(10, 3, :rosner) > 0.075
    @test 0.02 < alarms(20, 2, :auto) < 0.07
    @test alarms(60, 6, :auto) < 0.06
    @test_throws ArgumentError T.esd_critical_values(10, 9, 0.05)
    @test_throws ArgumentError T.esd_critical_values(10, 2, 0.05; method = :montecarlo)
end

@testitem "the confidence of a flag separates real outliers from the tail of the bulk" tags =
    [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(12)
    z = randn(rng, 2000)
    z[1:5] .= [9.0, -11.0, 8.5, 12.0, -10.0]
    c = T.flag_certainty(z)
    @test all(>(0.99), c[1:5])
    # The ordinary values of a clean pool are never confident outliers.
    @test count(>(0.9), c[6:end]) ≤ 2
    @test count(>(0.5), c[6:end]) < 10
    # A pool that is wider than assumed lowers the confidence of the same extreme values.
    wide = 3 .* randn(rng, 2000)
    wide[1] = 9.0
    @test T.flag_certainty(wide)[1] < 0.9
    # Always a probability.
    @test all(0 .<= c .<= 1)
end
