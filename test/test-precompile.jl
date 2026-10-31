@testitem "the precompile workload never reaches the database or the network" tags =
    [:unit, :fast] begin
    text = read(joinpath(pkgdir(ThermophysicalDB), "src", "precompile.jl"), String)
    # strip the comments, which explain the rule by naming the functions
    code = join((first(split(line, '#')) for line in split(text, '\n')), '\n')
    for forbidden in (
        "database(",
        "ensure_archive",
        "update_database!",
        "install_release",
        "install_archive!",
        "check_update",
        "download_file",
        "Downloads.",
        "fetch_latest_release",
        "default_fetcher",
        "readline",
    )
        @test !occursin(forbidden, code)
    end
    @test occursin("@compile_workload", code) && occursin("@setup_workload", code)
end
