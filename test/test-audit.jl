@testmodule AuditData begin
    using ThermophysicalDB: ThermophysicalDB
    using ..TwoDatabases: TwoDatabases
    using ..OwnData: OwnData
    const T = ThermophysicalDB

    # A database of the user with one reference, one experiment and `n` points, in `dir`.
    function lab(dir, n)
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(db; doi = "10.5555/Mine-1", year = 2024)
        exp = T.add_experiment!(
            ref;
            components = ["water"],
            compounds = OwnData.compound_db(),
        )
        add_points!(exp, n)
        return db, exp
    end

    function add_points!(exp, n)
        for k = 1:n
            T.add_measurement!(
                exp;
                property = "Viscosity",
                unit = "Pa s",
                value = k * 1e-3,
                temperature = 290.0 + k,
            )
        end
    end

    # The text of a log as lines, and back.
    lines(path) = readlines(path)
    put(path, text) = write(path, join(text, '\n') * '\n')

    # What a person who knows the format could do: rewrite a whole log with the hashes recomputed.
    function forge(path, edit)
        old = readlines(path)
        previous = ""
        out = String[]
        for (i, text) in enumerate(old)
            fields = split(text, '\t')
            body = fields[1:(end-1)]
            i > 1 && (body = edit(i, body))
            line = T.audit_line(previous, body)
            push!(out, line)
            previous = String(last(split(line, '\t')))
        end
        put(path, out)
    end
end

@testitem "the log is a chain of hashes that finds an edit from outside" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        path = joinpath(dir, "audit.log")
        T.audit_record!(
            dir,
            "database_saved",
            "a";
            sha256 = repeat("1", 64),
            counts = "1:2:3",
        )
        T.audit_record!(dir, "priority_changed", "a"; detail = "priority=0")
        T.audit_record!(
            dir,
            "database_saved",
            "a";
            sha256 = repeat("2", 64),
            counts = "1:2:5",
        )
        text = AuditData.lines(path)
        @test length(text) == 4 && startswith(text[1], "#tdb-audit\t1\t")
        # `before` is the `after` of the line before; a change that counts nothing keeps the counts.
        f = [split(l, '\t') for l in text[2:end]]
        @test [x[7] for x in f] == ["-", "1:2:3", "1:2:3"]
        @test [x[8] for x in f] == ["1:2:3", "1:2:3", "1:2:5"]
        @test f[2][5] == "priority=0" && f[2][6] == "-"
        check(p) = T.verify_audit_dir(dirname(p), nothing)
        @test check(path)[1] && check(path)[3] == 3
        # A field that is changed breaks its line.
        edited = copy(text)
        edited[3] = replace(edited[3], "priority_changed" => "database_saved")
        AuditData.put(path, edited)
        ok, _, lines, _, line, problem = check(path)
        @test !ok && line == 3 && occursin("hash", problem)
        # A line that is removed or inserted breaks the one after it.
        AuditData.put(path, text[[1, 2, 4]])
        @test !check(path)[1] && check(path)[5] == 3
        AuditData.put(path, [text[1:3]; text[3]; text[4]])
        @test !check(path)[1]
        # The header and an empty file are checked too.
        AuditData.put(path, [replace(text[1], "tdb-audit" => "other"); text[2:end]])
        @test !check(path)[1] && check(path)[5] == 1
        write(path, "")
        @test !check(path)[1]
        # Tabs and line breaks cannot split a line.
        AuditData.put(path, text)
        T.audit_record!(dir, "database_saved", "a\tb\nc")
        @test check(path)[1] && check(path)[3] == 4
        @test AuditData.lines(path)[end] |> l -> count(==('\t'), l) == 8
    end
end

