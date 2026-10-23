@testitem "extras attach free-form fields to any table" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    ref = T.add_reference!(ds.references; doi = "10.1/x")
    comp = T.add_compound!(ds.compounds; names = ["water"])
    experiment = T.add_experiment!(ds.experiments; reference = ref, components = [comp])
    prop = T.add_property!(ds.properties, "Mass density", "kg/m3")
    for value in (998.0, 997.0, 996.0)
        T.add_measurement!(ds.measurements; experiment, property = prop, value)
    end

    T.add_extra!(ds, :measurement, 1, "frequency_hz", 1.0e6)
    T.add_extra!(ds, :measurement, 3, "frequency_hz", 2.0e6)
    T.add_extra!(ds, :measurement, 2, "apparatus", "vibrating tube")
    T.add_extra!(ds, :reference, 1, "note", "checked by hand")
    @test T.validate(ds)

    @test isequal(T.extra_numbers(ds, :measurement, "frequency_hz"), [1.0e6, NaN, 2.0e6])
    @test T.extra_texts(ds, :measurement, "apparatus") == ["", "vibrating tube", ""]
    @test T.extra_texts(ds, :reference, "note") == ["checked by hand"]
    # A key is looked up per kind and per scope: no accidental cross-reads.
    @test all(isnan, T.extra_numbers(ds, :measurement, "apparatus"))
    @test all(isnan, T.extra_numbers(ds, :reference, "frequency_hz"))
    @test all(isnan, T.extra_numbers(ds, :measurement, "unknown"))
    @test T.extra_keys(ds, :measurement) == ["apparatus", "frequency_hz"]
    @test T.extra_keys(ds, :compound) == String[]
end

@testitem "extras reject invalid input and the last write wins" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    ref = T.add_reference!(ds.references; doi = "10.1/x")
    @test_throws ArgumentError T.add_extra!(ds, :nowhere, 1, "k", 1.0)
    @test_throws ArgumentError T.add_extra!(ds, :reference, 1, "", 1.0)
    @test_throws ArgumentError T.add_extra!(ds, :reference, 2, "k", 1.0)
    T.add_extra!(ds, :reference, ref, "k", 1.0)
    T.add_extra!(ds, :reference, ref, "k", 2.0)
    @test T.extra_numbers(ds, :reference, "k") == [2.0]
    # Corrupt the table: a row beyond the end of its scope.
    push!(ds.extras.scope, 4)
    push!(ds.extras.row, 5)
    push!(ds.extras.key, 1)
    push!(ds.extras.number, 0.0)
    push!(ds.extras.text, 0)
    @test_throws ArgumentError T.validate(ds)
end
