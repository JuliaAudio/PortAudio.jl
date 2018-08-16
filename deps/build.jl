using BinDeps
using Compat
using Compat.Sys: isapple, iswindows

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(Compat.Sys.BINDIR, "../../")

# include alias for WinRPM library
libportaudio = library_dependency("libportaudio", aliases=["libportaudio-2"])

# TODO: add other providers with correct names
provides(AptGet, "libportaudio2", libportaudio)
provides(Pacman, "portaudio", libportaudio)


@static if isapple()
    using Homebrew
    provides(Homebrew.HB, "portaudio", libportaudio)
end

@static if iswindows()
    using WinRPM
    provides(WinRPM.RPM, "libportaudio2", libportaudio, os = :Windows)
end

@BinDeps.install Dict(:libportaudio => :libportaudio, )
