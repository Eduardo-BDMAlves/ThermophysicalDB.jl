@testitem "coverage_factor follows the chosen policy" tags = [:unit, :fast] begin
    cf = ThermophysicalDB.coverage_factor
    @test cf(0.95) == 2.0
    @test cf(0.95; policy = :nominal) == 2.0
    @test cf(0.95; policy = :normal) ≈ 1.959963984540054
    @test cf(0.6827) == 1.0
    @test cf(0.9973; policy = :normal) == 3.0
    @test cf(0.95004) == 2.0
    @test_throws ArgumentError cf(0.80)
    @test_throws ArgumentError cf(95)
    @test_throws ArgumentError cf(0.95; policy = :other)
end

@testitem "expanded_uncertainty_k2 rescales and keeps missing values" tags = [:unit, :fast] begin
    f = ThermophysicalDB.expanded_uncertainty_k2
    @test f(0.5, 0.95) == 0.5
    @test f(0.5, 0.95; policy = :normal) ≈ 0.5 * 2 / 1.959963984540054
    @test f(1.0, 0.6827) == 2.0
    @test f(2.0, 0.9973) ≈ 4 / 3
    @test isnan(f(NaN, 0.95))
    @test f(1, 0.95) isa Float64
end
