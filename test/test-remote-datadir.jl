@testitem "database_dir honours the environment variable" tags = [:unit, :fast] begin
    mktempdir() do tmp
        withenv("THERMOPHYSICALDB_DATA_DIR" => tmp) do
            root = abspath(tmp)
            @test ThermophysicalDB.database_dir() == root
            @test ThermophysicalDB.thermoml_dir() == joinpath(root, "thermoml")
            @test ThermophysicalDB.user_dir() == joinpath(root, "user")
            # directories are created lazily, only on request
            @test !isdir(ThermophysicalDB.thermoml_dir())
            @test isdir(ThermophysicalDB.thermoml_dir(; create = true))
            @test !isdir(ThermophysicalDB.user_dir())
            @test isdir(ThermophysicalDB.user_dir(; create = true))
            @test isdir(ThermophysicalDB.database_dir(; create = true))
        end
    end
end

@testitem "database_dir expands a relative path" tags = [:unit, :fast] begin
    withenv("THERMOPHYSICALDB_DATA_DIR" => "relative/location") do
        @test isabspath(ThermophysicalDB.database_dir())
        @test endswith(ThermophysicalDB.database_dir(), joinpath("relative", "location"))
    end
end

@testitem "default_database_dir follows the platform conventions" tags = [:unit, :fast] begin
    mktempdir() do tmp
        if Sys.iswindows()
            withenv("LOCALAPPDATA" => tmp) do
                @test ThermophysicalDB.default_database_dir() ==
                      joinpath(tmp, "ThermophysicalDB")
            end
        elseif Sys.islinux()
            withenv("XDG_DATA_HOME" => tmp) do
                @test ThermophysicalDB.default_database_dir() ==
                      joinpath(tmp, "ThermophysicalDB")
            end
        end
        @test basename(ThermophysicalDB.default_database_dir()) == "ThermophysicalDB"
    end
end
