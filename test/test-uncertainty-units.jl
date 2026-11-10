@testitem "a term keeps its value type until it is stored" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.UncertaintyTerm(0.2; k = 2) isa T.UncertaintyTerm{Float64}
    @test T.UncertaintyTerm(2; k = 2).value === 2.0
    @test T.UncertaintyTerm("2 %"; k = 2) isa T.UncertaintyTerm{String}
    @test_throws ArgumentError T.UncertaintyTerm("2 %")         # the coverage is still required
    @test_throws ArgumentError T.UncertaintyTerm(-0.1; k = 1)
end

@testitem "uncertainties as texts, with units and as percentages" setup =
    [UncertaintyFixture] tags = [:unit, :fast] begin
    function combined(; row = 1, quantity, kwargs...)
        ds = build()
        return T.set_uncertainty!(ds; scope = :measurement, row, quantity, kwargs...).combined
    end
    # a property in another unit of the same quantity: 0.001 g/cm3 is 1 kg/m3
    @test combined(quantity = :property, statistical = "0.001 g/cm3") ≈ 1.0
    @test combined(quantity = :property, statistical = "0.001 g/cm^3") ≈ 1.0
    @test combined(quantity = :property, statistical = "2 kg/m3") ≈ 2.0
    @test combined(quantity = :property, statistical = "3") ≈ 3.0       # no unit: as stored
    # temperature: an uncertainty is a difference, so degC and degF have no offset
    @test combined(quantity = :temperature, device = "0.01 degC") == 0.01
    @test combined(quantity = :temperature, device = "0.01 °C") == 0.01
    @test combined(quantity = :temperature, device = "1.8 degF") == 1.0
    @test combined(quantity = :temperature, device = "10 mK") ≈ 0.01
    # pressure in other units (the database keeps kPa)
    @test combined(quantity = :pressure, statistical = "5 mbar") ≈ 0.5
    @test combined(quantity = :pressure, statistical = "1 psi") ≈ 6.894757293168361
    @test combined(quantity = :pressure, statistical = "1 bar") ≈ 100.0
    # a percentage is a fraction of the stored value of the same quantity at that point
    @test combined(quantity = :property, statistical = "0.01 %") ≈ 998.2 * 1.0e-4
    @test combined(quantity = :property, statistical = "100 ppm") ≈ 998.2 * 1.0e-4
    @test combined(row = 2, quantity = :temperature, device = "0.01 %") ≈ 298.15 * 1.0e-4
    @test combined(quantity = :pressure, device = "1 %") ≈ 1.01325
    # the coverage applies after the conversion: 2 % with k = 2 is 1 % as standard uncertainty
    @test combined(quantity = :property, statistical = T.UncertaintyTerm("2 %"; k = 2)) ≈
          998.2 * 0.01
    # the result is stored in the database unit, with the coverage that was given
    ds = build()
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :property,
        expanded = T.UncertaintyTerm("0.5 g/cm3"; k = 2),
    )
    t = T.uncertainty_table(ds)
    i = findfirst(==("expanded"), t.kind)
    @test t.value[i] == 500.0 && t.k[i] == 2.0
    @test ds.measurements.unc[1] == 500.0
    # a term can mix with plain numbers
    @test combined(quantity = :temperature, statistical = 0.02, device = "0.01 K") ≈
          sqrt(0.02^2 + 0.01^2)
end

@testitem "what cannot be converted is refused" setup = [UncertaintyFixture] tags =
    [:unit, :fast] begin
    ds = build()
    set(; scope = :measurement, row = 1, quantity, kwargs...) =
        T.set_uncertainty!(ds; scope, row, quantity, kwargs...)
    @test_throws ArgumentError set(quantity = :temperature, device = "5 kPa")    # dimension
    @test_throws ArgumentError set(quantity = :pressure, device = "5 K")
    @test_throws ArgumentError set(quantity = :property, statistical = "1 kPa")
    @test_throws ArgumentError set(quantity = :property, statistical = "1 furlong")
    @test_throws ArgumentError set(quantity = :property, statistical = "abc")
    @test_throws ArgumentError set(quantity = :property, statistical = "-1 kg/m3")
    # the composition has no unit that can be given, a percentage is fine
    @test_throws ArgumentError set(quantity = :composition1, statistical = "1 mol/mol")
    # at an experiment: no percentage and no quantity of the property
    experiment(; quantity, kwargs...) =
        T.set_uncertainty!(ds; scope = :experiment, row = 1, quantity, kwargs...)
    @test_throws ArgumentError experiment(quantity = :temperature, device = "1 %")
    @test_throws ArgumentError experiment(quantity = :property, device = "1 kg/m3")
    # but the thermometer of an experiment can be given with a unit
    experiment(quantity = :temperature, device = "0.01 degC")
    r = set(row = 2, quantity = :temperature, statistical = "0 K")
    @test r.combined ≈ 0.01
    # nothing was stored by the refused calls
    @test T.validate(ds)
end

@testitem "quantities of the units packages as uncertainties" setup = [UncertaintyFixture] tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU
    function combined(; quantity, kwargs...)
        ds = build()
        return T.set_uncertainty!(ds; scope = :measurement, row = 1, quantity, kwargs...).combined
    end
    # Unitful: parsed here, exactly
    @test combined(quantity = :temperature, device = 0.01u"°C") == 0.01
    @test combined(quantity = :temperature, device = 10.0u"mK") ≈ 0.01
    @test combined(quantity = :pressure, statistical = 5.0u"mbar") ≈ 0.5
    @test combined(quantity = :pressure, statistical = 1.0u"psi") == 6.894757293168361
    @test combined(quantity = :property, statistical = 0.001u"g/cm^3") ≈ 1.0
    @test combined(quantity = :property, statistical = 0.01u"percent") ≈ 998.2 * 1.0e-4
    @test combined(quantity = :temperature, device = 0.01u"percent") ≈ 293.15 * 1.0e-4
    # a unit that Unitful alone knows (dyn/cm^2 = 1e-4 kPa) is converted by Unitful
    @test combined(quantity = :pressure, statistical = 1.0u"dyn/cm^2") ≈ 1.0e-4 rtol =
        1.0e-12
    @test combined(
        quantity = :property,
        statistical = T.UncertaintyTerm(0.5u"g/cm^3"; k = 2),
    ) ≈ 250.0
    @test_throws ArgumentError combined(quantity = :temperature, device = 1.0u"m")
    @test_throws ArgumentError combined(quantity = :composition1, statistical = 1.0u"kg")
    # DynamicQuantities and FlexUnits convert by themselves
    @test combined(quantity = :temperature, device = 0.01 * DQ.uparse("K")) ≈ 0.01
    @test combined(quantity = :pressure, statistical = 1.0 * DQ.uparse("bar")) ≈ 100.0
    @test combined(quantity = :property, statistical = 0.001 * DQ.uparse("g/cm^3")) ≈ 1.0
    reg = FU.UnitRegistry
    @test combined(quantity = :temperature, device = 0.01 * reg.uparse("K")) ≈ 0.01
    @test combined(quantity = :pressure, statistical = 1.0 * reg.uparse("bar")) ≈ 100.0
    @test_throws ArgumentError combined(
        quantity = :pressure,
        statistical = 1.0 * DQ.uparse("K"),
    )
end
