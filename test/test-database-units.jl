@testitem "the tolerances of the duplicates are converted when the rules are made" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    r = T.DuplicateRules(; temperature = "0.1 degC", pressure = "0.01 bar", value = "0.1 %")
    @test r.temperature == 0.1 && r.pressure == 1.0 && r.value == 1.0e-3
    # A tolerance of temperature is a difference: only the scale is converted.
    @test T.DuplicateRules(; temperature = "0.1 degF").temperature ≈ 0.1 * 5 / 9
    @test T.DuplicateRules(; temperature = "50 mK").temperature == 0.05
    @test T.DuplicateRules(; pressure = "1 mbar").pressure == 0.1
    @test T.DuplicateRules(; pressure = "1 psi").pressure ≈ 6.894757293168361
    @test T.DuplicateRules(; value = "100 ppm", composition = "1 %").value ≈ 1.0e-4
    @test T.DuplicateRules(; composition = "1 %").composition == 1.0e-2
    # Plain numbers stay as they are (K, kPa, fractions).
    @test T.DuplicateRules(; temperature = 2, pressure = 3, value = 0.5).temperature === 2.0
    @test T.DuplicateRules() ==
          T.DuplicateRules(; temperature = "0.1 K", pressure = "1 kPa")
    @test_throws ArgumentError T.DuplicateRules(; temperature = "1 bar")
    @test_throws ArgumentError T.DuplicateRules(; temperature = "1 foo")
    @test_throws ArgumentError T.DuplicateRules(; pressure = "1 psig")
    @test_throws ArgumentError T.DuplicateRules(; value = "1 K")
    @test_throws ArgumentError T.DuplicateRules(; value = "-1 %")
    err = try
        T.DuplicateRules(; temperature = "1 bar")
        nothing
    catch e
        e
    end
    @test occursin("temperature tolerance", err.msg)
end

@testitem "the tolerances accept the quantities of a units package" tags = [:unit, :fast] begin
    using Unitful
    T = ThermophysicalDB
    r = T.DuplicateRules(; temperature = 0.1u"°C", pressure = 0.01u"bar")
    @test r.temperature ≈ 0.1 && r.pressure ≈ 1.0
    @test T.DuplicateRules(; temperature = 1u"mK").temperature ≈ 1.0e-3
    @test_throws ArgumentError T.DuplicateRules(; temperature = 1u"bar")
end

@testitem "numbers with units are stored in the unit of the database" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(
            db;
            doi = "10.5555/Units-1",
            authors = "Silva, A.",
            year = 2024,
        )
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        ds = T.member_dataset(db, "my_lab")
        add(; kw...) = T.add_measurement!(exp; property = "Mass density", kw...)
        # The archive has "Mass density, kg/m3": that is the unit of the point, whatever way it comes.
        add(; unit = "g/cm3", value = 0.9982, temperature = "20 degC", pressure = "1 atm")
        add(; value = "0.9970 g/cm3", temperature = "25 degC", pressure = "0.1 MPa")
        add(; unit = "kg/m3", value = 995.0, temperature = 303.15, pressure = 101.325)
        add(; value = "62.4 lb/ft3", temperature = "86 degF")
        m = ds.measurements
        @test m.value[1] ≈ 998.2 && m.value[2] ≈ 997.0 && m.value[3] == 995.0
        @test m.value[4] ≈ 62.4 * 16.01846337396014
        @test m.temperature[1] ≈ 293.15 &&
              m.temperature[2] ≈ 298.15 &&
              m.temperature[4] ≈ 303.15
        @test m.pressure[1] ≈ 101.325 && m.pressure[2] ≈ 100.0 && isnan(m.pressure[4])
        @test length(ds.properties) == 1
        @test ds.properties.unit[1] == "kg/m3"
        # An uncertainty is converted as a difference, with the same unit as the value.
        add(; unit = "g/cm3", value = 0.99, unc = 0.0005, temperature = 300.0)
        add(; value = "0.99 g/cm3", unc = "0.5 kg/m3", temperature = 301.0)
        add(; value = "1000 kg/m3", unc = "0.1 %", temperature = 302.0)
        @test m.unc[5] ≈ 0.5 && m.unc[6] ≈ 0.5 && m.unc[7] ≈ 1.0
        # A unit of another quantity, or one that cannot be read, is refused and nothing is added.
        n = length(m)
        @test_throws ArgumentError add(;
            unit = "bar",
            value = "1 kg/m3",
            temperature = 300.0,
        )
        @test_throws ArgumentError add(; value = "1 bar", temperature = 300.0)
        @test_throws ArgumentError add(; value = "1 foo", temperature = 300.0)
        @test_throws ArgumentError add(; value = 1.0, temperature = "300 bar")
        @test_throws ArgumentError add(; value = 1.0, pressure = "1 psig")
        @test_throws ArgumentError add(; value = 1.0, temperature = "-1 K")
        @test length(m) == n
        # Without a unit nothing is converted, as before.
        add(; value = 1.5, temperature = 310.0)
        @test m.value[end] == 1.5 && length(ds.properties) == 2
        @test ds.properties.unit[2] == ""
    end
