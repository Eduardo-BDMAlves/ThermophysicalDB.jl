@testmodule TwoDatabases begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    const WATER = "XLYOFNOQVPJJNP-UHFFFAOYSA-N"
    const SALT = "FAPWRFPIFSIZLT-UHFFFAOYSA-M"
    const METHANE = "VNWKTOKETHGBQD-UHFFFAOYSA-N"

    # One reference with one experiment and `n` points of `property` for the given compounds.
    function add_system!(ds, doi, compounds, property, unit, n; value = 1000.0)
        src = T.intern!(ds.sources, "fixture")
        ref = T.add_reference!(ds.references; doi, year = 2001, source = src)
        ids = Int32[
            T.add_compound!(ds.compounds; inchikey = key, names = [name]) for
            (key, name) in compounds
        ]
        prop = T.add_property!(ds.properties, property, unit)
        e = T.add_experiment!(ds.experiments; reference = ref, components = ids)
        for k = 1:n
            T.add_measurement!(
                ds.measurements;
                experiment = e,
                property = prop,
                value = value + k,
                temperature = 290.0 + k,
                pressure = 101.325,
                composition = (NaN, NaN, NaN),
            )
        end
        return ds
    end

    # The archive: water and salt water, 3 + 2 points of a mass density.
    function archive()
        ds = T.Dataset()
        add_system!(ds, "10.5555/tdbdb-001", [(WATER, "water")], "Mass density", "kg/m3", 3)
        add_system!(
            ds,
            "10.5555/tdbdb-002",
            [(SALT, "sodium chloride"), (WATER, "water")],
            "Mass density",
            "kg/m3",
            2,
        )
        return ds
    end

    # What the user measured: water (a viscosity), methane, and one compound known only by name.
    function mine()
        ds = T.Dataset()
        add_system!(ds, "10.5555/tdbdb-900", [(WATER, "water")], "Viscosity", "Pa s", 4)
        add_system!(
            ds,
            "10.5555/tdbdb-901",
            [(METHANE, "methane")],
            "Mass density",
            "kg/m3",
            2,
        )
        add_system!(ds, "10.5555/tdbdb-902", [("", "my brine")], "Mass density", "kg/m3", 1)
        return ds
    end

    function manifest()
        return T.Manifest(
            T.MANIFEST_FORMAT,
            "2099-01-01",
            "ThermoML.v2099-01-01.tgz",
            repeat("d", 64),
            "https://example.invalid/x",
            T.utc_timestamp(),
            1,
        )
    end

    # The archive in its cache file, not read yet, and the user's database in memory.
    function two(dir)
        T.write_cache(dir, archive(), manifest())
        return T.Database([
            T.Member("thermoml"; kind = :thermoml, path = T.cache_data_path(dir)),
            T.Member("user_self"; kind = :user, dataset = mine()),
        ])
    end
end

@testitem "the registry gives one number to what the databases share" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        reg = db.registry
        # Water, salt, methane, and the compound known by name only.
        @test length(reg.compound_keys) == 4
        water = reg.compound_index[TwoDatabases.WATER]
        @test reg.compound[1][1] == water && reg.compound[2][1] == water
        @test all(reg.has_compound[1][[reg.compound_index[TwoDatabases.SALT], water]])
        @test !reg.has_compound[1][reg.compound_index[TwoDatabases.METHANE]]
        # "Mass density" is shared, the viscosity is the user's.
        @test length(reg.property_keys) == 2
        @test reg.references == 5
        @test reg.unkeyed == [("user_self", Int32(3))]
        # Reading the registry did not read the archive.
        @test !T.is_open(db.members[1])
        @test T.members(db)[1].name == "thermoml" && T.members(db)[2].name == "user_self"
    end
end

@testitem "members are ordered by priority and can be added and removed" setup =
    [TwoDatabases] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    db = T.Database([
        T.Member("mine"; kind = :user, dataset = TwoDatabases.mine()),
        T.Member("nist"; kind = :thermoml, dataset = TwoDatabases.archive()),
    ])
    @test [m.name for m in T.members(db)] == ["nist", "mine"]
    lit = T.Member("papers"; kind = :literature, dataset = TwoDatabases.mine())
    T.add_member!(db, lit)
    @test [m.name for m in T.members(db)] == ["nist", "papers", "mine"]
    @test length(db.registry.members) == 3
    @test_throws ArgumentError T.add_member!(
        db,
        T.Member("papers"; kind = :user, dataset = T.Dataset()),
    )
    # The priority is the user's to change.
    first_user =
        T.Member("first"; kind = :user, priority = 0, dataset = TwoDatabases.mine())
    T.add_member!(db, first_user)
    @test T.members(db)[1].name == "first"
    T.remove_member!(db, "first")
    @test_throws ArgumentError T.remove_member!(db, "nowhere")
    @test_throws ArgumentError T.Member("x"; kind = :bogus, dataset = T.Dataset())
    @test_throws ArgumentError T.Member("x"; kind = :user)
    @test !T.Member("u"; kind = :user, dataset = T.Dataset()).persistent
    @test T.Member("n"; kind = :thermoml, dataset = T.Dataset()).persistent
    @test T.member_dataset(db, "nist") isa T.Dataset
    @test occursin("3 databases", sprint(show, db))
end

