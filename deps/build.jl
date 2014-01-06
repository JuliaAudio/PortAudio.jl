using BinDeps

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

libportaudio = library_dependency("libportaudio")

# TODO: add other providers with correct names
provides(AptGet, {"portaudio19-dev" => libportaudio})

@osx_only begin
    if Pkg.installed("Homebrew") === nothing
        error("Homebrew package not installed, please run Pkg.add(\"Homebrew\")")
    end
    using Homebrew
    provides(Homebrew.HB, {"portaudio" => libportaudio})
end

@BinDeps.install [:libportaudio => :libportaudio]

cd(joinpath(Pkg.dir(), "AudioIO", "deps", "src") )
run(`make`)
if (!ispath("../usr"))
  run(`mkdir ../usr`)
end
if (!ispath("../usr/lib"))
  run(`mkdir ../usr/lib`)
end
run(`mv libportaudio_shim.$(BinDeps.shlib_ext) ../usr/lib`)
