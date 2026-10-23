@testmodule Toy begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    "Eight points: 4 CO2+CH4 and 1 user CO2+CH4 conductivities, 2 water densities, 1 vapor pressure."
    function build()
        ds = T.Dataset()
        nist = T.intern!(ds.sources, "thermoml")
        mine = T.intern!(ds.sources, "user")
        mole = T.intern!(ds.kinds, "Mole fraction")
        r1 = T.add_reference!(
            ds.references;
            doi = "10.1007/s10765-005-5566-6",
            year = 2005,
            authors = ["Patek, J.", "Klomfar, J."],
            source = nist,
        )
        r2 = T.add_reference!(
            ds.references;
            doi = "10.1021/je000000x",
            year = 1990,
            authors = ["Someone, A."],
            source = nist,
        )
        r3 = T.add_reference!(ds.references; title = "bench", source = mine)
        co2 = T.add_compound!(
            ds.compounds;
            inchikey = "CURLTUGMZLYLDI-UHFFFAOYSA-N",
            names = ["carbon dioxide"],
            formula = "CO2",
        )
        ch4 = T.add_compound!(
            ds.compounds;
            inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            names = ["methane"],
            formula = "CH4",
        )
        water = T.add_compound!(ds.compounds; names = ["water"], formula = "H2O")
        lambda = T.add_property!(ds.properties, "Thermal conductivity", "W/m/K")
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        vapor = T.add_property!(ds.properties, "Vapor or sublimation pressure", "kPa")
        e1 = T.add_experiment!(
            ds.experiments;
            reference = r1,
            components = [co2, ch4],
            kinds = [mole, mole],
        )
        e2 = T.add_experiment!(
            ds.experiments;
            reference = r2,
            components = [water],
            kinds = [mole],
        )
        e3 = T.add_experiment!(
            ds.experiments;
            reference = r3,
            components = [co2, ch4],
            kinds = [mole, mole],
        )
        for (temp, press) in
            ((300.0, 1000.0), (325.0, 4000.0), (350.0, 8000.0), (425.0, 12000.0))
            T.add_measurement!(
                ds.measurements;
                experiment = e1,
                property = lambda,
                value = 0.02 + temp / 1.0e5,
                unc = 0.0004,
                unc_level = 0.95,
                temperature = temp,
                pressure = press,
                composition = (0.5, 0.5, NaN),
            )
        end
        for temp in (293.15, 303.15)
            T.add_measurement!(
                ds.measurements;
                experiment = e2,
                property = density,
                value = 998.0,
                unc = 0.1,
                unc_level = 0.95,
                temperature = temp,
                pressure = 101.325,
                composition = (1.0, NaN, NaN),
            )
        end
        T.add_measurement!(
            ds.measurements;
            experiment = e2,
            property = vapor,
            value = 2.339,
            temperature = 293.15,
            composition = (1.0, NaN, NaN),
        )
        T.add_measurement!(
            ds.measurements;
            experiment = e3,
            property = lambda,
            value = 0.0200,
            unc = 0.0002,
            unc_k = 2.0,
            temperature = 325.0,
            pressure = 4000.0,
            composition = (0.5, 0.5, NaN),
        )
        return ds
    end
end

@testitem "points selects by component with any/all/exact semantics" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    @test length(T.points(ds)) == 8
    @test length(T.points(ds; component = "methane")) == 5
    @test length(T.points(ds; component = "Water")) == 3
    # Formula and InChIKey (any case) resolve to the same compound as the name.
    @test length(T.points(ds; component = "CO2")) == 5
    @test length(T.points(ds; component = "curltugmzlyldi-uhfffaoysa-n")) == 5
    @test length(T.points(ds; component = ["methane", "water"])) == 8
    @test length(T.points(ds; component = ["methane", "water"], match = :all)) == 0
    @test length(T.points(ds; component = ["methane", "carbon dioxide"], match = :all)) == 5
    @test length(T.points(ds; component = ["methane", "carbon dioxide"], exact = true)) == 5
    @test length(T.points(ds; component = "methane", exact = true)) == 0
    @test length(T.points(ds; component = "water", exact = true)) == 3
    @test length(T.points(ds; pure = true)) == 3
    @test length(T.points(ds; pure = false)) == 5
    @test_throws ArgumentError T.points(ds; component = "metane")
    @test_throws ArgumentError T.points(ds; component = "methane", match = :some)
