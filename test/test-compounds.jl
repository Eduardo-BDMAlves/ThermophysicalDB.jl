@testmodule CompoundFixture begin
    using ThermophysicalDB: ThermophysicalDB
    using SHA: SHA
    const T = ThermophysicalDB

    # Lists in the format of the chemicals repository: CID, CAS, formula, molar mass, SMILES,
    # InChI (no prefix), InChIKey, IUPAC name, common name and synonyms, separated by tabs.
    row(fields...) = join(fields, '\t')

    const LARGE = [
        row(
            "962",
            "7732-18-5",
            "H2O",
            "18.01528",
            "O",
            "H2O/h1H2",
            "XLYOFNOQVPJJNP-UHFFFAOYSA-N",
            "oxidane",
            "water",
            "distilled water",
            "aqua",
        ),
        row(
            "297",
            "74-82-8",
            "CH4",
            "16.04246",
            "C",
            "CH4/h1H4",
            "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            "methane",
            "methane",
            "marsh gas",
            "méthane",
        ),
        row(
            "5234",
            "7647-14-5",
            "ClNa",
            "58.44277",
            "[Na+].[Cl-]",
            "ClH.Na/h1H;/q;+1/p-1",
            "FAPWRFPIFSIZLT-UHFFFAOYSA-M",
            "sodium;chloride",
            "sodium chloride",
            "salt",
            "halite",
        ),
        row(
            "7843",
            "106-97-8",
            "C4H10",
            "58.1222",
            "CCCC",
            "C4H10/c1-3-4-2/h3-4H2,1-2H3",
            "IJDNQMDRQITEOD-UHFFFAOYSA-N",
            "butane",
            "n-butane",
            "butane",
        ),
        row(
            "6360",
            "75-28-5",
            "C4H10",
            "58.1222",
            "CC(C)C",
            "C4H10/c1-4(2)3/h4H,1-3H3",
            "NNPPMTNAJDCUHE-UHFFFAOYSA-N",
            "2-methylpropane",
            "isobutane",
            "butane",
        ),
        "this line is not a record",
        "",
    ]
    const EXAMPLE = [
        row("-1", "64-17-5", "C2H6O", "46.069", "CCO", "", "", "", "ethyl alcohol", "etoh"),
    ]
    const IONS = [
        row(
            "923",
            "17341-25-2",
            "Na+",
            "22.98977",
            "[Na+]",
            "Na/q+1",
            "FKNQFGJONOIPTF-UHFFFAOYSA-N",
            "sodium(1+)",
            "sodium ion",
            "sodium cation",
        ),
        row(
            "312",
            "16887-00-6",
            "Cl-",
            "35.453",
            "[Cl-]",
            "ClH/h1H/p-1",
            "VEXZGXHMUGYJMC-UHFFFAOYSA-M",
            "chloride",
            "chloride",
            "chloride ion",
        ),
    ]
    # Repeats sodium chloride: its values replace the earlier ones, but a missing PubChem
    # number or InChI does not erase what the earlier list had.
    const INORGANIC = [
        row(
            "-1",
            "7647-14-5",
            "NaCl",
            "58.443",
            "[Na+].[Cl-]",
            "",
            "FAPWRFPIFSIZLT-UHFFFAOYSA-M",
            "sodium chloride",
            "sodium chloride",
            "common salt",
        ),
    ]

    const FILES = [
        "large list.tsv" => LARGE,
        "example list.tsv" => EXAMPLE,
        "ions.tsv" => IONS,
        "inorganic.tsv" => INORGANIC,
    ]

    # A seed that points at files written into `source`, with their real digests.
    function make_seed(source::AbstractString)
        mkpath(source)
        files = T.SeedFile[]
        for (name, lines) in FILES
            path = joinpath(source, name)
            write(path, join(lines, "\n") * "\n")
            push!(
                files,
                T.SeedFile(
                    name,
                    bytes2hex(SHA.sha256(read(path))),
                    "test:" * first(splitext(name)),
                ),
            )
        end
        return T.CompoundSeed(
            "https://example.org/repo",
            "https://example.org/raw",
            "c0ffee",
            "lists",
            files,
        ),
        source
    end

    # A download function that "downloads" from `source` by the file name in the URL.
    function copier(source)
        return function (url, dest; progress = false, kwargs...)
            name = replace(last(split(url, '/')), "%20" => " ")
            cp(joinpath(source, name), dest; force = true)
            return dest
        end
    end

    function database(dir; kwargs...)
        seed, source = make_seed(joinpath(dir, "remote"))
        T.forget_compounds!()
        return T.compound_database(;
            dir = joinpath(dir, "local"),
            seed,
            download = copier(source),
            progress = false,
            kwargs...,
        )
    end

    # ---- a stand-in for PubChem -------------------------------------------------------

    const PUBCHEM = Dict(
        702 => (
            props = Dict(
                "CID" => 702,
                "MolecularFormula" => "C2H6O",
                "MolecularWeight" => "46.07",
                "InChI" => "InChI=1S/C2H6O/c1-2-3/h3H,2H2,1H3",
                "InChIKey" => "LFQSCWFLJHTTHZ-UHFFFAOYSA-N",
                "IUPACName" => "ethanol",
                "SMILES" => "CCO",
                "ConnectivitySMILES" => "CCO",
            ),
            synonyms = [
                "Ethanol",
                "ethyl alcohol",
                "64-17-5",
                "123-45-6",
                "ETHYL ALCOHOL",
                "CHEBI:16236",
            ],
        ),
        5793 => (
            props = Dict(
                "CID" => 5793,
                "MolecularFormula" => "C6H12O6",
                "MolecularWeight" => 180.16,
                "InChIKey" => "WQZGKKKJIJFFOK-GASJEMHNSA-N",
                "IUPACName" => "(2R,3S,4R,5R)-2,3,4,5,6-pentahydroxyhexanal",
                "IsomericSMILES" => "C(C=O)(C(C(C(CO)O)O)O)O",
            ),
            synonyms = ["glucose", "D-glucose", "50-99-7"],
        ),
        107526 => (
            props = Dict(
                "CID" => 107526,
                "MolecularFormula" => "C6H12O6",
                "MolecularWeight" => "180.16",
                "InChIKey" => "GZCGUPFRVQAUEE-SLPGGIOYSA-N",
                "IUPACName" => "(2R,3S,4R,5R)-2,3,4,5,6-pentahydroxyhexanal",
                "CanonicalSMILES" => "C(C=O)(C(C(CO)O)O)O",
            ),
            synonyms = ["aldehydo-D-glucose", "2280-44-6"],
        ),
    )
    const PUBCHEM_NAMES = Dict(
        "ethanol" => [702],
        "64-17-5" => [702],
        "glucose" => [5793, 107526],
        "water" => Int[],
    )

    function respond(body)
        return 200, T.JSON.json(body)
    end

    """
    A `fetch(method, url, body)` that answers like PubChem for the compounds above and records
    every request in `calls`; a name that is not in `PUBCHEM_NAMES` is not found (404).
    """
    function pubchem_fake(calls)
        return function (method, url, body)
            push!(calls, (method, url, body))
            path = replace(url, T.PUBCHEM_BASE * "/" => "")
            parts = split(path, '/')
            if parts[1] == "compound" && parts[(end-1):end] == ["cids", "JSON"]
                value =
                    body === nothing ?
                    Base.unescape_string(replace(parts[3], "%" => "\\x")) :
                    split(body, '=')[2]
                if parts[2] == "name"
                    haskey(PUBCHEM_NAMES, value) || return 404, "{}"
                    isempty(PUBCHEM_NAMES[value]) && return 404, "{}"
                    return respond(
                        Dict("IdentifierList" => Dict("CID" => PUBCHEM_NAMES[value])),
                    )
                elseif parts[2] == "inchikey" && value == "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"
                    return respond(Dict("IdentifierList" => Dict("CID" => [702])))
                elseif parts[2] == "smiles" && value == "CCO"
                    return respond(Dict("IdentifierList" => Dict("CID" => [702])))
                end
                return 404, "{}"
            elseif parts[1] == "compound" &&
                   parts[2] == "inchikey" &&
                   parts[4] == "property"
                for (cid, entry) in PUBCHEM
                    entry.props["InChIKey"] == parts[3] && return respond(
                        Dict("PropertyTable" => Dict("Properties" => [entry.props])),
                    )
                end
                return 404, "{}"
            elseif parts[1] == "compound" && parts[2] == "cid" && parts[4] == "property"
                cids = parse.(Int, split(parts[3], ','))
                found = [PUBCHEM[c].props for c in cids if haskey(PUBCHEM, c)]
                isempty(found) && return 404, "{}"
                return respond(Dict("PropertyTable" => Dict("Properties" => found)))
            elseif parts[1] == "compound" && parts[2] == "cid" && parts[4] == "synonyms"
                cids = parse.(Int, split(parts[3], ','))
                found = [
                    Dict("CID" => c, "Synonym" => PUBCHEM[c].synonyms) for
                    c in cids if haskey(PUBCHEM, c)
                ]
                isempty(found) && return 404, "{}"
                return respond(Dict("InformationList" => Dict("Information" => found)))
            end
            return 400, "unexpected request"
        end
    end

    "Run `f()` with `fetch` instead of the network, and no pauses between retries."
    function with_fetch(f, fetch)
        old = (T.PUBCHEM_FETCH[], T.PUBCHEM_PAUSE[])
        T.PUBCHEM_FETCH[] = fetch
        T.PUBCHEM_PAUSE[] = _ -> nothing
        try
            return f()
        finally
            T.PUBCHEM_FETCH[], T.PUBCHEM_PAUSE[] = old
        end
    end
