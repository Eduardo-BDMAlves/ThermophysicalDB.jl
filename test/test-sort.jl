@testitem "sort orders a table by keys and directions with the missing last" tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable
    cols = (;
        id = collect(1:6),
        property = ["b", "a", "b", "a", "b", "a"],
        temperature = [300.0, NaN, 280.0, 290.0, 310.0, 270.0],
        value = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0],
        unit = fill("K", 6),
        unc_k2 = [0.5, 0.5, NaN, 1.0, 4.0, 16.0],
        year = Int16[2000, 0, 1990, 2010, 2000, 1980],
    )
    t = PointTable(cols)
    ids(; kwargs...) = sort(t; kwargs...).id

    # One key, in both directions: the point without a temperature is last either way.
    @test ids(by = :temperature) == [6, 3, 4, 1, 5, 2]
    @test ids(by = :temperature, rev = true) == [5, 1, 4, 3, 6, 2]
    @test ids(by = :temperature => :desc) == [5, 1, 4, 3, 6, 2]
    @test ids(by = :temperature => :asc, rev = true) == [6, 3, 4, 1, 5, 2]
    @test ids(by = :unc_k2 => :desc) == [6, 5, 4, 1, 2, 3]
    @test ids(by = :unc_k2) == [1, 2, 4, 5, 6, 3]
    # An unknown year (0) is a missing value too.
    @test ids(by = :year) == [6, 3, 1, 5, 4, 2]
    @test ids(by = :year, rev = true) == [4, 1, 5, 3, 6, 2]
    # Equal keys keep their order, in both directions.
    @test ids(by = :property) == [2, 4, 6, 1, 3, 5]
    @test ids(by = :property, rev = true) == [1, 3, 5, 2, 4, 6]
    # Several keys: the first is the most important.
    @test ids(by = [:property, :temperature => :desc]) == [4, 6, 2, 5, 1, 3]
    @test ids(by = (:property, :temperature)) == [6, 4, 2, 3, 1, 5]
    @test ids(by = [:property, :temperature => :asc], rev = true) == [3, 1, 5, 6, 4, 2]
    # The uncertainty over the value, which has no unit; the point without one is last.
    @test ids(by = :relative_unc) == [4, 2, 5, 1, 6, 3]
    @test ids(by = :relative_unc => :desc) == [1, 6, 2, 5, 4, 3]

    # The order alone, a new table, and nothing changed in the original.
    @test sortperm(t; by = :temperature) == [6, 3, 4, 1, 5, 2]
    sorted = sort(t; by = :temperature)
    @test sorted isa PointTable && keys(sorted) == keys(t)
    @test t.id == 1:6 && sorted.temperature !== t.temperature
    @test isequal(sorted, t[sortperm(t; by = :temperature)])

    # In place: the same result, the same table, and only the memory of one column more.
    inplace = PointTable(map(copy, cols))
    @test sort!(inplace; by = [:property, :temperature => :desc]) === inplace
    @test inplace.id == [4, 6, 2, 5, 1, 3]
    @test isequal(inplace, sort(t; by = [:property, :temperature => :desc]))
    @test t.id == 1:6                      # `t` was not touched
    twice = PointTable(map(copy, cols))
    sort!(twice; by = :temperature)
    sort!(twice; by = :temperature => :desc)
    @test twice.id == [5, 1, 4, 3, 6, 2]
    # A column that is shared is sorted with it; a column that cannot be changed is refused first.
    shared = PointTable(map(copy, cols))
    part = shared[[:id, :temperature]]
    sort!(shared; by = :temperature)
    @test part.id === shared.id && part.id == [6, 3, 4, 1, 5, 2]
    @test_throws ArgumentError sort!(PointTable((; n = [2.0, 1.0], id = 1:2)); by = :n)
    @test isempty(sort!(PointTable((; n = Float64[])); by = :n))

    # Texts: the empty one is missing and goes last.
    named = PointTable((; n = ["b", "", "a", "c"], id = 1:4))
    @test sort(named; by = :n).id == [3, 1, 4, 2]
    @test sort(named; by = :n => :desc).id == [4, 1, 3, 2]
    @test isempty(sort(t[1:0]; by = :temperature))

    # Wrong keys.
    @test_throws ArgumentError sort(t; by = :nothing_like_it)
    @test_throws ArgumentError sort(t; by = :temperature => :up)
    @test_throws ArgumentError sort(t; by = Symbol[])
    @test_throws ArgumentError sort(t; by = "temperature")
    @test_throws ArgumentError sort(t; by = [:temperature, 3])
    @test_throws ArgumentError sort(PointTable((; a = [1.0])); by = :relative_unc)
end

@testitem "sorting by a value of points with different units warns" tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable
    mixed = PointTable((;
        property = ["a", "b", "a", "b"],
        value = [3.0, 1.0, 2.0, 4.0],
        unit = ["K", "kPa", "K", "kPa"],
    ))
    @test_logs (:warn, r"different units") sort(mixed; by = :value)
    @test sort(mixed; by = :value).value == [1.0, 2.0, 3.0, 4.0]
    # With the property first, or with one unit, there is nothing to say.
    @test_logs sort(mixed; by = [:property, :value])
    @test_logs sort(mixed[[1, 3]]; by = :value)
    @test sort(mixed; by = [:property, :value]).value == [2.0, 3.0, 1.0, 4.0]
