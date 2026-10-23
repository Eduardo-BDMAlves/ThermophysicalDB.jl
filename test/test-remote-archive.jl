@testitem "foreach_archive_entry streams matching entries" setup = [Fixtures] tags =
    [:unit, :fast] begin
    big = repeat("x", 2_000_000)  # larger than the internal read buffer
    files = Dict(
        "10.1000/a.json" => "{\"a\":1}",
        "10.1000/a.xml" => "<a/>",
        "10.2000/b.json" => big,
        "10.2000/empty.json" => "",
    )
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "sample.tgz"), files)

        seen = Dict{String,String}()
        ThermophysicalDB.foreach_archive_entry(tgz) do path, data
            seen[path] = String(data)
        end
        @test seen == Dict(
            "10.1000/a.json" => "{\"a\":1}",
            "10.2000/b.json" => big,
            "10.2000/empty.json" => "",
        )

        xml = Dict{String,String}()
        ThermophysicalDB.foreach_archive_entry(tgz; suffix = ".xml") do path, data
            xml[path] = String(data)
        end
        @test xml == Dict("10.1000/a.xml" => "<a/>")
    end
end

@testitem "archives with a GNU-style end marker are read to the end" setup = [Fixtures] tags =
    [:unit, :fast] begin
    files = Dict("10.1000/a.json" => "{\"a\":1}", "10.1000/a.xml" => "<a/>")
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "gnu.tgz"), files; footer = true)
        seen = String[]
        ThermophysicalDB.foreach_archive_entry(tgz) do path, data
            push!(seen, path)
        end
        @test seen == ["10.1000/a.json"]
        inventory = ThermophysicalDB.archive_inventory(tgz)
        @test inventory.by_extension == Dict(".json" => 1, ".xml" => 1)
    end
end

@testitem "archive_inventory counts files per extension" setup = [Fixtures] tags =
    [:unit, :fast] begin
    files = Dict(
        "10.1000/a.json" => "{}",
        "10.1000/a.xml" => "<a/>",
        "10.2000/b.json" => "{}",
        "10.2000/b.xml" => "<b/>",
        "10.3000/c.json" => "{}",
    )
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "sample.tgz"), files)
        inventory = ThermophysicalDB.archive_inventory(tgz)
        @test inventory.files == 5
        @test inventory.by_extension == Dict(".json" => 3, ".xml" => 2)
    end
end
