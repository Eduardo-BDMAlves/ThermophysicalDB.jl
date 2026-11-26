@testmodule NotebookData begin
    using ThermophysicalDB: ThermophysicalDB
    using ..TwoDatabases: TwoDatabases
    using ..WorkData: WorkData
    const T = ThermophysicalDB

    # `WorkData.database` plus two more experiments in the database of the user (invented values):
    # a viscosity run of a second article and a second mass density run.
    function notebook(dir)
        db, root = WorkData.database(dir)
        ref = T.add_reference!(db; database = "my_lab", doi = "10.5555/mine-2", year = 2026)
        exp = T.add_experiment!(ref; components = [TwoDatabases.WATER], name = "visc-run")
        for (k, temperature) in enumerate((290.0, 300.0))
            T.add_measurement!(
                exp;
                property = "Viscosity",
                unit = "Pa*s",
                value = 0.0011 - 1e-5 * k,
                temperature,
                pressure = 101.325,
            )
        end
        return db, root
    end
end

@testitem "experiments get names, several at once, and are found by any" setup =
    [TwoDatabases, OwnData, WorkData, NotebookData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = NotebookData.notebook(dir)
        tags = T.experiment_names(T.points(db; source = "my_lab"))
        # The experiment without a name has the automatic one; the other the given one.
        @test count(==(["visc-run"]), tags) == 2
        auto = unique(filter(!=(["visc-run"]), tags))
        @test length(auto) == 1
        @test occursin(r"^my_lab_\d{4}_\d{2}_\d{2}_\d{2}:\d{2}(_.+)?$", only(only(auto)))
        # The name filter takes a string, a regular expression or a vector.
        @test length(T.points(db; experiment = "visc-run")) == 2
        @test length(T.points(db; experiment = r"^visc")) == 2
        @test length(T.points(db; experiment = ["visc-run", only(only(auto))])) == 5
        @test_throws ArgumentError T.points(db; experiment = "nothing-here")
        # `add_name!` names any experiment by its index in the table and keeps the other names.
        r = T.add_name!(T.points(db; source = "papers"), "literature-run", 1:2)
        @test r.experiments == 1 && r.changed
        @test length(T.points(db; experiment = "literature-run")) == 3
        T.add_name!(T.points(db; experiment = "literature-run"), "other-name")
        @test length(T.points(db; experiment = "literature-run")) == 3
        @test length(T.points(db; experiment = "other-name")) == 3
        @test all(
            t -> t == ["literature-run", "other-name"],
            T.experiment_names(T.points(db; experiment = "other-name")),
        )
        @test T.add_name!(T.points(db; experiment = "other-name"), "other-name").experiments ==
              0
        @test_throws ArgumentError T.add_name!(T.points(db; source = "papers"), " ")
        @test_throws ArgumentError T.add_name!(T.points(db; source = "papers"), "x", 99)
        # `modify_name!` changes one name: nothing happens without `confirm`.
        plan = T.modify_name!(db, "other-name", "renamed")
        @test !plan.changed && plan.experiments == 1
        @test length(T.points(db; experiment = "other-name")) == 3
        @test T.modify_name!(db, "other-name", "renamed"; confirm = true).changed
        @test_throws ArgumentError T.points(db; experiment = "other-name")
        @test length(T.points(db; experiment = "renamed")) == 3
        @test_throws ArgumentError T.modify_name!(db, "other-name", "x")
        T.modify_name!(
            T.points(db; experiment = "renamed"),
            "renamed",
            "again";
            confirm = true,
        )
        @test length(T.points(db; experiment = "again")) == 3
        # `remove_name!` needs the names, or `true` for all of them.
        @test_throws ArgumentError T.remove_name!(T.points(db; experiment = "again"), false)
        @test !T.remove_name!(T.points(db; experiment = "again"), "again").changed
        @test length(T.points(db; experiment = "again")) == 3
        @test T.remove_name!(T.points(db; experiment = "again"), "again"; confirm = true).changed
        @test_throws ArgumentError T.points(db; experiment = "again")
        @test length(T.points(db; experiment = "literature-run")) == 3
        T.remove_name!(T.points(db; experiment = "literature-run"), true; confirm = true)
        @test_throws ArgumentError T.points(db; experiment = "literature-run")
    end
end

@testitem "a named publication takes the points of its experiments only" setup =
    [TwoDatabases, OwnData, WorkData, NotebookData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = NotebookData.notebook(dir)
        T.add_publication!(
            db,
            T.Publication(;
                name = "paper-A",
                label = "Paper A",
                year = 2026,
                experiments = ["visc-run"],
            ),
        )
        @test_throws ArgumentError T.add_publication!(
            db,
            T.Publication(; name = "paper-B", experiments = ["missing"]),
        )
        @test [p.name for p in T.publications(db)] == ["paper-A"]
        t = T.table(T.points(db); this_work = "paper-A")
        @test count(==("Paper A"), t.work) == 2
        @test count(==(T.OWN_LABEL), t.work) == 3
        @test count(==(T.LITERATURE_LABEL), t.work) == 3 + 5
        # The figures get the same column from `this_work`.
        d = T.plotdata(T.points(db; source = "my_lab"); this_work = "paper-A")
        @test count(==("Paper A"), T.column(d, :work)) == 2
        # A selection works the same way as the name of the publication.
        sel = T.points(db; experiment = "visc-run")
        t2 = T.table(T.points(db); this_work = sel)
        @test count(==(t2.work[findfirst(!=(T.OWN_LABEL), t2.work)]), t2.work) >= 2
        # With two publications `:auto` is refused in an export but not in a table.
        T.add_to_publication!(
            db,
            "paper-A",
            T.experiment_names(T.points(db; source = "my_lab"))[1][1],
        )
        T.add_publication!(
            db,
            T.Publication(; name = "paper-B", experiments = ["visc-run"]),
        )
        @test_throws ArgumentError T.export_points(
            joinpath(dir, "out"),
            T.points(db; source = "my_lab");
            formats = (:csv,),
        )
        @test T.table(T.points(db; source = "my_lab")) isa T.PointTable
        # The publications are kept with the database and found again.
        T.save_database(db, "my_lab")
        found = only(
            T.discover_members(joinpath(dir, "databases")) |>
            x -> filter(m -> m.name == "my_lab", x),
        )
        @test sort([p.name for p in found.publications]) == ["paper-A", "paper-B"]
        # A name that a publication cites cannot vanish, but it can follow a new name.
        @test_throws ArgumentError T.remove_name!(
            T.points(db; experiment = "visc-run"),
            "visc-run";
            confirm = true,
        )
        @test_throws ArgumentError T.modify_name!(
            T.points(db; experiment = "visc-run"),
            "visc-run",
            "v1";
            confirm = true,
        )
        T.modify_name!(db, "visc-run", "visc-1"; confirm = true)
        @test "visc-1" in T.publications(db)[1].experiments &&
              !("visc-run" in T.publications(db)[1].experiments)
        @test T.publications(db)[2].experiments == ["visc-1"]
        T.modify_name!(db, "visc-1", "visc-run"; confirm = true)
        T.remove_publication!(db, "paper-B")
        @test [p.name for p in T.publications(db)] == ["paper-A"]
    end
end

@testitem "publishing some experiments leaves the rest of the notebook" setup =
    [TwoDatabases, OwnData, WorkData, NotebookData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = NotebookData.notebook(dir)
        T.add_publication!(
            db,
            T.Publication(; name = "paper-A", year = 2026, experiments = ["visc-run"]),
        )
        plan = T.publish!(db, "paper-A"; doi = "10.1234/a", to = "papers", online = false)
        @test !plan.published && plan.points == 2 && plan.partial == 0
        @test length(T.points(db; source = "my_lab")) == 5
        r = T.publish!(
            db,
            "paper-A";
            doi = "10.1234/a",
            to = "papers",
            online = false,
            confirm = true,
        )
        @test r.published
        @test length(T.points(db; source = "my_lab")) == 3
        @test length(T.points(db; source = "papers")) == 3 + 2
        # The name finds the points in their new database; the publication is gone.
        moved = T.points(db; experiment = "visc-run")
        @test length(moved) == 2
        @test all(==("10.1234/a"), T.table(moved).doi)
        @test isempty(T.publications(db))
        @test_throws ArgumentError T.publish!(db, "paper-A"; doi = "10.1234/a")
        # The archive can be neither an origin nor a destination.
        @test_throws ArgumentError T.move_experiments!(db, "visc-run", "thermoml")
        sel = T.points(db; property = "Mass density", source = "my_lab")
        @test_throws ArgumentError T.move_experiments!(db, sel, "my_lab"; confirm = true)
    end
end

@testitem "only the selected points of an experiment are published" setup =
    [TwoDatabases, OwnData, WorkData, NotebookData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = NotebookData.notebook(dir)
        sel = T.points(db; source = "my_lab", property = "Mass density")
        first_two = T.DatabaseView(
            db,
            sel.index,
            [T.DataView(p.dataset, p.rows[1:2]) for p in sel.parts],
        )
        r = T.publish!(
            db,
            first_two;
            doi = "10.1234/b",
            to = "papers",
            online = false,
            confirm = true,
        )
        @test r.points == 2 && r.partial == 1
        @test length(T.points(db; source = "my_lab", property = "Mass density")) == 1
        @test length(T.points(db; source = "papers", property = "Mass density")) == 3 + 2
    end
end
