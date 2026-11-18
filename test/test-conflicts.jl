@testitem "points that are already in the database: skip, replace, keep or refuse" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    article = (doi = "10.5555/Conf-1", authors = ["Silva, A."], year = 2024)
    experiment(; kw...) = (;
        components = [OwnData.WATER],
        property = "Mass density",
        unit = "kg/m3",
        temperature = [291.0, 292.0, 350.0],
        pressure = 101.325,
        value = [1001.0, 1002.0, 960.0],
        kw...,
    )
    fresh(dir) = begin
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        T.add_reference_data!(db; reference = article, experiments = [experiment()])
        db
    end
    npoints(db) = length(T.member_dataset(db, "my_lab").measurements)
    mktempdir() do dir
        db = fresh(dir)
        @test npoints(db) == 3
        # one new point (365 K), two that are already there
        more = [
            experiment(
                temperature = [291.0, 292.0, 365.0],
                value = [1001.0, 1002.0, 950.0],
            ),
        ]

        # refused by default in a session that cannot ask, and nothing is left behind
        err = try
            T.add_reference_data!(db; reference = article, experiments = more)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("already in the database", err.msg)
        @test occursin("on_conflict", err.msg) && occursin("nothing was added", err.msg)
        @test npoints(db) == 3
        @test_throws ArgumentError T.add_reference_data!(
            db;
            reference = article,
            experiments = more,
            on_conflict = :error,
        )
        @test npoints(db) == 3
        @test_throws ArgumentError T.add_reference_data!(
            db;
            reference = article,
            experiments = more,
            on_conflict = :nonsense,
        )

        # skip: only the point that is not there is added
        r = T.add_reference_data!(
            db;
            reference = article,
            experiments = more,
            on_conflict = :skip,
            warn_duplicates = false,
        )
        @test r.points == 1 && npoints(db) == 4
        ds = T.member_dataset(db, "my_lab")
        @test sort(ds.measurements.temperature) == [291.0, 292.0, 350.0, 365.0]
        @test r.reference isa T.ReferenceRef && r.reference.dataset === ds
        @test only(r.experiments).dataset === ds

        # replace: the old points that the new ones repeat go, the new ones stay
        db = fresh(dir * "-b")
        r = T.add_reference_data!(
            db;
            reference = article,
            experiments = [experiment(value = [1001.0, 1002.0, 960.0], purpose = "second")],
            on_conflict = :replace,
            warn_duplicates = false,
        )
        @test r.points == 3 && npoints(db) == 3
        ds = T.member_dataset(db, "my_lab")
        @test length(ds.experiments) == 1
        @test T.live_dataset(r.reference) === ds

        # keep: both stay (the notice is the warning)
        db = fresh(dir * "-c")
        T.add_reference_data!(
            db;
            reference = article,
            experiments = more,
            on_conflict = :keep,
            warn_duplicates = false,
        )
        @test npoints(db) == 6

        # a point that is not in the database is no conflict, whatever the keyword
        db = fresh(dir * "-d")
        T.add_reference_data!(
            db;
            reference = article,
            experiments = [
                experiment(temperature = [300.0, 301.0], value = [996.0, 995.0]),
            ],
            on_conflict = :error,
            warn_duplicates = false,
        )
        @test npoints(db) == 5
        T.add_reference_data!(
            db;
            reference = (doi = "10.5555/Conf-2",),
            experiments = [experiment()],
            warn_duplicates = false,
        )
        @test npoints(db) == 8
    end
end

@testitem "the user is asked what to do with the points that are already there" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    article = (doi = "10.5555/Ask-1",)
    experiment() = (;
        components = [OwnData.WATER],
        property = "Mass density",
        unit = "kg/m3",
        temperature = [291.0, 292.0],
        pressure = 101.325,
        value = [1001.0, 1002.0],
    )
    npoints(db) = length(T.member_dataset(db, "my_lab").measurements)
    function ask(answer)
        mktempdir() do dir
            db = OwnData.archive_only(joinpath(dir, "thermoml"))
            T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
            T.add_reference_data!(db; reference = article, experiments = [experiment()])
            out = IOBuffer()
            result = try
                T.add_reference_data!(
                    db;
                    reference = article,
                    experiments = [experiment()],
                    input = IOBuffer(answer),
                    output = out,
                    warn_duplicates = false,
                )
            catch e
                e
            end
            return result, npoints(db), String(take!(out)), T.member_dataset(db, "my_lab")
        end
    end
    result, n, text, _ = ask("s\n")
    @test result.points == 0 && n == 2 && occursin("already in the database", text)
    result, n, _, _ = ask("r\n")
    @test result.points == 2 && n == 2
    result, n, _, _ = ask("k\n")
    @test result.points == 2 && n == 4
    result, n, _, _ = ask("c\n")
    @test result isa ArgumentError && n == 2
    # an answer that is not one is asked again
    result, n, text, _ = ask("x\ns\n")
    @test result.points == 0 && n == 2 && occursin("Not a valid answer", text)
end

@testitem "replacing points is recorded in the log when it is saved" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        article = (doi = "10.5555/Log-1",)
        experiment() = (;
            components = [OwnData.WATER],
            property = "Mass density",
            unit = "kg/m3",
            temperature = [291.0, 292.0],
            pressure = 101.325,
            value = [1001.0, 1002.0],
        )
        T.add_reference_data!(db; reference = article, experiments = [experiment()])
        T.save_database(db, "my_lab")
        T.add_reference_data!(
            db;
            reference = article,
            experiments = [experiment()],
            on_conflict = :replace,
            warn_duplicates = false,
        )
        T.save_database(db, "my_lab")
        events = T.audit_log(db; database = "my_lab")
        i = findlast(==("points_replaced"), events.event)
        @test i !== nothing && occursin("reference=10.5555/Log-1", events.detail[i])
        @test T.verify_audit_log(db; database = "my_lab").ok == [true]
    end
end