@testitem "a selection asks only the databases that can answer" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        # Methane exists only in the user's database: the archive is never read.
        view = T.points(db; component = "methane")
        @test view isa T.DatabaseView && length(view) == 2
        @test length(T.parts(view)) == 1
        @test !T.is_open(db.members[1])
        # The viscosity, too, and a DOI that only the archive has.
        @test length(T.points(db; property = "viscosity")) == 4
        @test !T.is_open(db.members[1])
        # Water is in both: both answer, the archive is read now.
        water = T.points(db; component = "water")
        @test length(T.parts(water)) == 2 && length(water) == 3 + 2 + 4
        @test T.is_open(db.members[1])
        # exact keeps pure water; a mixture needs every component.
        @test length(T.points(db; component = "water", exact = true)) == 3 + 4
        @test length(T.mixture(db, "water", "sodium chloride")) == 2
        # Filters combine across the databases and chain.
        density = T.points(db; property = "Mass density")
        @test length(density) == 3 + 2 + 2 + 1
        @test length(T.points(density; component = "water")) == 3 + 2
        # One point at 292 K in each of the four systems that have one.
        @test length(T.points(db; temperature = (291.5, 292.5))) == 4
        # A name no database knows is an error, a name some databases lack is not.
        @test_throws ArgumentError T.points(db; component = "unobtainium")
        @test_throws ArgumentError T.points(db; property = "no such property")
        # A DOI that none has is an empty selection, as for one dataset.
        @test isempty(T.points(db; doi = "10.5555/nowhere"))
        @test length(T.points(db; doi = "10.5555/tdbdb-001")) == 3
        @test_throws ArgumentError T.points(db; component = 1)
    end
end

@testitem "a table over several databases says where each point comes from" setup =
    [TwoDatabases] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        view = T.points(db; component = "water")
        t = T.table(view)
        @test length(t.value) == length(view)
        @test t.database == [fill("thermoml", 5); fill("user_self", 4)]
        # With one part the table is the one of that part.
        one = T.points(db; component = "methane")
        @test !haskey(T.table(one), :database)
        @test isequal(T.table(one), T.table(only(T.parts(one))))
        # Each part keeps working as a DataView.
        @test sum(length, T.parts(view)) == length(view)
        @test occursin("DatabaseView(9 points", sprint(show, view))
    end
end

@testitem "find_compounds joins the databases and its result selects in all of them" setup =
    [TwoDatabases] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        found = T.find_compounds(db, "water")
        @test length(found) == 1
        # Points of water in both databases, one compound.
        @test found.points == [3 + 2 + 4]
        @test found.id == [db.registry.compound_index[TwoDatabases.WATER]]
        @test length(T.points(db; component = found)) == 9
        methane = T.find_compounds(db, "methane")
        @test length(T.points(db; component = methane)) == 2
        @test isempty(T.find_compounds(db, "unobtainium"))
    end
end

@testitem "one database keeps working like the dataset it holds" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    using Tables: Tables
    T = ThermophysicalDB
    ds = TwoDatabases.archive()
    db = T.Database(ds)
    view = T.points(db; component = "water")
    @test length(view) == 5
    @test isequal(T.table(view), T.table(T.points(ds; component = "water")))
    @test T.find_compounds(db, "water").points == T.find_compounds(ds, "water").points
    @test length(db) == length(ds)
    @test T.validate(db)
    # A selection of one database is read like its DataView, and is a Tables.jl source.
    @test view.rows == T.points(ds; component = "water").rows
    @test view.dataset === ds
    @test Tables.istable(typeof(view)) && Tables.columns(view).value == T.table(view).value
    @test length(T.condition_table(db).role) == length(T.condition_table(ds).role)
    # Functions that do not join databases yet say so instead of answering for one of them.
    two = T.Database([
        T.Member("a"; kind = :thermoml, dataset = ds),
        T.Member("b"; kind = :user, dataset = TwoDatabases.mine()),
    ])
    @test_throws ArgumentError T.sample_table(two)
    @test_throws ArgumentError T.export_points(
        mktempdir(),
        T.points(two; component = "water"),
    )
    @test T.member_dataset(two, "b") isa T.Dataset
end

@testitem "a selection over databases shows its first points" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        v = T.points(db; component = "water")
        text = sprint(show, MIME("text/plain"), v)
        @test occursin("DatabaseView: 9 points", text)
        @test occursin("database", text) && occursin("thermoml", text)
        @test occursin("user_self", text) && !occursin("… and", text)
        short = sprint(io -> show(io, MIME("text/plain"), v; maxrows = 6))
        @test occursin("… and 3 more points", short)
        @test count("thermoml  ", short) >= 5 && count("user_self ", short) >= 2
        # The database column is absent when only one database has points.
        one = T.points(db; property = "Viscosity")
        text = sprint(show, MIME("text/plain"), one)
        @test occursin("DatabaseView: 4 points", text)
        @test occursin("T [K]", text) && !occursin("… and", text)
    end
end

@testitem "a database lists its members with their sizes" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.group_digits(7) == "7" && T.group_digits(1234567) == "1,234,567"
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        text = sprint(show, MIME("text/plain"), db)
        @test occursin("Database: 2 databases", text)
        lines = split(text, '\n')
        archive = only(filter(l -> startswith(l, "thermoml"), lines))
        mine = only(filter(l -> startswith(l, "user_self"), lines))
        # points, references, compounds, properties
        @test split(archive)[4:7] == ["5", "2", "2", "1"]
        @test split(mine)[4:7] == ["7", "3", "3", "2"]
        @test endswith(archive, "not read") && endswith(mine, "read")
        # Showing the list did not read the archive.
        @test !T.is_open(db.members[1])
    end
end
