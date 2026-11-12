@testmodule Repeats begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    const WATER = "XLYOFNOQVPJJNP-UHFFFAOYSA-N"
    const SALT = "FAPWRFPIFSIZLT-UHFFFAOYSA-M"

    # One reference with one experiment: `points` are (T, p, value, amounts) of one property.
    function system!(
        ds,
        points;
        doi = "",
        authors = String[],
        year = 0,
        title = "",
        compounds = [(WATER, "water")],
        property = "Mass density",
        unit = "kg/m3",
        scale = "",
    )
        src = T.intern!(ds.sources, "fixture")
        ref = T.add_reference!(ds.references; doi, authors, year, title, source = src)
        ids = Int32[
            T.add_compound!(ds.compounds; inchikey = k, names = [n]) for (k, n) in compounds
        ]
        prop = T.add_property!(ds.properties, property, unit)
        kinds = isempty(scale) ? Int32[] : Int32[T.intern!(ds.kinds, scale) for _ in ids]
        e = T.add_experiment!(ds.experiments; reference = ref, components = ids, kinds)
        for p in points
            amounts = get(p, :x, (NaN, NaN, NaN))
            T.add_measurement!(
                ds.measurements;
                experiment = e,
                property = prop,
                value = p.v,
                temperature = get(p, :T, NaN),
                pressure = get(p, :p, NaN),
                composition = amounts,
            )
        end
        return ds
    end

    function member(name, kind, ds; priority = nothing)
        return priority === nothing ? T.Member(name; kind, dataset = ds) :
               T.Member(name; kind, dataset = ds, priority)
    end

    water(Ts, vs; p = 101.325) = [(; T = t, p, v) for (t, v) in zip(Ts, vs)]

    # Two databases that share a work: the DOI is written in another case in the second one.
    function pair(; first_points, second_points, kw1 = (;), kw2 = (;))
        a = system!(T.Dataset(), first_points; doi = "10.5555/Same-1", kw1...)
        b = system!(T.Dataset(), second_points; doi = "10.5555/same-1", kw2...)
        return T.Database([member("a", :thermoml, a), member("b", :literature, b)])
    end
end

