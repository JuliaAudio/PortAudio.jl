module LibPortAudio

using libportaudio_jll
export libportaudio_jll

function Pa_GetVersion()
    ccall((:Pa_GetVersion, libportaudio), Cint, ())
end

function Pa_GetVersionText()
    ccall((:Pa_GetVersionText, libportaudio), Ptr{Cchar}, ())
end

mutable struct PaVersionInfo
    versionMajor::Cint
    versionMinor::Cint
    versionSubMinor::Cint
    versionControlRevision::Ptr{Cchar}
    versionText::Ptr{Cchar}
end

# no prototype is found for this function at portaudio.h:114:22, please use with caution
function Pa_GetVersionInfo()
    ccall((:Pa_GetVersionInfo, libportaudio), Ptr{PaVersionInfo}, ())
end

const PaError = Cint

@enum PaErrorCode::Int32 begin
    paNoError = 0
    paNotInitialized = -10000
    paUnanticipatedHostError = -9999
    paInvalidChannelCount = -9998
    paInvalidSampleRate = -9997
    paInvalidDevice = -9996
    paInvalidFlag = -9995
    paSampleFormatNotSupported = -9994
    paBadIODeviceCombination = -9993
    paInsufficientMemory = -9992
    paBufferTooBig = -9991
    paBufferTooSmall = -9990
    paNullCallback = -9989
    paBadStreamPtr = -9988
    paTimedOut = -9987
    paInternalError = -9986
    paDeviceUnavailable = -9985
    paIncompatibleHostApiSpecificStreamInfo = -9984
    paStreamIsStopped = -9983
    paStreamIsNotStopped = -9982
    paInputOverflowed = -9981
    paOutputUnderflowed = -9980
    paHostApiNotFound = -9979
    paInvalidHostApi = -9978
    paCanNotReadFromACallbackStream = -9977
    paCanNotWriteToACallbackStream = -9976
    paCanNotReadFromAnOutputOnlyStream = -9975
    paCanNotWriteToAnInputOnlyStream = -9974
    paIncompatibleStreamHostApi = -9973
    paBadBufferPtr = -9972
end

function Pa_GetErrorText(errorCode)
    ccall((:Pa_GetErrorText, libportaudio), Ptr{Cchar}, (PaError,), errorCode)
end

function Pa_Initialize()
    ccall((:Pa_Initialize, libportaudio), PaError, ())
end

function Pa_Terminate()
    ccall((:Pa_Terminate, libportaudio), PaError, ())
end

const PaDeviceIndex = Cint

const PaHostApiIndex = Cint

function Pa_GetHostApiCount()
    ccall((:Pa_GetHostApiCount, libportaudio), PaHostApiIndex, ())
end

function Pa_GetDefaultHostApi()
    ccall((:Pa_GetDefaultHostApi, libportaudio), PaHostApiIndex, ())
end

@enum PaHostApiTypeId::UInt32 begin
    paInDevelopment = 0
    paDirectSound = 1
    paMME = 2
    paASIO = 3
    paSoundManager = 4
    paCoreAudio = 5
    paOSS = 7
    paALSA = 8
    paAL = 9
    paBeOS = 10
    paWDMKS = 11
    paJACK = 12
    paWASAPI = 13
    paAudioScienceHPI = 14
end

mutable struct PaHostApiInfo
    structVersion::Cint
    type::PaHostApiTypeId
    name::Ptr{Cchar}
    deviceCount::Cint
    defaultInputDevice::PaDeviceIndex
    defaultOutputDevice::PaDeviceIndex
end

function Pa_GetHostApiInfo(hostApi)
    ccall(
        (:Pa_GetHostApiInfo, libportaudio),
        Ptr{PaHostApiInfo},
        (PaHostApiIndex,),
        hostApi,
    )
end

function Pa_HostApiTypeIdToHostApiIndex(type)
    ccall(
        (:Pa_HostApiTypeIdToHostApiIndex, libportaudio),
        PaHostApiIndex,
        (PaHostApiTypeId,),
        type,
    )
end

function Pa_HostApiDeviceIndexToDeviceIndex(hostApi, hostApiDeviceIndex)
    ccall(
        (:Pa_HostApiDeviceIndexToDeviceIndex, libportaudio),
        PaDeviceIndex,
        (PaHostApiIndex, Cint),
        hostApi,
        hostApiDeviceIndex,
    )
end