end

@testitem "the seed is pinned and every file has a digest" tags = [:unit, :fast] begin
    seed = ThermophysicalDB.CHEMICALS_SEED
    @test occursin(r"^[0-9a-f]{40}$", seed.commit)
    @test length(seed.files) == 6
    @test all(f -> occursin(r"^[0-9a-f]{64}$", f.sha256), seed.files)
    @test allunique(f.source for f in seed.files)
    url = ThermophysicalDB.seed_url(seed, first(seed.files))
    @test startswith(
        url,
        "https://raw.githubusercontent.com/CalebBell/chemicals/$(seed.commit)/chemicals/Identifiers/",
    )
    @test !occursin(' ', url) && endswith(url, "large.tsv")
end

@testitem "the database is built from the lists, cached and read without the network" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        # 5 + 1 + 2 compounds, the repeated one counted once
        @test length(db) == 8
        @test db.meta["seed"]["skipped_lines"] == 1
        @test isfile(T.seed_cache_path(joinpath(dir, "local")))
        @test isfile(joinpath(dir, "local", "seed", "large list.tsv"))
        # the second time nothing is downloaded and nothing is parsed
        T.forget_compounds!()
        again = T.compound_database(;
            dir = joinpath(dir, "local"),
            seed = first(CompoundFixture.make_seed(joinpath(dir, "remote2"))),
            download = (args...; kwargs...) -> error("must not download"),
            progress = false,
        )
        @test length(again) == 8
        @test again.names == db.names
        @test isequal(again.molar_mass, db.molar_mass)
        # the same call in the same session returns the same object
        @test T.compound_database(; dir = joinpath(dir, "local")) === again
    end
end

@testitem "repeated compounds are merged, the later list wins and empty values keep the earlier one" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        r = lookup_compounds(db, "FAPWRFPIFSIZLT-UHFFFAOYSA-M")
        @test length(r) == 1
        rec = T.compound_record(db, only(r.id))
        @test rec.formula == "NaCl"                       # the later list
        @test rec.molar_mass == 58.443
        @test rec.cid == 5234                             # -1 does not erase a known CID
        @test rec.inchi == "InChI=1S/ClH.Na/h1H;/q;+1/p-1" # an empty InChI does not either
        @test rec.names[1] == "sodium chloride"
        @test "common salt" in rec.names && "halite" in rec.names && "salt" in rec.names
        @test count(==("sodium chloride"), rec.names) == 1
        @test rec.source == "test:large list"            # where it was first seen
        # without an InChIKey the first name identifies the compound
        e = lookup_compounds(db, "ethyl alcohol")
        @test length(e) == 1 && db.key[only(e.id)] == "name:ethyl alcohol"
    end
end

@testitem "every identifier finds the compound" tags = [:unit] setup = [CompoundFixture] begin
    using Tables: Tables
    T = CompoundFixture.T
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        water = only(lookup_compounds(db, "water").id)
        for (text, kind, by) in (
            ("7732-18-5", :cas, :auto),
            ("xlyofnoqvpjjnp-uhfffaoysa-n", :inchikey, :auto),
            ("962", :cid, :auto),
            ("CID 962", :cid, :cid),
            ("InChI=1S/H2O/h1H2", :inchi, :auto),
            ("H2O/h1H2", :inchi, :inchi),
            ("SMILES=O", :smiles, :auto),
            ("O", :smiles, :smiles),
            ("H2O", :formula, :auto),
            ("Aqua", :name, :auto),
            ("  DISTILLED   water ", :name, :auto),
        )
            r = lookup_compounds(db, text; by)
            @test only(r.id) == water
            @test only(r.match) == kind
        end
        # accents, spelling and the abbreviations of the ordinary search
        @test only(lookup_compounds(db, "METHANE").id) ==
              only(lookup_compounds(db, "méthane").id)
        @test only(lookup_compounds(db, "etoh").id) ==
              only(lookup_compounds(db, "ethyl alcohol").id)
        # a name shared by two compounds lists both
        @test length(lookup_compounds(db, "butane")) == 2
        # a plain "O" is not guessed to be a SMILES; the CAS and CID searches are exact
        @test !(:smiles in lookup_compounds(db, "O").match)
        @test isempty(lookup_compounds(db, "O"; by = :cas))
        # misspelled names give close candidates, identifiers never do
        close = lookup_compounds(db, "sodum chlorid")
        @test :similar in close.match && "sodium chloride" in close.name
        @test isempty(lookup_compounds(db, "7732-18-6"))
        @test_throws ArgumentError lookup_compounds(db, "water"; by = :nope)
        @test_throws ArgumentError lookup_compounds(db, "water"; limit = 0)
        # ions are there too
        @test lookup_compounds(db, "Na+").name == ["sodium ion"]
        @test lookup_compounds(db, "chloride").formula == ["Cl-"]
        # the table is a Tables.jl table and prints
        r = lookup_compounds(db, "butane")
        @test Tables.columntable(r).formula == ["C4H10", "C4H10"]
        @test occursin("n-butane", sprint(show, r))
    end
end

