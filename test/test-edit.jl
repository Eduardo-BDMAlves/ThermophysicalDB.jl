@testitem "remove_points! shows what would go and removes the selected points only" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    using Test: TestLogger
    using Base.CoreLogging: with_logger
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 6)
        ds = T.member_dataset(db, "my_lab")
        sel = T.points(db; source = "my_lab", temperature = (293, 295))
        @test length(sel) == 3

        # without confirm nothing happens, and it says so
        logger = TestLogger()
        r = with_logger(logger) do
            T.remove_points!(db, sel)
        end
        @test r.points == 3 && !r.removed && r.databases == ["my_lab"]
        @test any(occursin("Nothing was removed", l.message) for l in logger.logs)
        @test length(T.member_dataset(db, "my_lab").measurements) == 6

        r = T.remove_points!(db, sel; confirm = true)
        @test r.removed && r.points == 3 && r.experiments == 0
        ds2 = T.member_dataset(db, "my_lab")
        @test ds2 !== ds && length(ds2.measurements) == 3
        @test sort(ds2.measurements.temperature) == [291.0, 292.0, 296.0]
        @test all(t -> !(293 <= t <= 295), ds2.measurements.temperature)
        # the selection and the experiment from before are out of date
        @test_throws ArgumentError T.remove_points!(db, sel; confirm = true)
        @test_throws ArgumentError T.add_measurement!(
            exp;
            property = "Viscosity",
            value = 1.0,
        )

        # an experiment that loses all its points goes
        all_points = T.points(db; source = "my_lab")
        r = T.remove_points!(db, all_points; confirm = true)
        @test r.points == 3 && r.experiments == 1
        ds3 = T.member_dataset(db, "my_lab")
        @test length(ds3.measurements) == 0 && length(ds3.experiments) == 0
        @test length(ds3.references) == 1
    end
end

@testitem "remove_points! refuses the archive and what is not a selection" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 3)
        everything = T.points(db; duplicate = true)
        @test T.member_dataset(db, "thermoml") !== nothing
        err = try
            T.remove_points!(db, everything; confirm = true)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("never changed", err.msg)
        @test length(T.member_dataset(db, "my_lab").measurements) == 3
        @test_throws ArgumentError T.remove_points!(db, [1, 2, 3])
        # an empty selection removes nothing
        none = T.points(db; source = "my_lab", temperature = (1, 2))
        r = T.remove_points!(db, none; confirm = true)
        @test r.points == 0 && !r.removed
    end
end

@testitem "update_points! takes a number, a vector or a function, and checks before it writes" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 4)
        ds = T.member_dataset(db, "my_lab")
        sel = T.points(db; source = "my_lab")
        before = copy(ds.measurements.value)
        m = ds.measurements

        r = T.update_points!(db, sel; pressure = 101.325)
        @test r.points == 4 && r.changed == 4
        @test all(==(101.325), m.pressure)

        r = T.update_points!(db, sel; value = v -> v * 2)
        @test r.changed == 4 && m.value ≈ before .* 2
        r = T.update_points!(db, sel; temperature = [300.0, 301.0, 302.0, 303.0])
        @test m.temperature == [300.0, 301.0, 302.0, 303.0]
        # what does not change is not counted
        @test T.update_points!(db, sel; pressure = 101.325).changed == 0

        # a function of the temperature changes the points that were selected only
        some = T.points(db; source = "my_lab", temperature = (301, 302))
        r = T.update_points!(db, some; temperature = t -> t + 0.5)
        @test r.points == 2 && r.changed == 2
        @test m.temperature == [300.0, 301.5, 302.5, 303.0]

        # a mistake changes nothing: every number is checked first
        snapshot = (copy(m.value), copy(m.temperature), copy(m.pressure))
        err(f) =
            try
                f()
                nothing
            catch e
                e
            end
        e = err(
            () ->
                T.update_points!(db, sel; value = [1.0, 2.0, NaN, 4.0], pressure = 5.0),
        )
        @test e isa ArgumentError && occursin("point 3 of the selection", e.msg)
        @test (m.value, m.temperature, m.pressure) == snapshot
        @test err(() -> T.update_points!(db, sel; temperature = -1.0)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; pressure = -1.0)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; unc = -1.0)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; unc_level = 1.5)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; x2 = 0.5)) isa ArgumentError   # one component
        @test err(() -> T.update_points!(db, sel; value = [1.0, 2.0])) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; value = v -> "a")) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; color = 1.0)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel)) isa ArgumentError
        @test err(() -> T.update_points!(db, sel; value = 1.0, on_conflict = :skip)) isa
              ArgumentError
        @test (m.value, m.temperature, m.pressure) == snapshot

        # nothing is renumbered: what is held stays valid
        @test T.add_measurement!(
            exp;
            property = "Viscosity",
            unit = "Pa s",
            value = 9e-3,
        ) == 5
        @test T.member_dataset(db, "my_lab") === ds
        # the archive is refused
        @test_throws ArgumentError T.update_points!(
            db,
            T.points(db; duplicate = true);
            pressure = 1.0,
        )
    end
