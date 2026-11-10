# Quality checks over the whole package. Aqua looks for ambiguous methods, stale or unbounded
# dependencies, undefined exports and type piracy; JET follows type inference through the code and
# reports what would raise an error (a value that may be `nothing` or `missing`, a method that does
# not exist for a type that can reach it).

@testitem "Aqua: no ambiguities, stale dependencies, missing compat, unbound arguments or piracy" tags =
    [:quality] begin
    using Aqua
    Aqua.test_all(ThermophysicalDB)
end

@testitem "JET: type inference finds no errors in the package" tags = [:quality] begin
    using JET
    JET.test_package(ThermophysicalDB; target_modules = (ThermophysicalDB,))
end
