using BinDeps
using Compat

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

libportaudio = library_dependency("libportaudio")
libsndfile = library_dependency("libsndfile")

# TODO: add other providers with correct names
provides(AptGet, "portaudio19-dev", libportaudio)
provides(AptGet, "libsndfile1-dev", libsndfile)
provides(Pacman, "portaudio", libportaudio)
provides(Pacman, "libsndfile", libsndfile)


@osx_only begin
    using Homebrew
    provides(Homebrew.HB, "portaudio", libportaudio)
    provides(Homebrew.HB, "libsndfile", libsndfile)
end

@windows_only begin
    using WinRPM
    provides(WinRPM.RPM, "libportaudio2", libportaudio, os = :Windows)
    provides(WinRPM.RPM, "libsndfile1", libsndfile, os = :Windows)
end

@BinDeps.install @compat(Dict(:libportaudio => :libportaudio,
                  :libsndfile => :libsndfile))