@testitem "the same point of the same work is left out of the database that loses" setup =
    [Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    db = Repeats.pair(;
        first_points = Repeats.water([293.15, 298.15, 303.15], [998.2, 997.0, 995.6]),
        second_points = Repeats.water([293.20, 298.15, 310.0], [998.25, 997.0, 990.0]),
    )
    all_points = T.points(db; property = "Mass density", duplicate = true)
    @test length(all_points) == 6 && all_points.repeats === nothing
    one_copy = T.points(db; property = "Mass density", duplicate = false)
    @test length(one_copy) == 4
    @test length(T.points(db; property = "Mass density")) == 4    # the default leaves them out
    @test [length(p) for p in T.parts(one_copy)] == [3, 1]
    rep = T.duplicates(one_copy)
    @test length(rep) == 2 && all(==(:doi), rep.how) && all(==("a"), rep.database)
    @test rep.other_row == [1, 2] && rep.compounds == fill("water", 2)
    @test rep.work[1] == "10.5555/Same-1"
    @test isempty(T.conflicts(one_copy))
    # A view that was not filtered gives the same pairs.
    @test length(T.duplicates(all_points)) == 2
    @test length(T.duplicates(db; property = "Mass density")) == 2
    # The tolerances: tighter, and the pairs go.
    tight = T.DuplicateRules(temperature = 0.01)
    @test length(T.points(db; duplicate = tight)) == 5
    @test length(T.duplicates(all_points; rules = tight)) == 1
    @test length(T.points(db; duplicate = T.DuplicateRules(value = 0.0))) == 5
    @test_throws ArgumentError T.points(db; duplicate = :yes)
    @test_throws ArgumentError T.DuplicateRules(temperature = -1)
    @test_throws ArgumentError T.DuplicateRules(value = NaN)
    # Filters can be chained on the view; the report belongs to the selection that made it.
    @test length(T.points(one_copy; temperature = (290, 300))) == 2
    # The databases themselves are not changed.
    @test length(T.member_dataset(db, "a").measurements) == 3
    @test length(T.member_dataset(db, "b").measurements) == 3
end

@testitem "points of one database are never repeats of each other" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    db = Repeats.pair(;
        first_points = Repeats.water([293.15, 293.15], [998.2, 998.2]),
        second_points = Repeats.water([310.0], [990.0]),
    )
    @test length(T.points(db; duplicate = false)) == 3
    @test isempty(T.duplicates(db))
end

@testitem "the tolerances are those given: 0.1 K, 0.01 bar and 0.1 %" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    r = T.DEFAULT_DUPLICATE_RULES
    @test (r.temperature, r.pressure, r.value, r.composition) == (0.1, 1.0, 1.0e-3, 1.0e-3)
    function repeated(first, second)
        db = Repeats.pair(; first_points = [first], second_points = [second])
        return length(T.duplicates(db))
    end
    base = (; T = 293.15, p = 101.325, v = 1000.0)
    @test repeated(base, (; T = 293.25, p = 101.325, v = 1000.0)) == 1     # exactly 0.1 K
    @test repeated(base, (; T = 293.26, p = 101.325, v = 1000.0)) == 0
    @test repeated(base, (; T = 293.15, p = 102.325, v = 1000.0)) == 1     # exactly 1 kPa
    @test repeated(base, (; T = 293.15, p = 102.4, v = 1000.0)) == 0
    @test repeated(base, (; T = 293.15, p = 101.325, v = 1000.9)) == 1     # 0.09 %
    @test repeated(base, (; T = 293.15, p = 101.325, v = 1001.2)) == 0
    @test repeated(
        (; T = 293.15, p = 101.325, v = 0.0),
        (; T = 293.15, p = 101.325, v = 0.0),
    ) == 1
end

@testitem "what a point does not have is not compared, but the temperature is needed" setup =
    [Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    # No pressure on one side: the temperature and the value decide.
    db = Repeats.pair(;
        first_points = [(; T = 293.15, p = 101.325, v = 998.2)],
        second_points = [(; T = 293.15, v = 998.2)],
    )
    rep = T.duplicates(db)
    @test length(rep) == 1 && rep.ignored == ["pressure"]
    @test length(T.points(db; duplicate = false)) == 1
    # No temperature: never compared, however close the rest is.
    db = Repeats.pair(;
        first_points = [(; p = 101.325, v = 998.2), (; T = 293.15, v = 1.0)],
        second_points = [(; p = 101.325, v = 998.2)],
    )
    @test length(T.points(db; duplicate = false)) == 3
    @test T.duplicates(db).skipped == 2
end

@testitem "a work is told by its DOI, or by author and year, and never guessed" setup =
    [Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    pts = Repeats.water([293.15], [998.2])
    function repeats(kw1, kw2)
        a = Repeats.system!(T.Dataset(), pts; kw1...)
        b = Repeats.system!(T.Dataset(), pts; kw2...)
        db = T.Database([
            Repeats.member("a", :thermoml, a),
            Repeats.member("b", :literature, b),
        ])
        return T.duplicates(db)
    end
    doi = (; doi = "10.5555/x", authors = ["Silva, A.", "Souza, B."], year = 2020)
    # One has a DOI and the other has not: first author and year decide.
    rep = repeats(doi, (; authors = ["Silva, Ana"], year = 2020))
    @test length(rep) == 1 && rep.how == [:authors]
    @test length(repeats(doi, (; authors = ["A. Silva"], year = 2020))) == 1
    @test length(repeats(doi, (; authors = ["Silva, A."], year = 2021))) == 0
    @test length(repeats(doi, (; authors = ["Souza, B."], year = 2020))) == 0
    # When both have a title they must agree.
    titled = (;
        doi = "10.5555/x",
        authors = ["Silva, A."],
        year = 2020,
        title = "Density of water",
    )
    other = (; authors = ["Silva, A."], year = 2020, title = "Viscosity of oil")
    @test length(repeats(titled, other)) == 0
    @test length(repeats(titled, (; other..., title = "Density of water: a study"))) == 1
    @test length(repeats(titled, (; authors = ["Silva, A."], year = 2020))) == 1
    # Two different DOIs are two works, whoever wrote them.
    @test length(
        repeats(doi, (; doi = "10.5555/y", authors = ["Silva, A."], year = 2020)),
    ) == 0
    # No information on where the points come from: different points, however close.
    @test length(repeats((;), (;))) == 0
    @test length(repeats(doi, (;))) == 0
    @test length(repeats((; authors = ["Silva, A."]), (; authors = ["Silva, A."]))) == 0
    @test length(repeats((; year = 2020), (; year = 2020))) == 0
end

@testitem "compositions are compared by compound and in one scale" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    W, S = Repeats.WATER, Repeats.SALT
    function repeats(first, second; kw1 = (;), kw2 = (;))
        a = Repeats.system!(
            T.Dataset(),
            first;
            doi = "10.5555/c",
            compounds = [(W, "water"), (S, "sodium chloride")],
            scale = "Mole fraction",
            kw1...,
        )
        b = Repeats.system!(
            T.Dataset(),
            second;
            doi = "10.5555/c",
            compounds = [(W, "water"), (S, "sodium chloride")],
            scale = "Mole fraction",
            kw2...,
        )
        db = T.Database([
            Repeats.member("a", :thermoml, a),
            Repeats.member("b", :literature, b),
        ])
        return T.duplicates(db)
    end
    pt(x1, x2; T = 298.15, v = 1100.0) = (; T, v, x = (x1, x2, NaN))
    @test length(repeats([pt(0.9, 0.1)], [pt(0.9, 0.1)])) == 1
    @test length(repeats([pt(0.9, 0.1)], [pt(0.9005, 0.1)])) == 1
    @test length(repeats([pt(0.9, 0.1)], [pt(0.91, 0.09)])) == 0
    # An amount that one side does not give is not compared.
    @test occursin("composition", only(repeats([pt(0.9, 0.1)], [pt(0.9, NaN)]).ignored))
    # Different scales are not compared: both points are kept.
    @test length(
        repeats([pt(0.9, 0.1)], [pt(0.9, 0.1)]; kw2 = (; scale = "Mass fraction")),
    ) == 0
    # The same compounds listed in the other order.
    swapped = Repeats.system!(
        T.Dataset(),
        [pt(0.1, 0.9)];
        doi = "10.5555/c",
        compounds = [(S, "sodium chloride"), (W, "water")],
        scale = "Mole fraction",
    )
    original = Repeats.system!(
        T.Dataset(),
        [pt(0.9, 0.1)];
        doi = "10.5555/c",
        compounds = [(W, "water"), (S, "sodium chloride")],
        scale = "Mole fraction",
    )
    db = T.Database([
        Repeats.member("a", :thermoml, original),
        Repeats.member("b", :literature, swapped),
    ])
    @test length(T.duplicates(db)) == 1
    # Another property or another system is never the same.
    @test length(
        repeats(
            [pt(0.9, 0.1)],
            [pt(0.9, 0.1)];
            kw2 = (; property = "Viscosity", unit = "Pa s"),
        ),
    ) == 0
end

@testitem "the same state with another value is a conflict, and both points stay" setup =
    [Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    db = Repeats.pair(;
        first_points = Repeats.water([293.15, 298.15], [998.2, 997.0]),
        second_points = Repeats.water([293.15, 298.15], [1005.0, 997.0]),
    )
    view = T.points(db; duplicate = false)
    # 298.15 is a repeated point; 293.15 differs by 0.7 %: a conflict, both kept.
    @test length(view) == 3
    c = T.conflicts(view)
    @test length(c) == 1 && c.kind == [:conflict]
    @test c.value == [998.2] && c.other_value == [1005.0]
    @test length(T.duplicates(view)) == 1
    @test T.conflicts(db).row == c.row
    # A temperature that differs by a little is another point: not a conflict.
    db = Repeats.pair(;
        first_points = Repeats.water([293.15], [998.2]),
        second_points = Repeats.water([293.16], [1005.0]),
    )
    @test isempty(T.conflicts(db)) && isempty(T.duplicates(db))
    # The same state in two works is not a conflict.
    a = Repeats.system!(T.Dataset(), Repeats.water([293.15], [998.2]); doi = "10.5555/one")
    b = Repeats.system!(T.Dataset(), Repeats.water([293.15], [1005.0]); doi = "10.5555/two")
    db =
        T.Database([Repeats.member("a", :thermoml, a), Repeats.member("b", :literature, b)])
    @test isempty(T.conflicts(db)) && length(T.points(db; duplicate = false)) == 2
    # A pressure that one side does not give is not an exact state: no conflict.
    db = Repeats.pair(;
        first_points = [(; T = 293.15, p = 101.325, v = 998.2)],
        second_points = [(; T = 293.15, v = 1005.0)],
    )
    @test isempty(T.conflicts(db))
end

@testitem "the priority decides which database keeps the point" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    pts = Repeats.water([293.15, 298.15], [998.2, 997.0])
    a = Repeats.system!(T.Dataset(), pts; doi = "10.5555/p")
    b = Repeats.system!(T.Dataset(), pts; doi = "10.5555/p")
    c = Repeats.system!(T.Dataset(), pts; doi = "10.5555/p")
    db = T.Database([
        Repeats.member("a", :thermoml, a),
        Repeats.member("b", :literature, b),
        Repeats.member("c", :user, c),
    ])
    view = T.points(db; duplicate = false)
    @test length(view) == 2 && [length(p) for p in T.parts(view)] == [2]
    winner(v) = [db.members[i].name for i in v.index]
    @test winner(view) == ["a"]
    @test length(T.duplicates(view)) == 6    # every pair of copies, kept or not
    T.set_priority!(db, "c", 0)
    @test winner(T.points(db; duplicate = false)) == ["c"]
    T.set_priority!(db, "b", -1)
    @test winner(T.points(db; duplicate = false)) == ["b"]
end

@testitem "the view says what was left out, and the report is a table" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    db = Repeats.pair(;
        first_points = Repeats.water([293.15, 298.15], [998.2, 997.0]),
        second_points = Repeats.water([293.15, 298.15], [1005.0, 997.0]),
    )
    view = T.points(db; duplicate = false)
    text = sprint(show, MIME("text/plain"), view)
    @test occursin("1 repeated points left out", text) && occursin("1 conflicts", text)
    @test !occursin(
        "left out",
        sprint(show, MIME("text/plain"), T.points(db; duplicate = true)),
    )
    rep = T.duplicates(db)
    shown = sprint(show, MIME("text/plain"), rep)
    @test occursin("DuplicateReport: 1 repeated points, 0 conflicts", shown)
    @test occursin("10.5555/Same-1", shown) && occursin("a / b", shown)
    @test occursin("0.1 K", shown) && occursin("1 work is in more than one database", shown)
    @test sprint(show, rep) == "DuplicateReport(1 repeated, 0 in conflict)"
    cols = T.Tables.columns(rep)
    @test cols.kind == [:duplicate] &&
          cols.database == ["a"] &&
          cols.other_database == ["b"]
    @test T.Tables.istable(typeof(rep))
    @test occursin("DuplicateRules(T ± 0.1 K", sprint(show, T.DEFAULT_DUPLICATE_RULES))
    # One database: nothing to compare.
    one = T.Database([Repeats.member("a", :thermoml, T.member_dataset(db, "a"))])
    @test length(T.points(one; duplicate = false)) == 2
    @test isempty(T.duplicates(one))
    @test_throws ArgumentError T.points(one; duplicate = :no)
end

@testitem "adding the data of a work that is already there warns, and shows how to see both" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    using Test: TestLogger
    using Base.CoreLogging: with_logger
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        article = (doi = "10.5555/TDBDB-001", authors = ["Silva, A."], year = 2024)
        experiment(; kw...) = (;
            components = [OwnData.WATER],
            property = "Mass density",
            unit = "kg/m3",
            temperature = [291.0, 292.0, 350.0],
            pressure = 101.325,
            value = [1001.0, 1002.0, 960.0],
            kw...,
        )
        logger = TestLogger()
        with_logger(logger) do
            T.add_reference_data!(db; reference = article, experiments = [experiment()])
        end
        warns = filter(r -> r.level == Base.CoreLogging.Warn, logger.logs)
        @test length(warns) == 1
        w = only(warns)
        @test occursin("also in \"thermoml\" (3 points)", w.message)
        @test occursin("nothing was removed", w.message)
        kw = Dict(w.kwargs)
        @test kw[:added_points] == 3 && kw[:repeated_points] == 2 && kw[:conflicts] == 0
        @test kw[:see_both] == "points(db; doi = \"10.5555/TDBDB-001\", duplicate = true)"
        @test kw[:one_copy] == "points(db; doi = \"10.5555/TDBDB-001\")"
        # What the notice shows works, and the new database wins nothing: the archive has priority.
        both = T.points(db; doi = "10.5555/tdbdb-001", duplicate = true)
        @test length(both) == 3 + 3
        @test length(T.points(db; doi = "10.5555/tdbdb-001", duplicate = false)) == 4
        @test length(T.duplicates(db; doi = "10.5555/tdbdb-001")) == 2
        # Silenced, and a work that is not elsewhere gives no notice.
        logger = TestLogger()
        with_logger(logger) do
            T.add_reference_data!(
                db;
                reference = (doi = "10.5555/TDBDB-001",),
                experiments = [experiment(temperature = [291.0, 292.0, 350.0])],
                warn_duplicates = false,
            )
            T.add_reference_data!(
                db;
                reference = (doi = "10.5555/new-work",),
                experiments = [experiment()],
            )
        end
        @test isempty(filter(r -> r.level == Base.CoreLogging.Warn, logger.logs))
    end
end

@testitem "a work found by its first author and year is noticed too" setup =
    [TwoDatabases, OwnData, Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    using Test: TestLogger
    using Base.CoreLogging: with_logger
    ds = Repeats.system!(
        T.Dataset(),
        Repeats.water([293.15, 298.15], [998.2, 997.0]);
        authors = ["Silva, Ana"],
        year = 2020,
        title = "Density of water",
    )
    db = T.Database([Repeats.member("papers", :literature, ds)])
    T.add_database!(db, "mine"; dir = mktempdir())
    logger = TestLogger()
    with_logger(logger) do
        T.add_reference_data!(
            db;
            database = "mine",
            reference = (authors = ["Silva, A."], year = 2020),
            experiments = [(
                components = [Repeats.WATER],
                property = "Mass density",
                unit = "kg/m3",
                temperature = [293.15, 298.15],
                pressure = 101.325,
                value = [998.2, 997.0],
            ),],
        )
    end
    warns = filter(r -> r.level == Base.CoreLogging.Warn, logger.logs)
    @test length(warns) == 1
    kw = Dict(only(warns).kwargs)
    @test kw[:repeated_points] == 2
    @test kw[:see_both] == "points(db; author = \"Silva\", year = 2020, duplicate = true)"
    @test length(T.points(db; author = "Silva", year = 2020, duplicate = true)) == 4
    @test length(T.points(db; author = "Silva", year = 2020, duplicate = false)) == 2
end

@testitem "the same file entered twice in a database of yours is left out, not deleted" setup =
    [Repeats] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    R = Repeats
    # Two experiments of one reference (as if the same file had been imported twice) and two
    # references with nothing that tells the work (no DOI, no author).
    function twice(; doi)
        ds = T.Dataset()
        R.system!(ds, R.water([293.15, 298.15], [998.2, 997.0]); doi)
        R.system!(ds, R.water([293.15, 298.15], [998.2, 997.0]); doi)
        return ds
    end
    for doi in ("10.5555/twice-1", "")
        db = T.Database([R.member("mine", :user, twice(; doi))])
        @test length(T.points(db; duplicate = true)) == 4
        left = T.points(db)
        @test length(left) == 2 && left.repeats !== nothing
        @test length(T.duplicates(db)) == 2
    end
    # The replicates of one experiment are not repeats of each other.
    ds = T.Dataset()
    R.system!(ds, R.water([293.15, 293.15], [998.2, 998.2]); doi = "10.5555/replicates")
    @test length(T.points(T.Database([R.member("mine", :user, ds)]))) == 2
    # The archive is not searched for repeats inside itself.
    ds = twice(; doi = "10.5555/twice-2")
    @test length(T.points(T.Database([R.member("archive", :thermoml, ds)]))) == 4
end

@testitem "a selection that is empty keeps a part, so it can be tabulated" setup = [Repeats] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    R = Repeats
    db = Repeats.pair(
        first_points = R.water([293.15], [998.2]),
        second_points = R.water([293.15], [998.2]),
    )
    v = T.points(db; temperature = (400.0, 410.0), duplicate = true)
    @test isempty(v) && length(T.table(v).value) == 0
    w = try
        T.points(db; temperature = (400.0, 410.0))
    catch err
        err
    end
    @test w isa ArgumentError || (isempty(w) && length(T.table(w).value) == 0)
end

@testitem "the key of a work is made once and follows the references that are added" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = T.Dataset()
    a = T.add_reference!(
        ds.references;
        doi = " 10.5555/TDB-A ",
        authors = ["Poe, Edgar"],
        year = 1999,
        title = "A Title",
    )
    key_a = T.work_key(ds, a)
    @test key_a.doi == "10.5555/tdb-a"
    @test key_a.surname == T.normalize_name("Poe")
    @test key_a.year == 1999
    @test key_a.label == "10.5555/TDB-A"
    @test T.work_key(ds, a) === key_a                      # the same object: made once
    # References added later get their own keys and the earlier ones are kept.
    b = T.add_reference!(ds.references; authors = ["Smith, Jo"], year = 2004)
    key_b = T.work_key(ds, b)
    @test key_b.doi == "" && key_b.label == "Smith 2004"
    @test T.work_key(ds, a) === key_a
    @test T.work_key(ds, b) === key_b
    # What is cached is what is computed.
    for r in (a, b)
        fresh = T.compute_work_key(ds, r)
        cached = T.work_key(ds, r)
        @test (cached.doi, cached.surname, cached.year, cached.title, cached.label) ==
              (fresh.doi, fresh.surname, fresh.year, fresh.title, fresh.label)
    end
    # Searches from several threads see the same keys.
    keys = Vector{Any}(undef, 8)
    Threads.@threads for i = 1:8
        keys[i] = T.work_key(ds, i % 2 == 0 ? a : b)
    end
    @test all(i -> keys[i] === (i % 2 == 0 ? key_a : key_b), 1:8)
end
