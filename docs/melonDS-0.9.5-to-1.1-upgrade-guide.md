# MelonDSDeltaCore Upgrade Guide: melonDS 0.9.5 → 1.1

This document details everything needed to fork and upgrade **MelonDSDeltaCore** from melonDS 0.9.5 to melonDS 1.1, with a focus on enabling local multiplayer support.

## Table of Contents

1. [Why Upgrade](#1-why-upgrade)
2. [Architecture Changes Overview](#2-architecture-changes-overview)
3. [Step-by-Step Upgrade Plan](#3-step-by-step-upgrade-plan)
4. [Platform.h API Migration](#4-platformh-api-migration)
5. [NDS Core Instantiation Changes](#5-nds-core-instantiation-changes)
6. [Config System Migration](#6-config-system-migration)
7. [Multiplayer Architecture](#7-multiplayer-architecture)
8. [Podspec Changes](#8-podspec-changes)
9. [Bridge File Changes](#9-bridge-file-changes)
10. [Multiplayer Integration with Delta](#10-multiplayer-integration-with-delta)
11. [Risk Assessment](#11-risk-assessment)

---

## 1. Why Upgrade

| Aspect | 0.9.5 (Current) | 1.1 (Target) |
|--------|-----------------|---------------|
| **Architecture** | Global state, namespaces | `melonDS::NDS` class, fully instanced |
| **Multi-instance** | Separate OS processes + IPC | Multiple instances in one process |
| **Multiplayer** | Shared-memory IPC (not feasible on iOS) | Pluggable `MPInterface` abstraction |
| **MP Stability** | "Finicky" — connections drop after seconds | Thread-safe input, crash fixes |
| **WiFi Code** | Scattered in `frontend/qt_sdl/` | Clean `src/net/` module |
| **MP_* stubs** | All return 0/false in Delta's bridge | Can be wired to MultipeerConnectivity |

**Key insight:** In 0.9.5, all `Platform::MP_*` functions in Delta's bridge are **stubbed to return 0**. Local multiplayer was never implemented. melonDS 1.1's `MPInterface` abstraction makes this much cleaner to implement.

---

## 2. Architecture Changes Overview

### melonDS 0.9.5 (current)

```
Global namespaces: NDS::, GPU::, SPU::, Wifi::, etc.
    │
    ├── NDS::Init(), NDS::RunFrame(), NDS::Reset()
    ├── GPU::Framebuffer[FrontBuffer][0/1]
    ├── SPU::ReadOutput(buffer, len)
    └── Platform::MP_SendPacket(data, len, timestamp)
         └── Bridge stubs (return 0)
```

### melonDS 1.1 (target)

```
melonDS::NDS instance (constructed with NDSArgs + userdata)
    │
    ├── nds.RunFrame(), nds.Reset()
    ├── nds.GPU.Framebuffer[...]
    ├── nds.SPU.ReadOutput(buffer, len)
    └── Platform::MP_SendPacket(data, len, timestamp, userdata)
         │
         └── Frontend extracts instance from userdata
              └── MPInterface::Get().SendPacket(inst, data, len, timestamp)
                   └── LocalMP / LAN / Custom implementation
```

---

## 3. Step-by-Step Upgrade Plan

### Phase 1: Fork & Update melonDS Submodule
1. Fork `rileytestut/MelonDSDeltaCore`
2. Update the `melonDS` submodule from Riley's 0.9.x fork to upstream melonDS 1.1 tag
3. Verify the new source tree structure (new `src/net/`, `src/DSP_HLE/`, etc.)

### Phase 2: Fix Build (Podspec + Source Files)
4. Update podspec `source_files` to include new directories
5. Update podspec `exclude_files` for renamed/moved OpenGL files
6. Update header search paths
7. Update preprocessor definitions

### Phase 3: Migrate Bridge Code
8. Replace global `NDS::Init()` / `NDS::RunFrame()` with `melonDS::NDS` instance
9. Migrate `Config::` usage to `NDSArgs` constructor pattern
10. Update all `Platform::` function signatures (add `void* userdata`)
11. Remove deleted functions (`MP_Init`, `MP_DeInit`, `LAN_Init`, `LAN_DeInit`, etc.)
12. Add new required functions (`SignalStop`, `WriteDateTime`, `Mic_Start/Stop`, etc.)

### Phase 4: Implement Multiplayer
13. Implement `Platform::MP_*` functions to delegate to `MPInterface`
14. Create custom `MPInterface` subclass for MultipeerConnectivity
15. Wire up to Delta's `LocalMultiplayerManager`

### Phase 5: Test & Polish
16. Verify single-player games still work
17. Test local multiplayer with two devices
18. Performance testing

---

## 4. Platform.h API Migration

### Functions REMOVED in 1.1

```cpp
// DELETE these from the bridge:
void Init(int argc, char** argv);   // was not implemented anyway
void DeInit();                       // was not implemented anyway
void StopEmu();                      // replaced by SignalStop()
int InstanceID();                    // removed
std::string InstanceFileSuffix();    // removed

// Config system entirely removed:
int GetConfigInt(ConfigEntry entry);
bool GetConfigBool(ConfigEntry entry);
std::string GetConfigString(ConfigEntry entry);
bool GetConfigArray(ConfigEntry entry, void* data);

// Old file API replaced:
FILE* OpenFile(std::string path, std::string mode, bool mustexist);
FILE* OpenLocalFile(std::string path, std::string mode);

// Old multiplayer init/deinit removed:
bool MP_Init();
void MP_DeInit();

// LAN replaced by Net:
bool LAN_Init();
void LAN_DeInit();
int LAN_SendPacket(u8* data, int len);
int LAN_RecvPacket(u8* data);

// Mic_Prepare replaced:
void Mic_Prepare();
```

### Functions ADDED in 1.1

```cpp
// New stop mechanism:
void SignalStop(StopReason reason, void* userdata);

// New file API (returns FileHandle* instead of FILE*):
std::string GetLocalFilePath(const std::string& filename);
FileHandle* OpenFile(const std::string& path, FileMode mode);
FileHandle* OpenLocalFile(const std::string& path, FileMode mode);
bool FileExists(const std::string& name);
bool LocalFileExists(const std::string& name);
bool CheckFileWritable(const std::string& filepath);
bool CheckLocalFileWritable(const std::string& filepath);
bool CloseFile(FileHandle* file);
bool IsEndOfFile(FileHandle* file);
bool FileReadLine(char* str, int count, FileHandle* file);
u64 FilePosition(FileHandle* file);
bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin);
void FileRewind(FileHandle* file);
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file);
bool FileFlush(FileHandle* file);
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file);
u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...);
u64 FileLength(FileHandle* file);

// Logging:
void Log(LogLevel level, const char* fmt, ...);

// Timer functions:
u64 GetMSCount();
u64 GetUSCount();

// Semaphore addition:
bool Semaphore_TryWait(Semaphore* sema, int timeout_ms = 0);

// New save callbacks (all gain void* userdata):
void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata);
void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata);
void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen, void* userdata);
void WriteDateTime(int year, int month, int day, int hour, int minute, int second, void* userdata);

// Net replaces LAN:
int Net_SendPacket(u8* data, int len, void* userdata);
int Net_RecvPacket(u8* data, void* userdata);

// Camera gains userdata:
void Camera_Start(int num, void* userdata);
void Camera_Stop(int num, void* userdata);
void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata);

// New Mic API:
void Mic_Start(void* userdata);
void Mic_Stop(void* userdata);
int Mic_ReadInput(s16* data, int maxlength, void* userdata);

// AAC decoder:
AACDecoder* AAC_Init();
void AAC_DeInit(AACDecoder* dec);
bool AAC_Configure(AACDecoder* dec, int frequency, int channels);
bool AAC_DecodeFrame(AACDecoder* dec, const void* input, int inputlen, void* output, int outputlen);

// Addon/peripheral support:
bool Addon_KeyDown(KeyType type, void* userdata);
void Addon_RumbleStart(u32 len, void* userdata);
void Addon_RumbleStop(void* userdata);
float Addon_MotionQuery(MotionQueryType type, void* userdata);

// Dynamic library loading:
DynamicLibrary* DynamicLibrary_Load(const char* lib);
void DynamicLibrary_Unload(DynamicLibrary* lib);
void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name);
```

### Functions with CHANGED SIGNATURES

```cpp
// All MP functions gain void* userdata (and lose MP_Init/MP_DeInit):
void MP_Begin(void* userdata);                                           // was: void MP_Begin()
void MP_End(void* userdata);                                             // was: void MP_End()
int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata);     // was: no userdata
int MP_RecvPacket(u8* data, u64* timestamp, void* userdata);             // was: no userdata
int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata);        // was: no userdata
int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata); // was: no userdata
int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata);        // was: no userdata
int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata);         // was: no userdata
u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata); // was: no userdata
```

---

## 5. NDS Core Instantiation Changes

### Current bridge code (0.9.5 — global state):

```objc++
// In -startWithGameURL:
Config::Load();
Config::FirmwareUsername = "Delta";
Config::BIOS7Path = self.bios7URL.lastPathComponent.UTF8String;
// ... more Config:: assignments ...

NDS::SetConsoleType((int)self.systemType);
NDS::Init();

GPU::RenderSettings settings;
settings.Soft_Threaded = YES;
GPU::SetRenderSettings(0, settings);

NDS::Reset();
NDS::LoadCart((const u8 *)romData.bytes, (u32)romData.length, NULL, 0);
NDS::SetupDirectBoot(gameURL.lastPathComponent.UTF8String);
NDS::RunFrame();  // in game loop

// Video output:
memcpy(buffer, GPU::Framebuffer[GPU::FrontBuffer][0], screenBufferSize);
memcpy(buffer + offset, GPU::Framebuffer[GPU::FrontBuffer][1], screenBufferSize);

// Audio output:
u32 available = SPU::GetOutputSize();
int samples = SPU::ReadOutput(buffer, available);

// Input:
NDS::SetKeyMask(sanitizedInputs);
NDS::TouchScreen(x, y);
NDS::ReleaseScreen();
NDS::MicInputFrame(micBuffer, readFrames);
```

### New bridge code (1.1 — instance-based):

```objc++
// The bridge needs to own an NDS instance:
#include "NDS.h"
#include "Args.h"

// As an ivar or property:
std::unique_ptr<melonDS::NDS> nds;

// In -startWithGameURL:
melonDS::NDSArgs args;
args.ARM9BIOS = /* load BIOS9 file into ARM9BIOSImage */;
args.ARM7BIOS = /* load BIOS7 file into ARM7BIOSImage */;
args.Firmware = /* load firmware into melonDS::Firmware */;
args.JIT = /* JIT config or std::nullopt */;
args.Renderer = std::make_unique<melonDS::SoftRenderer>(true); // threaded

// userdata points back to our bridge context (for Platform:: callbacks)
void* userdata = (__bridge void*)self;  // or a C++ struct

if (self.systemType == MelonDSSystemTypeDSi) {
    melonDS::DSiArgs dsiArgs(std::move(args));
    dsiArgs.NANDImage = /* load NAND */;
    nds = std::make_unique<melonDS::DSi>(std::move(dsiArgs), userdata);
} else {
    nds = std::make_unique<melonDS::NDS>(std::move(args), userdata);
}

nds->Reset();

// Load cart — API changed, check new NDS.h for exact signatures
// Cart loading now uses NDSCart::CartCommon
auto cart = melonDS::NDSCart::ParseROM(romData.bytes, romData.length, nullptr);
nds->SetNDSCart(std::move(cart));
nds->SetupDirectBoot("game.nds");

// Game loop:
nds->RunFrame();

// Video output — GPU is now a member:
memcpy(buffer, nds->GPU.Framebuffer[nds->GPU.FrontBuffer][0], screenBufferSize);
memcpy(buffer + offset, nds->GPU.Framebuffer[nds->GPU.FrontBuffer][1], screenBufferSize);

// Audio output — SPU is now a member:
u32 available = nds->SPU.GetOutputSize();
int samples = nds->SPU.ReadOutput(buffer, available);

// Input — methods on the NDS instance:
nds->SetKeyMask(sanitizedInputs);
nds->TouchScreen(x, y);
nds->ReleaseScreen();
nds->MicInputFrame(micBuffer, readFrames);
```

---

## 6. Config System Migration

The entire `Config::` / `ConfigEntry` / `Platform::GetConfig*()` system is **removed** in 1.1. Configuration is passed through constructor args instead.

### What to delete from the bridge:

```cpp
// DELETE entirely — these functions and the ConfigEntry enum:
Platform::GetConfigInt(ConfigEntry entry)
Platform::GetConfigBool(ConfigEntry entry)
Platform::GetConfigString(ConfigEntry entry)
Platform::GetConfigArray(ConfigEntry entry, void* data)
```

### What to delete from source_files:

```
melonDS/src/frontend/qt_sdl/Config.{h,cpp}  // No longer exists or needed
```

### How config works now:

Configuration is set directly on the `NDSArgs` struct before constructing the NDS. There is no runtime config query system. BIOS/firmware/NAND paths are resolved by the frontend and loaded into memory before passing to the constructor.

---

## 7. Multiplayer Architecture

### The three-layer architecture in 1.1:

```
┌──────────────────────────────────────────────────────┐
│  Wifi.cpp (melonDS core)                             │
│  Calls: Platform::MP_SendPacket(data, len, ts,       │
│         NDS.UserData)                                │
└──────────────────┬───────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────┐
│  Platform::MP_* implementation (in bridge .mm file)  │
│  Extracts instance ID from userdata                  │
│  Calls: MPInterface::Get().SendPacket(inst, ...)     │
└──────────────────┬───────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────┐
│  MPInterface subclass                                │
│  ┌─────────────────┬──────────────┬────────────────┐ │
│  │ LocalMP         │ LAN          │ Custom         │ │
│  │ (in-process)    │ (network)    │ (Multipeer-    │ │
│  │                 │              │  Connectivity) │ │
│  └─────────────────┴──────────────┴────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### MPInterface.h — the abstract interface:

```cpp
class MPInterface {
public:
    static MPInterface& Get() { return *Current; }
    static void Set(MPInterfaceType type);

    virtual void Process() = 0;                    // called every video frame
    virtual void Begin(int inst) = 0;
    virtual void End(int inst) = 0;
    virtual int SendPacket(int inst, u8* data, int len, u64 timestamp) = 0;
    virtual int RecvPacket(int inst, u8* data, u64* timestamp) = 0;
    virtual int SendCmd(int inst, u8* data, int len, u64 timestamp) = 0;
    virtual int SendReply(int inst, u8* data, int len, u64 timestamp, u16 aid) = 0;
    virtual int SendAck(int inst, u8* data, int len, u64 timestamp) = 0;
    virtual int RecvHostPacket(int inst, u8* data, u64* timestamp) = 0;
    virtual u16 RecvReplies(int inst, u8* data, u64 timestamp, u16 aidmask) = 0;

protected:
    int RecvTimeout = 25;
};
```

### Platform::MP_* bridge pattern (what to implement):

```cpp
// In the bridge .mm file:
void MP_Begin(void* userdata) {
    // For single-instance Delta, inst is always 0
    // For multi-instance, extract from userdata
    int inst = 0; // or: ((BridgeContext*)userdata)->instanceID;
    MPInterface::Get().Begin(inst);
}

int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata) {
    int inst = 0;
    return MPInterface::Get().SendPacket(inst, data, len, timestamp);
}

int MP_RecvPacket(u8* data, u64* timestamp, void* userdata) {
    int inst = 0;
    return MPInterface::Get().RecvPacket(inst, data, timestamp);
}

// ... same pattern for all MP_* functions
```

---

## 8. Podspec Changes

### Current source_files:

```ruby
"melonDS/src/*.{h,hpp,cpp}",
"melonDS/src/tiny-AES-c/*.{h,hpp,c}",
"melonDS/src/dolphin/Arm64Emitter.{h,cpp}",
"melonDS/src/xxhash/*.{h,c}",
"melonDS/src/frontend/qt_sdl/Config.{h,cpp}",       # REMOVE
"melonDS/src/sha1/*.{h,c}",
"melonDS/src/fatfs/*.{h,c}",
"melonDS/src/teakra/src/*.{h,cpp}",
"melonDS/src/teakra/include/teakra/*.h",
"melonDS/src/frontend/qt_sdl/LAN_Socket.{h,cpp}",   # REMOVE (moved to src/net/)
"melonDS/src/frontend/libslirp/src/*.{h,c}",
"melonDS/src/frontend/libslirp/slirp/*.h",
"melonDS/src/frontend/libslirp/glib/*.{h,c}"
```

### New source_files (add these):

```ruby
# New directories in 1.1:
"melonDS/src/net/*.{h,cpp}",            # MPInterface, LocalMP, LAN, Net, etc.
"melonDS/src/DSP_HLE/*.{h,cpp}",        # New DSP HLE support (optional)
"melonDS/src/debug/*.{h,cpp}",          # Debug support (if needed)

# Verify these still exist and adjust as needed:
"melonDS/src/*.{h,hpp,cpp}",            # Core files (some renamed/moved)
"melonDS/src/fatfs/*.{h,c}",
"melonDS/src/sha1/*.{h,c}",
"melonDS/src/xxhash/*.{h,c}",
"melonDS/src/tiny-AES-c/*.{h,hpp,c}",
"melonDS/src/teakra/src/*.{h,cpp}",
"melonDS/src/teakra/include/teakra/*.h",
```

### Updated exclude_files:

```ruby
# OpenGL files may have been renamed/reorganized in 1.1:
"melonDS/src/GPU3D_OpenGL.cpp",          # Verify still exists
"melonDS/src/OpenGLSupport.cpp",         # Verify still exists
"melonDS/src/GPU_OpenGL.cpp",            # Verify still exists
"melonDS/src/teakra/src/teakra_c.cpp",
# ARMJIT exclusion may need revisiting — check if JIT files moved
```

### Updated xcconfig:

```ruby
"GCC_PREPROCESSOR_DEFINITIONS" => 'STATIC_LIBRARY=1 _NETINET_TCP_VAR_H_ MELONDS_VERSION=\"1.1\"',
"HEADER_SEARCH_PATHS" => '"${PODS_CONFIGURATION_BUILD_DIR}" "$(PODS_ROOT)/Headers/Private/MelonDSDeltaCore/melonDS/src" "$(PODS_ROOT)/Headers/Private/MelonDSDeltaCore/melonDS/src/net" "$(PODS_ROOT)/Headers/Private/MelonDSDeltaCore/melonDS/src/frontend/libslirp"',
```

---

## 9. Bridge File Changes

The entire `Platform` namespace implementation lives in `MelonDSEmulatorBridge.mm`. Here is a summary of every change needed:

### Functions to DELETE:

```cpp
void StopEmu() { ... }                    // → replaced by SignalStop
int InstanceID() { ... }                   // → removed
std::string InstanceFileSuffix() { ... }   // → removed
int GetConfigInt(ConfigEntry entry) { ... }    // → removed (whole config system)
bool GetConfigBool(ConfigEntry entry) { ... }  // → removed
std::string GetConfigString(ConfigEntry entry) { ... } // → removed
bool GetConfigArray(ConfigEntry entry, void* data) { ... } // → removed
FILE* OpenFile(std::string, std::string, bool) { ... }     // → new FileHandle API
FILE* OpenLocalFile(std::string, std::string) { ... }       // → new FileHandle API
void *GL_GetProcAddress(const char*) { ... }                // → removed
bool MP_Init() { ... }                    // → removed entirely
void MP_DeInit() { ... }                  // → removed entirely
bool LAN_Init() { ... }                   // → removed (replaced by Net_*)
void LAN_DeInit() { ... }                 // → removed
int LAN_SendPacket(u8*, int) { ... }      // → Net_SendPacket with userdata
int LAN_RecvPacket(u8*) { ... }           // → Net_RecvPacket with userdata
void Mic_Prepare() { ... }                // → Mic_Start/Mic_Stop/Mic_ReadInput
void WriteNDSSave(const u8*, u32, u32, u32) { ... }  // → gains void* userdata
void WriteGBASave(const u8*, u32, u32, u32) { ... }  // → gains void* userdata
void Camera_Start(int) { ... }            // → gains void* userdata
void Camera_Stop(int) { ... }             // → gains void* userdata
void Camera_CaptureFrame(int, u32*, int, int, bool) { ... } // → gains void* userdata
```

### Functions to ADD:

```cpp
// Stop/signal:
void SignalStop(StopReason reason, void* userdata) {
    // Equivalent to old StopEmu()
    MelonDSEmulatorBridge.sharedBridge.stopping = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DLTAEmulatorCore.emulationDidQuitNotification
        object:MelonDSEmulatorBridge.sharedBridge];
}

// New file I/O (implement using NSFileManager / fopen wrappers):
std::string GetLocalFilePath(const std::string& filename) { ... }
FileHandle* OpenFile(const std::string& path, FileMode mode) { ... }
FileHandle* OpenLocalFile(const std::string& path, FileMode mode) { ... }
bool FileExists(const std::string& name) { ... }
bool LocalFileExists(const std::string& name) { ... }
bool CheckFileWritable(const std::string& filepath) { ... }
bool CheckLocalFileWritable(const std::string& filepath) { ... }
bool CloseFile(FileHandle* file) { ... }
bool IsEndOfFile(FileHandle* file) { ... }
bool FileReadLine(char* str, int count, FileHandle* file) { ... }
u64 FilePosition(FileHandle* file) { ... }
bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin) { ... }
void FileRewind(FileHandle* file) { ... }
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file) { ... }
bool FileFlush(FileHandle* file) { ... }
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file) { ... }
u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...) { ... }
u64 FileLength(FileHandle* file) { ... }

// Logging:
void Log(LogLevel level, const char* fmt, ...) {
    va_list args; va_start(args, fmt);
    vprintf(fmt, args);  // or NSLog
    va_end(args);
}

// Timers:
u64 GetMSCount() { /* mach_absolute_time or clock_gettime */ }
u64 GetUSCount() { /* mach_absolute_time or clock_gettime */ }

// Semaphore addition:
bool Semaphore_TryWait(Semaphore* sema, int timeout_ms) {
    dispatch_semaphore_t s = (__bridge dispatch_semaphore_t)sema;
    if (timeout_ms == 0)
        return dispatch_semaphore_wait(s, DISPATCH_TIME_NOW) == 0;
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)timeout_ms * NSEC_PER_MSEC);
    return dispatch_semaphore_wait(s, timeout) == 0;
}

// New save callbacks (add void* userdata param):
void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata) { ... }
void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata) { ... }
void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen, void* userdata) { ... }
void WriteDateTime(int year, int month, int day, int hour, int minute, int second, void* userdata) { ... }