end

@testitem "update_points! forgets the digits of the numbers that change and clears with NaN" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 2)
        ds = T.member_dataset(db, "my_lab")
        m = ds.measurements
        m.digits .= 0x04
        m.temperature_digits .= 0x05
        sel = T.points(db; source = "my_lab")
        T.update_points!(db, sel; value = v -> v + 1.0)
        @test all(==(T.NO_DIGITS), m.digits) && all(==(0x05), m.temperature_digits)
        T.update_points!(db, sel; pressure = 100.0)
        T.update_points!(db, sel; pressure = NaN)
        @test all(isnan, m.pressure)
        @test all(==(0x05), m.temperature_digits)
        # the uncertainty, its factor and its level
        T.update_points!(db, sel; unc = 0.01, unc_k = 2.0)
        @test all(==(0.01), m.unc) && all(==(2.0), m.unc_k)
        T.update_points!(db, sel; unc_k = nothing, unc = u -> u / 2)
        @test all(==(0.005), m.unc) && all(==(2.0), m.unc_k)
    end
end

@testitem "update_points! asks when a change makes points repeat each other" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 3)       # 291, 292, 293 K
        ds = T.member_dataset(db, "my_lab")
        m = ds.measurements
        one(t) = T.points(db; source = "my_lab", temperature = (t, t))
        # a second experiment holds the point that the change will repeat
        ref = T.find_reference(db, T.writable_member(db, "my_lab"), "10.5555/Mine-1")
        other = T.add_experiment!(
            ref;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        T.add_measurement!(
            other;
            property = "Viscosity",
            unit = "Pa s",
            value = 1e-3,
            temperature = 291.0,
        )
        # row 4 is the same as row 1 (291 K, 1e-3 Pa s)
        # the point 2 (292 K, 2e-3) becomes 291 K, 1e-3: repeats, and the session cannot ask
        sel = one(292.0)
        before = (copy(m.temperature), copy(m.value))
        e = try
            T.update_points!(db, sel; temperature = 291.0, value = 1e-3)
            nothing
        catch err
            err
        end
        @test e isa ArgumentError && occursin("repeat each other", e.msg)
        @test occursin("nothing was changed", e.msg)
        @test (m.temperature, m.value) == before

        @test_throws ArgumentError T.update_points!(
            db,
            sel;
            temperature = 291.0,
            value = 1e-3,
            on_conflict = :error,
        )
        @test (m.temperature, m.value) == before

        # asked: cancel and keep
        ask(a) =
            try
                T.update_points!(
                    db,
                    sel;
                    temperature = 291.0,
                    value = 1e-3,
                    input = IOBuffer(a),
                    output = IOBuffer(),
                )
            catch err
                err
            end
        @test ask("c\n") isa ArgumentError && (m.temperature, m.value) == before
        r = ask("k\n")
        @test r.changed == 1 && m.temperature[2] == 291.0 && m.value[2] == 1e-3

        # a change that repeats nothing is no conflict, whatever the keyword
        r = T.update_points!(db, one(293.0); temperature = 300.0, on_conflict = :error)
        @test r.changed == 1
    end
end

@testitem "removing and changing points are recorded in the log when it is saved" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 5)
        T.save_database(db, "my_lab")
        sel = T.points(db; source = "my_lab")
        T.update_points!(db, sel; value = v -> v * 2, pressure = 100.0)
        T.remove_points!(
            db,
            T.points(db; source = "my_lab", temperature = (291, 292));
            confirm = true,
        )
        events = T.audit_log(db; database = "my_lab")
        @test "points_updated" ∉ events.event && "points_removed" ∉ events.event
        T.save_database(db, "my_lab")
        events = T.audit_log(db; database = "my_lab")
        i = findlast(==("points_updated"), events.event)
        j = findlast(==("points_removed"), events.event)
        @test i !== nothing && j !== nothing && i < j
        @test occursin("columns=value,pressure points=5", events.detail[i])
        @test occursin("points=2", events.detail[j])
        @test T.verify_audit_log(db; database = "my_lab").ok == [true]
        # the saved database has the changes
        db2 = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_member!(db2, only(T.discover_members(joinpath(dir, "databases"))))
        ds = T.member_dataset(db2, "my_lab")
        @test length(ds.measurements) == 3 && all(==(100.0), ds.measurements.pressure)
    end
end
