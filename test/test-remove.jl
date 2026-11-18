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