end

@testitem "table with sortby is the sort of the table, built before or after" setup = [Toy] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable
    using Logging: Logging
    using Unitful: Unitful
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds)
    quiet(f) = Logging.with_logger(f, Logging.NullLogger())

    # Keys that are read from the data before the table exists, and keys that need the table.
    before = (
        :temperature,
        :pressure,
        :value,
        :unc,
        :unc_k2,
        :unc_k,
        :year,
        :doi,
        :source,
        :method,
        :phase,
        :relative_unc,
        :property,
        [:property, :temperature => :desc],
        [:doi, :value],
    )
    after = (:components, :x1, :unit, [:components, :value], [:property, :x1 => :desc])
    plain = T.table(view)
    for by in (before..., after...), rev in (false, true)
        expected = quiet(() -> sort(plain; by, rev))
        got = quiet(() -> T.table(view; sortby = by, rev))
        @test isequal(got, expected)
    end

    # In place, on a table that was built: the same table, and the database is not touched.
    for by in (:temperature, :relative_unc, [:property, :value => :desc])
        inplace = T.table(view)
        expected = quiet(() -> sort(inplace; by))
        quiet(() -> sort!(inplace; by))
        @test isequal(inplace, expected)
    end
    @test isequal(T.table(view), plain) && issorted(view.rows)

    # The selection is not reordered, and a sorted table is a table of the same points.
    @test issorted(view.rows) && T.table(view).value == plain.value
    by_time = T.table(view; sortby = :temperature)
    @test isequal(sort(by_time.value), sort(plain.value))
    known = count(!isnan, by_time.temperature)
    @test issorted(by_time.temperature[1:known]) &&
          all(isnan, by_time.temperature[(known+1):end])

    # The conversions are the same before and after the sort.
    for kwargs in (
        (; units = :si),
        (; temperature_unit = "degC", pressure_unit = "bar"),
        (; policy = :normal),
    )
        for by in (:value, :temperature, :pressure, :unc_k2, :relative_unc)
            expected = quiet(() -> sort(T.table(view; kwargs...); by))
            got = quiet(() -> T.table(view; kwargs..., sortby = by))
            @test isequal(got, expected)
        end
    end
    one = T.points(ds; property = "Thermal conductivity")
    for kwargs in ((; unit = "mW/m/K"), (; quantities = Unitful))
        @test isequal(
            T.table(one; kwargs..., sortby = :value),
            sort(T.table(one; kwargs...); by = :value),
        )
    end

    # The details of the source are columns like any other.
    @test isequal(
        T.table(view; details = true, sortby = :digits),
        quiet(() -> sort(T.table(view; details = true); by = :digits)),
    )

    # The mixed units are said once, whichever way the sort is done.
    @test_logs (:warn, r"different units") T.table(view; sortby = :value)
    @test_logs (:warn, r"different units") sort(plain; by = :value)
    @test_logs T.table(view; sortby = [:property, :value])
    @test_throws ArgumentError T.table(view; sortby = :nothing_like_it)
    @test_throws ArgumentError T.table(view; sortby = :value => :up)
end

@testitem "a selection over databases is sorted as a whole" setup = [TwoDatabases] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB
    using Logging: Logging
    T = ThermophysicalDB
    mktempdir() do dir
        db = TwoDatabases.two(dir)
        v = T.points(db; component = "water")
        plain = T.table(v)
        @test :database in keys(plain)
        for by in (:temperature, :value, :database, [:database, :value => :desc])
            expected = Logging.with_logger(Logging.NullLogger()) do
                sort(plain; by)
            end
            got = Logging.with_logger(Logging.NullLogger()) do
                T.table(v; sortby = by)
            end
            @test isequal(got, expected)
        end
        one = T.points(db; component = "water", property = "Mass density")
        @test isequal(T.table(one; sortby = :value), sort(T.table(one); by = :value))
    end
end

@testitem "a shown table says how many entries are not given" tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable
    t = PointTable((;
        temperature = [300.0, 310.0, NaN, 330.0],
        value = [1.0, 2.0, 3.0, 4.0],
        unc = [NaN, NaN, NaN, 0.1],
        method = ["a", "", "a", "a"],
    ))
    text = sprint(show, MIME("text/plain"), t)
    @test occursin("missing", text)
    @test occursin("temperature 1 (25 %)", text) && occursin("unc 3 (75 %)", text)
    @test occursin("method 1 (25 %)", text) && !occursin("value 0", text)
    @test occursin("a blank cell is a value that the source does not give", text)
    complete = PointTable((; temperature = [300.0, 310.0], value = [1.0, 2.0]))
    full = sprint(show, MIME("text/plain"), complete)
    @test occursin("none (NaN or empty text)", full) && !occursin("blank cell", full)
    # A table without any of those columns has nothing to say about them.
    @test !occursin("missing", sprint(show, MIME("text/plain"), PointTable((; a = [1, 2]))))
end
