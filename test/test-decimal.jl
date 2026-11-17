@testitem "Decimal values: what was typed is what is stored" begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    @test T.decimal_value(0.1223) == 1223 // 10000
    @test T.decimal_value(122.3) == 1223 // 10
    @test T.decimal_value(1e-5) == 1 // 100000
    @test T.decimal_value(-0.273233) == -273233 // 1000000
    @test T.decimal_value(0.0) == 0
    @test T.decimal_value(1e20) == Rational{Int128}(10)^20
    @test T.decimal_value(3) == 3
    @test_throws InexactError T.decimal_value(NaN)

    # a conversion of a typed number is rounded once, from its decimal value
    milli = T.ExactAffine(1 // 1000)
    @test T.apply_exact(milli, 122.3) === 0.1223
    @test T.apply_exact(milli, 0.273233) === 0.000273233
    @test T.apply_exact(milli, 650.0) === 0.65

    # exact_float is the nearest Float64, also beyond 2^53
    for (digits, e) in
        ((123456789012345678, -20), (9007199254740993, -3), (1, -25), (7, 21))
        r =
            Rational{Int128}(digits) *
            (e >= 0 ? Rational{Int128}(10)^e : 1 // Int128(10)^(-e))
        @test T.exact_float(r) == parse(Float64, "$(digits)e$e")
    end
    @test T.exact_float(1 // 3) == 1 / 3
end

@testitem "Decimal values: noise is cleaned, real digits are not" begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    @test T.clean_float(5.8704000000000006e-5) === 5.8704e-5
    @test T.clean_float(0.12229999999999999) === 0.1223
    @test T.clean_float(6.115000000000001e-5) === 6.115e-5
    @test T.clean_float(0.273233) === 0.273233
    @test T.clean_float(100000.5) === 100000.5
    @test T.clean_float(1 / 3) === 0.333333333333333
    @test T.clean_float(0.0) === 0.0
    @test isnan(T.clean_float(NaN))
    @test T.clean_float(Inf) === Inf
    @test T.clean_float(-0.12229999999999999) === -0.1223

    # decimals of up to 15 digits with one unit of noise go back to what they were,
    # over the whole range of exponents
    for (digits, e) in ((123456789012345, -20), (1, -30), (999999999999999, 22), (5, 15))
        x0 = parse(Float64, "$(digits)e$e")
        @test T.clean_float(x0) === x0
        @test T.clean_float(nextfloat(x0)) === x0
        @test T.clean_float(prevfloat(x0)) === x0
    end

    v = [0.12229999999999999, 5.8704000000000006e-5, 2.0]
    @test T.clean_floats!(v) === v
    @test v == [0.1223, 5.8704e-5, 2.0]
end

@testitem "Metrological rounding rules" begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    # GUM 7.2.6: two digits when the leading digit is 1 or 2, one otherwise
    @test T.uncertainty_place(6.115e-5) == -5
    @test T.uncertainty_place(0.0187) == -3
    @test T.uncertainty_place(0.12) == -2
    @test T.uncertainty_place(2.96) == -1
    @test T.uncertainty_place(0.0003) == -5
    @test T.uncertainty_place(1e-5) == -6
    @test T.uncertainty_place(5e24) == 24

    # halves go away from zero, as they are written
    @test T.round_to_place(0.15, -1) == 0.2
    @test T.round_to_place(0.25, -1) == 0.3
    @test T.round_to_place(2.675, -2) == 2.68
    @test T.round_to_place(-0.15, -1) == -0.2
    @test T.round_to_place(0.12233, -4) == 0.1223
    @test T.round_to_place(122.3, 1) == 120.0
    @test T.round_to_place(1.234e-30, -32) == 1.23e-30
    @test T.round_sigdigits(0.12234567, 4) == 0.1223
    @test T.round_to_place(0.0, -3) === 0.0

    # digits are taken away, never added
    x = [0.12, 0.1223, 273.15]
    @test all(T.round_to_place(v, -8) === v for v in x)
end

@testitem "Percentages of a value are free of binary noise" begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    u = T.clean_float(0.05 * 0.01 * 0.1223)
    @test u === 6.115e-5
end

@testitem "Export: report = :source and :gum" setup = [TwoDatabases, OwnData] begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    db = T.Database([T.Member("lab"; kind = :user, dataset = T.Dataset(), priority = 3)])
    cdb = OwnData.compound_db()
    T.add_reference_data!(
        db;
        reference = (doi = "10.1/dec", year = 2024, authors = ["S"]),
        compounds = cdb,
        warn_duplicates = false,
        experiments = [(
            components = ["water"],
            property = "Thermal conductivity",
            unit = "mW/m/K",
            temperature = [300.0, 310.0, 320.0],
            pressure = [101.325, 101.325, 101.325],
            value = [122.34, 122.3, 650.0],
            unc = ["0.05 %", "0.0187 mW/m/K", "0.0611 mW/m/K"],
            unc_k = [2.0, 2.0, 2.0],
        )],
    )
    ds = T.member_dataset(db, "lab")
    m = ds.measurements
    # the stored numbers are those that were typed
    @test m.value == [0.12234, 0.1223, 0.65]
    @test m.unc[2] === 1.87e-5
    @test m.unc[3] === 6.11e-5

    view = T.DataView(ds)
    full = T.table(view)
    @test full.value == [0.12234, 0.1223, 0.65]

    dir = mktempdir()
    @test_throws ArgumentError T.export_points(
        joinpath(dir, "x"),
        view;
        report = :loose,
        references = false,
        reference = :doi,
    )
    for (mode, name) in ((:gum, "m"), (:source, "f"))
        T.export_points(
            joinpath(dir, name),
            view;
            formats = (:csv,),
            references = false,
            reference = :doi,
            report = mode,
        )
    end
    lines(name) = readlines(joinpath(dir, name, name * ".csv"))
    full_lines = lines("f")
    @test occursin("1.87e-5", full_lines[end-1])
    @test occursin("6.11e-5", full_lines[end])

    rounded = lines("m")
    # 0.0187 mW/m/K at the place of two digits: 1.9e-5; 0.0611 mW/m/K: 6.0e-5
    @test occursin("1.9e-5", rounded[end-1])
    @test occursin("6.0e-5", rounded[end])
    # the first point has an uncertainty of 0.05 %: 6.117e-5 -> 6.0e-5, and the value
    # is rounded to 1e-5: 0.12234 -> 0.12234
    @test occursin("0.12234", rounded[2])
    @test !occursin("6.117", rounded[2])
    # the default is :source
    T.export_points(
        joinpath(dir, "d"),
        view;
        formats = (:csv,),
        references = false,
        reference = :doi,
    )
    @test lines("d") == full_lines
end
