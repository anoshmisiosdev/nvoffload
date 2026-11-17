#pragma once
// Process-level decision made once at load: is nvoffload active in this process?
//
// With no NVOFFLOAD_POLICY in the environment (manual nvprime-run use) it is always active. When NVOffload.app has
// set NVOFFLOAD_POLICY session-wide, the JSON file decides:
//   { "mode": "off" | "allowlist" | "all",  "apps": ["bundle.id", "ExecutableName", ...],  "exclude": [...] }
//   off        never active
//   allowlist  active only for listed bundle identifiers / executable names
//   all        active for every third-party GUI app (has a bundle id not starting with com.apple.), plus listed names
// Apple's own apps strip DYLD_INSERT_LIBRARIES anyway; nvoffload's own processes are always excluded.
bool        nvo_policy_active(void);
const char *nvo_policy_reason(void);
