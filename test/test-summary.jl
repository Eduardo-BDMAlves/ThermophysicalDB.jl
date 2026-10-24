@testitem "parse_month and citation_text" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.parse_month("jan") == 1
    @test T.parse_month("December") == 12
    @test T.parse_month("7") == 7
    @test T.parse_month("13") == 0
    @test T.parse_month("xyz") == 0
    @test T.parse_month(nothing) == 0

    entry(authors, year) =
        T.BibEntry("article", "Key", ["author" => authors, "year" => year])
    @test T.citation_text(entry("Doe, J.", "2005")) == "Doe (2005)"
    @test T.citation_text(entry("Doe, J. and Roe, R.", "2005")) == "Doe and Roe (2005)"
    @test T.citation_text(entry("Doe, J. and Roe, R. and Moe, A.", "2005")) ==
          "Doe et al. (2005)"
    @test T.citation_text(entry("{Müller}, J.", "2005")) == "Müller (2005)"
    @test T.citation_text(T.BibEntry("misc", "Key", Pair{String,String}[])) == "Key"
end

@testitem "long method names are abbreviated by their initials" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.abbreviate_method("Vibrating tube method") == "VTM"
    @test T.abbreviate_method("Method of the transient hot wire") == "MTHW"
    legend = Dict{String,String}()
    abbreviations = Dict{String,String}()
    shown(name) = T.display_method!(legend, abbreviations, name, 12)
    @test shown("Pycnometer") == "Pycnometer"                       # short: unchanged
    @test shown("Vibrating tube method") == "VTM"
    @test shown("Vibrating tube method") == "VTM"                   # same name, same abbreviation
    @test shown("Vapor transfer method") == "VTM2"                  # different name, same initials
    @test legend ==
          Dict("VTM" => "Vibrating tube method", "VTM2" => "Vapor transfer method")
end

@testitem "central and number formatting" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.central([3.0, 1.0, 2.0], :median) == 2.0
    @test T.central([4.0, 1.0, 2.0, 3.0], :median) == 2.5
    @test T.central([1.0, 2.0, 6.0], :mean) == 3.0
    @test isnan(T.central(Float64[], :median))
    @test T.format_number(273.15, 5) == "273.15"
    @test T.format_number(300.0, 4) == "300"
    @test T.format_number(0.123456, 2) == "0.12"
    @test T.format_number(NaN, 3) == "--"
    @test T.format_range(300.0, 300.0, 4, "–") == "300"
    @test T.format_range(300.0, 425.0, 4, "--") == "300--425"
    @test T.format_range(NaN, NaN, 4, "--") == "--"
    @test T.latex_escape("R&D 50% a_b") == "R\\&D 50\\% a\\_b"
    @test T.latex_escape("25 °C") == "25 \\textdegree{}C"
end

@testitem "reference_summary has a row per article and property, ordered by year" setup =
    [Toy] tags = [:unit, :fast] begin
    using Unitful
    T = ThermophysicalDB
    ds = Toy.build()
    s = T.reference_summary(ds; online = false, cache = false, progress = false)
    @test length(s) == 4
    # a reference without a year comes first, then 1990 (two properties, by name), then 2005
    @test s.key == ["Anonymous", "Moe1990", "Moe1990", "Doe2005"]
    @test s.property == [
        "Thermal conductivity",
        "Mass density",
        "Vapor or sublimation pressure",
        "Thermal conductivity",
    ]
    @test s.n_points == [1, 2, 1, 4]
    @test s.year == [0, 1990, 1990, 2005]
    # default units: K and MPa
    @test s.T_min[4] ≈ 300.0 && s.T_max[4] ≈ 425.0
    @test s.p_min[4] ≈ 1.0 && s.p_max[4] ≈ 12.0
    # a point without pressure gives no range
    @test isnan(s.p_min[3]) && isnan(s.p_max[3])
    # uncertainty: k = 2 given by the source for the first row (0.0002 on 0.02 = 1 %)
    @test s.unc_rel[1] ≈ 1.0
    @test s.n_uncertainty == [1, 2, 0, 4]
    @test isnan(s.unc_rel[3])

    # the units are the user's choice, including affine ones
    sc = T.reference_summary(
        ds;
        temperature_unit = u"°C",
        pressure_unit = u"kPa",
        online = false,
        cache = false,
        progress = false,
    )
    @test sc.T_min[4] ≈ 26.85
    @test sc.p_min[4] ≈ 1000.0 && sc.p_max[4] ≈ 12000.0
    @test sc.temperature_unit == "°C" && sc.pressure_unit == "kPa"

    # mean and median are both available; anything else is an error
    sm = T.reference_summary(
        ds;
        statistic = :mean,
        online = false,
        cache = false,
        progress = false,
    )
    @test sm.statistic === :mean
    @test_throws ArgumentError T.reference_summary(ds; statistic = :mode, online = false)

    # a Tables.jl table
    @test T.Tables.istable(s)
    @test T.Tables.columntable(s).key == s.key
