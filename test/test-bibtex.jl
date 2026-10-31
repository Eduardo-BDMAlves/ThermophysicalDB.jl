@testitem "parse_bibtex reads braces, quotes, bare tokens and nesting" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    text = """
    @article{Some_Key,
      title={A {Nested} title, with comma},
      author = "Müller, Jörg and Roe, R.",
      year = 2006,
      month=jan,
      pages={541–612}
    }
    """
    e = T.parse_bibtex(text)
    @test e.type == "article"
    @test e.key == "Some_Key"
    @test T.field_value(e, "title") == "A {Nested} title, with comma"
    @test T.field_value(e, "author") == "Müller, Jörg and Roe, R."
    @test T.field_value(e, "year") == "2006"
    @test T.field_value(e, "month") == "jan"
    @test T.field_value(e, "pages") == "541–612"
    @test T.field_value(e, "volume") === nothing
    @test T.parse_bibtex("not a bibtex entry") === nothing
    @test T.parse_bibtex("@article{key, title={unbalanced") === nothing
end

@testitem "the resolver's escaped ampersand is cleaned" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.clean_resolver_value("Heat &amp\$\\mathsemicolon\$ mass") == "Heat \\& mass"
    @test T.escape_bibtex("R&D 50% a_b") == "R\\&D 50\\% a\\_b"
    @test T.escape_bibtex("already \\& escaped") == "already \\& escaped"
    @test T.normalize_pages("541-612") == "541--612"
    @test T.normalize_pages("541–612") == "541--612"
    @test T.normalize_pages("e1234") == "e1234"
end

@testitem "letter_suffix counts a, b, ..., z, aa, ab, ..." tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.letter_suffix(1) == "a"
    @test T.letter_suffix(26) == "z"
    @test T.letter_suffix(27) == "aa"
    @test T.letter_suffix(28) == "ab"
    @test T.letter_suffix(52) == "az"
    @test T.letter_suffix(53) == "ba"
    @test T.letter_suffix(702) == "zz"
    @test T.letter_suffix(703) == "aaa"
end

@testitem "mendeley_key is surname, year and first word of the title, in lower case" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    key(author, year, title) = T.mendeley_key(
        T.BibEntry("article", "", ["author" => author, "year" => year, "title" => title]),
    )
    # the pattern of the reference manager
    @test key("Roe, Ann", "1999", "Surfaces, interfaces, and colloids : principles") ==
          "roe1999surfaces"
    # the title is lower-cased, and `The` and `A` are words like any other
    @test key("Poe, W. and Qux, Z.", "2002", "The FORMULATION of a fictitious thing") ==
          "poe2002the"
    @test key("Poe, W.", "2019", "A Comprehensive Review") == "poe2019a"
    # the first word ends at a hyphen, an accent is dropped, a letter that does not
    # decompose is spelled out
    @test key("Doe, J.", "2006", "Particle-stabilized emulsions") == "doe2006particle"
    @test key("Hägglund, Pål", "2001", "Água: Análise") == "hagglund2001agua"
    @test key("Strauß, A.", "2010", "Œuvres complètes") == "strauss2010oeuvres"
    @test key("Façade, A.", "2020", "Estabilidade e reologia") == "facade2020estabilidade"
    # particles stay in the surname and spaces and hyphens vanish
    @test key("da Costa, Anna", "2019", "Análise do impacto") == "dacosta2019analise"
    @test key("de Barros, Carol", "2021", "Análise do efeito") == "debarros2021analise"
    @test key("Abu-Daabes, M. A.", "2005", "Thermal behaviour") == "abudaabes2005thermal"
    # TeX accents and braces in the title
    @test key("K{\\\"o}nig, E.", "2006", "{ThermoML}/Data Archive") == "konig2006thermoml"
    # no year: `sd`; no author: `anonymous`
    @test key("Tad, Tom F. 1937-", "", "Nanodispersions") ==
          "tad" * "sd" * "nanodispersions"
    entry = T.BibEntry("misc", "", ["title" => "bench"])
    @test T.mendeley_key(entry) == "anonymoussdbench"
    @test T.mendeley_key(T.BibEntry("misc", "", Pair{String,String}[])) == "anonymoussd"
