@testitem "unit catalog agrees with Unitful for every entry" tags = [:unit, :fast] begin
    using Unitful: Unitful, uconvert, uparse
    specs = ThermophysicalDB.UNIT_SPECS
    @test length(specs) == 26
    @test allunique(spec.native for spec in specs)
    for spec in specs
        native = uparse(spec.unitful)
        si = uparse(spec.si)
        # Fails with a DimensionError when the SI string has the wrong dimension.
        converted = uconvert(si, 1.0 * native)
        @test Unitful.ustrip(converted) ≈ spec.to_si rtol = 1.0e-12
    end
end

@testitem "split_property_name separates label and unit" tags = [:unit, :fast] begin
    split = ThermophysicalDB.split_property_name
    label, spec = split("Mass density, kg/m3")
    @test label == "Mass density"
    @test spec.native == "kg/m3"
    label, spec = split("Molar heat capacity at constant pressure, J/K/mol")
    @test label == "Molar heat capacity at constant pressure"
    @test spec.si == "J/K/mol"
    for dimensionless in (
        "Mole fraction",
        "Refractive index (Na D-line)",
        "Azeotropic composition: mole fraction",
    )
        name, unit = split(dimensionless)
        @test name == dimensionless
        @test unit === nothing
    end
    # An unknown suffix is never guessed to be a unit.
    label, spec = split("Something odd, furlongs/fortnight")
    @test label == "Something odd, furlongs/fortnight"
    @test spec === nothing
end
