@testmodule CombineData begin
    using ThermophysicalDB: ThermophysicalDB
    using ..TwoDatabases: TwoDatabases
    using ..OwnData: OwnData
    const T = ThermophysicalDB

    function compounds()
        cdb = T.CompoundDB()
        for (key, cas, formula, name) in (
            ("VLKZTOCTOMPKJO-UHFFFAOYSA-N", "110-54-3", "C6H14", "hexane"),
            ("HEDRZPFGACZZDS-UHFFFAOYSA-N", "67-66-3", "CHCl3", "chloroform"),
            ("IMNFDUFMRHMDMM-UHFFFAOYSA-N", "142-82-5", "C7H16", "heptane"),
        )
            T.insert_record!(cdb; inchikey = key, cas, formula, names = [name])
        end
        return cdb
    end

    const K = "Thermal conductivity"

    # Pure hexane; a table of hexane + chloroform that gives x1 only and runs from 0 to 1; the same
    # binary the other way round with both amounts; a binary in molality; a ternary.
    function experiments()
        return [
            (
                components = ["hexane"],
                property = K,
                unit = "W/m/K",
                temperature = [303.15, 313.15],
                value = [0.1200, 0.1180],
            ),
            (
                components = ["hexane", "chloroform"],
                property = K,
                unit = "W/m/K",
                temperature = 303.15,
                x1 = [0.0, 0.5, 1.0],
                value = [0.1108, 0.1049, 0.1152],
            ),
            (
                components = ["chloroform", "hexane"],
                property = K,
                unit = "W/m/K",
                temperature = 303.15,
                x1 = [0.2, 0.0, 1.0],
                x2 = [0.8, 1.0, 0.0],
                value = [0.1131, 0.1161, 0.1119],
            ),
            (
                components = ["hexane", "chloroform"],
                property = K,
                unit = "W/m/K",
                composition_scale = :molality,
                temperature = 303.15,
                x1 = [1.0],
                value = [0.1300],
            ),
            (
                components = ["hexane", "chloroform", "heptane"],
                property = K,
                unit = "W/m/K",
                temperature = 303.15,
                x1 = [0.0, 0.5],
                x2 = [0.0, 0.5],
                value = [0.1203, 0.1100],
            ),
        ]
    end

    function lab(dir; name = "my_lab", doi = "10.5555/Pure-1")
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, name; dir = joinpath(dir, "databases"))
        T.add_reference_data!(
            db;
            reference = (doi = doi, year = 2024, authors = ["Silva, A."]),
            experiments = experiments(),
            compounds = compounds(),
        )
        return db
    end

    values(view) = sort(round.(T.table(view).value; digits = 4))
end

