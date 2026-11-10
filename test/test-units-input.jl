@testitem "the names of a temperature scale are aliases of one definition" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    for scale in T.TEMPERATURE_SCALES, name in scale.names
        @test T.TEMPERATURE_UNITS[name] == scale.to_kelvin
        @test T.parse_exact_unit(name) == scale.degree
        for kind in (T.NativeTemperature(),)
            @test T.unit_affine(kind, "K", name) ==
                  T.unit_affine(kind, "K", first(scale.names))
        end
    end
    x = collect(250.0:0.37:350.0)
    for (a, b) in (
        ("°C", "degC"),
        ("°C", "℃"),
        ("°F", "degF"),
        ("°F", "℉"),
        ("°R", "Ra"),
        ("°R", "degR"),
    )
        @test T.convert_native(x, T.NativeTemperature(), a) ==
              T.convert_native(x, T.NativeTemperature(), b)
    end
end

@testitem "quantities given by the user are converted with the exact arithmetic" tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    T = ThermophysicalDB
    kt, kp = T.NativeTemperature(), T.NativePressure()
    rounded(r) = Float64(Rational{BigInt}(numerator(r), denominator(r)))
    # 77 degF and 25 degC are 298.15 K to the last bit.
    @test T.native_value(77.0u"°F", kt) == 298.15
    @test T.native_value(25.0u"°C", kt) == 298.15
    @test T.native_value((77 // 1) * u"°F", kt) == 298.15
    # A float that is not a short decimal: the exact value of the float, rounded once.
    exact25 = T.exact_value(25.1) + 27315 // 100
    @test T.native_value(25.1u"°C", kt) == Float64(Rational{BigInt}(exact25))
    @test T.native_value(1.0u"psi", kp) == Float64(T.PSI.scale / 1000)
    @test T.native_value(1.0u"atm", kp) == 101.325
    @test T.native_value(750.0u"Torr", kp) == Float64(750 * T.TORR.scale / 1000)
    # Same result as the conversion of columns, which uses the same constants.
    @test T.native_value(1.0u"bar", kp) == 100.0
    # Differences take the scale only.
    @test T.native_difference(0.01u"°C", kt) == 0.01
    @test T.native_difference(1.8u"°F", kt) == 1.0
    @test T.native_difference(5.0u"mbar", kp) == 0.5
    # A property: the unit of the property is the native one.
    spec = T.unit_spec("W/m/K")
    @test T.native_value(23.0u"mW/m/K", spec) == 0.023
    @test T.native_value(1.0u"btu/hr/ft/Ra", spec) ≈ 1.730734666 rtol = 1.0e-9
    # The dimension is checked by the package, with one kind of error.
    @test_throws ArgumentError T.native_value(1.0u"m", kt)
    @test_throws ArgumentError T.native_value(1.0u"K", kp)
    @test_throws ArgumentError T.native_value(1.0u"kPa", spec)
    # A unit whose symbol the parser does not know is converted by Unitful.
    @test T.native_value(1.0u"dyn/cm^2", kp) ≈ 1.0e-4 rtol = 1.0e-12
    @test T.native_difference(1.0u"dyn/cm^2", kp) ≈ 1.0e-4 rtol = 1.0e-12
    @test T.quantity_affine(kp, "dyn cm^-2") === nothing
    # reference_summary with unit objects: the same constants as the names.
    @test T.convert_native(300.0, kt, u"°C") == T.convert_native(300.0, kt, "°C")
    @test T.convert_native(101.325, kp, u"atm") == T.convert_native(101.325, kp, "atm")
    @test T.convert_native(100.0, kp, u"dyn/cm^2") ≈ 1.0e6 rtol = 1.0e-12
end

@testitem "a property that is a temperature converts with its offset, the uncertainty without" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    spec = T.unit_spec("K")
    a = T.quantity_affine(spec, "°C")                    # degC -> K
    @test a == T.TEMPERATURE_UNITS["°C"]
    @test T.quantity_affine(spec, "degF") == T.TEMPERATURE_UNITS["degF"]
    @test T.quantity_affine(spec, "mK") == T.ExactAffine(1 // 1000)
    @test_throws ArgumentError T.quantity_affine(spec, "kPa")
    # In a compound unit the degree has no offset.
    conductivity = T.unit_spec("W/m/K")
    @test T.quantity_affine(conductivity, "W/m/°C").offset == 0
    @test T.quantity_affine(conductivity, "W/m/°F") == T.ExactAffine(9 // 5)
    # apply_exact: one rounding of the exact value.
    @test T.apply_exact(a, 25.0) == 298.15
    @test T.apply_exact(T.difference_of(a), 0.01) == 0.01
    @test isnan(T.apply_exact(a, NaN))
    @test T.apply_exact(a, Inf) == Inf
    @test T.apply_exact(T.ExactAffine(1 // 3), 1.0e-300) ≈ 1.0e-300 / 3       # outside Exact: Float64 path
    @test T.exact_value(0.1) == 3602879701896397 // 36028797018963968
    @test T.exact_value(-2.5) == -5 // 2
    @test T.exact_value(3) == 3
end
