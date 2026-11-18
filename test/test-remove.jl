@testitem "remove_database! moves a saved database to a temporary folder, with its log" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 4)
        T.save_database(db, "my_lab")
        folder = joinpath(dir, "databases", "my_lab")
        @test isdir(folder)
        trash = joinpath(dir, "trash")

        moved = T.remove_database!(db, "my_lab"; to = trash)
        @test startswith(moved, trash) && isdir(moved)
        @test !isdir(folder)
        @test isfile(joinpath(moved, T.MEMBER_META)) &&
              isfile(joinpath(moved, T.MEMBER_FILE))
        @test isempty(filter(m -> m.kind === :user, T.members(db)))
        @test_throws ArgumentError T.member_dataset(db, "my_lab")

        # the removal is the last thing in the log that was moved, and the chain is intact
        log = joinpath(moved, basename(T.audit_log_path(folder)))
        lines = readlines(log)
        @test any(occursin("database_removed", l) for l in lines)
        @test any(occursin("database_remove_started", l) for l in lines)
        ok = T.walk_audit_log(log, _ -> nothing)[1]
        @test ok

        # the folder is not found by database() any more
        @test isempty(T.discover_members(joinpath(dir, "databases")))

        # a second removal of the same name to the same folder gets a name of its own
        db2, _ = AuditData.lab(dir, 2)
        T.save_database(db2, "my_lab")
        again = T.remove_database!(db2, "my_lab"; to = trash)
        @test again != moved && isdir(again)
    end
end

@testitem "remove_database! refuses what would lose points and what is not valid" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 3)
        trash = joinpath(dir, "trash")

        # never saved: the points exist only in memory
        err = try
            T.remove_database!(db, "my_lab"; to = trash)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("not saved", err.msg)
        @test length(T.members(db)) == 2

        # saved, then edited: the new points would be lost
        T.save_database(db, "my_lab")
        AuditData.add_points!(exp, 2)
        @test_throws ArgumentError T.remove_database!(db, "my_lab"; to = trash)
        @test isdir(joinpath(dir, "databases", "my_lab"))

        # the archive is never removed, and nothing is removed if one name is wrong
        @test_throws ArgumentError T.remove_database!(db, "thermoml"; to = trash)
        @test_throws ArgumentError T.remove_database!(db, ["my_lab", "nothing"]; to = trash)
        @test_throws ArgumentError T.remove_database!(db, ["my_lab", "my_lab"]; to = trash)
        @test_throws ArgumentError T.remove_database!(db, String[]; to = trash)
        @test length(T.members(db)) == 2

        # force says that they can go; a database that only lived in memory returns ""
        @test T.remove_database!(db, "my_lab"; force = true, to = trash) != ""
        T.add_database!(db, "scratch"; dir = joinpath(dir, "databases"))
        @test T.remove_database!(db, "scratch"; to = trash) == ""
        @test length(T.members(db)) == 1
    end
end

@testitem "remove_database! takes several databases at once" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 2)
        T.add_database!(db, "other"; dir = joinpath(dir, "databases"))
        T.save_database(db, "my_lab")
        T.save_database(db, "other")
        moved = T.remove_database!(db, ["my_lab", "other"]; to = joinpath(dir, "trash"))
        @test length(moved) == 2 && all(isdir, moved)
        @test length(T.members(db)) == 1
    end
end

