VERSION >= v"0.7.0-" && using InteractiveUtils
versioninfo()

if VERSION < v"0.7.0-"
    Pkg.clone(pwd(), "PortAudio")
    Pkg.build("PortAudio")
    # for now we need SampledSignals  and RingBuffers master
    Pkg.checkout("SampledSignals")
    Pkg.checkout("RingBuffers")
else
    using Pkg
    # for now we need to `clone` because there's no way to specify the
    # package name for `add`
    Pkg.clone(pwd(), "PortAudio")
    Pkg.build("PortAudio")
    Pkg.add(PackageSpec(name="SampledSignals", rev="master"))
    Pkg.add(PackageSpec(name="RingBuffers", rev="master"))
end

# add test deps manually because we'll be running test/runtests.jl manually
Pkg.add("Compat")
