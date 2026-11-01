@testsnippet UncertaintyFixture begin
    import ThermophysicalDB
    T = ThermophysicalDB

    # a water density experiment with three points, built by hand
    function build()
        ds = T.Dataset()
        ref = T.add_reference!(ds.references; doi = "10.5555/tdbfixture-010")
        comp = T.add_compound!(ds.compounds; names = ["water"])
        experiment = T.add_experiment!(ds.experiments; reference = ref, components = [comp])
        prop = T.add_property!(ds.properties, "Mass density", "kg/m3")
        for (value, t) in ((998.2, 293.15), (997.0, 298.15), (995.6, 303.15))
            T.add_measurement!(
                ds.measurements;
                experiment,
                property = prop,
                value,
                temperature = t,
                pressure = 101.325,
            )
        end
        return ds
    end
end

@testitem "an uncertainty term always carries its coverage" setup = [UncertaintyFixture] tags =
    [:unit, :fast] begin
    @test_throws ArgumentError T.UncertaintyTerm(0.1)
    @test_throws ArgumentError T.UncertaintyTerm(-0.1; k = 2)
    @test_throws ArgumentError T.UncertaintyTerm(0.1; k = 0)
    a = T.UncertaintyTerm(0.2; k = 2.0)
    @test (a.value, a.k, a.level) == (0.2, 2.0, 0.95)
    b = T.UncertaintyTerm(0.2; level = 0.95)
    @test b.k == 2.0
    c = T.UncertaintyTerm(0.2; k = 1.0)
    @test c.level == 0.6827
    @test isnan(T.UncertaintyTerm(0.2; k = 3.3).level)
    @test_throws ArgumentError T.UncertaintyTerm(0.2; level = 0.8)   # no k known for 80 %
end

@testitem "the combined and the expanded uncertainty follow from the terms" setup =
    [UncertaintyFixture] tags = [:unit, :fast] begin
    ds = build()
    # a thermometer shared by the points: standard uncertainty 0.01 K
    T.set_uncertainty!(
        ds;
        scope = :experiment,
        row = 1,
        quantity = :temperature,
        device = 0.01,
    )
    r = T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :temperature,
        statistical = 0.02,
        device = T.UncertaintyTerm(0.01; k = 2.0),   # 0.005 K as a standard uncertainty
    )
    @test r.combined ≈ sqrt(0.01^2 + 0.02^2 + 0.005^2)
    @test r.k == 2.0 && r.level == 0.95 && r.expanded ≈ 2 * r.combined
    @test T.validate(ds)

    t = T.uncertainty_table(ds)
    @test t.kind == ["device", "statistical", "device", "combined", "expanded"]
    @test t.origin == ["given", "given", "given", "derived", "derived"]
    @test t.measurement == [T.NO_ID, 1, 1, 1, 1]
    @test t.standard[3] ≈ 0.005 && t.k[3] == 2.0
    @test all(==("10.5555/tdbfixture-010"), t.doi)
    @test t.method[4] == T.DERIVED_COMBINED_TEXT && t.method[5] == T.DERIVED_EXPANDED_TEXT

    # a second call for the same quantity of the same point is refused
    @test_throws ArgumentError T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :temperature,
        statistical = 0.1,
    )
    # a coverage can be asked for by level
    r2 = T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 2,
        quantity = :pressure,
        statistical = 0.5,
        level = 0.99,
    )
    @test r2.combined == 0.5 && r2.k ≈ 2.5758293035489004 && r2.level == 0.99
end

