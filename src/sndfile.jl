export af_open, FilePlayer

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

    function SF_INFO(frames::Integer, samplerate::Integer, channels::Integer,
                     format::Integer, sections::Integer, seekable::Integer)
        new(int64(frames), int32(samplerate), int32(channels), int32(format),
            int32(sections), int32(seekable))
    end
end

type AudioFile
    filePtr::Ptr{Void}
    sfinfo::SF_INFO
end

function af_open(path::String, mode::String="r")
    # TODO: handle write/append modes
    sfinfo = SF_INFO(0, 0, 0, 0, 0, 0)
    filePtr = ccall((:sf_open, sndfile), Ptr{Void},
                    (Ptr{Uint8}, Int32, Ptr{SF_INFO}),
                    path, SFM_READ, &sfinfo)
    if filePtr == C_NULL
        errmsg = ccall((:sf_strerror, sndfile), Ptr{Uint8}, (Ptr{Void},), filePtr)
        error(bytestring(errmsg))
    end

    return AudioFile(filePtr, sfinfo)
end

function Base.close(file::AudioFile)
    err = ccall((:sf_close, sndfile), Int32, (Ptr{Void},), file.filePtr)
    if err != 0
        error("Failed to close file")
    end
end

function af_open(f::Function, path::String)
    file = af_open(path)
    f(file)
    close(file)
end

# TODO: we should implement a general read(node::AudioNode) that pulls data
# through an arbitrary render chain and returns the result as a vector
function Base.read(file::AudioFile, nframes::Integer = file.sfinfo.frames,
                   dtype::Type = Int16)
    arr = []
    @assert file.sfinfo.channels <= 2
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

type FilePlayer <: AudioNode
    active::Bool
    deactivate_cond::Condition
    file::AudioFile

    function FilePlayer(file::AudioFile)
        node = new(false, Condition(), file)
        finalizer(node, node -> close(node.file))
        return node
    end

    function FilePlayer(path::String)
        return FilePlayer(af_open(path))
    end
end

function render(node::FilePlayer, device_input::AudioBuf, info::DeviceInfo)
    @assert node.file.sfinfo.samplerate == info.sample_rate

    audio = read(node.file, info.buf_size, AudioSample)

    if audio == Nothing
        deactivate(node)
        return zeros(AudioSample, info.buf_size), is_active(node)
    end

    # if the file is stereo, mix the two channels together
    if node.file.sfinfo.channels == 2
        return (audio[1, :] / 2) + (audio[2, :] / 2), is_active(node)
    end

    return audio, is_active(node)
end

function play(filename::String, args...)
    player = FilePlayer(filename)
    play(player, args...)
end

function play(file::AudioFile, args...)
    player = FilePlayer(file)
    play(player, args...)
end
