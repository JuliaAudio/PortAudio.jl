using BinDeps
using Compat

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

# include alias for WinRPM library
libportaudio = library_dependency("libportaudio", aliases=["libportaudio-2"])

# TODO: add other providers with correct names
provides(AptGet, "libportaudio2", libportaudio)
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
