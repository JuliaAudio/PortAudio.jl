#!/usr/bin/env julia

using BaseTestNext
using PortAudio

println("DEVICES FOUND:")
for d in PortAudio.devices()
    println(d)
end

exit(0)