// Net (replaces LAN):
int Net_SendPacket(u8* data, int len, void* userdata) { ... }
int Net_RecvPacket(u8* data, void* userdata) { ... }

// Camera (gains userdata):
void Camera_Start(int num, void* userdata) { }
void Camera_Stop(int num, void* userdata) { }
void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata) { }

// Mic (new API):
void Mic_Start(void* userdata) { /* start AVAudioEngine */ }
void Mic_Stop(void* userdata) { /* stop AVAudioEngine */ }
int Mic_ReadInput(s16* data, int maxlength, void* userdata) { /* read from ring buffer */ }

// AAC decoder (can stub or use AudioToolbox):
AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder* dec) { }
bool AAC_Configure(AACDecoder* dec, int frequency, int channels) { return false; }
bool AAC_DecodeFrame(AACDecoder* dec, const void* input, int inputlen, void* output, int outputlen) { return false; }

// Addon/peripherals (stub):
bool Addon_KeyDown(KeyType type, void* userdata) { return false; }
void Addon_RumbleStart(u32 len, void* userdata) { }
void Addon_RumbleStop(void* userdata) { }
float Addon_MotionQuery(MotionQueryType type, void* userdata) { return 0.0f; }

// Dynamic library (stub on iOS):
DynamicLibrary* DynamicLibrary_Load(const char* lib) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary* lib) { }
void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name) { return nullptr; }
```

### Functions to UPDATE (signature changes):

```cpp
// MP functions — add void* userdata, delegate to MPInterface:
void MP_Begin(void* userdata) {
    MPInterface::Get().Begin(0);
}
void MP_End(void* userdata) {
    MPInterface::Get().End(0);
}
int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata) {
    return MPInterface::Get().SendPacket(0, data, len, timestamp);
}
int MP_RecvPacket(u8* data, u64* timestamp, void* userdata) {
    return MPInterface::Get().RecvPacket(0, data, timestamp);
}
int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata) {
    return MPInterface::Get().SendCmd(0, data, len, timestamp);
}
int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata) {
    return MPInterface::Get().SendReply(0, data, len, timestamp, aid);
}
int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata) {
    return MPInterface::Get().SendAck(0, data, len, timestamp);
}
int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata) {
    return MPInterface::Get().RecvHostPacket(0, data, timestamp);
}
u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata) {
    return MPInterface::Get().RecvReplies(0, data, timestamp, aidmask);
}
```

---

## 10. Multiplayer Integration with Delta

### Option A: Custom MPInterface Subclass (Recommended)

Create a new class that bridges melonDS multiplayer to MultipeerConnectivity:

```cpp
// MPInterface_MultipeerConnectivity.h
#include "MPInterface.h"