end

@testitem "points filters by property, conditions and reference, and chains" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    @test length(T.points(ds; property = "thermal conductivity")) == 5
    @test length(T.points(ds; property = r"density"i)) == 2
    @test length(T.points(ds; property = ["Mass density", "Thermal conductivity"])) == 7
    @test_throws ArgumentError T.points(ds; property = "Viscosity")

    @test length(T.points(ds; temperature = (320, 400))) == 3
    @test length(T.points(ds; temperature = (400, nothing))) == 1
    @test length(T.points(ds; temperature = (nothing, 300))) == 3
    # The vapor pressure point has no pressure condition: a pressure filter drops it.
    @test length(T.points(ds; pressure = (nothing, 5000))) == 5
    @test length(T.points(ds)) == 8

    @test length(T.points(ds; source = "user")) == 1
    @test_throws ArgumentError T.points(ds; source = "nowhere")
    @test length(T.points(ds; author = "patek")) == 4
    @test length(T.points(ds; year = 2005)) == 4
    @test length(T.points(ds; year = (1980, 1999))) == 3
    @test length(T.points(ds; doi = "10.1021/JE000000X")) == 3

    chained = T.points(T.points(ds; component = "methane"); temperature = (320, 400))
    direct = T.points(ds; component = "methane", temperature = (320, 400))
    @test chained.rows == direct.rows
    @test length(chained) == 3
    # A view shares the dataset instead of copying it.
    @test chained.dataset === ds
end

@testitem "table materialises columns with units and k = 2 uncertainty" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    tbl = T.table(T.points(ds; component = "methane"))
    @test length(tbl.value) == 5
    @test all(==("carbon dioxide + methane"), tbl.components)
    @test tbl.xkind[1] == "Mole fraction"
    @test tbl.unit[1] == "W/m/K"
    @test tbl.source == ["thermoml", "thermoml", "thermoml", "thermoml", "user"]
    @test tbl.x1 == fill(0.5, 5)
    @test all(isnan, tbl.x3)
    # Nominal: 95 % is treated as k = 2, so U is unchanged; a reported k is honoured.
    @test tbl.unc_k2 == [0.0004, 0.0004, 0.0004, 0.0004, 0.0002]
    normal = T.table(T.points(ds; component = "methane"); policy = :normal)
    @test normal.unc_k2[1] ≈ 0.0004 * 2 / 1.959963984540054
    @test normal.unc_k2[5] == 0.0002

    water = T.table(T.points(ds; component = "water"))
    vapor = findfirst(==("Vapor or sublimation pressure"), water.property)
    @test water.unit[vapor] == "kPa"
    @test water.value[vapor] == 2.339
    @test isnan(water.unc_k2[vapor])
    si = T.table(T.points(ds; component = "water"); units = :si)
    @test si.unit[vapor] == "Pa"
    @test si.value[vapor] ≈ 2339.0
    @test si.pressure[1] ≈ 101325.0
    @test si.temperature == water.temperature
    @test_throws ArgumentError T.table(T.points(ds); units = :imperial)
    @test length(T.table(T.points(ds; component = "water", temperature = (1, 2))).value) ==
          0
end

@testitem "unsupported confidence levels give NaN and one warning" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    T.add_measurement!(
        ds.measurements;
        experiment = 1,
        property = 1,
        value = 1.0,
        unc = 0.1,
        unc_level = 0.8,
    )
    view = T.points(ds; property = "Thermal conductivity")
    tbl = @test_logs (:warn, r"unc_k2 is NaN") T.table(view)
    @test isnan(tbl.unc_k2[end])
    @test tbl.unc[end] == 0.1
end

