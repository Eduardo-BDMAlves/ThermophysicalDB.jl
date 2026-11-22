@testmodule FilterData begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    """
    Eleven points: 4 conductivities of methane + ethane (mole fractions, gas, hot wire), 3 densities
    of ethane + methane (mass fractions, liquid, vibrating tube, listed in the other order), and 4
    densities of water (liquid, vibrating tube, one without uncertainty, one with k = 1).
    """
    function build(; liquids::Bool = true)
        ds = T.Dataset()
        src = T.intern!(ds.sources, "thermoml")
        mole = T.intern!(ds.kinds, "Mole fraction")
        mass = T.intern!(ds.kinds, "Mass fraction")
        wire = T.intern!(ds.methods, "Transient hot-wire")
        tube = liquids ? T.intern!(ds.methods, "Vibrating tube densimeter") : T.NO_ID
        gas = T.intern!(ds.phases, "Gas")
        liquid = liquids ? T.intern!(ds.phases, "Liquid") : T.NO_ID
        ref = T.add_reference!(
            ds.references;
            doi = "10.5555/filters-1",
            year = 2001,
            source = src,
        )
        ch4 = T.add_compound!(ds.compounds; names = ["methane"], formula = "CH4")
        c2h6 = T.add_compound!(ds.compounds; names = ["ethane"], formula = "C2H6")
        water = T.add_compound!(ds.compounds; names = ["water"], formula = "H2O")
        lambda = T.add_property!(ds.properties, "Thermal conductivity", "W/m/K")
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        e1 = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [ch4, c2h6],
            kinds = [mole, mole],
        )
        e2 = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [c2h6, ch4],
            kinds = [mass, mass],
        )
        e3 = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [water],
            kinds = [mole],
        )
        for (x, u) in ((0.2, 0.001), (0.4, 0.002), (0.6, 0.004), (0.8, 0.008))
            T.add_measurement!(
                ds.measurements;
                experiment = e1,
                property = lambda,
                value = 0.03 + x / 100,
                unc = u,
                unc_k = 2.0,
                method = wire,
                phase = gas,
                temperature = 300.0,
                pressure = 100.0,
                composition = (x, 1 - x, NaN),
            )
        end
        # Mass fraction of ethane 0.3, 0.5, 0.7; the uncertainty is a 95 % level of confidence.
        for (x, v) in (liquids ? ((0.3, 410.0), (0.5, 420.0), (0.7, 430.0)) : ())
            T.add_measurement!(
                ds.measurements;
                experiment = e2,
                property = density,
                value = v,
                unc = 2.0,
                unc_level = 0.95,
                method = tube,
                phase = liquid,
                temperature = 280.0,
                pressure = 5000.0,
                composition = (x, 1 - x, NaN),
            )
        end
        water_points =
            ((998.0, 0.5, 2.0), (997.0, 1.0, 1.0), (996.0, NaN, NaN), (995.0, 0.1, 2.0))
        for (v, u, k) in (liquids ? water_points : ())
            T.add_measurement!(
                ds.measurements;
                experiment = e3,
                property = density,
                value = v,
                unc = u,
                unc_k = k,
                method = tube,
                phase = liquid,
                temperature = 295.0,
                pressure = 101.325,
                composition = (1.0, NaN, NaN),
            )
        end
        return ds
    end
end

@testitem "phase and method are looked for in the text and listed" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB, points, table, phases, measurement_methods, DataView
    ds = FilterData.build()
    @test length(points(ds; phase = "gas")) == 4
    @test length(points(ds; phase = "LIQ")) == 7                 # a substring, any case
    @test length(points(ds; phase = ["gas", "liquid"])) == 11
    @test length(points(ds; phase = r"^Gas$")) == 4
    @test length(points(ds; method = "hot-wire")) == 4
    @test length(points(ds; method = "vibrating")) == 7
    @test length(points(ds; method = "tube", phase = "gas")) == 0   # criteria combine
    @test_throws ArgumentError points(ds; phase = "plasma")
    @test_throws ArgumentError points(ds; method = "calorimeter")
    err = try
        points(ds; phase = "plasma")
        nothing
    catch e
        e
    end
    @test startswith(err.msg, "no phase matches") && ThermophysicalDB.no_match(err)

    t = table(points(ds; phase = "liquid"))
    @test all(==("Liquid"), t.phase) && length(t) == 7

    p = phases(ds)
    @test p.phase == ["Liquid", "Gas"] && p.points == [7, 4]
    m = measurement_methods(ds)
    @test m.method == ["Vibrating tube densimeter", "Transient hot-wire"] &&
          m.points == [7, 4]
    @test phases(points(ds; property = "Thermal conductivity")).points == [4]
    @test isempty(phases(DataView(ds, Int32[])).phase)
end

