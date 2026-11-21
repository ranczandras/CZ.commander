// Blackmagic RAW (.braw) thumbnails for CZ.commander.
// Uses the Blackmagic RAW API (headers in BlackmagicSDK/, Blackmagic Design permissive license).
// The decoder library itself is NOT shipped: it is loaded at run time from an installed
// Blackmagic RAW Player, DaVinci Resolve or Blackmagic RAW SDK.

#include "include/BRAWBridge.h"
#include "BlackmagicSDK/BlackmagicRawAPI.h"

#include <mutex>
#include <vector>

namespace {

const char* const kFrameworkDirs[] = {
    "/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Frameworks",
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
    "/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app/Contents/Frameworks",
    "/Library/Frameworks",
};

/// Receives decode results for the single job currently in flight (calls are serialized).
class ThumbnailCallback : public IBlackmagicRawCallback {
public:
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleFull;
    CGImageRef image = nullptr;

    void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result, IBlackmagicRawFrame* frame) override {
        IBlackmagicRawJob* processJob = nullptr;
        if (result == S_OK) result = frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU8);
        if (result == S_OK) result = frame->SetResolutionScale(scale);
        if (result == S_OK) result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &processJob);
        if (result == S_OK) result = processJob->Submit();
        if (result != S_OK && processJob != nullptr) processJob->Release();
        readJob->Release();
    }

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* processed) override {
        uint32_t width = 0, height = 0, sizeBytes = 0;
        void* pixels = nullptr;
        if (result == S_OK) result = processed->GetWidth(&width);
        if (result == S_OK) result = processed->GetHeight(&height);
        if (result == S_OK) result = processed->GetResourceSizeBytes(&sizeBytes);
        if (result == S_OK) result = processed->GetResource(&pixels);
        if (result == S_OK && pixels != nullptr && width > 0 && height > 0 && sizeBytes >= width * height * 4) {
            // Copy: the decoder's buffer is only valid inside this callback.
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, static_cast<const UInt8*>(pixels), sizeBytes);
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            image = CGImageCreate(width, height, 8, 32, width * 4, space,
                                  kCGImageAlphaNoneSkipLast | kCGImageByteOrderDefault,
                                  provider, nullptr, true, kCGRenderingIntentDefault);
            CGColorSpaceRelease(space);
            CGDataProviderRelease(provider);
            CFRelease(data);
        }
        job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) override { return E_NOTIMPL; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 0; }
    ULONG STDMETHODCALLTYPE Release() override { return 0; }
};

std::mutex g_mutex;
bool g_triedLoad = false;
IBlackmagicRawFactory* g_factory = nullptr;
IBlackmagicRaw* g_codec = nullptr;
ThumbnailCallback g_callback;

/// Loads the decoder once (caller holds g_mutex).
bool ensureCodec() {
    if (g_codec != nullptr) return true;
    if (g_triedLoad) return false;
    g_triedLoad = true;
    for (const char* dir : kFrameworkDirs) {
        CFStringRef path = CFStringCreateWithCString(kCFAllocatorDefault, dir, kCFStringEncodingUTF8);
        g_factory = CreateBlackmagicRawFactoryInstanceFromPath(path);
        CFRelease(path);
        if (g_factory != nullptr) break;
    }
    if (g_factory == nullptr) return false;
    if (g_factory->CreateCodec(&g_codec) != S_OK || g_codec == nullptr) {
        g_codec = nullptr;
        return false;
    }
    if (g_codec->SetCallback(&g_callback) != S_OK) {
        g_codec->Release();
        g_codec = nullptr;
        return false;
    }
    return true;
}

/// Smallest decoder scale that still gives at least `maxDimension` pixels on the long side.
BlackmagicRawResolutionScale pickScale(uint32_t width, uint32_t height, int maxDimension) {
    const uint32_t longSide = width > height ? width : height;
    if (longSide / 8 >= static_cast<uint32_t>(maxDimension)) return blackmagicRawResolutionScaleEighth;
    if (longSide / 4 >= static_cast<uint32_t>(maxDimension)) return blackmagicRawResolutionScaleQuarter;
    if (longSide / 2 >= static_cast<uint32_t>(maxDimension)) return blackmagicRawResolutionScaleHalf;
    return blackmagicRawResolutionScaleFull;
}

} // namespace

bool CZBRAWIsAvailable(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return ensureCodec();
}

CGImageRef CZBRAWCreateThumbnail(const char* path, int maxDimension) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!ensureCodec()) return nullptr;

    CFStringRef clipPath = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (clipPath == nullptr) return nullptr;

    IBlackmagicRawClip* clip = nullptr;
    IBlackmagicRawJob* readJob = nullptr;
    CGImageRef result = nullptr;

    if (g_codec->OpenClip(clipPath, &clip) == S_OK && clip != nullptr) {
        uint32_t width = 0, height = 0;
        clip->GetWidth(&width);
        clip->GetHeight(&height);
        g_callback.scale = pickScale(width, height, maxDimension > 0 ? maxDimension : 256);
        g_callback.image = nullptr;
        if (clip->CreateJobReadFrame(0, &readJob) == S_OK && readJob != nullptr) {
            if (readJob->Submit() == S_OK) {
                g_codec->FlushJobs();   // blocks until read + decode + process finished
                result = g_callback.image;
                g_callback.image = nullptr;
            } else {
                readJob->Release();
            }
        }
        clip->Release();
    }
    CFRelease(clipPath);
    return result;
}
