// DEBUG-only: lets `-DeStreamOpenDetail <id>:<type>` open a Detail window at launch without touching the shell.
#if DEBUG
#include <TargetConditionals.h>
#if TARGET_OS_OSX
extern void DeStreamDetailDebugInstall(void);
__attribute__((constructor)) static void deStreamDetailDebugConstructor(void) { DeStreamDetailDebugInstall(); }
#endif
#endif
