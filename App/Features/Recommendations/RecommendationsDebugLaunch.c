// DEBUG-only: lets `-DeStreamOpenSuggestions <state>` open a For You QA window at launch without touching the shell.
#if DEBUG
#include <TargetConditionals.h>
#if TARGET_OS_OSX
extern void DeStreamSuggestionsDebugInstall(void);
__attribute__((constructor)) static void deStreamSuggestionsDebugConstructor(void) { DeStreamSuggestionsDebugInstall(); }
#endif
#endif
