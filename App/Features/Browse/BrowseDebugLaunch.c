// DEBUG-only: lets `-DeStreamOpenBrowse home|search` open a Browse window at launch without touching the shell.
#if DEBUG
#include <TargetConditionals.h>
#if TARGET_OS_OSX
extern void DeStreamBrowseDebugInstall(void);
__attribute__((constructor)) static void deStreamBrowseDebugConstructor(void) { DeStreamBrowseDebugInstall(); }
#endif
#endif