namespace melonDS {

class MPInterface_MPC : public MPInterface {
public:
    MPInterface_MPC();
    ~MPInterface_MPC();

    void Process() override;
    void Begin(int inst) override;
    void End(int inst) override;

    int SendPacket(int inst, u8* data, int len, u64 timestamp) override;
    int RecvPacket(int inst, u8* data, u64* timestamp) override;
    int SendCmd(int inst, u8* data, int len, u64 timestamp) override;
    int SendReply(int inst, u8* data, int len, u64 timestamp, u16 aid) override;
    int SendAck(int inst, u8* data, int len, u64 timestamp) override;
    int RecvHostPacket(int inst, u8* data, u64* timestamp) override;
    u16 RecvReplies(int inst, u8* data, u64 timestamp, u16 aidmask) override;

private:
    // Bridge to Swift's LocalMultiplayerManager
    void* swiftManager;  // (__bridge void*) to the Swift manager object

    // Packet queues (similar to LocalMP's circular buffers but
    // fed by MultipeerConnectivity receive callbacks)
    // ...
};

}
```

The key insight: `LocalMP` uses in-process shared buffers + semaphores. Our custom implementation would use the **same FIFO queue pattern** but feed the queues from MultipeerConnectivity instead of in-process writes.

### Option B: Hook Platform::MP_* Directly (Simpler, less clean)

Skip `MPInterface` entirely and implement `Platform::MP_*` to call into Swift/ObjC multiplayer code directly:

```cpp
int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata) {
    MelonDSEmulatorBridge* bridge = (__bridge MelonDSEmulatorBridge*)userdata;
    NSData* packet = [NSData dataWithBytes:data length:len];
    [bridge.multiplayerManager sendPacket:packet
                                     type:MPPacketTypeRegular
                                timestamp:timestamp];
    return len;
}
```

### Frame Format

The WiFi frames passed through `MP_SendPacket` etc. are:
- **12-byte TX header** + original 802.11 frame
- Max frame size: **2376 bytes** (`0x948`)
- Frame types: 0=regular, 1=CMD (host→clients), 2=reply (client→host), 3=ACK

When sending over MultipeerConnectivity, wrap in an envelope:

```
[4 bytes: magic "NIFI"]
[4 bytes: sender instance ID]
[4 bytes: type (0/1/2/3)]
[4 bytes: length]
[8 bytes: timestamp]
[N bytes: frame data]
```

This matches `MPPacketHeader` from `LocalMP.h` exactly.

---

## 11. Risk Assessment

### High Risk
- **NDS class migration**: Touches every line that references NDS::, GPU::, SPU::. Most invasive change.
- **File I/O rewrite**: The new `FileHandle*` API replaces `FILE*` throughout. Many functions to implement.
- **Config removal**: Every `Config::` reference must be replaced with constructor args.

### Medium Risk
- **Podspec source_files**: File paths have changed significantly. Will need iterative testing.
- **GPU rendering**: The GPU API changed. Software renderer initialization is different.
- **Save state format**: Savestate API may have changed — old save states might not be compatible.

### Low Risk
- **MP function signatures**: Mechanical change — add `void* userdata` to each function.
- **Thread/Mutex/Semaphore**: Mostly unchanged, just add `Semaphore_TryWait`.
- **Camera/Mic stubs**: Simple signature updates.

### Recommendation

The **FileHandle API** is the largest new implementation burden but is purely mechanical (wrapping `fopen`/`fread`/`fwrite`). Reference the Qt frontend's `Platform.cpp` at `src/frontend/qt_sdl/Platform.cpp` in the 1.1 source for a working implementation to adapt.

The **NDS class migration** is the highest-risk change. Consider doing this incrementally:
1. First, get it compiling with stubs
2. Then, get single-player working
3. Finally, wire up multiplayer

---

## References

- [melonDS 1.1 source — Platform.h](https://github.com/melonDS-emu/melonDS/blob/master/src/Platform.h)
- [melonDS 1.1 source — MPInterface.h](https://github.com/melonDS-emu/melonDS/blob/master/src/net/MPInterface.h)
- [melonDS 1.1 source — LocalMP.cpp](https://github.com/melonDS-emu/melonDS/blob/master/src/net/LocalMP.cpp)
- [melonDS 1.1 source — NDS.h](https://github.com/melonDS-emu/melonDS/blob/master/src/NDS.h)
- [melonDS 1.1 source — Args.h](https://github.com/melonDS-emu/melonDS/blob/master/src/Args.h)
- [melonDS 1.1 source — Qt frontend Platform.cpp](https://github.com/melonDS-emu/melonDS/blob/master/src/frontend/qt_sdl/Platform.cpp)
- [Current MelonDSDeltaCore](https://github.com/rileytestut/MelonDSDeltaCore)

---

## 12. Repository Upgrade Status (Implemented)

The repository now includes initial upgrade scaffolding toward melonDS 1.1:

- `melonDS` submodule is pinned to upstream melonDS `1.1` tag commit.
- `MelonDSDeltaCore.podspec` was updated to:
  - identify melonDS as `1.1` in preprocessor definitions
  - include new 1.1 source directories (`src/net`, `src/DSP_HLE`, `src/debug`)
  - use `src/net/libslirp` paths
- `MelonDS.swift` core version string was updated to `1.1`.
- `MelonDSEmulatorBridge.mm` Platform callback namespace/signatures were migrated to `melonDS::Platform` with 1.1 callback signatures and multiplayer packet bridge plumbing.

### Validation Script

Run:

```bash
scripts/validate_upgrade.sh
```

This validates:

- submodule pinning to melonDS `1.1`
- version definitions in podspec and Swift metadata
- presence of key 1.1 `Platform` bridge callback signatures

### Important Note

This upgrade is **in progress**. Full runtime parity requires completing the NDS core migration from global `NDS::/GPU::/SPU::` usage to instance-based `melonDS::NDS` ownership and wiring all remaining 1.1 API behavior paths in the bridge.
