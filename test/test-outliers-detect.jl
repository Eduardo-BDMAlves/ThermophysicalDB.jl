# Synthetic worlds with known truth for the outlier detection. Values follow smooth laws and
# carry small deterministic noise, so every point that is flagged was put there by the test.
@testmodule Synthetic begin
    using ThermophysicalDB: ThermophysicalDB
    using StableRNGs: StableRNG
    const T = ThermophysicalDB

    function world()
        ds = T.Dataset()
        nist = T.intern!(ds.sources, "thermoml")
        mole = T.intern!(ds.kinds, "Mole fraction")
        ref(c) = T.add_reference!(
            ds.references;
            doi = "10.5555/outliers-$c",
            year = 2000 + Int(c) - Int('a'),
            authors = ["Author $c"],
            source = nist,
        )
        refs = (a = ref('a'), b = ref('b'), c = ref('c'))
        water = T.add_compound!(ds.compounds; names = ["water"], formula = "H2O")
        ethanol = T.add_compound!(ds.compounds; names = ["ethanol"], formula = "C2H6O")
        prop(label, unit) = T.add_property!(ds.properties, label, unit)
        props = (
            density = prop("Mass density", "kg/m3"),
            viscosity = prop("Viscosity", "Pa*s"),
            ratio = prop("Heat capacity ratio cp/cv", ""),
            permittivity = prop("Relative permittivity at zero frequency", ""),
            fraction = prop("Mole fraction", ""),
            excess = prop("Excess molar volume", "m3/mol"),
            saturation = prop("Heat capacity at saturation pressure per volume", "J/K/m3"),
        )
        return (; ds, refs, water, ethanol, mole, props)
    end

    pure(w, ref; compound = w.water) = T.add_experiment!(
        w.ds.experiments;
        reference = ref,
        components = [compound],
        kinds = [w.mole],
    )

    binary(w, ref; reverse = false) = T.add_experiment!(
        w.ds.experiments;
        reference = ref,
        components = reverse ? [w.ethanol, w.water] : [w.water, w.ethanol],
        kinds = [w.mole, w.mole],
    )

    function add!(
        w,
        e,
        property,
        value;
        temperature = NaN,
        pressure = NaN,
        x = (NaN, NaN, NaN),
        unc = NaN,
        k = 2.0,
    )
        return T.add_measurement!(
            w.ds.measurements;
            experiment = e,
            property,
            value,
            unc,
            unc_k = isnan(unc) ? NaN : k,
            temperature,
            pressure,
            composition = x,
        )
    end

    "Water density on a grid of temperature and pressure, two publications alternating by isobar."
    function density_grid(; seed = 1, noise = 0.02, unc = 0.1)
        w = world()
        rng = StableRNG(seed)
        ea, eb = pure(w, w.refs.a), pure(w, w.refs.b)
        truth(t, p) = 1000 - 0.3 * (t - 300) - 0.004 * (t - 300)^2 + 4.5e-4 * (p - 101.325)
        rows = Int[]
        for (k, p) in enumerate([101.325, 5000.0, 10000.0, 20000.0, 40000.0]),
            t = 280.0:5.0:340.0

            e = isodd(k) ? ea : eb
            row = add!(
                w,
                e,
                w.props.density,
                truth(t, p) + noise * randn(rng);
                temperature = t,
                pressure = p,
                unc,
                x = (1.0, NaN, NaN),
            )
            push!(rows, row)
        end
        return (; w..., rows, truth)
    end
end

@testitem "a clean series is kept whole and an injected outlier is found on its axis" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    view = T.DataView(g.ds)
    clean = T.find_outliers(view)
    @test length(clean.kept) == length(view)
    @test isempty(clean.outliers) && isempty(clean.disputed)
    @test clean.counts.physical == 0 && clean.counts.untested == 0

    row = g.rows[20]
    g.ds.measurements.value[row] += 3.0
    res = T.find_outliers(view)
    @test collect(res.outliers.rows) == [row]
    @test isempty(res.disputed)
    why = T.reasons(res)
    @test Set(why.code) == Set([:trend_1d, :joint_surface])
    @test all(why.index .== 20) && all(why.category .== :outlier)
    k = findfirst(==(:trend_1d), why.code)
    @test why.axis[k] == :T
    @test why.z[k] > 10
    @test why.statistic[k] > why.critical[k]
    @test why.rank[k] == 1
    @test why.deviation[k] ≈ 3.0 atol = 0.1
    @test why.reference_value[k] ≈ g.truth(why.temperature[k], why.pressure[k]) atol = 0.1
    @test why.property[k] == "Mass density"
    @test occursin("local parabola along T", why.detail[k])
