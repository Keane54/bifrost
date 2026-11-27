#include "BifrostModuleHostSandbox.h"

#include <stddef.h>
#include <sandbox.h>

// Apple deprecated sandbox_init and calls custom profiles unsupported, but there's no removal date
// and Chromium's helpers rely on it too, so the warning is silenced here and nowhere else. Flags 0
// means the profile is SBPL text. Apple's named profiles are never used, because SDK 27 kills a
// process that uses them. The host writes nothing when this fails, so the error text is freed
// unread.
int bifrost_enter_sandbox(const char *profile) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    char *error = NULL;
    int result = sandbox_init(profile, 0, &error);
    sandbox_free_error(error);
#pragma clang diagnostic pop
    return result == 0 ? 0 : -1;
}