mutable struct PaHostErrorInfo
    hostApiType::PaHostApiTypeId
    errorCode::Clong
    errorText::Ptr{Cchar}
end

function Pa_GetLastHostErrorInfo()
    ccall((:Pa_GetLastHostErrorInfo, libportaudio), Ptr{PaHostErrorInfo}, ())
end

function Pa_GetDeviceCount()
    ccall((:Pa_GetDeviceCount, libportaudio), PaDeviceIndex, ())
end

function Pa_GetDefaultInputDevice()
    ccall((:Pa_GetDefaultInputDevice, libportaudio), PaDeviceIndex, ())
end

function Pa_GetDefaultOutputDevice()
    ccall((:Pa_GetDefaultOutputDevice, libportaudio), PaDeviceIndex, ())
end

const PaTime = Cdouble

const PaSampleFormat = Culong

mutable struct PaDeviceInfo
    structVersion::Cint
    name::Ptr{Cchar}
    hostApi::PaHostApiIndex
    maxInputChannels::Cint
    maxOutputChannels::Cint
    defaultLowInputLatency::PaTime
    defaultLowOutputLatency::PaTime
    defaultHighInputLatency::PaTime
    defaultHighOutputLatency::PaTime
    defaultSampleRate::Cdouble
end

function Pa_GetDeviceInfo(device)
    ccall((:Pa_GetDeviceInfo, libportaudio), Ptr{PaDeviceInfo}, (PaDeviceIndex,), device)
end

struct PaStreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostApiSpecificStreamInfo::Ptr{Cvoid}
end

function Pa_IsFormatSupported(inputParameters, outputParameters, sampleRate)
    ccall(
        (:Pa_IsFormatSupported, libportaudio),
        PaError,
        (Ptr{PaStreamParameters}, Ptr{PaStreamParameters}, Cdouble),
        inputParameters,
        outputParameters,
        sampleRate,
    )
end

const PaStream = Cvoid

const PaStreamFlags = Culong

mutable struct PaStreamCallbackTimeInfo
    inputBufferAdcTime::PaTime
    currentTime::PaTime
    outputBufferDacTime::PaTime
end

const PaStreamCallbackFlags = Culong

@enum PaStreamCallbackResult::UInt32 begin
    paContinue = 0
    paComplete = 1
    paAbort = 2
end

# typedef int PaStreamCallback ( const void * input , void * output , unsigned long frameCount , const PaStreamCallbackTimeInfo * timeInfo , PaStreamCallbackFlags statusFlags , void * userData )
const PaStreamCallback = Cvoid

function Pa_OpenStream(
    stream,
    inputParameters,
    outputParameters,
    sampleRate,
    framesPerBuffer,
    streamFlags,
    streamCallback,
    userData,
)
    ccall(
        (:Pa_OpenStream, libportaudio),
        PaError,
        (
            Ptr{Ptr{PaStream}},
            Ptr{PaStreamParameters},
            Ptr{PaStreamParameters},
            Cdouble,
            Culong,
            PaStreamFlags,
            Ptr{Cvoid},
            Ptr{Cvoid},
        ),
        stream,
        inputParameters,
        outputParameters,
        sampleRate,
        framesPerBuffer,
        streamFlags,
        streamCallback,
        userData,
    )
end

function Pa_OpenDefaultStream(
    stream,
    numInputChannels,
    numOutputChannels,
    sampleFormat,
    sampleRate,
    framesPerBuffer,
    streamCallback,
    userData,
)
    ccall(
        (:Pa_OpenDefaultStream, libportaudio),
        PaError,
        (
            Ptr{Ptr{PaStream}},
            Cint,
            Cint,
            PaSampleFormat,
            Cdouble,
            Culong,
            Ptr{Cvoid},
            Ptr{Cvoid},
        ),
        stream,
        numInputChannels,
        numOutputChannels,
        sampleFormat,
        sampleRate,
        framesPerBuffer,
        streamCallback,
        userData,
    )
end

function Pa_CloseStream(stream)
    ccall((:Pa_CloseStream, libportaudio), PaError, (Ptr{PaStream},), stream)
end

# typedef void PaStreamFinishedCallback ( void * userData )
const PaStreamFinishedCallback = Cvoid

function Pa_SetStreamFinishedCallback(stream, streamFinishedCallback)
    ccall(
        (:Pa_SetStreamFinishedCallback, libportaudio),
        PaError,
        (Ptr{PaStream}, Ptr{Cvoid}),
        stream,
        streamFinishedCallback,
    )