end

@testitem "assign_keys! suffixes repeated keys by DOI and never takes a reserved one" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    entry(author, year, title, doi) = T.BibEntry(
        "article",
        "",
        ["author" => author, "year" => string(year), "title" => title, "doi" => doi],
    )
    entries = [
        entry("Roe, Robert D. and Frenkel, Michael", 2003, "Thermal data", "10.1/b"),
        entry("Müller, Erich A.", 2013, "Density", "10.1/m"),
        entry("Roe, R. D.", 1990, "Viscosity of water", "10.1/a"),
        entry("Roe, R. D.", 1990, "Viscosity of ice", "10.1/c"),
        entry("Roe, R. D.", 1990, "Viscosity of steam", "10.1/d"),
        T.BibEntry("misc", "", ["title" => "no author"]),
        entry("van der Waals, J. D.", 1873, "On the continuity", "10.1/w"),
    ]
    T.assign_keys!(entries, Set(["muller2013density"]))
    keys = [e.key for e in entries]
    @test keys[1] == "roe2003thermal"
    # the same surname and year with different words in the title: no suffix needed
    @test keys[3] == keys[4] == keys[5] == "roe1990viscosity" || (
        keys[3] == "roe1990viscositya" &&
        keys[4] == "roe1990viscosityb" &&
        keys[5] == "roe1990viscosityc"
    )
    # a reserved key is never taken
    @test keys[2] == "muller2013densityx"
    @test keys[6] == "anonymoussdno"
    @test keys[7] == "vanderwaals1873on"
    @test allunique(keys)
end

@testitem "merge_entries keeps the resolver, completes it and reports conflicts" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    resolver = T.BibEntry(
        "article",
        "x",
        [
            "title" => "{ThermoML}: an {XML} approach",
            "author" => "Doe, John and Roe, Richard",
            "year" => "2004",
            "journal" => "J. Test",
            "pages" => "1--9",
        ],
    )
    archive = T.BibEntry(
        "article",
        "",
        [
            "author" => "Doe, J. and Roe, R.",
            "title" => "ThermoML: An XML approach",
            "journal" => "Journal of Testing",
            "year" => "2005",
            "volume" => "12",
            "pages" => "1-9",
        ],
    )
    conflicts = []
    merged = T.merge_entries(resolver, archive, "10.1/x", conflicts)
    # the resolver wins on every common field
    @test T.field_value(merged, "year") == "2004"
    @test T.field_value(merged, "journal") == "J. Test"
    # a field only the archive has is added
    @test T.field_value(merged, "volume") == "12"
    # the title, the first author and the pages agree once case and punctuation are ignored
    @test [c.field for c in conflicts] == ["year"]
    @test conflicts[1].resolver == "2004"
    @test conflicts[1].archive == "2005"
    @test conflicts[1].doi == "10.1/x"
end

@testitem "clean_archive_author keeps the full given name from the brackets" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.clean_archive_author("Azizov, N. D.[Nazim D.]") == "Azizov, Nazim D."
    @test T.clean_archive_author("Abu-Daabes, M. A.[Malyuba A.]") ==
          "Abu-Daabes, Malyuba A."
    @test T.clean_archive_author("Doe, J.") == "Doe, J."
end

@testitem "cache_name encodes a DOI as a file name" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.cache_name("10.1021/je034088i") == "10.1021%2Fje034088i.bib"
    @test T.cache_name("10.1002/(SICI)1097") == "10.1002%2F%28SICI%291097.bib"
end

