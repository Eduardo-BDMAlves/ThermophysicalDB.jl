@testmodule SampleData begin
    using ThermophysicalDB: ThermophysicalDB
    using Test: @test_logs
    using ..Fixtures
    using ..ThermoMLFixture

    """The dataset of the miniature article: CO2 (2 steps), methane (1 step), water (no sample)."""
    function build()
        T = ThermophysicalDB
        return mktempdir() do dir
            archive = joinpath(dir, "t.tgz")
            Fixtures.make_tgz(
                archive,
                Dict("10.5555/tdbfixture-001.json" => ThermoMLFixture.JSON),
            )
            ds, _ = @test_logs min_level = Base.CoreLogging.Warn T.build_dataset(
                archive;
                progress = false,
            )
            ds
        end
    end
end

@testitem "sample_table and purity_step_table list the samples and their steps" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()

    st = T.sample_table(ds)
    @test length(st.sample) == 2
    i = findfirst(==("carbon dioxide"), st.compound)
    @test st.doi[i] == "10.5555/tdbfixture-001"
    @test st.inchikey[i] == "CURLTUGMZLYLDI-UHFFFAOYSA-N"
    @test st.purity[i] ≈ 0.999 && st.purity_kind[i] == "mole"
    @test st.purity_initial[i] ≈ 0.995 && st.purity_initial_kind[i] == "mass"
    @test st.purity_basis[i] == "measured" && st.nsteps[i] == 2
    @test st.analysis[i] == "Stated by supplier; Gas chromatography"
    @test st.purification[i] == "None used; Fractional distillation"
    @test st.supplier[i] == "" && st.origin[i] == "Commercial source"
    j = findfirst(==("methane"), st.compound)
    @test st.purity_basis[j] == "supplier" && st.water[j] ≈ 2e-5
    @test isnan(st.purity_initial[j]) && st.purity_initial_kind[j] == ""

    steps = T.purity_step_table(ds)
    @test length(steps.step) == 3
    k = findall(==("carbon dioxide"), steps.compound)
    @test steps.step[k] == [1, 2]
    @test steps.mass[k][1] ≈ 0.995 && isnan(steps.mass[k][2])
    @test steps.mole[k][2] ≈ 0.999
    @test steps.digits[k] == [3, 3]
    @test steps.analysis_text[k] == ["", "FID"]
    @test steps.purification_text[k] == ["", "twice"]

    # restricted to a selection: water has no sample, so its points add nothing
    v = T.points(ds; component = "water")
    @test isempty(T.sample_table(v).sample)
    @test isempty(T.purity_step_table(v).step)
    @test length(T.sample_table(T.points(ds; component = "methane")).sample) == 2
end

@testitem "table(details = true) carries purity, digits and the uncertainty evaluation" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    plain = T.table(T.points(ds; component = "methane"))
    @test !(:purity1 in keys(plain))

    t = T.table(T.points(ds; component = "methane"); details = true)
    @test t.purpose == fill("Principal objective of the work", 2)
    # only the point that states an uncertainty has a method for it
    @test t.unc_method == ["Propagation of evaluated standard uncertainties", ""]
    @test t.digits == [4, -1] && t.temperature_digits == [6, -1]
    @test t.pressure_digits == [2, -1]
    # component 1 is carbon dioxide, component 2 methane, component 3 does not exist
    @test t.purity1 ≈ [0.999, 0.999] && t.purity_kind1 == ["mole", "mole"]
    @test t.purity2 ≈ [0.9995, 0.9995] && t.purity_basis2 == ["supplier", "supplier"]
    @test all(isnan, t.purity3) && all(isempty, t.purity_basis3)

    # a component without a sample gives NaN, like any other missing value
    w = T.table(T.points(ds; component = "water"); details = true)
    @test all(isnan, w.purity1) && all(isempty, w.purity_basis1)
    @test w.purpose == ["", ""]
end

@testitem "reference_summary reports purity, its validation and the purification" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    s = T.reference_summary(ds; online = false, cache = false, progress = false)
    @test length(s) == 3
    i = findfirst(==("Thermal conductivity"), s.property)
    @test s.purity[i] == "carbon dioxide 99.9 % mol; methane 99.95 % mass"
    @test s.purity_min[i] ≈ 99.9 && s.purity_max[i] ≈ 99.95
    @test s.purity_basis[i] == "measured; supplier"
    @test s.purity_method[i] == "Stated by supplier; Gas chromatography"
    @test s.purification[i] == "None used; Fractional distillation"
    @test s.sample_source[i] == "Commercial source" && s.supplier[i] == ""

    # water has no sample: empty texts and NaN, like any other absent number
    j = findfirst(==("Mass density"), s.property)
    @test s.purity[j] == "" && isnan(s.purity_min[j]) && s.purity_method[j] == ""

    # the default table shows the new columns when some article states them
    @test [:purity, :purity_method, :purification] ⊆ T.default_columns(s)
    md = T.markdown_table(s; reference = :key)
    @test occursin("| Purity |", md) && occursin("Gas chromatography", md)
    tex = T.latex_table(s; columns = [:reference, :purity, :purity_basis, :supplier])
    @test occursin("99.9 \\% mol", tex) && occursin("Purity basis", tex)
    # the columns are chosen freely
    only_purity = T.markdown_table(s; columns = [:reference, :purity_basis])
    @test occursin("| Reference | Purity basis |", only_purity)
    csv = T.csv_table(s; notice = false)
    header = first(split(csv, '\n'))
    @test occursin("purity_min [%]", header) && occursin("sample_source", header)
    @test_throws ArgumentError T.markdown_table(s; columns = [:purity, :nonsense])

    # only the described part of the selection counts
    only_water = T.reference_summary(
        T.points(ds; component = "water");
        online = false,
        cache = false,
        progress = false,
    )
    @test !any(in(T.default_columns(only_water)), [:purity, :purity_method, :purification])
end

@testitem "the cache keeps samples, steps and digits" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    store = Dict{String,Any}()
    T.write_dataset((key, value) -> store[key] = value, ds)
    @test store["schema_version"] == 3
    back = T.restore_dataset(key -> store[key])
    @test T.validate(back)
    @test back.samples.purity ≈ ds.samples.purity
    @test back.samples.index == ds.samples.index
    @test back.purity_steps.analysis == ds.purity_steps.analysis
    @test back.experiments.samples == ds.experiments.samples
    @test back.measurements.digits == ds.measurements.digits
    @test isequal(T.sample_table(back), T.sample_table(ds))
end
