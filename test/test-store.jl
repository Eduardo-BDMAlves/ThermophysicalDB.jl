@testitem "a dataset survives a round trip through plain arrays" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    T.add_extra!(ds, :measurement, 1, "frequency_hz", 1.0e6)
    T.add_extra!(ds, :reference, 1, "keywords", "a; b")
    store = Dict{String,Any}()
    T.write_dataset((key, value) -> (store[key] = value; nothing), ds)

    copied = T.restore_dataset(key -> store[key])
    @test length(copied) == length(ds)
    @test isequal(T.table(T.points(copied)), T.table(T.points(ds)))
    @test isequal(
        T.extra_numbers(copied, :measurement, "frequency_hz"),
        T.extra_numbers(ds, :measurement, "frequency_hz"),
    )
    texts = T.extra_texts(copied, :reference, "keywords")
    @test texts == T.extra_texts(ds, :reference, "keywords")
    @test texts[1] == "a; b"
    @test all(isempty, texts[2:end])

    # The lookup dictionaries are rebuilt, so adding known things reuses their rows.
    @test T.add_reference!(copied.references; doi = "10.1007/s10765-005-5566-6") == 1
    @test T.add_compound!(copied.compounds; inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N") == 2
    @test T.add_property!(copied.properties, "Mass density", "kg/m3") == 2
    @test T.intern!(copied.sources, "user") == 2

    store["schema_version"] = 999
    @test_throws ArgumentError T.restore_dataset(key -> store[key])
end

@testitem "the cache is written, reused and invalidated" setup = [Toy] tags = [:integration] begin
    T = ThermophysicalDB
    ds = Toy.build()
    manifest(version, digit) = T.Manifest(
        T.MANIFEST_FORMAT,
        version,
        "ThermoML.v$version.tgz",
        repeat(digit, 64),
        "https://example.invalid/x",
        T.utc_timestamp(),
        1,
    )
    current, other = manifest("2099-01-01", "a"), manifest("2099-02-01", "b")
    mktempdir() do dir
        @test T.read_cache(dir, current) === nothing
        meta = T.write_cache(dir, ds, current)
        @test meta["archive_sha256"] == current.sha256
        @test !isfile(T.cache_data_path(dir) * ".part")
        loaded = T.read_cache(dir, current)
        @test loaded isa T.Dataset
        @test isequal(T.table(T.points(loaded)), T.table(T.points(ds)))
        # Another archive, or another schema, must not reuse this cache.
        @test T.read_cache(dir, other) === nothing
        # A damaged data file is reported and ignored, never fatal.
        write(T.cache_data_path(dir), "garbage")
        result = @test_logs (:warn, r"could not be read") T.read_cache(dir, current)
        @test result === nothing
    end
end

@testitem "database() installs, builds, caches and then loads from the cache" setup =
    [Fixtures, ThermoMLFixture] tags = [:integration] begin
    using Base.CoreLogging: with_logger
    using Test: TestLogger
    T = ThermophysicalDB
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(
            joinpath(tmp, "payload.tgz"),
            Dict("10.1007/s10765-005-5566-6.json" => ThermoMLFixture.JSON),
        )
        release = Fixtures.make_release("2099-01-01")
        dir = joinpath(tmp, "thermoml")
        options = (;
            dir,
            progress = false,
            fetch = () -> release,
            download = Fixtures.fake_download(tgz, T.file_sha256(tgz)),
        )
        T.forget_database!()

        db =
            @test_logs (:info, r"Downloading") (:info, r"Building") match_mode = :any T.database(;
                options...,
            )
        @test db isa T.Dataset && length(db) == 4
        @test isfile(T.cache_data_path(dir)) && isfile(T.cache_meta_path(dir))
        # Same session: the very same object, no work.
        @test T.database(; options...) === db

        # New session: nothing is parsed, the cache is loaded.
        T.forget_database!()
        logger = TestLogger()
        again = with_logger(() -> T.database(; options...), logger)
        @test !any(record -> occursin("Building", record.message), logger.logs)
        @test again !== db
        @test isequal(T.table(T.points(again)), T.table(T.points(db)))

        # rebuild = true ignores the cache.
        rebuilt = @test_logs (:info, r"Building") match_mode = :any T.database(;
            options...,
            rebuild = true,
        )
        @test length(rebuilt) == 4
        T.forget_database!()
    end
end
