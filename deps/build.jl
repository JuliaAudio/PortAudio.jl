using BinDeps

@BinDeps.setup

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

libportaudio = library_dependency("libportaudio")

# TODO: add other providers with correct names
provides(AptGet,
    {"portaudio19-dev" => libportaudio}
)

@BinDeps.install [:libportaudio => :libportaudio]

cd(joinpath(Pkg.dir(), "PortAudio", "deps", "src") )
run(`make`)
if (!ispath("../usr"))
  run(`mkdir ../usr`)
end
if (!ispath("../usr/lib"))
  run(`mkdir ../usr/lib`)
end
run(`mv libportaudio_shim.$(BinDeps.shlib_ext) ../usr/lib`)
