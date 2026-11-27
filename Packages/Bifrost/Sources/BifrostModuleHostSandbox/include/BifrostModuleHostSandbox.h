// The one call of the module host that Swift can't make itself. The SDK declares sandbox_init in
// sandbox.h, which no Swift module exports, and marks it deprecated, which -warnings-as-errors
// would turn into a failed build, so this C wrapper makes the call instead.
#ifndef BIFROST_MODULE_HOST_SANDBOX_H
#define BIFROST_MODULE_HOST_SANDBOX_H

// Puts the process in the sandbox of an SBPL profile for the rest of its life. It gives 0 when
// the sandbox is on and -1 when sandbox_init refused the profile.
int bifrost_enter_sandbox(const char *profile);

#endif
