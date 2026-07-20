#include <aaudio/AAudio.h>
#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <string>
#include <vector>

namespace {

constexpr char kLogTag[] = "AudioRepeaterNative";
struct StreamState {
    AAudioStream* stream = nullptr;
    int32_t bytesPerFrame = 0;
};

StreamState* fromHandle(jlong handle) {
    return reinterpret_cast<StreamState*>(static_cast<intptr_t>(handle));
}

void throwIllegalState(JNIEnv* env, const std::string& message) {
    jclass exceptionClass = env->FindClass("java/lang/IllegalStateException");
    if (exceptionClass != nullptr) {
        env->ThrowNew(exceptionClass, message.c_str());
    }
}

std::string resultMessage(const char* operation, aaudio_result_t result) {
    return std::string(operation) + " failed: " + AAudio_convertResultToText(result) +
        " (" + std::to_string(result) + ")";
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeOpen(
    JNIEnv* env,
    jobject,
    jint sampleRate,
    jint channelCount
) {
    AAudioStreamBuilder* builder = nullptr;
    aaudio_result_t result = AAudio_createStreamBuilder(&builder);
    if (result != AAUDIO_OK || builder == nullptr) {
        throwIllegalState(env, resultMessage("AAudio_createStreamBuilder", result));
        return 0;
    }

    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSampleRate(builder, sampleRate);
    AAudioStreamBuilder_setChannelCount(builder, channelCount);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MUSIC);

    AAudioStream* stream = nullptr;
    result = AAudioStreamBuilder_openStream(builder, &stream);
    AAudioStreamBuilder_delete(builder);
    if (result != AAUDIO_OK || stream == nullptr) {
        throwIllegalState(env, resultMessage("AAudioStreamBuilder_openStream", result));
        return 0;
    }

    const auto actualSharingMode = AAudioStream_getSharingMode(stream);
    const auto actualPerformanceMode = AAudioStream_getPerformanceMode(stream);
    const int32_t actualSampleRate = AAudioStream_getSampleRate(stream);
    const int32_t actualChannelCount = AAudioStream_getChannelCount(stream);

    if (actualSharingMode != AAUDIO_SHARING_MODE_EXCLUSIVE) {
        AAudioStream_close(stream);
        throwIllegalState(env, "AAudio EXCLUSIVE request fell back to SHARED");
        return 0;
    }
    if (actualPerformanceMode != AAUDIO_PERFORMANCE_MODE_LOW_LATENCY) {
        AAudioStream_close(stream);
        throwIllegalState(env, "AAudio LOW_LATENCY request was not granted");
        return 0;
    }
    if (actualSampleRate != sampleRate || actualChannelCount != channelCount) {
        const std::string message =
            "AAudio format mismatch: requested " + std::to_string(sampleRate) + " Hz / " +
            std::to_string(channelCount) + " ch, actual " + std::to_string(actualSampleRate) +
            " Hz / " + std::to_string(actualChannelCount) + " ch";
        AAudioStream_close(stream);
        throwIllegalState(env, message);
        return 0;
    }

    const int32_t framesPerBurst = AAudioStream_getFramesPerBurst(stream);
    if (framesPerBurst > 0) {
        const int32_t requestedBufferFrames = framesPerBurst * 16;
        const aaudio_result_t bufferResult =
            AAudioStream_setBufferSizeInFrames(stream, requestedBufferFrames);
        if (bufferResult < 0) {
            __android_log_print(
                ANDROID_LOG_WARN,
                kLogTag,
                "AAudioStream_setBufferSizeInFrames failed: %s (%d)",
                AAudio_convertResultToText(bufferResult),
                bufferResult
            );
        }
    }

    auto* state = new StreamState();
    state->stream = stream;
    state->bytesPerFrame = actualChannelCount * static_cast<int32_t>(sizeof(int16_t));

    __android_log_print(
        ANDROID_LOG_INFO,
        kLogTag,
        "opened EXCLUSIVE LOW_LATENCY rate=%d channels=%d burst=%d capacity=%d buffer=%d",
        actualSampleRate,
        actualChannelCount,
        framesPerBurst,
        AAudioStream_getBufferCapacityInFrames(stream),
        AAudioStream_getBufferSizeInFrames(stream)
    );
    return static_cast<jlong>(reinterpret_cast<intptr_t>(state));
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeGetInfo(
    JNIEnv* env,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr || state->stream == nullptr) {
        throwIllegalState(env, "AAudio stream is closed");
        return nullptr;
    }

    const jint values[] = {
        static_cast<jint>(AAudioStream_getSharingMode(state->stream)),
        static_cast<jint>(AAudioStream_getPerformanceMode(state->stream)),
        AAudioStream_getSampleRate(state->stream),
        AAudioStream_getChannelCount(state->stream),
        AAudioStream_getFramesPerBurst(state->stream),
        AAudioStream_getBufferCapacityInFrames(state->stream),
        AAudioStream_getBufferSizeInFrames(state->stream),
    };
    jintArray result = env->NewIntArray(static_cast<jsize>(std::size(values)));
    if (result != nullptr) {
        env->SetIntArrayRegion(result, 0, static_cast<jsize>(std::size(values)), values);
    }
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeStart(
    JNIEnv* env,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr || state->stream == nullptr) {
        throwIllegalState(env, "AAudio stream is closed");
        return;
    }
    const aaudio_result_t result = AAudioStream_requestStart(state->stream);
    if (result != AAUDIO_OK) {
        throwIllegalState(env, resultMessage("AAudioStream_requestStart", result));
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeWrite(
    JNIEnv* env,
    jobject,
    jlong handle,
    jbyteArray buffer,
    jint offset,
    jint byteCount,
    jlong timeoutNanos
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr || state->stream == nullptr) {
        throwIllegalState(env, "AAudio stream is closed");
        return 0;
    }
    if (buffer == nullptr || offset < 0 || byteCount < 0 ||
        offset + byteCount > env->GetArrayLength(buffer) ||
        byteCount % state->bytesPerFrame != 0) {
        throwIllegalState(env, "AAudio write buffer is invalid or not frame-aligned");
        return 0;
    }

    std::vector<jbyte> copy(static_cast<size_t>(byteCount));
    env->GetByteArrayRegion(buffer, offset, byteCount, copy.data());
    if (env->ExceptionCheck()) {
        return 0;
    }

    const int32_t requestedFrames = byteCount / state->bytesPerFrame;
    const aaudio_result_t writtenFrames = AAudioStream_write(
        state->stream,
        copy.data(),
        requestedFrames,
        timeoutNanos
    );
    if (writtenFrames < 0) {
        throwIllegalState(env, resultMessage("AAudioStream_write", writtenFrames));
        return 0;
    }
    return writtenFrames * state->bytesPerFrame;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeGetFramesRead(
    JNIEnv* env,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr || state->stream == nullptr) {
        throwIllegalState(env, "AAudio stream is closed");
        return 0;
    }
    return AAudioStream_getFramesRead(state->stream);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeGetXRunCount(
    JNIEnv* env,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr || state->stream == nullptr) {
        throwIllegalState(env, "AAudio stream is closed");
        return 0;
    }
    return AAudioStream_getXRunCount(state->stream);
}

extern "C" JNIEXPORT void JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeRequestStop(
    JNIEnv*,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state != nullptr && state->stream != nullptr) {
        AAudioStream_requestStop(state->stream);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_a2m_audiorepeater_NativeAaudioStream_nativeClose(
    JNIEnv*,
    jobject,
    jlong handle
) {
    StreamState* state = fromHandle(handle);
    if (state == nullptr) return;
    if (state->stream != nullptr) {
        AAudioStream_close(state->stream);
        state->stream = nullptr;
    }
    delete state;
}