@testitem "the pure compound is found in systems of one component and at the end of mixture tables" setup =
    [TwoDatabases, OwnData, CombineData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = CombineData.lab(dir)
        k = "Thermal conductivity"

        # a plain search finds only the system of one component
        @test length(T.points(db; component = "hexane", pure = true)) == 2

        hexane = T.pure_component(db, "hexane"; property = k)
        # pure (2), x1 = 1 of the first binary and x2 = 1 of the second (x1 = 0, x2 = 1),
        # and nothing of the molality table (not a fraction) or of the ternary
        @test CombineData.values(hexane) == [0.1152, 0.1161, 0.1180, 0.1200]
        @test T.parts(hexane)[1].dataset === T.member_dataset(db, "my_lab")

        # chloroform is never a system of its own here: x1 = 0 with x2 not given, and x2 given
        chloroform = T.pure_component(db, "chloroform"; property = k)
        @test CombineData.values(chloroform) == [0.1108, 0.1119]

        # the compound is the third of the system and its amount is not given: the others add up to 0
        heptane = T.pure_component(db, "heptane"; property = k)
        @test CombineData.values(heptane) == [0.1203]

        # other filters refine the result, and the tolerance decides what is the whole system
        @test CombineData.values(
            T.pure_component(db, "hexane"; temperature = (310, 320)),
        ) == [0.1180]
        near = T.pure_component(db, "hexane"; property = k, tol = 0.3)
        @test length(near) == length(hexane) + 1     # x2 = 0.8 of the first row of the second binary
        @test_throws ArgumentError T.pure_component(db, "hexane"; pure = true)
        @test_throws ArgumentError T.pure_component(db, ["hexane", "chloroform"])
        @test_throws ArgumentError T.pure_component(db, "hexane"; tol = 0.7)
        @test_throws ArgumentError T.pure_component(db, "hexane"; tol = -1e-3)
        @test_throws ArgumentError T.pure_component(db, "no such compound")

        # a dataset and a view give the same points
        ds = T.member_dataset(db, "my_lab")
        @test CombineData.values(T.pure_component(ds, "hexane"; property = k)) ==
              CombineData.values(hexane)
        @test CombineData.values(
            T.pure_component(T.points(db; component = "hexane"), "hexane"; property = k),
        ) == CombineData.values(hexane)
    end
end

@testitem "selections of one dataset are combined by union, intersect and setdiff" setup =
    [TwoDatabases, OwnData, CombineData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = CombineData.lab(dir)
        ds = T.member_dataset(db, "my_lab")
        n = length(ds.measurements)
        a = T.DataView(ds, Int32[2, 4, 6, 8])
        b = T.DataView(ds, Int32[4, 5, 6, 7])
        @test collect(union(a, b).rows) == [2, 4, 5, 6, 7, 8]
        @test collect(intersect(a, b).rows) == [4, 6]
        @test collect(setdiff(a, b).rows) == [2, 8]
        @test collect(setdiff(b, a).rows) == [5, 7]

        # lists that are not in order, and rows that are given twice, are put in order
        messy = T.DataView(ds, Int32[8, 2, 2, 6, 4])
        @test collect(union(messy, b).rows) == [2, 4, 5, 6, 7, 8]
        @test collect(setdiff(messy, b).rows) == [2, 8]

        # the symbols are the same functions
        @test collect((a ∪ b).rows) == collect(union(a, b).rows)
        @test collect((a ∩ b).rows) == collect(intersect(a, b).rows)
        @test collect((a ∪ b ∩ T.DataView(ds, Int32[4, 5])).rows) == [2, 4, 5, 6, 8]

        # more than two, ranges, empty results, and the whole dataset
        all_rows = T.DataView(ds)
        @test collect(union(a, b, T.DataView(ds, Int32[1])).rows) == [1, 2, 4, 5, 6, 7, 8]
        @test length(union(all_rows, a)) == n
        @test collect(intersect(all_rows, a).rows) == [2, 4, 6, 8]
        @test collect(intersect(a, b, T.DataView(ds, Int32[6, 9])).rows) == [6]
        @test isempty(setdiff(a, all_rows))
        @test isempty(intersect(a, T.DataView(ds, Int32[1, 3])))
        @test length(union(all_rows, all_rows)) == n

        # the result is a selection that can be refined and tabulated
        both = union(
            T.points(ds; component = "hexane", pure = true),
            T.points(ds; component = "hexane", fraction = "hexane" => (0.9999, 1)),
        )
        @test length(both) == 2 + 1 + 1 + 1     # the pure system, x1 = 1, x2 = 1 and the molality one
        @test length(T.points(both; temperature = (310, 320))) == 1
        @test length(T.table(both).value) == length(both)

        other = T.Dataset()
        @test_throws ArgumentError union(a, T.DataView(other))
        @test_throws ArgumentError intersect(a, T.DataView(other))
        @test_throws ArgumentError setdiff(a, T.DataView(other))
        @test_throws ArgumentError union(a, T.points(db; component = "hexane"))
    end
end

@testitem "selections of a database are combined by member, and repeated points are left out" setup =
    [TwoDatabases, OwnData, CombineData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = CombineData.lab(dir)
        # the same work in a second database of yours: every point is repeated
        T.add_database!(db, "copy"; dir = joinpath(dir, "databases"), priority = 4)
        T.add_reference_data!(
            db;
            database = "copy",
            reference = (doi = "10.5555/Pure-1", year = 2024, authors = ["Silva, A."]),
            experiments = CombineData.experiments(),
            compounds = CombineData.compounds(),
            warn_duplicates = false,
        )
        k = "Thermal conductivity"
        pure = T.points(db; component = "hexane", pure = true, property = k)
        limit = T.points(
            db;
            component = "hexane",
            property = k,
            fraction = "hexane" => (0.9999, 1),
        )
        both = union(pure, limit)
        @test length(both) == length(pure) + length(limit) - length(intersect(pure, limit))
        @test T.parts(both) isa Vector{T.DataView}
        # each point once: the copy of lower priority is left out, as `points` does
        @test length(both) == 2 + 3
        @test length(T.parts(both)) == 1
        # selections that keep the repeated points: the union leaves them out unless asked not to
        pure_all =
            T.points(db; component = "hexane", pure = true, property = k, duplicate = true)
        limit_all = T.points(
            db;
            component = "hexane",
            property = k,
            fraction = "hexane" => (0.9999, 1),
            duplicate = true,
        )
        @test length(union(pure_all, limit_all; duplicate = true)) == 2 * (2 + 3)
        @test length(union(pure_all, limit_all)) == 2 + 3

        @test length(intersect(pure, limit)) == 0
        @test isempty(setdiff(pure, pure))
        @test length(setdiff(both, pure)) == length(limit)
        # the molality point is in `both` (the filter by fraction does not look at the kind), not here
        @test length(T.pure_component(db, "hexane"; property = k)) == length(both) - 1
        @test length(T.pure_component(db, "hexane"; property = k, duplicate = true)) ==
              2 * (length(both) - 1)

        # a selection of another database is refused
        other = CombineData.lab(mktempdir())
        @test_throws ArgumentError union(pure, T.points(other; component = "hexane"))
    end
end

@testitem "overlap counts the points that several selections share" setup =
    [TwoDatabases, OwnData, CombineData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = CombineData.lab(dir)
        ds = T.member_dataset(db, "my_lab")
        hexane = T.points(ds; component = "hexane")
        chloroform = T.points(ds; component = "chloroform")
        cold_free = T.points(ds; temperature = (310, 320))
        ov = T.overlap(:hexane => hexane, :chloroform => chloroform, :warm => cold_free)

        @test ov isa T.Overlap && ov.names == ["hexane", "chloroform", "warm"]
        @test ov.sizes == [length(hexane), length(chloroform), length(cold_free)]
        # every point is in exactly one region
        @test sum(ov.points) == length(hexane ∪ chloroform ∪ cold_free)
        @test ov.region == ["only hexane", "hexane ∩ chloroform", "hexane ∩ warm"]
        @test ov.points == [1, 9, 1]
        @test ov.references == [1, 1, 1]
        @test ov.sets == [true false false; true true false; true false true]

        # a region is the set expression that its label says
        @test collect(ov["hexane ∩ chloroform"].rows) ==
              collect(setdiff(hexane ∩ chloroform, cold_free).rows)
        @test collect(ov["only hexane"].rows) ==
              collect(setdiff(setdiff(hexane, chloroform), cold_free).rows)
        @test collect(ov[2].rows) == collect(ov["hexane ∩ chloroform"].rows)
        @test length(ov) == 3 && length(collect(ov)) == 3
        @test collect(ov[end].rows) == collect(ov["hexane ∩ warm"].rows)
        @test_throws ArgumentError ov["nothing"]

        # the regions rebuild each selection
        for (s, view) in enumerate((hexane, chloroform, cold_free))
            rows = reduce(
                vcat,
                [collect(ov[i].rows) for i in eachindex(ov.region) if ov.sets[i, s]];
                init = Int32[],
            )
            @test sort(rows) == collect(view.rows)
        end

        # without names, with unsorted lists, and a region can be refined
        plain = T.overlap(hexane, chloroform)
        @test plain.names == ["1", "2"] && plain.region == ["only 1", "1 ∩ 2"]
        messy = T.overlap(T.DataView(ds, Int32[5, 3, 3, 1]), T.DataView(ds, Int32[3, 4]))
        @test messy.region == ["only 1", "only 2", "1 ∩ 2"] && messy.points == [2, 1, 1]
        @test length(T.points(ov["hexane ∩ chloroform"]; temperature = (310, 320))) == 0
        @test occursin("hexane ∩ chloroform", sprint(show, MIME("text/plain"), ov))
        @test occursin("3 regions", sprint(show, ov))

        # the errors
        @test_throws ArgumentError T.overlap(hexane)
        @test_throws ArgumentError T.overlap(hexane, chloroform; names = ["a"])
        @test_throws ArgumentError T.overlap(hexane, chloroform; names = ["a", "a"])
        @test_throws ArgumentError T.overlap(hexane, T.DataView(T.Dataset()))
        @test_throws ArgumentError T.overlap(hexane, T.points(db; component = "hexane"))
        @test_throws ArgumentError T.overlap((hexane for _ = 1:17)...)
        @test T.overlap((hexane for _ = 1:16)...).points == [length(hexane)]
    end
end

@testitem "overlap of selections of a database goes member by member" setup =
    [TwoDatabases, OwnData, CombineData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = CombineData.lab(dir)
        T.add_database!(db, "copy"; dir = joinpath(dir, "databases"), priority = 4)
        T.add_reference_data!(
            db;
            database = "copy",
            reference = (doi = "10.5555/Other-1", year = 2023, authors = ["Souza, B."]),
            experiments = CombineData.experiments()[1:2],
            compounds = CombineData.compounds(),
            warn_duplicates = false,
        )
        k = "Thermal conductivity"
        hexane = T.points(db; component = "hexane", property = k, duplicate = true)
        chloroform = T.points(db; component = "chloroform", property = k, duplicate = true)
        ov = T.overlap(:hexane => hexane, :chloroform => chloroform)
        @test ov isa T.Overlap{T.DatabaseView}
        @test ov.sizes == [length(hexane), length(chloroform)]
        # my_lab: 11 hexane points, 9 with chloroform; copy: 5 hexane points, 3 with chloroform
        @test ov.region == ["only hexane", "hexane ∩ chloroform"]
        @test ov.points == [2 + 2, 9 + 3]
        @test ov.references == [1 + 1, 1 + 1]
        both = ov["hexane ∩ chloroform"]
        @test length(T.parts(both)) == 2 && length(both) == 12
        @test length(both) == length(hexane ∩ chloroform)
        @test length(ov["only hexane"]) == length(setdiff(hexane, chloroform))
        @test sum(ov.points) == length(union(hexane, chloroform; duplicate = true))

        @test_throws ArgumentError T.overlap(
            hexane,
            T.points(T.member_dataset(db, "my_lab")),
        )
        other = CombineData.lab(mktempdir())
        @test_throws ArgumentError T.overlap(hexane, T.points(other; component = "hexane"))
    end
end
