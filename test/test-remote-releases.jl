@testsnippet NistMetadata begin
    # Mimics a JSON record with escaped slashes, a digest link, a schema link and a
    # second (hypothetical) archive version.
    metadata = """
    {"components": [
      {"downloadURL": "https:\\/\\/data.nist.gov\\/od\\/ds\\/mds2-2422\\/ThermoML.v2020-09-30.tgz"},
      {"downloadURL": "https://data.nist.gov/od/ds/mds2-2422/ThermoML.v2020-09-30.tgz.sha256"},
      {"downloadURL": "https://data.nist.gov/od/ds/mds2-2422/ThermoML.v2023-01-15.tgz"},
      {"downloadURL": "https://data.nist.gov/od/ds/mds2-2422/ThermoML.v2023-01-15.tgz"},
      {"downloadURL": "https://data.nist.gov/od/ds/mds2-2422/ThermoML.xsd"}
    ]}
    """
end

@testitem "parse_releases finds archive links and ignores the rest" setup = [NistMetadata] tags =
    [:unit, :fast] begin
    releases = ThermophysicalDB.parse_releases(metadata)
    @test [r.version for r in releases] == ["2020-09-30", "2023-01-15"]
    @test releases[1].archive_url ==
          "https://data.nist.gov/od/ds/mds2-2422/ThermoML.v2020-09-30.tgz"
    @test releases[2].sha256_url == releases[2].archive_url * ".sha256"
    @test releases[2].archive_name == "ThermoML.v2023-01-15.tgz"
    @test all(r -> r.sha256 === nothing, releases)
    @test isempty(ThermophysicalDB.parse_releases("<html>nothing to see</html>"))
end

@testitem "built-in releases are sorted and carry a valid digest" tags = [:unit, :fast] begin
    releases = ThermophysicalDB.BUILTIN_RELEASES
    @test issorted([r.version for r in releases])
    @test ThermophysicalDB.builtin_latest() === last(releases)
    for r in releases
        @test r.archive_name == "ThermoML.v$(r.version).tgz"
        @test endswith(r.archive_url, r.archive_name)
        @test r.sha256_url == r.archive_url * ".sha256"
        @test ThermophysicalDB.parse_sha256(r.sha256) == r.sha256
    end
end

@testitem "fetch_latest_release tries every metadata URL" setup = [NistMetadata] tags =
    [:unit, :fast] begin
    calls = String[]
    get_text = function (url; timeout)
        push!(calls, url)
        url == "https://a.invalid" && error("boom")
        url == "https://b.invalid" && return "nothing useful"
        return metadata
    end
    urls = ("https://a.invalid", "https://b.invalid", "https://c.invalid")
    release = ThermophysicalDB.fetch_latest_release(; urls, get_text)
    @test release.version == "2023-01-15"
    @test calls == collect(urls)

    err = try
        ThermophysicalDB.fetch_latest_release(; urls = urls[1:2], get_text)
    catch e
        e
    end
    @test err isa ThermophysicalDB.NoReleaseError
    message = sprint(showerror, err)
    @test occursin("boom", message)
    @test occursin("no archive link", message)
end