end

function Pa_StartStream(stream)
    ccall((:Pa_StartStream, libportaudio), PaError, (Ptr{PaStream},), stream)
end

function Pa_StopStream(stream)
    ccall((:Pa_StopStream, libportaudio), PaError, (Ptr{PaStream},), stream)
end

function Pa_AbortStream(stream)
    ccall((:Pa_AbortStream, libportaudio), PaError, (Ptr{PaStream},), stream)
end

function Pa_IsStreamStopped(stream)
    ccall((:Pa_IsStreamStopped, libportaudio), PaError, (Ptr{PaStream},), stream)
end

function Pa_IsStreamActive(stream)
    ccall((:Pa_IsStreamActive, libportaudio), PaError, (Ptr{PaStream},), stream)
end

mutable struct PaStreamInfo
    structVersion::Cint
    inputLatency::PaTime
    outputLatency::PaTime
    sampleRate::Cdouble
end

function Pa_GetStreamInfo(stream)
    ccall((:Pa_GetStreamInfo, libportaudio), Ptr{PaStreamInfo}, (Ptr{PaStream},), stream)
end

function Pa_GetStreamTime(stream)
    ccall((:Pa_GetStreamTime, libportaudio), PaTime, (Ptr{PaStream},), stream)
end

function Pa_GetStreamCpuLoad(stream)
    ccall((:Pa_GetStreamCpuLoad, libportaudio), Cdouble, (Ptr{PaStream},), stream)
end

function Pa_ReadStream(stream, buffer, frames)
    ccall(
        (:Pa_ReadStream, libportaudio),
        PaError,
        (Ptr{PaStream}, Ptr{Cvoid}, Culong),
        stream,
        buffer,
        frames,
    )
end

function Pa_WriteStream(stream, buffer, frames)
    ccall(
        (:Pa_WriteStream, libportaudio),
        PaError,
        (Ptr{PaStream}, Ptr{Cvoid}, Culong),
        stream,
        buffer,
        frames,
    )
end

function Pa_GetStreamReadAvailable(stream)
    ccall((:Pa_GetStreamReadAvailable, libportaudio), Clong, (Ptr{PaStream},), stream)
end

function Pa_GetStreamWriteAvailable(stream)
    ccall((:Pa_GetStreamWriteAvailable, libportaudio), Clong, (Ptr{PaStream},), stream)
end

function Pa_GetSampleSize(format)
    ccall((:Pa_GetSampleSize, libportaudio), PaError, (PaSampleFormat,), format)
end

function Pa_Sleep(msec)
    ccall((:Pa_Sleep, libportaudio), Cvoid, (Clong,), msec)
end

const paNoDevice = PaDeviceIndex(-1)

const paUseHostApiSpecificDeviceSpecification = PaDeviceIndex(-2)

const paFloat32 = PaSampleFormat(0x00000001)

const paInt32 = PaSampleFormat(0x00000002)

const paInt24 = PaSampleFormat(0x00000004)

const paInt16 = PaSampleFormat(0x00000008)

const paInt8 = PaSampleFormat(0x00000010)

const paUInt8 = PaSampleFormat(0x00000020)

const paCustomFormat = PaSampleFormat(0x00010000)

const paNonInterleaved = PaSampleFormat(0x80000000)

const paFormatIsSupported = 0

const paFramesPerBufferUnspecified = 0

const paNoFlag = PaStreamFlags(0)

const paClipOff = PaStreamFlags(0x00000001)

const paDitherOff = PaStreamFlags(0x00000002)

const paNeverDropInput = PaStreamFlags(0x00000004)

const paPrimeOutputBuffersUsingStreamCallback = PaStreamFlags(0x00000008)

const paPlatformSpecificFlags = PaStreamFlags(0xffff0000)

const paInputUnderflow = PaStreamCallbackFlags(0x00000001)

const paInputOverflow = PaStreamCallbackFlags(0x00000002)

const paOutputUnderflow = PaStreamCallbackFlags(0x00000004)

const paOutputOverflow = PaStreamCallbackFlags(0x00000008)

const paPrimingOutput = PaStreamCallbackFlags(0x00000010)

# exports
const PREFIXES = ["Pa", "pa"]
for name in names(@__MODULE__; all = true), prefix in PREFIXES
    if startswith(string(name), prefix)
        @eval export $name
    end
end

end # module