@testitem "bibtex combines the resolver and the archive, with keys and sources" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    resolver = Dict(
        "10.5555/tdbfixture-001" => """
        @article{Doe_2004, title={The title &amp\$\\mathsemicolon\$ more}, volume={12},
          DOI={10.5555/tdbfixture-001}, author={Doe, John and Roe, Richard}, year={2004},
          journal={J. Test}}
        """,
    )
    fetcher = function (doi)
        haskey(resolver, doi) || error("no entry for $doi")
        return resolver[doi]
    end
    text, report = T.build_bibliography(ds; cache = false, progress = false, fetcher)
    @test report.entries == 3
    @test report.resolved == 1
    @test sort(report.archive_only) == ["10.5555/tdbfixture-002", "bench"]
    @test [(c.field, c.resolver, c.archive) for c in report.conflicts] == [("year", "2004", "2005")]

    chunks = split(text, "\n\n"; keepempty = false)
    # the notice comes first and is a BibTeX comment, not an entry
    @test startswith(chunks[1], "@comment{")
    @test occursin("dataset citation: ", chunks[1]) &&
          occursin("not evaluated or endorsed", chunks[1])
    # the request to cite the package is a comment too, ahead of the package entry
    comments = filter(c -> startswith(c, "@comment{"), chunks)
    @test length(comments) == 2 && occursin("please consider citing it", comments[2])
    entries = [T.parse_bibtex(chunk) for chunk in chunks if !startswith(chunk, "@comment{")]
    keys = [e.key for e in entries]
    @test keys == [
        "riccardi2021thermoml",
        "frenkel2006xml",
        "alvessdthermophysicaldb",
        "anonymoussdbench",
        "doe2004the",
        "moe1990",
    ]
    doe = entries[5]
    @test T.field_value(doe, "title") == "The title \\& more"
    @test T.field_value(doe, "year") == "2004"
    @test T.field_value(doe, "volume") == "12"
    moe = entries[6]
    @test T.field_value(moe, "author") == "Moe, A."
    @test T.field_value(moe, "year") == "1990"

    # the same selection without the credit of the source
    bare = T.bibtex(ds; cache = false, progress = false, include_source = false, fetcher)
    @test !occursin("riccardi2021thermoml", bare)
    @test startswith(bare, "@comment{")          # the notice stays even then
    # a selection reaches only its own articles
    water = T.bibtex(
        T.points(ds; component = "water");
        cache = false,
        progress = false,
        include_source = false,
        fetcher,
    )
    @test occursin("Moe", water) && !occursin("Doe", water)
end

@testitem "bibtex caches the resolver and works offline from the cache" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    calls = Ref(0)
    fetcher = function (doi)
        calls[] += 1
        return "@article{k, title={Cached title}, author={Doe, John}, year={2005}, doi={$doi}}"
    end
    mktempdir() do tmp
        withenv("THERMOPHYSICALDB_DATA_DIR" => tmp) do
            first_run = T.bibtex(ds; progress = false, fetcher)
            @test calls[] == 2                      # the two DOIs of the fixture
            @test isfile(joinpath(tmp, "bibtex", T.cache_name("10.5555/tdbfixture-001")))
            second_run = T.bibtex(ds; progress = false, fetcher)
            @test calls[] == 2                      # served from the cache
            @test second_run == first_run
            # offline, with a fetcher that must not be reached
            offline = T.bibtex(
                ds;
                online = false,
                progress = false,
                fetcher = _ -> error("network"),
            )
            @test offline == first_run
            # refresh requests the DOIs again
            T.bibtex(ds; progress = false, refresh = true, fetcher)
            @test calls[] == 4
            # a path to write
            report = T.write_bibtex(
                joinpath(tmp, "refs.bib"),
                ds;
                online = false,
                progress = false,
            )
            @test report isa T.BibtexReport
            @test occursin("@article{", read(joinpath(tmp, "refs.bib"), String))
        end
    end
end

