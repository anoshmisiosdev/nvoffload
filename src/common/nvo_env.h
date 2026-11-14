#pragma once
// Environment variables nvoffload reads and sets. Keep every name here so the launcher,
// the dylib and the docs agree.

// ---- read by nvoffload --------------------------------------------------------------
#define NVO_ENV_LOG          "NVOFFLOAD_LOG"       // 0..3, see nvo_log.h
#define NVO_ENV_DEVICE       "NVOFFLOAD_DEVICE"    // nvidia (default) | default | intel | registry:0x<id> | <name substring>
#define NVO_ENV_BRIDGE       "NVOFFLOAD_BRIDGE"    // 1 (default) = cross-GPU present bridge on when two devices exist; 0 = off
#define NVO_ENV_TRACE_PRESENT "NVOFFLOAD_TRACE_PRESENT" // 1 = log every CAMetalLayer nextDrawable / present
#define NVO_ENV_LIB          "NVOFFLOAD_LIB"       // launcher: explicit path to libnvoffload.dylib

// ---- NullMoth (nullmoth/nvidia-macos-driver) --------------------------------------------
// Read by NVMTLDriver.bundle / libnvmtl_translate / NVK. nvoffload never clears these; the
// launcher passes them through untouched. Listed so --info can show which are set.
static const char *const kNullMothEnvVars[] = {
    "NVMTL_APP_PROFILE", "NVMTL_AIRCACHE", "NVMTL_SPVCACHE_OFF", "NVMTL_CANONICAL_POINTERS",
    "NVMTL_SHARED_VRAM", "NVMTL_NO_NOCOPY", "NVMTL_NO_NVDEC", "NVMTL_TILE_SHADING",
    "NVMTL_RAW_PRESSURE", "NVMTL_NVK_MESSAGES", "NVMTL_FPS_LIMIT",
    "NVRM_FLUSH_TIMEOUT_MS", "NVRM_EVENT_WAIT", "NVRM_XNU_TRACE",
    "NVK_CURVES", "NVK_HWRT_QUERY", "NVK_LOCAL_MAP_SYSMEM", "NVK_PREEMPT_LOG",
    nullptr
};

// ---- MoltenVK ---------------------------------------------------------------------------
// MoltenVK orders VkPhysicalDevices with MTLCreateSystemDefaultDevice() first unless this is 1.
// nvoffload forces it to 0 so the interposed default device (the NVIDIA GPU) is physicalDevices[0].
#define MVK_ENV_FORCE_LOW_POWER "MVK_CONFIG_FORCE_LOW_POWER_GPU"
