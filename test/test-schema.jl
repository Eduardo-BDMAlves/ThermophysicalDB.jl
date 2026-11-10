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
    a = ThermophysicalDB.add_reference!(
        t;
        doi = "10.5555/tdbfixture-003",
        year = 2005,
        authors = ["Poe, B."],
    )
    b = ThermophysicalDB.add_reference!(t; doi = "10.5555/tdbfixture-003", year = 1999)
    c = ThermophysicalDB.add_reference!(t; doi = "10.5555/tdbfixture-004")
    d = ThermophysicalDB.add_reference!(t; title = "no doi")
    e = ThermophysicalDB.add_reference!(t; title = "no doi either")
    @test a == b == 1
    @test (c, d, e) == (2, 3, 4)
    @test length(t) == 4
    @test t.year[a] == 2005
    @test t.authors[a] == ["Poe, B."]
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
    ref = T.add_reference!(ds.references; doi = "10.5555/tdbfixture-003", source = src)
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

@testitem "schema_tables describes every column and every relation of the Dataset" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    tables = T.schema_tables()
    pools = T.schema_pools()
    names = [t.name for t in tables]

    @test names == [
        :references,
        :compounds,
        :samples,
        :purity_steps,
        :properties,
        :experiments,
        :measurements,
        :extras,
        :conditions,
        :uncertainties,
    ]
    @test length(pools) == 18

    # every column of every table is described, apart from the lookup dictionary
    ds = T.Dataset()
    for t in tables
        fields = [
            f for f in fieldnames(typeof(getfield(ds, t.name))) if !(f in T.DERIVED_FIELDS)
        ]
        @test [c.name for c in t.columns] == fields
    end

    # every relation points to something that exists, and none of the declarations is stale
    for t in tables, c in t.columns
        c.role in (:table, :pool) && @test c.target in vcat(names, pools)
    end
    declared = Set(keys(T.FOREIGN_KEYS))
    described =
        Set((t.name, c.name) for t in tables for c in t.columns if c.target !== :none)
    @test declared == described

    # shapes
    measurements = only(t for t in tables if t.name === :measurements)
    composition = only(c for c in measurements.columns if c.name === :composition)
    @test composition.arity == T.MAX_COMPONENTS && composition.eltype == "Float64"
    experiment = only(c for c in measurements.columns if c.name === :experiment)
    @test experiment.role === :table && experiment.target === :experiments
    references = only(t for t in tables if t.name === :references)
    @test [c.name for c in references.columns if c.role === :unique] == [:doi]
end

@testitem "compact columns return the same numbers as plain vectors" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    v = T.PooledFloats{UInt8}()
    values = [0.95, NaN, 0.8, 0.95, -0.0, 0.0, NaN, 0.95]
    for x in values
        push!(v, x)
    end
    @test isequal(v, values)
    @test length(v) == 8 && v.codes isa Vector{UInt8}
    @test length(v.pool) == 4                       # 0.95, 0.8, -0.0 and 0.0 are distinct
    @test sign(v[5]) == -1 && sign(v[6]) == 1 || signbit(v[5]) && !signbit(v[6])
    v[2] = 2.0
    v[1] = NaN
    @test v[2] == 2.0 && isnan(v[1])
    @test sum(skipmissing(ifelse.(isnan.(v), missing, v))) ≈ 2.0 + 0.8 + 0.95 + 0.95
    # a column filled from disk gets its lookup back
    copy = T.PooledFloats{UInt8}()
    append!(copy.codes, v.codes)
    append!(copy.pool, v.pool)
    T.rebuild_lookup!(copy)
    push!(copy, 0.8)
    @test copy[end] == 0.8 && length(copy.pool) == length(v.pool)
    # too many distinct values is explained, not an InexactError
    full = T.PooledFloats{UInt8}()
    for x = 1:255
        push!(full, Float64(x))
    end
    @test_throws ArgumentError push!(full, 256.0)
    push!(full, 255.0)                               # a known value still fits
    # narrow identifiers
    @test T.narrow(UInt8, 255, "property") === 0xff
    err = try
        T.narrow(UInt8, 256, "property")
    catch e
        e
    end
    @test err isa ArgumentError && occursin("property 256", err.msg)
    @test_throws ArgumentError T.narrow(UInt8, -1, "phase")
end

@testitem "the evaluator and the assessment live in columns and survive the cache" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    ref = T.add_reference!(ds.references; doi = "10.5555/tdbfixture-compact")
    comp = T.add_compound!(ds.compounds; names = ["water"])
    experiment = T.add_experiment!(ds.experiments; reference = ref, components = [comp])
    prop = T.add_property!(ds.properties, "Mass density", "kg/m3")
    who = T.intern!(ds.evaluators, "A. Evaluator")
    T.add_measurement!(
        ds.measurements;
        experiment,
        property = prop,
        value = 998.0,
        unc = 0.1,
        unc_k = 2,
        unc_level = 0.95,
        evaluator = who,
        assessment = 2,
    )
    T.add_measurement!(ds.measurements; experiment, property = prop, value = 997.0)
    m = ds.measurements
    @test T.pool_string(ds.evaluators, m.evaluator[1]) == "A. Evaluator"
    @test m.evaluator[2] == T.NO_ID && m.assessment[1] == 2.0 && isnan(m.assessment[2])
    @test isequal(m.unc_k, [2.0, NaN]) && isequal(m.unc_level, [0.95, NaN])
    @test T.validate(ds)
    store = Dict{String,Any}()
    T.write_dataset((key, array) -> store[key] = array, ds)
    back = T.restore_dataset(key -> store[key])
    @test isequal(back.measurements.assessment, m.assessment)
    @test isequal(back.measurements.unc_level, m.unc_level)
    @test back.measurements.evaluator == m.evaluator
    @test T.pool_string(back.evaluators, back.measurements.evaluator[1]) == "A. Evaluator"
    push!(back.measurements.unc_level, 0.95)         # the lookup was rebuilt: no new value
    @test length(back.measurements.unc_level.pool) == 1
    # an identifier that does not fit is explained
    @test_throws ArgumentError T.add_measurement!(
        ds.measurements;
        experiment,
        property = 300,
        value = 1.0,
    )
end

@testitem "compact! keeps every value" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    ref = T.add_reference!(ds.references; doi = "10.5555/tdbfixture-shrink")
    comp = T.add_compound!(ds.compounds; names = ["water"])
    experiment = T.add_experiment!(ds.experiments; reference = ref, components = [comp])
    prop = T.add_property!(ds.properties, "Mass density", "kg/m3")
    for i = 1:100
        T.add_measurement!(
            ds.measurements;
            experiment,
            property = prop,
            value = 990.0 + i,
            unc_level = isodd(i) ? 0.95 : NaN,
        )
    end
    before = copy(ds.measurements.value)
    levels = copy(ds.measurements.unc_level)
    @test T.compact!(ds) === ds
    @test ds.measurements.value == before && isequal(ds.measurements.unc_level, levels)
    @test T.validate(ds)
    T.add_measurement!(
        ds.measurements;
        experiment,
        property = prop,
        value = 1.0,
        unc_level = 0.5,
    )
    @test length(ds.measurements) == 101 && ds.measurements.unc_level[end] == 0.5
end
