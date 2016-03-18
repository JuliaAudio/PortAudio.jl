using BinDeps
using Compat

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

libportaudio = library_dependency("libportaudio")

# TODO: add other providers with correct names
provides(AptGet, "portaudio19-dev", libportaudio)
provides(Pacman, "portaudio", libportaudio)


@osx_only begin
    using Homebrew
    provides(Homebrew.HB, "portaudio", libportaudio)
end

@windows_only begin
    using WinRPM
    provides(WinRPM.RPM, "libportaudio2", libportaudio, os = :Windows)
end

@BinDeps.install @compat(Dict(:libportaudio => :libportaudio, ))
