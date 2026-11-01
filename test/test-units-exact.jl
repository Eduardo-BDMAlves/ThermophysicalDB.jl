@testitem "exact definitions of the customary units" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    # Legal definitions, as rationals.
    @test T.INCH.scale == 254 // 10000
    @test T.POUND_MASS.scale == 45359237 // 10^8
    @test T.STANDARD_GRAVITY.scale == 980665 // 10^5
    @test T.ATMOSPHERE.scale == 101325
    @test T.TORR.scale == 101325 // 760
    @test T.BAR.scale == 10^5
    # psi = lbf / inch^2, derived and not typed in.
    @test T.PSI.scale == 8896443230521 // 1290320000
    # Conventional mmHg = 13595.1 kg/m^3 * gn * 1 mm.
    @test T.MMHG.scale == 26664477483 // 200000000
    @test T.PSI.dim == T.PASCAL.dim == T.MMHG.dim == T.TORR.dim
    # Rankine and the temperature scales.
    @test T.TEMPERATURE_UNITS["°R"] == T.ExactAffine(5 // 9, 0 // 1)
    @test T.TEMPERATURE_UNITS["°F"] == T.ExactAffine(5 // 9, 45967 // 180)
    @test T.TEMPERATURE_UNITS["°C"] == T.ExactAffine(1 // 1, 27315 // 100)
end

@testitem "the unit text parser" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    p = T.parse_exact_unit
    @test p("kPa*dm3/mol").scale == 1
    @test p("kPa*dm3/mol").dim == T.parse_exact_unit("Pa*m^3/mol").dim
    @test p("W/m/K").dim == (T.WATT / T.METRE / T.KELVIN_UNIT).dim
    @test p("1/kPa").scale == 1 // 1000
    @test p("K^-1").dim == p("1/K").dim
    @test p("mol/dm3").scale == 1000
    @test p("S*m2/mol").dim == T.parse_exact_unit("S*m^2/mol").dim
    @test p("kg").scale == 1
    @test p("mbar").scale == 10^5 // 1000
    @test_throws ArgumentError p("furlong")
    @test_throws ArgumentError p("kPa*")
    # Same dimension is enforced when a catalog entry is built.
    @test_throws ArgumentError T.UnitSpec("kPa", "kPa", "kg")
    # Every catalog factor is the rounding of its exact rational.
    for spec in T.UNIT_SPECS
        @test spec.to_si == Float64(spec.exact)
    end
end

@testitem "constants are the correctly rounded exact values" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    rounded(r) = Float64(BigFloat(numerator(r); precision = 2000) / denominator(r))
    for table in (T.TEMPERATURE_UNITS, T.PRESSURE_UNITS), (_, a) in table
        f = T.FloatAffine(a)
        @test f.scale == rounded(a.scale)
        @test f.offset == rounded(a.offset)
    end
    for spec in T.UNIT_SPECS
        @test spec.to_si == rounded(spec.exact)
    end
    # The offset of the fahrenheit scale is the case the typed constants got wrong by 1 ulp.
    @test T.FloatAffine(T.TEMPERATURE_UNITS["°F"]).offset == 255.37222222222223
end

@testitem "chains of conversions are composed exactly" tags = [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    T = ThermophysicalDB
    t = T.TEMPERATURE_UNITS
    R, F, C = t["°R"], t["°F"], t["°C"]
    # degR -> degF -> degC -> K equals the direct composition, in rationals.
    via = C ∘ inv(C) ∘ F ∘ inv(F) ∘ R
    @test via == R
    degR_to_degC = inv(C) ∘ R
    @test degR_to_degC(49167 // 100) == 0          # 491.67 degR is 0 degC, exactly
    @test (inv(F) ∘ R)(49167 // 100) == 32         # and 32 degF
    @test (inv(R) ∘ F)(32) == 49167 // 100
    # Cross-check against Unitful, which is exact for these units with rational quantities.
    @test Unitful.ustrip(Unitful.uconvert(u"K", (0 // 1) * u"°F")) == F(0 // 1)
    @test Unitful.ustrip(Unitful.uconvert(u"K", (0 // 1) * u"°C")) == C(0 // 1)
    @test Unitful.ustrip(Unitful.uconvert(u"K", (1 // 1) * u"Ra")) == R(1 // 1)
    p = T.PRESSURE_UNITS
    @test Unitful.ustrip(Unitful.uconvert(u"Pa", (1 // 1) * u"atm")) ==
          1000 * p["atm"].scale
    @test Unitful.ustrip(Unitful.uconvert(u"Pa", (1 // 1) * u"Torr")) ==
          1000 * p["torr"].scale
    # A difference does not take the offset: 0.01 degC is 0.01 K, 1.8 degF is 1 K.
    @test T.difference(C)(1 // 100) == 1 // 100
    @test T.difference(F)(18 // 10) == 1
    # Float64 constants of a chain are rounded once from the exact composition.
    direct = T.unit_affine(T.NativeTemperature(), "°R", "°C")
    @test direct == T.FloatAffine(inv(C) ∘ R)
end

@testitem "rational arithmetic never overflows in silence" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    big = T.ExactUnit(T.Exact(typemax(Int128) ÷ 3), T.NO_DIMENSION)
    @test_throws OverflowError big * big
    @test_throws OverflowError big^3
end

@testitem "column kernels agree with the scalar conversion and do not allocate" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    kind = T.NativeTemperature()
    x = collect(range(200.0, 700.0; length = 1001))
    x[7] = NaN
    for to in ("K", "°C", "°F", "°R")
        v = T.convert_native(x, kind, to)
        s = [T.convert_native(xi, kind, to) for xi in x]
        @test isequal(v, s)
        @test isnan(v[7])
    end
    # Identity and pure scale take their own branches.
    @test isequal(T.convert_native(x, kind, "K"), x)
    @test T.convert_native(x, kind, "K") !== x
    p = [101.325, 1.0e4, NaN]
    @test isequal(T.convert_native(p, T.NativePressure(), "Pa"), p .* 1000)
    # In place, also onto the source itself.
    y = copy(x)
    T.convert_unit!(y, y, kind, "K", "°C")
    @test isequal(y, T.convert_native(x, kind, "°C"))
    # Back to the native unit.
    z = T.to_native(T.convert_native(x, kind, "°F"), kind, "°F")
    @test all(isapprox.(z[[1:6; 8:end]], x[[1:6; 8:end]]; rtol = 1.0e-14))
    f = T.unit_affine(kind, "K", "°C")
    out = similar(x)
    T.apply!(out, x, f)                 # compile
    @test (@allocated T.apply!(out, x, f)) == 0
    @test_throws ArgumentError T.convert_native(x, kind, "furlong")
    @test_throws DimensionMismatch T.apply!(zeros(3), x, f)
end