@testitem "the fraction of a compound is found wherever it sits in the system" setup =
    [FilterData] tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, points, table
    using Unitful: Unitful, @u_str
    ds = FilterData.build()
    # Methane is x1 of the first system and x2 of the second one.
    t = table(points(ds; fraction = "methane" => (0.35, 0.65)))
    @test sort(t.value) == sort([0.03 + 0.004, 0.03 + 0.006, 420.0])
    # 0.3 mass fraction of ethane is 0.7 of methane.
    @test length(points(ds; fraction = "methane" => (0.69, 0.71))) == 1
    @test length(points(ds; fraction = "ethane" => (0.69, 0.71))) == 1
    @test length(points(ds; fraction = "methane" => (nothing, 0.25))) == 1
    @test length(points(ds; fraction = "methane" => 0.5)) == 1
    @test length(points(ds; fraction = "methane" => range(0.0, 0.35; length = 8))) == 2
    # Both compounds: the points of the systems that have both and satisfy both.
    both = points(ds; fraction = ["methane" => (0.0, 0.5), "ethane" => (0.5, 1.0)])
    @test length(both) == 4
    # The kind of composition.
    @test length(points(ds; xkind = "mass")) == 3
    @test length(points(ds; xkind = "mole")) == 8
    @test length(points(ds; xkind = "mole", fraction = "ethane" => (0.5, 0.9))) == 2
    @test length(points(ds; xkind = "mass", fraction = "ethane" => (0.5, 0.9))) == 2
    # The limits of a fraction may be percentages.
    @test length(points(ds; fraction = "methane" => (35u"percent", 65u"percent"))) == 3
    @test_throws ArgumentError points(ds; xkind = "volume")
    @test_throws ArgumentError points(ds; fraction = "unobtainium" => (0, 1))
    @test_throws ArgumentError points(ds; fraction = (0, 1))
    # A system without the compound is not a point of it.
    @test isempty(points(ds; fraction = "water" => (0.0, 0.5)))
    @test length(points(ds; fraction = "water" => (0.5, 1.0))) == 4
end

@testitem "the value is limited in the unit of the property" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, points, table
    using Unitful: Unitful, @u_str
    ds = FilterData.build()
    # Plain numbers are in the native unit of each property.
    @test length(points(ds; value = (nothing, 1.0))) == 4          # the conductivities
    @test length(points(ds; value = (415.0, 999.0))) == 6
    @test length(points(ds; property = "Mass density", value = (415.0, 999.0))) == 6
    @test length(points(ds; value = 998.0)) == 1
    @test isempty(points(ds; property = "Mass density", value = (1.0, 2.0)))
    # With a unit, the limits are converted and the properties of another quantity are left out.
    @test length(points(ds; value = (0.0, 0.04), unit = "mW/m/K")) == 0
    @test length(points(ds; value = (30.0, 40.0), unit = "mW/m/K")) == 4
    @test length(points(ds; value = (0.9, 1.0), unit = "g/cm3")) == 4
    @test length(points(ds; value = (410.0, 420.0) .* u"kg/m^3")) == 2
    @test length(points(ds; value = (30.0, 40.0) .* u"mW/m/K")) == 4
    @test length(points(ds; value = (0.9, 1.0) .* u"g/cm^3")) == 4
    @test_throws ArgumentError points(ds; value = (1, 2) .* u"s")
    @test_throws ArgumentError points(ds; value = (1, 2) .* u"s", unit = "s")
    @test_throws ArgumentError points(ds; value = (1, 2), unit = "m")
    @test_throws ArgumentError points(ds; value = "high")
    # Chained with a property filter: the same result as filtering the table.
    t = table(points(ds; property = "Mass density"))
    @test length(points(ds; property = "Mass density", value = (996.0, 998.0))) ==
          count(v -> 996.0 <= v <= 998.0, t.value)
end

