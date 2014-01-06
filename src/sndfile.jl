export openAudio, closeAudio, readFrames

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
        arr = Array(dtype, 2, nframes)
    else
        arr = Array(dtype, nframes)
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
        return []
    end

    if file.sfinfo.channels == 2
        return arr[:, 1:nread]
    end

    return arr[1:nread]
end
