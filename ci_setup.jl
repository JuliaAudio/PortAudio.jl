VERSION >= v"0.7.0-" && using InteractiveUtils
versioninfo()

if VERSION < v"0.7.0-"
    Pkg.clone(pwd(), "PortAudio")
    Pkg.build("PortAudio")
    # for now we need SampledSignals master
    Pkg.checkout("SampledSignals")
else
    using Pkg
    # for now we need to `clone` because there's no way to specify the
    # package name for `add`
    Pkg.clone(pwd(), "PortAudio")
    Pkg.build("PortAudio")
    Pkg.add(PackageSpec(name="SampledSignals", rev="master"))
end