@testitem "saving, changing the priority and installing are recorded, in memory edits are not" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        withenv("THERMOPHYSICALDB_DATA_DIR" => joinpath(dir, "data")) do
            db, exp = AuditData.lab(dir, 2)
            lab_dir = joinpath(dir, "databases", "my_lab")
            # Nothing on disk, nothing logged.
            @test !isfile(joinpath(lab_dir, "audit.log"))
            T.set_priority!(db, "my_lab", 1)
            @test !isfile(joinpath(lab_dir, "audit.log"))
            path = T.save_database(db, "my_lab")
            AuditData.add_points!(exp, 1)    # a change in memory only
            @test length(T.audit_log(db; database = "my_lab").seq) == 2    # started, saved
            T.save_database(db, "my_lab")
            T.set_priority!(db, "my_lab", 0)
            events = T.audit_log(db; database = "my_lab")
            @test events.event == [
                "database_save_started",
                "database_saved",
                "database_save_started",
                "database_saved",
                "priority_changed",
            ]
            @test events.object == fill("my_lab", 5) && events.seq == 1:5
            @test events.after[2] == "1:1:2" && events.before[3] == "1:1:2"
            @test events.after[4] == "1:1:3" && events.after[5] == "1:1:3"
            @test events.detail[5] == "priority=0"
            @test events.sha256[4] == bytes2hex(open(ThermophysicalDB.SHA.sha256, path))
            @test events.sha256[2] != events.sha256[4]
            # The identifier of the log is kept next to it, and in the log.
            id = ThermophysicalDB.TOML.parsefile(joinpath(lab_dir, "audit.toml"))["uuid"]
            @test split(first(eachline(joinpath(lab_dir, "audit.log"))), '\t')[3] == id
            @test T.verify_audit_log(db).ok == [true]

            # The archive that is installed.
            tdir = T.thermoml_dir(; create = true)
            T.write_manifest(tdir, TwoDatabases.manifest())
            e = T.audit_log(db; database = "thermoml")
            @test e.event == ["archive_installed"] && e.object == ["2099-01-01"]
            @test e.sha256 == [repeat("d", 64)] &&
                  startswith(e.detail[1], "source=https://")
            # The compounds that are saved.
            cdb = OwnData.compound_db()
            T.save_compounds(cdb; dir = T.compounds_dir())
            @test T.audit_log(db; database = "compounds").event ==
                  ["compounds_save_started", "compounds_saved"]
            @test T.verify_audit_log(db).scope == ["thermoml", "compounds", "my_lab"]
            @test all(T.verify_audit_log(db).ok)
            # The filters of the table.
            all_events = T.audit_log(db)
            @test length(all_events.seq) == 8
            @test T.audit_log(db; event = "database_saved").object == ["my_lab", "my_lab"]
            @test length(
                T.audit_log(db; event = ["database_saved", "compounds_saved"]).seq,
            ) == 3
            @test isempty(T.audit_log(db; since = "2999-01-01").seq)
            @test length(T.audit_log(db; since = "2000-01-01T00:00:00Z").seq) == 8
            @test_throws ArgumentError T.audit_log(db; database = "nope")
        end
    end
end

@testitem "a log that is removed or swapped is noticed, and a checkpoint proves that it was not rewritten" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        withenv("THERMOPHYSICALDB_DATA_DIR" => joinpath(dir, "data")) do
            db, exp = AuditData.lab(dir, 2)
            T.save_database(db, "my_lab")
            AuditData.add_points!(exp, 2)
            T.save_database(db, "my_lab")
            lab_dir = joinpath(dir, "databases", "my_lab")
            path = joinpath(lab_dir, "audit.log")
            keep = read(path)

            cp = T.audit_checkpoint(db; database = "my_lab")
            @test cp.scope == "my_lab" && cp.lines == 4 && length(cp.head) == 64
            @test T.verify_audit_log(db; database = "my_lab", checkpoint = cp).ok == [true]
            @test T.verify_audit_log(
                db;
                database = "my_lab",
                checkpoint = (lines = 1, head = "x" ^ 64),
            ).ok == [false]
            @test_throws ArgumentError T.verify_audit_log(db; checkpoint = cp)

            # A log that was rewritten from the start, with every hash recomputed, is a valid
            # chain, but not the one that was written down.
            AuditData.forge(
                path,
                (i, body) -> i == 3 ? replace.(body, "1:1:2" => "1:1:9") : body,
            )
            @test T.verify_audit_log(db; database = "my_lab").ok == [true]
            r = T.verify_audit_log(db; database = "my_lab", checkpoint = cp)
            @test r.ok == [false] && occursin("rewritten", only(r.problem))
            @test_throws ArgumentError T.audit_checkpoint(db; database = "nope")

            # Another log, with another identifier, is not the one that belongs to the data.
            write(path, keep)
            other = mktempdir()
            T.audit_record!(other, "database_saved", "x")
            cp_other = read(joinpath(other, "audit.log"))
            write(path, cp_other)
            r = T.verify_audit_log(db; database = "my_lab")
            @test r.ok == [false] && occursin("not the one", only(r.problem))
            # A log that was removed, while its identifier is still there.
            rm(path)
            r = T.verify_audit_log(db; database = "my_lab")
            @test r.ok == [false] && occursin("missing", only(r.problem))
            # The next change starts it again, with the same identifier, and says so.
            id = ThermophysicalDB.TOML.parsefile(joinpath(lab_dir, "audit.toml"))["uuid"]
            T.save_database(db, "my_lab")
            e = T.audit_log(db; database = "my_lab")
            @test e.event == ["log_recreated", "database_save_started", "database_saved"]
            @test T.verify_audit_log(db; database = "my_lab").ok == [true]
            @test T.verify_audit_log(db; database = "my_lab").uuid == [id]
        end
    end