end

@testitem "the three views partition the input and keep its order" setup = [Synthetic] tags =
    [:unit] begin
    using Tables
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    g.ds.measurements.value[g.rows[20]] += 3.0
    g.ds.measurements.value[g.rows[33]] = -5.0
    view = T.points(g.ds; temperature = (275, 345))
    res = T.find_outliers(view)
    kept, outliers, disputed = res
    @test kept === res.kept && outliers === res.outliers && disputed === res.disputed
    parts = [collect(kept.rows); collect(outliers.rows); collect(disputed.rows)]
    @test sort(parts) == sort(collect(view.rows))
    @test length(unique(parts)) == length(parts)
    @test issorted(kept.rows) && issorted(outliers.rows)
    @test kept.dataset === view.dataset
    @test res.counts.kept + res.counts.outliers + res.counts.disputed == length(view)
    @test Set(outliers.rows) == Set([g.rows[20], g.rows[33]])
    @test length(res) == 3 && eltype(res) == T.DataView
    @test occursin("2 outliers", sprint(show, res))
    text = sprint(show, MIME("text/plain"), res)
    @test occursin("physical_rule", text) &&
          occursin("coverage", text) &&
          occursin("certainty", text)
    # reasons and diagnostics are Tables.jl tables with equal-length columns.
    why = T.reasons(res)
    @test Tables.istable(why)
    @test length(unique(length.(values(why)))) == 1
    @test all(why.category .== :outlier)
    diag = T.diagnostics(res)
    @test Tables.istable(diag)
    @test length(unique(length.(values(diag)))) == 1
    @test all(in(diag.index), why.index[why.code .!= :physical_rule])
    @test sum(diag.flagged) == count(why.code .∈ Ref((:trend_1d, :joint_surface)))
end

@testitem "an empty view and invalid arguments are handled" setup = [Synthetic] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    empty = T.find_outliers(T.DataView(g.ds, Int32[]))
    @test length(empty.kept) == 0 && empty.counts.input == 0
    view = T.DataView(g.ds)
    @test_throws ArgumentError T.find_outliers(view; window = 4)
    @test_throws ArgumentError T.find_outliers(view; min_points = 3)
    @test_throws ArgumentError T.find_outliers(view; level = 0)
    @test_throws ArgumentError T.find_outliers(view; consensus_fraction = 0.3)
    @test_throws ArgumentError T.find_outliers(view; critical = :other)
    @test_throws ArgumentError T.find_outliers(view; source_offset = :other)
    @test_throws ArgumentError T.find_outliers(view; transform = :other)
    @test_throws ArgumentError T.find_outliers(view; transform = (speed = :log,))
    @test_throws ArgumentError T.find_outliers(view; tolerance = (Q = 1,))
    @test_throws ArgumentError T.find_outliers(view; neighbors = 5)
    @test_throws ArgumentError T.find_outliers(
        view;
        known_limits = Dict("Mass density" => 5),
    )
    # A Dataset is accepted like a view.
    @test length(T.find_outliers(g.ds).kept) == length(view)
end

@testitem "results do not depend on the seed of the clean series nor on repetition" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    g.ds.measurements.value[g.rows[20]] += 3.0
    view = T.DataView(g.ds)
    a = T.find_outliers(view; seed = 3)
    b = T.find_outliers(view; seed = 3)
    @test a.category == b.category
    @test T.reasons(a).z == T.reasons(b).z
    @test isequal(T.diagnostics(a).slope, T.diagnostics(b).slope)
    c = T.find_outliers(view; seed = 99)
    @test c.category == a.category
end

