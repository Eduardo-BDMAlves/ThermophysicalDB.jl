@testitem "the unit reader accepts what the units packages print" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    p = T.parse_exact_unit
    @test p("mW m^-1 K^-1") == p("mW/m/K")
    @test p("W/(m*K)") == p("W/m/K")
    @test p("kg m^-1 s^-2") == T.PASCAL
    @test p("J/(mol K)") == p("J/mol/K")
    @test p("Pa·s") == p("Pa*s")
    @test p("(kPa)^2").scale == 10^6
    @test p("m^3").scale == 1
    @test_throws ArgumentError p("(m")
    @test_throws ArgumentError p("m)")
    @test_throws ArgumentError p("m^")
    @test_throws ArgumentError p("m^x")
    @test T.try_text_factor("W/m/K", "mW m^-1 K^-1") == 1000
    @test T.try_text_factor("W/m/K", "furlong/fortnight") === nothing
    @test_throws ArgumentError T.try_text_factor("W/m/K", "kPa")
end

@testitem "temperature and pressure in any unit, by name" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    plain = T.table(view)
    t = plain.temperature
    @test T.table(view; temperature_unit = "K").temperature == t
    @test T.table(view; temperature_unit = "°C").temperature ≈ t .- 273.15 rtol = 1.0e-13
    @test T.table(view; temperature_unit = "degF").temperature ≈
          (t .- 273.15) .* 9 ./ 5 .+ 32 rtol = 1.0e-13
    @test T.table(view; temperature_unit = "°R").temperature ≈ t .* 9 ./ 5 rtol = 1.0e-14
    @test T.table(view; temperature_unit = "mK").temperature ≈ t .* 1000 rtol = 1.0e-14
    p = plain.pressure
    @test T.table(view; pressure_unit = "bar").pressure ≈ p ./ 100 rtol = 1.0e-14
    @test T.table(view; pressure_unit = "mbar").pressure ≈ p .* 10 rtol = 1.0e-14
    @test T.table(view; pressure_unit = "Pa").pressure ≈ p .* 1000 rtol = 1.0e-14
    @test T.table(view; pressure_unit = "N/m2").pressure ≈ p .* 1000 rtol = 1.0e-14
    @test T.table(view; pressure_unit = :psi).pressure ≈ p ./ 6.894757293168361 rtol =
        1.0e-14
    # The other columns are untouched.
    both = T.table(view; temperature_unit = "°C", pressure_unit = "MPa")
    @test both.value == plain.value
    @test both.unit == plain.unit
    @test_throws ArgumentError T.table(view; temperature_unit = "kPa")
    @test_throws ArgumentError T.table(view; pressure_unit = "K")
    @test_throws ArgumentError T.table(view; temperature_unit = "furlong")
    @test_throws ArgumentError T.table(view; pressure_unit = "bar", units = :si)
end

@testitem "units of the packages: parsed here when possible, converted by the package otherwise" setup =
    [Toy] tags = [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    plain = T.table(view)
    ub = T.unit_backend(Unitful)

    # What Unitful prints is read by the exact parser, so no Unitful conversion is used.
    @test T.unit_text(ub, u"mW/m/K") == "mW K^-1 m^-1"
    @test T.try_named_unit(T.NativeTemperature(), T.unit_text(ub, u"°C")) ==
          T.TEMPERATURE_UNITS["°C"]
    tc = T.table(view; temperature_unit = u"°C")
    @test Unitful.unit(eltype(tc.temperature)) == u"°C"
    @test Unitful.ustrip.(tc.temperature) ≈ plain.temperature .- 273.15 rtol = 1.0e-13
    tf = T.table(view; temperature_unit = u"°F", pressure_unit = u"psi")
    @test Unitful.unit(eltype(tf.pressure)) == u"psi"
    @test Unitful.ustrip.(tf.pressure) ≈ plain.pressure ./ 6.894757293168361 rtol = 1.0e-14
    @test Unitful.ustrip.(T.table(view; pressure_unit = u"bar").pressure) ≈
          plain.pressure ./ 100 rtol = 1.0e-14
    # The value is the same as the text path.
    @test Unitful.ustrip.(T.table(view; unit = u"mW/m/K").value) ==
          T.table(view; unit = "mW/m/K").value

    # A symbol the exact parser does not know: Unitful converts (dyn/cm^2 = 0.1 Pa).
    dyn = T.table(view; pressure_unit = u"dyn/cm^2")
    @test Unitful.ustrip.(dyn.pressure) ≈ plain.pressure .* 1.0e4 rtol = 1.0e-12
    # erg/s/cm/K: 1 W/m/K = 1e5 erg/s/cm/K.
    erg = T.table(view; unit = u"erg/s/cm/K")
    @test T.try_text_factor("W/m/K", T.unit_text(ub, u"erg/s/cm/K")) === nothing
    @test Unitful.ustrip.(erg.value) ≈ plain.value .* 1.0e5 rtol = 1.0e-12
    @test_throws ArgumentError T.table(view; temperature_unit = u"kPa")

    # DynamicQuantities and FlexUnits give no text, so they convert (SI inside).
    dq = T.table(view; temperature_unit = DQ.uparse("K"), pressure_unit = DQ.uparse("bar"))
    @test DQ.ustrip.(dq.pressure) ≈ plain.pressure .* 1000 rtol = 1.0e-13
    @test DQ.ustrip.(dq.temperature) ≈ plain.temperature
    reg = FU.UnitRegistry
    fu = T.table(view; pressure_unit = reg.uparse("bar"))
    @test FU.ustrip.(fu.pressure) ≈ plain.pressure .* 1000 rtol = 1.0e-13
end
