@testitem "install_release downloads, verifies and records the archive" setup = [Fixtures] tags =
    [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        digest = ThermophysicalDB.file_sha256(tgz)
        release = Fixtures.make_release("2024-01-01")
        dir = joinpath(tmp, "cache", "thermoml")  # does not exist yet

        manifest = Fixtures.install(release, dir, Fixtures.fake_download(tgz, digest))

        installed = joinpath(dir, release.archive_name)
        @test isfile(installed)
        @test !isfile(installed * ".part")
        @test ThermophysicalDB.file_sha256(installed) == digest
        @test manifest.version == "2024-01-01"
        @test manifest.sha256 == digest
        @test manifest.size_bytes == filesize(installed)
        @test manifest.source_url == release.archive_url
        @test ThermophysicalDB.read_manifest(dir) == manifest
        @test ThermophysicalDB.archive_path(manifest; dir) == installed
        @test ThermophysicalDB.installed_manifest(dir) == manifest
    end
end

@testitem "install_release rejects a corrupted download" setup = [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        release = Fixtures.make_release("2024-01-01")
        dir = joinpath(tmp, "cache")
        wrong = Fixtures.fake_download(tgz, repeat("0", 64))

        @test_logs (:info, r"Downloading") @test_throws ThermophysicalDB.ChecksumMismatchError ThermophysicalDB.install_release(
            release;
            dir,
            download = wrong,
        )
        @test !isfile(joinpath(dir, release.archive_name))
        @test !isfile(joinpath(dir, release.archive_name * ".part"))
        @test ThermophysicalDB.read_manifest(dir) === nothing
    end
end

@testitem "install_release falls back to the built-in digest" setup = [Fixtures] tags =
    [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        digest = ThermophysicalDB.file_sha256(tgz)
        release = Fixtures.make_release("2024-01-01"; sha256 = digest)
        served = Fixtures.fake_download(tgz, digest)
        # the digest file cannot be fetched, the archive itself can
        download = function (url, dest)
            endswith(url, ".sha256") && error("digest endpoint is down")
            return served(url, dest)
        end
        manifest =
            @test_logs (:warn, r"built-in") (:info, r"Downloading") ThermophysicalDB.install_release(
                release;
                dir = joinpath(tmp, "cache"),
                download,
            )
        @test manifest.sha256 == digest

        # without a built-in digest the failure must surface
        bare = Fixtures.make_release("2024-02-02")
        @test_throws ErrorException ThermophysicalDB.install_release(
            bare;
            dir = joinpath(tmp, "other"),
            download,
        )
    end
end

@testitem "install_release replaces older archives unless asked to keep them" setup =
    [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        v1 = Fixtures.make_release("2024-01-01")
        v2 = Fixtures.make_release("2025-01-01")
        v3 = Fixtures.make_release("2026-01-01")

        dir = joinpath(tmp, "cache")
        Fixtures.install(v1, dir, download)
        Fixtures.install(v2, dir, download)
        @test !isfile(joinpath(dir, v1.archive_name))
        @test isfile(joinpath(dir, v2.archive_name))
        @test ThermophysicalDB.read_manifest(dir).version == "2025-01-01"

        @test_logs (:info, r"Downloading") ThermophysicalDB.install_release(
            v3;
            dir,
            download,
            keep_old = true,
        )
        @test isfile(joinpath(dir, v2.archive_name))
        @test isfile(joinpath(dir, v3.archive_name))
        @test ThermophysicalDB.read_manifest(dir).version == "2026-01-01"
    end
end

@testitem "manifest round-trips and refuses tampered content" tags = [:unit, :fast] begin
    mktempdir() do dir
        @test ThermophysicalDB.read_manifest(dir) === nothing

        manifest = ThermophysicalDB.Manifest(
            ThermophysicalDB.MANIFEST_FORMAT,
            "2024-01-01",
            "ThermoML.v2024-01-01.tgz",
            repeat("ab", 32),
            "https://example.invalid/ThermoML.v2024-01-01.tgz",
            "2026-10-23T12:00:00Z",
            1234,
        )
        ThermophysicalDB.write_manifest(dir, manifest)
        @test ThermophysicalDB.read_manifest(dir) == manifest

        # an archive name that escapes the directory must be rejected
        path = ThermophysicalDB.manifest_path(dir)
        write(
            path,
            replace(read(path, String), "ThermoML.v2024-01-01.tgz" => "../evil.tgz"),
        )
        @test ThermophysicalDB.read_manifest(dir) === nothing

        # unknown format versions and garbage are ignored too
        write(path, "format = 99\n")
        @test ThermophysicalDB.read_manifest(dir) === nothing
        write(path, "this is = = not toml")
        @test_logs (:warn, r"unreadable") @test ThermophysicalDB.read_manifest(dir) ===
                                                nothing
    end
end

@testitem "installed_manifest ignores a truncated archive" setup = [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        release = Fixtures.make_release("2024-01-01")
        dir = joinpath(tmp, "cache")
        Fixtures.install(release, dir, download)
        @test ThermophysicalDB.installed_manifest(dir) !== nothing

        write(joinpath(dir, release.archive_name), "truncated")
        @test_logs (:warn, r"disagree") @test ThermophysicalDB.installed_manifest(dir) ===
                                              nothing
        rm(joinpath(dir, release.archive_name))
        @test_logs (:warn, r"disagree") @test ThermophysicalDB.installed_manifest(dir) ===
                                              nothing
    end
end

@testitem "check_update reports every state" setup = [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        old = Fixtures.make_release("2024-01-01")
        new = Fixtures.make_release("2025-06-01")
        dir = joinpath(tmp, "cache")
        offline = () -> error("network is down")

        status = ThermophysicalDB.check_update(; dir, fetch = () -> old)
        @test status.state === :not_installed
        @test status.source === :remote
        @test status.latest.version == "2024-01-01"
        @test status.installed === nothing

        # offline and nothing installed: the built-in release is the target
        status = ThermophysicalDB.check_update(; dir, fetch = offline)
        @test status.state === :not_installed
        @test status.source === :builtin
        @test status.latest === ThermophysicalDB.builtin_latest()
        @test occursin("network is down", status.reason)

        Fixtures.install(old, dir, download)

        status = ThermophysicalDB.check_update(; dir, fetch = () -> old)
        @test status.state === :up_to_date
        status = ThermophysicalDB.check_update(; dir, fetch = () -> new)
        @test status.state === :update_available
        @test status.latest.version == "2025-06-01"
        @test status.installed.version == "2024-01-01"
        status = ThermophysicalDB.check_update(; dir, fetch = offline)
        @test status.state === :unknown
        @test status.source === :builtin
    end
end

@testitem "ensure_archive installs when missing and honours the update policy" setup =
    [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        old = Fixtures.make_release("2024-01-01")
        new = Fixtures.make_release("2025-06-01")
        dir = joinpath(tmp, "cache")
        offline = () -> error("network is down")

        @test_throws ArgumentError ThermophysicalDB.ensure_archive(;
            update = :sometimes,
            dir,
        )

        # missing: downloaded regardless of the policy
        manifest = @test_logs (:info, r"Downloading") ThermophysicalDB.ensure_archive(;
            dir,
            fetch = () -> old,
            download,
        )
        @test manifest.version == "2024-01-01"

        # :notify keeps the local copy and warns
        manifest = @test_logs (:warn, r"Newer") ThermophysicalDB.ensure_archive(;
            dir,
            fetch = () -> new,
            download,
        )
        @test manifest.version == "2024-01-01"

        # :never must not even try to reach the network
        manifest = ThermophysicalDB.ensure_archive(;
            update = :never,
            dir,
            fetch = () -> error("must not be called"),
            download,
        )
        @test manifest.version == "2024-01-01"

        # offline: silently keeps the local copy
        manifest = ThermophysicalDB.ensure_archive(; dir, fetch = offline, download)
        @test manifest.version == "2024-01-01"

        # :install switches to the newer archive
        manifest = @test_logs (:info, r"Downloading") ThermophysicalDB.ensure_archive(;
            update = :install,
            dir,
            fetch = () -> new,
            download,
        )
        @test manifest.version == "2025-06-01"
        @test !isfile(joinpath(dir, old.archive_name))
    end
end

@testitem "update_database! only installs what is needed" setup = [Fixtures] tags = [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        old = Fixtures.make_release("2024-01-01")
        new = Fixtures.make_release("2025-06-01")
        dir = joinpath(tmp, "cache")

        manifest = @test_logs (:info, r"Downloading") ThermophysicalDB.update_database!(;
            dir,
            fetch = () -> old,
            download,
        )
        @test manifest.version == "2024-01-01"

        manifest = @test_logs (:info, r"up to date") ThermophysicalDB.update_database!(;
            dir,
            fetch = () -> old,
            download = (url, dest) -> error("must not download"),
        )
        @test manifest.version == "2024-01-01"

        manifest =
            @test_logs (:info, r"Could not reach") ThermophysicalDB.update_database!(;
                dir,
                fetch = () -> error("network is down"),
                download = (url, dest) -> error("must not download"),
            )
        @test manifest.version == "2024-01-01"

        manifest = @test_logs (:info, r"Downloading") ThermophysicalDB.update_database!(;
            dir,
            fetch = () -> new,
            download,
        )
        @test manifest.version == "2025-06-01"
    end
end