@testitem "what the user adds survives an update of the list and wins over it" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        id = register_compound!(
            db;
            names = ["cesium formate", "caesium formate"],
            inchikey = "WLHQEXWBUBNKIO-UHFFFAOYSA-N",
            cas = "3495-36-1",
            formula = "CHCsO2",
            molar_mass = 177.92,
        )
        # completing a row that is in the list: the user's values and names go first
        water = register_compound!(
            db;
            names = ["H2O (mine)"],
            inchikey = "XLYOFNOQVPJJNP-UHFFFAOYSA-N",
            molar_mass = 18.015,
        )
        @test length(db) == 9
        rec = T.compound_record(db, water)
        @test rec.molar_mass == 18.015 &&
              rec.names[1] == "H2O (mine)" &&
              "water" in rec.names
        @test rec.custom && rec.formula == "H2O" && rec.cid == 962
        @test T.compound_record(db, id).custom
        @test count(db.custom) == 2
        path = save_compounds(db; dir = joinpath(dir, "local"))
        @test isfile(path)
        # rebuilding the list from scratch keeps them
        again = CompoundFixture.database(dir; rebuild = true)
        @test length(again) == 9
        @test only(lookup_compounds(again, "caesium formate").id) == id
        @test again.molar_mass[id] == 177.92
        @test T.compound_record(again, water).molar_mass == 18.015
        @test count(again.custom) == 2
        # a compound needs an InChIKey or a name
        @test_throws ArgumentError register_compound!(again; names = String[])
    end
end

@testitem "a damaged download is rejected and explained" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        seed, source = CompoundFixture.make_seed(joinpath(dir, "remote"))
        bad = function (url, dest; progress = false, kwargs...)
            write(dest, "not the file")
            return dest
        end
        T.forget_compounds!()
        @test_throws T.ChecksumMismatchError T.compound_database(;
            dir = joinpath(dir, "local"),
            seed,
            download = bad,
            progress = false,
        )
        @test !isfile(joinpath(dir, "local", "seed", seed.files[1].name))
        @test !isfile(joinpath(dir, "local", "seed", seed.files[1].name * ".part"))
        # a failed download tells where to get the files, not about the NIST archive
        failing = (url, dest; kwargs...) -> throw(T.DownloadError(url, ["no route"]))
        err = try
            T.compound_database(;
                dir = joinpath(dir, "local"),
                seed,
                download = failing,
                progress = false,
            )
        catch e
            e
        end
        @test err isa T.DownloadError
        text = sprint(showerror, err)
        @test occursin("example.org/repo/tree/c0ffee/lists", text) &&
              !occursin("nist", lowercase(text))
        # the NIST message is unchanged
        @test occursin("data.nist.gov", sprint(showerror, T.DownloadError("u", ["x"])))
        # a file the user copied by hand with the right digest is used as it is
        mkpath(joinpath(dir, "local", "seed"))
        for f in seed.files
            cp(joinpath(source, f.name), joinpath(dir, "local", "seed", f.name))
        end
        T.forget_compounds!()
        db = T.compound_database(;
            dir = joinpath(dir, "local"),
            seed,
            download = (args...; kwargs...) -> error("must not download"),
            progress = false,
        )
        @test length(db) == 8
    end
end

@testitem "compounds of the dataset are linked, and the dataset is left alone" tags =
    [:unit] setup = [CompoundFixture] begin
    using Tables: Tables
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        ds = T.Dataset()
        add(; kwargs...) = T.add_compound!(ds.compounds; kwargs...)
        water = add(
            inchikey = "XLYOFNOQVPJJNP-UHFFFAOYSA-N",
            inchi = "InChI=1S/H2O/h1H2",
            names = ["water"],
            formula = "H2O",
        )
        methane = add(
            inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            names = ["methane"],
            formula = "H4C",
        )
        by_inchi = add(
            inchikey = "ZZZZZZZZZZZZZZ-UHFFFAOYSA-N",
            inchi = "InChI=1S/ClH.Na/h1H;/q;+1/p-1",
            names = ["brine salt"],
            formula = "NaCl",
        )
        by_name = add(names = ["Halite"], formula = "C2H4")
        shared = add(names = ["butane"])
        isotope = add(
            inchikey = "IJDNQMDRQITEOD-UNQQEJLLSA-N",
            inchi = "InChI=1S/C4H10/c1-3-4-2/h3-4H2,1-2H3/i1D3",
            names = ["n-butane"],
            formula = "C4H7D3",
        )
        other = add(
            inchikey = "XXXXXXXXXXXXXX-UHFFFAOYSA-N",
            inchi = "InChI=1S/C9H20/c1-3-5-7-9-8-6-4-2/h3-9H2,1-2H3",
            names = ["isobutane"],
            formula = "C9H20",
        )
        unknown = add(names = ["unobtainium"], formula = "Xx")
        before = (length(ds.compounds), copy(ds.compounds.names), copy(ds.compounds.key))
        linked = link_compounds(ds, cdb)
        @test linked isa LinkedDatabase && linked.dataset === ds
        links = linked.links
        @test (length(ds.compounds), ds.compounds.names, ds.compounds.key) == before
        rows(c) = findall(==(Int32(c)), links.compound)
        @test links.via[only(rows(water))] == :inchikey
        @test links.record_cas[only(rows(water))] == "7732-18-5"
        @test links.molar_mass[only(rows(water))] == 18.01528
        @test links.formula_check[only(rows(water))] == :same
        @test links.formula_check[only(rows(methane))] == :same      # "H4C" is "CH4"
        @test links.via[only(rows(by_inchi))] == :inchi
        @test links.record_formula[only(rows(by_inchi))] == "NaCl"
        @test links.via[only(rows(by_name))] == :name
        @test links.formula_check[only(rows(by_name))] == :different  # the dataset says C2H4
        @test length(rows(shared)) == 2 && all(==(2), links.candidates[rows(shared)])
        @test all(==(:name), links.via[rows(shared)])
        @test links.record[only(rows(unknown))] == 0 &&
              links.via[only(rows(unknown))] == :none
        @test links.formula_check[only(rows(unknown))] == :unknown
        @test links.inchi_check[only(rows(water))] == :same
        @test links.inchi_check[only(rows(by_inchi))] == :same
        @test links.inchi_check[only(rows(by_name))] == :unknown      # the dataset has no InChI for it
        # the same skeleton with other isotopes is related, not the same compound
        @test links.via[only(rows(isotope))] == :name
        @test links.inchi_check[only(rows(isotope))] == :stereo
        # a name that leads to a different skeleton is flagged
        @test links.inchi_check[rows(other)[1]] == :different
        @test links.formula_check[rows(other)[1]] == :different
        # by_name = false links only by InChIKey and InChI
        strict = link_compounds(ds, cdb; by_name = false).links
        @test :name ∉ strict.via
        @test strict.record[only(findall(==(Int32(by_name)), strict.compound))] == 0
        @test occursin("found in the compound database", sprint(show, links))
        @test occursin("LinkedDatabase", sprint(show, linked))
        @test length(Tables.columntable(links).compound) == length(links)
        @test Tables.columntable(linked).compound == links.compound
    end
end

