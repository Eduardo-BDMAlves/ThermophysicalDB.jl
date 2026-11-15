@testitem "a table is indexed like a data frame" tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable, table, parent
    using Tables: Tables
    cols = (;
        components = ["a", "a", "b", "b", "b"],
        property = ["p", "p", "p", "q", "q"],
        temperature = [300.0, 310.0, 320.0, 330.0, NaN],
        value = [1.0, 2.0, 3.0, 4.0, 5.0],
        unit = ["kPa", "kPa", "kPa", "K", "K"],
    )
    t = PointTable(cols)

    # Names and sizes.
    @test size(t) == (5, 5) && size(t, 1) == 5 && size(t, 2) == 5
    @test length(t) == 5 && !isempty(t) && lastindex(t) == 5 && lastindex(t, 2) == 5
    @test keys(t) == keys(cols) && haskey(t, :value) && !haskey(t, :nada)
    @test parent(t) === cols
    @test t.temperature === cols.temperature
    @test propertynames(t) == keys(cols)

    # One argument.
    @test t[:temperature] === cols.temperature
    @test isequal(
        t[3],
        (;
            components = "b",
            property = "p",
            temperature = 320.0,
            value = 3.0,
            unit = "kPa",
        ),
    )
    @test isequal(t[end], t[5]) && t[end].value == 5.0
    @test t[:value, end] == 5.0 && t[end, :value] == 5.0

    # Two arguments, in both orders, by position and with slices.
    @test t[3, :temperature] == 320.0 && t[:temperature, 3] == 320.0
    @test t[3, 3] == 320.0
    @test isequal(t[2, :], t[2])
    @test t[1:2, :temperature] == [300.0, 310.0]
    @test t[:temperature, 1:2] == [300.0, 310.0]
    @test t[[5, 1], :value] == [5.0, 1.0]
    @test t[:, :value] == cols.value && t[:, :value] !== cols.value
    @test t[1:2, 4] == [1.0, 2.0]
    @test t[Int32[3, 4], :value] == [3.0, 4.0]

    # Parts of the table are tables, with a copy of the rows.
    sub = t[2:3]
    @test sub isa PointTable && size(sub) == (2, 5) && sub.value == [2.0, 3.0]
    @test t[1:0] isa PointTable && isempty(t[1:0])
    narrow = t[[:value, :unit]]
    @test narrow isa PointTable &&
          keys(narrow) == (:value, :unit) &&
          narrow.value === cols.value
    both = t[1:2, [:temperature, :value]]
    @test both isa PointTable &&
          keys(both) == (:temperature, :value) &&
          both.value == [1.0, 2.0]
    masked = t[t.value .> 3.5]
    @test masked.value == [4.0, 5.0] && masked isa PointTable
    @test t[:, [:value]].value == cols.value
    sub.value[1] = 99.0
    @test cols.value[2] == 2.0   # rows are copied

    # What does not exist says so.
    @test_throws BoundsError t[0]
    @test_throws BoundsError t[6]
    @test_throws BoundsError t[1:6]
    @test_throws BoundsError t[3, 6]
    @test_throws BoundsError t[6, :value]
    @test_throws BoundsError t[:value, 0]
    @test_throws DimensionMismatch t[[true, false]]
    err = try
        t[:temp]
    catch e
        e
    end
    @test err isa ArgumentError && occursin(":temperature", err.msg)
    @test_throws ArgumentError t.nada
    @test_throws ArgumentError t[[:value, :nada]]

    # Iteration goes by rows.
    rows = collect(t)
    @test length(rows) == 5 && isequal(rows[1], t[1]) && eltype(rows) == eltype(t)
    seen = Float64[]
    for row in t
        push!(seen, row.value)
    end
    @test seen == cols.value
    @test sum(row.value for row in t) == 15.0
    @test Tables.istable(t) && Tables.columns(t) === cols
    @test Tables.schema(t).names == keys(cols)
    @test isequal(Tables.rowtable(t), Tables.rowtable(cols))
    @test_throws ArgumentError PointTable((; a = [1, 2], b = [1]))
