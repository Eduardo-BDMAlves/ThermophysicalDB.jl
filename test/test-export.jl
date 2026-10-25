@testitem "export_target chooses a file format, a ThermoML file or a directory" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.export_target("data/water.csv") == (:file, :csv, "data/water.csv")
    @test T.export_target("data/water.XLSX")[1:2] == (:file, :xlsx)
    @test T.export_target("water.json")[1:2] == (:file, :json)
    @test T.export_target("water.jld2")[1:2] == (:file, :jld2)
    @test T.export_target("data/water.thermoml.json")[1:2] == (:file, :thermoml)
    # no extension, or a trailing separator: a directory named after the path
    @test T.export_target("data/Fluid") == (:directory, :all, "data/Fluid")
    @test T.export_target("data/Fluid.v2/") == (:directory, :all, "data/Fluid.v2")
    @test_throws ArgumentError T.export_target("data/water.txt")
    @test_throws ArgumentError T.export_target("")
    @test T.file_extension(:thermoml) == ".thermoml.json"
    @test T.file_extension(:csv) == ".csv"
end

@testitem "sheet names are legal and unique" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    used = Set{String}(["references", "origin"])
    @test T.sheet_name("a:b/c", used) == "a-b-c"
    @test T.sheet_name("A-B-C", used) == "A-B-C 2"       # Excel ignores case
    long = repeat("x", 40)
    @test T.sheet_name(long, used) == repeat("x", 31)
    @test T.sheet_name(long, used) == repeat("x", 29) * " 2"
    @test T.sheet_name("", used) == "points"
    @test T.sheet_name("references", used) == "references 2"
end

@testitem "the JSON writer keeps order, escapes text and writes null for NaN" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    object = T.JObject("a" => "x\"y\n", "b" => Any[1, NaN, nothing], "c" => true)
    io = IOBuffer()
    T.write_json(io, object, 0, 0)       # everything on one line
    @test String(take!(io)) == "{\"a\": \"x\\\"y\\n\", \"b\": [1, null, null], \"c\": true}"
    io = IOBuffer()
    T.write_json(io, T.JObject("k" => Any[1, 2]), 0, typemax(Int))
    @test String(take!(io)) == "{\n  \"k\": [\n    1,\n    2\n  ]\n}"
    @test T.JObject().pairs == Pair{String,Any}[]
end