@testitem "the ordinary search also understands the compound database" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        ds = T.Dataset()
        water = T.add_compound!(
            ds.compounds;
            inchikey = "XLYOFNOQVPJJNP-UHFFFAOYSA-N",
            names = ["water"],
            formula = "H2O",
        )
        T.add_compound!(ds.compounds; names = ["oxidane"], formula = "H2O")       # a name only, no InChIKey
        other = T.add_compound!(
            ds.compounds;
            inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            names = ["methane"],
        )
        @test isempty(find_compounds(ds, "7732-18-5"))                           # the dataset alone does not know the CAS
        found = find_compounds(ds, cdb, "7732-18-5")
        @test found.id[1] == water && :exact in found.match
        @test find_compounds(ds, cdb, "962").id[1] == water
        @test find_compounds(ds, cdb, "aqua").id[1] == water                     # a synonym no article used
        # a compound that has no InChIKey is reached only through its own names
        @test length(find_compounds(ds, cdb, "aqua")) == 1
        found = find_compounds(ds, cdb, "oxidane")
        @test water in found.id && 2 in found.id
        # what the dataset alone finds is still found
        @test find_compounds(ds, cdb, "methane").id[1] == other
        @test isempty(find_compounds(ds, cdb, "unobtainium"))
        @test_throws ArgumentError find_compounds(ds, cdb, "water"; limit = 0)
    end
end

@testitem "formulas are compared by their elements" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.element_counts("C2H6O") == Dict("C" => 2, "H" => 6, "O" => 1)
    @test T.element_counts("CaCl2") == Dict("Ca" => 1, "Cl" => 2)
    @test T.element_counts("H2O2") == Dict("H" => 2, "O" => 2)
    @test T.element_counts("Na+") === nothing
    @test T.element_counts("CaCl2.6H2O") === nothing
    @test T.element_counts("") === nothing
    @test T.compare_formulas("C2H6O", "H6C2O") == :same
    @test T.compare_formulas("C2H6O", "C2H6") == :different
    @test T.compare_formulas("CaCl2", "CaCl2") == :same
    @test T.compare_formulas("Na+", "Na+") == :same
    @test T.compare_formulas("Na+", "Na") == :unknown
    @test T.compare_formulas("", "H2O") == :unknown
end

@testitem "InChIs are compared by skeleton and by stereochemistry" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    z = "InChI=1S/C6H12/c1-3-5-6-4-2/h3,5H,4,6H2,1-2H3"
    @test T.compare_inchis(z * "/b5-3+", z * "/b5-3-") == :stereo
    @test T.compare_inchis(z * "/b5-3+", z * "/b5-3+") == :same
    @test T.compare_inchis(z, z * "/b5-3+") == :stereo
    @test T.compare_inchis("InChI=1S/H2O/h1H2", "InChI=1S/H2O/h1H2/i1D2") == :stereo
    @test T.compare_inchis("InChI=1S/H2O/h1H2", "InChI=1S/CH4/h1H4") == :different
    @test T.compare_inchis("H2O/h1H2", "InChI=1S/H2O/h1H2") == :same
    @test T.compare_inchis("", "InChI=1S/H2O/h1H2") == :unknown
end

@testitem "text columns are packed and unpacked without loss" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    values = ["a", "", "ünï", "a b", "line\nbreak", ""]
    packed = T.pack_strings(values)
    @test T.unpack_strings(packed, length(values)) ==
          ["a", "", "ünï", "a b", "line break", ""]
    @test T.unpack_strings(T.pack_strings(String[]), 0) == String[]
    @test T.unpack_strings(T.pack_strings([""]), 1) == [""]
    @test_throws ArgumentError T.unpack_strings(packed, 3)
end

@testitem "the fast name normalisation agrees with the Unicode one" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    slow(t) = (
        f = Base.Unicode.normalize(t; casefold = true, stripmark = true);
        String(filter(c -> isletter(c) || isdigit(c), f))
    )
    for text in (
        "Iso-Butane",
        "n-Hexane",
        "1,2-ethanediol",
        " Sodium  Chloride ",
        "(2R)-propan-2-ol",
        "CO2",
        "",
        "---",
        "H2O/h1H2",
        "Na+",
        "café",
        "Ångström",
    )
        @test T.normalize_name(text) == slow(text)
    end
end

@testitem "identifiers are normalised as written" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.normalize_cas(" 7732-18-5 ") == "7732-18-5"
    @test T.normalize_cas("7732185") == ""
    @test T.inchi_body("InChI=1S/H2O/h1H2") == "H2O/h1H2"
    @test T.inchi_body("InChI=1/H2O/h1H2") == "H2O/h1H2"
    @test T.inchi_body("H2O/h1H2") == "H2O/h1H2"
    @test T.full_inchi("H2O/h1H2") == "InChI=1S/H2O/h1H2"
    @test T.full_inchi("InChI=1S/H2O/h1H2") == "InChI=1S/H2O/h1H2"
    @test T.full_inchi("") == ""
    @test T.identifier_kind("7732-18-5") == :cas
    @test T.identifier_kind("xlyofnoqvpjjnp-uhfffaoysa-n") == :inchikey   # case does not matter
    @test T.identifier_kind("XLYOFNOQVPJJNP-UHFFFAOYSA") == :name
    @test T.identifier_kind("XLYOFNOQVPJJNP-UHFFFAOYSA-N") == :inchikey
    @test T.identifier_kind("InChI=1S/H2O/h1H2") == :inchi
    @test T.identifier_kind("smiles=CCO") == :smiles
    @test T.identifier_kind("water") == :name
end

