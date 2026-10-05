// DEBUG-only: lets `-DeStreamOpenLibrary downloads|saved|saved:<id>` open a Library window at launch without touching the shell.
#if DEBUG
#include <TargetConditionals.h>
#if TARGET_OS_OSX
extern void DeStreamLibraryDebugInstall(void);
__attribute__((constructor)) static void deStreamLibraryDebugConstructor(void) { DeStreamLibraryDebugInstall(); }
#endif
#endif
