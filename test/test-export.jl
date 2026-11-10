@testitem "export_points takes a directory name, never a file name" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.export_directory("data/Fluid") == "data/Fluid"
    @test T.export_directory("data/Fluid/") == "data/Fluid"
    # a trailing separator keeps a dot in the name of the directory
    @test T.export_directory("data/Fluid.v2/") == "data/Fluid.v2"
    for name in
        ("data/water.csv", "water.xlsx", "data/water.thermoml.json", "data/water.txt")
        err = try
            T.export_directory(name)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("directory name, not a file name", err.msg)
    end
    @test_throws ArgumentError T.export_directory("")
    @test T.file_extension(:thermoml) == ".thermoml.json"
    @test T.file_extension(:md) == ".md"

    # the formats: tuple of symbols, defaults, validation
    defaults = T.export_formats(nothing)
    @test defaults[1:5] == (:csv, :md, :tex, :json, :jld2)
    @test (:xlsx in defaults) == T.xlsx_available()
    @test T.export_formats(:csv) == (:csv,)
    @test T.export_formats((:csv, :thermoml, :csv)) == (:csv, :thermoml)
    @test_throws ArgumentError T.export_formats((:pdf,))
    @test_throws ArgumentError T.export_formats(())
    if !T.xlsx_available()
        @test_throws ArgumentError T.export_formats((:xlsx,))
    end
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
        report, file = Toy.export1(
            joinpath(tmp, "water.csv"),
            v;
            online = false,
            cache = false,
            progress = false,
        )
        @test report isa T.ExportReport
        @test report.points == 2 && report.articles == 1
        lines = readlines(file)
        @test length(lines) == 4
        @test startswith(lines[1], "# data origin: NIST/TRC ThermoML Archive")
        @test occursin("dataset doi: 10.18434/mds2-2422", lines[1])
        @test occursin("modified data", lines[1])
        # one system and one property: neither is repeated in every row
        @test split(lines[2], ',') == [
            "reference",
            "xkind",
            "temperature [K]",
            "pressure [kPa]",
            "x1 [-]",
            "value [kg/m3]",
            "unc [kg/m3]",
            "unc_level [-]",
            "unc_k2 [kg/m3]",
        ]
        row = split(lines[3], ',')
        @test row[1:2] == ["moe1990", "Mole fraction"]
        @test parse(Float64, row[3]) == 293.15
        @test parse(Float64, row[4]) == 101.325
        @test parse(Float64, row[6]) == 998.0
        # the references table is written next to it, with the BibTeX keys the file uses
        dir = joinpath(tmp, "water")
        @test report.files ==
              [file, joinpath(dir, "water_references.csv"), joinpath(dir, "water.bib")]
        @test occursin(r"@\w+\{moe1990,", read(joinpath(dir, "water.bib"), String))
        refs = readlines(joinpath(dir, "water_references.csv"))
        @test startswith(refs[1], "# data origin: NIST/TRC ThermoML Archive")
        @test startswith(refs[2], "key,doi,year")

        # no references files when they are not wanted
        bare = joinpath(tmp, "bare.csv")
        @test_logs (:warn, r"references = false") Toy.export1(
            bare,
            v;
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        @test readdir(joinpath(tmp, "bare")) == ["bare.csv"]
    end
end

@testitem "mixed units add a unit column, and data that are not from NIST carry no origin" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    mktempdir() do tmp
        _, all_file = Toy.export1(
            joinpath(tmp, "all.csv"),
            ds;
            references = false,
            reference = :doi,
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

        _, mine = Toy.export1(
            joinpath(tmp, "mine.csv"),
            T.points(ds; source = "user");
            references = false,
            reference = :doi,
            online = false,
            cache = false,
            progress = false,
        )
        lines = readlines(mine)
        @test length(lines) == 2
        @test startswith(lines[1], "reference,")
        @test startswith(lines[2], "anonymoussdbench,")
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
            path = joinpath(tmp, "$style", "$style.csv")
            export_file() = Toy.export1(
                file,
                v;
                reference = style,
                references = false,
                online = false,
                cache = false,
                progress = false,
            )
            # the keys without their `.bib` are warned about (see test-notice.jl)
            style === :key ? (@test_logs (:warn, r"references = false") export_file()) :
            export_file()
            first(split(readlines(path)[3], ','; limit = 2))
        end
        @test first_value(:key) == "doe2005"
        @test first_value(:doi) == "10.5555/tdbfixture-001"
        # the text has no comma, so the cell is not quoted
        @test first_value(:text) == "Doe and Roe (2005)"
    end
    @test_throws ArgumentError T.export_points("x", v; reference = :nonsense)
end

@testitem "a JSON file carries the separate uncertainty terms of the points that have them" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    r1, r2 = v.rows
    e1 = ds.measurements.experiment[r1]
    T.set_uncertainty!(
        ds;
        scope = :experiment,
        row = e1,
        quantity = :temperature,
        device = 0.01,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = r1,
        quantity = :temperature,
        statistical = 0.02,
    )
    T.set_uncertainty!(
        ds;
        scope = :measurement,
        row = r1,
        quantity = :pressure,
        combined = 0.5,
    )
    mktempdir() do tmp
        _, file = Toy.export1(
            joinpath(tmp, "water.json"),
            v;
            online = false,
            cache = false,
            progress = false,
        )
        points = T.JSON.parse(read(file, String))["points"]
        terms = points[1]["uncertainties"]
        @test [(t["quantity"], t["kind"], t["origin"]) for t in terms] == [
            ("temperature", "device", "given"),
            ("temperature", "statistical", "given"),
            ("temperature", "combined", "derived"),
            ("temperature", "expanded", "derived"),
            ("pressure", "combined", "given"),
            ("pressure", "expanded", "derived"),
        ]
        @test terms[1]["shared"] == true && !haskey(terms[2], "shared")
        @test terms[4]["value"] ≈ 2 * sqrt(0.01^2 + 0.02^2) && terms[4]["k"] == 2.0
        @test terms[4]["level"] == 0.95 && haskey(terms[3], "method")
        # a point without terms has no member, and a term of the experiment reaches all points
        shared = [
            t for t in get(points[2], "uncertainties", []) if t["quantity"] == "temperature"
        ]
        @test length(shared) == (ds.measurements.experiment[r2] == e1 ? 1 : 0)
        # in SI the pressure terms are in pascal, like the pressure column
        _, file = Toy.export1(
            joinpath(tmp, "si.json"),
            v;
            units = :si,
            online = false,
            cache = false,
            progress = false,
        )
        si = T.JSON.parse(read(file, String))["points"][1]["uncertainties"]
        @test si[5]["value"] == 500.0
    end
    # the ThermoML exports are untouched: only the expanded uncertainty of the property
    @test T.validate(ds)
end

@testitem "a JSON file has one record per point, with the origin as its first entry" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        _, file = Toy.export1(
            joinpath(tmp, "water.json"),
            v;
            online = false,
            cache = false,
            progress = false,
        )
        text = read(file, String)
        @test startswith(text, "{\n  \"origin\": {")
        obj = T.JSON.parse(text)
        @test obj["origin"]["dataset_doi"] == "10.18434/mds2-2422"
        @test obj["metadata"]["points"] == 2
        @test obj["units"]["temperature"] == "K"
        @test obj["units"]["value"] == "kg/m3"
        points = obj["points"]
        @test length(points) == 2
        @test points[1]["reference"] == "moe1990"
        @test !haskey(points[1], "components") && !haskey(points[1], "property")
        @test points[1]["temperature"] == 293.15
        @test points[1]["x"] == [1.0]
        @test points[1]["value"] == 998.0 && points[1]["unit"] == "kg/m3"
        @test !haskey(points[1], "method")                # empty fields are left out
        rows = obj["references"]["rows"]
        @test rows[1]["key"] == "moe1990" && rows[1]["property"] == "Mass density"
        @test obj["references"]["temperature_unit"] == "K"
    end
end

@testitem "a JLD2 file holds the columns, the units and the references" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    mktempdir() do tmp
        _, file = Toy.export1(
            joinpath(tmp, "water.jld2"),
            v;
            online = false,
            cache = false,
            progress = false,
        )
        T.JLD2.jldopen(file, "r") do f
            @test f["points/value"] == [998.0, 998.0]
            @test f["points/reference"] == ["moe1990", "moe1990"]
            @test f["units/temperature"] == "K"
            @test "value [kg/m3]" in f["metadata/headers"]
            @test f["references/key"] == ["moe1990"]
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
        report, file = Toy.export1(
            joinpath(tmp, "water.tex"),
            v;
            online = false,
            cache = false,
            progress = false,
        )
        dir = joinpath(tmp, "water")
        @test file in report.files && joinpath(dir, "water.bib") in report.files
        text = read(file, String)
        @test startswith(text, "% data origin: NIST/TRC ThermoML Archive")
        @test occursin("\\begin{longtable}{", text)
        @test occursin("\\toprule", text) && occursin("\\end{longtable}", text)
        @test occursin("temperature [K]", text) && occursin("value [kg/m3]", text)
        @test occursin("\\cite{moe1990} & Mole fraction", text)
        @test count("\\cite{moe1990}", text) == 2
        refs = read(joinpath(dir, "water_references.tex"), String)
        @test occursin("\\cite{moe1990}", refs) && occursin("\\begin{longtable}", refs)

        # written out, the reference is plain text
        _, plain = Toy.export1(
            joinpath(tmp, "plain.tex"),
            v;
            reference = :text,
            references = false,
            online = false,
            cache = false,
            progress = false,
        )
        @test occursin("Moe (1990) & Mole fraction", read(plain, String))
    end
end

@testitem "SI units are applied to the values and the pressure" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; component = "methane", source = "thermoml")
    mktempdir() do tmp
        _, file = Toy.export1(
            joinpath(tmp, "si.csv"),
            v;
            units = :si,
            references = false,
            reference = :doi,
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

@testitem "a directory gets the formats asked for, named after the path" setup = [Toy] tags =
    [:unit] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    quiet = (; online = false, cache = false, progress = false)
    mktempdir() do tmp
        # the default: the directory is created, the formats are the defaults
        target = joinpath(tmp, "data", "Fluid")
        report = T.export_points(target, v; quiet...)
        for ext in (".csv", ".md", ".tex", ".json", ".jld2")
            @test isfile(joinpath(target, "Fluid" * ext))
        end
        @test isfile(joinpath(target, "Fluid.xlsx")) == T.xlsx_available()
        @test !isfile(joinpath(target, "Fluid.thermoml.json"))
        # the references follow the table formats that were written, plus the .bib
        for name in (
            "Fluid_references.csv",
            "Fluid_references.md",
            "Fluid_references.tex",
            "Fluid.bib",
        )
            @test isfile(joinpath(target, name))
        end
        @test all(isfile, report.files)
        @test report.points == 2 && report.articles == 1

        # a tuple of symbols chooses; a ThermoML file is one of them
        chosen = joinpath(tmp, "chosen")
        T.export_points(chosen, v; formats = (:csv, :thermoml), quiet...)
        @test sort(readdir(chosen)) ==
              ["chosen.bib", "chosen.csv", "chosen.thermoml.json", "chosen_references.csv"]

        # formats that hold their references inside the file write only the .bib beside it
        inside = joinpath(tmp, "inside")
        T.export_points(inside, v; formats = (:json, :jld2), quiet...)
        @test sort(readdir(inside)) == ["inside.bib", "inside.jld2", "inside.json"]

        # one format can be given as a symbol, and the directory can exist already
        T.export_points(chosen, v; formats = :md, quiet...)
        @test isfile(joinpath(chosen, "chosen.md"))

        # a ThermoML-only directory needs neither references nor network
        only = joinpath(tmp, "only")
        report = T.export_points(only, v; formats = (:thermoml,))
        @test readdir(only) == ["only.thermoml.json"] && report.bibtex === nothing

        # a path with an extension is a mistake, not a directory with a dot in its name
        @test_throws ArgumentError T.export_points(joinpath(tmp, "z.csv"), v; quiet...)
        @test !ispath(joinpath(tmp, "z.csv"))
        @test isdir(
            T.export_directory(joinpath(tmp, "dotted.v2") * "/") |> d -> (mkpath(d); d),
        )
        @test_throws ArgumentError T.export_points(joinpath(tmp, "z"), v; formats = (:pdf,))
        @test !ispath(joinpath(tmp, "z"))

        # asking for .xlsx explicitly is an error when it cannot be written
        if !T.xlsx_available()
            @test_throws ArgumentError T.export_points(
                joinpath(tmp, "y"),
                v;
                formats = (:xlsx,),
                quiet...,
            )
        end
    end
end

@testitem "a Markdown table of the points, with the notice as a comment" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    quiet = (; online = false, cache = false, progress = false)
    mktempdir() do tmp
        v = T.points(ds; component = ["methane", "carbon dioxide"], source = "thermoml")
        _, file = Toy.export1(joinpath(tmp, "gas.md"), v; quiet...)
        lines = readlines(file)
        @test lines[1] == "<!--"
        @test any(startswith("dataset citation: "), lines)
        close = findfirst(==("-->"), lines)
        @test close !== nothing && lines[close+1] == ""
        header, align = lines[close+2], lines[close+3]
        @test startswith(header, "| reference | xkind |") && endswith(header, " |")
        @test !occursin("components", header)
        cells(line) = strip.(split(strip(line, ['|', ' ']), '|'))
        names = cells(header)
        # text columns left, numbers right
        @test cells(align)[1] == ":---" && last(cells(align)) == "---:"
        @test length(cells(align)) == length(names)
        rows = lines[(close+4):end]
        @test length(rows) == length(v)
        first_row = cells(rows[1])
        @test length(first_row) == length(names)
        @test first_row[1] == "doe2005"
        @test parse(Float64, first_row[findfirst(==("temperature [K]"), names)]) == 300.0
        @test parse(Float64, first_row[findfirst(==("pressure [kPa]"), names)]) == 1000.0

        # one system and property: no repeated columns; a pipe in text is escaped
        w = T.points(ds; property = "Mass density")
        _, file = Toy.export1(joinpath(tmp, "w.md"), w; reference = :text, quiet...)
        text = read(file, String)
        @test occursin("| Moe (1990) |", text)
        @test T.md_cell(IOBuffer(), "a|b") > 0
        io = IOBuffer()
        T.md_cell(io, "a|b")
        @test String(take!(io)) == "a\\|b"
        io = IOBuffer()
        T.md_cell(io, NaN)
        T.md_cell(io, 2.5)
        @test String(take!(io)) == "2.5"

        # data that are not from the archive carry no comment
        _, file = Toy.export1(
            joinpath(tmp, "mine.md"),
            T.points(ds; source = "user");
            references = false,
            reference = :doi,
            quiet...,
        )
        @test !occursin("<!--", read(file, String))
    end
end

@testitem "an empty selection cannot be exported" setup = [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    empty_view = T.points(ds; property = "Mass density", temperature = (1000, 2000))
    @test length(empty_view) == 0
    @test_throws ArgumentError T.export_points("none", empty_view)
end

@testitem "the ThermoML subset reads back to the same points" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; source = "thermoml")
    @test length(v) == 7
    mktempdir() do tmp
        file = joinpath(tmp, "subset", "subset.thermoml.json")
        # nothing here touches the network or the references
        report = T.export_points(joinpath(tmp, "subset"), v; formats = (:thermoml,))
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

    # points that do not come from the archive carry no origin note
    mktempdir() do tmp
        report = T.export_points(
            joinpath(tmp, "mine"),
            T.points(ds; source = "user");
            formats = (:thermoml,),
        )
        text = read(only(report.files), String)
        @test !occursin("origin", text) && occursin("articles", text)
    end
end

@testitem "an .xlsx has a sheet per system, a references sheet and an origin sheet" setup =
    [Toy] tags = [:unit] begin
    using XLSX
    T = ThermophysicalDB
    # XLSX.readtable returns a DataTable (columns and labels), not a tuple
    function readsheet(file, sheet)
        table = XLSX.readtable(file, sheet)
        return table.data, table.column_labels
    end
    ds = Toy.build()
    mktempdir() do tmp
        # with XLSX loaded the default export writes the workbook too
        report = T.export_points(
            joinpath(tmp, "all"),
            ds;
            online = false,
            cache = false,
            progress = false,
        )
        file = joinpath(tmp, "all", "all.xlsx")
        @test file in report.files
        XLSX.openxlsx(file) do book
            @test XLSX.sheetnames(book) ==
                  ["carbon dioxide + methane", "water", "references", "origin"]
        end

        data, labels = readsheet(file, "water")
        @test Symbol("temperature [K]") in labels
        @test Symbol("value [see unit]") in labels && :unit in labels
        @test !(Symbol("x2 [-]") in labels)                   # a pure system has one composition
        column(name) = data[findfirst(==(name), labels)]
        @test column(:property)[1] == "Mass density"
        @test column(Symbol("value [see unit]"))[1] == 998.0

        data, labels = readsheet(file, "references")
        @test :key in labels
        @test "moe1990" in data[findfirst(==(:key), labels)]

        data, labels = readsheet(file, "origin")
        @test labels == [:field, :value]
        @test data[1][1] == "data origin"

        # everything in one sheet
        _, single = Toy.export1(
            joinpath(tmp, "single.xlsx"),
            ds;
            sheets = :single,
            online = false,
            cache = false,
            progress = false,
        )
        XLSX.openxlsx(single) do book
            @test XLSX.sheetnames(book) == ["points", "references", "origin"]
        end
        data, labels = readsheet(single, "points")
        @test length(data[1]) == 8

        # the origin sheet is absent for data that are not from the archive
        _, mine = Toy.export1(
            joinpath(tmp, "mine.xlsx"),
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

@testitem "the method and the phase are written only with details = true" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    fill!(ds.measurements.method, T.intern!(ds.methods, "Transient hot-wire method"))
    fill!(ds.measurements.phase, T.intern!(ds.phases, "Liquid"))
    v = T.points(ds; property = "Mass density")
    quiet = (; online = false, cache = false, progress = false)
    mktempdir() do tmp
        header(file) = split(readlines(file)[2], ',')

        _, plain = Toy.export1(joinpath(tmp, "plain.csv"), v; quiet...)
        @test !("method" in header(plain)) && !("phase" in header(plain))
        @test !occursin("Transient", read(plain, String))

        _, full = Toy.export1(joinpath(tmp, "full.csv"), v; details = true, quiet...)
        names = header(full)
        @test "method" in names && "phase" in names
        row = split(readlines(full)[3], ',')
        @test row[findfirst(==("method"), names)] == "Transient hot-wire method"
        @test row[findfirst(==("phase"), names)] == "Liquid"

        # the other formats follow the same rule (the references table keeps the method)
        for ext in (".tex", ".md")
            _, a = Toy.export1(joinpath(tmp, "a" * ext), v; quiet...)
            _, b = Toy.export1(joinpath(tmp, "b" * ext), v; details = true, quiet...)
            @test !occursin("Transient", read(a, String))
            @test occursin("Transient hot-wire method", read(b, String))
        end

        _, a = Toy.export1(joinpath(tmp, "a.json"), v; quiet...)
        _, b = Toy.export1(joinpath(tmp, "b.json"), v; details = true, quiet...)
        points_of(file) = T.JSON.parse(read(file, String))["points"]
        @test all(p -> !haskey(p, "method") && !haskey(p, "phase"), points_of(a))
        @test all(
            p -> p["method"] == "Transient hot-wire method" && p["phase"] == "Liquid",
            points_of(b),
        )
        _, a = Toy.export1(joinpath(tmp, "a.jld2"), v; quiet...)
        _, b = Toy.export1(joinpath(tmp, "b.jld2"), v; details = true, quiet...)
        T.JLD2.jldopen(a) do f
            @test !haskey(f, "points/method")
        end
        T.JLD2.jldopen(b) do f
            @test f["points/method"] == fill("Transient hot-wire method", 2)
        end
    end
end

@testitem "components and property are written only when they vary, or with details = true" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    quiet = (; online = false, cache = false, progress = false)
    mktempdir() do tmp
        function header(view; kwargs...)
            _, file = Toy.export1(
                joinpath(tmp, "t.csv"),
                view;
                references = false,
                reference = :doi,
                quiet...,
                kwargs...,
            )
            return split(readlines(file)[2], ',')
        end
        one_each = T.points(ds; property = "Mass density")           # water, one property
        one_system = T.points(ds; component = "water")                # water, two properties
        everything = ds                                               # several of both

        names = header(one_each)
        @test !("components" in names) && !("property" in names)
        names = header(one_system)
        @test !("components" in names) && "property" in names
        names = header(everything)
        @test "components" in names && "property" in names

        # details = true writes them whatever the selection
        names = header(one_each; details = true)
        @test "components" in names && "property" in names

        # the same rule in the other formats
        _, file = Toy.export1(
            joinpath(tmp, "t.json"),
            one_each;
            references = false,
            reference = :doi,
            quiet...,
        )
        @test all(
            p -> !haskey(p, "components") && !haskey(p, "property"),
            T.JSON.parse(read(file, String))["points"],
        )
        _, file = Toy.export1(
            joinpath(tmp, "t.json"),
            one_each;
            details = true,
            references = false,
            reference = :doi,
            quiet...,
        )
        @test all(
            p -> p["components"] == "water" && p["property"] == "Mass density",
            T.JSON.parse(read(file, String))["points"],
        )
        _, file = Toy.export1(
            joinpath(tmp, "t.jld2"),
            one_each;
            references = false,
            reference = :doi,
            quiet...,
        )
        T.JLD2.jldopen(file) do f
            @test !haskey(f, "points/components") && !haskey(f, "points/property")
        end
    end
end
