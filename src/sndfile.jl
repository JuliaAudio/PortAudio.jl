export openAudio, closeAudio, readFrames, FileInput

const sndfile = "libsndfile"


const SFM_READ = int32(0x10)
const SFM_WRITE = int32(0x20)

type SF_INFO
    frames::Int64
    samplerate::Int32
    channels::Int32
    format::Int32
    sections::Int32
    seekable::Int32
end

type Sndfile
    filePtr::Ptr{Void}
    sfinfo::SF_INFO
end

function openAudio(path::String)
    sfinfo = SF_INFO(0, 0, 0, 0, 0, 0)
    filePtr = ccall((:sf_open, sndfile), Ptr{Void},
                    (Ptr{Uint8}, Int32, Ptr{SF_INFO}),
                    path, SFM_READ, &sfinfo)
    if filePtr == C_NULL
        errmsg = ccall((:sf_strerror, sndfile), Ptr{Uint8}, (Ptr{Void},), filePtr)
        error(bytestring(errmsg))
    end

    return Sndfile(filePtr, sfinfo)
end

function closeAudio(file::Sndfile)
    err = ccall((:sf_close, sndfile), Int32, (Ptr{Void},), file.filePtr)
    if err != 0
        error("Failed to close file")
    end
end

function openAudio(f::Function, path::String)
    file = openAudio(path)
    f(file)
    closeAudio(file)
end

function readFrames(file::Sndfile, nframes::Integer, dtype::Type = Int16)
    arr = []
    if file.sfinfo.channels == 2
        arr = zeros(dtype, 2, nframes)
    else
        arr = zeros(dtype, nframes)
    end

    if dtype == Int16
        nread = ccall((:sf_readf_short, sndfile), Int64,
                        (Ptr{Void}, Ptr{Int16}, Int64),
                        file.filePtr, arr, nframes)
    elseif dtype == Int32
        nread = ccall((:sf_readf_int, sndfile), Int64,
                        (Ptr{Void}, Ptr{Int32}, Int64),
                        file.filePtr, arr, nframes)
    elseif dtype == Float32
        nread = ccall((:sf_readf_float, sndfile), Int64,
                        (Ptr{Void}, Ptr{Float32}, Int64),
                        file.filePtr, arr, nframes)
    elseif dtype == Float64
        nread = ccall((:sf_readf_double, sndfile), Int64,
                        (Ptr{Void}, Ptr{Float64}, Int64),
                        file.filePtr, arr, nframes)
    end

    if nread == 0
        return Nothing
    end

    return arr
end

type FileInput <: AudioNode
    active::Bool
    file::Sndfile

    function FileInput(path::String)
        node = new(false, openAudio(path))
        finalizer(node, node -> closeAudio(node.file))
        return node
    end
end

function render(node::FileInput, device_input::AudioBuf, info::DeviceInfo)
    @assert node.file.sfinfo.samplerate == info.sample_rate

    audio = readFrames(node.file, info.buf_size, AudioSample)

    if audio == Nothing
        return zeros(AudioSample, info.buf_size), false
    end

    # if the file is stereo, mix the two channels together
    if node.file.sfinfo.channels == 2
        return (audio[1, :] / 2) + (audio[2, :] / 2), node.active
    end

    return audio, node.active
end