@testitem "the joint stage gives the same numbers in parallel and sequentially" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    m = g.ds.measurements
    m.value[g.rows[20]] += 3.0
    n = length(m)
    xi = vcat(m.temperature', m.pressure')
    mk() = T.JointTask(
        1,
        [1, 2],
        collect(1:n),
        xi,
        copy(xi),
        copy(m.value),
        fill(0.05, n),
        fill(Int32(1), n),
    )
    set = T.Settings(; seed = 3)
    sequential = mk()
    T.process_joint!(sequential, set; threaded = false)
    @test count(>(0), sequential.window) > 50
    for _ = 1:3
        parallel = mk()
        T.process_joint!(parallel, set)
        @test isequal(parallel.z, sequential.z)
        @test isequal(parallel.slope, sequential.slope)
        @test isequal(parallel.curvature_sd, sequential.curvature_sd)
        @test parallel.window == sequential.window
    end
    # The planted error stands out.
    @test abs(sequential.z[20]) > 5
end

@testitem "the dynamic scheduler visits every index once with private state" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    n = 500
    visits = zeros(Int, n)
    seen = Vector{Any}(undef, n)
    T.dynamic_foreach(n; init = () -> Ref(0)) do state, i
        state[] += 1
        visits[i] += 1
        seen[i] = objectid(state)
    end
    @test all(==(1), visits)
    @test length(unique(seen)) <= Threads.nthreads()
    @test T.dynamic_foreach(0) do _, _
        error("must not be called")
    end === nothing
end

