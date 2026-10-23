@testmodule Fixtures begin
    using ThermophysicalDB: ThermophysicalDB
    using Tar: Tar
    using CodecZlib: GzipCompressorStream
    using Test: @test_logs

    """
    Write a gzip-compressed tarball with the given `relative path => content` files.
    `Tar.create` omits the end-of-archive marker; `footer = true` appends what GNU tar
    writes: two zero blocks followed by zero padding up to a 10 KiB record.
    """
    function make_tgz(path::AbstractString, files::AbstractDict; footer::Bool = false)
        mktempdir() do dir
            for (relative, content) in files
                full = joinpath(dir, relative)
                mkpath(dirname(full))
                write(full, content)
            end
            open(path, "w") do io
                gz = GzipCompressorStream(io)
                Tar.create(dir, gz)
                footer && write(gz, zeros(UInt8, 10240))
                close(gz)
            end
        end
        return String(path)
    end

    """A `download(url, dest)` stand-in that serves `archive` and its `digest`."""
    function fake_download(archive::AbstractString, digest::AbstractString)
        return function (url, dest)
            if endswith(url, ".sha256")
                write(dest, digest * "  " * basename(archive) * "\n")
            else
                cp(archive, dest; force = true)
            end
            return dest
        end
    end

    function make_release(version::AbstractString; sha256 = nothing)
        name = "ThermoML.v$(version).tgz"
        url = "https://example.invalid/$(name)"
        return ThermophysicalDB.Release(version, name, url, url * ".sha256", sha256)
    end

    """`install_release` with the expected "Downloading" log message captured."""
    function install(release, dir, download)
        return @test_logs (:info, r"Downloading") match_mode = :any ThermophysicalDB.install_release(
            release;
            dir,
            download,
        )
    end
end
