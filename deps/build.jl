using BinDeps

ENV["JULIA_ROOT"] = abspath(JULIA_HOME, "../../")

cd(joinpath(Pkg.dir(), "PortAudio", "deps", "src") )
run(`make`)
if (!ispath("../usr"))
  run(`mkdir ../usr`)
end
if (!ispath("../usr/lib"))
  run(`mkdir ../usr/lib`)
end
run(`mv libportaudio_shim.$(BinDeps.shlib_ext) ../usr/lib`)
