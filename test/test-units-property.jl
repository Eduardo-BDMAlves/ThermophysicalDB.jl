@testitem "units written as text compose from prefixes and customary units" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    f = T.text_factor
    @test f("W/m/K", "mW/m/K") == 1000
    @test f("kPa", "mbar") == 10
    @test f("kg/m3", "g/cm3") == 1 // 1000
    @test f("Pa*s", "cP") == 1000
    @test f("m2/s", "cSt") == 10^6
    @test f("kJ/mol", "kcal/mol") == 1000 // 4184
    @test f("mol/dm3", "mmol/L") == 1000
    @test f("kPa", "psi") == 1000 * T.PSI.scale^-1
    @test f("s", "min") == 1 // 60
    @test f("s", "hr") == 1 // 3600
    @test T.BTU_IT.scale == 105505585262 // 10^8
    @test T.CALORIE_IT.scale == 41868 // 10000
    @test T.GALLON_US.scale == 231 * (254 // 10000)^3
    # Prefixes do not hide the symbols that start like one.
    @test T.parse_exact_unit("min").scale == 60
    @test T.parse_exact_unit("mmHg").scale == T.MMHG.scale
    @test T.parse_exact_unit("mm").scale == 1 // 1000
    # Thermal conductivity in the units of engineering practice.
    btu = f("W/m/K", "Btu/hr/ft/degF")
    @test btu == (3600 * (3048 // 10000) * (5 // 9)) // (105505585262 // 10^8)
    @test isapprox(Float64(btu), 0.5777893; rtol = 1.0e-7)
    inch_form = f("W/m/K", "Btu*in/hr/ft2/°F")
    @test isapprox(Float64(1 / inch_form), 0.1442279; rtol = 1.0e-6)
    # The degree is an interval inside a compound unit.
    @test f("1/K", "1/°F") == 5 // 9
    @test f("J/K/mol", "J/°R/mol") == 5 // 9
    # Wrong dimension and offsets are refused.
    @test_throws ArgumentError f("W/m/K", "BTU*hr/inch/s/°F")
    @test_throws ArgumentError f("kPa", "W")
    @test_throws ArgumentError f("K", "°C")
    @test_throws ArgumentError f("K", "degF")
    @test f("K", "°R") == 9 // 5
end

@testitem "table(; unit) converts the property columns" setup = [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    plain = T.table(view)
    milli = T.table(view; unit = "mW/m/K")
    @test milli.value == plain.value .* 1000
    @test isequal(milli.unc, plain.unc .* 1000)
    @test isequal(milli.unc_k2, plain.unc_k2 .* 1000)
    @test all(==("mW/m/K"), milli.unit)
    @test milli.temperature == plain.temperature
    @test milli.pressure == plain.pressure
    @test isequal(milli.unc_k, plain.unc_k)
    btu = T.table(view; unit = "Btu/hr/ft/degF")
    @test all(isapprox.(btu.value, plain.value .* 0.5777893; rtol = 1.0e-7))
    @test_throws ArgumentError T.table(view; unit = "kPa")
    @test_throws ArgumentError T.table(view; unit = "mW/m/K", units = :si)
    @test_throws ArgumentError T.table(T.points(ds; component = "water"); unit = "mW/m/K")
end

@testitem "table(; unit) with unit objects of each package" setup = [Toy] tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    plain = T.table(view)

    # Unitful: exact factor, quantities in the unit asked for; no keyword needed.
    uf = T.table(view; unit = u"mW/m/K")
    @test Unitful.unit(eltype(uf.value)) == u"mW/m/K"
    @test Unitful.ustrip.(uf.value) == plain.value .* 1000
    @test T.unit_factor(T.backend_of(u"W/m/K"), u"W/m/K", u"mW/m/K") === 1000 // 1
    uf2 = T.table(view; quantities = Unitful, unit = u"W/(m*K)")
    @test Unitful.ustrip.(uf2.value) == plain.value
    @test_throws ArgumentError T.table(view; unit = u"kPa")
    @test_throws ArgumentError T.table(view; unit = u"°C")

    # DynamicQuantities keeps SI inside, so the numbers are the SI values.
    dq = T.table(view; unit = DQ.uparse("mW/m/K"))
    @test DQ.ustrip.(dq.value) ≈ plain.value
    @test_throws ArgumentError T.table(view; unit = DQ.uparse("kPa"))

    # FlexUnits.
    reg = FU.UnitRegistry
    fu = T.table(view; unit = reg.uparse("mW/m/K"))
    @test FU.ustrip.(fu.value) ≈ plain.value
    @test_throws ArgumentError T.table(view; unit = reg.uparse("kPa"))

    # The package is told by the type of the object when quantities is not given.
    @test T.backend_of(DQ.uparse("m")) === T.unit_backend(DQ)
    @test_throws ArgumentError T.backend_of(3.0)

    # A text unit with a package attaches the unit it names.
    txt = T.table(view; quantities = Unitful, unit = "mW/m/K")
    @test Unitful.ustrip.(txt.value) == plain.value .* 1000
end