end

@testitem "the table of a selection is a PointTable that is shown with a summary" setup =
    [Toy] tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable, parent
    using Tables: Tables
    using Unitful: Unitful, @u_str
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds)
    t = T.table(v)
    @test t isa PointTable && length(t) == length(v) && size(t, 2) >= 19
    @test Tables.columns(v) isa NamedTuple && Tables.columns(v).value == t.value
    @test t[1:2].value == t.value[1:2]
    @test t[:value, 1] == t.value[1]

    text = sprint(show, MIME("text/plain"), t)
    @test startswith(text, "PointTable: $(length(t)) points × $(size(t, 2)) columns")
    @test occursin("references", text) && occursin("systems", text)
    @test occursin("T [K]", text) && occursin("values by property and unit", text)
    @test occursin("p [kPa]", text)
    @test sprint(show, t) == "PointTable($(length(t)) points × $(size(t, 2)) columns)"

    si = T.table(v; units = :si)
    @test occursin("p [Pa]", sprint(show, MIME("text/plain"), si))
    other = T.table(v; temperature_unit = "degC")
    @test occursin("T [degC]", sprint(show, MIME("text/plain"), other))

    # The summary is computed from the columns when it is shown, so a change is seen.
    before = sprint(show, MIME("text/plain"), t)
    t2 = T.table(v)
    t2.temperature .= 1234.5
    @test occursin("1234.5", sprint(show, MIME("text/plain"), t2))
    @test !occursin("1234.5", before)

    # An empty selection, and a table of quantities.
    none = T.table(T.points(ds; component = "water", temperature = (1, 2)))
    @test isempty(none)
    @test sprint(show, MIME("text/plain"), none) ==
          "PointTable: 0 points × $(size(none, 2)) columns\n"
    water = T.points(ds; component = "water", property = "Vapor or sublimation pressure")
    q = T.table(water; quantities = Unitful)
    @test q isa PointTable
    @test occursin("values by property and unit", sprint(show, MIME("text/plain"), q))
end

@testitem "tables are equal when their columns and units are" tags = [:unit, :fast] begin
    using ThermophysicalDB: PointTable
    a = PointTable((; x = [1.0, NaN], y = ["a", "b"]))
    b = PointTable((; x = [1.0, NaN], y = ["a", "b"]))
    @test isequal(a, b) && hash(a) == hash(b)
    @test a != b   # NaN is not equal to itself, as in a NamedTuple
    c = PointTable((; x = [1.0, 2.0], y = ["a", "b"]))
    @test c == PointTable((; x = [1.0, 2.0], y = ["a", "b"]))
    @test c != PointTable((; x = [1.0, 2.0], y = ["a", "b"]), "degC")
    @test !isequal(c, PointTable((; x = [1.0, 2.0], y = ["a", "c"])))
end

@testitem "a table narrowed to some columns is shown with the columns it has" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    t = T.table(T.points(Toy.build()))
    narrow = t[1:2, [:temperature, :value]]
    text = sprint(show, MIME("text/plain"), narrow)
    @test startswith(text, "PointTable: 2 points × 2 columns")
    @test occursin("T [K]", text) &&
          occursin("value", text) &&
          !occursin("components", text)
    only_text = sprint(show, MIME("text/plain"), t[[:components]])
    @test occursin("components", only_text)
    @test occursin("PointTable", sprint(show, MIME("text/plain"), t[[:unit, :value]]))
    @test occursin("PointTable", sprint(show, MIME("text/plain"), t[1:0, [:value]]))
    # A table with columns of its own (nothing of a point table) is shown too.
    plain = T.PointTable((; a = [1.0, 2.0], b = ["x", "y"]))
    shown = sprint(show, MIME("text/plain"), plain)
    @test occursin("a", shown) && occursin("x", shown)
end