@testitem "points that only the joint surface questions are disputed" setup = [Synthetic] tags =
    [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    w = Synthetic.world()
    rng = StableRNG(2)
    e = Synthetic.pure(w, w.refs.a)
    rows = Int[]
    for _ = 1:90
        t = 280 + 60rand(rng)
        p = 1000 + 39000rand(rng)
        v =
            1000 - 0.3 * (t - 300) - 0.004 * (t - 300)^2 +
            4.5e-4 * (p - 101.325) +
            0.02 * randn(rng)
        push!(
            rows,
            Synthetic.add!(
                w,
                e,
                w.props.density,
                v;
                temperature = t,
                pressure = p,
                unc = 0.1,
                x = (1.0, NaN, NaN),
            ),
        )
    end
    w.ds.measurements.value[rows[10]] += 2.0
    res = T.find_outliers(T.DataView(w.ds))
    # No two points share a temperature or a pressure, so no line can be followed.
    @test all(==(:joint_surface), T.reasons(res).code)
    @test collect(res.disputed.rows) == [rows[10]]
    @test isempty(res.outliers)
    @test T.reasons(res).category == [:disputed]
    @test T.reasons(res).axis == [:joint]
    off = T.find_outliers(T.DataView(w.ds); joint = false)
    @test length(off.kept) == 90 && off.counts.tested == 0 && off.counts.untested == 90
end

@testitem "a flag along an axis outranks the joint surface" setup = [Synthetic] tags =
    [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    g.ds.measurements.value[g.rows[20]] += 3.0
    res = T.find_outliers(T.DataView(g.ds))
    @test g.rows[20] in res.outliers.rows
    @test !(g.rows[20] in res.disputed.rows)
    # With the line analysis off the same point is only disputed.
    only_joint = T.find_outliers(T.DataView(g.ds); trend = false)
    @test g.rows[20] in only_joint.disputed.rows
end

@testitem "several points of one publication on the same side are a source offset" setup =
    [Synthetic] tags = [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    w = Synthetic.world()
    rng = StableRNG(4)
    ea, eb = Synthetic.pure(w, w.refs.a), Synthetic.pure(w, w.refs.b)
    truth(t) = 1000 - 0.3 * (t - 300) - 0.004 * (t - 300)^2
    rows_b = Int[]
    rows_a = Int[]
    for (i, t) in enumerate(280.0:2.0:350.0)
        if i % 3 == 0
            push!(
                rows_b,
                Synthetic.add!(
                    w,
                    eb,
                    w.props.density,
                    truth(t) + 1.0 + 0.02randn(rng);
                    temperature = t,
                    pressure = 101.325,
                    unc = 0.1,
                    x = (1.0, NaN, NaN),
                ),
            )
        else
            push!(
                rows_a,
                Synthetic.add!(
                    w,
                    ea,
                    w.props.density,
                    truth(t) + 0.02randn(rng);
                    temperature = t,
                    pressure = 101.325,
                    unc = 0.1,
                    x = (1.0, NaN, NaN),
                ),
            )
        end
    end
    view = T.DataView(w.ds)
    res = T.find_outliers(view)
    @test issubset(rows_b[2:(end-1)], res.disputed.rows)
    @test isdisjoint(rows_a, res.disputed.rows) && isdisjoint(rows_a, res.outliers.rows)
    why = T.reasons(res)
    @test :source_offset in why.code
    k = findfirst(==(:source_offset), why.code)
    @test occursin("same publication", why.detail[k])
    @test why.doi[k] == "10.5555/outliers-b"
    # On request the offset points are outliers.
    strict = T.find_outliers(view; source_offset = :outlier)
    @test issubset(rows_b[2:(end-1)], strict.outliers.rows)
    @test isempty(strict.disputed)
    # Two sources that agree produce no offset.
    for r in rows_b
        w.ds.measurements.value[r] -= 1.0
    end
    agree = T.find_outliers(view)
    @test isempty(agree.outliers) && isempty(agree.disputed)
end

@testitem "short lines are reported as untested, never as validated" setup = [Synthetic] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    for t = 290.0:5.0:310.0
        Synthetic.add!(
            w,
            e,
            w.props.density,
            1000.0 - 0.3 * (t - 300);
            temperature = t,
            pressure = 101.325,
            unc = 0.1,
            x = (1.0, NaN, NaN),
        )
    end
    res = T.find_outliers(T.DataView(w.ds))
    @test length(res.kept) == 5
    @test res.counts.tested == 0 && res.counts.untested == 5
    @test any(occursin("too few neighbours", n) for n in res.notes)
    @test occursin("not tested", sprint(show, MIME("text/plain"), res))
    @test isempty(T.diagnostics(res).index)
    # Lowering the minimum length is allowed down to five points.
    short = T.find_outliers(T.DataView(w.ds); min_points = 5, window = 5)
    @test short.counts.untested == 0
end

@testitem "derivatives of the local fit match an exact parabola" setup = [Synthetic] tags =
    [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    a, b, c = 1000.0, -0.3, -0.004
    ts = 280.0:4.0:336.0
    for t in ts
        Synthetic.add!(
            w,
            e,
            w.props.density,
            a + b * (t - 300) + c * (t - 300)^2;
            temperature = t,
            pressure = 101.325,
            unc = 0.1,
            x = (1.0, NaN, NaN),
        )
    end
    res = T.find_outliers(T.DataView(w.ds); joint = false)
    d = T.diagnostics(res)
    @test length(d.index) == length(ts)
    for (i, t) in zip(d.index, ts)
        @test d.slope[i] ≈ b + 2c * (t - 300) atol = 1e-6
        @test d.curvature[i] ≈ 2c atol = 1e-6
    end
    @test all(d.stage .== :trend_1d) && all(d.axis .== :T)
    @test all(d.window .== 9) && all(d.consensus .== 9)
    @test all(d.phi .== 1.0)
    @test all(d.slope_sd .> 0) && all(isfinite, d.influence)
    @test all(d.sign_test .== :not_applicable)
    @test all(d.transform .== "identity")
    # An exact parabola has nothing to flag.
    @test isempty(res.outliers)
end

@testitem "the density must rise with pressure along an isotherm" setup = [Synthetic] tags =
    [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    good, bad = Synthetic.pure(w, w.refs.a), Synthetic.pure(w, w.refs.b)
    for p in range(1000.0, 40000.0; length = 12)
        Synthetic.add!(
            w,
            good,
            w.props.density,
            1000.0 + 4.5e-4 * (p - 1000);
            temperature = 300.0,
            pressure = p,
            unc = 0.1,
            x = (1.0, NaN, NaN),
        )
        Synthetic.add!(
            w,
            bad,
            w.props.density,
            1000.0 - 4.5e-4 * (p - 1000);
            temperature = 320.0,
            pressure = p,
            unc = 0.1,
            x = (1.0, NaN, NaN),
        )
    end
    res = T.find_outliers(T.DataView(w.ds); joint = false)
    d = T.diagnostics(res)
    @test all(d.axis .== :P)
    ok = d.index .<= 24 .&& isodd.(d.index)
    verdict(i) = d.sign_test[findfirst(==(i), d.index)]
    @test all(verdict(i) == :consistent for i = 1:2:24)
    @test all(verdict(i) == :violation for i = 2:2:24)
    # Slopes are reported in kg/m³ per kPa.
    @test d.slope[1] ≈ 4.5e-4 atol = 1e-8
    # A sign error is not an outlier: it is a diagnostic.
    @test isempty(res.outliers)
end

@testitem "viscosity is fitted as ln(η) against 1/T and found when wrong" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    rows = Int[]
    for t = 275.0:5.0:360.0
        eta = exp(-6.0 + 1800 / t)
        push!(
            rows,
            Synthetic.add!(
                w,
                e,
                w.props.viscosity,
                eta;
                temperature = t,
                pressure = 101.325,
                unc = 0.01eta,
                x = (1.0, NaN, NaN),
            ),
        )
    end
    clean = T.find_outliers(T.DataView(w.ds); joint = false)
    @test isempty(clean.outliers) && isempty(clean.disputed)
    @test all(==("ln(y), 1/T"), T.diagnostics(clean).transform)
    w.ds.measurements.value[rows[9]] *= 1.5
    res = T.find_outliers(T.DataView(w.ds); joint = false)
    @test collect(res.outliers.rows) == [rows[9]]
    why = T.reasons(res)
    @test why.reference_value[1] ≈ exp(-6.0 + 1800 / why.temperature[1]) rtol = 1e-3
    # The transformation can be overridden.
    plain = T.find_outliers(T.DataView(w.ds); joint = false, transform = :none)
    @test all(==("identity"), T.diagnostics(plain).transform)
    forced =
        T.find_outliers(T.DataView(w.ds); joint = false, transform = (response = :log,))
    @test all(==("ln(y), 1/T"), T.diagnostics(forced).transform)
end

@testitem "a power-of-ten slip is annotated" setup = [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    g.ds.measurements.value[g.rows[20]] *= 10
    res = T.find_outliers(T.DataView(g.ds))
    why = T.reasons(res)
    k = findfirst(==(:trend_1d), why.code)
    @test occursin("factor 10^1", why.detail[k])
    # A change of unit that the check should not see.
    g2 = Synthetic.density_grid()
    g2.ds.measurements.value[g2.rows[20]] += 3.0
    why2 = T.reasons(T.find_outliers(T.DataView(g2.ds)))
    @test !occursin("factor", why2.detail[findfirst(==(:trend_1d), why2.code)])
end

@testitem "mixtures are one system whatever the order of the components" setup = [Synthetic] tags =
    [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    ewe, eew = Synthetic.binary(w, w.refs.a), Synthetic.binary(w, w.refs.b; reverse = true)
    rows = Int[]
    for (i, xw) in enumerate(range(0.05, 0.95; length = 19))
        rho = 790 + 210xw - 60xw * (1 - xw)
        if iseven(i)
            push!(
                rows,
                Synthetic.add!(
                    w,
                    ewe,
                    w.props.density,
                    rho;
                    temperature = 298.15,
                    pressure = 101.325,
                    unc = 0.1,
                    x = (xw, 1 - xw, NaN),
                ),
            )
        else
            push!(
                rows,
                Synthetic.add!(
                    w,
                    eew,
                    w.props.density,
                    rho;
                    temperature = 298.15,
                    pressure = 101.325,
                    unc = 0.1,
                    x = (1 - xw, xw, NaN),
                ),
            )
        end
    end
    res = T.find_outliers(T.DataView(w.ds); joint = false)
    @test res.counts.groups == 1
    @test res.counts.tested == 19
    @test isempty(res.outliers)
    w.ds.measurements.value[rows[10]] += 4.0
    bad = T.find_outliers(T.DataView(w.ds); joint = false)
    @test collect(bad.outliers.rows) == [rows[10]]
    d = T.diagnostics(bad)
    @test all(d.axis .== :x1)
    @test T.reasons(bad).axis == [:x1]
end

@testitem "a drifting setpoint stays on one line and distinct isobars do not mix" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    for p in (101.325, 20000.0), (i, t) in enumerate(280.0:5.0:340.0)
        drift = 0.04 * mod(i, 3)
        Synthetic.add!(
            w,
            e,
            w.props.density,
            1000 - 0.3 * (t - 300) + 4.5e-4 * (p - 101.325);
            temperature = t + drift,
            pressure = p * (1 + 0.003 * mod(i, 2)),
            unc = 0.1,
            x = (1.0, NaN, NaN),
        )
    end
    res = T.find_outliers(T.DataView(w.ds); joint = false)
    @test res.counts.tested == 26
    @test isempty(res.outliers)
    tight = T.find_outliers(T.DataView(w.ds); joint = false, tolerance = (P = 1e-5,))
    @test tight.counts.tested < 26
    @test_throws ArgumentError T.find_outliers(T.DataView(w.ds); tolerance = (P = 2.0,))
end

@testitem "uncertainties decide how much scatter is tolerated" setup = [Synthetic] tags =
    [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    function series(unc)
        w = Synthetic.world()
        rng = StableRNG(6)
        e = Synthetic.pure(w, w.refs.a)
        rows = Int[]
        for t = 280.0:3.0:340.0
            push!(
                rows,
                Synthetic.add!(
                    w,
                    e,
                    w.props.density,
                    1000 - 0.3 * (t - 300) + 0.5randn(rng);
                    temperature = t,
                    pressure = 101.325,
                    unc,
                    x = (1.0, NaN, NaN),
                ),
            )
        end
        return w, rows
    end
    # Noisy data with honest uncertainties: scatter is expected, nothing is an outlier and
    # the scale factor says the data are noisier than their uncertainties.
    w, rows = series(1.0)
    w.ds.measurements.value[rows[8]] += 6.0
    honest = T.find_outliers(T.DataView(w.ds); joint = false)
    @test rows[8] in honest.outliers.rows
    @test T.median_value(T.diagnostics(honest).phi) ≈ 1.0 atol = 0.7
    # Without uncertainties the scale comes from the data themselves and the result agrees.
    w2, rows2 = series(NaN)
    w2.ds.measurements.value[rows2[8]] += 6.0
    unknown = T.find_outliers(T.DataView(w2.ds); joint = false)
    @test rows2[8] in unknown.outliers.rows
    @test all(isfinite, T.diagnostics(unknown).phi)
    # Optimistic uncertainties do not turn noise into outliers: the scale factor absorbs it.
    w3, _ = series(0.001)
    optimistic = T.find_outliers(T.DataView(w3.ds); joint = false)
    # (the two end points of the line have one-sided windows and are the ones at risk)
    @test length(optimistic.outliers) ≤ 2
    @test T.median_value(T.diagnostics(optimistic).phi) > 10
end

@testitem "the certainty of the flags is reported per point and for the whole run" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    g.ds.measurements.value[g.rows[20]] += 3.0
    res = T.find_outliers(T.DataView(g.ds))
    c = res.counts
    @test 0.9 <= c.certainty <= 1.0
    @test isnan(c.corroboration) || 0 <= c.corroboration <= 1
    why = T.reasons(res)
    @test all(0 .<= filter(isfinite, why.certainty) .<= 1)
    # A physical violation is certain by definition.
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    Synthetic.add!(
        w,
        e,
        w.props.density,
        -5.0;
        temperature = 300.0,
        pressure = 100.0,
        x = (1.0, NaN, NaN),
    )
    r = T.find_outliers(T.DataView(w.ds))
    @test T.reasons(r).certainty == [1.0]
    # No flag, no figure to report.
    clean = T.find_outliers(T.DataView(Synthetic.density_grid().ds))
    @test isnan(clean.counts.certainty)
end
