@testitem "StringPool interns and keeps the empty string as NO_ID" tags = [:unit, :fast] begin
    pool = ThermophysicalDB.StringPool()
    a = ThermophysicalDB.intern!(pool, "Hot wire method")
    b = ThermophysicalDB.intern!(pool, "Vibrating tube")
    @test (a, b) == (1, 2)
    @test ThermophysicalDB.intern!(pool, "Hot wire method") == a
    # A SubString must hit the same entry without being copied first.
    @test ThermophysicalDB.intern!(pool, SubString("xHot wire method", 2)) == a
    @test ThermophysicalDB.intern!(pool, "") == ThermophysicalDB.NO_ID
    @test length(pool) == 2
    @test ThermophysicalDB.pool_string(pool, b) == "Vibrating tube"
    @test ThermophysicalDB.pool_string(pool, ThermophysicalDB.NO_ID) == ""
end

@testitem "references are deduplicated by DOI" tags = [:unit, :fast] begin
    t = ThermophysicalDB.ReferenceTable()
    a = ThermophysicalDB.add_reference!(t; doi = "10.1/x", year = 2005, authors = ["A, B."])
    b = ThermophysicalDB.add_reference!(t; doi = "10.1/x", year = 1999)
    c = ThermophysicalDB.add_reference!(t; doi = "10.1/y")
    d = ThermophysicalDB.add_reference!(t; title = "no doi")
    e = ThermophysicalDB.add_reference!(t; title = "no doi either")
    @test a == b == 1
    @test (c, d, e) == (2, 3, 4)
    @test length(t) == 4
    @test t.year[a] == 2005
    @test t.authors[a] == ["A, B."]
end

@testitem "compounds are keyed by InChIKey, then by name" tags = [:unit, :fast] begin
    t = ThermophysicalDB.CompoundTable()
    key = "VNWKTOKETHGBQD-UHFFFAOYSA-N"
    a = ThermophysicalDB.add_compound!(
        t;
        inchikey = key,
        names = ["methane"],
        formula = "CH4",
    )
    b = ThermophysicalDB.add_compound!(t; inchikey = key, names = ["methane", "carbane"])
    @test a == b
    @test t.names[a] == ["methane", "carbane"]
    @test t.formula[a] == "CH4"
    c = ThermophysicalDB.add_compound!(t; names = ["Water"])
    d = ThermophysicalDB.add_compound!(t; names = [" water "])
    @test c == d != a
    @test t.key[c] == "name:water"
    @test_throws ArgumentError ThermophysicalDB.add_compound!(t)
end

@testitem "properties are keyed by label and unit" tags = [:unit, :fast] begin
    t = ThermophysicalDB.PropertyTable()
    a = ThermophysicalDB.add_property!(t, "Mass density", "kg/m3")
    @test ThermophysicalDB.add_property!(t, "Mass density", "kg/m3") == a
    @test ThermophysicalDB.add_property!(t, "Mass density", "kg/dm3") != a
    @test ThermophysicalDB.add_property!(t, "Mole fraction") == 3
    @test t.unit[3] == ""
end

@testitem "a dataset built by hand validates" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    src = T.intern!(ds.sources, "thermoml")
    ref = T.add_reference!(ds.references; doi = "10.1/x", source = src)
    co2 = T.add_compound!(ds.compounds; names = ["carbon dioxide"])
    ch4 = T.add_compound!(ds.compounds; names = ["methane"])
    kind = T.intern!(ds.kinds, "Mole fraction")
    experiment = T.add_experiment!(
        ds.experiments;
        reference = ref,
        components = [co2, ch4],
        kinds = [kind, kind],
    )
    prop = T.add_property!(
        ds.properties,
        "Thermal conductivity",
        "W/m/K";
        group = T.intern!(ds.groups, "TransportProp"),
    )
    n = T.add_measurement!(
        ds.measurements;
        experiment = experiment,
        property = prop,
        value = 0.03312,
        unc = 0.00059,
        unc_level = 0.95,
        temperature = 298.893,
        pressure = 6100,
        composition = (0.5, 0.5, NaN),
    )
    @test n == 1
    @test length(ds) == 1
    @test T.validate(ds)
    @test ds.experiments.ncomp[experiment] == 2
    @test ds.experiments.components[3][experiment] == T.NO_ID
    @test isnan(ds.measurements.unc_k[1])
    @test occursin("1 measurements", sprint(show, ds))

    @test_throws ArgumentError T.add_experiment!(
        ds.experiments;
        reference = ref,
        components = [co2, ch4, co2, ch4],
    )
    # Break an invariant: a measurement pointing at a missing experiment.
    T.add_measurement!(ds.measurements; experiment = 99, property = prop, value = 1.0)
    @test_throws ArgumentError T.validate(ds)
end