@testitem "a linked database finds a compound by any identifier and asks when it is ambiguous" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        ds = T.Dataset()
        mole = T.intern!(ds.kinds, "Mole fraction")
        source = T.intern!(ds.sources, "thermoml")
        ref = T.add_reference!(ds.references; doi = "10.5555/linked-001", source)
        add(; kwargs...) = T.add_compound!(ds.compounds; kwargs...)
        water = add(
            inchikey = "XLYOFNOQVPJJNP-UHFFFAOYSA-N",
            inchi = "InChI=1S/H2O/h1H2",
            names = ["water"],
            formula = "H2O",
        )
        methane = add(
            inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            names = ["methane"],
            formula = "CH4",
        )
        nbutane = add(
            inchikey = "IJDNQMDRQITEOD-UHFFFAOYSA-N",
            names = ["n-butane"],
            formula = "C4H10",
        )
        isobutane = add(
            inchikey = "NNPPMTNAJDCUHE-UHFFFAOYSA-N",
            names = ["isobutane"],
            formula = "C4H10",
        )
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        for (compounds, n) in (
            ([water], 3),
            ([methane], 2),
            ([nbutane], 5),
            ([isobutane], 1),
            ([water, methane], 4),
        )
            e = T.add_experiment!(
                ds.experiments;
                reference = ref,
                components = compounds,
                kinds = fill(mole, length(compounds)),
            )
            for i = 1:n
                T.add_measurement!(
                    ds.measurements;
                    experiment = e,
                    property = density,
                    temperature = 290.0 + i,
                    pressure = 101.325,
                    value = 1.0,
                )
            end
        end
        linked = link_compounds(ds, cdb)
        used(view) = sort!(unique(view.dataset.measurements.experiment[view.rows]))

        # a synonym, a CAS number and a CID that no article used lead to the same compound
        @test length(points(linked; component = "oxidane")) == 3 + 4
        @test length(points(linked; component = "7732-18-5")) == 3 + 4
        @test length(points(linked; component = "962")) == 3 + 4
        @test length(points(linked; component = "water", exact = true)) == 3
        # everything else of `points` still works, and an integer id or a vector is accepted
        @test length(points(linked; component = ["aqua", "methane"], match = :all)) == 4
        @test length(points(linked; component = Int(water))) == 3 + 4
        @test length(points(linked)) == length(points(ds))
        @test length(mixture(linked, "7732-18-5", "74-82-8")) == 4
        @test_throws ArgumentError mixture(linked, "water")
        @test find_compounds(linked, "oxidane").id == find_compounds(ds, cdb, "oxidane").id

        # a formula shared by two isomers is ambiguous
        @test_throws ArgumentError points(linked; component = "C4H10", choose = :error)
        err = try
            points(linked; component = "C4H10", choose = :error)
        catch e
            e
        end
        message = sprint(showerror, err)
        @test occursin("matches 2 compounds", message) &&
              occursin("n-butane", message) &&
              occursin("isobutane", message) &&
              occursin("106-97-8", message)
        # not interactive, no answer prepared: no guess either (the input is stdin)
        @test_throws ArgumentError points(linked; component = "C4H10")

        # the menu is ordered by number of points: 1 is n-butane (5), 2 is isobutane (1)
        out = IOBuffer()
        view = points(linked; component = "C4H10", input = IOBuffer("2\n"), output = out)
        @test length(view) == 1
        menu = String(take!(out))
        @test occursin("1. n-butane", replace(menu, r"\s+" => " ")) ||
              occursin("n-butane", menu)
        @test occursin("Which one?", menu)
        # the answer is remembered for the same text
        @test haskey(linked.choices, "c4h10")
        @test length(points(linked; component = "c4h10", choose = :error)) == 1
        forget_choices!(linked)
        @test isempty(linked.choices)
        # an invalid answer asks again; "a" takes all of them; "q" cancels
        out = IOBuffer()
        view = points(
            linked;
            component = "C4H10",
            input = IOBuffer("7\nxyz\na\n"),
            output = out,
        )
        @test length(view) == 6
        @test occursin("Not a valid answer", String(take!(out)))
        forget_choices!(linked)
        @test_throws ArgumentError points(
            linked;
            component = "C4H10",
            input = IOBuffer("q\n"),
            output = IOBuffer(),
        )
        @test_throws ArgumentError points(
            linked;
            component = "C4H10",
            input = IOBuffer(""),
            output = IOBuffer(),
        )
        @test isempty(linked.choices)
        # prepared answers: a number, :all, or a symbol for every text
        @test length(points(linked; component = "C4H10", choose = Dict("c4h10" => 1))) == 5
        forget_choices!(linked)
        @test length(points(linked; component = "C4H10", choose = Dict("C4H10" => 2))) == 1
        forget_choices!(linked)
        @test length(points(linked; component = "C4H10", choose = :all)) == 6
        @test isempty(linked.choices)                       # :all is not remembered
        @test length(points(linked; component = "C4H10", choose = Dict("C4H10" => :all))) ==
              6
        forget_choices!(linked)
        @test_throws ArgumentError points(
            linked;
            component = "C4H10",
            choose = Dict("C4H10" => 3),
        )
        @test_throws ArgumentError points(
            linked;
            component = "C4H10",
            choose = Dict("C4H10" => "x"),
        )
        @test_throws ArgumentError points(linked; component = "C4H10", choose = :maybe)
        @test_throws ArgumentError points(linked; component = "C4H10", choose = 1)
        # a mixture asks for each ambiguous component
        view = mixture(
            linked,
            "C4H10",
            "74-82-8";
            exact = false,
            input = IOBuffer("1\n"),
            output = IOBuffer(),
        )
        @test isempty(view)                                  # no butane + methane system exists
        forget_choices!(linked)

        # a close but inexact name is never taken without an answer
        @test_throws ArgumentError points(linked; component = "watr", choose = :all)
        @test_throws ArgumentError points(linked; component = "watr", choose = :error)
        @test length(
            points(
                linked;
                component = "watr",
                input = IOBuffer("1\n"),
                output = IOBuffer(),
            ),
        ) == 3 + 4
        forget_choices!(linked)
        # known by the compound database but not in the dataset
        err = try
            points(linked; component = "ethyl alcohol")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("compound database", sprint(showerror, err)) ||
              occursin("no compound", sprint(showerror, err))
        # unknown everywhere
        @test_throws ArgumentError points(linked; component = "unobtainium")
    end
end

@testitem "register_compound! can save what it adds, and does not by default" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        path = T.custom_cache_path(joinpath(dir, "local"))
        first_id = register_compound!(db; names = ["compound one"], molar_mass = 10.0)
        @test !isfile(path)                                   # not saved unless asked
        second_id = register_compound!(
            db;
            names = ["cesium formate"],
            inchikey = "WLHQEXWBUBNKIO-UHFFFAOYSA-N",
            molar_mass = 177.92,
            save = true,
        )
        @test isfile(path)                                    # in the folder it was loaded from
        again = CompoundFixture.database(dir; rebuild = true)
        @test only(lookup_compounds(again, "compound one").id) == first_id   # saved with it
        @test again.molar_mass[second_id] == 177.92
        @test count(again.custom) == 2
        # another folder on request
        other = joinpath(dir, "other")
        register_compound!(db; names = ["compound two"], save = true, dir = other)
        @test isfile(T.custom_cache_path(other))
    end
end

@testitem "what PubChem answers is read, and a question is built from a text" tags =
    [:unit, :fast] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    @test T.valid_cas("64-17-5") && T.valid_cas("7732-18-5") && T.valid_cas("50-99-7")
    @test !T.valid_cas("123-45-6") && !T.valid_cas("64-17") && !T.valid_cas("water")
    @test T.percent_encode("1-butyl 3/methyl") == "1-butyl%203%2Fmethyl"
    @test T.percent_encode("é") == "%C3%A9"
    @test T.needs_post("a/b") && !T.needs_post("ethanol")
    @test T.pubchem_kind("64-17-5", :auto) == :name
    @test T.pubchem_kind("962", :auto) == :cid
    @test T.pubchem_kind("LFQSCWFLJHTTHZ-UHFFFAOYSA-N", :auto) == :inchikey
    @test T.pubchem_kind("SMILES=CCO", :auto) == :smiles
    @test T.pubchem_kind("InChI=1S/H2O/h1H2", :auto) == :inchi
    @test T.pubchem_kind("anything", :cas) == :name
    @test_throws ArgumentError T.pubchem_kind("H2O", :formula)
    @test T.pubchem_value("SMILES=CCO", :smiles) == "CCO"
    @test T.pubchem_value("cid: 702", :cid) == "702"
    @test T.pubchem_value("lfqscwfltjhthz-uhfffaoysa-n", :inchikey) ==
          "LFQSCWFLTJHTHZ-UHFFFAOYSA-N"
    # the answer is read under any of the names PubChem has used for the SMILES
    for key in ("SMILES", "IsomericSMILES", "ConnectivitySMILES", "CanonicalSMILES")
        record = T.pubchem_record(Dict("CID" => 1, key => "CCO"), String[])
        @test record.smiles == "CCO"
    end
    ethanol = CompoundFixture.PUBCHEM[702]
    record = T.pubchem_record(ethanol.props, ethanol.synonyms)
    @test record.cid == 702 && record.formula == "C2H6O" && record.molar_mass == 46.07
    @test record.cas == "64-17-5"                       # "123-45-6" fails the check digit
    @test record.names[1] == "Ethanol"
    @test count(==("ethyl alcohol"), lowercase.(record.names)) == 1   # no repeated spelling
    @test "64-17-5" ∉ record.names
    # the molar mass may be a number or a text, and may be missing
    @test T.pubchem_record(Dict("CID" => 1, "MolecularWeight" => 18.015), String[]).molar_mass ==
          18.015
    @test isnan(T.pubchem_record(Dict("CID" => 1), String[]).molar_mass)
    many = ["name $i" for i = 1:60]
    @test length(T.pubchem_record(Dict("CID" => 1), many).names) == T.PUBCHEM_MAX_NAMES
    @test_throws ArgumentError T.pubchem_rate!(0)
    old = T.PUBCHEM_RATE[]
    @test T.pubchem_rate!(2) == 2.0 && T.PUBCHEM_RATE[] == 2.0
    T.PUBCHEM_RATE[] = old