end

@testitem "a property that no database has is stored in the SI" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(
            db;
            doi = "10.5555/Units-2",
            authors = "Silva, A.",
            year = 2024,
        )
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        ds = T.member_dataset(db, "my_lab")
        add(prop; kw...) =
            T.add_measurement!(exp; property = prop, temperature = 300.0, kw...)
        add("Dynamic thing"; unit = "cP", value = 0.89)
        add("Dynamic thing"; unit = "mPa*s", value = 1.0)
        add("Dynamic thing"; value = "2 Pa s")
        add("Bulk thing"; unit = "g/cm3", value = 1.0)
        add("Pressure thing"; unit = "bar", value = 2.0)
        add("Energy thing"; unit = "kJ/mol", value = 3.0)
        add("Speed thing"; unit = "km/h", value = 36.0)
        add("Heat thing"; unit = "cal/g/K", value = 1.0)
        p = ds.properties
        unit_of(label) = p.unit[findfirst(==(label), p.label)]
        @test unit_of("Dynamic thing") == "Pa*s"
        @test count(==("Dynamic thing"), p.label) == 1
        @test ds.measurements.value[1:3] ≈ [8.9e-4, 1.0e-3, 2.0]
        @test unit_of("Bulk thing") == "kg/m3" && ds.measurements.value[4] ≈ 1000.0
        @test unit_of("Pressure thing") == "Pa" && ds.measurements.value[5] ≈ 2.0e5
        @test unit_of("Energy thing") == "J/mol" && ds.measurements.value[6] ≈ 3000.0
        @test unit_of("Speed thing") == "m/s" && ds.measurements.value[7] ≈ 10.0
        @test unit_of("Heat thing") == "J/K/kg" && ds.measurements.value[8] ≈ 4184.0
        # A value that is already in the SI keeps the way it was written.
        add("Plain thing"; unit = "m/s", value = 1.0)
        @test unit_of("Plain thing") == "m/s"
        add("Odd thing"; unit = "mol/s", value = 1.0)
        @test unit_of("Odd thing") == "mol/s"
        add("Odd thing 2"; unit = "mmol/s/m2/K", value = 1.0)
        @test unit_of("Odd thing 2") == "mol/m^2/s/K"
    end
end

@testitem "the data of an article are converted, and one mistake leaves the database as it was" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = (doi = "10.5555/Units-3", authors = ["Silva, A."], year = 2024)
        exp(; kw...) = (;
            components = [OwnData.WATER],
            property = "Mass density",
            temperature = ["20 degC", "25 degC", 303.15],
            pressure = "1 bar",
            unit = "g/cm3",
            value = [0.9982, "0.9970 g/cm3", 0.9956],
            kw...,
        )
        ds = T.member_dataset(db, "my_lab")
        # The third point of the second experiment is wrong: nothing at all is added.
        @test_throws ArgumentError T.add_reference_data!(
            db;
            reference = ref,
            experiments = [exp(), exp(; pressure = [1.0, 1.0, "1 K"])],
            warn_duplicates = false,
        )
        @test length(ds.measurements) == 0 && length(ds.references) == 0
        out = T.add_reference_data!(
            db;
            reference = ref,
            experiments = [exp(), exp(; unit = "kg/m3", value = [998.2, 997.0, 995.6])],
            warn_duplicates = false,
        )
        @test out.points == 6
        m = ds.measurements
        @test m.value[1:3] ≈ [998.2, 997.0, 995.6] && m.value[4:6] ≈ [998.2, 997.0, 995.6]
        @test m.temperature[1:3] ≈ [293.15, 298.15, 303.15]
        @test all(≈(100.0), m.pressure)
        @test length(ds.properties) == 1 && ds.properties.unit[1] == "kg/m3"
    end
end

@testitem "the points accept the quantities of a units package" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    using Unitful
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(
            db;
            doi = "10.5555/Units-4",
            authors = "Silva, A.",
            year = 2024,
        )
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        ds = T.member_dataset(db, "my_lab")
        T.add_measurement!(
            exp;
            property = "Mass density",
            value = 0.9982u"g/cm^3",
            unc = 0.0005u"g/cm^3",
            temperature = 20u"°C",
            pressure = 1u"atm",
        )
        m = ds.measurements
        @test m.value[1] ≈ 998.2 && m.unc[1] ≈ 0.5
        @test m.temperature[1] ≈ 293.15 && m.pressure[1] ≈ 101.325
        @test ds.properties.unit[1] == "kg/m3"
        @test_throws ArgumentError T.add_measurement!(
            exp;
            property = "Mass density",
            value = 1.0u"bar",
            temperature = 300.0,
        )
    end
end
