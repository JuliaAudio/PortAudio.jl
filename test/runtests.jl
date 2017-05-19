#!/usr/bin/env julia

using Base.Test
using TestSetExtensions
using PortAudio
using SampledSignals
using RingBuffers

# pull in some extra stuff we need to test the callback directly
using PortAudio: notifyhandle, notifycb_c, shim_processcb_c
using PortAudio: pa_shim_errmsg_t, pa_shim_info_t
using PortAudio: PA_SHIM_ERRMSG_ERR_OVERFLOW, PA_SHIM_ERRMSG_UNDERFLOW, PA_SHIM_ERRMSG_OVERFLOW

"Setup buffers to test callback behavior"
function setup_callback(inchans, outchans, nframes, synced)
    sourcebuf = RingBuffer{Float32}(inchans, nframes*2) # the microphone input should end up here
    sinkbuf = RingBuffer{Float32}(outchans, nframes*2) # the callback should copy this to cb_output
    errbuf = RingBuffer{pa_shim_errmsg_t}(1, 8)

    # pass NULL for i/o we're not using
    info = pa_shim_info_t(
        inchans > 0 ? pointer(sourcebuf) : C_NULL,
        outchans > 0 ? pointer(sinkbuf) : C_NULL,
        pointer(errbuf),
        synced, notifycb_c,
        inchans > 0 ? notifyhandle(sourcebuf) : C_NULL,
        outchans > 0 ? notifyhandle(sinkbuf) : C_NULL,
        notifyhandle(errbuf)
    )
    flags = Culong(0)

    cb_input = rand(Float32, inchans, nframes) # simulate microphone input
    cb_output = rand(Float32, outchans, nframes) # this is where the output should go

    function processfunc()
        ccall(shim_processcb_c, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong, Ptr{Void}),
            cb_input, cb_output, nframes, C_NULL, flags, pointer_from_objref(info))
    end

    (sourcebuf, sinkbuf, errbuf, cb_input, cb_output, processfunc)
end

function test_callback(inchans, outchans, synced)
    nframes = 8
    (sourcebuf, sinkbuf, errbuf,
     cb_input, cb_output, process) = setup_callback(inchans, outchans,
                                                    nframes, synced)
    if outchans > 0
        testout = rand(Float32, outchans, nframes) # generate some test data to play
        write(sinkbuf, testout) # fill the output ringbuffer
    end
    @test process() == PortAudio.paContinue
    if outchans > 0
        # testout -> sinkbuf -> cb_output
        @test cb_output == testout
    end
    if inchans > 0
        # cb_input -> sourcebuf
        @test read(sourcebuf, nframes) == cb_input
    end
    @test framesreadable(errbuf) == 0
end

"""
    test_callback_underflow(inchans, outchans; nframes=8, underfill=3, synced=false)

Test that the callback works on underflow conditions. underfill is the numer of
frames we feed in, which should be less than nframes.
"""
function test_callback_underflow(inchans, outchans, synced)
    nframes = 8
    underfill = 3 # must be less than nframes
    (sourcebuf, sinkbuf, errbuf,
     cb_input, cb_output, process) = setup_callback(inchans, outchans,
                                                    nframes, synced)
    outchans > 0 || error("Can't test underflow with no output")
    testout = rand(Float32, outchans, underfill)
    write(sinkbuf, testout) # underfill the output ringbuffer
    # call callback (partial underflow)
    @test process() == PortAudio.paContinue
    @test cb_output[:, 1:underfill] == testout
    @test cb_output[:, (underfill+1):nframes] == zeros(Float32, outchans, (nframes-underfill))
    errs = readavailable(errbuf)
    if inchans > 0
        received = readavailable(sourcebuf)
        if synced
            @test size(received, 2) == underfill
            @test received == cb_input[:, 1:underfill]
            @test length(errs) == 2
            @test Set(errs) == Set([PA_SHIM_ERRMSG_UNDERFLOW, PA_SHIM_ERRMSG_OVERFLOW])
        else
            @test size(received, 2) == nframes
            @test received == cb_input
            @test length(errs) == 1
            @test errs[1] == PA_SHIM_ERRMSG_UNDERFLOW
        end
    else
        @test length(errs) == 1
        @test errs[1] == PA_SHIM_ERRMSG_UNDERFLOW
    end

    # call again (total underflow)
    @test process() == PortAudio.paContinue
    @test cb_output == zeros(Float32, outchans, nframes)
    errs = readavailable(errbuf)
    if inchans > 0
        received = readavailable(sourcebuf)
        if synced
            @test size(received, 2) == 0
            @test length(errs) == 2
            @test Set(errs) == Set([PA_SHIM_ERRMSG_UNDERFLOW, PA_SHIM_ERRMSG_OVERFLOW])
        else
            @test size(received, 2) == nframes
            @test received == cb_input
            @test length(errs) == 1
            @test errs[1] == PA_SHIM_ERRMSG_UNDERFLOW
        end
    else
        @test length(errs) == 1
        @test errs[1] == PA_SHIM_ERRMSG_UNDERFLOW
    end