@testitem "the package entries come from CITATION.cff, with a fallback" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        # a fictitious record: the release DOI and the article of the package
        cff = joinpath(tmp, "CITATION.cff")
        write(
            cff,
            """
     cff-version: 1.2.0
     title: ThermophysicalDB.jl
     version: 1.0.0
     doi: 10.5555/zenodo.0000000
     date-released: 2027-03-01
     authors:
       - given-names: Ana
         family-names: Roe
       - name: Fictional Lab
     repository-code: "https://example.invalid/repo"
     preferred-citation:
       type: article
       title: "A fictitious article"
       authors:
         - family-names: Roe
           given-names: Ana
           name-particle: de
       journal: "J. Test"
       year: 2027
       volume: 3
       issue: 2
       start: 10
       end: 20
       doi: 10.5555/article.0001
     """,
        )
        software, article = T.package_entries(cff)
        @test software.key == "roe2027thermophysicaldb" && article.key == "deroe2027a"
        @test software.type == "misc" && article.type == "article"
        @test T.field_value(software, "author") == "Roe, Ana and {Fictional Lab}"
        @test T.field_value(software, "doi") == "10.5555/zenodo.0000000"
        @test T.field_value(software, "version") == "1.0.0"
        @test T.field_value(software, "year") == "2027"
        @test T.field_value(software, "url") == "https://example.invalid/repo"
        @test T.field_value(article, "author") == "de Roe, Ana"
        @test T.field_value(article, "pages") == "10--20"
        @test T.field_value(article, "doi") == "10.5555/article.0001"

        # without a preferred-citation there is only the software
        write(cff, "cff-version: 1.2.0\ntitle: X\nauthors:\n  - family-names: Roe\n")
        @test length(T.package_entries(cff)) == 1

        # a missing or broken file never fails the export
        @test only(T.package_entries(joinpath(tmp, "none.cff"))).key ==
              "alvessdthermophysicaldb"
        write(cff, "title: [unclosed")
        @test only(T.package_entries(cff)).key == "alvessdthermophysicaldb"
    end
    # the file shipped with the package is read
    @test T.package_entries()[1].key == "alvessdthermophysicaldb"
end

@testitem "the package is credited in the .bib only, and can be left out" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    quiet = (; cache = false, progress = false, fetcher = doi -> error("offline"))
    text = T.bibtex(ds; quiet...)
    @test occursin("please consider citing it", text)
    @test occursin("@misc{alvessdthermophysicaldb,", text)
    # the request comes after the sources and before the articles
    at(s) = first(findfirst(s, text))
    @test at("@misc{riccardi2021thermoml,") <
          at("please consider citing") <
          at("@misc{alvessdthermophysicaldb,") <
          at("@misc{doe2005,")

    bare = T.bibtex(ds; include_package = false, quiet...)
    @test !occursin("thermophysicaldb,", bare) && !occursin("consider citing", bare)

    # a custom CFF with an article adds both entries, and their keys are reserved
    mktempdir() do tmp
        cff = joinpath(tmp, "CITATION.cff")
        write(
            cff,
            """
     cff-version: 1.2.0
     title: ThermophysicalDB.jl
     authors:
       - family-names: Roe
         given-names: Ana
     preferred-citation:
       type: article
       title: "A fictitious article"
       authors:
         - family-names: Roe
           given-names: Ana
       year: 2027
       doi: 10.5555/article.0001
     """,
        )
        custom = T.bibtex(ds; package_cff = cff, quiet...)
        @test occursin("@misc{roesdthermophysicaldb,", custom)
        @test occursin("@article{roe2027a,", custom)
        # the tables never mention the package
        s = T.reference_summary(ds; online = false, cache = false, progress = false)
        @test !occursin("ThermophysicalDB", T.csv_table(s; notice = false))
        @test !occursin("ThermophysicalDB", T.latex_table(s; notice = false))
    end

    # the exported .bib carries it unless asked otherwise, and every table stays free of it
    mktempdir() do tmp
        v = T.points(ds; property = "Mass density")
        opts = (; online = false, cache = false, progress = false)
        T.export_points(joinpath(tmp, "a"), v; formats = (:csv,), opts...)
        T.export_points(
            joinpath(tmp, "b"),
            v;
            formats = (:csv,),
            include_package = false,
            opts...,
        )
        @test occursin(
            "@misc{alvessdthermophysicaldb,",
            read(joinpath(tmp, "a", "a.bib"), String),
        )
        @test !occursin(
            "@misc{alvessdthermophysicaldb,",
            read(joinpath(tmp, "b", "b.bib"), String),
        )
        @test !occursin(
            "ThermophysicalDB",
            join(readlines(joinpath(tmp, "a", "a.csv"))[2:end], "\n"),
        )
    end
end