@testitem "DataView is a Tables.jl table and prints readably" setup = [Toy] tags =
    [:unit, :fast] begin
    using Tables: Tables
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    @test Tables.istable(typeof(view))
    @test Tables.getcolumn(Tables.columns(view), :value) == T.table(view).value
    @test length(collect(Tables.rows(view))) == 5
    @test :unc_k2 in Tables.columnnames(Tables.columns(view))

    text = sprint(show, MIME("text/plain"), view)
    @test occursin("DataView: 5 of 8 points", text)
    @test occursin("carbon dioxide + methane", text)
    @test occursin("T [K]", text)
    @test !occursin("x3", text)           # all-empty columns are dropped
    @test !occursin("more points", text)
    short = sprint(io -> show(io, MIME("text/plain"), view; maxrows = 2))
    @test occursin("… and 3 more points", short)
    empty = T.points(ds; temperature = (1, 2))
    @test sprint(show, MIME("text/plain"), empty) == "DataView: 0 of 8 points\n"
    @test sprint(show, view) == "DataView(5 points)"
end

@testitem "points accepts Unitful limits for temperature and pressure" setup = [Toy] tags =
    [:unit, :fast] begin
    using Unitful: @u_str, DimensionError
    T = ThermophysicalDB
    ds = Toy.build()
    # 293.15 K to 303.15 K: both limits are measured temperatures.
    in_kelvin = T.points(ds; temperature = (293.15, 303.15))
    @test length(in_kelvin) == 4
    @test T.points(ds; temperature = (20u"°C", 30u"°C")).rows == in_kelvin.rows
    @test T.points(ds; temperature = (293.15u"K", 303.15u"K")).rows == in_kelvin.rows
    @test length(T.points(ds; temperature = (nothing, 20u"°C"))) == 2

    # 101.325 kPa is exactly 1 atm.
    @test length(T.points(ds; pressure = (1u"atm", 1.1u"atm"))) == 2
    @test length(T.points(ds; pressure = (0.9u"bar", 1.1u"bar"))) == 2
    @test T.points(ds; pressure = (1u"atm", 1.1u"atm")).rows ==
          T.points(ds; pressure = (101.325, 111.4575)).rows

    # 20-30 °C and at least 1 atm: two densities of water and the 300 K conductivity.
    both = T.points(ds; temperature = (20u"°C", 30u"°C"), pressure = (1u"atm", nothing))
    @test length(both) == 3

    @test_throws DimensionError T.points(ds; temperature = (1u"m", 2u"m"))
    @test_throws DimensionError T.points(ds; pressure = (1u"K", 2u"K"))
    # Units make no sense for a year.
    @test_throws ArgumentError T.points(ds; year = (1u"m", 2u"m"))
end

@testitem "table delivers Unitful quantities for a single-unit selection" setup = [Toy] tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str, Quantity, ustrip, unit
    T = ThermophysicalDB
    ds = Toy.build()

    view = T.points(ds; component = "methane")
    tbl = T.table(view; unitful = true)
    plain = T.table(view)
    @test eltype(tbl.value) <: Quantity
    @test isconcretetype(eltype(tbl.value))
    @test unit(eltype(tbl.value)) == u"W/m/K"
    @test ustrip.(tbl.value) == plain.value
    @test ustrip.(tbl.unc_k2) == plain.unc_k2
    @test unit(eltype(tbl.temperature)) == u"K"
    @test unit(eltype(tbl.pressure)) == u"kPa"
    @test ustrip.(tbl.temperature) == plain.temperature
    # The text and provenance columns are untouched.
    @test tbl.unit == plain.unit
    @test tbl.doi == plain.doi

    si = T.table(T.points(ds; property = "Mass density"); unitful = true, units = :si)
    @test unit(eltype(si.value)) == u"kg/m^3"
    @test unit(eltype(si.pressure)) == u"Pa"
    @test Unitful.uconvert(u"atm", si.pressure[1]) ≈ 1.0u"atm"

    # Mixed units cannot share one concrete element type.
    err = try
        T.table(T.points(ds; component = "water"); unitful = true)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("narrow it with `property`", err.msg)

    empty = T.table(T.points(ds; component = "water", temperature = (1, 2)); unitful = true)
    @test isempty(empty.value)
end

@testitem "every SI unit string of the catalog is valid Unitful syntax" tags =
    [:unit, :fast] begin
    using Unitful: Unitful, uparse, dimension
    T = ThermophysicalDB
    for spec in T.UNIT_SPECS
        @test dimension(uparse(spec.si)) == dimension(uparse(spec.unitful))
    end
end