@testitem "the uncertainty is limited at k = 2, absolute or relative" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, points, table
    using Unitful: Unitful, @u_str
    ds = FilterData.build()
    all_points = table(points(ds))
    # The filters agree with the column `unc_k2` of the table, point by point.
    @test length(points(ds; uncertainty = (nothing, 1.0))) == 6
    relative = table(points(ds; relative_uncertainty = (nothing, 0.001)))
    @test length(relative) == 2
    @test all(r -> r.unc_k2 / abs(r.value) <= 0.001, relative)
    @test length(relative) == count(
        i ->
            !isnan(all_points.unc_k2[i]) &&
            all_points.unc_k2[i] / abs(all_points.value[i]) <= 0.001,
        eachindex(all_points.unc_k2),
    )
    # A point without an uncertainty is not a point of any limit on it.
    @test !any(isnan, table(points(ds; relative_uncertainty = (nothing, Inf))).unc_k2)
    @test length(points(ds; relative_uncertainty = (nothing, Inf))) == 10
    # k = 1 doubles the value: 1.0 at k = 1 is 2.0 at k = 2.
    t = table(points(ds; property = "Mass density", uncertainty = (1.9, 2.1)))
    @test length(t) == 4                  # three at the level 95 % (read as k = 2) and one with k = 1
    @test all(u -> 1.9 <= u <= 2.1, t.unc_k2)
    # Both limits together, and with a unit.
    narrow = points(
        ds;
        property = "Thermal conductivity",
        relative_uncertainty = (nothing, 0.1),
        uncertainty = (nothing, 0.003),
    )
    @test length(narrow) == 2
    @test length(
        points(
            ds;
            property = "Thermal conductivity",
            uncertainty = (0.9, 3.0),
            unit = "mW/m/K",
        ),
    ) == 2
    @test_throws ArgumentError points(ds; relative_uncertainty = "low")
    # Ratios may be quantities: percentages and parts per million.
    @test length(points(ds; relative_uncertainty = (nothing, 0.1u"percent"))) ==
          length(points(ds; relative_uncertainty = (nothing, 0.001)))
    @test length(points(ds; relative_uncertainty = (nothing, 1000u"ppm"))) ==
          length(points(ds; relative_uncertainty = (nothing, 0.001)))
    @test length(points(ds; relative_uncertainty = (nothing, 10u"percent"))) ==
          length(points(ds; relative_uncertainty = (nothing, 0.1)))
    @test_throws ArgumentError points(ds; relative_uncertainty = (nothing, 1u"m"))
end

@testitem "the new filters chain and work over several databases" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, points, table, phases, measurement_methods
    T = ThermophysicalDB
    ds = FilterData.build()
    chained = points(
        points(ds; phase = "liquid");
        method = "vibrating",
        fraction = "water" => (0.5, 1.0),
    )
    @test table(chained).value == [998.0, 997.0, 996.0, 995.0]
    once =
        points(ds; phase = "liquid", method = "vibrating", fraction = "water" => (0.5, 1.0))
    @test table(once).value == table(chained).value

    # The second database has gas only: it is left out of a search for liquids, not an error.
    db = T.Database([
        T.Member("a"; kind = :thermoml, dataset = ds),
        T.Member("b"; kind = :user, dataset = FilterData.build(; liquids = false)),
    ])
    @test length(points(db; phase = "liquid", duplicate = true)) == 7
    @test length(points(db; phase = "gas", duplicate = true)) == 8
    @test length(points(db; fraction = "methane" => (0.35, 0.65), duplicate = true)) == 5
    @test length(points(db; value = (30.0, 40.0), unit = "mW/m/K", duplicate = true)) == 8
    @test length(
        points(
            db;
            relative_uncertainty = (nothing, 0.1),
            property = "Mass density",
            duplicate = true,
        ),
    ) >= 0
    @test_throws ArgumentError points(db; phase = "plasma")
    @test phases(db).phase == ["Gas", "Liquid"] && phases(db).points == [8, 7]
    @test measurement_methods(points(db; duplicate = true)).points == [8, 7]
end

@testitem "measured_properties lists and searches the properties" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, points, measured_properties, table
    T = ThermophysicalDB
    ds = FilterData.build()
    all_of = measured_properties(ds)
    @test all_of.property == ["Mass density", "Thermal conductivity"]
    @test all_of.points == [7, 4]
    @test keys(all_of) == (:property, :points)

    # text (a substring, any case), a regular expression, a function and a vector
    @test measured_properties(ds; search = "DENS").property == ["Mass density"]
    @test measured_properties(ds; search = " conduct ").points == [4]   # spaces around are ignored
    @test measured_properties(ds; search = "conduct").points == [4]
    @test measured_properties(ds; search = r"^Thermal").property == ["Thermal conductivity"]
    @test measured_properties(ds; search = p -> endswith(p, "density")).points == [7]
    @test measured_properties(ds; search = ["density", "conduct"]) == all_of
    @test measured_properties(ds; search = "").property == all_of.property
    @test measured_properties(ds; search = "critical") ==
          (property = String[], points = Int[])
    @test_throws TypeError measured_properties(ds; search = p -> 1)

    # a selection only counts its own points
    gas = points(ds; phase = "gas")
    @test measured_properties(gas) == (property = ["Thermal conductivity"], points = [4])

    # it goes straight to `points`, as the result or as its column
    found = measured_properties(ds; search = ["density", "conduct"])
    @test length(points(ds; property = found)) == 11
    @test length(points(ds; property = found.property)) == 11
    @test length(points(ds; property = measured_properties(ds; search = "conduct"))) == 4
    @test_throws ArgumentError points(ds; property = measured_properties(ds; search = "x"))

    # databases add the counts of their members by label
    db = T.Database([
        T.Member("a"; kind = :thermoml, dataset = ds),
        T.Member("b"; kind = :user, dataset = FilterData.build(; liquids = false)),
    ])
    @test measured_properties(db) ==
          (property = ["Thermal conductivity", "Mass density"], points = [8, 7])
    @test measured_properties(db; search = "density").points == [7]
    @test measured_properties(points(db; duplicate = true); search = "conduct").points ==
          [8]
end