@testitem "clear_database! empties a database and keeps its identity until it is saved" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 5)
        T.save_database(db, "my_lab")
        created = T.created_at(db, "my_lab")
        T.set_priority!(db, "my_lab", 7)
        @test length(T.member_dataset(db, "my_lab").measurements) == 5

        m = T.clear_database!(db, "my_lab")
        @test m.name == "my_lab" && m.priority == 7 && m.kind === :user
        ds = T.member_dataset(db, "my_lab")
        @test length(ds.measurements) == 0 && length(ds.references) == 0
        @test T.created_at(db, "my_lab") == created
        @test T.modified_at(db, "my_lab") >= created
        @test length(T.members(db)) == 2

        # the folder is not touched until the save, and the new data can be added at once
        @test T.discover_members(joinpath(dir, "databases"))[1].name == "my_lab"
        db2 = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_member!(db2, only(T.discover_members(joinpath(dir, "databases"))))
        @test length(T.member_dataset(db2, "my_lab").measurements) == 5

        ref = T.add_reference!(db; doi = "10.5555/New-1", year = 2025)
        e2 = T.add_experiment!(
            ref;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        AuditData.add_points!(e2, 2)
        T.save_database(db, "my_lab")
        db3 = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_member!(db3, only(T.discover_members(joinpath(dir, "databases"))))
        @test length(T.member_dataset(db3, "my_lab").measurements) == 2
        @test T.verify_audit_log(db; database = "my_lab").ok == [true]

        @test_throws ArgumentError T.clear_database!(db, "thermoml")
        @test_throws ArgumentError T.clear_database!(db, "nothing")
    end
end

@testitem "remove_reference! removes one article and leaves the others as they were" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 5)
        ref_b = T.add_reference!(
            db;
            doi = "10.5555/Other-2",
            year = 2022,
            authors = ["Lima, B."],
        )
        exp_b = T.add_experiment!(
            ref_b;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        T.add_measurement!(
            exp_b;
            property = "Viscosity",
            unit = "Pa s",
            value = 0.5,
            temperature = 300.0,
            unc = 0.01,
            unc_temperature = 0.05,
        )
        AuditData.add_points!(exp_b, 2)
        ds = T.member_dataset(db, "my_lab")
        before = length(ds.measurements)
        @test before == 8
        b_values = copy(ds.measurements.value[6:8])

        removed = T.remove_reference!(db, "10.5555/Mine-1")
        @test removed == (references = 1, experiments = 1, points = 5)
        ds2 = T.member_dataset(db, "my_lab")
        @test ds2 !== ds
        @test length(ds2.references) == 1 && ds2.references.doi == ["10.5555/Other-2"]
        @test length(ds2.experiments) == 1 && ds2.experiments.reference == [1]
        @test ds2.measurements.value == b_values
        @test ds2.measurements.experiment == [1, 1, 1]
        # what hangs from a point moved with it, and what hung from the removed article is gone
        @test all(==(1), ds2.uncertainties.row) && !isempty(ds2.uncertainties.row)
        @test ds.uncertainties.row == [6, 6]    # before: the sixth point of the table
        @test length(ds2.uncertainties) == length(ds.uncertainties)
        @test ds2.references.index["10.5555/Other-2"] == 1

        # the old data are no longer there, and the rest answers as a database built without them
        @test isempty(T.points(db; doi = "10.5555/Mine-1"))
        @test length(T.points(db; doi = "10.5555/Other-2")) == 3

        # a reference or an experiment held from before is refused, not used on other rows
        err = try
            T.add_experiment!(ref_b; components = ["water"], compounds = OwnData.compound_db())
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("no longer valid", err.msg)
        @test_throws ArgumentError T.add_measurement!(
            exp_b;
            property = "Viscosity",
            unit = "Pa s",
            value = 1.0,
        )
        @test occursin("no longer valid", sprint(show, ref_b))

        # the same article can be added again and the new references work
        again = T.add_reference!(db; doi = "10.5555/Other-2")
        @test again.id == 1
        T.add_experiment!(again; components = ["water"], compounds = OwnData.compound_db())

        # the other things are refused with a message
        @test_throws ArgumentError T.remove_reference!(db, "10.9999/none")
        @test_throws ArgumentError T.remove_reference!(
            db,
            "10.5555/Other-2";
            database = "thermoml",
        )
    end
end

@testitem "remove_reference! is recorded in the log when it is saved, and survives a reload" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 4)
        ref_b = T.add_reference!(db; doi = "10.5555/Other-2", year = 2022)
        exp_b = T.add_experiment!(
            ref_b;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        AuditData.add_points!(exp_b, 3)
        T.save_database(db, "my_lab")
        T.remove_reference!(db, "10.5555/Mine-1")
        # nothing is written until the save
        events = T.audit_log(db; database = "my_lab")
        @test "reference_removed" ∉ events.event
        T.save_database(db, "my_lab")
        events = T.audit_log(db; database = "my_lab")
        i = findlast(==("reference_removed"), events.event)
        @test i !== nothing
        @test occursin("reference=10.5555/Mine-1", events.detail[i])
        @test occursin("points=4", events.detail[i])
        @test findlast(==("database_saved"), events.event) > i
        @test T.verify_audit_log(db; database = "my_lab").ok == [true]

        db2 = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_member!(db2, only(T.discover_members(joinpath(dir, "databases"))))
        ds = T.member_dataset(db2, "my_lab")
        @test length(ds.measurements) == 3 && ds.references.doi == ["10.5555/Other-2"]
        @test length(T.points(db2; doi = "10.5555/Other-2")) == 3

        # the same for a database that is cleared
        T.clear_database!(db, "my_lab")
        T.save_database(db, "my_lab")
        events = T.audit_log(db; database = "my_lab")
        @test "database_cleared" in events.event
    end
end