end

@testitem "PubChem answers are kept as JSON, loaded again and never asked twice in vain" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        folder = joinpath(dir, "local")
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            before = length(cdb)
            ids = fetch_pubchem!(cdb, "ethanol")
            @test length(ids) == 1 && length(cdb) == before + 1
            record = T.compound_record(cdb, only(ids))
            @test record.cid == 702 && record.cas == "64-17-5" && record.source == "pubchem"
            @test record.names[1] == "Ethanol" && record.molar_mass == 46.07
            @test record.inchikey == "LFQSCWFLJHTTHZ-UHFFFAOYSA-N" && !record.custom
            @test length(calls) == 3                       # the CID, the properties, the synonyms
            @test all(c -> c[1] == "GET", calls)
            # the raw answer is kept, with the date and the question
            file = T.pubchem_file(folder, 702)
            @test isfile(file)
            document = T.JSON.parse(read(file, String))
            @test document["cid"] == 702 && document["query"] == "ethanol"
            @test document["properties"]["InChIKey"] == "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"
            @test "64-17-5" in document["synonyms"] && haskey(document, "retrieved")
            # the database knows it now: nothing is asked, the rows it has are returned
            n = length(calls)
            @test fetch_pubchem!(cdb, "ethanol") == ids
            @test ids ⊆ fetch_pubchem!(cdb, "64-17-5")      # the seed row has this CAS too
            @test fetch_pubchem!(cdb, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N") == ids
            @test fetch_pubchem!(cdb, "702") == ids
            @test length(calls) == n
            # force = true asks which CID it is; the rest is read from the file
            @test fetch_pubchem!(cdb, "ethanol"; force = true) == ids
            @test length(calls) == n + 1
            # refresh asks for everything again
            fetch_pubchem!(cdb, "ethanol"; refresh = true)
            @test length(calls) == n + 4
            # a compound can be asked by InChIKey, by a SMILES (in the body) and by CID
            empty!(calls)
            @test fetch_pubchem!(cdb, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"; force = true) == ids
            @test occursin("/inchikey/", calls[1][2])
            @test fetch_pubchem!(cdb, "SMILES=CCO"; force = true) == ids
            @test any(c -> c[1] == "POST" && c[3] == "smiles=CCO", calls)
            @test fetch_pubchem!(cdb, "702"; force = true) == ids
            @test fetch_pubchem!(cdb, "702"; by = :cid, force = true) == ids
            @test_throws ArgumentError fetch_pubchem!(cdb, "H2O"; by = :formula)
            @test_throws ArgumentError fetch_pubchem!(cdb, "   ")
            @test_throws ArgumentError fetch_pubchem!(cdb, "ethanol"; limit = 0)
        end
        # a new session reads the files and finds the compound without the network
        again = CompoundFixture.database(dir; reload = true)
        found = lookup_compounds(again, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N")
        @test length(found) == 1 && again.cas[only(found.id)] == "64-17-5"
        @test only(lookup_compounds(again, "Ethanol").id) == only(found.id)
        # a damaged file is ignored with a warning, the rest still loads
        write(T.pubchem_file(folder, 999), "not json")
        damaged =
            @test_logs (:warn, r"could not be read") match_mode = :any CompoundFixture.database(
                dir;
                reload = true,
            )
        @test length(lookup_compounds(damaged, "ethanol")) == 1
        # what the user registers goes on top of what PubChem said
        register_compound!(
            again;
            names = ["Ethanol"],
            inchikey = "LFQSCWFLJHTTHZ-UHFFFAOYSA-N",
            molar_mass = 46.0,
        )
        @test again.molar_mass[only(found.id)] == 46.0
    end
end

@testitem "a question PubChem cannot answer is remembered for 180 days" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        folder = joinpath(dir, "local")
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            before = length(cdb)
            @test isempty(fetch_pubchem!(cdb, "unobtainium"))
            @test length(cdb) == before && length(calls) == 1
            @test isfile(T.pubchem_missing_path(folder))
            @test haskey(T.read_pubchem_missing(folder), "name:unobtainium")
            # not asked again ...
            @test_logs (:info, r"had nothing") fetch_pubchem!(cdb, "Unobtainium")
            @test length(calls) == 1
            # ... unless asked to
            @test isempty(fetch_pubchem!(cdb, "unobtainium"; refresh = true))
            @test length(calls) == 2
            # or when the answer is older than 180 days
            missing = T.read_pubchem_missing(folder)
            missing["name:unobtainium"] = string(T.Dates.today() - T.Dates.Day(181))
            open(io -> T.TOML.print(io, missing), T.pubchem_missing_path(folder), "w")
            @test !T.known_missing(folder, "name:unobtainium") == true
            @test isempty(fetch_pubchem!(cdb, "unobtainium"))
            @test length(calls) == 3
            missing["name:unobtainium"] = string(T.Dates.today() - T.Dates.Day(179))
            open(io -> T.TOML.print(io, missing), T.pubchem_missing_path(folder), "w")
            @test T.known_missing(folder, "name:unobtainium")
            # a name that is found later is no longer missing
            T.record_missing!(folder, "name:ethanol")
            @test !isempty(fetch_pubchem!(cdb, "ethanol"; refresh = true))
            @test !haskey(T.read_pubchem_missing(folder), "name:ethanol")
        end
        # a damaged list of questions is ignored
        write(T.pubchem_missing_path(folder), "= = =")
        @test_logs (:warn, r"was ignored") @test isempty(T.read_pubchem_missing(folder))
    end
end

@testitem "several compounds for one text: the user chooses" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        folder = joinpath(dir, "local")
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            before = length(cdb)
            err = try
                fetch_pubchem!(cdb, "glucose"; choose = :error)
            catch e
                e
            end
            @test err isa ArgumentError
            message = sprint(showerror, err)
            @test occursin("matches 2 compounds in PubChem", message) &&
                  occursin("CID 5793", message) &&
                  occursin("CID 107526", message) &&
                  occursin("180.16 g/mol", message)
            @test length(cdb) == before                  # nothing is added without an answer
            # not interactive and nothing prepared: no guess either (the input is stdin)
            @test_throws ArgumentError fetch_pubchem!(cdb, "glucose")
            # the menu, in the order PubChem gives
            out = IOBuffer()
            ids = fetch_pubchem!(cdb, "glucose"; input = IOBuffer("2\n"), output = out)
            @test length(ids) == 1 && cdb.cid[only(ids)] == 107526
            @test "glucose" in lowercase.(cdb.names[only(ids)])   # the text PubChem matched
            @test occursin("Which one?", String(take!(out)))
            @test isfile(T.pubchem_file(folder, 107526))
            @test !isfile(T.pubchem_file(folder, 5793))  # only the chosen one is kept
            # an invalid answer asks again; "a" takes both; "q" and no answer cancel
            out = IOBuffer()
            ids = fetch_pubchem!(
                cdb,
                "glucose";
                force = true,
                input = IOBuffer("9\nxyz\na\n"),
                output = out,
            )
            @test length(ids) == 2 && isfile(T.pubchem_file(folder, 5793))
            @test occursin("Not a valid answer", String(take!(out)))
            for answer in ("q\n", "")
                @test_throws ArgumentError fetch_pubchem!(
                    cdb,
                    "glucose";
                    force = true,
                    input = IOBuffer(answer),
                    output = IOBuffer(),
                )
            end
            # prepared answers
            @test cdb.cid[only(
                fetch_pubchem!(cdb, "glucose"; force = true, choose = Dict("Glucose" => 1)),
            )] == 5793
            @test length(fetch_pubchem!(cdb, "glucose"; force = true, choose = :all)) == 2
            @test length(
                fetch_pubchem!(
                    cdb,
                    "glucose";
                    force = true,
                    choose = Dict("glucose" => :all),
                ),
            ) == 2
            @test_throws ArgumentError fetch_pubchem!(
                cdb,
                "glucose";
                force = true,
                choose = Dict("glucose" => 3),
            )
            @test_throws ArgumentError fetch_pubchem!(
                cdb,
                "glucose";
                force = true,
                choose = :maybe,
            )
            # at most `limit` candidates are offered
            @test length(fetch_pubchem!(cdb, "glucose"; force = true, limit = 1)) == 1
        end
    end
end

@testitem "PubChem busy, unreachable or refusing: retries, then a clear error and no change" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        inner = CompoundFixture.pubchem_fake([])
        function flaky(failures, status)
            count = Ref(0)
            return function (method, url, body)
                count[] += 1
                count[] <= failures && return status, "busy"
                return inner(method, url, body)
            end
        end
        # two busy answers, then the real one
        pauses = Float64[]
        old = T.PUBCHEM_PAUSE[]
        try
            CompoundFixture.with_fetch(flaky(2, 503)) do
                T.PUBCHEM_PAUSE[] = seconds -> push!(pauses, seconds)
                @test length(fetch_pubchem!(cdb, "ethanol")) == 1
            end
        finally
            T.PUBCHEM_PAUSE[] = old
        end
        @test pauses == [2, 5]
        before = length(cdb)
        # always busy, or no answer at all: PubChemError, with advice, and nothing added
        for (status, expected) in ((503, "busy"), (0, "did not answer"))
            forever = (m, u, b) -> (status, "no connection")
            CompoundFixture.with_fetch(forever) do
                err = try
                    fetch_pubchem!(cdb, "something else")
                catch e
                    e
                end
                @test err isa T.PubChemError && err.status == status
                message = sprint(showerror, err)
                @test occursin(expected, message) &&
                      occursin("Try again later", message) &&
                      occursin("Nothing was changed", message) &&
                      occursin("/compound/name/something%20else/cids/JSON", message)
            end
        end
        # a refusal is not retried
        refused = Ref(0)
        CompoundFixture.with_fetch((m, u, b) -> (refused[] += 1; (400, "bad request"))) do
            @test_throws T.PubChemError fetch_pubchem!(cdb, "ethanol"; force = true)
            @test refused[] == 1
        end
        @test length(cdb) == before
        # a failure is not remembered as "not found"
        @test !isfile(T.pubchem_missing_path(joinpath(dir, "local")))
    end
end

@testitem "online = true asks PubChem only for what is not known" tags = [:unit] setup =
    [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            # without online = true the network is never used
            @test isempty(lookup_compounds(cdb, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"))
            @test isempty(calls)
            # a text the database knows is not asked
            @test length(lookup_compounds(cdb, "water"; online = true)) >= 1
            @test isempty(calls)
            # one it does not know is asked, kept, and found again
            found = lookup_compounds(cdb, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"; online = true)
            @test length(found) == 1 && found.match[1] == :inchikey
            @test !isempty(calls)
            n = length(calls)
            @test length(
                lookup_compounds(cdb, "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"; online = true),
            ) == 1
            @test length(calls) == n                         # now it is known
            # a compound that PubChem knows under another name is marked as such
            found = lookup_compounds(cdb, "64-17-5"; by = :name, online = true)
            @test :pubchem in found.match || :name in found.match
            # PubChem has nothing: what the database had is returned, nothing is added
            before = length(cdb)
            nothing_found = lookup_compounds(cdb, "unobtainium"; online = true)
            @test length(cdb) == before && isempty(nothing_found)
            @test_throws ArgumentError lookup_compounds(
                cdb,
                "H2O";
                by = :formula,
                online = true,
            )
        end
    end
end

@testitem "a linked database can ask PubChem for a compound that neither database knows" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        ds = T.Dataset()
        mole = T.intern!(ds.kinds, "Mole fraction")
        source = T.intern!(ds.sources, "thermoml")
        ref = T.add_reference!(ds.references; doi = "10.5555/pubchem-001", source)
        ethanol = T.add_compound!(
            ds.compounds;
            inchikey = "LFQSCWFLJHTTHZ-UHFFFAOYSA-N",
            names = ["alcohol of the article"],
            formula = "C2H6O",
        )
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        e = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [ethanol],
            kinds = [mole],
        )
        for i = 1:3
            T.add_measurement!(
                ds.measurements;
                experiment = e,
                property = density,
                temperature = 290.0 + i,
                pressure = 101.325,
                value = 789.0,
            )
        end
        linked = link_compounds(ds, cdb)
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            # the CAS number is in the compound database, but without an InChIKey: no link
            @test_throws ArgumentError points(linked; component = "64-17-5")
            @test isempty(calls)
            # asked of PubChem, the InChIKey arrives and the compound of the dataset is found
            view = points(linked; component = "64-17-5", online = true)
            @test length(view) == 3 && !isempty(calls)
            n = length(calls)
            @test length(points(linked; component = "64-17-5", online = true)) == 3
            @test length(calls) == n                  # known now, so not asked again
            @test length(points(linked; component = "Ethanol")) == 3   # a name PubChem gave
            # unknown to PubChem too: the usual error
            @test_throws ArgumentError points(
                linked;
                component = "unobtainium",
                online = true,
            )
            @test length(
                mixture(linked, "64-17-5", "64-17-5"; exact = false, online = true),
            ) in (0, 3)
        end
        # the database knows water (with an InChIKey) but the dataset has no water: PubChem
        # would bring the same compound, so it is not asked
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            n = length(calls)
            @test_throws ArgumentError points(linked; component = "water", online = true)
            @test length(calls) == n
        end
        # the menu of PubChem has its own prepared answers
        glucose = T.add_compound!(
            ds.compounds;
            inchikey = "GZCGUPFRVQAUEE-SLPGGIOYSA-N",
            names = ["glucose of the article"],
        )
        e2 = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [glucose],
            kinds = [mole],
        )
        T.add_measurement!(
            ds.measurements;
            experiment = e2,
            property = density,
            temperature = 300.0,
            pressure = 101.325,
            value = 1500.0,
        )
        linked2 = link_compounds(ds, cdb)
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            @test_throws ArgumentError points(linked2; component = "glucose", online = true)
            view = points(
                linked2;
                component = "glucose",
                online = true,
                choose = Dict("pubchem:glucose" => 2),
            )
            @test length(view) == 1
        end
    end
end

@testitem "the most measured compounds that the database lacks are fetched in advance" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        folder = joinpath(dir, "local")
        ds = T.Dataset()
        mole = T.intern!(ds.kinds, "Mole fraction")
        source = T.intern!(ds.sources, "thermoml")
        ref = T.add_reference!(ds.references; doi = "10.5555/prefetch-001", source)
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        function measured(points; kwargs...)
            c = T.add_compound!(ds.compounds; kwargs...)
            e = T.add_experiment!(
                ds.experiments;
                reference = ref,
                components = [c],
                kinds = [mole],
            )
            for i = 1:points
                T.add_measurement!(
                    ds.measurements;
                    experiment = e,
                    property = density,
                    temperature = 290.0 + i,
                    pressure = 101.325,
                    value = 1.0,
                )
            end
            return c
        end
        water = measured(7; inchikey = "XLYOFNOQVPJJNP-UHFFFAOYSA-N", names = ["water"])
        ethanol = measured(3; inchikey = "LFQSCWFLJHTTHZ-UHFFFAOYSA-N", names = ["ethanol"])
        glucose = measured(5; inchikey = "GZCGUPFRVQAUEE-SLPGGIOYSA-N", names = ["glucose"])
        unknown =
            measured(10; inchikey = "AAAAAAAAAAAAAA-BBBBBBBBBB-C", names = ["ionic liquid"])
        keyless = measured(20; names = ["no key at all"])
        @test T.unlinked_compounds(ds, cdb) == Int32[ethanol, glucose, unknown]   # water is known
        calls = []
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake(calls)) do
            @test_throws ArgumentError prefetch_compounds!(ds, cdb; top = 0)
            @test_throws ArgumentError prefetch_compounds!(ds, cdb; batch = 0)
            before = length(cdb)
            # the 3 most measured are the unknown one (10), water (7) and glucose (5); water
            # is already known, so the other two are asked
            summary = prefetch_compounds!(ds, cdb; top = 3, progress = false)
            @test summary == (
                considered = 3,
                unknown = 2,
                requested = 2,
                fetched = 1,
                not_found = 1,
                remembered_missing = 0,
            )
            @test length(calls) == 3                  # two InChIKeys, and one batch of synonyms
            @test length(cdb) == before + 1
            @test only(lookup_compounds(cdb, "GZCGUPFRVQAUEE-SLPGGIOYSA-N").id) != 0
            @test isfile(T.pubchem_file(folder, 107526))
            @test haskey(
                T.read_pubchem_missing(folder),
                "inchikey:aaaaaaaaaaaaaa-bbbbbbbbbb-c",
            )
            # the link now exists, and the one PubChem lacks is not asked again
            @test T.unlinked_compounds(ds, cdb) == Int32[ethanol, unknown]
            # the same 3 are in the database now: nothing new is asked
            empty!(calls)
            summary = prefetch_compounds!(ds, cdb; top = 3, progress = false)
            @test summary == (
                considered = 3,
                unknown = 1,
                requested = 0,
                fetched = 0,
                not_found = 0,
                remembered_missing = 1,
            )
            @test isempty(calls)
            # a larger rank reaches ethanol (3 points), the only one that is new
            summary = prefetch_compounds!(ds, cdb; top = 4, progress = false)
            @test summary.considered == 4 && summary.unknown == 2
            @test summary.requested == 1 && summary.fetched == 1 && summary.not_found == 0
            @test summary.remembered_missing == 1
            @test length(calls) == 2                  # one InChIKey, and the synonyms
            @test T.unlinked_compounds(ds, cdb) == Int32[unknown]
            # nothing left to ask, unless asked to
            empty!(calls)
            summary = prefetch_compounds!(ds, cdb; progress = false)
            @test summary.requested == 0 && isempty(calls)
            summary = prefetch_compounds!(ds, cdb; refresh = true, progress = false)
            @test summary.requested == 1 && summary.not_found == 1 && length(calls) == 1
            # a linked database and the dataset alone are accepted
            @test prefetch_compounds!(link_compounds(ds, cdb); progress = false).requested ==
                  0
        end
        # the files are read in the next session, and the link is made by InChIKey
        again = CompoundFixture.database(dir; reload = true)
        linked = link_compounds(ds, again)
        links = linked.links
        @test links.via[only(findall(==(Int32(glucose)), links.compound))] == :inchikey
        @test links.via[only(findall(==(Int32(ethanol)), links.compound))] == :inchikey
        @test links.record[only(findall(==(Int32(keyless)), links.compound))] == 0
    end
end

@testitem "a failure while fetching in advance keeps what was fetched and tells what happened" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        folder = joinpath(dir, "local")
        ds = T.Dataset()
        mole = T.intern!(ds.kinds, "Mole fraction")
        source = T.intern!(ds.sources, "thermoml")
        ref = T.add_reference!(ds.references; doi = "10.5555/prefetch-002", source)
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        for (key, n) in
            (("LFQSCWFLJHTTHZ-UHFFFAOYSA-N", 4), ("GZCGUPFRVQAUEE-SLPGGIOYSA-N", 3))
            c = T.add_compound!(ds.compounds; inchikey = key, names = [key])
            e = T.add_experiment!(
                ds.experiments;
                reference = ref,
                components = [c],
                kinds = [mole],
            )
            for i = 1:n
                T.add_measurement!(
                    ds.measurements;
                    experiment = e,
                    property = density,
                    temperature = 290.0 + i,
                    pressure = 101.325,
                    value = 1.0,
                )
            end
        end
        inner = CompoundFixture.pubchem_fake([])
        count = Ref(0)
        # the first compound is answered (its InChIKey, then its synonyms) and the service
        # goes down at the next request
        failing = function (method, url, body)
            count[] += 1
            count[] <= 2 && return inner(method, url, body)
            return 503, "busy"
        end
        CompoundFixture.with_fetch(failing) do
            @test_throws T.PubChemError prefetch_compounds!(
                ds,
                cdb;
                batch = 1,
                progress = false,
            )
        end
        # batch = 1 writes each compound as soon as it is answered, so the first one is kept,
        # and the failure was not remembered as "not found"
        @test isfile(T.pubchem_file(folder, 702))
        @test !isfile(T.pubchem_file(folder, 107526))
        @test !haskey(
            T.read_pubchem_missing(folder),
            "inchikey:gzcgupfrvqauee-slpggioysa-n",
        )
        # in `database(; prefetch_compounds = n)` the failure is only a warning
        CompoundFixture.with_fetch((m, u, b) -> (503, "busy")) do
            @test_logs (:warn, r"could not be fetched from PubChem") T.prefetch_missing_compounds(
                ds,
                5,
                false,
                () -> cdb,
            )
        end
        # and the helper does what it says when the service answers
        CompoundFixture.with_fetch(CompoundFixture.pubchem_fake([])) do
            @test T.prefetch_missing_compounds(ds, 5, false, () -> cdb) === nothing
            @test T.unlinked_compounds(ds, cdb) == Int32[]
        end
    end
end
