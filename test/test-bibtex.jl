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

@testitem "assign_keys! uses surname and year, and suffixes repeated pairs by DOI" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    entry(author, year, doi) = T.BibEntry(
        "article",
        "",
        ["author" => author, "year" => string(year), "doi" => doi],
    )
    entries = [
        entry("Chirico, Robert D. and Frenkel, Michael", 2003, "10.1/b"),
        entry("Müller, Erich A.", 2013, "10.1/m"),
        entry("Chirico, R. D.", 1990, "10.1/a"),
        entry("Chirico, R. D.", 1990, "10.1/c"),
        T.BibEntry("misc", "", ["title" => "no author"]),
        entry("van der Waals, J. D.", 1873, "10.1/w"),
    ]
    T.assign_keys!(entries, Set(["Muller2013"]))
    keys = [e.key for e in entries]
    # same surname, different years: no suffix; same surname and year: by DOI
    @test keys[1] == "Chirico2003"
    @test keys[3] == "Chirico1990a"
    @test keys[4] == "Chirico1990b"
    # accents are folded; a reserved key is never taken
    @test keys[2] == "Muller2013x"
    # no year: the surname alone
    @test keys[5] == "Anonymous"
    @test keys[6] == "vanderWaals1873"
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

    entries = [T.parse_bibtex(chunk) for chunk in split(text, "\n\n"; keepempty = false)]
    keys = [e.key for e in entries]
    @test keys == ["ThermoMLArchive", "ThermoMLStandard", "Anonymous", "Doe2004", "Moe1990"]
    doe = entries[4]
    @test T.field_value(doe, "title") == "The title \\& more"
    @test T.field_value(doe, "year") == "2004"
    @test T.field_value(doe, "volume") == "12"
    moe = entries[5]
    @test T.field_value(moe, "author") == "Moe, A."
    @test T.field_value(moe, "year") == "1990"

    # the same selection without the credit of the source
    bare = T.bibtex(ds; cache = false, progress = false, include_source = false, fetcher)
    @test !occursin("ThermoMLArchive", bare)
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