@testitem "the references of CITATION.cff: sources, notice and checks" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    # a one-line record, as the resolver would answer (no multi-line string in a closure: the
    # formatter indents such a string a little more at every run)
    resolver_record(title, second) = string(
        "@article{x, title={",
        title,
        "}, volume={5}, year={2002}, pages={10-20}, ",
        "author={Poe, Will and ",
        second,
        ", Zed}}",
    )
    # the dataset of the notice is the one of the file
    @test T.ARCHIVE_DOI == "10.18434/mds2-2422" && T.ARCHIVE_VERSION == "1.2"
    @test startswith(T.ARCHIVE_CITATION, "Riccardi, D.; Bazyleva, A.;")
    @test endswith(T.ARCHIVE_CITATION, "https://doi.org/10.18434/mds2-2422")
    # the entries that credit the data are the references marked data-source
    sources = T.source_entries()
    @test [e.key for e in sources] == ["riccardi2021thermoml", "frenkel2006xml"]
    @test T.field_value(sources[1], "note") == "Dataset, version 1.2"
    @test T.field_value(sources[1], "title") == "{ThermoML}/Data Archive"
    # the documentation lists every reference, with the access date of the dataset
    everything = T.documentation_entries()
    @test length(everything) == length(T.cff_references(T.CFF)) &&
          allunique(e.key for e in everything)
    @test occursin("accessed 2026-", T.field_value(everything[1], "note"))
    # a `@misc` with a DOI links through the DOI alone (DocumenterCitations has one link slot)
    for e in everything
        e.type == "misc" &&
            T.field_value(e, "doi") !== nothing &&
            @test T.field_value(e, "url") === nothing
    end
    # the exported entry of the same dataset keeps its URL
    @test T.field_value(T.source_entries()[1], "url") !== nothing
    mktempdir() do tmp
        file = T.write_documentation_bibliography(joinpath(tmp, "refs.bib"))
        text = read(file, String)
        @test startswith(text, "% Generated from CITATION.cff")
        for key in ("riccardi2022towards", "frenkel2003thermoml", "chirico2003thermoml")
            @test occursin("{" * key * ",", text)
        end
        @test occursin("Journal of Chemical \\& Engineering Data", text)
    end

    # the shipped file passes its own structural checks
    check = T.check_references(; online = false, cache = false)
    @test isempty(check.problems) && isempty(check)
    @test check.skipped == ["riccardi2021thermoml"]
    articles = length(T.cff_references(T.CFF)) - 1   # all but the dataset
    @test length(check.unresolved) == articles && check.compared == 0
    @test all(u -> occursin("online = false", u.reason), check.unresolved)
    # asking the resolver and getting nothing is a failure, with the reason
    down = T.check_references(; cache = false, fetcher = doi -> error("no route to host"))
    @test !isempty(down) && length(down.unresolved) == articles
    @test all(u -> occursin("no route to host", u.reason), down.unresolved)
    @test occursin("unresolved: ", sprint(show, down))
    # a reply that is not text, or not BibTeX, says what it was
    odd = T.check_references(; cache = false, fetcher = doi -> 42)
    @test all(
        u -> occursin("Int64", u.reason) || occursin("MethodError", u.reason),
        odd.unresolved,
    )
    page = T.check_references(; cache = false, fetcher = doi -> "<html>login</html>")
    @test all(u -> occursin("not a BibTeX entry", u.reason), page.unresolved)

    # a fake resolver: agreement, then a title and an author that differ
    mktempdir() do tmp
        cff = joinpath(tmp, "CITATION.cff")
        write(
            cff,
            """
     cff-version: 1.2.0
     title: X
     authors: [{family-names: Roe}]
     references:
       - type: data
         abbreviation: roe2020dataset
         keywords: [data-source]
         title: "Dataset"
         authors: [{family-names: Roe, given-names: Ann}]
         year: 2020
         version: "1"
         doi: 10.5555/dataset
       - type: article
         abbreviation: poe2002thermal
         keywords: [group]
         title: "Thermal data of a fictitious fluid"
         authors: [{family-names: Poe, given-names: Will}, {family-names: Qux, given-names: Zed}]
         journal: "J. Test"
         year: 2002
         volume: 5
         start: 10
         end: 20
         doi: 10.5555/fixture-a
     """,
        )
        good = doi -> resolver_record("Thermal data of a fictitious fluid", "Qux")
        check = T.check_references(cff; cache = false, fetcher = good)
        @test isempty(check) && check.compared == 1 && check.skipped == ["roe2020dataset"]

        bad = doi -> resolver_record("Another title", "Rux")
        check = T.check_references(cff; cache = false, fetcher = bad)
        @test !isempty(check) &&
              sort([c.field for c in check.conflicts]) == ["author", "title"]

        # a resolver that fails is reported, not an error
        check = T.check_references(cff; cache = false, fetcher = doi -> error("offline"))
        @test !isempty(check) && only(check.unresolved).key == "poe2002thermal"
        @test occursin("offline", only(check.unresolved).reason)
        # tolerated when asked, as with the network off
        tolerant = T.check_references(
            cff;
            cache = false,
            fetcher = doi -> error("offline"),
            require_resolver = false,
        )
        @test isempty(tolerant) && length(tolerant.unresolved) == 1

        # structural problems: a wrong key, a missing keyword, a repeated key
        write(
            cff,
            replace(
                read(cff, String),
                "abbreviation: poe2002thermal" => "abbreviation: Poe2002",
                "keywords: [group]" => "keywords: [misc]",
            ),
        )
        check = T.check_references(cff; online = false, cache = false)
        @test any(contains("should be `poe2002thermal`"), check.problems)
        @test any(contains("needs keywords"), check.problems)
        @test !isempty(check)
    end
