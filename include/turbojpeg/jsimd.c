// detect automatically CPU type
#include <hl.h>
#if defined(__ANDROID__) || defined(__aarch64__) || defined(_M_ARM64)
#	include "jsimd_none.c"
#elif defined(HL_64)
#	include "x64/jsimd_x86_64.c"
#else
#	include "x86/jsimd_i386.c"
#endif