end

@testitem "failures, rejections and unreadable databases are recorded, and a save has a start and an end" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    using Logging: Logging
    T = ThermophysicalDB
    events(dir) = [split(l, '\t')[3] for l in readlines(joinpath(dir, "audit.log"))[2:end]]
    mktempdir() do dir
        withenv("THERMOPHYSICALDB_DATA_DIR" => joinpath(dir, "data")) do
            db, exp = AuditData.lab(dir, 2)
            member = last(T.members(db))
            lab_dir = dirname(member.path)

            # A save that fails: the temporary file is taken by a folder with something in it.
            mkpath(joinpath(member.path * ".part", "x"))
            @test_throws Exception T.save_database(db, "my_lab")
            @test events(lab_dir) == ["database_save_started", "database_save_failed"]
            failed = split(readlines(joinpath(lab_dir, "audit.log"))[end], '\t')
            @test failed[4] == "my_lab" && occursin(r"^\w+: ", failed[5])
            @test !member.persistent
            @test T.verify_audit_dir(lab_dir, nothing)[1]
            # Once the obstacle is gone the same call works, and the log tells the whole story.
            rm(member.path * ".part"; recursive = true)
            T.save_database(db, "my_lab")
            @test events(lab_dir) == [
                "database_save_started",
                "database_save_failed",
                "database_save_started",
                "database_saved",
            ]
            # An argument that is wrong is not a failed save: nothing was attempted.
            @test_throws ArgumentError T.save_database(db, "nope")
            @test length(events(lab_dir)) == 4

            # A damaged database is recorded once, however many sessions find it.
            root = joinpath(dir, "databases")
            meta = joinpath(lab_dir, "member.toml")
            write(meta, "not toml [")
            Logging.with_logger(Logging.NullLogger()) do
                T.discover_members(root)
                T.discover_members(root)
            end
            @test events(lab_dir)[end] == "database_unreadable" &&
                  length(events(lab_dir)) == 5
            @test T.verify_audit_dir(lab_dir, nothing)[1]

            # The compounds, the same way.
            cdir = joinpath(dir, "compounds")
            mkpath(joinpath(T.custom_cache_path(cdir) * ".part", "x"))
            cdb = OwnData.compound_db()
            @test_throws Exception T.save_compounds(cdb; dir = cdir)
            @test events(cdir) == ["compounds_save_started", "compounds_save_failed"]

            # An archive whose digest does not match is rejected, with both digests, and nothing
            # is installed; one that matches has a start and an end.
            tdir = joinpath(dir, "thermoml")
            file = joinpath(dir, "ThermoML.v2099-01-01.tgz")
            write(file, "not really an archive")
            actual = T.file_sha256(file)
            @test_throws T.ChecksumMismatchError T.install_archive!(
                file;
                sha256 = repeat("0", 64),
                dir = tdir,
            )
            @test events(tdir) == ["archive_rejected"]
            rejected = split(readlines(joinpath(tdir, "audit.log"))[end], '\t')
            @test rejected[6] == actual && rejected[5] == "expected=" * repeat("0", 64)
            @test T.read_manifest(tdir) === nothing
            Logging.with_logger(Logging.NullLogger()) do
                T.install_archive!(file; sha256 = actual, dir = tdir)
            end
            @test events(tdir) ==
                  ["archive_rejected", "archive_install_started", "archive_installed"]
            # An installation that fails afterwards (the temporary manifest is taken by a folder).
            mkpath(joinpath(T.manifest_path(tdir) * ".tmp", "x"))
            file2 = joinpath(dir, "ThermoML.v2099-01-02.tgz")
            write(file2, "another one")
            @test_throws Exception T.install_archive!(
                file2;
                sha256 = T.file_sha256(file2),
                dir = tdir,
            )
            @test events(tdir)[(end-1):end] ==
                  ["archive_install_started", "archive_install_failed"]
            @test T.verify_audit_dir(tdir, nothing)[1]
        end
    end
end
