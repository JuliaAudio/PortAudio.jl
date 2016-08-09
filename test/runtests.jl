#!/usr/bin/env julia

if VERSION >= v"0.5.0-dev+7720"
    using Base.Test
else
    using BaseTestNext
end
using PortAudio
using SampledSignals
using RingBuffers

# these test are currently set up to run on OSX

@testset "PortAudio Tests" begin
    devs = PortAudio.devices()
    i = findfirst(d -> d.maxinchans > 0, devs)
    indev = i > 0 ? devs[i] : nothing
    i = findfirst(d -> d.maxoutchans > 0, devs)
    outdev = i > 0 ? devs[i] : nothing
    i = findfirst(d -> d.maxoutchans > 0 && d.maxinchans > 0, devs)
    duplexdev = i > 0 ? devs[i] : nothing

    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = takebuf_string(io)
        # make sure this is the same version I tested with
        @test result ==
            """PortAudio V19-devel (built Aug  6 2014 17:54:39)
            Version Number: 1899
            """
    end

    @testset "PortAudio Callback works and doesn't allocate" begin
        cb = PortAudio.pa_callbacks[Float32]
        inbuf = rand(Float32, 16) # simulate microphone input
        sourcebuf = LockFreeRingBuffer(Float32, 64) # the microphone input should end up here

        outbuf = zeros(Float32, 24) # this is where the output should go
        sinkbuf = LockFreeRingBuffer(Float32, 64) # the callback should copy this to outbuf

        # 2 input channels, 3 output channels
        info = PortAudio.CallbackInfo(2, sourcebuf, 3, sinkbuf)

        # handle any conversions here so they don't mess with the allocation
        # the seemingly-redundant type specifiers avoid some allocation during the ccall.
        # might be due to https://github.com/JuliaLang/julia/issues/15276
        inptr::Ptr{Float32} = Ptr{Float32}(pointer(inbuf))
        outptr::Ptr{Float32} = Ptr{Float32}(pointer(outbuf))
        nframes = Culong(8)
        flags = Culong(0)
        infoptr::Ptr{PortAudio.CallbackInfo{Float32}} = Ptr{PortAudio.CallbackInfo{Float32}}(pointer_from_objref(info))

        testin = zeros(Float32, 16)
        testout = rand(Float32, 24)
        write(sinkbuf, testout) # fill the output ringbuffer
        ret = ccall(cb, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{PortAudio.CallbackInfo{Float32}}),
            inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test ret === PortAudio.paContinue
        @test outbuf == testout
        read!(sourcebuf, testin)
        @test inbuf == testin

        testout = rand(Float32, 10)
        write(sinkbuf, testout) # underfill the output ringbuffer
        # call again (partial underrun)
        ret = ccall(cb, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{PortAudio.CallbackInfo{Float32}}),
            inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test ret === PortAudio.paContinue
        @test outbuf[1:10] == testout
        @test outbuf[11:24] == zeros(Float32, 14)
        @test nreadable(sourcebuf) == 10
        @test read!(sourcebuf, testin) == 10
        @test testin[1:10] == inbuf[1:10]

        # call again (total underrun)
        ret = ccall(cb, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{PortAudio.CallbackInfo{Float32}}),
            inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test ret === PortAudio.paContinue
        @test outbuf == zeros(Float32, 24)
        @test nreadable(sourcebuf) == 0

        write(sinkbuf, testout) # fill the output ringbuffer
        # test allocation
        alloc = @allocated ccall(cb, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{PortAudio.CallbackInfo{Float32}}),
            inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test alloc == 0
        # now test allocation in underrun state
        alloc = @allocated ccall(cb, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{PortAudio.CallbackInfo{Float32}}),
            inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test alloc == 0
    end

    @testset "Open Default Device" begin
        println("Recording...")
        stream = PortAudioStream(2, 0)
        buf = read(stream, 5s)
        close(stream)
        @test size(buf) == (round(Int, 5s * samplerate(stream)), nchannels(stream.source))
        println("Playing back recording...")
        stream = PortAudioStream()
        write(stream, buf)
        println("flushing...")
        flush(stream)
        close(stream)
        println("Testing pass-through")
        stream = PortAudioStream(2, 2)
        write(stream, stream, 5s)
        flush(stream)
        close(stream)
        println("done")
    end
    @testset "Samplerate-converting writing" begin
        stream = PortAudioStream()
        write(stream, SinSource(eltype(stream), samplerate(stream)*0.5, [220Hz, 330Hz]), 3s)
        write(stream, SinSource(eltype(stream), samplerate(stream)*1.5, [220Hz, 330Hz]), 3s)
        flush(stream)
        close(stream)
    end
    @testset "Open Device by name" begin
        stream = PortAudioStream("Built-in Microph", "Built-in Output")
        buf = read(stream, 0.001s)
        @test size(buf) == (round(Int, 0.001s * samplerate(stream)), nchannels(stream.source))
        write(stream, buf)
        io = IOBuffer()
        show(io, stream)
        @test takebuf_string(io) == """
        PortAudio.PortAudioStream{Float32,SIUnits.SIQuantity{Int64,0,0,-1,0,0,0,0,0,0}}
          Samplerate: 48000 s⁻¹
          Buffer Size: 4096 frames
          2 channel sink: "Built-in Output"
          2 channel source: "Built-in Microph\""""
        close(stream)
    end
    @testset "Error on wrong name" begin
        @test_throws ErrorException PortAudioStream("foobarbaz")
    end
    # no way to check that the right data is actually getting read or written here,
    # but at least it's not crashing.
    @testset "Queued Writing" begin
        stream = PortAudioStream(0, 2)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.sink))*0.1, samplerate(stream))
        t1 = @async write(stream, buf)
        t2 = @async write(stream, buf)
        @test wait(t1) == 48000
        @test wait(t2) == 48000
        flush(stream)
        close(stream)
    end
    @testset "Queued Reading" begin
        stream = PortAudioStream(2, 0)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.source))*0.1, samplerate(stream))
        t1 = @async read!(stream, buf)
        t2 = @async read!(stream, buf)
        @test wait(t1) == 48000
        @test wait(t2) == 48000
        close(stream)
    end
end