end

function test_callback_overflow(inchans, outchans, synced)
    nframes = 8
    (sourcebuf, sinkbuf, errbuf,
     cb_input, cb_output, process) = setup_callback(inchans, outchans,
                                                    nframes, synced)
    inchans > 0 || error("Can't test overflow with no input")
    @test frameswritable(sinkbuf) == nframes*2

    # the first time it should half-fill the input ring buffer
    if outchans > 0
        testout = rand(Float32, outchans, nframes)
        write(sinkbuf, testout)
    end
    @test framesreadable(sourcebuf) == 0
    outchans > 0 && @test frameswritable(sinkbuf) == nframes
    @test process() == PortAudio.paContinue
    @test framesreadable(errbuf) == 0
    @test framesreadable(sourcebuf) == nframes
    outchans > 0 && @test frameswritable(sinkbuf) == nframes*2

    # now run the process func again to completely fill the input ring buffer
    outchans > 0 && write(sinkbuf, testout)
    @test framesreadable(sourcebuf) == nframes
    outchans > 0 && @test frameswritable(sinkbuf) == nframes
    @test process() == PortAudio.paContinue
    @test framesreadable(errbuf) == 0
    @test framesreadable(sourcebuf) == nframes*2
    outchans > 0 && @test frameswritable(sinkbuf) == nframes*2

    # now this time the process func should overflow the input buffer
    outchans > 0 && write(sinkbuf, testout)
    @test framesreadable(sourcebuf) == nframes*2
    outchans > 0 && @test frameswritable(sinkbuf) == nframes
    @test process() == PortAudio.paContinue
    @test framesreadable(sourcebuf) == nframes*2
    errs = readavailable(errbuf)
    if outchans > 0
        if synced
            # if input and output are synced, thec callback didn't pull from
            # the output ringbuf
            @test frameswritable(sinkbuf) == nframes
            @test cb_output == zeros(Float32, outchans, nframes)
            @test length(errs) == 2
            @test Set(errs) == Set([PA_SHIM_ERRMSG_UNDERFLOW, PA_SHIM_ERRMSG_OVERFLOW])
        else
            @test frameswritable(sinkbuf) == nframes*2
            @test length(errs) == 1
            @test errs[1] == PA_SHIM_ERRMSG_OVERFLOW
        end
    else
        @test length(errs) == 1
        @test errs[1] == PA_SHIM_ERRMSG_OVERFLOW
    end
end

@testset ExtendedTestSet "PortAudio Tests" begin
    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = split(String(take!((io))), "\n")
        # make sure this is the same version I tested with
        @test startswith(result[1], "PortAudio V19")
    end

    @testset "using correct shim version" begin
        @test PortAudio.shimhash() == "87021557a9f999545828eb11e4ebad2cd278b734dd91a8bd3faf05c89912cf80"
    end

    @testset "Basic callback functionality" begin
        @testset "basic duplex (no sync)" begin
            test_callback(2, 3, false)
        end
        @testset "basic input-only (no sync)" begin
            test_callback(2, 0, false)
        end
        @testset "basic output-only (no sync)" begin
            test_callback(0, 2, false)
        end
        @testset "basic no input or output (no sync)" begin
            test_callback(0, 0, false)
        end
        @testset "basic duplex (sync)" begin
            test_callback(2, 3, true)
        end
        @testset "basic input-only (sync)" begin
            test_callback(2, 0, true)
        end
        @testset "basic output-only (sync)" begin
            test_callback(0, 2, true)
        end
        @testset "basic no input or output (sync)" begin
            test_callback(0, 0, true)
        end
    end

    @testset "Ouput underflow" begin
        @testset "underflow duplex (nosync)" begin
            test_callback_underflow(2, 3, false)
        end
        @testset "underflow output-only (nosync)" begin
            test_callback_underflow(0, 3, false)
        end
        @testset "underflow duplex (sync)" begin
            test_callback_underflow(2, 3, true)
        end
        @testset "underflow output-only (sync)" begin
            test_callback_underflow(0, 3, true)
        end
    end

    @testset "Input overflow" begin
        @testset "overflow duplex (nosync)" begin
            test_callback_overflow(2, 3, false)
        end
        @testset "overflow input-only (nosync)" begin
            test_callback_overflow(2, 0, false)
        end
        @testset "overflow duplex (sync)" begin
            test_callback_overflow(2, 3, true)
        end
        @testset "overflow input-only (sync)" begin
            test_callback_overflow(2, 0, true)
        end
    end
end