@testitem "a CSV has the unit of each column in its header and the origin on the first line" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        file = joinpath(tmp, "water.csv")
        report = T.export_points(file, v; online = false, cache = false, progress = false)
        @test report isa T.ExportReport
        @test report.points == 2 && report.articles == 1
        lines = readlines(file)
        @test length(lines) == 4
        @test startswith(lines[1], "# data origin: NIST/TRC ThermoML Archive")
        @test occursin("dataset doi: 10.18434/mds2-2422", lines[1])
        @test occursin("modified data", lines[1])
        @test split(lines[2], ',') == [
            "reference",
            "components",
            "xkind",
            "property",
            "temperature [K]",
            "pressure [kPa]",
            "x1 [-]",
            "value [kg/m3]",
            "unc [kg/m3]",
            "unc_level [-]",
            "unc_k2 [kg/m3]",
        ]
        row = split(lines[3], ',')
        @test row[1:4] == ["Moe1990", "water", "Mole fraction", "Mass density"]
        @test parse(Float64, row[5]) == 293.15
        @test parse(Float64, row[6]) == 101.325
        @test parse(Float64, row[8]) == 998.0
        # the references table is written next to it, with the BibTeX keys the file uses
        @test report.files == [
            file,
            joinpath(tmp, "water_references.csv"),
            joinpath(tmp, "water.bib"),
            joinpath(tmp, "water_references.tex"),
        ]
        @test occursin(r"@\w+\{Moe1990,", read(joinpath(tmp, "water.bib"), String))
        @test startswith(readline(joinpath(tmp, "water_references.csv")), "key,doi,year")

        # no references files when they are not wanted
        bare = joinpath(tmp, "bare.csv")
        T.export_points(
            bare,
            v;
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        @test !isfile(joinpath(tmp, "bare_references.csv"))
    end
end

@testitem "mixed units add a unit column, and data that are not from NIST carry no origin" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    mktempdir() do tmp
        all_file = joinpath(tmp, "all.csv")
        T.export_points(
            all_file,
            ds;
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        lines = readlines(all_file)
        @test length(lines) == 10
        header = split(lines[2], ',')
        @test "unit" in header && "value [see unit]" in header
        @test "x2 [-]" in header && !("x3 [-]" in header)
        @test "unc_k [-]" in header          # the user point states a coverage factor

        mine = joinpath(tmp, "mine.csv")
        T.export_points(
            mine,
            T.points(ds; source = "user");
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        lines = readlines(mine)
        @test length(lines) == 2
        @test startswith(lines[1], "reference,")
        @test startswith(lines[2], "Anonymous,")
    end
end

@testitem "the reference column holds the key, the written-out citation or the DOI" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; component = ["methane", "carbon dioxide"], source = "thermoml")
    mktempdir() do tmp
        first_value(style) = begin
            file = joinpath(tmp, "$style.csv")
            T.export_points(
                file,
                v;
                reference = style,
                references = false,
                online = false,
                cache = false,
                progress = false,
            )
            first(split(readlines(file)[3], ','; limit = 2))
        end
        @test first_value(:key) == "Doe2005"
        @test first_value(:doi) == "10.5555/tdbfixture-001"
        # the text has no comma, so the cell is not quoted
        @test first_value(:text) == "Doe and Roe (2005)"
    end
    @test_throws ArgumentError T.export_points("x.csv", v; reference = :nonsense)
end

@testitem "a JSON file has one record per point, with the origin as its first entry" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        file = joinpath(tmp, "water.json")
        T.export_points(file, v; online = false, cache = false, progress = false)
        text = read(file, String)
        @test startswith(text, "{\n  \"origin\": {")
        obj = T.JSON.parse(text)
        @test obj["origin"]["dataset_doi"] == "10.18434/mds2-2422"
        @test obj["metadata"]["points"] == 2
        @test obj["units"]["temperature"] == "K"
        @test obj["units"]["value"] == "kg/m3"
        points = obj["points"]
        @test length(points) == 2
        @test points[1]["reference"] == "Moe1990"
        @test points[1]["components"] == "water"
        @test points[1]["temperature"] == 293.15
        @test points[1]["x"] == [1.0]
        @test points[1]["value"] == 998.0 && points[1]["unit"] == "kg/m3"
        @test !haskey(points[1], "method")                # empty fields are left out
        rows = obj["references"]["rows"]
        @test rows[1]["key"] == "Moe1990" && rows[1]["property"] == "Mass density"
        @test obj["references"]["temperature_unit"] == "K"
    end
end

@testitem "a JLD2 file holds the columns, the units and the references" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        file = joinpath(tmp, "water.jld2")
        T.export_points(file, v; online = false, cache = false, progress = false)
        T.JLD2.jldopen(file, "r") do f
            @test f["points/value"] == [998.0, 998.0]
            @test f["points/reference"] == ["Moe1990", "Moe1990"]
            @test f["units/temperature"] == "K"
            @test "value [kg/m3]" in f["metadata/headers"]
            @test f["references/key"] == ["Moe1990"]
            @test f["origin/dataset_doi"] == "10.18434/mds2-2422"
        end
    end
end

@testitem "a .tex has the same table as the CSV, citing the keys of the .bib" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        file = joinpath(tmp, "water.tex")
        report = T.export_points(file, v; online = false, cache = false, progress = false)
        @test file in report.files && joinpath(tmp, "water.bib") in report.files
        text = read(file, String)
        @test startswith(text, "% data origin: NIST/TRC ThermoML Archive")
        @test occursin("\\begin{longtable}{", text)
        @test occursin("\\toprule", text) && occursin("\\end{longtable}", text)
        @test occursin("temperature [K]", text) && occursin("value [kg/m3]", text)
        @test occursin("\\cite{Moe1990} & water", text)
        @test count("\\cite{Moe1990}", text) == 2
        refs = read(joinpath(tmp, "water_references.tex"), String)
        @test occursin("\\cite{Moe1990}", refs) && occursin("\\begin{longtable}", refs)

        # written out, the reference is plain text
        plain = joinpath(tmp, "plain.tex")
        T.export_points(
            plain,
            v;
            reference = :text,
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        @test occursin("Moe (1990) & water", read(plain, String))
    end
end

@testitem "SI units are applied to the values and the pressure" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; component = "methane", source = "thermoml")
    mktempdir() do tmp
        file = joinpath(tmp, "si.csv")
        T.export_points(
            file,
            v;
            units = :si,
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        lines = readlines(file)
        header = split(lines[2], ',')
        @test "pressure [Pa]" in header
        @test "value [W/m/K]" in header
        row = split(lines[3], ',')
        @test parse(Float64, row[findfirst(==("pressure [Pa]"), header)]) == 1.0e6
    end
end

@testitem "a directory gets every format, named after the path" setup = [Toy] tags = [:unit] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        target = joinpath(tmp, "data", "Fluid")
        captured = Ref{Any}(nothing)
        export_it() = (
            captured[] = T.export_points(
                target,
                v;
                online = false,
                cache = false,
                progress = false,
            )
        )
        if T.xlsx_available()
            export_it()
        else
            @test_logs (:warn, r"Skipping the .xlsx") export_it()
        end
        report = captured[]
        for ext in (".csv", ".json", ".jld2", ".tex")
            @test isfile(joinpath(target, "Fluid" * ext))
        end
        @test isfile(joinpath(target, "Fluid_references.csv"))
        @test isfile(joinpath(target, "Fluid.bib"))
        @test isfile(joinpath(target, "Fluid.xlsx")) == T.xlsx_available()
        @test (:xlsx in first.(report.skipped)) == !T.xlsx_available()
        @test !isfile(joinpath(target, "Fluid.thermoml.json"))

        # the formats can be chosen; a ThermoML file is one of them
        chosen = joinpath(tmp, "chosen")
        T.export_points(
            chosen,
            v;
            formats = (:csv, :thermoml),
            online = false,
            cache = false,
            progress = false,
        )
        @test sort(readdir(chosen)) == [
            "chosen.bib",
            "chosen.csv",
            "chosen.thermoml.json",
            "chosen_references.csv",
            "chosen_references.tex",
        ]

        # asking for .xlsx explicitly is an error when it cannot be written
        if !T.xlsx_available()
            @test_throws ArgumentError T.export_points(
                joinpath(tmp, "x.xlsx"),
                v;
                online = false,
                cache = false,
                progress = false,
            )
            @test_throws ArgumentError T.export_points(
                joinpath(tmp, "y"),
                v;
                formats = (:xlsx,),
                online = false,
                cache = false,
                progress = false,
            )
        end
        @test_throws ArgumentError T.export_points(joinpath(tmp, "z"), v; formats = (:pdf,))
        @test_throws ArgumentError T.export_points(
            joinpath(tmp, "z.csv"),
            v;
            formats = (:csv,),
        )
    end
end

@testitem "an empty selection cannot be exported" setup = [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    empty_view = T.points(ds; property = "Mass density", temperature = (1000, 2000))
    @test length(empty_view) == 0
    @test_throws ArgumentError T.export_points("none.csv", empty_view)
end

@testitem "the ThermoML subset reads back to the same points" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; source = "thermoml")
    @test length(v) == 7
    mktempdir() do tmp
        file = joinpath(tmp, "subset.thermoml.json")
        # nothing here touches the network or the references
        report = T.export_points(file, v)
        @test report.files == [file] && report.bibtex === nothing
        text = read(file, String)
        @test startswith(text, "{\n  \"origin\": {")
        obj = T.JSON.parse(text)
        articles = obj["articles"]
        @test length(articles) == 2

        article = articles[1]
        @test article["Citation"]["sDOI"] == "10.5555/tdbfixture-001"
        @test article["Citation"]["yrPubYr"] == 2005
        @test length(article["Compound"]) == 2
        @test article["Compound"][1]["RegNum"]["nOrgNum"] == 1
        block = article["PureOrMixtureData"][1]
        @test block["Property"][1]["Property-MethodID"]["PropertyGroup"]["Property"]["ePropName"] ==
              "Thermal conductivity, W/m/K"
        @test length(block["NumValues"]) == 4

        # read the articles back with the parser that reads the archive
        copy = T.Dataset()
        source = T.intern!(copy.sources, "thermoml")
        build = T.BuildReport()
        for a in articles
            parsed = T.parse_article("article.json", Vector{UInt8}(T.JSON.json(a)))
            @test isempty(parsed.error)
            T.ingest!(copy, parsed, source, build)
        end
        @test isempty(build.skipped) && isempty(build.failed)
        back = T.DataView(copy)
        @test length(back) == length(v)

        before = T.table(v)
        after = T.table(back)
        @test after.value == before.value
        @test after.temperature == before.temperature
        @test isequal(after.pressure, before.pressure)
        @test isequal(after.x1, before.x1) && isequal(after.x2, before.x2)
        @test after.property == before.property
        @test after.unit == before.unit
        @test after.components == before.components
        @test after.doi == before.doi
        @test after.year == before.year
        @test all(isapprox.(after.unc, before.unc; nans = true))
        @test all(isapprox.(after.unc_k2, before.unc_k2; nans = true))
    end

    # the same layout through the .json extension
    mktempdir() do tmp
        file = joinpath(tmp, "subset.json")
        T.export_points(file, v; json_layout = :thermoml)
        @test haskey(T.JSON.parse(read(file, String)), "articles")
    end

    # points that do not come from the archive carry no origin note
    mktempdir() do tmp
        file = joinpath(tmp, "mine.thermoml.json")
        T.export_points(file, T.points(ds; source = "user"))
        text = read(file, String)
        @test !occursin("origin", text) && occursin("articles", text)
    end
end

@testitem "an .xlsx has a sheet per system, a references sheet and an origin sheet" setup =
    [Toy] tags = [:unit] begin
    using XLSX
    T = ThermophysicalDB
    ds = Toy.build()
    mktempdir() do tmp
        file = joinpath(tmp, "all.xlsx")
        T.export_points(file, ds; online = false, cache = false, progress = false)
        XLSX.openxlsx(file) do book
            @test XLSX.sheetnames(book) ==
                  ["carbon dioxide + methane", "water", "references", "origin"]
        end

        data, labels = XLSX.readtable(file, "water")
        @test Symbol("temperature [K]") in labels
        @test Symbol("value [see unit]") in labels && :unit in labels
        @test !(Symbol("x2 [-]") in labels)                   # a pure system has one composition
        column(name) = data[findfirst(==(name), labels)]
        @test column(:property)[1] == "Mass density"
        @test column(Symbol("value [see unit]"))[1] == 998.0

        data, labels = XLSX.readtable(file, "references")
        @test :key in labels
        @test "Moe1990" in data[findfirst(==(:key), labels)]

        data, labels = XLSX.readtable(file, "origin")
        @test labels == [:field, :value]
        @test data[1][1] == "data origin"

        # everything in one sheet
        single = joinpath(tmp, "single.xlsx")
        T.export_points(
            single,
            ds;
            sheets = :single,
            online = false,
            cache = false,
            progress = false,
        )
        XLSX.openxlsx(single) do book
            @test XLSX.sheetnames(book) == ["points", "references", "origin"]
        end
        data, labels = XLSX.readtable(single, "points")
        @test length(data[1]) == 8

        # the origin sheet is absent for data that are not from the archive
        mine = joinpath(tmp, "mine.xlsx")
        T.export_points(
            mine,
            T.points(ds; source = "user");
            online = false,
            cache = false,
            progress = false,
        )
        XLSX.openxlsx(mine) do book
            @test XLSX.sheetnames(book) == ["carbon dioxide + methane", "references"]
        end
    end
end