end

@testitem "the summary is written as LaTeX, Markdown and CSV with the keys of the BibTeX" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    s = T.reference_summary(ds; online = false, cache = false, progress = false)

    tex = T.latex_table(s)
    @test occursin("\\begin{longtable}", tex) && occursin("\\end{longtable}", tex)
    @test occursin("\\toprule", tex) &&
          occursin("\\midrule", tex) &&
          occursin("\\bottomrule", tex)
    @test occursin("\\cite{Doe2005}", tex) && occursin("\\cite{Moe1990}", tex)
    # more than one property and system: the columns appear
    @test occursin("Property", tex) && occursin("System", tex)
    @test occursin("\$T\$ [K]", tex) && occursin("\$p\$ [MPa]", tex)
    # the keys are the ones in the BibTeX of the same summary
    bib = T.bibtex(s)
    @test occursin(r"@\w+\{Doe2005,", bib) && occursin(r"@\w+\{Moe1990,", bib)
    # columns can be chosen, and the reference can be written out
    tex2 = T.latex_table(s; columns = [:reference, :points], reference = :text)
    @test occursin("Doe and Roe (2005)", tex2) && !occursin("Property", tex2)

    md = T.markdown_table(s)
    @test occursin("| Reference |", md) && occursin("Doe and Roe (2005)", md)
    @test count(==('\n'), md) >= 6

    csv = T.csv_table(s)
    lines = split(strip(csv), '\n')
    @test length(lines) == 5
    @test startswith(lines[1], "key,doi,year,month,citation")
    @test occursin("T_min [K]", lines[1]) && occursin("p_max [MPa]", lines[1])

    text = sprint(show, MIME"text/plain"(), s)
    @test occursin("ReferenceSummary: 4 rows", text)
    @test_throws ArgumentError T.latex_table(s; columns = [:reference, :nonsense])
end

@testitem "write_references writes the files that agree with each other" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    mktempdir() do tmp
        prefix = joinpath(tmp, "refs")
        s = T.write_references(prefix, ds; online = false, cache = false, progress = false)
        @test s isa T.ReferenceSummary
        for ext in ("bib", "tex", "md", "csv")
            @test isfile("$prefix.$ext")
        end
        @test occursin("\\cite{Doe2005}", read("$prefix.tex", String))
        @test occursin(r"@\w+\{Doe2005,", read("$prefix.bib", String))

        only_bib = joinpath(tmp, "only")
        T.write_references(
            only_bib,
            ds;
            formats = (:bib,),
            online = false,
            cache = false,
            progress = false,
        )
        @test isfile("$only_bib.bib") && !isfile("$only_bib.tex")
        @test_throws ArgumentError T.write_references(
            joinpath(tmp, "x"),
            ds;
            formats = (:pdf,),
            online = false,
            cache = false,
            progress = false,
        )
    end
end
