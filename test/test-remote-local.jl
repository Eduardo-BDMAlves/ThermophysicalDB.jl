@testitem "install_archive! verifies and installs a local file" setup = [Fixtures] tags =
    [:unit] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        digest = T.file_sha256(tgz)
        dir = joinpath(tmp, "data", "thermoml")

        manifest = @test_logs (:info, r"local file") T.install_archive!(
            tgz;
            version = "2099-01-01",
            sha256 = digest,
            dir,
        )
        installed = joinpath(dir, "ThermoML.v2099-01-01.tgz")
        @test isfile(installed) && !isfile(installed * ".part")
        @test manifest.version == "2099-01-01"
        @test manifest.sha256 == digest
        @test manifest.size_bytes == filesize(installed)
        @test T.installed_manifest(dir) == manifest
        @test T.archive_path(manifest; dir) == installed
        # The original is left alone.
        @test isfile(tgz)
        # ensure_archive now finds it without any network.
        @test T.ensure_archive(; update = :never, dir) == manifest
    end
end

@testitem "install_archive! finds version and digest from the file name and sidecar" setup =
    [Fixtures] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        payload = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        named = joinpath(tmp, "ThermoML.v2098-05-06.tgz")
        cp(payload, named)
        digest = T.file_sha256(named)
        write(named * ".sha256", digest)         # bare digest, as NIST publishes it
        dir = joinpath(tmp, "thermoml")
        manifest = @test_logs (:info, r"local file") T.install_archive!(named; dir)
        @test manifest.version == "2098-05-06" && manifest.sha256 == digest
    end
end

@testitem "install_archive! refuses bad input and installs nothing" setup = [Fixtures] tags =
    [:unit] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        dir = joinpath(tmp, "thermoml")
        @test_throws T.ChecksumMismatchError T.install_archive!(
            tgz;
            version = "2099-01-01",
            sha256 = repeat("0", 64),
            dir,
        )
        @test T.installed_manifest(dir) === nothing
        @test !isfile(joinpath(dir, "ThermoML.v2099-01-01.tgz"))
        # No version in the file name and none given.
        @test_throws ArgumentError T.install_archive!(tgz; sha256 = T.file_sha256(tgz), dir)
        # No digest anywhere.
        @test_throws ArgumentError T.install_archive!(tgz; version = "2099-01-01", dir)
        @test_throws ArgumentError T.install_archive!(joinpath(tmp, "missing.tgz"); dir)
    end
end

@testitem "install_archive! replaces an older archive" setup = [Fixtures] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        old = Fixtures.make_tgz(joinpath(tmp, "old.tgz"), Dict("a.json" => "{}"))
        new = Fixtures.make_tgz(joinpath(tmp, "new.tgz"), Dict("b.json" => "{ }"))
        dir = joinpath(tmp, "thermoml")
        @test_logs (:info, r"local file") T.install_archive!(
            old;
            version = "2098-01-01",
            sha256 = T.file_sha256(old),
            dir,
        )
        @test_logs (:info, r"local file") T.install_archive!(
            new;
            version = "2099-01-01",
            sha256 = T.file_sha256(new),
            dir,
        )
        @test !isfile(joinpath(dir, "ThermoML.v2098-01-01.tgz"))
        @test isfile(joinpath(dir, "ThermoML.v2099-01-01.tgz"))
        @test T.installed_manifest(dir).version == "2099-01-01"
    end
end
