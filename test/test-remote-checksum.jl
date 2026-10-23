@testitem "parse_sha256 accepts bare digests and sha256sum lines" tags = [:unit, :fast] begin
    digest = repeat("ab", 32)
    @test ThermophysicalDB.parse_sha256(digest) == digest
    @test ThermophysicalDB.parse_sha256(uppercase(digest) * "  archive.tgz\n") == digest
    @test ThermophysicalDB.parse_sha256(digest * " *archive.tgz") == digest
    @test_throws ArgumentError ThermophysicalDB.parse_sha256("not a digest")
    @test_throws ArgumentError ThermophysicalDB.parse_sha256(repeat("a", 63))
    @test_throws ArgumentError ThermophysicalDB.parse_sha256(repeat("a", 65))
end

@testitem "file_sha256 and verify_sha256" tags = [:unit, :fast] begin
    # SHA-256 of the three bytes "abc" (FIPS 180-2 test vector)
    abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    mktempdir() do dir
        path = joinpath(dir, "data.bin")
        write(path, "abc")
        @test ThermophysicalDB.file_sha256(path) == abc
        @test ThermophysicalDB.verify_sha256(path, abc)
        @test ThermophysicalDB.verify_sha256(path, uppercase(abc))
        @test_throws ThermophysicalDB.ChecksumMismatchError ThermophysicalDB.verify_sha256(
            path,
            repeat("0", 64),
        )
        err = try
            ThermophysicalDB.verify_sha256(path, repeat("0", 64))
        catch e
            e
        end
        @test err.actual == abc
        @test occursin("mismatch", sprint(showerror, err))
    end
end