@testitem "a combined term gives the expanded one, an expanded term the combined one" setup =
    [UncertaintyFixture] tags = [:unit, :fast] begin
    ds = build()
    # the combined term of the user wins over the terms
    r = T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :property,
        statistical = 1.0,
        combined = 0.3,
        k = 2.0,
        evaluation = "Propagation of evaluated standard uncertainties",
    )
    @test r.combined == 0.3 && r.expanded ≈ 0.6
    m = ds.measurements
    @test (m.unc[1], m.unc_k[1], m.unc_level[1]) == (0.6, 2.0, 0.95)
    @test T.pool_string(ds.unc_methods, m.unc_method[1]) ==
          "Propagation of evaluated standard uncertainties"

    # only an expanded term, as the archive states it
    r = T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 2,
        quantity = :property,
        expanded = T.UncertaintyTerm(0.4; level = 0.95),
    )
    @test r.combined ≈ 0.2 && r.expanded == 0.4 && r.k == 2.0
    @test m.unc[2] == 0.4
    t = T.uncertainty_table(ds)
    i = findfirst(r -> r == 2, t.measurement)
    @test t.kind[i:(i+1)] == ["expanded", "combined"]
    @test t.origin[i:(i+1)] == ["given", "derived"]

    # nothing to derive from: no rows, no change
    T.set_uncertainty!(ds; scope = :measurement, row = 3, quantity = :property)
    @test isnan(m.unc[3]) && count(==(3), T.uncertainty_table(ds).measurement) == 0
    @test T.validate(ds)
    @test_throws ArgumentError T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 9,
        quantity = :property,
        combined = 1.0,
    )
    @test_throws ArgumentError T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 3,
        quantity = :nowhere,
        combined = 1.0,
    )
    @test_throws ArgumentError T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 3,
        quantity = :pressure,
        combined = 1.0,
        evaluation = "x",
    )
end

@testitem "expanded_uncertainty gives error bars at any coverage" setup =
    [UncertaintyFixture] tags = [:unit, :fast] begin
    ds = build()
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :temperature,
        combined = 0.02,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 3,
        quantity = :temperature,
        combined = 0.04,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 2,
        quantity = :pressure,
        combined = 0.5,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 2,
        quantity = :property,
        expanded = T.UncertaintyTerm(0.3; k = 2.0),
    )
    v = T.DataView(ds)
    @test isequal(T.expanded_uncertainty(v, :temperature), [0.04, NaN, 0.08])
    @test isequal(T.expanded_uncertainty(v, :temperature; k = 1), [0.02, NaN, 0.04])
    @test isequal(T.expanded_uncertainty(v, :pressure; units = :si), [NaN, 1000.0, NaN])
    @test isequal(T.expanded_uncertainty(v, :property; k = 2), [NaN, 0.3, NaN])
    @test all(isnan, T.expanded_uncertainty(v, :composition1))
    # the point that has only the `unc` of the archive is read with its own coverage
    ds2 = build()
    ds2.measurements.unc[1] = 0.6
    ds2.measurements.unc_k[1] = 2.0
    @test T.expanded_uncertainty(T.DataView(ds2, Int32[1]), :property; k = 1) == [0.3]
    # a selection keeps the terms of its points only
    one = T.DataView(ds, Int32[3])
    @test T.uncertainty_table(one).measurement == [3, 3]
    @test_throws ArgumentError T.expanded_uncertainty(v, :temperature; k = 0)
end

@testitem "the uncertainty table survives the cache and is checked" setup =
    [UncertaintyFixture] tags = [:unit, :fast] begin
    ds = build()
    T.set_uncertainty!(
        ds;
        scope = :experiment,
        row = 1,
        quantity = :temperature,
        device = 0.01,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = 1,
        quantity = :temperature,
        statistical = 0.02,
    )
    store = Dict{String,Any}()
    T.write_dataset((key, value) -> (store[key] = value; nothing), ds)
    back = T.restore_dataset(key -> store[key])
    @test T.uncertainty_table(back) == T.uncertainty_table(ds)
    # corrupt the table: a coverage factor that is zero
    push!(ds.uncertainties.scope, 2)
    push!(ds.uncertainties.row, 2)
    push!(ds.uncertainties.quantity, 1)
    push!(ds.uncertainties.kind, 1)
    push!(ds.uncertainties.origin, 1)
    push!(ds.uncertainties.value, 1.0)
    push!(ds.uncertainties.k, 0.0)
    push!(ds.uncertainties.level, NaN)
    push!(ds.uncertainties.method, T.NO_ID)
    @test_throws ArgumentError T.validate(ds)
end
