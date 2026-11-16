@testmodule ShareData begin
    using ThermophysicalDB: ThermophysicalDB
    using CodecZlib: GzipDecompressorStream
    using Tar: Tar
    using ..TwoDatabases: TwoDatabases
    using ..OwnData: OwnData
    using ..AuditData: AuditData
    const T = ThermophysicalDB

    # Another computer: its own archive and its own folder of databases.
    function computer(dir)
        root = joinpath(dir, "other")
        return OwnData.archive_only(joinpath(root, "thermoml")), joinpath(root, "databases")
    end

    # A second database with one reference and a few points.
    function second(db, dir, name, n)
        T.add_database!(db, name; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(db; database = name, doi = "10.5555/Second-1", year = 2023)
        exp = T.add_experiment!(
            ref;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        AuditData.add_points!(exp, n)
        return exp
    end

    # Unpack a `.tdb`, let `edit(folder)` change what is inside, and pack it again.
    function tamper(file, edit)
        work = mktempdir()
        tarball = joinpath(work, "in.tar")
        open(file) do io
            open(out -> write(out, read(GzipDecompressorStream(io))), tarball, "w")
        end
        folder = joinpath(work, "files")
        Tar.extract(tarball, folder)
        edit(folder)
        target = joinpath(work, "out.tdb")
        T.pack_share(folder, target)
        return target
    end

    # The same file with the digest of one file of the manifest brought up to date.
    function refresh_digest(folder, name, file, key)
        manifest = joinpath(folder, "manifest.toml")
        data = T.TOML.parsefile(manifest)
        entry = only(filter(e -> e["name"] == name, data["databases"]))
        entry[key] = T.file_sha256(joinpath(folder, name, file))
        open(io -> T.TOML.print(io, data), manifest, "w")
    end

    saved(db, name) = length(T.member_dataset(db, name).measurements)
end

@testitem "a database goes to another computer with its log, and the import is recorded" setup =
    [TwoDatabases, OwnData, AuditData, ShareData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 5)
        T.save_database(db, "my_lab")
        file = joinpath(dir, "hexane.tdb")
        out = T.export_database(db, "my_lab", file)
        @test isfile(file) && out.bytes == filesize(file) && length(out.sha256) == 64
        @test out.databases[1].name == "my_lab" && out.databases[1].points == 5

        # the export is in the log of the source, and the copy that travels already has it
        events = T.audit_log(db; database = "my_lab")
        @test "database_export_started" in events.event &&
              "database_exported" in events.event
        @test occursin(
            "file=hexane.tdb",
            events.detail[findlast(==("database_exported"), events.event)],
        )
        @test T.verify_audit_log(db; database = "my_lab").ok == [true]

        # another computer
        db2, dest = ShareData.computer(dir)
        members = T.import_database!(db2, file; dir = dest)
        @test only(members).name == "my_lab" && only(members).kind === :user
        @test only(members).persistent
        @test ShareData.saved(db2, "my_lab") == 5
        @test length(T.discover_members(dest)) == 1    # saved in a folder that database() opens

        # what was imported is recorded with where it came from
        log2 = T.audit_log(db2; database = "my_lab")
        i = findlast(==("database_imported"), log2.event)
        detail = log2.detail[i]
        @test occursin("source=$(out.databases[1].audit_uuid)", detail)
        @test occursin("source_lines=$(out.databases[1].audit_lines)", detail)
        @test occursin("bundle_sha256=$(out.sha256)", detail)
        @test occursin("on_conflict=error", detail)
        @test log2.after[i] == events.after[findlast(==("database_exported"), events.event)]
        @test T.verify_audit_log(db2; database = "my_lab").ok == [true]

        # each computer keeps a log of its own, and the one that came is kept whole
        own = T.verify_audit_log(db2; database = "my_lab")
        @test only(own.uuid) != out.databases[1].audit_uuid
        kept = readdir(joinpath(dest, "my_lab", "imports"); join = true)
        @test length(kept) == 1 &&
              occursin(out.databases[1].audit_uuid, basename(only(kept)))
        ok, uuid, lines, head, _... = T.walk_audit_log(only(kept), _ -> nothing)
        @test ok &&
              uuid == out.databases[1].audit_uuid &&
              lines == out.databases[1].audit_lines
        @test any(occursin("database_exported", l) for l in readlines(only(kept)))
    end
end

@testitem "only what was saved is exported, and a database that was never saved is refused" setup =
    [TwoDatabases, OwnData, AuditData, ShareData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 3)
        file = joinpath(dir, "x.tdb")
        err = try
            T.export_database(db, "my_lab", file)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("has not been saved", err.msg)
        @test !isfile(file)

        T.save_database(db, "my_lab")
        AuditData.add_points!(exp, 2)               # in memory only
        @test_logs (:warn, r"changes that were not saved") match_mode = :any T.export_database(
            db,
            "my_lab",
            file,
        )
        db2, dest = ShareData.computer(dir)
        T.import_database!(db2, file; dir = dest)
        @test ShareData.saved(db2, "my_lab") == 3      # not the 5 of the memory
        @test length(T.member_dataset(db, "my_lab").measurements) == 5

        # the archive is never exported, a file is not overwritten by accident
        @test_throws ArgumentError T.export_database(db, "thermoml", joinpath(dir, "a.tdb"))
        @test_throws ArgumentError T.export_database(db, "my_lab", file)
        @test T.export_database(db, "my_lab", file; overwrite = true).bytes > 0
        @test_throws ArgumentError T.export_database(db, "missing", joinpath(dir, "b.tdb"))
    end
end

@testitem "a database that exists is not overwritten unless asked" setup =
    [TwoDatabases, OwnData, AuditData, ShareData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 4)
        T.save_database(db, "my_lab")
        file = joinpath(dir, "x.tdb")
        T.export_database(db, "my_lab", file)
        db2, dest = ShareData.computer(dir)
        T.import_database!(db2, file; dir = dest)

        err = try
            T.import_database!(db2, file; dir = dest)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("on_conflict = :rename", err.msg)
        @test length(T.members(db2)) == 2          # the archive and the database

        both = T.import_database!(db2, file; dir = dest, on_conflict = :rename)
        @test only(both).name == "my_lab-2"
        @test isfile(joinpath(dest, "my_lab-2", "member.toml"))
        @test T.TOML.parsefile(joinpath(dest, "my_lab-2", "member.toml"))["name"] ==
              "my_lab-2"
        @test ShareData.saved(db2, "my_lab") == ShareData.saved(db2, "my_lab-2") == 4

        # a new version of the same database replaces the old one; both imports are in the log
        AuditData.add_points!(exp, 3)
        T.save_database(db, "my_lab")
        T.export_database(db, "my_lab", file; overwrite = true)
        T.import_database!(db2, file; dir = dest, on_conflict = :replace)
        @test ShareData.saved(db2, "my_lab") == 7
        log2 = T.audit_log(db2; database = "my_lab")
        @test count(==("database_imported"), log2.event) == 2
        @test occursin(
            "replaced=true",
            log2.detail[findlast(==("database_imported"), log2.event)],
        )
        @test T.verify_audit_log(db2; database = "my_lab").ok == [true]
        @test length(readdir(joinpath(dest, "my_lab", "imports"))) == 2

        # what exists only in memory is not thrown away by a replacement
        AuditData.add_points!(
            T.add_experiment!(
                T.add_reference!(db2; database = "my_lab", doi = "10.5555/Later-1"),
                components = ["water"],
                compounds = OwnData.compound_db(),
            ),
            1,
        )
        err = try
            T.import_database!(db2, file; dir = dest, on_conflict = :replace)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("were not saved", err.msg)
        @test_throws ArgumentError T.import_database!(
            db2,
            file;
            dir = dest,
            on_conflict = :merge,
        )
    end
end

@testitem "an export that was changed, damaged or is not one is refused before anything is written" setup =
    [TwoDatabases, OwnData, AuditData, ShareData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 4)
        T.save_database(db, "my_lab")
        file = joinpath(dir, "x.tdb")
        T.export_database(db, "my_lab", file)
        db2, dest = ShareData.computer(dir)

        # The text of the refusal, or "" when the import was accepted or failed another way.
        function refusal(path)
            try
                T.import_database!(db2, path; dir = dest)
                return ""
            catch e
                return e isa ArgumentError ? e.msg : sprint(showerror, e)
            end
        end
        refused(path, pattern) = occursin(pattern, refusal(path))

        # the data were changed
        changed =
            ShareData.tamper(file, f -> write(joinpath(f, "my_lab", "dataset.jld2"), "x"))
        @test refused(changed, r"data of \"my_lab\" does not match the manifest")

        # the log was rewritten with its hashes recomputed: the digest of the file shows it
        forged = ShareData.tamper(
            file,
            f -> AuditData.forge(
                joinpath(f, "my_lab", "audit.log"),
                (i, body) -> (body[5] = "edited"; body),
            ),
        )
        @test refused(forged, r"audit log of \"my_lab\" does not match the manifest")

        # a line edited without the hashes recomputed, with the digest of the manifest brought up to date
        edited = ShareData.tamper(
            file,
            function (f)
                path = joinpath(f, "my_lab", "audit.log")
                text = readlines(path)
                text[end] = replace(text[end], "my_lab" => "other")
                AuditData.put(path, text)
                ShareData.refresh_digest(f, "my_lab", "audit.log", "audit_sha256")
            end,
        )
        @test occursin(r"damaged", refusal(edited))

        # not a .tdb, an entry that does not belong, and a newer format
        garbage = joinpath(dir, "garbage.tdb")
        write(garbage, "this is not an export")
        @test refused(garbage, r"is not a \.tdb file")
        extra = ShareData.tamper(file, f -> write(joinpath(f, "notes.txt"), "x"))
        @test refused(extra, r"notes\.txt")
        newer = ShareData.tamper(file, function (f)
            manifest = joinpath(f, "manifest.toml")
            data = T.TOML.parsefile(manifest)
            data["version"] = 99
            open(io -> T.TOML.print(io, data), manifest, "w")
        end)
        @test refused(newer, r"format version 99")
        @test_throws ArgumentError T.import_database!(
            db2,
            joinpath(dir, "nothing.tdb");
            dir = dest,
        )

        # nothing was written by the refusals
        @test !isdir(dest) || isempty(readdir(dest))
        @test length(T.members(db2)) == 1
    end
end

@testitem "several databases go in one file, and one can be taken with another name" setup =
    [TwoDatabases, OwnData, AuditData, ShareData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, exp = AuditData.lab(dir, 4)
        ShareData.second(db, dir, "articles", 2)
        T.save_database(db, "my_lab")
        T.save_database(db, "articles")
        file = joinpath(dir, "lab.tdb")
        out = T.export_database(db, nothing, file)
        @test sort([d.name for d in out.databases]) == ["articles", "my_lab"]

        db2, dest = ShareData.computer(dir)
        @test_throws ArgumentError T.import_database!(db2, file; dir = dest, name = "x")
        @test_throws ArgumentError T.import_database!(db2, file; dir = dest, only = "nope")
        members = T.import_database!(
            db2,
            file;
            dir = dest,
            only = "articles",
            name = "articles_home",
        )
        @test only(members).name == "articles_home"
        @test ShareData.saved(db2, "articles_home") == 2
        @test T.verify_audit_log(db2; database = "articles_home").ok == [true]
        @test !isdir(joinpath(dest, "my_lab"))

        both = T.import_database!(db2, file; dir = dest)
        @test sort([m.name for m in both]) == ["articles", "my_lab"]
        @test length(T.discover_members(dest)) == 3
    end
end