end

@testitem "the DOI2BibTeX reply is a Citation, and its text is what is used" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    text = """
        @article{doe2004the,
          title = {The title},
          volume = {12},
          journal = {J. Test},
          author = {Doe, John and Roe, Richard},
          year = {2004},
          pages = {541\u2013612},
          doi = {10.5555/tdbfixture-001}
        }"""
    reply = T.DOI2BibTeX.Citation(text)
    @test T.citation_text(reply) == text
    @test T.citation_text(text) == text
    # a fetcher that returns a Citation, as the real one does, is a resolved article
    ds = Toy.build()
    fetcher = doi -> doi == "10.5555/tdbfixture-001" ? reply : error("no entry")
    out, report = T.build_bibliography(ds; cache = false, progress = false, fetcher)
    @test report.resolved == 1
    # the pages of the resolver are written with the BibTeX range
    @test occursin("pages    = {541--612}", out)
    check = T.check_references(; cache = false, fetcher = doi -> reply)
    @test check.compared == length(T.cff_references(T.CFF)) - 1
end

@testitem "a year that differs by one with the same issue is a note, not a conflict" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        cff = joinpath(tmp, "CITATION.cff")
        write(
            cff,
            """
     cff-version: 1.2.0
     title: X
     authors: [{family-names: Roe}]
     references:
       - type: data
         abbreviation: roe2020dataset
         keywords: [data-source]
         title: "Dataset"
         authors: [{family-names: Roe}]
         year: 2020
         doi: 10.5555/dataset
       - type: article
         abbreviation: poe2003thermal
         keywords: [group]
         title: "Thermal data"
         authors: [{family-names: Poe, given-names: Will}]
         journal: "J. Test"
         year: 2003
         volume: 48
         start: 2
         end: 13
         doi: 10.5555/fixture-a
     """,
        )
        online =
            year ->
                doi ->
                    "@article{x, title={Thermal data}, volume={48}, year={$year}, pages={2-13}, author={Poe, Will}}"
        # the online date is a year earlier: a note
        check = T.check_references(cff; cache = false, fetcher = online(2002))
        @test isempty(check) &&
              isempty(check.conflicts) &&
              only(check.notes).field == "year"
        @test occursin("note: poe2003thermal", sprint(show, check))
        # two years apart, or a different issue, is a conflict
        check = T.check_references(cff; cache = false, fetcher = online(2001))
        @test !isempty(check) && only(check.conflicts).field == "year"
        other =
            doi ->
                "@article{x, title={Thermal data}, volume={49}, year={2002}, pages={2-13}, author={Poe, Will}}"
        check = T.check_references(cff; cache = false, fetcher = other)
        @test sort([c.field for c in check.conflicts]) == ["volume", "year"]
    end
end
