/*
 * Copyright (C)2015-2026 Haxe Foundation
 * ARM64 JIT Implementation for HashLink
 */

#if defined(__aarch64__) || defined(_M_ARM64)

#include <math.h>
#include <hlmodule.h>
#ifndef HL_WIN
#include <signal.h>
#include <unistd.h>
#else
#include <intrin.h>  /* For __dmb, __isb, FlushInstructionCache etc. on MSVC ARM64 */
#endif
#include <string.h>

#if defined(__APPLE__)
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#include <sys/ucontext.h>
#include <mach/mach.h>
#endif

/* Debug tracking */
int g_debug_findex = 0;

/*
 * Wrapper for setjmp that can be called as a regular function from JIT code.
 * On many platforms (especially MSVC ARM64), setjmp is a compiler intrinsic/macro
 * and cannot be taken as a function pointer. This wrapper provides a stable
 * address for the JIT to call.
 */
#include <setjmp.h>
static int hl_setjmp_wrapper(jmp_buf buf) {
    return setjmp(buf);
}

#ifdef JIT_TRACE_REGALLOC
int g_trace_findex = 0;
int g_trace_opCount = 0;
#endif

/* Global variables to track JIT code location for debugging - defined later */
unsigned char *jit_code_base = NULL;
int jit_code_size = 0;

/* Global for signal handler */
static volatile void *last_callback_fun = NULL;

/* Debug: track function compilation */
static int jit_func_count = 0;
static const char *jit_last_func = NULL;

/* Signal handler for debugging crashes - gets installed after hl_jit_code */
static struct { int findex; int start; int end; } g_func_table[10000];
static int g_func_table_count = 0;

static int lookup_function_by_offset(int offset) {
    for (int i = 0; i < g_func_table_count; i++) {
        if (offset >= g_func_table[i].start && offset < g_func_table[i].end) {
            return g_func_table[i].findex;
        }
    }
    return -1;
}

#ifndef HL_WIN
void arm64_crash_handler_siginfo(int sig, siginfo_t *info, void *ucontext) {
    /* This handler runs even if another handler is installed after */
    static volatile int handler_called = 0;
    handler_called++;
    
    /* Write ARM64-specific debug info to stderr immediately */
    write(2, "\n=== ARM64 JIT DEBUG ===\n", 25);
    
#if defined(__APPLE__) && defined(__aarch64__)
    if (ucontext) {
        ucontext_t *uc = (ucontext_t *)ucontext;
        arm_thread_state64_t *ts = (arm_thread_state64_t *)&uc->uc_mcontext->__ss;
        uint64_t pc = ts->__pc;
        uint64_t fault = info ? (uint64_t)(intptr_t)info->si_addr : 0;
        
        char buf[512];
        int len = snprintf(buf, sizeof(buf),
            "PC: 0x%llx  Fault: 0x%llx\n"
            "X0: 0x%llx  X1: 0x%llx  X2: 0x%llx\n"
            "X19: 0x%llx  X20: 0x%llx  X21: 0x%llx\n"
            "FP: 0x%llx  SP: 0x%llx  LR: 0x%llx\n",
            pc, fault,
            ts->__x[0], ts->__x[1], ts->__x[2],
            ts->__x[19], ts->__x[20], ts->__x[21],
            ts->__fp, ts->__sp, ts->__lr);
        write(2, buf, len);
        
        if (jit_code_base) {
            intptr_t offset = (intptr_t)pc - (intptr_t)jit_code_base;
            len = snprintf(buf, sizeof(buf),
                "JIT base: %p  PC offset: 0x%lx (size=%d)\n",
                jit_code_base, (unsigned long)offset, jit_code_size);
            write(2, buf, len);
            
            if (offset >= 0 && offset < jit_code_size) {
                int findex = lookup_function_by_offset((int)offset);
                unsigned int *instr = (unsigned int *)pc;
                len = snprintf(buf, sizeof(buf),
                    "In JIT: findex=%d  instr=0x%08x\n", findex, *instr);
                write(2, buf, len);
                
                /* Print surrounding instructions */
                for (int di = -4; di <= 2; di++) {
                    unsigned int *p = instr + di;
                    len = snprintf(buf, sizeof(buf), "  %s 0x%llx: 0x%08x\n",
                        (di == 0) ? "->" : "  ", (unsigned long long)p, *p);
                    write(2, buf, len);
                }
            }
            
            /* Also look up LR */
            intptr_t lr_offset = (intptr_t)ts->__lr - (intptr_t)jit_code_base;
            if (lr_offset >= 0 && lr_offset < jit_code_size) {
                int lr_findex = lookup_function_by_offset((int)lr_offset);
                len = snprintf(buf, sizeof(buf),
                    "Caller (LR): findex=%d  offset=0x%lx\n", lr_findex, (unsigned long)lr_offset);
                write(2, buf, len);
            }
        }
    }
#endif
    write(2, "=========================\n", 26);
    /* Also dump HL stack trace and raise signal */
    printf("SIGNAL %d\n", sig);
    if (hl_get_thread() != NULL) {
        hl_dump_stack();
    }
    fflush(stdout);
    /* Reset handler and re-raise to get default behavior (crash) */
    signal(sig, SIG_DFL);
    raise(sig);
}
#endif /* !HL_WIN */

/* Extern declarations for native functions we want to debug */
extern varray* hl_type_enum_values(hl_type *t);

#ifdef HL_DEBUG
// #define JIT_DEBUG
#endif

/* DISABLED - was for debugging trace() issue */
// #define JIT_DEBUG

/* Enable runtime tracing for specific functions (comment out to disable) */
// #define JIT_FORCE_STACK  /* Force stack for all ops - diagnostic only */
// #define JIT_TRACE_FUNC_6273 6273   /* Heaps crash function */
// #define JIT_TRACE_FUNC_6212 6212   /* Heaps crash function (updated findex) */
// #define JIT_TRACE_REGALLOC 1  /* Enable register allocator tracing for crash function */
// #define JIT_TRACE_FUNC_248 248
// #define JIT_TRACE_FUNC_240 240
// #define JIT_TRACE_FUNC_63 63
// #define JIT_TRACE_FUNC_20 20
// #define JIT_TRACE_FUNC_255 255  /* TestManyRegs function */
// #define JIT_TRACE_FUNC_2305 2305  /* Previous crash function */
// #define JIT_TRACE_FUNC_4781 4781  /* New crash function */

/* Disable verbose debug output - comment out to re-enable */
#define JIT_QUIET 1

/* Debug limit: only compile first N ops of large functions, then return */
/* Set to 0 to disable, or a positive number to limit */
// #define JIT_DEBUG_LIMIT_FUNC 6212  /* Only apply limit to this function */
// #define JIT_DEBUG_LIMIT_OPS  10726  /* Compile only first N ops */

/* Runtime trace helper */
void runtime_trace_op(int findex, int opCount, const char *opName) {
    printf("TRACE[%d]: op[%d] = %s\n", findex, opCount, opName);
    fflush(stdout);
}

/* Debug helper to print X0 value for HVIRTUAL calls */
void jit_debug_print_x0(int64_t x0_val) {
    printf("DEBUG X0: %lld (0x%llx)\n", (long long)x0_val, (unsigned long long)x0_val);
    fflush(stdout);
}

/* Debug helper for OSwitch */
void jit_debug_switch(int64_t value, int ncases) {
    printf("DEBUG SWITCH: value=%lld (0x%llx), ncases=%d\n", 
           (long long)value, (unsigned long long)value, ncases);
    fflush(stdout);
}

/* Only called for ncases=5 switches to debug FunctionKind */
void jit_debug_switch5(int64_t value, int extra0, int extra4) {
    static int call_count = 0;
    call_count++;
    /* Only print if case 0 and case 4 have the same target (Splitter pattern) */
    if (extra0 == extra4) {
        printf("SPLITTER SWITCH: call#%d value=%lld (0x%llx)\n", 
               call_count, value, (unsigned long long)value);
        if (value < 0 || value > 4) {
            printf("  *** GARBAGE VALUE! This is memory corruption or wrong register! ***\n");
        } else if (value == 2 || value == 3) {
            printf("  *** VALUE %lld WILL HIT DEFAULT (Init/Helper) ***\n", value);
        }
    }
    fflush(stdout);
}

/* Debug helper for dynamic field get */
void jit_debug_dyn_get(void *obj, int hash, void *dst_type, const char *label) {
    printf("DEBUG DYN_GET: obj=%p, hash=%d, dst_type=%p, from %s\n", 
           obj, hash, dst_type, label);
    fflush(stdout);
}

/* Debug helper for OEnumIndex - trace enum value access */
void jit_debug_enum_index(void *enum_ptr, int result_index) {
    printf("DEBUG ENUM_INDEX: enum_ptr=%p, result_index=%d\n", enum_ptr, result_index);
    if (enum_ptr) {
        venum *e = (venum *)enum_ptr;
        printf("  enum->t=%p (kind=%d)\n", (void*)e->t, e->t ? e->t->kind : -1);
        if (e->t && e->t->kind == HENUM) {
            printf("  enum type name: %s\n", e->t->tenum ? e->t->tenum->name : "null");
        }
    }
    fflush(stdout);
}

/* Debug helper for OField on HVIRTUAL */
void jit_debug_vfield_access(void *vobj, int field_idx, void *field_ptr, void *result, int is_fast_path) {
    printf("DEBUG VFIELD: vobj=%p, field_idx=%d, field_ptr=%p, result=%p, fast_path=%d\n",
           vobj, field_idx, field_ptr, result, is_fast_path);
    if (vobj) {
        vvirtual *v = (vvirtual *)vobj;
        printf("  virtual->t=%p (kind=%d)\n", (void*)v->t, v->t ? v->t->kind : -1);
        if (v->t && v->t->kind == HVIRTUAL && v->t->virt && field_idx < v->t->virt->nfields) {
            printf("  field[%d].hashed_name=%d, field[%d].t->kind=%d\n", 
                   field_idx, v->t->virt->fields[field_idx].hashed_name,
                   field_idx, v->t->virt->fields[field_idx].t ? v->t->virt->fields[field_idx].t->kind : -1);
        }
    }
    fflush(stdout);
}

/* Debug helper for FunctionKind access specifically */
void jit_debug_functionkind_access(void *vobj, int field_idx) {
    if (!vobj) {
        printf("FKIND DEBUG: vobj is NULL!\n");
        fflush(stdout);
        return;
    }
    vvirtual *v = (vvirtual *)vobj;
    printf("FKIND DEBUG: vobj=%p, field_idx=%d\n", vobj, field_idx);
    printf("  v->t=%p (kind=%d)\n", (void*)v->t, v->t ? v->t->kind : -1);
    
    /* Get the field pointer from vfields */
    void **fields = hl_vfields(v);
    void *field_ptr = fields[field_idx];
    printf("  hl_vfields(v)[%d] = %p\n", field_idx, field_ptr);
    
    if (field_ptr) {
        /* This should be an enum pointer - check it */
        venum *e = *(venum **)field_ptr;  /* Dereference the field ptr */
        printf("  *field_ptr = %p (enum)\n", (void*)e);
        if (e) {
            printf("  enum->t=%p (kind=%d), enum->index=%d\n", 
                   (void*)e->t, e->t ? e->t->kind : -1, e->index);
            if (e->t && e->t->kind == HENUM && e->t->tenum) {
                printf("  enum type: nconstructs=%d, construct[%d].name=",
                       e->t->tenum->nconstructs, e->index);
                if (e->index < e->t->tenum->nconstructs) {
                    const uchar *name = e->t->tenum->constructs[e->index].name;
                    while (name && *name) { putchar((char)*name); name++; }
                }
                printf("\n");
            }
        }
    }
    fflush(stdout);
}

/* Debug helper for HVIRTUAL method call */
void jit_debug_hvirtual_call(void *vobj, int field_index, void *method_ptr) {
    vvirtual *v = (vvirtual *)vobj;
    printf("=== HVIRTUAL DEBUG ===\n");
    printf("Virtual object: %p\n", vobj);
    printf("Field index: %d\n", field_index);
    printf("Method pointer from hl_vfields: %p\n", method_ptr);
    if (v) {
        printf("Virtual->t: %p (kind=%d)\n", (void *)v->t, v->t ? v->t->kind : -1);
        printf("Virtual->value: %p\n", (void *)v->value);
        if (v->t && v->t->kind == HVIRTUAL && v->t->virt) {
            printf("Virtual type has %d fields\n", v->t->virt->nfields);
            if (field_index < v->t->virt->nfields) {
                printf("Field %d: hashed_name=%d\n", field_index, v->t->virt->fields[field_index].hashed_name);
            }
        }
        /* Check the actual hl_vfields content */
        void **fields = hl_vfields(v);
        printf("hl_vfields(v)[%d] = %p\n", field_index, fields[field_index]);
    }
    fflush(stdout);
}

/* Runtime helper for object comparison using compareFun 
 * This is called at runtime when the type has a compareFun.
 * The compareFun might not be fully resolved at JIT compile time,
 * so we resolve it at runtime.
 */
int jit_obj_compare(vdynamic *a, vdynamic *b) {
    if (a == b) return 0;
    if (a == NULL) return -1;
    if (b == NULL) return 1;
    
    hl_runtime_obj *rt = hl_get_obj_rt(a->t);
    if (rt && rt->compareFun) {
        return rt->compareFun(a, b);
    }
    /* No compareFun - compare pointers */
    return a > b ? 1 : -1;
}

/* Debug helper - can be called from JIT code to detect infinite loops */
static int jit_loop_count = 0;
void jit_debug_loop_check(void) {
    jit_loop_count++;
    if ((jit_loop_count % 100000) == 0) {
        printf("JIT LOOP CHECK: %d iterations\n", jit_loop_count);
        fflush(stdout);
    }
    if (jit_loop_count > 1000000) {
        printf("JIT LOOP: Too many iterations (%d)! Infinite loop detected. Exiting...\n", jit_loop_count);
        fflush(stdout);
        exit(1);
    }
}

/* Runtime function call counter - for debugging */
static volatile int g_jit_call_count = 0;
static volatile int g_jit_last_findex = -1;
void jit_trace_function_entry(int findex) {
    g_jit_call_count++;
    g_jit_last_findex = findex;
    /* Print every call for now to debug */
    printf("JIT CALL[%d]: findex=%d\n", g_jit_call_count, findex);
    fflush(stdout);
}

/* Runtime validation for native calls - called before each native function call */
static volatile int g_native_call_count = 0;
void jit_validate_native_call(void *func_ptr, int nargs, void *arg0, void *arg1) {
    g_native_call_count++;
    /* Only print periodically to avoid overwhelming output */
    if (g_native_call_count % 1000 == 0 || g_native_call_count < 20) {
        printf("NATIVE[%d]: func=%p nargs=%d arg0=%p arg1=%p\n", 
               g_native_call_count, func_ptr, nargs, arg0, arg1);
        fflush(stdout);
    }
}

/* Debug helper - called when trying to call a closure with invalid function pointer */
void jit_debug_null_closure(void *closure_ptr) {
    vclosure *c = (vclosure *)closure_ptr;
    printf("=== INVALID CLOSURE FUNCTION POINTER ===\n");
    printf("Closure address: %p\n", closure_ptr);
    if (closure_ptr) {
        printf("Closure->t: %p\n", (void *)c->t);
        printf("Closure->fun: %p\n", c->fun);
        printf("Closure->hasValue: %d\n", c->hasValue);
        printf("Closure->value: %p\n", c->value);
        if (c->t) {
            printf("Closure->t->kind: %d\n", c->t->kind);
            if (c->t->fun) {
                printf("Closure->t->fun->nargs: %d\n", c->t->fun->nargs);
            }
        }
    }
    printf("==========================================\n");
    fflush(stdout);
}

/* Global JIT code range for validation */
static void *g_jit_code_base = NULL;
static size_t g_jit_code_size = 0;

/* Global flag to track if we've seen a bad closure */
static volatile int g_bad_closure_count = 0;

/* Check if a function pointer is valid - DOES NOT ALLOCATE to avoid triggering GC */
void jit_validate_closure(void *closure_ptr, void *fun_ptr) {
    (void)closure_ptr;
    (void)fun_ptr;
}

/* ============================================================================
 * ARM64 Register Definitions
 * ============================================================================ */

typedef enum {
    X0 = 0, X1, X2, X3, X4, X5, X6, X7,   /* Args / Return (caller-saved) */
    X8,                                    /* Indirect result (caller-saved) */
    X9, X10, X11, X12, X13, X14, X15,     /* Temporaries (caller-saved) */
    X16, X17,                              /* IP0, IP1 - intra-procedure scratch */
    X18,                                   /* Platform register (reserved) */
    X19, X20, X21, X22, X23, X24, X25, X26, X27, X28, /* Callee-saved */
    X29, X30,                              /* FP, LR */
    XZR = 31, SP = 31, WZR = 31,
    _REG_LAST = 0xFF
} CpuReg;

#define FP X29
#define LR X30

typedef enum {
    V0 = 0, V1, V2, V3, V4, V5, V6, V7,   /* Args / Return (caller-saved) */
    V8, V9, V10, V11, V12, V13, V14, V15, /* Callee-saved (lower 64 bits only) */
    V16, V17, V18, V19, V20, V21, V22, V23,
    V24, V25, V26, V27, V28, V29, V30, V31,
    _VREG_LAST = 0xFF
} FpuReg;

/* Condition Codes */
typedef enum {
    COND_EQ = 0x0, COND_NE = 0x1, COND_CS = 0x2, COND_CC = 0x3,
    COND_MI = 0x4, COND_PL = 0x5, COND_VS = 0x6, COND_VC = 0x7,
    COND_HI = 0x8, COND_LS = 0x9, COND_GE = 0xA, COND_LT = 0xB,
    COND_HS = 0x2, COND_LO = 0x3,  /* Unsigned >= and < */
    COND_GT = 0xC, COND_LE = 0xD, COND_AL = 0xE, COND_NV = 0xF
} ArmCond;

#define JAlways COND_AL
#define JEq     COND_EQ
#define JNeq    COND_NE
#define JSLt    COND_LT
#define JSGte   COND_GE
#define JSGt    COND_GT
#define JSLte   COND_LE
#define JULt    COND_CC
#define JUGte   COND_CS
#define JUGt    COND_HI
#define JULte   COND_LS

/* ============================================================================
 * Register Allocation Configuration
 * ============================================================================ */

/* Scratch registers we can freely allocate (caller-saved, not reserved) */
#define RCPU_SCRATCH_COUNT 11
static const int RCPU_SCRATCH_REGS[] = { X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10 };

/* Function call argument registers (ARM64 AAPCS) */
#define CALL_NREGS 8
static const CpuReg CALL_REGS[] = { X0, X1, X2, X3, X4, X5, X6, X7 };

/* FPU scratch registers */
#define RFPU_SCRATCH_COUNT 16
static const int RFPU_SCRATCH_REGS[] = { V0, V1, V2, V3, V4, V5, V6, V7, 
                                          V16, V17, V18, V19, V20, V21, V22, V23 };

/* Total register counts for preg array */
#define RCPU_COUNT 31  /* X0-X30 */
#define RFPU_COUNT 32  /* V0-V31 */
#define REG_COUNT  (RCPU_COUNT + RFPU_COUNT)

/* Map FPU register to preg index */
#define VREG(i) ((i) + RCPU_COUNT)
#define PVREG(i) REG_AT(VREG(i))
#define REG_IS_FPU(i) ((i) >= RCPU_COUNT)

/* ============================================================================
 * Register Structures
 * ============================================================================ */

typedef struct jlist jlist;
struct jlist {
    int pos;
    int target;
    jlist *next;
};

typedef struct vreg vreg;

typedef enum {
    RUNUSED = 0,
    RCPU,
    RFPU,
    RSTACK,
    RCONST,
    RADDR,
    RMEM
} preg_kind;

typedef struct {
    preg_kind kind;
    int id;
    int lock;
    vreg *holds;
} preg;

struct vreg {
    int stackPos;
    int size;
    hl_type *t;
    preg *current;
    preg stack;
};

/* ============================================================================
 * JIT Context Structure
 * ============================================================================ */

struct _jit_ctx {
    union {
        unsigned char *b;
        unsigned int *w;
        unsigned long long *w64;
        int *i;
        double *d;
    } buf;
    vreg *vregs;
    preg pregs[REG_COUNT];
    vreg *savedRegs[REG_COUNT];
    int savedLocks[REG_COUNT];
    int *opsPos;
    int maxRegs;
    int maxOps;
    int bufSize;
    int totalRegsSize;
    int functionPos;
    int allocOffset;
    int currentPos;
    int nativeArgsCount;
    unsigned char *startBuf;
    hl_module *m;
    hl_function *f;
    jlist *jumps;
    jlist *calls;
    jlist *switchs;
    hl_alloc falloc;
    hl_alloc galloc;
    vclosure *closure_list;
    hl_debug_infos *debug;
    int c2hl;
    int hl2c;
    int longjump;
    void *static_functions[8];
    bool static_function_offset;
};

/* ============================================================================
 * Macros and Helpers
 * ============================================================================ */

/* Maximum bytes for a single opcode sequence */
#define MAX_OP_SIZE 256

#define BUF_POS() ((int)(ctx->buf.b - ctx->startBuf))

/* Ensure buffer has enough space */
static void jit_buf(jit_ctx *ctx) {
    int curpos = ctx->startBuf ? BUF_POS() : 0;
    if (ctx->startBuf == NULL || curpos > ctx->bufSize - MAX_OP_SIZE) {
        int nsize = ctx->bufSize * 4 / 3;
        unsigned char *nbuf;
        
        if (nsize == 0) {
            /* Initial allocation based on code size estimate */
            nsize = 64 * 1024; /* Start with 64KB */
        }
        if (nsize < ctx->bufSize + MAX_OP_SIZE * 4)
            nsize = ctx->bufSize + MAX_OP_SIZE * 4;
        
        nbuf = (unsigned char *)malloc(nsize);
        if (nbuf == NULL) {
            printf("ARM64 JIT: Failed to allocate %d bytes\n", nsize);
            return;
        }
        
        if (ctx->startBuf) {
            memcpy(nbuf, ctx->startBuf, curpos);
            free(ctx->startBuf);
        }
        ctx->startBuf = nbuf;
        ctx->buf.b = nbuf + curpos;
        ctx->bufSize = nsize;
    }
}

#define EMIT(inst) do { jit_buf(ctx); *ctx->buf.w++ = (unsigned int)(inst); } while(0)

#define REG_AT(i) (&ctx->pregs[i])
#ifdef JIT_DEBUG
#define R(id) (({ \
    if ((id) < 0 || (id) > ctx->f->nregs) \
        printf("R(%d) out of bounds (nregs=%d)\n", (id), ctx->f->nregs); \
    &ctx->vregs[id]; \
}))
#else
#define R(id) (&ctx->vregs[id])
#endif

#define IS_FLOAT(r) ((r)->t->kind == HF64 || (r)->t->kind == HF32)

#define RLOCK(r)   do { if ((r)->lock < ctx->currentPos) (r)->lock = ctx->currentPos; } while(0)
#define RUNLOCK(r) do { if ((r)->lock == ctx->currentPos) (r)->lock = 0; } while(0)

#define ASSERT(cond) do { if (!(cond)) { printf("JIT ARM64 ASSERT failed at line %d\n", __LINE__); hl_debug_break(); exit(-1); } } while(0)

#define jit_exit() do { hl_debug_break(); exit(-1); } while(0)
#define jit_error(msg) do { printf("JIT ARM64 ERROR: %s (line %d)\n", msg, __LINE__); jit_exit(); } while(0)

static preg _unused = { RUNUSED, 0, 0, NULL };
#define UNUSED (&_unused)

#ifdef JIT_DEBUG
static const char *PREG_NAMES[] = { "RUNUSED", "RCPU", "RFPU", "RSTACK", "RCONST", "RADDR", "RMEM" };
#endif

/* ============================================================================
 * ARM64 Instruction Encoding Macros
 * ============================================================================ */

/* MOV immediate */
#define ARM64_MOVZ(sf, rd, imm16, shift) \
    EMIT(0xD2800000 | ((sf) << 31) | (((shift)/16) << 21) | (((imm16) & 0xFFFF) << 5) | ((rd) & 0x1F))
#define ARM64_MOVZ_X(rd, imm16) ARM64_MOVZ(1, rd, imm16, 0)
#define ARM64_MOVZ_W(rd, imm16) ARM64_MOVZ(0, rd, imm16, 0)

#define ARM64_MOVK(sf, rd, imm16, shift) \
    EMIT(0xF2800000 | ((sf) << 31) | (((shift)/16) << 21) | (((imm16) & 0xFFFF) << 5) | ((rd) & 0x1F))
#define ARM64_MOVK_X(rd, imm16, shift) ARM64_MOVK(1, rd, imm16, shift)

#define ARM64_MOVN(sf, rd, imm16, shift) \
    EMIT(0x92800000 | ((sf) << 31) | (((shift)/16) << 21) | (((imm16) & 0xFFFF) << 5) | ((rd) & 0x1F))
#define ARM64_MOVN_X(rd, imm16) ARM64_MOVN(1, rd, imm16, 0)

/* ADD/SUB immediate */
#define ARM64_ADD_IMM(sf, rd, rn, imm12) \
    EMIT(0x11000000 | ((sf) << 31) | (((imm12) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_ADD_IMM_X(rd, rn, imm12) ARM64_ADD_IMM(1, rd, rn, imm12)
#define ARM64_ADD_IMM_W(rd, rn, imm12) ARM64_ADD_IMM(0, rd, rn, imm12)

#define ARM64_SUB_IMM(sf, rd, rn, imm12) \
    EMIT(0x51000000 | ((sf) << 31) | (((imm12) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_SUB_IMM_X(rd, rn, imm12) ARM64_SUB_IMM(1, rd, rn, imm12)
#define ARM64_SUB_IMM_W(rd, rn, imm12) ARM64_SUB_IMM(0, rd, rn, imm12)

/* MOV register (via ORR with XZR) */
#define ARM64_MOV_REG(sf, rd, rm) \
    EMIT(0xAA0003E0 | ((sf) << 31) | (((rm) & 0x1F) << 16) | ((rd) & 0x1F))
#define ARM64_MOV_X(rd, rm) ARM64_MOV_REG(1, rd, rm)
#define ARM64_MOV_W(rd, rm) ARM64_MOV_REG(0, rd, rm)

/* ADD/SUB register (shifted) - NOTE: Rd=31 and Rn=31 are XZR, NOT SP! */
#define ARM64_ADD_REG(sf, rd, rn, rm) \
    EMIT(0x0B000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_ADD_X(rd, rn, rm) ARM64_ADD_REG(1, rd, rn, rm)
#define ARM64_ADD_W(rd, rn, rm) ARM64_ADD_REG(0, rd, rn, rm)

#define ARM64_SUB_REG(sf, rd, rn, rm) \
    EMIT(0x4B000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_SUB_X(rd, rn, rm) ARM64_SUB_REG(1, rd, rn, rm)
#define ARM64_SUB_W(rd, rn, rm) ARM64_SUB_REG(0, rd, rn, rm)

/* ADD/SUB extended register - REQUIRED when Rd or Rn is SP (reg 31)!
 * The shifted register variant treats reg 31 as XZR, not SP.
 * Extended register variant: option=011 (UXTX), imm3=000 (no shift)
 * ADD (ext): sf 00 01011 001 Rm 011 000 Rn Rd
 * SUB (ext): sf 10 01011 001 Rm 011 000 Rn Rd
 */
#define ARM64_ADD_EXT_X(rd, rn, rm) \
    EMIT(0x8B206000 | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_SUB_EXT_X(rd, rn, rm) \
    EMIT(0xCB206000 | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))

/* CMP (SUBS with discarded result) */
#define ARM64_SUBS_REG(sf, rd, rn, rm) \
    EMIT(0x6B000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_CMP_X(rn, rm) ARM64_SUBS_REG(1, XZR, rn, rm)
#define ARM64_CMP_W(rn, rm) ARM64_SUBS_REG(0, WZR, rn, rm)

#define ARM64_SUBS_IMM(sf, rd, rn, imm12) \
    EMIT(0x71000000 | ((sf) << 31) | (((imm12) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_CMP_IMM_X(rn, imm12) ARM64_SUBS_IMM(1, XZR, rn, imm12)
#define ARM64_CMP_IMM_W(rn, imm12) ARM64_SUBS_IMM(0, WZR, rn, imm12)

/* MUL/DIV */
#define ARM64_MUL(sf, rd, rn, rm) \
    EMIT(0x1B007C00 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_MUL_X(rd, rn, rm) ARM64_MUL(1, rd, rn, rm)
#define ARM64_MUL_W(rd, rn, rm) ARM64_MUL(0, rd, rn, rm)

#define ARM64_SDIV(sf, rd, rn, rm) \
    EMIT(0x1AC00C00 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_SDIV_X(rd, rn, rm) ARM64_SDIV(1, rd, rn, rm)
#define ARM64_SDIV_W(rd, rn, rm) ARM64_SDIV(0, rd, rn, rm)

#define ARM64_UDIV(sf, rd, rn, rm) \
    EMIT(0x1AC00800 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_UDIV_X(rd, rn, rm) ARM64_UDIV(1, rd, rn, rm)
#define ARM64_UDIV_W(rd, rn, rm) ARM64_UDIV(0, rd, rn, rm)

/* Logic */
#define ARM64_AND_REG(sf, rd, rn, rm) \
    EMIT(0x0A000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_AND_X(rd, rn, rm) ARM64_AND_REG(1, rd, rn, rm)
#define ARM64_AND_W(rd, rn, rm) ARM64_AND_REG(0, rd, rn, rm)

#define ARM64_ORR_REG(sf, rd, rn, rm) \
    EMIT(0x2A000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_ORR_X(rd, rn, rm) ARM64_ORR_REG(1, rd, rn, rm)
#define ARM64_ORR_W(rd, rn, rm) ARM64_ORR_REG(0, rd, rn, rm)

#define ARM64_EOR_REG(sf, rd, rn, rm) \
    EMIT(0x4A000000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_EOR_X(rd, rn, rm) ARM64_EOR_REG(1, rd, rn, rm)
#define ARM64_EOR_W(rd, rn, rm) ARM64_EOR_REG(0, rd, rn, rm)

#define ARM64_MVN(sf, rd, rm) \
    EMIT(0x2A2003E0 | ((sf) << 31) | (((rm) & 0x1F) << 16) | ((rd) & 0x1F))
#define ARM64_MVN_X(rd, rm) ARM64_MVN(1, rd, rm)

/* Shifts */
#define ARM64_LSL_REG(sf, rd, rn, rm) \
    EMIT(0x1AC02000 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_LSL_X(rd, rn, rm) ARM64_LSL_REG(1, rd, rn, rm)
#define ARM64_LSL_W(rd, rn, rm) ARM64_LSL_REG(0, rd, rn, rm)

#define ARM64_LSR_REG(sf, rd, rn, rm) \
    EMIT(0x1AC02400 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_LSR_X(rd, rn, rm) ARM64_LSR_REG(1, rd, rn, rm)
#define ARM64_LSR_W(rd, rn, rm) ARM64_LSR_REG(0, rd, rn, rm)

#define ARM64_ASR_REG(sf, rd, rn, rm) \
    EMIT(0x1AC02800 | ((sf) << 31) | (((rm) & 0x1F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_ASR_X(rd, rn, rm) ARM64_ASR_REG(1, rd, rn, rm)
#define ARM64_ASR_W(rd, rn, rm) ARM64_ASR_REG(0, rd, rn, rm)

/* Shift by immediate - UBFM encoding */
/* LSL (immediate) is alias for UBFM with immr = -shift mod 64, imms = 63 - shift */
#define ARM64_LSL_IMM_X(rd, rn, shift) \
    EMIT(0xD3400000 | (((64 - (shift)) & 0x3F) << 16) | (((63 - (shift)) & 0x3F) << 10) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_LSR_IMM_X(rd, rn, shift) \
    EMIT(0xD340FC00 | (((shift) & 0x3F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))
#define ARM64_ASR_IMM_X(rd, rn, shift) \
    EMIT(0x9340FC00 | (((shift) & 0x3F) << 16) | (((rn) & 0x1F) << 5) | ((rd) & 0x1F))

/* Load/Store - unsigned offset */
#define ARM64_LDR_X(rt, rn, imm) \
    EMIT(0xF9400000 | ((((imm) >> 3) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_LDR_W(rt, rn, imm) \
    EMIT(0xB9400000 | ((((imm) >> 2) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))

/* Byte load/store (for bools) */
#define ARM64_LDRB(rt, rn, imm) \
    EMIT(0x39400000 | (((imm) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_STRB(rt, rn, imm) \
    EMIT(0x39000000 | (((imm) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))

#define ARM64_STR_X(rt, rn, imm) \
    EMIT(0xF9000000 | ((((imm) >> 3) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_STR_W(rt, rn, imm) \
    EMIT(0xB9000000 | ((((imm) >> 2) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))

/* Load/Store pair with pre/post index */
#define ARM64_STP_PRE_X(rt1, rt2, rn, imm) \
    EMIT(0xA9800000 | (((((imm) >> 3) & 0x7F) << 15)) | (((rt2) & 0x1F) << 10) | (((rn) & 0x1F) << 5) | ((rt1) & 0x1F))

#define ARM64_LDP_POST_X(rt1, rt2, rn, imm) \
    EMIT(0xA8C00000 | (((((imm) >> 3) & 0x7F) << 15)) | (((rt2) & 0x1F) << 10) | (((rn) & 0x1F) << 5) | ((rt1) & 0x1F))

/* Load/Store pair with signed offset (no index update) */
#define ARM64_STP_X(rt1, rt2, rn, imm) \
    EMIT(0xA9000000 | (((((imm) >> 3) & 0x7F) << 15)) | (((rt2) & 0x1F) << 10) | (((rn) & 0x1F) << 5) | ((rt1) & 0x1F))

#define ARM64_LDP_X(rt1, rt2, rn, imm) \
    EMIT(0xA9400000 | (((((imm) >> 3) & 0x7F) << 15)) | (((rt2) & 0x1F) << 10) | (((rn) & 0x1F) << 5) | ((rt1) & 0x1F))

/* FPU Load/Store */
#define ARM64_LDR_D(vt, rn, imm) \
    EMIT(0xFD400000 | ((((imm) >> 3) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))
#define ARM64_STR_D(vt, rn, imm) \
    EMIT(0xFD000000 | ((((imm) >> 3) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))

#define ARM64_LDR_S(vt, rn, imm) \
    EMIT(0xBD400000 | ((((imm) >> 2) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))
#define ARM64_STR_S(vt, rn, imm) \
    EMIT(0xBD000000 | ((((imm) >> 2) & 0xFFF) << 10) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))

/* Unscaled offset loads/stores (for negative offsets within -256 to 255) */
#define ARM64_STUR_X(rt, rn, imm9) \
    EMIT(0xF8000000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_LDUR_X(rt, rn, imm9) \
    EMIT(0xF8400000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_STUR_W(rt, rn, imm9) \
    EMIT(0xB8000000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_LDUR_W(rt, rn, imm9) \
    EMIT(0xB8400000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((rt) & 0x1F))
#define ARM64_STUR_D(vt, rn, imm9) \
    EMIT(0xFC000000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))
#define ARM64_LDUR_D(vt, rn, imm9) \
    EMIT(0xFC400000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))
#define ARM64_STUR_S(vt, rn, imm9) \
    EMIT(0xBC000000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))
#define ARM64_LDUR_S(vt, rn, imm9) \
    EMIT(0xBC400000 | ((((imm9) & 0x1FF) << 12)) | (((rn) & 0x1F) << 5) | ((vt) & 0x1F))

/* FPU Move */
#define ARM64_FMOV_D(vd, vn) \
    EMIT(0x1E604000 | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))
#define ARM64_FMOV_S(vd, vn) \
    EMIT(0x1E204000 | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))

/* FPU <-> General Purpose Register Move */
#define ARM64_FMOV_D_X(vd, xn) \
    EMIT(0x9E670000 | (((xn) & 0x1F) << 5) | ((vd) & 0x1F))  /* FMOV Dd, Xn */
#define ARM64_FMOV_X_D(xd, vn) \
    EMIT(0x9E660000 | (((vn) & 0x1F) << 5) | ((xd) & 0x1F))  /* FMOV Xd, Dn */
#define ARM64_FMOV_S_W(vd, wn) \
    EMIT(0x1E270000 | (((wn) & 0x1F) << 5) | ((vd) & 0x1F))  /* FMOV Sd, Wn */
#define ARM64_FMOV_W_S(wd, vn) \
    EMIT(0x1E260000 | (((vn) & 0x1F) << 5) | ((wd) & 0x1F))  /* FMOV Wd, Sn */

/* FPU Arithmetic */
#define ARM64_FADD_D(vd, vn, vm) \
    EMIT(0x1E602800 | (((vm) & 0x1F) << 16) | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))
#define ARM64_FSUB_D(vd, vn, vm) \
    EMIT(0x1E603800 | (((vm) & 0x1F) << 16) | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))
#define ARM64_FMUL_D(vd, vn, vm) \
    EMIT(0x1E600800 | (((vm) & 0x1F) << 16) | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))
#define ARM64_FDIV_D(vd, vn, vm) \
    EMIT(0x1E601800 | (((vm) & 0x1F) << 16) | (((vn) & 0x1F) << 5) | ((vd) & 0x1F))

/* Branch */
#define ARM64_B(offset) EMIT(0x14000000 | (((offset) >> 2) & 0x3FFFFFF))
#define ARM64_BL(offset) EMIT(0x94000000 | (((offset) >> 2) & 0x3FFFFFF))
#define ARM64_B_COND(cond, offset) EMIT(0x54000000 | ((((offset) >> 2) & 0x7FFFF) << 5) | ((cond) & 0xF))
#define ARM64_BR(rn) EMIT(0xD61F0000 | (((rn) & 0x1F) << 5))
#define ARM64_BLR(rn) EMIT(0xD63F0000 | (((rn) & 0x1F) << 5))
#define ARM64_RET() EMIT(0xD65F03C0)

/* Special */
#define ARM64_NOP() EMIT(0xD503201F)
#define ARM64_BRK(imm16) EMIT(0xD4200000 | (((imm16) & 0xFFFF) << 5))

/* ============================================================================
 * Register Allocator
 * ============================================================================ */

/* Get the preg for a vreg's stack slot */
static preg *fetch(vreg *v) {
    if (v->current) {
        /* Bidirectional check: ensure register still holds this vreg */
        preg *p = v->current;
        if (p->holds == v) {
            return p;
        }
        /* Binding is stale - clear it */
        v->current = NULL;
    }
    return &v->stack;
}

/* Disassociate a physical register from its virtual register */
static void scratch(preg *r) {
    if (r && r->holds) {
        r->holds->current = NULL;
        r->holds = NULL;
        r->lock = 0;
    }
}

/* Forward declarations */
static preg *alloc_cpu(jit_ctx *ctx, vreg *v, bool andLoad);
static void copy_to_stack(jit_ctx *ctx, preg *stack, preg *from, int size);

/* Allocate a physical register */
static preg *alloc_reg(jit_ctx *ctx, preg_kind k) {
    int i;
    
    switch (k) {
    case RCPU:
        {
            int off = ctx->allocOffset++;
            /* First pass: find a free register */
            for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
                int r = RCPU_SCRATCH_REGS[(i + off) % RCPU_SCRATCH_COUNT];
                preg *p = REG_AT(r);
                if (p->lock >= ctx->currentPos) continue;
                if (p->holds == NULL) {
                    RLOCK(p);
                    p->kind = RCPU;
                    p->id = r;
                    return p;
                }
            }
            /* Second pass: spill a register */
            for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
                int r = RCPU_SCRATCH_REGS[(i + off) % RCPU_SCRATCH_COUNT];
                preg *p = REG_AT(r);
                if (p->lock >= ctx->currentPos) continue;
                if (p->holds) {
                    /* Spill to stack */
#ifdef JIT_DEBUG
                    if (g_debug_findex == 255) {
                        printf("SPILL[f255]: X%d holds vreg with stackPos=%d, op=%d\n",
                               r, p->holds->stackPos, ctx->currentPos);
                    }
#endif
                    copy_to_stack(ctx, &p->holds->stack, p, p->holds->size);
                    RLOCK(p);
                    p->holds->current = NULL;
                    p->holds = NULL;
                    return p;
                }
            }
        }
        break;
        
    case RFPU:
        {
            int off = ctx->allocOffset++;
            /* First pass: find a free register */
            for (i = 0; i < RFPU_SCRATCH_COUNT; i++) {
                int r = RFPU_SCRATCH_REGS[(i + off) % RFPU_SCRATCH_COUNT];
                preg *p = REG_AT(VREG(r));
                if (p->lock >= ctx->currentPos) continue;
                if (p->holds == NULL) {
                    RLOCK(p);
                    p->kind = RFPU;
                    p->id = r;
                    return p;
                }
            }
            /* Second pass: spill a register */
            for (i = 0; i < RFPU_SCRATCH_COUNT; i++) {
                int r = RFPU_SCRATCH_REGS[(i + off) % RFPU_SCRATCH_COUNT];
                preg *p = REG_AT(VREG(r));
                if (p->lock >= ctx->currentPos) continue;
                if (p->holds) {
                    copy_to_stack(ctx, &p->holds->stack, p, p->holds->size);
                    RLOCK(p);
                    p->holds->current = NULL;
                    p->holds = NULL;
                    return p;
                }
            }
        }
        break;
        
    default:
        ASSERT(0);
    }
    
    printf("ARM64 JIT: Out of registers (currentPos=%d)\n", ctx->currentPos);
    for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
        preg *p = REG_AT(RCPU_SCRATCH_REGS[i]);
        printf("  CPU reg X%d: lock=%d, holds=%p\n", RCPU_SCRATCH_REGS[i], p->lock, (void*)p->holds);
    }
    jit_error("Out of registers");
    return NULL;
}

/* Forward declarations for functions defined later but needed here */
static void load_imm64(jit_ctx *ctx, CpuReg rd, int64_t value);
static void sub_large_imm(jit_ctx *ctx, CpuReg rd, CpuReg rn, int imm, CpuReg tmp_reg);
static void add_large_imm(jit_ctx *ctx, CpuReg rd, CpuReg rn, int imm, CpuReg tmp_reg);

/* Copy from physical register to stack */
static void copy_to_stack(jit_ctx *ctx, preg *stack, preg *from, int size) {
    ASSERT(stack->kind == RSTACK);
    int offset = stack->id; /* stack offset from FP */
    
#ifdef JIT_DEBUG
    extern int g_debug_findex;
    if (g_debug_findex == 255) {
        printf("copy_to_stack[f255]: offset=%d, from->kind=%d, from->id=%d, size=%d, op=%d\n",
               offset, from->kind, from->id, size, ctx->currentPos);
    }
#endif
    
    /* For negative offsets, use STUR (signed 9-bit offset) or compute address */
    if (offset < 0 && offset >= -256) {
        /* Use STUR with signed offset */
        if (from->kind == RCPU) {
            if (size == 8)
                EMIT(0xF8000000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (from->id & 0x1F)); /* STUR X */
            else if (size == 1)
                EMIT(0x38000000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (from->id & 0x1F)); /* STURB */
            else
                EMIT(0xB8000000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (from->id & 0x1F)); /* STUR W */
        } else if (from->kind == RFPU) {
            if (size == 8)
                EMIT(0xFC000000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (from->id & 0x1F));
            else
                EMIT(0xBC000000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (from->id & 0x1F));
        }
    } else if (offset < -256) {
        /* Large negative offset - compute address in temp register first.
         * 
         * CRITICAL FIX: sub_large_imm uses a scratch register to hold the
         * immediate value when imm > 4095. If from->id == scratch_reg, the
         * value to store gets clobbered before the STR! We must choose temps
         * that don't conflict with from->id.
         *
         * We need: addr_reg (holds computed address) and scratch_reg (for imm).
         * Neither can be from->id. addr_reg != scratch_reg.
         */
        int from_reg = (from->kind == RCPU) ? from->id : -1;
        
        /* Choose addr_reg: X19 unless from uses X19 */
        int addr_reg = (from_reg == X19) ? X20 : X19;
        
        /* Choose scratch_reg: must differ from both addr_reg and from_reg */
        int scratch_reg;
        if (from_reg != X9 && addr_reg != X9)
            scratch_reg = X9;
        else if (from_reg != X10 && addr_reg != X10)
            scratch_reg = X10;
        else
            scratch_reg = X8;
        
        /* Save both temp regs to stack (use STP pre-index for 16-byte alignment)
         * STP Xaddr, Xscratch, [SP, #-16]! 
         * Encoding: 0xA9BF0000 | (Rt2 << 10) | (Rn << 5) | Rt1  where Rn=SP(31), imm7=-16/8=-2=0x7E */
        {
            /* Use pre-index STP: STP rt1, rt2, [SP, #-16]! */
            unsigned int stp_enc = 0xA9BF0000 | ((scratch_reg & 0x1F) << 10) | (31 << 5) | (addr_reg & 0x1F);
            EMIT(stp_enc);
        }
        
        sub_large_imm(ctx, addr_reg, FP, -offset, scratch_reg);
        
        if (from->kind == RCPU) {
            if (size == 8)
                ARM64_STR_X(from->id, addr_reg, 0);
            else if (size == 1)
                ARM64_STRB(from->id, addr_reg, 0);
            else
                ARM64_STR_W(from->id, addr_reg, 0);
        } else if (from->kind == RFPU) {
            if (size == 8)
                ARM64_STR_D(from->id, addr_reg, 0);
            else
                ARM64_STR_S(from->id, addr_reg, 0);
        }
        
        /* Restore both temp regs: LDP Xaddr, Xscratch, [SP], #16 */
        {
            unsigned int ldp_enc = 0xA8C10000 | ((scratch_reg & 0x1F) << 10) | (31 << 5) | (addr_reg & 0x1F);
            EMIT(ldp_enc);
        }
    } else {
        /* Positive offset - use unsigned offset form */
        if (from->kind == RCPU) {
            if (size == 8)
                ARM64_STR_X(from->id, FP, offset);
            else if (size == 1)
                ARM64_STRB(from->id, FP, offset);
            else
                ARM64_STR_W(from->id, FP, offset);
        } else if (from->kind == RFPU) {
            if (size == 8)
                ARM64_STR_D(from->id, FP, offset);
            else
                ARM64_STR_S(from->id, FP, offset);
        }
    }
}

/* Copy from stack to physical register */
static void copy_from_stack(jit_ctx *ctx, preg *to, preg *stack, int size) {
    ASSERT(stack->kind == RSTACK);
    int offset = stack->id;
    
#ifdef JIT_DEBUG
    extern int g_debug_findex;
    if (g_debug_findex == 255) {
        printf("copy_from_stack[f255]: offset=%d, to->kind=%d, to->id=%d, size=%d, op=%d\n",
               offset, to->kind, to->id, size, ctx->currentPos);
    }
#endif
    
    /* For negative offsets, use LDUR (signed 9-bit offset) or compute address */
    if (offset < 0 && offset >= -256) {
        /* Use LDUR with signed offset */
        if (to->kind == RCPU) {
            if (size == 8)
                EMIT(0xF8400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (to->id & 0x1F)); /* LDUR X */
            else if (size == 1)
                EMIT(0x38400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (to->id & 0x1F)); /* LDURB */
            else
                EMIT(0xB8400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (to->id & 0x1F)); /* LDUR W */
        } else if (to->kind == RFPU) {
            if (size == 8)
                EMIT(0xFC400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (to->id & 0x1F));
            else
                EMIT(0xBC400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (to->id & 0x1F));
        }
    } else if (offset < -256) {
        /* Large negative offset - compute address in temp register first.
         * 
         * CRITICAL: We need addr_reg and scratch_reg that don't conflict with to->id.
         * Also addr_reg != to->id (restore would overwrite loaded value).
         * Also scratch_reg from sub_large_imm must not conflict with either.
         */
        int to_reg = (to->kind == RCPU) ? to->id : -1;
        int addr_reg = (to_reg == X19) ? X20 : X19;
        
        /* Choose scratch_reg: must differ from both addr_reg and to_reg */
        int scratch_reg;
        if (to_reg != X9 && addr_reg != X9)
            scratch_reg = X9;
        else if (to_reg != X10 && addr_reg != X10)
            scratch_reg = X10;
        else
            scratch_reg = X8;
        
        /* Save both temp regs: STP addr_reg, scratch_reg, [SP, #-16]! */
        {
            unsigned int stp_enc = 0xA9BF0000 | ((scratch_reg & 0x1F) << 10) | (31 << 5) | (addr_reg & 0x1F);
            EMIT(stp_enc);
        }
        
        sub_large_imm(ctx, addr_reg, FP, -offset, scratch_reg);
        
        if (to->kind == RCPU) {
            if (size == 8)
                ARM64_LDR_X(to->id, addr_reg, 0);
            else if (size == 1)
                ARM64_LDRB(to->id, addr_reg, 0);
            else
                ARM64_LDR_W(to->id, addr_reg, 0);
        } else if (to->kind == RFPU) {
            if (size == 8)
                ARM64_LDR_D(to->id, addr_reg, 0);
            else
                ARM64_LDR_S(to->id, addr_reg, 0);
        }
        
        /* Restore both temp regs: LDP addr_reg, scratch_reg, [SP], #16 */
        {
            unsigned int ldp_enc = 0xA8C10000 | ((scratch_reg & 0x1F) << 10) | (31 << 5) | (addr_reg & 0x1F);
            EMIT(ldp_enc);
        }
    } else {
        /* Positive offset - use unsigned offset form */
        if (to->kind == RCPU) {
            if (size == 8)
                ARM64_LDR_X(to->id, FP, offset);
            else if (size == 1)
                ARM64_LDRB(to->id, FP, offset);
            else
                ARM64_LDR_W(to->id, FP, offset);
        } else if (to->kind == RFPU) {
            if (size == 8)
                ARM64_LDR_D(to->id, FP, offset);
            else
                ARM64_LDR_S(to->id, FP, offset);
        }
    }
}

/* Copy between two physical registers */
static void copy_reg(jit_ctx *ctx, preg *to, preg *from, int size) {
    if (to == from) return;
    
    if (to->kind == RCPU && from->kind == RCPU) {
        if (size == 8)
            ARM64_MOV_X(to->id, from->id);
        else
            ARM64_MOV_W(to->id, from->id);
    } else if (to->kind == RFPU && from->kind == RFPU) {
        if (size == 8)
            ARM64_FMOV_D(to->id, from->id);
        else
            ARM64_FMOV_S(to->id, from->id);
    } else if (to->kind == RCPU && from->kind == RFPU) {
        /* FPU to CPU: FMOV Xd, Dn (copy bits without conversion) */
        if (size == 8)
            EMIT(0x9E660000 | (to->id & 0x1F) | ((from->id & 0x1F) << 5)); /* FMOV Xd, Dn */
        else
            EMIT(0x1E260000 | (to->id & 0x1F) | ((from->id & 0x1F) << 5)); /* FMOV Wd, Sn */
    } else if (to->kind == RFPU && from->kind == RCPU) {
        /* CPU to FPU: FMOV Dd, Xn (copy bits without conversion) */
        if (size == 8)
            EMIT(0x9E670000 | (to->id & 0x1F) | ((from->id & 0x1F) << 5)); /* FMOV Dd, Xn */
        else
            EMIT(0x1E270000 | (to->id & 0x1F) | ((from->id & 0x1F) << 5)); /* FMOV Sd, Wn */
    } else {
        jit_error("Cannot copy between these register kinds");
    }
}

/* Generic copy operation */
static preg *copy(jit_ctx *ctx, preg *to, preg *from, int size) {
    if (to == from || size == 0)
        return to;
        
    switch (to->kind) {
    case RCPU:
    case RFPU:
        switch (from->kind) {
        case RCPU:
        case RFPU:
            copy_reg(ctx, to, from, size);
            return to;
        case RSTACK:
            copy_from_stack(ctx, to, from, size);
            return to;
        default:
            break;
        }
        break;
    case RSTACK:
        switch (from->kind) {
        case RCPU:
            copy_to_stack(ctx, to, from, size);
            return from;  /* Return source register, not stack */
        case RFPU:
            copy_to_stack(ctx, to, from, size);
            return from;  /* Return source register, not stack */
        case RSTACK:
            {
                /* Stack-to-stack copy: use a temporary register */
                /* We don't know the vreg type, but can infer from size */
                preg *tmp;
                if (size == 4 || size == 8) {
                    /* Could be float or int - use CPU register, works for both */
                    tmp = alloc_reg(ctx, RCPU);
                    copy_from_stack(ctx, tmp, from, size);
                    copy_to_stack(ctx, to, tmp, size);
                } else {
                    /* Small values - always CPU */
                    tmp = alloc_reg(ctx, RCPU);
                    copy_from_stack(ctx, tmp, from, size);
                    copy_to_stack(ctx, to, tmp, size);
                }
                return tmp;
            }
        default:
            break;
        }
        break;
    default:
        break;
    }
    
#ifdef JIT_DEBUG
    printf("copy(%s,%s) not implemented\n", PREG_NAMES[to->kind], PREG_NAMES[from->kind]);
#endif
    ASSERT(0);
    return NULL;
}

/* Load a virtual register into a physical register */
static void load(jit_ctx *ctx, preg *r, vreg *v) {
    preg *from = fetch(v);
    if (from == r || v->size == 0) return;
    
#ifdef JIT_DEBUG
    printf("load: r->id=%d, v->size=%d, from->kind=%d, from->id=%d, v->stack.id=%d, v->stackPos=%d\n",
           r->id, v->size, from->kind, from->id, v->stack.id, v->stackPos);
    if (from->kind == RUNUSED) {
        printf("load: trying to load from RUNUSED vreg, current=%p, stack.kind=%d\n", 
               (void*)v->current, v->stack.kind);
    }
#endif
    
    if (r->holds) r->holds->current = NULL;
    if (v->current) {
        v->current->holds = NULL;
    }
    r->holds = v;
    v->current = r;
    copy(ctx, r, from, v->size);
}

/* Allocate a CPU register for a virtual register, optionally loading its value */
static preg *alloc_cpu(jit_ctx *ctx, vreg *v, bool andLoad) {
    preg *p = v->current;
    if (p) {
        /* Verify the binding is still valid (bidirectional check) */
        if (p->kind == RCPU && p->holds == v) {
            RLOCK(p);
            return p;
        }
        /* Binding is stale - clear it */
        v->current = NULL;
    }
    
    p = alloc_reg(ctx, RCPU);
    if (andLoad) {
        load(ctx, p, v);
        RLOCK(p);  /* Lock the register to prevent spilling before use */
    }
    /* NOTE: When andLoad=false, the caller is about to store a new value to this vreg.
     * We should NOT bind the register to the vreg here because:
     * 1. The value in the register is not valid yet (caller will compute it)
     * 2. The caller's store() call with bind=true will set up proper binding if needed
     * If we bind here, and a later operation uses this register, vreg will
     * think it still has a valid copy but the register was reused.
     */
    return p;
}

/* Allocate an FPU register for a virtual register */
static preg *alloc_fpu(jit_ctx *ctx, vreg *v, bool andLoad) {
    preg *p = v->current;
    if (p) {
        /* Verify the binding is still valid (bidirectional check) */
        if (p->kind == RFPU && p->holds == v) {
            RLOCK(p);
            return p;
        }
        /* Binding is stale - clear it */
        v->current = NULL;
    }
    
    p = alloc_reg(ctx, RFPU);
    if (andLoad) {
        load(ctx, p, v);
        RLOCK(p);  /* Lock the register to prevent spilling before use */
    }
    /* NOTE: When andLoad=false, we don't bind - same as alloc_cpu */
    return p;
}

/* Store a physical register value into a virtual register */
static void store(jit_ctx *ctx, vreg *r, preg *v, bool bind) {
    if (r->current && r->current != v) {
        r->current->holds = NULL;
        r->current = NULL;
    }
    
    /* Handle type mismatch: if storing a float but value is in CPU reg, move to FPU first */
    if (IS_FLOAT(r) && v->kind == RCPU) {
        /* Allocate an FPU register and move the value */
        preg *fpu_reg = alloc_reg(ctx, RFPU);
        if (r->t->kind == HF64) {
            ARM64_FMOV_D_X(fpu_reg->id, v->id);  /* Move from CPU to FPU (64-bit) */
        } else {
            ARM64_FMOV_S_W(fpu_reg->id, v->id);  /* Move from CPU to FPU (32-bit) */
        }
        v = fpu_reg;
    }
    /* Handle opposite mismatch: if storing an int but value is in FPU reg, move to CPU first */
    else if (!IS_FLOAT(r) && v->kind == RFPU) {
        preg *cpu_reg = alloc_reg(ctx, RCPU);
        ARM64_FMOV_X_D(cpu_reg->id, v->id);  /* Move from FPU to CPU */
        v = cpu_reg;
    }
    
    preg *orig_v = v;
    v = copy(ctx, &r->stack, v, r->size);
    if (IS_FLOAT(r) != (v->kind == RFPU)) {
        printf("store mismatch: IS_FLOAT=%d, r->t->kind=%d, v->kind=%d, orig_v->kind=%d, currentPos=%d\n", 
               IS_FLOAT(r), r->t->kind, v->kind, orig_v->kind, ctx->currentPos);
        ASSERT(0);
    }
    if (bind && r->current != v && (v->kind == RCPU || v->kind == RFPU)) {
        /* Clear old binding before creating new one */
        if (v->holds && v->holds != r) {
            v->holds->current = NULL;
        }
        scratch(v);
        r->current = v;
        v->holds = r;
    }
}

/* Store result from return registers (X0 or D0) */
static void store_result(jit_ctx *ctx, vreg *r) {
    if (IS_FLOAT(r)) {
        /* Float return is in D0 */
        preg *d0 = REG_AT(VREG(0));  /* D0 = first FPU register */
        d0->kind = RFPU;
        d0->id = 0;
        store(ctx, r, d0, true);
    } else {
        /* Integer return is in X0 */
        preg *x0 = REG_AT(X0);
        store(ctx, r, x0, true);
    }
}

/* Discard all scratch registers (before a call) */
static void discard_regs(jit_ctx *ctx, bool native_call) {
    int i;
    (void)native_call;
    
    for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
        preg *r = REG_AT(RCPU_SCRATCH_REGS[i]);
        if (r->holds) {
            r->holds->current = NULL;
            r->holds = NULL;
        }
    }
    for (i = 0; i < RFPU_SCRATCH_COUNT; i++) {
        preg *r = REG_AT(VREG(RFPU_SCRATCH_REGS[i]));
        if (r->holds) {
            r->holds->current = NULL;
            r->holds = NULL;
        }
    }
}

/* Save register bindings (for branching paths like OCallClosure) */
static void save_regs(jit_ctx *ctx) {
    int i;
    for (i = 0; i < REG_COUNT; i++) {
        ctx->savedRegs[i] = ctx->pregs[i].holds;
        ctx->savedLocks[i] = ctx->pregs[i].lock;
    }
}

static void restore_regs(jit_ctx *ctx) {
    int i;
    /* Clear all vreg->current bindings */
    for (i = 0; i < ctx->maxRegs; i++) {
        ctx->vregs[i].current = NULL;
    }
    /* Restore preg bindings */
    for (i = 0; i < REG_COUNT; i++) {
        vreg *r = ctx->savedRegs[i];
        preg *p = &ctx->pregs[i];
        p->holds = r;
        p->lock = ctx->savedLocks[i];
        if (r) r->current = p;
    }
}

/* Validate register binding consistency - for debugging */
static void validate_bindings(jit_ctx *ctx, int opCount) {
    int i;
    /* Check all CPU registers */
    for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
        preg *p = REG_AT(RCPU_SCRATCH_REGS[i]);
        if (p->holds) {
            vreg *v = p->holds;
            if (v->current != p) {
                printf("BINDING ERROR at op[%d]: X%d holds vreg (stackPos=%d) but vreg->current=%p != preg=%p\n",
                       opCount, RCPU_SCRATCH_REGS[i], v->stackPos, (void*)v->current, (void*)p);
                fflush(stdout);
            }
        }
    }
    /* Check all FPU registers */
    for (i = 0; i < RFPU_SCRATCH_COUNT; i++) {
        preg *p = REG_AT(VREG(RFPU_SCRATCH_REGS[i]));
        if (p->holds) {
            vreg *v = p->holds;
            if (v->current != p) {
                printf("BINDING ERROR at op[%d]: V%d holds vreg (stackPos=%d) but vreg->current=%p != preg=%p\n",
                       opCount, RFPU_SCRATCH_REGS[i], v->stackPos, (void*)v->current, (void*)p);
                fflush(stdout);
            }
        }
    }
}

/* ============================================================================
 * Load Immediate Helpers
 * ============================================================================ */

static void load_imm64(jit_ctx *ctx, CpuReg rd, int64_t value) {
    /* Invalidate any vreg binding to this register since we're overwriting it */
    preg *p = &ctx->pregs[rd];
    if (p->holds) {
        p->holds->current = NULL;
        p->holds = NULL;
    }
    
    /* Debug removed for production */
    if (value == 0) {
        ARM64_MOV_X(rd, XZR);
    } else if (value > 0 && value < 0x10000) {
        ARM64_MOVZ_X(rd, (unsigned short)value);
    } else if (value < 0 && value >= -0x10000) {
        ARM64_MOVN_X(rd, (unsigned short)(~value));
    } else {
        ARM64_MOVZ_X(rd, (unsigned short)(value & 0xFFFF));
        if ((value >> 16) & 0xFFFF)
            ARM64_MOVK_X(rd, (unsigned short)((value >> 16) & 0xFFFF), 16);
        if ((value >> 32) & 0xFFFF)
            ARM64_MOVK_X(rd, (unsigned short)((value >> 32) & 0xFFFF), 32);
        if ((value >> 48) & 0xFFFF)
            ARM64_MOVK_X(rd, (unsigned short)((value >> 48) & 0xFFFF), 48);
    }
}

/* Helper to compute rd = rn - imm where imm may be > 4095 (the SUB_IMM limit).
 * Uses tmp_reg as a scratch register when needed.
 * tmp_reg MUST be different from rd and rn. */
static void sub_large_imm(jit_ctx *ctx, CpuReg rd, CpuReg rn, int imm, CpuReg tmp_reg) {
    if (imm <= 4095) {
        ARM64_SUB_IMM_X(rd, rn, imm);
    } else {
        /* Load large immediate into temp register and use register subtraction */
        load_imm64(ctx, tmp_reg, imm);
        ARM64_SUB_X(rd, rn, tmp_reg);
    }
}

/* Helper to compute rd = rn + imm where imm may be > 4095 (the ADD_IMM limit).
 * Uses tmp_reg as a scratch register when needed.
 * tmp_reg MUST be different from rd and rn. */
static void add_large_imm(jit_ctx *ctx, CpuReg rd, CpuReg rn, int imm, CpuReg tmp_reg) {
    if (imm <= 4095) {
        ARM64_ADD_IMM_X(rd, rn, imm);
    } else {
        /* Load large immediate into temp register and use register addition */
        load_imm64(ctx, tmp_reg, imm);
        ARM64_ADD_X(rd, rn, tmp_reg);
    }
}

/* ============================================================================
 * Function Prologue/Epilogue
 * ============================================================================ */

/* Debug helper for tracing function entries */
static int jit_func_enter_count = 0;
void jit_debug_func_enter(void) {
    jit_func_enter_count++;
    if (jit_func_enter_count <= 100 || (jit_func_enter_count % 10000) == 0) {
        printf("JIT FUNC ENTER: count=%d\n", jit_func_enter_count);
        fflush(stdout);
    }
    if (jit_func_enter_count > 2000000) {
        printf("JIT FUNC ENTER: Too many function calls! Exiting...\n");
        fflush(stdout);
        exit(1);
    }
}

/* Debug helper to print after call returns */
void jit_debug_call_return(void *ret_val, int findex) {
    printf("JIT CALL RETURNED: findex=%d, X0=%p\n", findex, ret_val);
    fflush(stdout);
}

/* Debug helper called at runtime before todyn */
void jit_debug_todyn(int op_num) {
    printf("TODYN: op=%d\n", op_num);
    fflush(stdout);
}

/* Debug helper called after alloc */
void jit_debug_todyn_after_alloc(void *result) {
    printf("TODYN_ALLOC: result=%p\n", result);
    fflush(stdout);
}

/* Debug helper called after store to dyn */
void jit_debug_todyn_after_store(void) {
    printf("TODYN_STORE: done\n");
    fflush(stdout);
}

/* Debug helper called when OToDyn completes */
void jit_debug_todyn_complete(void) {
    printf("TODYN_COMPLETE\n");
    fflush(stdout);
}

/* Debug helper for ONew */
void jit_debug_onew(int op_num, int kind) {
    printf("ONEW: op=%d kind=%d\n", op_num, kind);
    fflush(stdout);
}

/* Debug helper for ONew after alloc */
void jit_debug_onew_after(void *result) {
    printf("ONEW_AFTER: result=%p\n", result);
    fflush(stdout);
}

/* Debug helper for ONew after store */
void jit_debug_onew_stored(void) {
    printf("ONEW_STORED\n");
    fflush(stdout);
}

/* Debug helper for allocation */
void jit_debug_alloc(void *type_ptr, const char *kind) {
    printf("JIT ALLOC: type=%p kind=%s\n", type_ptr, kind);
    fflush(stdout);
    if (type_ptr == NULL || (intptr_t)type_ptr < 0x1000) {
        printf("  ERROR: Invalid type pointer!\n");
        fflush(stdout);
    }
}

/* Check type before virtual alloc - called from generated code */
void jit_check_virtual_type(void *type_ptr) {
    static int check_count = 0;
    check_count++;
    printf("CHECK %d: type=%p\n", check_count, type_ptr);
    fflush(stdout);
    hl_type *t = (hl_type*)type_ptr;
    if (t == NULL || (intptr_t)t < 0x1000) {
        printf("ERROR: Invalid type %p before hl_alloc_virtual\n", type_ptr);
        fflush(stdout);
    } else if (t->kind != HVIRTUAL) {
        printf("ERROR: Type %p is not virtual (kind=%d)\n", type_ptr, t->kind);
        fflush(stdout);
    }
}

/* Runtime trace for ops */
void jit_debug_trace_op(int findex, int opnum, int opcode) {
    static int counter = 0;
    counter++;
    /* Only print every 1000th op to reduce overhead but still see progress */
    if (counter % 1000 == 0) {
        printf("TRACE[%d] F%d @%d op=%d\n", counter, findex, opnum, opcode);
        fflush(stdout);
    }
}

/* Debug function called at runtime to check FP value before crash point */
void jit_debug_check_fp(void *fp_value, void *sp_value) {
    printf("RUNTIME CHECK: FP=%p SP=%p diff=%ld\n", fp_value, sp_value, (long)((char*)fp_value - (char*)sp_value));
    fflush(stdout);
}

/* Define JIT_TRACE_CALLS to enable runtime call tracing (very slow but helps debug) */
/* #define JIT_TRACE_CALLS */

static void op_enter(jit_ctx *ctx) {
    /* Save frame pointer, link register, and callee-saved registers we use */
    /* We use X19 in OCallClosure, X20 for temp, X21 in OCallMethod HVIRTUAL */
    ARM64_STP_PRE_X(FP, LR, SP, -48);  /* Save FP and LR, allocate 48 bytes */
    ARM64_STP_X(X19, X20, SP, 16);      /* Save X19 and X20 at SP+16 */
    ARM64_STP_X(X21, X22, SP, 32);      /* Save X21 and X22 at SP+32 (X22 for alignment) */
    /* MOV FP, SP - need to use ADD because ORR uses XZR for reg 31 */
    ARM64_ADD_IMM_X(FP, SP, 0);
    
#ifdef JIT_TRACE_CALLS
    /* Call trace function - saves all registers, calls tracer, restores */
    {
        /* Save X0 (used for passing findex) */
        ARM64_STP_PRE_X(X0, X1, SP, -16);
        /* Load findex into X0 */
        load_imm64(ctx, X0, ctx->f->findex);
        /* Call the trace function */
        scratch(REG_AT(X9));
        load_imm64(ctx, X9, (int64_t)(intptr_t)jit_trace_function_entry);
        ARM64_BLR(X9);
        /* Restore X0, X1 */
        ARM64_LDP_POST_X(X0, X1, SP, 16);
    }
#endif
    
    /* Allocate space for locals */
    int localSize = ctx->totalRegsSize;
    if (localSize > 0) {
        localSize = (localSize + 15) & ~15; /* 16-byte align */
        if (localSize <= 4095) {
            ARM64_SUB_IMM_X(SP, SP, localSize);
        } else {
            scratch(REG_AT(X9));
            load_imm64(ctx, X9, localSize);
            ARM64_SUB_EXT_X(SP, SP, X9);
        }
    }
}

static void op_ret_void(jit_ctx *ctx) {
    /* Restore stack, callee-saved registers, and return */
    /* MOV SP, FP - need to use ADD because ORR uses XZR for reg 31 */
    ARM64_ADD_IMM_X(SP, FP, 0);
    ARM64_LDP_X(X21, X22, SP, 32);      /* Restore X21 and X22 */
    ARM64_LDP_X(X19, X20, SP, 16);      /* Restore X19 and X20 */
    ARM64_LDP_POST_X(FP, LR, SP, 48);   /* Restore FP and LR, deallocate 48 bytes */
    ARM64_RET();
}

static void op_ret(jit_ctx *ctx, vreg *r) {
    /* Move return value to X0/V0 if needed */
    if (r && r->t->kind != HVOID) {
        if (IS_FLOAT(r)) {
            preg *pr = alloc_fpu(ctx, r, true);
            if (pr->id != V0) {
                if (r->t->kind == HF64)
                    ARM64_FMOV_D(V0, pr->id);
                else
                    ARM64_FMOV_S(V0, pr->id);
            }
        } else {
            preg *pr = alloc_cpu(ctx, r, true);
            if (pr->id != X0)
                ARM64_MOV_X(X0, pr->id);
        }
    }
    
    op_ret_void(ctx);
}

/* ============================================================================
 * Opcode Helpers
 * ============================================================================ */

/* Move between virtual registers */
static void op_mov(jit_ctx *ctx, vreg *to, vreg *from) {
    preg *r = fetch(from);
    if (IS_FLOAT(from)) {
        r = alloc_fpu(ctx, from, true);
    } else {
        /* For non-float, always allocate CPU register to ensure value is loaded */
        r = alloc_cpu(ctx, from, true);
    }
    store(ctx, to, r, true);
}

/* Store an integer constant into a register */
static void store_const(jit_ctx *ctx, vreg *r, int c) {
    preg *pr = alloc_cpu(ctx, r, false);
    load_imm64(ctx, pr->id, c);
    store(ctx, r, pr, false);
}

/* Forward declaration */
static void call_native(jit_ctx *ctx, void *nativeFun, int stackSize);

/* Binary operation helper */
static void op_binop(jit_ctx *ctx, vreg *dst, vreg *a, vreg *b, hl_op op) {
    if (IS_FLOAT(a)) {
        /* Float operations */
        preg *pa = alloc_fpu(ctx, a, true);
        RLOCK(pa);  /* Lock before allocating more registers */
        preg *pb = alloc_fpu(ctx, b, true);
        RLOCK(pb);
        preg *pd = alloc_fpu(ctx, dst, false);
        
        switch (op) {
        case OAdd:
            if (a->t->kind == HF32) {
                /* FADD S */
                EMIT(0x1E202800 | (((pb->id) & 0x1F) << 16) | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
            } else {
                ARM64_FADD_D(pd->id, pa->id, pb->id);
            }
            break;
        case OSub:
            if (a->t->kind == HF32) {
                EMIT(0x1E203800 | (((pb->id) & 0x1F) << 16) | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
            } else {
                ARM64_FSUB_D(pd->id, pa->id, pb->id);
            }
            break;
        case OMul:
            if (a->t->kind == HF32) {
                EMIT(0x1E200800 | (((pb->id) & 0x1F) << 16) | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
            } else {
                ARM64_FMUL_D(pd->id, pa->id, pb->id);
            }
            break;
        case OSDiv:
            if (a->t->kind == HF32) {
                EMIT(0x1E201800 | (((pb->id) & 0x1F) << 16) | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
            } else {
                ARM64_FDIV_D(pd->id, pa->id, pb->id);
            }
            break;
        case OSMod:
            /* Float modulo - call fmod/fmodf */
            /* Move operands to D0/S0 and D1/S1 for call */
            if (pa->id != 0) {
                if (a->t->kind == HF32)
                    ARM64_FMOV_S(0, pa->id);
                else
                    ARM64_FMOV_D(0, pa->id);
            }
            if (pb->id != 1) {
                if (a->t->kind == HF32)
                    ARM64_FMOV_S(1, pb->id);
                else
                    ARM64_FMOV_D(1, pb->id);
            }
            call_native(ctx, a->t->kind == HF32 ? (void*)fmodf : (void*)fmod, 0);
            if (pd->id != 0) {
                if (a->t->kind == HF32)
                    ARM64_FMOV_S(pd->id, 0);
                else
                    ARM64_FMOV_D(pd->id, 0);
            }
            break;
        default:
            jit_error("Unsupported float binop");
        }
        store(ctx, dst, pd, true);
        RUNLOCK(pa);
        RUNLOCK(pb);
    } else {
        /* Integer operations - use 32-bit ops for Int32 and smaller, 64-bit for Int64/pointers */
        preg *pa = alloc_cpu(ctx, a, true);
        RLOCK(pa);  /* Lock before allocating more registers */
        preg *pb = alloc_cpu(ctx, b, true);
        RLOCK(pb);
        preg *pd = alloc_cpu(ctx, dst, false);
        int is64 = (a->t->kind == HI64);
        
        switch (op) {
        case OAdd:
            if (is64) ARM64_ADD_X(pd->id, pa->id, pb->id);
            else ARM64_ADD_W(pd->id, pa->id, pb->id);
            break;
        case OSub:
            if (is64) ARM64_SUB_X(pd->id, pa->id, pb->id);
            else ARM64_SUB_W(pd->id, pa->id, pb->id);
            break;
        case OMul:
            if (is64) ARM64_MUL_X(pd->id, pa->id, pb->id);
            else ARM64_MUL_W(pd->id, pa->id, pb->id);
            break;
        case OSDiv:
            if (is64) ARM64_SDIV_X(pd->id, pa->id, pb->id);
            else ARM64_SDIV_W(pd->id, pa->id, pb->id);
            break;
        case OUDiv:
            if (is64) ARM64_UDIV_X(pd->id, pa->id, pb->id);
            else ARM64_UDIV_W(pd->id, pa->id, pb->id);
            break;
        case OAnd:
            if (is64) ARM64_AND_X(pd->id, pa->id, pb->id);
            else ARM64_AND_W(pd->id, pa->id, pb->id);
            break;
        case OOr:
            if (is64) ARM64_ORR_X(pd->id, pa->id, pb->id);
            else ARM64_ORR_W(pd->id, pa->id, pb->id);
            break;
        case OXor:
            if (is64) ARM64_EOR_X(pd->id, pa->id, pb->id);
            else ARM64_EOR_W(pd->id, pa->id, pb->id);
            break;
        case OShl:
            if (is64) ARM64_LSL_X(pd->id, pa->id, pb->id);
            else ARM64_LSL_W(pd->id, pa->id, pb->id);
            break;
        case OSShr:
            if (is64) ARM64_ASR_X(pd->id, pa->id, pb->id);
            else ARM64_ASR_W(pd->id, pa->id, pb->id);
            break;
        case OUShr:
            if (is64) ARM64_LSR_X(pd->id, pa->id, pb->id);
            else ARM64_LSR_W(pd->id, pa->id, pb->id);
            break;
        case OSMod:
            {
                /* Signed modulo: a - (a / b) * b using MSUB */
                preg *tmp = alloc_reg(ctx, RCPU);
                if (is64) {
                    ARM64_SDIV_X(tmp->id, pa->id, pb->id);  /* tmp = a / b */
                    /* MSUB (64-bit): pd = pa - tmp * pb */
                    EMIT(0x9B008000 | ((pb->id) << 16) | ((pa->id) << 10) | ((tmp->id) << 5) | (pd->id));
                } else {
                    ARM64_SDIV_W(tmp->id, pa->id, pb->id);  /* tmp = a / b */
                    /* MSUB (32-bit): pd = pa - tmp * pb */
                    EMIT(0x1B008000 | ((pb->id) << 16) | ((pa->id) << 10) | ((tmp->id) << 5) | (pd->id));
                }
                RUNLOCK(tmp);
            }
            break;
        case OUMod:
            {
                /* Unsigned modulo: a - (a / b) * b using MSUB */
                preg *tmp = alloc_reg(ctx, RCPU);
                if (is64) {
                    ARM64_UDIV_X(tmp->id, pa->id, pb->id);  /* tmp = a / b */
                    /* MSUB (64-bit): pd = pa - tmp * pb */
                    EMIT(0x9B008000 | ((pb->id) << 16) | ((pa->id) << 10) | ((tmp->id) << 5) | (pd->id));
                } else {
                    ARM64_UDIV_W(tmp->id, pa->id, pb->id);  /* tmp = a / b */
                    /* MSUB (32-bit): pd = pa - tmp * pb */
                    EMIT(0x1B008000 | ((pb->id) << 16) | ((pa->id) << 10) | ((tmp->id) << 5) | (pd->id));
                }
                RUNLOCK(tmp);
            }
            break;
        default:
            jit_error("Unsupported integer binop");
        }
        store(ctx, dst, pd, true);
        RUNLOCK(pa);
        RUNLOCK(pb);
    }
}

/* Negation */
static void op_neg(jit_ctx *ctx, vreg *dst, vreg *a) {
    if (IS_FLOAT(a)) {
        preg *pa = alloc_fpu(ctx, a, true);
        RLOCK(pa);  /* Lock before allocating dst */
        preg *pd = alloc_fpu(ctx, dst, false);
        /* FNEG */
        if (a->t->kind == HF32)
            EMIT(0x1E214000 | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
        else
            EMIT(0x1E614000 | (((pa->id) & 0x1F) << 5) | ((pd->id) & 0x1F));
        store(ctx, dst, pd, true);
        RUNLOCK(pa);
    } else {
        preg *pa = alloc_cpu(ctx, a, true);
        RLOCK(pa);  /* Lock before allocating dst */
        preg *pd = alloc_cpu(ctx, dst, false);
        /* NEG is SUB from XZR/WZR */
        if (a->t->kind == HI64)
            ARM64_SUB_X(pd->id, XZR, pa->id);
        else
            ARM64_SUB_W(pd->id, WZR, pa->id);
        store(ctx, dst, pd, true);
        RUNLOCK(pa);
    }
}

/* ============================================================================
 * Jump Management
 * ============================================================================ */

static void add_jump(jit_ctx *ctx, int pos, int target) {
    jlist *j = (jlist *)hl_malloc(&ctx->falloc, sizeof(jlist));
    j->pos = pos;
    j->target = target;
    j->next = ctx->jumps;
    ctx->jumps = j;
}

static void add_call(jit_ctx *ctx, int pos, int findex) {
    jlist *j = (jlist *)hl_malloc(&ctx->galloc, sizeof(jlist));
    j->pos = pos;
    j->target = findex;
    j->next = ctx->calls;
    ctx->calls = j;
}

/* ============================================================================
 * Function Calls
 * ============================================================================ */

/* Prepare arguments for a function call */
static int prepare_call_args(jit_ctx *ctx, int count, int *args) {
    int i;
    int stackArgs = 0;
    
    /* SPILL all scratch register bindings before preparing call args.
     * This ensures values that only exist in registers are written to their
     * stack slots, so they can be correctly loaded for call argument setup.
     * Previous version just invalidated without spilling, which caused stale
     * stack data to be used for overflow args (args 9+ that go on the stack).
     */
    for (i = 0; i < RCPU_SCRATCH_COUNT; i++) {
        preg *r = REG_AT(RCPU_SCRATCH_REGS[i]);
        if (r->holds) {
            /* Spill to stack before invalidating */
            copy_to_stack(ctx, &r->holds->stack, r, r->holds->size);
            r->holds->current = NULL;
            r->holds = NULL;
        }
    }
    for (i = 0; i < RFPU_SCRATCH_COUNT; i++) {
        preg *r = REG_AT(VREG(RFPU_SCRATCH_REGS[i]));
        if (r->holds) {
            /* Spill to stack before invalidating */
            copy_to_stack(ctx, &r->holds->stack, r, r->holds->size);
            r->holds->current = NULL;
            r->holds = NULL;
        }
    }
    
#ifdef JIT_DEBUG
    static int call_count = 0;
    if (call_count < 20) {
        printf("ARM64: prepare_call_args count=%d, currentPos=%d\n", count, ctx->currentPos);
        for (i = 0; i < count; i++) {
            vreg *r = R(args[i]);
            printf("  arg[%d]: vreg=%d, t->kind=%d, size=%d, stackPos=%d, current=%p, stack.id=%d\n",
                   i, args[i], r->t->kind, r->size, r->stackPos, (void*)r->current, r->stack.id);
        }
        call_count++;
    }
#endif
    
    /* First pass: copy args to call registers, using RLOCK to prevent clobbering */
    /* ARM64 ABI: Integer args go in X0-X7, FP args go in D0-D7, with SEPARATE indices */
    int cpuIdx = 0;  /* Index for X0-X7 */
    int fpuIdx = 0;  /* Index for D0-D7 */
    
    for (i = 0; i < count && (cpuIdx < CALL_NREGS || fpuIdx < 8); i++) {
        vreg *r = R(args[i]);
        preg *cur = fetch(r);
        preg *dest;
        
#ifdef JIT_DEBUG
        if (call_count <= 20) {
            printf("  arg[%d] fetch: cur->kind=%d, cur->id=%d\n", i, cur->kind, cur->id);
        }
#endif
        
        if (IS_FLOAT(r)) {
            if (fpuIdx >= 8) continue;  /* Too many FPU args */
            dest = &ctx->pregs[RCPU_COUNT + fpuIdx]; /* V0-V7 */
            fpuIdx++;
            if (cur != dest) {
                copy(ctx, dest, cur, r->size);
                scratch(dest);
            }
        } else {
            if (cpuIdx >= CALL_NREGS) continue;  /* Too many CPU args */
            dest = &ctx->pregs[CALL_REGS[cpuIdx]];
            cpuIdx++;
            if (cur != dest) {
                copy(ctx, dest, cur, r->size);
                scratch(dest);
            }
        }
        RLOCK(dest);
    }
    
    /* Calculate stack space for extra args.
     * ARM64 has separate CPU (X0-X7) and FPU (D0-D7) register banks.
     * An arg overflows only if its specific bank is full.
Yeah     * Apple ARM64 ABI: stack arguments use natural alignment (4 bytes for int,
     * 8 bytes for pointer/double), NOT always padded to 8 bytes like AAPCS64.
     */
    {
        int cpuCount = 0, fpuCount = 0;
        int tmpOffset = 0;
        for (i = 0; i < count; i++) {
            vreg *r = R(args[i]);
            bool overflowed;
            if (IS_FLOAT(r)) {
                overflowed = (fpuCount >= 8);
                fpuCount++;
            } else {
                overflowed = (cpuCount >= CALL_NREGS);
                cpuCount++;
            }
            if (!overflowed) continue;
            int argSize = r->size;
            if (argSize < 4) argSize = 4;  /* minimum 4 bytes on stack */
            int argAlign = argSize <= 4 ? 4 : 8;
            tmpOffset = (tmpOffset + (argAlign - 1)) & ~(argAlign - 1);
            tmpOffset += argSize;
        }
        stackArgs = tmpOffset;
    }
    
    /* Align stack to 16 bytes if needed */
    int stackSize = (stackArgs + 15) & ~15;
    if (stackSize > 0) {
        if (stackSize <= 4095) {
            ARM64_SUB_IMM_X(SP, SP, stackSize);
        } else {
            scratch(REG_AT(X9));
            load_imm64(ctx, X9, stackSize);
            ARM64_SUB_EXT_X(SP, SP, X9);
        }
    }
    
    /* Push extra args to stack (only those that overflow their register bank).
     * Apple ARM64 ABI: use natural alignment (4B for int, 8B for ptr/double)
     * and store with the correct width (STR W for 4B, STR X for 8B).
     */
    {
        int cpuCount = 0, fpuCount = 0, stkOffset = 0;
        for (i = 0; i < count; i++) {
            vreg *r = R(args[i]);
            bool overflow;
            if (IS_FLOAT(r)) {
                overflow = (fpuCount >= 8);
                fpuCount++;
            } else {
                overflow = (cpuCount >= CALL_NREGS);
                cpuCount++;
            }
            if (!overflow) continue;
            
            /* Compute natural alignment for this arg (Apple ARM64 ABI) */
            int argSize = r->size;
            if (argSize < 4) argSize = 4;  /* minimum 4 bytes on stack */
            int argAlign = argSize <= 4 ? 4 : 8;
            stkOffset = (stkOffset + (argAlign - 1)) & ~(argAlign - 1);
            
            /* Load the vreg from its stack slot into a temp register,
             * then store to the call stack area. */
            int offset = r->stackPos;
            int tmp_reg = X8;
            
            if (IS_FLOAT(r)) {
                /* FPU overflow: use V0 as temp */
                if (offset >= -256 && offset < 0) {
                    if (r->size == 8)
                        EMIT(0xFC400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (0 & 0x1F));
                    else
                        EMIT(0xBC400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (0 & 0x1F));
                } else if (offset < -256) {
                    if (-offset <= 4095) {
                        ARM64_SUB_IMM_X(tmp_reg, FP, -offset);
                    } else {
                        load_imm64(ctx, tmp_reg, -offset);
                        ARM64_SUB_X(tmp_reg, FP, tmp_reg);
                    }
                    if (r->size == 8)
                        EMIT(0xFD400000 | (0 << 10) | ((tmp_reg & 0x1F) << 5) | (0 & 0x1F));
                    else
                        EMIT(0xBD400000 | (0 << 10) | ((tmp_reg & 0x1F) << 5) | (0 & 0x1F));
                } else {
                    if (r->size == 8)
                        EMIT(0xFD400000 | (((offset >> 3) & 0xFFF) << 10) | ((FP & 0x1F) << 5) | (0 & 0x1F));
                    else
                        EMIT(0xBD400000 | (((offset >> 2) & 0xFFF) << 10) | ((FP & 0x1F) << 5) | (0 & 0x1F));
                }
                /* Store to call stack with correct width */
                if (argSize == 8)
                    EMIT(0xFD000000 | (((stkOffset >> 3) & 0xFFF) << 10) | ((SP & 0x1F) << 5) | (0 & 0x1F));
                else
                    EMIT(0xBD000000 | (((stkOffset >> 2) & 0xFFF) << 10) | ((SP & 0x1F) << 5) | (0 & 0x1F));
            } else {
                /* CPU/pointer overflow: load from vreg stack slot */
                if (offset >= -256 && offset < 0) {
                    if (r->size == 8)
                        EMIT(0xF8400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (tmp_reg & 0x1F));
                    else if (r->size == 1)
                        EMIT(0x38400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (tmp_reg & 0x1F));
                    else
                        EMIT(0xB8400000 | ((offset & 0x1FF) << 12) | ((FP & 0x1F) << 5) | (tmp_reg & 0x1F));
                } else if (offset < -256) {
                    int addr_reg = X9;
                    if (-offset <= 4095) {
                        ARM64_SUB_IMM_X(addr_reg, FP, -offset);
                    } else {
                        load_imm64(ctx, addr_reg, -offset);
                        ARM64_SUB_X(addr_reg, FP, addr_reg);
                    }
                    if (r->size == 8)
                        ARM64_LDR_X(tmp_reg, addr_reg, 0);
                    else if (r->size == 1)
                        ARM64_LDRB(tmp_reg, addr_reg, 0);
                    else
                        ARM64_LDR_W(tmp_reg, addr_reg, 0);
                } else {
                    if (r->size == 8)
                        ARM64_LDR_X(tmp_reg, FP, offset);
                    else if (r->size == 1)
                        ARM64_LDRB(tmp_reg, FP, offset);
                    else
                        ARM64_LDR_W(tmp_reg, FP, offset);
                }
                /* Store to call stack with correct width for Apple ARM64 ABI */
                if (argSize == 8) {
                    ARM64_STR_X(tmp_reg, SP, stkOffset);
                } else {
                    ARM64_STR_W(tmp_reg, SP, stkOffset);
                }
            }
            stkOffset += argSize;
        }
    }
    
    /* Unlock call registers using correct per-bank indices */
    {
        int cpuCount = 0, fpuCount = 0;
        for (i = 0; i < count; i++) {
            vreg *r = R(args[i]);
            if (IS_FLOAT(r)) {
                if (fpuCount < 8)
                    RUNLOCK(&ctx->pregs[RCPU_COUNT + fpuCount]);
                fpuCount++;
            } else {
                if (cpuCount < CALL_NREGS)
                    RUNLOCK(&ctx->pregs[CALL_REGS[cpuCount]]);
                cpuCount++;
            }
        }
    }
    
    return stackSize;
}

/* Initialize module for JIT compilation */
/* Build a JIT helper function, returning its offset in the code buffer */
static int jit_build(jit_ctx *ctx, void (*fbuild)(jit_ctx *)) {
    int pos;
    jit_buf(ctx);
    pos = BUF_POS();
    fbuild(ctx);
    return pos;
}

#ifdef HL_WIN
/*
 * Custom longjmp for Windows ARM64.
 *
 * On Windows, longjmp uses RtlUnwindEx which requires proper unwind info
 * for each frame on the stack. JIT-generated code has no unwind info,
 * so system longjmp crashes when trying to unwind through JIT frames.
 *
 * This custom implementation directly restores registers from the jmp_buf
 * without doing SEH unwinding, similar to the x86 JIT's JIT_CUSTOM_LONGJUMP.
 *
 * Windows ARM64 _JUMP_BUFFER layout:
 *   offset   0: Frame     (uint64_t)
 *   offset   8: Reserved  (uint64_t)
 *   offset  16: X19
 *   offset  24: X20
 *   offset  32: X21
 *   offset  40: X22
 *   offset  48: X23
 *   offset  56: X24
 *   offset  64: X25
 *   offset  72: X26
 *   offset  80: X27
 *   offset  88: X28
 *   offset  96: Fp  (X29)
 *   offset 104: Lr  (X30)
 *   offset 112: Sp
 *   offset 120: Fpcr (uint32_t)
 *   offset 124: Fpsr (uint32_t)
 *   offset 128: D[0] (D8)
 *   offset 136: D[1] (D9)
 *   offset 144: D[2] (D10)
 *   offset 152: D[3] (D11)
 *   offset 160: D[4] (D12)
 *   offset 168: D[5] (D13)
 *   offset 176: D[6] (D14)
 *   offset 184: D[7] (D15)
 */
static void jit_longjump(jit_ctx *ctx) {
    /* Args: X0 = jmp_buf*, W1 = return value */
    
    /* Save buf pointer to X2 (X0 will become return value) */
    ARM64_MOV_X(X2, X0);
    
    /* Ensure return value is non-zero (longjmp spec requires this) */
    EMIT(0x35000041);  /* CBNZ W1, PC+8 (skip next instruction if W1 != 0) */
    ARM64_MOVZ_W(X1, 1);  /* W1 = 1 */
    
    /* Set return value */
    ARM64_MOV_W(X0, X1);
    
    /* Restore callee-saved FPU registers D8-D15 (before SP changes) */
    ARM64_LDR_D(V8, X2, 128);
    ARM64_LDR_D(V9, X2, 136);
    ARM64_LDR_D(V10, X2, 144);
    ARM64_LDR_D(V11, X2, 152);
    ARM64_LDR_D(V12, X2, 160);
    ARM64_LDR_D(V13, X2, 168);
    ARM64_LDR_D(V14, X2, 176);
    ARM64_LDR_D(V15, X2, 184);
    
    /* Restore FPCR and FPSR */
    ARM64_LDR_W(X9, X2, 120);
    EMIT(0xD51B4409);  /* MSR FPCR, X9 */
    ARM64_LDR_W(X9, X2, 124);
    EMIT(0xD51B4429);  /* MSR FPSR, X9 */
    
    /* Restore callee-saved GPRs X19-X28 */
    ARM64_LDP_X(X19, X20, X2, 16);
    ARM64_LDP_X(X21, X22, X2, 32);
    ARM64_LDP_X(X23, X24, X2, 48);
    ARM64_LDP_X(X25, X26, X2, 64);
    ARM64_LDP_X(X27, X28, X2, 80);
    
    /* Restore FP (X29) and LR (X30) */
    ARM64_LDP_X(X29, X30, X2, 96);
    
    /* Restore SP (must use ADD since MOV Xd, Xm treats r31 as XZR) */
    ARM64_LDR_X(X9, X2, 112);
    ARM64_ADD_IMM_X(SP, X9, 0);  /* MOV SP, X9 */
    
    /* Return to saved LR */
    ARM64_RET();
}
#endif

static void hl_jit_init_module(jit_ctx *ctx, hl_module *m) {
    ctx->m = m;
    
    /* Module initialization */
    
    if (m->code->hasdebug) {
        ctx->debug = (hl_debug_infos *)malloc(sizeof(hl_debug_infos) * m->code->nfunctions);
        if (ctx->debug)
            /* Use 0 instead of -1: ARM64 JIT doesn't populate debug offsets,
               so -1 causes crash when freeing. NULL pointers are safe to free. */
            memset(ctx->debug, 0, sizeof(hl_debug_infos) * m->code->nfunctions);
    }
    
#ifdef HL_WIN
    /* Build custom longjmp to bypass SEH unwinding through JIT frames */
    ctx->longjump = jit_build(ctx, jit_longjump);
#endif
    
    /* Float constants will be embedded inline when needed */
}

/* Call a native function */
static void call_native(jit_ctx *ctx, void *nativeFun, int stackSize) {
    /* Load function address into X9 - invalidate any vreg binding first */
    scratch(REG_AT(X9));
    load_imm64(ctx, X9, (int64_t)(intptr_t)nativeFun);
    
    /* BLR X9 */
    ARM64_BLR(X9);
    
    /* Restore stack */
    if (stackSize > 0) {
        if (stackSize <= 4095) {
            ARM64_ADD_IMM_X(SP, SP, stackSize);
        } else {
            load_imm64(ctx, X9, stackSize);
            ARM64_ADD_EXT_X(SP, SP, X9);
        }
    }
    
    /* Discard all scratch registers after call */
    discard_regs(ctx, true);
}

/* Call an HL function by index */
static void op_call_fun(jit_ctx *ctx, vreg *dst, int findex, int count, int *args) {
    int fid = findex < 0 ? -1 : ctx->m->functions_indexes[findex];
    int total_fns = ctx->m->code->nfunctions + ctx->m->code->nnatives;
    bool isNative = fid >= ctx->m->code->nfunctions;
    int stackSize = prepare_call_args(ctx, count, args);
    
    if (fid < 0) {
        printf("JIT ARM64 ERROR: Invalid function index %d (fid=%d, nfunctions=%d, nnatives=%d, total=%d)\n", 
               findex, fid, ctx->m->code->nfunctions, ctx->m->code->nnatives, total_fns);
        printf("  functions_ptrs[%d] = %p\n", findex, ctx->m->functions_ptrs[findex]);
        /* Try to use the function pointer directly if it's set */
        if (ctx->m->functions_ptrs[findex] != NULL) {
            printf("  Using functions_ptrs directly for native call\n");
            call_native(ctx, ctx->m->functions_ptrs[findex], stackSize);
            if (dst != NULL) {
                preg *pd = alloc_cpu(ctx, dst, true);
                ARM64_MOV_X(pd->id, X0);
            }
            return;
        }
        jit_error("Invalid function index");
    } else if (isNative) {
        /* Native function - already resolved */
        call_native(ctx, ctx->m->functions_ptrs[findex], stackSize);
    } else {
        /* HL function - stage for later patching since addresses aren't resolved yet */
        /* Invalidate any vreg binding to X9 before using it for the function address */
        scratch(REG_AT(X9));
        
        add_call(ctx, BUF_POS(), findex);
        /* Placeholder MOVZ/MOVK sequence that will be patched */
        ARM64_MOVZ_X(X9, 0);
        ARM64_MOVK_X(X9, 0, 16);
        ARM64_MOVK_X(X9, 0, 32);
        ARM64_MOVK_X(X9, 0, 48);
        ARM64_BLR(X9);
        
        /* Restore stack */
        if (stackSize > 0) {
            if (stackSize <= 4095) {
                ARM64_ADD_IMM_X(SP, SP, stackSize);
            } else {
                load_imm64(ctx, X9, stackSize);
                ARM64_ADD_EXT_X(SP, SP, X9);
            }
        }
        
        /* Discard ALL register bindings after HL function call.
         * This is necessary because the called function may have clobbered
         * any register, and our bindings could be stale.
         */
        discard_regs(ctx, true);
    }
    
    /* Store result - skip for void functions */
    if (dst && dst->t->kind != HVOID) {
        if (IS_FLOAT(dst)) {
            /* Save result before alloc_fpu might trigger spills */
            ARM64_FMOV_D(V16, V0); /* Use a higher FPU reg as temp */
            preg *pd = alloc_fpu(ctx, dst, false);
            if (dst->t->kind == HF64)
                ARM64_FMOV_D(pd->id, V16);
            else
                ARM64_FMOV_S(pd->id, V16);
            store(ctx, dst, pd, true);
        } else {
            /* Save result before alloc_cpu might clobber X0 */
            /* For 32-bit returns, zero-extend to ensure upper bits are clean */
            if (dst->size <= 4) {
                ARM64_MOV_W(X20, X0);  /* MOV W11, W0 - zero extends */
            } else {
                ARM64_MOV_X(X20, X0);
            }
            preg *pd = alloc_cpu(ctx, dst, false);
            ARM64_MOV_X(pd->id, X20);
            store(ctx, dst, pd, true);
        }
    }
}

/* ============================================================================
 * Global Access
 * ============================================================================ */

static void op_get_global(jit_ctx *ctx, vreg *dst, int globalIdx) {
    void *addr = ctx->m->globals_data + ctx->m->globals_indexes[globalIdx];
    
    /* Load address into temp register */
    preg *tmp = alloc_reg(ctx, RCPU);
    RLOCK(tmp);  /* Lock before alloc_fpu/alloc_cpu might reuse it */
    load_imm64(ctx, tmp->id, (int64_t)(intptr_t)addr);
    
    /* Load value from address */
    if (IS_FLOAT(dst)) {
        preg *pd = alloc_fpu(ctx, dst, false);
        if (dst->t->kind == HF64)
            ARM64_LDR_D(pd->id, tmp->id, 0);
        else
            ARM64_LDR_S(pd->id, tmp->id, 0);
        store(ctx, dst, pd, true);
    } else {
        preg *pd = alloc_cpu(ctx, dst, false);
        if (dst->size == 8)
            ARM64_LDR_X(pd->id, tmp->id, 0);
        else
            ARM64_LDR_W(pd->id, tmp->id, 0);
        store(ctx, dst, pd, true);
    }
    
    RUNLOCK(tmp);
}

static void op_set_global(jit_ctx *ctx, int globalIdx, vreg *src) {
    void *addr = ctx->m->globals_data + ctx->m->globals_indexes[globalIdx];
    
    /* Load address into temp register */
    preg *tmp = alloc_reg(ctx, RCPU);
    RLOCK(tmp);  /* Lock before alloc_fpu/alloc_cpu might reuse it */
    load_imm64(ctx, tmp->id, (int64_t)(intptr_t)addr);
    
    /* Store value to address */
    if (IS_FLOAT(src)) {
        preg *ps = alloc_fpu(ctx, src, true);
        if (src->t->kind == HF64)
            ARM64_STR_D(ps->id, tmp->id, 0);
        else
            ARM64_STR_S(ps->id, tmp->id, 0);
    } else {
        preg *ps = alloc_cpu(ctx, src, true);
        if (src->size == 8)
            ARM64_STR_X(ps->id, tmp->id, 0);
        else if (src->size == 1)
            ARM64_STRB(ps->id, tmp->id, 0);
        else
            ARM64_STR_W(ps->id, tmp->id, 0);
    }
    
    RUNLOCK(tmp);
}

/* ============================================================================
 * Field Access
 * ============================================================================ */

static void op_get_field(jit_ctx *ctx, vreg *dst, vreg *obj, int fieldIdx) {
    hl_runtime_obj *rt;
    int offset;
    
    switch (obj->t->kind) {
    case HOBJ:
    case HSTRUCT:
        rt = hl_get_obj_rt(obj->t);
        offset = rt->fields_indexes[fieldIdx];
        
        {
            preg *po = alloc_cpu(ctx, obj, true);
            RLOCK(po);  /* Lock po before allocating dst register */
            
            if (IS_FLOAT(dst)) {
                preg *pd = alloc_fpu(ctx, dst, false);
                if (dst->t->kind == HF64)
                    ARM64_LDR_D(pd->id, po->id, offset);
                else
                    ARM64_LDR_S(pd->id, po->id, offset);
                store(ctx, dst, pd, true);
            } else {
                preg *pd = alloc_cpu(ctx, dst, false);
                if (dst->size == 8)
                    ARM64_LDR_X(pd->id, po->id, offset);
                else if (dst->size == 1)
                    ARM64_LDRB(pd->id, po->id, offset);
                else
                    ARM64_LDR_W(pd->id, po->id, offset);
                store(ctx, dst, pd, true);
            }
            RUNLOCK(po);
        }
        break;
    
    case HVIRTUAL:
        {
            /* Virtual field access:
             * if (hl_vfields(obj)[fieldIdx]) 
             *     result = *hl_vfields(obj)[fieldIdx];
             * else 
             *     result = hl_dyn_get*(obj, hash, type);
             *
             * We use X20/X21 (callee-saved) to preserve values across the slow path.
             */
            preg *po = alloc_cpu(ctx, obj, true);
            
            /* Load hl_vfields(obj)[fieldIdx] = *(obj + 24 + fieldIdx * 8) */
            int vfields_offset = 24 + fieldIdx * 8;  /* sizeof(vvirtual) = 24 */
            
            /* Save obj pointer to X21 (callee-saved) and field ptr to X20 */
            ARM64_MOV_X(X21, po->id);
            ARM64_LDR_X(X20, po->id, vfields_offset);
            
            /* Check if field pointer is null */
            ARM64_CMP_IMM_X(X20, 0);
            
            int jhasfield = BUF_POS();
            ARM64_B_COND(COND_NE, 0);  /* Jump to fast path if not null */
            
            /* --- Slow path: call hl_dyn_get* --- */
            discard_regs(ctx, false);
            
            ARM64_MOV_X(X0, X21);  /* obj (from callee-saved X21) */
            
            /* Load field hash */
            int hash = obj->t->virt->fields[fieldIdx].hashed_name;
            load_imm64(ctx, X1, hash);  /* hash */
            
            /* Choose the right hl_dyn_get* function */
            void *dynget_fn;
            switch (dst->t->kind) {
            case HF32:
                dynget_fn = hl_dyn_getf;
                break;
            case HF64:
                dynget_fn = hl_dyn_getd;
                break;
            case HI64:
                dynget_fn = hl_dyn_geti64;
                break;
            case HI32:
            case HUI16:
            case HUI8:
            case HBOOL:
                dynget_fn = hl_dyn_geti;
                load_imm64(ctx, X2, (int64_t)(intptr_t)dst->t);
                break;
            default:
                dynget_fn = hl_dyn_getp;
                load_imm64(ctx, X2, (int64_t)(intptr_t)dst->t);
                break;
            }
            
            call_native(ctx, dynget_fn, 0);
            
            /* Store result - save to X20 before alloc might clobber X0 */
            if (IS_FLOAT(dst)) {
                if (dst->t->kind == HF32) {
                    ARM64_FMOV_S(20, 0);  /* D20 = S0 */
                } else {
                    ARM64_FMOV_D(20, 0);  /* D20 = D0 */
                }
            } else {
                ARM64_MOV_X(X20, X0);
            }
            
            int jend = BUF_POS();
            ARM64_B(0);  /* Jump to end */
            
            /* --- Fast path: dereference field pointer (X20 has the field ptr) --- */
            int hasfield_pos = BUF_POS();
            
            /* X20 already has the field pointer from before the conditional jump */
            if (IS_FLOAT(dst)) {
                if (dst->t->kind == HF64)
                    ARM64_LDR_D(20, X20, 0);  /* D20 = *X20 */
                else
                    ARM64_LDR_S(20, X20, 0);  /* S20 = *X20 */
            } else {
                if (dst->size == 8)
                    ARM64_LDR_X(X20, X20, 0);
                else if (dst->size == 1)
                    ARM64_LDRB(X20, X20, 0);
                else
                    ARM64_LDR_W(X20, X20, 0);
            }
            
            /* --- Merge point: result is in X20/D20 --- */
            int end_pos = BUF_POS();
            
            /* Store from X20/D20 to destination */
            if (IS_FLOAT(dst)) {
                preg *pd = alloc_fpu(ctx, dst, false);
                if (dst->t->kind == HF64) {
                    if (pd->id != 20)
                        ARM64_FMOV_D(pd->id, 20);
                } else {
                    if (pd->id != 20)
                        ARM64_FMOV_S(pd->id, 20);
                }
                store(ctx, dst, pd, true);
            } else {
                preg *pd = alloc_cpu(ctx, dst, false);
                if (pd->id != X20)
                    ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            
            /* Patch jumps */
            int rel_hasfield = (hasfield_pos - jhasfield) / 4;
            *(unsigned int *)(ctx->startBuf + jhasfield) = 
                (*(unsigned int *)(ctx->startBuf + jhasfield) & 0xFF00001F) | 
                ((rel_hasfield & 0x7FFFF) << 5);
            
            int rel_end = (end_pos - jend) / 4;
            *(unsigned int *)(ctx->startBuf + jend) = 
                0x14000000 | (rel_end & 0x3FFFFFF);
        }
        break;
        
    default:
        /* Unsupported type for field access */
        ARM64_BRK(0xF1E1);
        break;
    }
}

static void op_set_field(jit_ctx *ctx, vreg *obj, int fieldIdx, vreg *src) {
    hl_runtime_obj *rt;
    int offset;
    
    switch (obj->t->kind) {
    case HOBJ:
    case HSTRUCT:
        rt = hl_get_obj_rt(obj->t);
        offset = rt->fields_indexes[fieldIdx];
        
        {
            preg *po = alloc_cpu(ctx, obj, true);
            RLOCK(po);
            
            if (IS_FLOAT(src)) {
                preg *ps = alloc_fpu(ctx, src, true);
                if (src->t->kind == HF64)
                    ARM64_STR_D(ps->id, po->id, offset);
                else
                    ARM64_STR_S(ps->id, po->id, offset);
            } else {
                preg *ps = alloc_cpu(ctx, src, true);
                if (src->size == 8)
                    ARM64_STR_X(ps->id, po->id, offset);
                else if (src->size == 1)
                    ARM64_STRB(ps->id, po->id, offset);
                else
                    ARM64_STR_W(ps->id, po->id, offset);
            }
            RUNLOCK(po);
        }
        break;
    
    case HVIRTUAL:
        {
            /* Virtual field set:
             * if (hl_vfields(obj)[fieldIdx]) 
             *     *hl_vfields(obj)[fieldIdx] = value;
             * else 
             *     hl_dyn_set*(obj, hash, type, value);
             *
             * We use X20/X21/X22 (callee-saved) to preserve values across paths.
             * X20 = field pointer
             * X21 = obj pointer
             * X22 = src value (for non-float)
             * D20 = src value (for float)
             */
            int vfields_offset = 24 + fieldIdx * 8;
            
            /* Save obj pointer to X21, load field pointer to X20 */
            preg *po = alloc_cpu(ctx, obj, true);
            ARM64_MOV_X(X21, po->id);
            ARM64_LDR_X(X20, po->id, vfields_offset);
            
            /* Save src value to X22/D20 */
            if (IS_FLOAT(src)) {
                preg *ps = alloc_fpu(ctx, src, true);
                if (src->t->kind == HF32)
                    ARM64_FMOV_S(20, ps->id);
                else
                    ARM64_FMOV_D(20, ps->id);
            } else {
                preg *ps = alloc_cpu(ctx, src, true);
                ARM64_MOV_X(X22, ps->id);
            }
            
            /* Check if field pointer is null */
            ARM64_CMP_IMM_X(X20, 0);
            
            int jhasfield = BUF_POS();
            ARM64_B_COND(COND_NE, 0);  /* Jump to fast path if not null */
            
            /* --- Slow path: call hl_dyn_set* --- */
            discard_regs(ctx, false);
            
            ARM64_MOV_X(X0, X21);  /* obj (from callee-saved X21) */
            
            int hash = obj->t->virt->fields[fieldIdx].hashed_name;
            load_imm64(ctx, X1, hash);  /* hash */
            load_imm64(ctx, X2, (int64_t)(intptr_t)src->t);  /* type */
            
            /* Load value into X3 or D0 from saved registers */
            void *dynset_fn;
            if (IS_FLOAT(src)) {
                if (src->t->kind == HF32)
                    ARM64_FMOV_S(0, 20);
                else
                    ARM64_FMOV_D(0, 20);
                dynset_fn = (src->t->kind == HF32) ? hl_dyn_setf : hl_dyn_setd;
            } else {
                ARM64_MOV_X(X3, X22);
                switch (src->t->kind) {
                case HI64:
                    dynset_fn = hl_dyn_seti64;
                    break;
                case HI32:
                case HUI16:
                case HUI8:
                case HBOOL:
                    dynset_fn = hl_dyn_seti;
                    break;
                default:
                    dynset_fn = hl_dyn_setp;
                    break;
                }
            }
            
            call_native(ctx, dynset_fn, 0);
            
            int jend = BUF_POS();
            ARM64_B(0);  /* Jump to end */
            
            /* --- Fast path: store to field pointer (X20) using saved value (X22/D20) --- */
            int hasfield_pos = BUF_POS();
            
            if (IS_FLOAT(src)) {
                if (src->t->kind == HF64)
                    ARM64_STR_D(20, X20, 0);
                else
                    ARM64_STR_S(20, X20, 0);
            } else {
                if (src->size == 8)
                    ARM64_STR_X(X22, X20, 0);
                else if (src->size == 1)
                    ARM64_STRB(X22, X20, 0);
                else
                    ARM64_STR_W(X22, X20, 0);
            }
            
            int end_pos = BUF_POS();
            
            /* Patch jumps */
            int rel_hasfield = (hasfield_pos - jhasfield) / 4;
            *(unsigned int *)(ctx->startBuf + jhasfield) = 
                (*(unsigned int *)(ctx->startBuf + jhasfield) & 0xFF00001F) | 
                ((rel_hasfield & 0x7FFFF) << 5);
            
            int rel_end = (end_pos - jend) / 4;
            *(unsigned int *)(ctx->startBuf + jend) = 
                0x14000000 | (rel_end & 0x3FFFFFF);
        }
        break;
        
    default:
        ARM64_BRK(0xF1E2);
        break;
    }
}

/* ============================================================================
 * Main JIT Entry Points
 * ============================================================================ */

int hl_jit_function(jit_ctx *ctx, hl_module *m, hl_function *f) {
    int i, size = 0;
    int nargs = f->type->fun->nargs;
    unsigned short *debug16 = NULL;
    int *debug32 = NULL;
    int codePos;
    
    jit_func_count++;
    /* jit_last_func tracks debug file info - skip for now */
    
    /* Debug output for tracking JIT compilation */
    #if 0  /* Enable for verbose JIT tracking */
    printf("JIT #%d: nregs=%d nops=%d\n", 
           jit_func_count,
           f->nregs, f->nops);
    fflush(stdout);
    }
    #endif
    
    ctx->f = f;
    ctx->m = m;
    ctx->allocOffset = 0;
    ctx->jumps = NULL;
    ctx->currentPos = 0;
    
    /* Reset physical registers at start of each function */
    for (i = 0; i < REG_COUNT; i++) {
        preg *r = &ctx->pregs[i];
        r->lock = 0;
        r->holds = NULL;
    }
    
    /* Allocate/resize vregs array */
    if (f->nregs > ctx->maxRegs) {
        free(ctx->vregs);
        ctx->vregs = (vreg *)malloc(sizeof(vreg) * (f->nregs + 1));
        if (ctx->vregs == NULL) {
            ctx->maxRegs = 0;
            return -1;
        }
        ctx->maxRegs = f->nregs;
    }
    
    /* Allocate/resize opsPos array */
    if (f->nops > ctx->maxOps) {
        free(ctx->opsPos);
        ctx->opsPos = (int *)malloc(sizeof(int) * (f->nops + 1));
        if (ctx->opsPos == NULL) {
            ctx->maxOps = 0;
            return -1;
        }
        ctx->maxOps = f->nops;
    }
    memset(ctx->opsPos, 0, (f->nops + 1) * sizeof(int));
    
    /* Initialize virtual registers */
    for (i = 0; i < f->nregs; i++) {
        vreg *r = R(i);
        r->t = f->regs[i];
        r->size = hl_type_size(r->t);
        r->current = NULL;
        r->stack.holds = NULL;
        r->stack.id = 0;
        r->stack.kind = RSTACK;
    }
    
    /* Initialize scratch register at f->nregs for closure calls */
    {
        vreg *scratch = &ctx->vregs[f->nregs];
        scratch->t = &hlt_dyn;
        scratch->size = 8;
        scratch->current = NULL;
        scratch->stack.holds = NULL;
        scratch->stack.id = 0;
        scratch->stack.kind = RSTACK;
        scratch->stackPos = 0;
    }
    
    /* Calculate stack layout */
    int argsSize = 0;
    int cpuArgCount = 0;
    int fpuArgCount = 0;
    for (i = 0; i < nargs; i++) {
        vreg *r = R(i);
        bool isReg;
        if (IS_FLOAT(r)) {
            isReg = (fpuArgCount < 8);
            fpuArgCount++;
        } else {
            isReg = (cpuArgCount < CALL_NREGS);
            cpuArgCount++;
        }
        if (isReg) {
            /* Args passed in registers need local storage */
            /* Use at least 8 bytes for each vreg to ensure unique stack slots */
            int slot_size = r->size > 0 ? r->size : 8;
            size += slot_size;
            size += (size & 7) ? (8 - (size & 7)) : 0; /* 8-byte align */
            r->stackPos = -size;
        } else {
            /* Args on stack already */
            r->stackPos = argsSize + 48; /* After saved FP/LR/X19/X20/X21/X22 (48 bytes) */
            int slot_size = r->size > 0 ? r->size : 8;
            argsSize += (slot_size + 7) & ~7;
        }
    }
    for (i = nargs; i < f->nregs; i++) {
        vreg *r = R(i);
        /* Use at least 8 bytes for each vreg to ensure unique stack slots */
        int slot_size = r->size > 0 ? r->size : 8;
        size += slot_size;
        size += (size & 7) ? (8 - (size & 7)) : 0;
        r->stackPos = -size;
    }
    size = (size + 15) & ~15; /* 16-byte align */
    ctx->totalRegsSize = size;
    
    /* Update stack references */
    for (i = 0; i < f->nregs; i++) {
        vreg *r = R(i);
        r->stack.id = r->stackPos;
    }
    
    ctx->functionPos = BUF_POS();
    codePos = ctx->functionPos;
    ctx->currentPos = 1;
    
    static int func_count = 0;
    
    func_count++;
    
#ifdef JIT_DEBUG
    g_debug_findex = f->findex;
#endif
    
    /* Generate prologue */
    op_enter(ctx);
    
    /* Allocate debug offset tracking array */
    if (m->code->hasdebug) {
        debug16 = (unsigned short*)malloc(sizeof(unsigned short) * (f->nops + 1));
        if (debug16) debug16[0] = (unsigned short)(BUF_POS() - codePos);
    }
    
    /* Store register arguments to stack
     * ARM64 ABI: Integer args in X0-X7, Float args in D0-D7 with SEPARATE indices.
     * So for func(Int, Float, Int, Float): args are in X0, D0, X1, D1
     */
    int cpuArgIdx = 0;  /* Index for X0-X7 */
    int fpuArgIdx = 0;  /* Index for D0-D7 */
    
    for (i = 0; i < nargs && (cpuArgIdx < CALL_NREGS || fpuArgIdx < 8); i++) {
        vreg *r = R(i);
        if (r->stackPos < 0) {
            int offset = r->stackPos;
            if (IS_FLOAT(r)) {
                int regIdx = fpuArgIdx++;
                if (regIdx >= 8) continue;  /* Too many float args */
                if (offset >= -256) {
                    /* Use STUR for small negative offsets */
                    if (r->size == 8)
                        ARM64_STUR_D(regIdx, FP, offset);
                    else
                        ARM64_STUR_S(regIdx, FP, offset);
                } else {
                    /* Large negative offset - compute address first using sub_large_imm */
                    sub_large_imm(ctx, X9, FP, -offset, X10);
                    if (r->size == 8)
                        ARM64_STR_D(regIdx, X9, 0);
                    else
                        ARM64_STR_S(regIdx, X9, 0);
                }
            } else {
                int regIdx = cpuArgIdx++;
                if (regIdx >= CALL_NREGS) continue;  /* Too many CPU args */
                if (offset >= -256) {
                    /* Use STUR for small negative offsets */
                    if (r->size == 8)
                        ARM64_STUR_X(CALL_REGS[regIdx], FP, offset);
                    else
                        ARM64_STUR_W(CALL_REGS[regIdx], FP, offset);
                } else {
                    /* Large negative offset - compute address first using sub_large_imm */
                    sub_large_imm(ctx, X9, FP, -offset, X10);
                    if (r->size == 8)
                        ARM64_STR_X(CALL_REGS[regIdx], X9, 0);
                    else
                        ARM64_STR_W(CALL_REGS[regIdx], X9, 0);
                }
            }
        } else {
            /* Arg passed on stack - just count the register type for indices */
            if (IS_FLOAT(r)) fpuArgIdx++;
            else cpuArgIdx++;
        }
    }
    
    /* Build jump target bitmap - opcodes that are targets of jumps need register clearing */
    /* This is critical for correctness: when a jump is taken, the register allocator
     * state at the target reflects the fall-through path, not the jump source.
     * We must invalidate all bindings at jump targets to force reloading from stack.
     */
    int *is_jump_target = (int *)malloc(sizeof(int) * f->nops);
    memset(is_jump_target, 0, sizeof(int) * f->nops);
    for (int i = 0; i < f->nops; i++) {
        hl_opcode *op = f->ops + i;
        int target = -1;
        switch (op->op) {
            case OJNull:
            case OJNotNull:
                target = i + 1 + op->p2;
                break;
            case OJEq:
            case OJNotEq:
            case OJSLt:
            case OJSGte:
            case OJSGt:
            case OJSLte:
            case OJULt:
            case OJUGte:
            case OJNotLt:   /* Float comparison - was missing! */
            case OJNotGte:  /* Float comparison - was missing! */
                target = i + 1 + op->p3;
                break;
            case OJTrue:
            case OJFalse:
                target = i + 1 + op->p2;
                break;
            case OJAlways:
                target = i + 1 + op->p1;
                break;
            case OSwitch:
                /* Switch has multiple targets in extra[] array, plus a default */
                /* Mark all case targets */
                for (int k = 0; k < op->p2; k++) {
                    int case_target = i + 1 + op->extra[k];
                    if (case_target >= 0 && case_target < f->nops) {
                        is_jump_target[case_target] = 1;
                    }
                }
                /* Default case falls through to next opcode, which is also a target */
                /* (value >= ncases branches to default which is right after switch JIT code) */
                target = i + 1;  /* Mark next opcode as target for default path */
                break;
            case OLabel:
                /* OLabel is explicitly a jump target marker */
                is_jump_target[i] = 1;
                break;
            case OTrap:
                /* Trap jumps to handler on exception */
                target = i + 1 + op->p2;
                break;
            default:
                break;
        }
        if (target >= 0 && target < f->nops) {
            is_jump_target[target] = 1;
        }
    }
    
    ctx->opsPos[0] = BUF_POS();
    
    int func_start_offset = BUF_POS();
    
    /* Compile opcodes */
    for (int opCount = 0; opCount < f->nops; opCount++) {
        hl_opcode *o = f->ops + opCount;
        
#if defined(JIT_DEBUG_LIMIT_FUNC) && defined(JIT_DEBUG_LIMIT_OPS)
        /* Debug: limit compilation of specific function to isolate crash */
        if (f->findex == JIT_DEBUG_LIMIT_FUNC && opCount == 10729) {
            /* Debug: print register state before this OCall0 */
            vreg *dst10 = R(10);
            printf("  Op 10729 OCall0: dst=vreg10 stackPos=%d size=%d type=%d\n",
                   dst10->stackPos, dst10->size, dst10->t->kind);
            printf("  vreg10->current=%p\n", (void*)dst10->current);
            fflush(stdout);
            /* Continue with normal compilation */
        }
        if (f->findex == JIT_DEBUG_LIMIT_FUNC && opCount >= JIT_DEBUG_LIMIT_OPS) {
            /* Set opsPos for remaining ops to current position (the ret) */
            int retPos = BUF_POS();
            printf("JIT_DEBUG_LIMIT: Function %d truncated at op %d (limit %d)\n", 
                   f->findex, opCount, JIT_DEBUG_LIMIT_OPS);
            /* Check if any jumps target skipped ops */
            for (int sk = opCount; sk < f->nops; sk++) {
                ctx->opsPos[sk] = retPos;
                if (is_jump_target[sk]) {
                    printf("  WARNING: Op %d is a jump target but was skipped!\n", sk);
                }
            }
            op_ret_void(ctx);
            break;
        }
        /* Print last 10 ops before limit */
        if (f->findex == JIT_DEBUG_LIMIT_FUNC && opCount >= JIT_DEBUG_LIMIT_OPS - 10) {
            printf("  Compile Op %d: op=%d p1=%d p2=%d p3=%d is_jump_target=%d\n", 
                   opCount, o->op, o->p1, o->p2, o->p3, is_jump_target[opCount]);
            if (o->op == 24) {  /* OCall0 */
                int findex = o->p2;
                int fid = findex < 0 ? -1 : ctx->m->functions_indexes[findex];
                bool isNative = fid >= ctx->m->code->nfunctions;
                printf("    OCall0: findex=%d fid=%d isNative=%d\n", findex, fid, isNative);
            }
            fflush(stdout);
        }
#endif
        
        /* If this opcode is a jump target, invalidate all register bindings.
         * This ensures we reload values from stack regardless of which path got us here.
         */
        if (is_jump_target[opCount]) {
            int j;
            for (j = 0; j < REG_COUNT; j++) {
                preg *p = &ctx->pregs[j];
                if (p->holds) {
                    p->holds->current = NULL;
                    p->holds = NULL;
                }
            }
        }
        
        /* DISABLED: Periodic register clearing didn't fix the Heaps crash */
        /* TODO: Investigate the actual root cause */
        /*
        if (f->nregs > 100) {
            discard_regs(ctx, true);
        }
        */
        
#if 0  /* Disabled compile-time trace */
        /* Compile-time trace for specific functions (no runtime overhead) */
        if ((f->findex == 6273 || f->findex == 255 || f->findex == 6212 || f->findex == 2305 || f->findex == 2321 || f->findex == 4785 || f->findex == 4753 || f->findex == 2308 || f->findex == 2309 || f->findex == 4781) && opCount < 500) {
            /* Print at compile time only */
            printf("COMPILE[findex=%d]: op[%d] = %s (p1=%d p2=%d p3=%d)\n",
                   f->findex, opCount, hl_op_name(o->op), o->p1, o->p2, o->p3);
            fflush(stdout);
        }

        /* DISABLED: Runtime instrumentation - affects crash location */
            /* Push X0-X2, X30 to stack */
            ARM64_STP_PRE_X(X0, X1, SP, -32);  /* sp -= 32, store x0,x1 */
            ARM64_STP_X(X2, X30, SP, 16);      /* store x2, x30 at sp+16 */
            
            /* Load arguments for runtime_trace_op - invalidate bindings first */
            scratch(REG_AT(X0));
            scratch(REG_AT(X1));
            scratch(REG_AT(X2));
            scratch(REG_AT(X9));
            load_imm64(ctx, X0, f->findex);            /* arg0 = findex */
            load_imm64(ctx, X1, opCount);              /* arg1 = opCount */
            load_imm64(ctx, X2, (int64_t)(intptr_t)hl_op_name(o->op)); /* arg2 = opName */
            
            /* Call runtime_trace_op */
            load_imm64(ctx, X9, (int64_t)(intptr_t)runtime_trace_op);
            ARM64_BLR(X9);
            
            /* Restore X0-X2, X30 */
            ARM64_LDP_X(X2, X30, SP, 16);
            ARM64_LDP_POST_X(X0, X1, SP, 32);
            
            /* Discard all scratch registers since the call clobbered them */
            discard_regs(ctx, true);
#endif
        
#ifdef JIT_DEBUG
        printf("op[%d]: %s p1=%d p2=%d p3=%d (nregs=%d)\n", 
               opCount, hl_op_name(o->op), o->p1, o->p2, o->p3, f->nregs);
#endif
        
        /* NOTE: Per-opcode register binding clearing was previously here but
         * was found to cause issues with code that reuses vregs across multiple
         * trace() calls. The clearing was interfering with correct register 
         * allocation tracking. Each opcode that needs clean state (like OLabel
         * for loop targets) handles its own clearing.
         */
        
        vreg *dst = (o->p1 >= 0 && o->p1 < f->nregs) ? R(o->p1) : NULL;
        vreg *ra = (o->p2 >= 0 && o->p2 < f->nregs) ? R(o->p2) : NULL;
        vreg *rb = (o->p3 >= 0 && o->p3 < f->nregs) ? R(o->p3) : NULL;
        
        ctx->currentPos = opCount + 1;
        
        switch (o->op) {
        case OMov:
        case OUnsafeCast:
            op_mov(ctx, dst, ra);
            break;
            
        case OInt:
            store_const(ctx, dst, m->code->ints[o->p2]);
            break;
            
        case OBool:
            store_const(ctx, dst, o->p2);
            break;
            
        case ONull:
            {
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, XZR);
                store(ctx, dst, pd, false);
            }
            break;
            
        case OAdd:
        case OSub:
        case OMul:
        case OSDiv:
        case OUDiv:
        case OSMod:
        case OUMod:
        case OAnd:
        case OOr:
        case OXor:
        case OShl:
        case OSShr:
        case OUShr:
            op_binop(ctx, dst, ra, rb, o->op);
            break;
            
        case ONeg:
            op_neg(ctx, dst, ra);
            break;
            
        case ONot:
            {
                preg *pa = alloc_cpu(ctx, ra, true);
                RLOCK(pa);  /* Lock before allocating dst */
                preg *pd = alloc_cpu(ctx, dst, false);
                /* Boolean NOT: if pa == 0 then 1, else 0 */
                /* CMP pa, #0; CSET pd, EQ (32-bit) */
                ARM64_CMP_IMM_W(pa->id, 0);  /* 32-bit compare */
                EMIT(0x1A9F17E0 | ((pd->id) & 0x1F)); /* CSET Wd, EQ (32-bit) */
                store(ctx, dst, pd, true);
                RUNLOCK(pa);
            }
            break;
            
        case ORet:
            op_ret(ctx, dst);
            break;
            
        case OLabel:
            /* Labels are jump targets - invalidate all register bindings
             * because the register contents may differ depending on how we got here.
             * This is especially important for loops where values change each iteration.
             */
            {
                int i;
                for (i = 0; i < REG_COUNT; i++) {
                    preg *p = &ctx->pregs[i];
                    if (p->holds) {
                        p->holds->current = NULL;
                        p->holds = NULL;
                    }
                }
            }
            break;
            
        case OJAlways:
            {
                int jpos = BUF_POS();
                ARM64_B(0); /* Placeholder */
                add_jump(ctx, jpos, opCount + 1 + o->p1);
            }
            break;
            
        case OJTrue:
        case OJFalse:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                ARM64_CMP_IMM_X(pd->id, 0);
                int jpos = BUF_POS();
                ARM64_B_COND(o->op == OJTrue ? COND_NE : COND_EQ, 0);
                add_jump(ctx, jpos, opCount + 1 + o->p2);
            }
            break;
            
        case OJNull:
        case OJNotNull:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                ARM64_CMP_IMM_X(pd->id, 0);
                int jpos = BUF_POS();
                ARM64_B_COND(o->op == OJNull ? COND_EQ : COND_NE, 0);
                add_jump(ctx, jpos, opCount + 1 + o->p2);
            }
            break;
            
        case OJEq:
        case OJNotEq:
            {
                /* Handle nullable (HNULL) types specially - they're boxed values */
                if (dst->t->kind == HNULL) {
                    /* Nullable comparison: a == b if (a == b) || (a && b && *a == *b) */
                    preg *pa = alloc_cpu(ctx, dst, true);
                    RLOCK(pa);
                    preg *pb = alloc_cpu(ctx, ra, true);
                    RLOCK(pb);
                    
                    if (o->op == OJEq) {
                        /* For OJEq: jump if a == b OR (a != null AND b != null AND values equal) */
                        /* First check: if pointers are equal, jump to target */
                        ARM64_CMP_X(pa->id, pb->id);
                        int jptr_eq = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to target later */
                        
                        /* If a is null, don't jump (values can't be equal) */
                        ARM64_CMP_IMM_X(pa->id, 0);
                        int ja_null = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to skip */
                        
                        /* If b is null, don't jump */
                        ARM64_CMP_IMM_X(pb->id, 0);
                        int jb_null = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to skip */
                        
                        /* Both non-null, compare values at offset 8 (HDYN_VALUE) */
                        hl_type *inner = dst->t->tparam;
                        int valSize = hl_type_size(inner);
                        preg *tmp = alloc_reg(ctx, RCPU);
                        preg *tmp2 = alloc_reg(ctx, RCPU);
                        
                        if (valSize <= 4) {
                            ARM64_LDR_W(tmp->id, pa->id, 8);
                            ARM64_LDR_W(tmp2->id, pb->id, 8);
                            ARM64_CMP_W(tmp->id, tmp2->id);
                        } else {
                            ARM64_LDR_X(tmp->id, pa->id, 8);
                            ARM64_LDR_X(tmp2->id, pb->id, 8);
                            ARM64_CMP_X(tmp->id, tmp2->id);
                        }
                        
                        int jval_eq = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to target */
                        
                        /* Fall through: not equal */
                        int skip_pos = BUF_POS();
                        
                        /* Patch ja_null and jb_null to here */
                        unsigned int *pja = (unsigned int *)(ctx->startBuf + ja_null);
                        *pja = (*pja & 0xFF00001F) | ((((skip_pos - ja_null) >> 2) & 0x7FFFF) << 5);
                        unsigned int *pjb = (unsigned int *)(ctx->startBuf + jb_null);
                        *pjb = (*pjb & 0xFF00001F) | ((((skip_pos - jb_null) >> 2) & 0x7FFFF) << 5);
                        
                        /* Patch jptr_eq and jval_eq to jump target */
                        add_jump(ctx, jptr_eq, opCount + 1 + o->p3);
                        add_jump(ctx, jval_eq, opCount + 1 + o->p3);
                    } else {
                        /* For OJNotEq: jump if a != b AND (a == null OR b == null OR values differ) */
                        /* First check: if pointers are equal, don't jump */
                        ARM64_CMP_X(pa->id, pb->id);
                        int jptr_eq = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to skip */
                        
                        /* If a is null (and b isn't, since ptrs differ), jump */
                        ARM64_CMP_IMM_X(pa->id, 0);
                        int ja_null = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to target */
                        
                        /* If b is null, jump */
                        ARM64_CMP_IMM_X(pb->id, 0);
                        int jb_null = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0); /* Will patch to target */
                        
                        /* Both non-null, compare values */
                        hl_type *inner = dst->t->tparam;
                        int valSize = hl_type_size(inner);
                        preg *tmp = alloc_reg(ctx, RCPU);
                        preg *tmp2 = alloc_reg(ctx, RCPU);
                        
                        if (valSize <= 4) {
                            ARM64_LDR_W(tmp->id, pa->id, 8);
                            ARM64_LDR_W(tmp2->id, pb->id, 8);
                            ARM64_CMP_W(tmp->id, tmp2->id);
                        } else {
                            ARM64_LDR_X(tmp->id, pa->id, 8);
                            ARM64_LDR_X(tmp2->id, pb->id, 8);
                            ARM64_CMP_X(tmp->id, tmp2->id);
                        }
                        
                        int jval_ne = BUF_POS();
                        ARM64_B_COND(COND_NE, 0); /* Will patch to target */
                        
                        /* Fall through: equal */
                        int skip_pos = BUF_POS();
                        
                        /* Patch jptr_eq to here */
                        unsigned int *pjptr = (unsigned int *)(ctx->startBuf + jptr_eq);
                        *pjptr = (*pjptr & 0xFF00001F) | ((((skip_pos - jptr_eq) >> 2) & 0x7FFFF) << 5);
                        
                        /* Patch ja_null, jb_null, jval_ne to jump target */
                        add_jump(ctx, ja_null, opCount + 1 + o->p3);
                        add_jump(ctx, jb_null, opCount + 1 + o->p3);
                        add_jump(ctx, jval_ne, opCount + 1 + o->p3);
                    }
                    
                    RUNLOCK(pa);
                    RUNLOCK(pb);
                    break;
                }
                /* Fall through for non-nullable types */
            }
            /* fall through */
        case OJSLt:
        case OJSGte:
        case OJSGt:
        case OJSLte:
        case OJULt:
        case OJUGte:
            {
                /* Check for dynamic types - need to call hl_dyn_compare */
                if (dst->t->kind == HDYN || ra->t->kind == HDYN || 
                    dst->t->kind == HFUN || ra->t->kind == HFUN) {
                    /* Call hl_dyn_compare(a, b) - returns int: <0, 0, >0 */
                    preg *pa = alloc_cpu(ctx, dst, true);
                    RLOCK(pa);  /* Lock pa before allocating pb to prevent spilling */
                    preg *pb = alloc_cpu(ctx, ra, true);
                    
                    scratch(REG_AT(X0));
                    scratch(REG_AT(X1));
                    
                    /* Handle register clobbering - same logic as HOBJ comparison */
                    if (pa->id == X0 && pb->id == X1) {
                        /* Already in correct positions */
                    } else if (pa->id == X1 && pb->id == X0) {
                        /* Swap using XOR */
                        ARM64_EOR_X(X0, X0, X1);
                        ARM64_EOR_X(X1, X1, X0);
                        ARM64_EOR_X(X0, X0, X1);
                    } else if (pa->id == X1) {
                        ARM64_MOV_X(X0, pa->id);
                        ARM64_MOV_X(X1, pb->id);
                    } else if (pb->id == X0) {
                        ARM64_MOV_X(X1, pb->id);
                        ARM64_MOV_X(X0, pa->id);
                    } else {
                        ARM64_MOV_X(X0, pa->id);
                        ARM64_MOV_X(X1, pb->id);
                    }
                    
                    RUNLOCK(pa);  /* Unlock after we've used pa->id */
                    
                    call_native(ctx, hl_dyn_compare, 0);
                    
                    /* Result is in X0 (W0 for 32-bit result) */
                    /* For OJEq: jump if result == 0 */
                    /* For OJNotEq: jump if result != 0 */
                    /* For OJSLt: jump if result < 0 */
                    /* For OJSGte: jump if result >= 0 */
                    /* For OJSGt: jump if result > 0 */
                    /* For OJSLte: jump if result <= 0 */
                    
                    /* Handle hl_invalid_comparison for OJSGt/OJSGte */
                    if (o->op == OJSGt || o->op == OJSGte) {
                        /* Check if result == hl_invalid_comparison, if so don't jump */
                        preg *tmp = alloc_reg(ctx, RCPU);
                        load_imm64(ctx, tmp->id, hl_invalid_comparison);
                        ARM64_CMP_W(X0, tmp->id);
                        int jinvalid = BUF_POS();
                        ARM64_B_COND(COND_EQ, 0);  /* Skip if invalid */
                        
                        /* Test result against 0 */
                        ARM64_CMP_IMM_W(X0, 0);
                        ArmCond cond = (o->op == OJSGt) ? COND_GT : COND_GE;
                        int jpos = BUF_POS();
                        ARM64_B_COND(cond, 0);
                        add_jump(ctx, jpos, opCount + 1 + o->p3);
                        
                        /* Patch invalid jump to here */
                        int skip_pos = BUF_POS();
                        unsigned int *pj = (unsigned int *)(ctx->startBuf + jinvalid);
                        *pj = (*pj & 0xFF00001F) | ((((skip_pos - jinvalid) >> 2) & 0x7FFFF) << 5);
                    } else {
                        /* Test result against 0 */
                        ARM64_CMP_IMM_W(X0, 0);
                        
                        ArmCond cond;
                        switch (o->op) {
                        case OJEq: cond = COND_EQ; break;
                        case OJNotEq: cond = COND_NE; break;
                        case OJSLt: cond = COND_LT; break;
                        case OJSGte: cond = COND_GE; break;
                        case OJSGt: cond = COND_GT; break;
                        case OJSLte: cond = COND_LE; break;
                        case OJULt: cond = COND_CC; break;
                        case OJUGte: cond = COND_CS; break;
                        default: cond = COND_AL; break;
                        }
                        
                        int jpos = BUF_POS();
                        ARM64_B_COND(cond, 0);
                        add_jump(ctx, jpos, opCount + 1 + o->p3);
                    }
                    break;
                }
                
                /* Check for HOBJ/HSTRUCT with compareFun (e.g., String comparison) 
                 * We use jit_obj_compare which resolves compareFun at runtime,
                 * since at JIT compile time the compareFun might not be fully initialized.
                 */
                if ((dst->t->kind == HOBJ || dst->t->kind == HSTRUCT) &&
                    hl_get_obj_rt(dst->t)->compareFun) {
                    /* Call jit_obj_compare(a, b) - returns int: <0, 0, >0 */
                    preg *pa = alloc_cpu(ctx, dst, true);
                    RLOCK(pa);  /* Lock pa before allocating pb to prevent spilling */
                    preg *pb = alloc_cpu(ctx, ra, true);
                    
                    /* Set up call arguments, being careful about register clobbering.
                     * We need to move pa to X0 and pb to X1 without clobbering.
                     */
                    scratch(REG_AT(X0));
                    scratch(REG_AT(X1));
                    
                    if (pa->id == X0 && pb->id == X1) {
                        /* Already in correct positions - no moves needed */
                    } else if (pa->id == X1 && pb->id == X0) {
                        /* Swap: pa is in X1 (want in X0), pb is in X0 (want in X1) 
                         * Use XOR swap to avoid needing a temp */
                        ARM64_EOR_X(X0, X0, X1);  /* X0 = X0 ^ X1 */
                        ARM64_EOR_X(X1, X1, X0);  /* X1 = X1 ^ (X0^X1) = X0 */
                        ARM64_EOR_X(X0, X0, X1);  /* X0 = (X0^X1) ^ X0 = X1 */
                    } else if (pa->id == X1) {
                        /* pa is in X1 - save it before moving pb to X1 */
                        ARM64_MOV_X(X0, pa->id);   /* X0 = pa (move first) */
                        ARM64_MOV_X(X1, pb->id);   /* X1 = pb */
                    } else if (pb->id == X0) {
                        /* pb is in X0 - save it before moving pa to X0 */
                        ARM64_MOV_X(X1, pb->id);   /* X1 = pb (move first) */
                        ARM64_MOV_X(X0, pa->id);   /* X0 = pa */
                    } else {
                        /* Normal case - no conflicts */
                        ARM64_MOV_X(X0, pa->id);
                        ARM64_MOV_X(X1, pb->id);
                    }
                    
                    RUNLOCK(pa);  /* Unlock after we've used pa->id */
                    
                    /* Call jit_obj_compare which handles null checks and resolves compareFun */
                    call_native(ctx, (void*)jit_obj_compare, 0);
                    
                    /* Test result against 0 */
                    ARM64_CMP_IMM_W(X0, 0);
                    
                    ArmCond cond;
                    switch (o->op) {
                    case OJEq: cond = COND_EQ; break;
                    case OJNotEq: cond = COND_NE; break;
                    case OJSLt: cond = COND_LT; break;
                    case OJSGte: cond = COND_GE; break;
                    case OJSGt: cond = COND_GT; break;
                    case OJSLte: cond = COND_LE; break;
                    default: cond = COND_AL; break;
                    }
                    
                    int jpos = BUF_POS();
                    ARM64_B_COND(cond, 0);
                    add_jump(ctx, jpos, opCount + 1 + o->p3);
                    break;
                }
                
                /* Handle float comparisons - use FCMP instead of CMP */
                if (IS_FLOAT(dst)) {
                    preg *pa = alloc_fpu(ctx, dst, true);
                    RLOCK(pa);
                    preg *pb = alloc_fpu(ctx, ra, true);
                    
                    /* FCMP Dn, Dm or FCMP Sn, Sm */
                    if (dst->t->kind == HF64)
                        EMIT(0x1E602000 | ((pb->id) << 16) | ((pa->id) << 5)); /* FCMP Dn, Dm */
                    else
                        EMIT(0x1E202000 | ((pb->id) << 16) | ((pa->id) << 5)); /* FCMP Sn, Sm */
                    RUNLOCK(pa);
                    
                    /* FCMP sets: N,Z,C,V flags
                     * For ordered comparison (no NaN):
                     *   a < b:  N=1, Z=0, C=0, V=0
                     *   a == b: N=0, Z=1, C=1, V=0
                     *   a > b:  N=0, Z=0, C=1, V=0
                     * For unordered (NaN): V=1, C=1, Z=0, N=0
                     */
                    ArmCond cond;
                    switch (o->op) {
                    case OJEq: cond = COND_EQ; break;      /* Z=1 */
                    case OJNotEq: cond = COND_NE; break;   /* Z=0 */
                    case OJSLt: cond = COND_MI; break;     /* N=1 (less than) */
                    case OJSGte: cond = COND_GE; break;    /* N==V (greater or equal) */
                    case OJSGt: cond = COND_GT; break;     /* Z=0 and N==V */
                    case OJSLte: cond = COND_LE; break;    /* Z=1 or N!=V */
                    default: cond = COND_AL; break;
                    }
                    
                    int jpos = BUF_POS();
                    ARM64_B_COND(cond, 0);
                    add_jump(ctx, jpos, opCount + 1 + o->p3);
                    break;
                }
                
                /* p1 = reg a, p2 = reg b, p3 = jump offset */
                preg *pa = alloc_cpu(ctx, dst, true);  /* dst = R(p1) */
                RLOCK(pa);
                preg *pb = alloc_cpu(ctx, ra, true);   /* ra = R(p2) */
                /* Use 32-bit or 64-bit comparison based on operand size */
                if (dst->size == 4 || ra->size == 4) {
                    ARM64_CMP_W(pa->id, pb->id);
                } else {
                    ARM64_CMP_X(pa->id, pb->id);
                }
                RUNLOCK(pa);
                
                ArmCond cond;
                switch (o->op) {
                case OJEq: cond = COND_EQ; break;
                case OJNotEq: cond = COND_NE; break;
                case OJSLt: cond = COND_LT; break;
                case OJSGte: cond = COND_GE; break;
                case OJSGt: cond = COND_GT; break;
                case OJSLte: cond = COND_LE; break;
                case OJULt: cond = COND_CC; break;
                case OJUGte: cond = COND_CS; break;
                default: cond = COND_AL; break;
                }
                
                int jpos = BUF_POS();
                ARM64_B_COND(cond, 0);
                add_jump(ctx, jpos, opCount + 1 + o->p3);
            }
            break;
            
        /* Float comparisons with NaN handling */
        case OJNotLt:
        case OJNotGte:
            {
                /* For floats, these handle NaN cases */
                /* FCMP sets: N,Z,C,V flags. V=1 means unordered (NaN) */
                /* JNotLt: jump if NOT (a < b), i.e., a >= b OR unordered */
                /* JNotGte: jump if NOT (a >= b), i.e., a < b OR unordered */
                /* p1 = reg a, p2 = reg b, p3 = jump offset */
                if (IS_FLOAT(dst)) {
                    preg *pa = alloc_fpu(ctx, dst, true);
                    RLOCK(pa);
                    preg *pb = alloc_fpu(ctx, ra, true);
                    RLOCK(pb);  /* Lock pb too */
                    
                    if (ra->t->kind == HF64)
                        EMIT(0x1E602000 | ((pb->id) << 16) | ((pa->id) << 5)); /* FCMP Dn, Dm */
                    else
                        EMIT(0x1E202000 | ((pb->id) << 16) | ((pa->id) << 5)); /* FCMP Sn, Sm */
                    RUNLOCK(pa);
                    RUNLOCK(pb);  /* Unlock pb */
                    
                    ArmCond cond;
                    if (o->op == OJNotLt)
                        cond = COND_PL; /* N=0: not less than (includes unordered via VS) */
                    else
                        cond = COND_LT; /* N=1: less than */
                    
                    /* For NaN handling, we need to also check unordered (VS) */
                    int jpos = BUF_POS();
                    if (o->op == OJNotLt) {
                        /* Jump if >= or unordered: use GE which handles this */
                        ARM64_B_COND(COND_GE, 0);
                    } else {
                        /* Jump if < or unordered: use LT or VS */
                        ARM64_B_COND(COND_LT, 0);
                    }
                    add_jump(ctx, jpos, opCount + 1 + o->p3);
                    
                    /* Also jump on unordered (VS) */
                    int jvs = BUF_POS();
                    ARM64_B_COND(COND_VS, 0);
                    add_jump(ctx, jvs, opCount + 1 + o->p3);
                } else {
                    /* Integer version - same as regular comparisons */
                    /* p1 = reg a, p2 = reg b, p3 = jump offset */
                    preg *pa = alloc_cpu(ctx, dst, true);
                    RLOCK(pa);
                    preg *pb = alloc_cpu(ctx, ra, true);
                    ARM64_CMP_X(pa->id, pb->id);
                    RUNLOCK(pa);
                    
                    ArmCond cond = (o->op == OJNotLt) ? COND_GE : COND_LT;
                    int jpos = BUF_POS();
                    ARM64_B_COND(cond, 0);
                    add_jump(ctx, jpos, opCount + 1 + o->p3);
                }
            }
            break;
            
        case OIncr:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                if (dst->size == 4) {
                    /* 32-bit increment */
                    ARM64_ADD_IMM_W(pd->id, pd->id, 1);
                } else {
                    ARM64_ADD_IMM_X(pd->id, pd->id, 1);
                }
                store(ctx, dst, pd, false);
            }
            break;
            
        case ODecr:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                if (dst->size == 4) {
                    /* 32-bit decrement */
                    ARM64_SUB_IMM_W(pd->id, pd->id, 1);
                } else {
                    ARM64_SUB_IMM_X(pd->id, pd->id, 1);
                }
                store(ctx, dst, pd, false);
            }
            break;
            
        case ONop:
            ARM64_NOP();
            break;
            
        /* Function calls */
        case OCall0:
            op_call_fun(ctx, dst, o->p2, 0, NULL);
            break;
            
        case OCall1:
            op_call_fun(ctx, dst, o->p2, 1, &o->p3);
            break;
            
        case OCall2:
            {
                int args[2] = { o->p3, (int)(intptr_t)o->extra };
                op_call_fun(ctx, dst, o->p2, 2, args);
            }
            break;
            
        case OCall3:
            {
                int args[3] = { o->p3, o->extra[0], o->extra[1] };
                op_call_fun(ctx, dst, o->p2, 3, args);
            }
            break;
            
        case OCall4:
            {
                int args[4] = { o->p3, o->extra[0], o->extra[1], o->extra[2] };
                op_call_fun(ctx, dst, o->p2, 4, args);
            }
            break;
            
        case OCallN:
            op_call_fun(ctx, dst, o->p2, o->p3, o->extra);
            break;
            
        /* Global access */
        case OGetGlobal:
            op_get_global(ctx, dst, o->p2);
            break;
            
        case OSetGlobal:
            op_set_global(ctx, o->p1, ra);
            break;
            
        /* Field access */
        case OField:
            op_get_field(ctx, dst, ra, o->p3);
            break;
            
        case OSetField:
            op_set_field(ctx, dst, o->p2, rb);
            break;
            
        /* Object allocation */
        case ONew:
            {
                void *allocFun = NULL;
                int nargs = 1;
                
                switch (dst->t->kind) {
                case HOBJ:
                case HSTRUCT:
                    allocFun = hl_alloc_obj;
                    break;
                case HDYNOBJ:
                    allocFun = hl_alloc_dynobj;
                    nargs = 0;
                    break;
                case HVIRTUAL:
                    allocFun = hl_alloc_virtual;
                    break;
                default:
                    ARM64_BRK(0xADD);
                    break;
                }
                
                if (allocFun) {
                    /* Discard all registers before setting up call to ensure clean state */
                    discard_regs(ctx, false);
                    
                    if (nargs > 0) {
                        /* Load type pointer as first argument */
                        load_imm64(ctx, X0, (int64_t)(intptr_t)dst->t);
                    }
                    
                    call_native(ctx, allocFun, 0);
                    
                    /* Save result to X20 (callee-saved) before alloc_cpu might clobber X0 */
                    ARM64_MOV_X(X20, X0);
                    
                    /* Store result - X20 still valid */
                    preg *pd = alloc_cpu(ctx, dst, false);
                    ARM64_MOV_X(pd->id, X20);
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        /* Float constant */
        case OFloat:
            {
                double dval = m->code->floats[o->p2];
                if (dval == 0.0) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    /* FMOV Vd, #0 - use MOVI for zero */
                    if (dst->t->kind == HF32)
                        EMIT(0x0F000400 | ((pd->id) & 0x1F)); /* MOVI Vd.2S, #0 */
                    else
                        EMIT(0x2F00E400 | ((pd->id) & 0x1F)); /* MOVI Vd.2D, #0 */
                    store(ctx, dst, pd, true);
                } else {
                    /* Load float from constant pool via address */
                    preg *tmp = alloc_reg(ctx, RCPU);
                    RLOCK(tmp);  /* Lock before alloc_fpu might reuse it */
                    load_imm64(ctx, tmp->id, (int64_t)(intptr_t)&m->code->floats[o->p2]);
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, tmp->id, 0);
                    else
                        ARM64_LDR_S(pd->id, tmp->id, 0);
                    store(ctx, dst, pd, true);
                    RUNLOCK(tmp);
                }
            }
            break;
            
        /* String constant */
        case OString:
            {
                const uchar *str = hl_get_ustring(m->code, o->p2);
                preg *pd = alloc_cpu(ctx, dst, false);
                load_imm64(ctx, pd->id, (int64_t)(intptr_t)str);
                store(ctx, dst, pd, false);
            }
            break;
            
        /* Bytes constant */
        case OBytes:
            {
                char *b = m->code->version >= 5 ? 
                    m->code->bytes + m->code->bytes_pos[o->p2] : 
                    m->code->strings[o->p2];
                preg *pd = alloc_cpu(ctx, dst, false);
                load_imm64(ctx, pd->id, (int64_t)(intptr_t)b);
                store(ctx, dst, pd, false);
            }
            break;
            
        /* Type operations */
        case OType:
            {
                hl_type *t = m->code->types + o->p2;
                preg *pd = alloc_cpu(ctx, dst, false);
#ifdef JIT_DEBUG
                printf("OType: vreg=%d, dst->stackPos=%d, type=%p (kind=%d), pd=X%d\n",
                       o->p1, dst->stackPos, (void*)t, t->kind, pd->id);
#endif
                load_imm64(ctx, pd->id, (int64_t)(intptr_t)t);
                store(ctx, dst, pd, false);
            }
            break;
            
        /* Null check */
        case ONullCheck:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                ARM64_CMP_IMM_X(pd->id, 0);
                /* Branch over the error if not null */
                int jpos = BUF_POS();
                ARM64_B_COND(COND_NE, 0);  /* Placeholder - will patch */
                
                /* Null case - call hl_null_access() which throws an exception */
                call_native(ctx, hl_null_access, 0);
                /* hl_null_access doesn't return, but emit unreachable BRK */
                ARM64_BRK(0xDEAD);
                
                /* Patch the branch to skip to here */
                int end_pos = BUF_POS();
                unsigned int *pj = (unsigned int *)(ctx->startBuf + jpos);
                *pj = (*pj & 0xFF00001F) | ((((end_pos - jpos) >> 2) & 0x7FFFF) << 5);
            }
            break;
            
        /* Array operations */
        case OArraySize:
            {
                preg *pa = alloc_cpu(ctx, ra, true);
                preg *pd = alloc_cpu(ctx, dst, false);
                /* Array size is at offset 16 in varray structure:
                 * struct { hl_type *t; hl_type *at; int size; int __pad; }
                 * t is 8 bytes, at is 8 bytes, so size is at offset 16 */
                ARM64_LDR_W(pd->id, pa->id, 16);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OGetArray:
            {
                preg *parr = alloc_cpu(ctx, ra, true);
                RLOCK(parr);  /* Lock to prevent reuse */
                preg *pidx = alloc_cpu(ctx, rb, true);
                RLOCK(pidx);  /* Lock to prevent reuse */
                int elemSize = hl_type_size(dst->t);
                
                /* Calculate element address: arr + sizeof(varray) + idx * elemSize */
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after element load */
                
                if (elemSize == 8) {
                    /* LSL by 3 for 8-byte elements */
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 3);
                } else if (elemSize == 4) {
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 2);
                } else if (elemSize == 2) {
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 1);
                } else {
                    ARM64_MOV_X(tmp->id, pidx->id);
                }
                
                /* Add base address + varray header */
                ARM64_ADD_IMM_X(tmp->id, tmp->id, sizeof(varray));
                ARM64_ADD_X(tmp->id, parr->id, tmp->id);
                RUNLOCK(parr);
                RUNLOCK(pidx);
                
                /* Load element */
                if (IS_FLOAT(dst)) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, tmp->id, 0);
                    else
                        ARM64_LDR_S(pd->id, tmp->id, 0);
                    store(ctx, dst, pd, true);
                } else {
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (elemSize == 8)
                        ARM64_LDR_X(pd->id, tmp->id, 0);
                    else if (elemSize == 4)
                        ARM64_LDR_W(pd->id, tmp->id, 0);
                    else if (elemSize == 2)
                        EMIT(0x79400000 | ((tmp->id) << 5) | (pd->id)); /* LDRH */
                    else
                        EMIT(0x39400000 | ((tmp->id) << 5) | (pd->id)); /* LDRB */
                    store(ctx, dst, pd, true);
                }
                RUNLOCK(tmp);
            }
            break;
            
        case OSetArray:
            {
                preg *parr = alloc_cpu(ctx, dst, true);
                RLOCK(parr);  /* Lock to prevent reuse */
                preg *pidx = alloc_cpu(ctx, ra, true);
                RLOCK(pidx);  /* Lock to prevent reuse */
                int elemSize = hl_type_size(rb->t);
                
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after store */
                
                if (elemSize == 8) {
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 3);
                } else if (elemSize == 4) {
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 2);
                } else if (elemSize == 2) {
                    ARM64_LSL_IMM_X(tmp->id, pidx->id, 1);
                } else {
                    ARM64_MOV_X(tmp->id, pidx->id);
                }
                
                ARM64_ADD_IMM_X(tmp->id, tmp->id, sizeof(varray));
                ARM64_ADD_X(tmp->id, parr->id, tmp->id);
                RUNLOCK(parr);
                RUNLOCK(pidx);
                
                /* Store element */
                if (IS_FLOAT(rb)) {
                    preg *ps = alloc_fpu(ctx, rb, true);
                    if (rb->t->kind == HF64)
                        ARM64_STR_D(ps->id, tmp->id, 0);
                    else
                        ARM64_STR_S(ps->id, tmp->id, 0);
                } else {
                    preg *ps = alloc_cpu(ctx, rb, true);
                    if (elemSize == 8)
                        ARM64_STR_X(ps->id, tmp->id, 0);
                    else if (elemSize == 4)
                        ARM64_STR_W(ps->id, tmp->id, 0);
                    else if (elemSize == 2)
                        EMIT(0x79000000 | ((tmp->id) << 5) | (ps->id)); /* STRH */
                    else
                        EMIT(0x39000000 | ((tmp->id) << 5) | (ps->id)); /* STRB */
                }
                RUNLOCK(tmp);
            }
            break;
            
        /* Memory access: bytes/pointers */
        case OGetI8:
            {
                preg *pbase = alloc_cpu(ctx, ra, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, rb, true);
                RLOCK(poff);
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after load */
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                preg *pd = alloc_cpu(ctx, dst, false);
                /* LDRB - load unsigned byte (not LDRSB which sign-extends) */
                EMIT(0x39400000 | ((tmp->id) << 5) | (pd->id));
                store(ctx, dst, pd, true);
                RUNLOCK(tmp);
            }
            break;
            
        case OSetI8:
            {
                preg *pbase = alloc_cpu(ctx, dst, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, ra, true);
                RLOCK(poff);
                preg *pval = alloc_cpu(ctx, rb, true);
                preg *tmp = alloc_reg(ctx, RCPU);
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                EMIT(0x39000000 | ((tmp->id) << 5) | (pval->id)); /* STRB */
                RUNLOCK(tmp);
            }
            break;
            
        case OGetI16:
            {
                preg *pbase = alloc_cpu(ctx, ra, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, rb, true);
                RLOCK(poff);
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after load */
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                preg *pd = alloc_cpu(ctx, dst, false);
                /* LDRSH - load signed halfword */
                EMIT(0x79C00000 | ((tmp->id) << 5) | (pd->id));
                store(ctx, dst, pd, true);
                RUNLOCK(tmp);
            }
            break;
            
        case OSetI16:
            {
                preg *pbase = alloc_cpu(ctx, dst, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, ra, true);
                RLOCK(poff);
                preg *pval = alloc_cpu(ctx, rb, true);
                preg *tmp = alloc_reg(ctx, RCPU);
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                EMIT(0x79000000 | ((tmp->id) << 5) | (pval->id)); /* STRH */
                RUNLOCK(tmp);
            }
            break;
            
        case OGetMem:
            {
                preg *pbase = alloc_cpu(ctx, ra, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, rb, true);
                RLOCK(poff);
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after load */
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                
                if (IS_FLOAT(dst)) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, tmp->id, 0);
                    else
                        ARM64_LDR_S(pd->id, tmp->id, 0);
                    store(ctx, dst, pd, true);
                } else {
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (dst->size == 8)
                        ARM64_LDR_X(pd->id, tmp->id, 0);
                    else if (dst->size == 1)
                        ARM64_LDRB(pd->id, tmp->id, 0);
                    else
                        ARM64_LDR_W(pd->id, tmp->id, 0);
                    store(ctx, dst, pd, true);
                }
                RUNLOCK(tmp);
            }
            break;
            
        case OSetMem:
            {
                preg *pbase = alloc_cpu(ctx, dst, true);
                RLOCK(pbase);
                preg *poff = alloc_cpu(ctx, ra, true);
                RLOCK(poff);
                preg *tmp = alloc_reg(ctx, RCPU);
                RLOCK(tmp);  /* Lock tmp - needed until after store */
                ARM64_ADD_X(tmp->id, pbase->id, poff->id);
                RUNLOCK(pbase);
                RUNLOCK(poff);
                
                if (IS_FLOAT(rb)) {
                    preg *ps = alloc_fpu(ctx, rb, true);
                    if (rb->t->kind == HF64)
                        ARM64_STR_D(ps->id, tmp->id, 0);
                    else
                        ARM64_STR_S(ps->id, tmp->id, 0);
                } else {
                    preg *ps = alloc_cpu(ctx, rb, true);
                    if (rb->size == 8)
                        ARM64_STR_X(ps->id, tmp->id, 0);
                    else if (rb->size == 1)
                        ARM64_STRB(ps->id, tmp->id, 0);
                    else
                        ARM64_STR_W(ps->id, tmp->id, 0);
                }
                RUNLOCK(tmp);
            }
            break;
            
        /* Type conversions */
        case OToSFloat:
            if (ra != dst) {
                if (ra->t->kind == HI32 || ra->t->kind == HUI16 || ra->t->kind == HUI8) {
                    preg *pr = alloc_cpu(ctx, ra, true);
                    preg *pd = alloc_fpu(ctx, dst, false);
                    /* SCVTF - signed convert to float */
                    if (dst->t->kind == HF64)
                        EMIT(0x1E620000 | ((pr->id) << 5) | (pd->id)); /* SCVTF Dd, Wn */
                    else
                        EMIT(0x1E220000 | ((pr->id) << 5) | (pd->id)); /* SCVTF Sd, Wn */
                    store(ctx, dst, pd, true);
                } else if (ra->t->kind == HI64) {
                    preg *pr = alloc_cpu(ctx, ra, true);
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        EMIT(0x9E620000 | ((pr->id) << 5) | (pd->id)); /* SCVTF Dd, Xn */
                    else
                        EMIT(0x9E220000 | ((pr->id) << 5) | (pd->id)); /* SCVTF Sd, Xn */
                    store(ctx, dst, pd, true);
                } else if (ra->t->kind == HF64 && dst->t->kind == HF32) {
                    preg *pr = alloc_fpu(ctx, ra, true);
                    preg *pd = alloc_fpu(ctx, dst, false);
                    EMIT(0x1E624000 | ((pr->id) << 5) | (pd->id)); /* FCVT Sd, Dn */
                    store(ctx, dst, pd, true);
                } else if (ra->t->kind == HF32 && dst->t->kind == HF64) {
                    preg *pr = alloc_fpu(ctx, ra, true);
                    preg *pd = alloc_fpu(ctx, dst, false);
                    EMIT(0x1E22C000 | ((pr->id) << 5) | (pd->id)); /* FCVT Dd, Sn */
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        case OToUFloat:
            if (ra != dst) {
                preg *pr = alloc_cpu(ctx, ra, true);
                preg *pd = alloc_fpu(ctx, dst, false);
                /* UCVTF - unsigned convert to float */
                if (ra->t->kind == HI64) {
                    if (dst->t->kind == HF64)
                        EMIT(0x9E630000 | ((pr->id) << 5) | (pd->id));
                    else
                        EMIT(0x9E230000 | ((pr->id) << 5) | (pd->id));
                } else {
                    if (dst->t->kind == HF64)
                        EMIT(0x1E630000 | ((pr->id) << 5) | (pd->id));
                    else
                        EMIT(0x1E230000 | ((pr->id) << 5) | (pd->id));
                }
                store(ctx, dst, pd, true);
            }
            break;
            
        case OToInt:
            if (ra != dst) {
                if (ra->t->kind == HF64 || ra->t->kind == HF32) {
                    preg *pr = alloc_fpu(ctx, ra, true);
                    preg *pd = alloc_cpu(ctx, dst, false);
                    /* FCVTZS - convert to signed int, round towards zero */
                    if (ra->t->kind == HF64)
                        EMIT(0x9E780000 | ((pr->id) << 5) | (pd->id)); /* FCVTZS Xd, Dn */
                    else
                        EMIT(0x1E380000 | ((pr->id) << 5) | (pd->id)); /* FCVTZS Wd, Sn */
                    store(ctx, dst, pd, true);
                } else {
                    /* Integer to integer conversion */
                    preg *pr = alloc_cpu(ctx, ra, true);
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (dst->t->kind == HI64 && ra->t->kind == HI32) {
                        /* Sign extend 32 to 64 */
                        EMIT(0x93407C00 | ((pr->id) << 5) | (pd->id)); /* SXTW */
                    } else {
                        ARM64_MOV_X(pd->id, pr->id);
                    }
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        /* Reference operations */
        case ORef:
            {
                /* Get address of stack variable.
                 * CRITICAL: Must spill ra to stack first! The value may be in an
                 * FPU/CPU register but not yet written to its stack slot. If we just
                 * take the stack address without spilling, the pointer would point
                 * to stale/zero data.
                 */
                if (ra->current != NULL && ra->current->holds == ra) {
                    copy_to_stack(ctx, &ra->stack, ra->current, ra->size);
                }
                /* Now scratch the binding since someone may modify via pointer */
                scratch(ra->current);
                preg *pd = alloc_cpu(ctx, dst, false);
                int offset = ra->stackPos;
                if (offset >= 0) {
                    add_large_imm(ctx, pd->id, FP, offset, X9);
                } else {
                    sub_large_imm(ctx, pd->id, FP, -offset, X9);
                }
                store(ctx, dst, pd, false);
            }
            break;
            
        case OUnref:
            {
                preg *pr = alloc_cpu(ctx, ra, true);
                if (IS_FLOAT(dst)) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, pr->id, 0);
                    else
                        ARM64_LDR_S(pd->id, pr->id, 0);
                    store(ctx, dst, pd, true);
                } else {
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (dst->size == 8)
                        ARM64_LDR_X(pd->id, pr->id, 0);
                    else if (dst->size == 1)
                        ARM64_LDRB(pd->id, pr->id, 0);
                    else
                        ARM64_LDR_W(pd->id, pr->id, 0);
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        case OSetref:
            {
                preg *pd = alloc_cpu(ctx, dst, true);
                if (IS_FLOAT(ra)) {
                    preg *ps = alloc_fpu(ctx, ra, true);
                    if (ra->t->kind == HF64)
                        ARM64_STR_D(ps->id, pd->id, 0);
                    else
                        ARM64_STR_S(ps->id, pd->id, 0);
                } else {
                    preg *ps = alloc_cpu(ctx, ra, true);
                    if (ra->size == 8)
                        ARM64_STR_X(ps->id, pd->id, 0);
                    else if (ra->size == 1)
                        ARM64_STRB(ps->id, pd->id, 0);
                    else
                        ARM64_STR_W(ps->id, pd->id, 0);
                }
            }
            break;
            
        /* Closures */
        case OStaticClosure:
            {
                /* Allocate and initialize a static closure */
                hl_module *m = ctx->m;
                int findex = o->p2;
                int fidx = m->functions_indexes[findex];
                vclosure *c = (vclosure *)hl_malloc(&m->ctx.alloc, sizeof(vclosure));
                c->hasValue = 0;
                
                if (fidx < 0) {
                    jit_error("OStaticClosure: invalid function index");
                } else if (fidx >= m->code->nfunctions) {
                    /* Native function - already resolved */
                    c->t = m->code->natives[fidx - m->code->nfunctions].t;
                    c->fun = m->functions_ptrs[findex];
                    c->value = NULL;
                } else {
                    /* User function - will be patched later */
                    c->t = m->code->functions[fidx].type;
                    c->fun = (void*)(intptr_t)findex; /* Store findex for patching */
                    c->value = ctx->closure_list;
                    ctx->closure_list = c;
                }
                
                preg *pd = alloc_cpu(ctx, dst, false);
                load_imm64(ctx, pd->id, (int64_t)(intptr_t)c);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OGetThis:
            {
                /* this is in r0 */
                vreg *r0 = R(0);
                hl_runtime_obj *rt = hl_get_obj_rt(r0->t);
                int offset = rt->fields_indexes[o->p2];
                
                preg *pthis = alloc_cpu(ctx, r0, true);
                RLOCK(pthis);
                if (IS_FLOAT(dst)) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, pthis->id, offset);
                    else
                        ARM64_LDR_S(pd->id, pthis->id, offset);
                    store(ctx, dst, pd, true);
                } else {
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (dst->size == 8)
                        ARM64_LDR_X(pd->id, pthis->id, offset);
                    else if (dst->size == 1)
                        ARM64_LDRB(pd->id, pthis->id, offset);
                    else
                        ARM64_LDR_W(pd->id, pthis->id, offset);
                    store(ctx, dst, pd, true);
                }
                RUNLOCK(pthis);
            }
            break;
            
        case OSetThis:
            {
                vreg *r0 = R(0);
                hl_runtime_obj *rt = hl_get_obj_rt(r0->t);
                int offset = rt->fields_indexes[o->p1];
                
                preg *pthis = alloc_cpu(ctx, r0, true);
                RLOCK(pthis);
                if (IS_FLOAT(ra)) {
                    preg *ps = alloc_fpu(ctx, ra, true);
                    if (ra->t->kind == HF64)
                        ARM64_STR_D(ps->id, pthis->id, offset);
                    else
                        ARM64_STR_S(ps->id, pthis->id, offset);
                } else {
                    preg *ps = alloc_cpu(ctx, ra, true);
                    if (ra->size == 8)
                        ARM64_STR_X(ps->id, pthis->id, offset);
                    else if (ra->size == 1)
                        ARM64_STRB(ps->id, pthis->id, offset);
                    else
                        ARM64_STR_W(ps->id, pthis->id, offset);
                }
                RUNLOCK(pthis);
            }
            break;
            
        case OGetType:
            {
                /* Get runtime type of dynamic value.
                 * Must handle null: return &hlt_void if value is null (matches x86 JIT).
                 * Without this, Std.isOfType(null, SomeClass) crashes via BaseType.check.
                 */
                preg *pr = alloc_cpu(ctx, ra, true);
                RLOCK(pr);
                preg *pd = alloc_cpu(ctx, dst, false);
                
                /* Null check: if value == NULL, return &hlt_void */
                ARM64_CMP_IMM_X(pr->id, 0);
                int jnonnull = BUF_POS();
                ARM64_B_COND(COND_NE, 0);  /* branch to non-null path */
                
                /* Null path: load &hlt_void */
                load_imm64(ctx, pd->id, (int64_t)(intptr_t)&hlt_void);
                int jend = BUF_POS();
                ARM64_B(0);  /* jump to end */
                
                /* Non-null path: load type from first field */
                int nonnull_pos = BUF_POS();
                ARM64_LDR_X(pd->id, pr->id, 0);
                
                int end_pos = BUF_POS();
                /* Patch branches */
                {
                    unsigned int *pj1 = (unsigned int *)(ctx->startBuf + jnonnull);
                    *pj1 = (*pj1 & 0xFF00001F) | ((((nonnull_pos - jnonnull) >> 2) & 0x7FFFF) << 5);
                    unsigned int *pj2 = (unsigned int *)(ctx->startBuf + jend);
                    *pj2 = 0x14000000 | (((end_pos - jend) >> 2) & 0x3FFFFFF);
                }
                RUNLOCK(pr);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OGetTID:
            {
                /* Get type kind from type pointer */
                preg *pr = alloc_cpu(ctx, ra, true);
                preg *pd = alloc_cpu(ctx, dst, false);
                /* kind is first byte of hl_type */
                EMIT(0x39400000 | ((pr->id) << 5) | (pd->id)); /* LDRB */
                store(ctx, dst, pd, true);
            }
            break;
            
        /* Safe cast */
        case OSafeCast:
            {
                /*
                 * Fast path: HNULL -> numeric unboxing (matches x86 JIT behavior).
                 * Instead of calling the C runtime hl_dyn_castX, inline the null
                 * check and direct load from the vdynamic->v field (offset 8).
                 * This is critical because the C runtime path takes &ra on stack,
                 * but the vreg may be in a register and NOT yet spilled to stack.
                 */
                if (ra->t->kind == HNULL && ra->t->tparam->kind == dst->t->kind) {
                    switch (dst->t->kind) {
                    case HUI8:
                    case HUI16:
                    case HI32:
                    case HBOOL:
                    case HI64:
                        {
                            preg *tmp = alloc_cpu(ctx, ra, true);
                            RLOCK(tmp);
                            /* Null check: if ptr == NULL, result is 0 */
                            ARM64_CMP_IMM_X(tmp->id, 0);
                            int jnull = BUF_POS();
                            ARM64_B_COND(COND_NE, 0);  /* branch to non-null */
                            /* Null path: result = 0 */
                            preg *pd = alloc_cpu(ctx, dst, false);
                            ARM64_MOV_X(pd->id, XZR);
                            int jend = BUF_POS();
                            ARM64_B(0);  /* jump to end */
                            /* Non-null path: load value from v->v (offset 8) */
                            int nonnull_pos = BUF_POS();
                            if (dst->t->kind == HI64)
                                ARM64_LDR_X(pd->id, tmp->id, 8);
                            else
                                ARM64_LDR_W(pd->id, tmp->id, 8);  /* v->v.i is always int-sized */
                            int end_pos = BUF_POS();
                            /* Patch branches */
                            {
                                unsigned int *pj1 = (unsigned int *)(ctx->startBuf + jnull);
                                *pj1 = (*pj1 & 0xFF00001F) | ((((nonnull_pos - jnull) >> 2) & 0x7FFFF) << 5);
                                unsigned int *pj2 = (unsigned int *)(ctx->startBuf + jend);
                                *pj2 = 0x14000000 | (((end_pos - jend) >> 2) & 0x3FFFFFF);
                            }
                            RUNLOCK(tmp);
                            store(ctx, dst, pd, true);
                        }
                        break;
                    case HF32:
                    case HF64:
                        {
                            preg *tmp = alloc_cpu(ctx, ra, true);
                            RLOCK(tmp);
                            preg *pd = alloc_fpu(ctx, dst, false);
                            /* Null check */
                            ARM64_CMP_IMM_X(tmp->id, 0);
                            int jnull = BUF_POS();
                            ARM64_B_COND(COND_NE, 0);  /* branch to non-null */
                            /* Null path: result = 0.0 */
                            /* MOVI Dd, #0 */
                            EMIT(0x2F00E400 | (pd->id));
                            int jend = BUF_POS();
                            ARM64_B(0);  /* jump to end */
                            /* Non-null path: load from v->v (offset 8) */
                            int nonnull_pos = BUF_POS();
                            if (dst->t->kind == HF64) {
                                /* LDR Dd, [Xn, #8] */
                                EMIT(0xFD400400 | ((tmp->id) << 5) | (pd->id));
                            } else {
                                /* LDR Sd, [Xn, #8] */
                                EMIT(0xBD400800 | ((tmp->id) << 5) | (pd->id));
                            }
                            int end_pos = BUF_POS();
                            /* Patch branches */
                            {
                                unsigned int *pj1 = (unsigned int *)(ctx->startBuf + jnull);
                                *pj1 = (*pj1 & 0xFF00001F) | ((((nonnull_pos - jnull) >> 2) & 0x7FFFF) << 5);
                                unsigned int *pj2 = (unsigned int *)(ctx->startBuf + jend);
                                *pj2 = 0x14000000 | (((end_pos - jend) >> 2) & 0x3FFFFFF);
                            }
                            RUNLOCK(tmp);
                            store(ctx, dst, pd, true);
                        }
                        break;
                    default:
                        goto safecast_slow_path;
                    }
                    break;
                }
                
                safecast_slow_path:
                {
                    /* 
                     * Slow path: call C runtime cast function.
                     * CRITICAL: spill ra to stack before taking its address, since
                     * the cast functions receive &data (pointer to stack location).
                     */
                    void *castfn;
                    switch (dst->t->kind) {
                    case HF32:
                        castfn = hl_dyn_castf;
                        break;
                    case HF64:
                        castfn = hl_dyn_castd;
                        break;
                    case HI64:
                        castfn = hl_dyn_casti64;
                        break;
                    case HI32:
                    case HUI16:
                    case HUI8:
                    case HBOOL:
                        castfn = hl_dyn_casti;
                        break;
                    default:
                        castfn = hl_dyn_castp;
                        break;
                    }
                    
                    /* Spill ra to stack first - the cast function needs &ra on stack */
                    if (ra->current != NULL) {
                        store(ctx, ra, ra->current, true);
                    }
                    
                    if (dst->t->kind == HF32 || dst->t->kind == HF64 || 
                        dst->t->kind == HI64) {
                        /* dyn_castf/d/i64(data, t) - X0=&value, X1=type */
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        if (ra->stackPos < 0) {
                            sub_large_imm(ctx, X0, FP, -ra->stackPos, X9);
                        } else {
                            add_large_imm(ctx, X0, FP, ra->stackPos, X9);
                        }
                        load_imm64(ctx, X1, (int64_t)(intptr_t)ra->t);
                    } else {
                        /* dyn_castp/i(data, t, to) - X0=&value, X1=src_type, X2=dst_type */
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        scratch(REG_AT(X2));
                        if (ra->stackPos < 0) {
                            sub_large_imm(ctx, X0, FP, -ra->stackPos, X9);
                        } else {
                            add_large_imm(ctx, X0, FP, ra->stackPos, X9);
                        }
                        load_imm64(ctx, X1, (int64_t)(intptr_t)ra->t);
                        load_imm64(ctx, X2, (int64_t)(intptr_t)dst->t);
                    }
                    call_native(ctx, castfn, 0);
                    store_result(ctx, dst);
                }
            }
            break;
            
        /* Dynamic operations - call runtime */
        case OToDyn:
            {
                if (ra->t->kind == HBOOL) {
                    scratch(REG_AT(X0));
                    preg *ps = alloc_cpu(ctx, ra, true);
                    ARM64_MOV_X(X0, ps->id);
                    call_native(ctx, hl_alloc_dynbool, 0);
                } else if (hl_is_ptr(ra->t)) {
                    /* Check for null first */
                    preg *ps = alloc_cpu(ctx, ra, true);
                    ARM64_CMP_IMM_X(ps->id, 0);
                    int jnonnull = BUF_POS();
                    ARM64_B_COND(COND_NE, 0);
                    /* Null case - return null */
                    ARM64_MOV_X(X0, XZR);
                    int jend = BUF_POS();
                    ARM64_B(0);
                    /* Non-null - wrap in dynamic */
                    int nonnull_pos = BUF_POS();
                    discard_regs(ctx, false);  /* Clear all bindings */
                    scratch(REG_AT(X0));
                    load_imm64(ctx, X0, (int64_t)(intptr_t)ra->t);
                    call_native(ctx, hl_alloc_dynamic, 0);
                    /* Save result to X20 (callee-saved) */
                    ARM64_MOV_X(X20, X0);
                    /* Store value */
                    preg *ps2 = alloc_cpu(ctx, ra, true);
                    ARM64_STR_X(ps2->id, X20, 8); /* HDYN_VALUE offset */
                    ARM64_MOV_X(X0, X20); /* Result in X0 */
                    int end_pos = BUF_POS();
                    
                    /* Patch jumps */
                    unsigned int *pj1 = (unsigned int *)(ctx->startBuf + jnonnull);
                    *pj1 = (*pj1 & 0xFF00001F) | ((((nonnull_pos - jnonnull) >> 2) & 0x7FFFF) << 5);
                    unsigned int *pj2 = (unsigned int *)(ctx->startBuf + jend);
                    *pj2 = 0x14000000 | (((end_pos - jend) >> 2) & 0x3FFFFFF);
                } else {
                    /* Non-pointer, non-bool: allocate vdynamic and store value */
                    discard_regs(ctx, false);  /* Clear all bindings first */
                    scratch(REG_AT(X0));
                    load_imm64(ctx, X0, (int64_t)(intptr_t)ra->t);
                    call_native(ctx, hl_alloc_dynamic, 0);
                    
                    /* Result is in X0, save to X20 (callee-saved) FIRST */
                    ARM64_MOV_X(X20, X0);
                    
                    /* Load the value to store - X20 still has result */
                    preg *ps = alloc_cpu(ctx, ra, true);
                    ARM64_STR_X(ps->id, X20, 8);  /* Store value at dyn->v (offset 8) */
                    
                    ARM64_MOV_X(X0, X20);  /* Result back in X0 */
                }
                
                /* Save result to X20 (callee-saved) before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OToVirtual:
            {
                /* Load source value into X1 first (using a temp if needed) */
                preg *ps = alloc_cpu(ctx, ra, true);
                RLOCK(ps);
                
                /* Save to callee-saved register before we set up args */
                ARM64_MOV_X(X19, ps->id);
                RUNLOCK(ps);
                
                /* Now set up args: X0 = type, X1 = value */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                load_imm64(ctx, X0, (int64_t)(intptr_t)dst->t);
                ARM64_MOV_X(X1, X19);
                
                call_native(ctx, hl_to_virtual, 0);
                
                /* Save result to X20 (callee-saved) before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            break;
            
        /* Switch */
        case OSwitch:
            {
                /* dst = R(o->p1) = vreg with value to switch on
                 * o->p2 = number of cases
                 * o->extra[i] = jump offset for case i
                 * o->p3 = default jump offset (but x86 ignores this and falls through!)
                 * 
                 * The HL bytecode lays out cases such that the default case code
                 * is immediately after the switch opcode. So for the default case,
                 * we should fall through to the next opcode, NOT jump to o->p3.
                 * 
                 * IMPORTANT: Use 32-bit comparisons (like x86 JIT) since enum indices
                 * are 32-bit integers. Using 64-bit comparisons can fail if upper
                 * 32 bits contain garbage.
                 */
                preg *pval = alloc_cpu(ctx, dst, true);
                RLOCK(pval);
                int ncases = o->p2;
                
                /* Runtime debug for ncases=5 (FunctionKind) - DISABLED */
                /* if (ncases == 5) { ... } */
                
                /* First check if value >= ncases (unsigned), if so fall through to default */
                /* Use 32-bit comparisons since enum indices are 32-bit integers */
                preg *tmp = alloc_reg(ctx, RCPU);
                EMIT(0x52800000 | ((ncases & 0xFFFF) << 5) | (tmp->id & 0x1F));  /* MOVZ Wtmp, ncases */
                ARM64_CMP_W(pval->id, tmp->id);  /* 32-bit compare */
                int jdefault = BUF_POS();
                ARM64_B_COND(COND_HS, 0);  /* Branch if value >= ncases (UNSIGNED) */
                
                /* Otherwise, use value as index into jump table */
                /* We emit conditional branches for each case */
#ifdef JIT_DEBUG
                printf("OSwitch: ncases=%d, dst vreg=%d\n", ncases, o->p1);
                for (int i = 0; i < ncases; i++) {
                    printf("  case %d -> extra=%d (target opCount=%d)\n", i, o->extra[i], opCount + 1 + o->extra[i]);
                }
#endif
                for (int i = 0; i < ncases; i++) {
                    ARM64_CMP_IMM_W(pval->id, i);  /* 32-bit compare */
                    int jpos = BUF_POS();
                    ARM64_B_COND(COND_EQ, 0);
                    add_jump(ctx, jpos, opCount + 1 + o->extra[i]);
                }
                
                /* After all case comparisons, fall through to default (next opcode) */
                /* Patch the jdefault branch to here */
                {
                    int from = jdefault;
                    int to = BUF_POS();
                    int offset = to - from;
                    unsigned int *instr = (unsigned int *)(ctx->startBuf + from);
                    *instr = (*instr & 0xFF00001F) | (((offset >> 2) & 0x7FFFF) << 5);
                }
                
                RUNLOCK(pval);
            }
            break;
            
        /* Throw/Rethrow - call runtime (never returns) */
        case OThrow:
            {
                preg *ps = alloc_cpu(ctx, dst, true);
                /* Move to X0 first, then scratch */
                ARM64_MOV_X(X0, ps->id);
                scratch(REG_AT(X0));
                call_native(ctx, hl_throw, 0);
                ARM64_BRK(0xD1E1);  /* Unreachable */
            }
            break;
            
        case ORethrow:
            {
                preg *ps = alloc_cpu(ctx, dst, true);
                /* Move to X0 first, then scratch */
                ARM64_MOV_X(X0, ps->id);
                scratch(REG_AT(X0));
                call_native(ctx, hl_rethrow, 0);
                ARM64_BRK(0xD1E2);  /* Unreachable */
            }
            break;
            
        /* Assert */
        case OAssert:
            ARM64_BRK(0xA55E);
            break;
            
        /* Instance closure - create closure with bound value */
        case OInstanceClosure:
            {
                /* Load the value first and save to a callee-saved register */
                preg *pval = alloc_cpu(ctx, rb, true);
                int valReg = pval->id;
                
                /* Move to X20 (callee-saved) before we scratch registers */
                ARM64_MOV_X(X20, valReg);
                
                /* Prepare args: type, fun_ptr (placeholder), value */
                /* Invalidate vreg bindings before overwriting X0, X1, X2, X9 */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                scratch(REG_AT(X2));
                scratch(REG_AT(X9));
                load_imm64(ctx, X0, (int64_t)(intptr_t)m->code->functions[m->functions_indexes[o->p2]].type);
                
                /* Add to call patch list for function pointer */
                /* Patching always targets X9, so emit placeholder for X9 then move to X1 */
                add_call(ctx, BUF_POS(), o->p2);
                ARM64_MOVZ_X(X9, 0);   /* Placeholder - will be patched */
                ARM64_MOVK_X(X9, 0, 16);
                ARM64_MOVK_X(X9, 0, 32);
                ARM64_MOVK_X(X9, 0, 48);
                ARM64_MOV_X(X1, X9);   /* Move to X1 for call */
                
                /* Use saved value from X20 */
                ARM64_MOV_X(X2, X20);
                
                call_native(ctx, hl_alloc_closure_ptr, 0);
                
                /* Save result before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            break;
            
        /* Virtual closure - lookup in vtable */
        case OVirtualClosure:
            {
                /* Find the type from proto table */
                hl_type *t = NULL;
                hl_type *ot = ra->t;
                int i;
                while (t == NULL && ot) {
                    for (i = 0; i < ot->obj->nproto; i++) {
                        hl_obj_proto *pp = ot->obj->proto + i;
                        if (pp->pindex == o->p3) {
                            t = m->code->functions[m->functions_indexes[pp->findex]].type;
                            break;
                        }
                    }
                    ot = ot->obj->super;
                }
                
                preg *pobj = alloc_cpu(ctx, ra, true);
                preg *tmp = alloc_reg(ctx, RCPU);
                
                /* Save object pointer to X20 (callee-saved) before scratching */
                ARM64_MOV_X(X20, pobj->id);
                
                /* Invalidate vreg bindings before overwriting X0, X1, X2 */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                scratch(REG_AT(X2));
                
                /* Load function from vtable: obj->type->vobj_proto[o->p3] */
                /* Use X20 since pobj may have been scratched */
                ARM64_LDR_X(tmp->id, X20, 0);                /* tmp = obj->type */
                ARM64_LDR_X(tmp->id, tmp->id, 2 * 8);        /* tmp = type->vobj_proto */
                ARM64_LDR_X(X1, tmp->id, o->p3 * 8);         /* X1 = proto[p3] (fun ptr) */
                
                /* Args: type, fun, value */
                load_imm64(ctx, X0, (int64_t)(intptr_t)t);
                ARM64_MOV_X(X2, X20);  /* Use saved value */
                
                call_native(ctx, hl_alloc_closure_ptr, 0);
                
                /* Save result before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
                RUNLOCK(tmp);
            }
            break;
            
        /* Call closure */
        case OCallClosure:
            if (ra->t->kind == HDYN) {
                /* Dynamic closure - call hl_dyn_call */
                int nargs = o->p3;
#ifdef JIT_DEBUG
                printf("OCallClosure: nargs=%d, extra=%p\n", nargs, (void*)o->extra);
                for (int j = 0; j < nargs; j++)
                    printf("  extra[%d]=%d\n", j, o->extra ? o->extra[j] : -1);
#endif
                int argsSize = nargs * 8;
                argsSize = (argsSize + 15) & ~15;
                
                /* Allocate stack space for args array */
                if (argsSize > 0) {
                    if (argsSize <= 4095)
                        ARM64_SUB_IMM_X(SP, SP, argsSize);
                    else {
                        scratch(REG_AT(X9));
                        load_imm64(ctx, X9, argsSize);
                        ARM64_SUB_EXT_X(SP, SP, X9);
                    }
                }
                
                /* Store args to stack - handle floats specially */
                for (int i = 0; i < nargs; i++) {
                    vreg *arg = R(o->extra[i]);
                    if (IS_FLOAT(arg)) {
                        /* Float args - fetch from FPU register and store as 64-bit */
                        preg *pa = alloc_fpu(ctx, arg, true);
                        ARM64_STR_D(pa->id, SP, i * 8);
                    } else {
                        preg *pa = alloc_cpu(ctx, arg, true);
                        ARM64_STR_X(pa->id, SP, i * 8);
                    }
                }
                
                /* Call hl_dyn_call(closure, args, nargs) */
                /* Invalidate vreg bindings before overwriting X0, X1, X2 */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                scratch(REG_AT(X2));
                preg *pclo = alloc_cpu(ctx, ra, true);
                ARM64_MOV_X(X0, pclo->id);
                ARM64_ADD_IMM_X(X1, SP, 0);  /* MOV X1, SP */
                ARM64_MOVZ_X(X2, nargs);
                call_native(ctx, hl_dyn_call, 0);
                
                /* Restore stack */
                if (argsSize > 0) {
                    if (argsSize <= 4095)
                        ARM64_ADD_IMM_X(SP, SP, argsSize);
                    else {
                        load_imm64(ctx, X9, argsSize);
                        ARM64_ADD_EXT_X(SP, SP, X9);
                    }
                }
                
                if (dst->t->kind != HVOID) {
                    /* Save result before alloc_cpu might clobber X0 */
                    ARM64_MOV_X(X20, X0);
                    preg *pd = alloc_cpu(ctx, dst, false);
                    ARM64_MOV_X(pd->id, X20);
                    store(ctx, dst, pd, true);
                }
            } else {
                /* Typed closure */
                preg *pclo = alloc_cpu(ctx, ra, true);
                preg *tmp = alloc_reg(ctx, RCPU);
                
                /* Save closure pointer to X20 before prepare_call_args might clobber it */
                ARM64_MOV_X(X20, pclo->id);
                
                /* Check if closure has bound value */
                ARM64_LDR_W(tmp->id, pclo->id, 2 * 8); /* hasValue at offset 16 */
                ARM64_CMP_IMM_X(tmp->id, 0);
                
                /* Save register bindings before the conditional branch */
                save_regs(ctx);
                
                int jhasval = BUF_POS();
                ARM64_B_COND(COND_NE, 0);
                
                /* No value - just call with args */
                /* First validate the closure before we set up arguments 
                 * (validation call clobbers X0-X7) */
                ARM64_LDR_X(X9, X20, 8); /* fun ptr from saved closure */
                ARM64_MOV_X(X0, X20);  /* X20 has saved closure pointer */
                ARM64_MOV_X(X1, X9);   /* X9 has function pointer */
                call_native(ctx, jit_validate_closure, 0);
                
                /* Now set up arguments (after validation) */
                int stackSize = prepare_call_args(ctx, o->p3, o->extra);
                
                /* Reload function pointer */
                ARM64_LDR_X(X9, X20, 8); /* fun ptr from saved closure */

                /* If X9 is null, skip the call (nullable closure) */
                ARM64_CMP_IMM_X(X9, 0);
                int jfunok = BUF_POS();
                ARM64_B_COND(COND_NE, 0);
                /* Null closure - clean up stack and skip the call */
                if (stackSize > 0) ARM64_ADD_IMM_X(SP, SP, stackSize);
                if (dst->t->kind != HVOID) {
                    scratch(REG_AT(X0));
                    ARM64_MOVZ_X(X0, 0);
                }
                int jskip_null = BUF_POS();
                ARM64_B(0);  /* Jump to end */
                
                int funok_pos = BUF_POS();
                unsigned int *pjfok = (unsigned int *)(ctx->startBuf + jfunok);
                *pjfok = (*pjfok & 0xFF00001F) | ((((funok_pos - jfunok) >> 2) & 0x7FFFF) << 5);

                ARM64_BLR(X9);
                if (stackSize > 0) ARM64_ADD_IMM_X(SP, SP, stackSize);
                
                /* Patch null skip jump to here */
                int after_call_pos = BUF_POS();
                unsigned int *pjskip = (unsigned int *)(ctx->startBuf + jskip_null);
                *pjskip = 0x14000000 | (((after_call_pos - jskip_null) >> 2) & 0x3FFFFFF);
                
                discard_regs(ctx, false);
                
                int jend = BUF_POS();
                ARM64_B(0);
                
                /* Has value - prepend value to args */
                int hasval_pos = BUF_POS();
                
                /* Restore register bindings from before the branch */
                restore_regs(ctx);
                
                /* Strategy: Manually set up all args without using prepare_call_args.
                 * This avoids issues with scratch vregs and register binding.
                 * 
                 * Total args will be: closure_value, extra[0], extra[1], ...
                 * So we have o->p3 + 1 total args.
                 */
                discard_regs(ctx, false);
                
                /* Save closure ptr to a callee-saved location before we clobber regs */
                pclo = alloc_cpu(ctx, ra, true);
                ARM64_MOV_X(X19, pclo->id);  /* X19 is callee-saved */
                
                /* Validate the closure BEFORE setting up arguments
                 * (validation call clobbers X0-X7 so must be done first) */
                ARM64_LDR_X(X9, X19, 8);  /* fun is at offset 8 */
                ARM64_MOV_X(X0, X19);     /* closure pointer */
                ARM64_MOV_X(X1, X9);      /* function pointer */
                call_native(ctx, jit_validate_closure, 0);
                
                /* Calculate stack space needed for args beyond register args.
                 * ARM64 ABI: Integer args go in X0-X7, Float args in D0-D7,
                 * with SEPARATE register indices per bank.
                 * The closure value (always CPU) takes X0, so CPU args start at X1.
                 */
                int totalCpuArgs = 1; /* closure value in X0 */
                int totalFpuArgs = 0;
                int stackArgsSize = 0;
                for (int i = 0; i < o->p3; i++) {
                    vreg *arg = R(o->extra[i]);
                    if (IS_FLOAT(arg)) {
                        if (totalFpuArgs >= 8)
                            stackArgsSize += 8;
                        totalFpuArgs++;
                    } else {
                        if (totalCpuArgs >= CALL_NREGS)
                            stackArgsSize += 8;
                        totalCpuArgs++;
                    }
                }
                stackArgsSize = (stackArgsSize + 15) & ~15;  /* 16-byte align */
                
                if (stackArgsSize > 0) {
                    ARM64_SUB_IMM_X(SP, SP, stackArgsSize);
                }
                
                /* Scratch and lock target CPU registers (X1+) before loading args */
                {
                    int cpuIdx = 1; /* X0 reserved for closure value */
                    for (int i = 0; i < o->p3; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (!IS_FLOAT(arg) && cpuIdx < CALL_NREGS) {
                            scratch(REG_AT(CALL_REGS[cpuIdx]));
                            RLOCK(REG_AT(CALL_REGS[cpuIdx]));
                            cpuIdx++;
                        }
                    }
                }
                /* Scratch and lock target FPU registers (D0+) */
                {
                    int fpuIdx = 0;
                    for (int i = 0; i < o->p3; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (IS_FLOAT(arg) && fpuIdx < 8) {
                            scratch(REG_AT(VREG(fpuIdx)));
                            RLOCK(REG_AT(VREG(fpuIdx)));
                            fpuIdx++;
                        }
                    }
                }
                
                /* Place args using separate CPU/FPU register banks (ARM64 ABI) */
                {
                    int cpuIdx = 1; /* X0 reserved for closure value */
                    int fpuIdx = 0;
                    int stkOffset = 0;
                    for (int i = 0; i < o->p3; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (IS_FLOAT(arg)) {
                            preg *pa = alloc_fpu(ctx, arg, true);
                            if (fpuIdx < 8) {
                                /* Float arg goes in D register */
                                if (pa->id != fpuIdx) {
                                    if (arg->t->kind == HF32)
                                        ARM64_FMOV_S(fpuIdx, pa->id);
                                    else
                                        ARM64_FMOV_D(fpuIdx, pa->id);
                                }
                                fpuIdx++;
                            } else {
                                /* Overflow to stack */
                                if (arg->t->kind == HF32)
                                    ARM64_STR_S(pa->id, SP, stkOffset);
                                else
                                    ARM64_STR_D(pa->id, SP, stkOffset);
                                stkOffset += 8;
                            }
                            RUNLOCK(pa);
                        } else {
                            preg *pa = alloc_cpu(ctx, arg, true);
                            if (cpuIdx < CALL_NREGS) {
                                int targetReg = CALL_REGS[cpuIdx];
                                if (pa->id != targetReg) {
                                    ARM64_MOV_X(targetReg, pa->id);
                                }
                                cpuIdx++;
                            } else {
                                ARM64_STR_X(pa->id, SP, stkOffset);
                                stkOffset += 8;
                            }
                            RUNLOCK(pa);
                        }
                    }
                }
                
                /* Unlock target CPU registers */
                {
                    int cpuIdx = 1;
                    for (int i = 0; i < o->p3; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (!IS_FLOAT(arg) && cpuIdx < CALL_NREGS) {
                            RUNLOCK(REG_AT(CALL_REGS[cpuIdx]));
                            cpuIdx++;
                        }
                    }
                }
                /* Unlock target FPU registers */
                {
                    int fpuIdx = 0;
                    for (int i = 0; i < o->p3; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (IS_FLOAT(arg) && fpuIdx < 8) {
                            RUNLOCK(REG_AT(VREG(fpuIdx)));
                            fpuIdx++;
                        }
                    }
                }
                
                /* Load closure value into X0 (from saved closure ptr in X19) */
                ARM64_LDR_X(X0, X19, 3 * 8);  /* value is at offset 24 in closure */

                /* Load function pointer */
                ARM64_LDR_X(X9, X19, 8);  /* fun is at offset 8 */

                /* If X9 is null, skip the call (nullable closure) */
                ARM64_CMP_IMM_X(X9, 0);
                int jfunok2 = BUF_POS();
                ARM64_B_COND(COND_NE, 0);
                /* Null closure - clean up stack and skip to end */
                if (stackArgsSize > 0) {
                    ARM64_ADD_IMM_X(SP, SP, stackArgsSize);
                }
                if (dst->t->kind != HVOID) {
                    scratch(REG_AT(X0));
                    ARM64_MOVZ_X(X0, 0);
                }
                int jskip_null2 = BUF_POS();
                ARM64_B(0);  /* Jump to end */
                
                int funok2_pos = BUF_POS();
                unsigned int *pjfok2 = (unsigned int *)(ctx->startBuf + jfunok2);
                *pjfok2 = (*pjfok2 & 0xFF00001F) | ((((funok2_pos - jfunok2) >> 2) & 0x7FFFF) << 5);

                ARM64_BLR(X9);
                
                if (stackArgsSize > 0) {
                    ARM64_ADD_IMM_X(SP, SP, stackArgsSize);
                }
                
                /* Patch null skip jump */
                int after_call2_pos = BUF_POS();
                unsigned int *pjskip2 = (unsigned int *)(ctx->startBuf + jskip_null2);
                *pjskip2 = 0x14000000 | (((after_call2_pos - jskip_null2) >> 2) & 0x3FFFFFF);
                
                discard_regs(ctx, false);
                
                int end_pos = BUF_POS();
                
                /* Patch jumps */
                unsigned int *pj1 = (unsigned int *)(ctx->startBuf + jhasval);
                *pj1 = (*pj1 & 0xFF00001F) | ((((hasval_pos - jhasval) >> 2) & 0x7FFFF) << 5);
                unsigned int *pj2 = (unsigned int *)(ctx->startBuf + jend);
                *pj2 = 0x14000000 | (((end_pos - jend) >> 2) & 0x3FFFFFF);
                
                store_result(ctx, dst);
            }
            break;
            
        /* Call method via vtable */
        case OCallMethod:
            {
                vreg *robj = R(o->extra[0]);
                
                switch (robj->t->kind) {
                case HOBJ: {
                    /* Load vtable method BEFORE prepare_call_args clears bindings.
                     * This matches x86 JIT behavior.
                     */
                    preg *pobj = alloc_cpu(ctx, robj, true);
                    RLOCK(pobj);
                    scratch(REG_AT(X9));
                    ARM64_LDR_X(X9, pobj->id, 0);       /* type */
                    ARM64_LDR_X(X9, X9, 2 * 8);         /* vobj_proto */
                    ARM64_LDR_X(X9, X9, o->p2 * 8);     /* method ptr */
                    RUNLOCK(pobj);

                    /* Save method pointer to callee-saved X19 before prepare_call_args */
                    ARM64_MOV_X(X19, X9);

                    int stackSize = prepare_call_args(ctx, o->p3, o->extra);

                    /* Call via saved method pointer */
                    ARM64_BLR(X19);
                    
                    if (stackSize > 0) ARM64_ADD_IMM_X(SP, SP, stackSize);
                    discard_regs(ctx, false);
                    
                    store_result(ctx, dst);
                    break;
                }
                case HVIRTUAL: {
                    /* For virtual objects, check if there's a direct method pointer.
                     * Layout: vvirtual { type, value, next } followed by function pointers
                     * hl_vfields(o)[f] = *(o + sizeof(vvirtual) + f*8)
                     * If non-null, call it with o->value as first arg.
                     * Otherwise, fall back to hl_dyn_call_obj.
                     */
                    preg *pobj = alloc_cpu(ctx, robj, true);
                    RLOCK(pobj);
                    
                    /* Load hl_vfields(o)[p2] = *(o + 24 + p2*8) */
                    int vfields_offset = 24 + o->p2 * 8;  /* sizeof(vvirtual) = 24 */
                    scratch(REG_AT(X9));
                    ARM64_LDR_X(X9, pobj->id, vfields_offset);
                    
                    /* Save method pointer to X19 IMMEDIATELY before it can be clobbered */
                    ARM64_MOV_X(X19, X9);
                    
                    RUNLOCK(pobj);
                    
                    /* Check if method pointer is null */
                    ARM64_CMP_IMM_X(X19, 0);
                    
                    /* If null, jump to dynamic fallback */
                    int jmp_to_fallback = BUF_POS();
                    EMIT(0); /* Placeholder for B.EQ */
                    
                    /* --- Fast path: Direct call --- */
                    /* For HVIRTUAL, arg0 in o->extra is the virtual object itself.
                     * We need to replace it with o->value for the actual call.
                     * Strategy: Build a modified args array and use prepare_call_args.
                     */
                    int nargs = o->p3;
                    int stackSize = 0;
                    
                    /* Save o->value to X20 before args clobber registers */
                    pobj = alloc_cpu(ctx, robj, true);
                    ARM64_LDR_X(X20, pobj->id, 8);  /* value is at offset 8, save to X20 */
                    
                    /* Method pointer is already in X19 */
                    
                    /* Manually place args using ARM64 ABI with separate CPU/FPU register banks.
                     * arg[0] = o->value (CPU, in X20 -> X0)
                     * arg[1..n-1]: CPU args go to X1..X7, float args go to D0..D7.
                     */
                    discard_regs(ctx, false);

                    /* Calculate stack space needed for args beyond register args.
                     * CPU and FPU args have separate register banks on ARM64.
                     * o->value takes X0, so remaining CPU args start at X1.
                     */
                    int cpuCount = 1; /* o->value takes X0 */
                    int fpuCount = 0;
                    int stackArgsBytes = 0;
                    for (int i = 1; i < nargs; i++) {
                        vreg *arg = R(o->extra[i]);
                        if (IS_FLOAT(arg)) {
                            if (fpuCount >= 8) stackArgsBytes += 8;
                            fpuCount++;
                        } else {
                            if (cpuCount >= CALL_NREGS) stackArgsBytes += 8;
                            cpuCount++;
                        }
                    }
                    int stackArgsSize = (stackArgsBytes + 15) & ~15;

                    if (stackArgsSize > 0) {
                        ARM64_SUB_IMM_X(SP, SP, stackArgsSize);
                    }
                    stackSize = stackArgsSize;

                    /* Scratch and lock target CPU registers (X1+) */
                    {
                        int ci = 1;
                        for (int i = 1; i < nargs; i++) {
                            vreg *arg = R(o->extra[i]);
                            if (!IS_FLOAT(arg) && ci < CALL_NREGS) {
                                scratch(REG_AT(CALL_REGS[ci]));
                                RLOCK(REG_AT(CALL_REGS[ci]));
                                ci++;
                            }
                        }
                    }
                    /* Scratch and lock target FPU registers (D0+) */
                    {
                        int fi = 0;
                        for (int i = 1; i < nargs; i++) {
                            vreg *arg = R(o->extra[i]);
                            if (IS_FLOAT(arg) && fi < 8) {
                                scratch(REG_AT(VREG(fi)));
                                RLOCK(REG_AT(VREG(fi)));
                                fi++;
                            }
                        }
                    }

                    /* Place args[1..n-1] using separate CPU/FPU indices */
                    {
                        int ci = 1; /* CPU index (X0 = o->value) */
                        int fi = 0; /* FPU index */
                        int stkOff = 0;
                        for (int i = 1; i < nargs; i++) {
                            vreg *arg = R(o->extra[i]);
                            if (IS_FLOAT(arg)) {
                                preg *pa = alloc_fpu(ctx, arg, true);
                                if (fi < 8) {
                                    if (pa->id != fi) {
                                        if (arg->t->kind == HF32)
                                            ARM64_FMOV_S(fi, pa->id);
                                        else
                                            ARM64_FMOV_D(fi, pa->id);
                                    }
                                    fi++;
                                } else {
                                    if (arg->t->kind == HF32)
                                        ARM64_STR_S(pa->id, SP, stkOff);
                                    else
                                        ARM64_STR_D(pa->id, SP, stkOff);
                                    stkOff += 8;
                                }
                                RUNLOCK(pa);
                            } else {
                                preg *pa = alloc_cpu(ctx, arg, true);
                                if (ci < CALL_NREGS) {
                                    int targetReg = CALL_REGS[ci];
                                    if (pa->id != targetReg) {
                                        ARM64_MOV_X(targetReg, pa->id);
                                    }
                                    ci++;
                                } else {
                                    ARM64_STR_X(pa->id, SP, stkOff);
                                    stkOff += 8;
                                }
                                RUNLOCK(pa);
                            }
                        }
                    }

                    /* Unlock target CPU registers */
                    {
                        int ci = 1;
                        for (int i = 1; i < nargs; i++) {
                            vreg *arg = R(o->extra[i]);
                            if (!IS_FLOAT(arg) && ci < CALL_NREGS) {
                                RUNLOCK(REG_AT(CALL_REGS[ci]));
                                ci++;
                            }
                        }
                    }
                    /* Unlock target FPU registers */
                    {
                        int fi = 0;
                        for (int i = 1; i < nargs; i++) {
                            vreg *arg = R(o->extra[i]);
                            if (IS_FLOAT(arg) && fi < 8) {
                                RUNLOCK(REG_AT(VREG(fi)));
                                fi++;
                            }
                        }
                    }

                    /* Put o->value (saved in X20) into X0 */
                    scratch(REG_AT(X0));
                    ARM64_MOV_X(X0, X20);
                    
                    /* Call method (pointer saved in X19) */
                    ARM64_BLR(X19);
                    
                    if (stackSize > 0) ARM64_ADD_IMM_X(SP, SP, stackSize);
                    discard_regs(ctx, false);
                    store_result(ctx, dst);
                    
                    /* CRITICAL: Clear X0 binding after store_result.
                     * X0 is a scratch register that will be clobbered by subsequent calls.
                     * If we leave the binding, subsequent code may think dst is still in X0
                     * when it's actually been clobbered.
                     */
                    {
                        preg *x0 = REG_AT(X0);
                        if (x0->holds) {
                            x0->holds->current = NULL;
                            x0->holds = NULL;
                        }
                    }
                    
                    /* Jump over fallback */
                    int jmp_to_end = BUF_POS();
                    EMIT(0); /* Placeholder for B */
                    
                    /* --- Slow path: Dynamic fallback via hl_dyn_call_obj --- */
                    int fallback_pos = BUF_POS();
                    /* Patch the jump to here */
                    int rel_fallback = (fallback_pos - jmp_to_fallback) / 4;
                    *(unsigned int *)(ctx->startBuf + jmp_to_fallback) = 
                        0x54000000 | ((rel_fallback & 0x7FFFF) << 5) | COND_EQ;  /* B.EQ */
                    
                    /* Save the virtual object to X21 (callee-saved) before discarding regs.
                     * We need it to get o->value for the dynamic call.
                     */
                    {
                        preg *pobj_save = alloc_cpu(ctx, robj, true);
                        ARM64_MOV_X(X21, pobj_save->id);
                    }
                    
                    discard_regs(ctx, false);
                    
                    /* Call hl_dyn_call_obj(obj->value, ft, hfield, args, ret)
                     * 
                     * We need to:
                     * 1. Build args array on stack (excluding the virtual object itself)
                     * 2. For non-pointer return types, allocate vdynamic on stack for ret
                     * 3. Call hl_dyn_call_obj
                     * 4. Extract return value
                     */
                    {
                        bool need_dyn = !hl_is_ptr(dst->t) && dst->t->kind != HVOID;
                        int paramsSize = (nargs - 1) * 8;  /* args array (excluding obj) */
                        if (need_dyn) paramsSize += sizeof(vdynamic);
                        /* Always allocate at least 16 bytes for proper alignment and valid args pointer */
                        if (paramsSize < 16) paramsSize = 16;
                        paramsSize = (paramsSize + 15) & ~15;  /* 16-byte align */
                        
                        ARM64_SUB_IMM_X(SP, SP, paramsSize);
                        
                        /* Build args array at SP.
                         * For each arg after the first (the virtual itself), store pointer.
                         */
                        for (int i = 1; i < nargs; i++) {
                            vreg *a = R(o->extra[i]);
                            preg *pa = alloc_cpu(ctx, a, true);
                            if (hl_is_ptr(a->t)) {
                                /* Store pointer directly */
                                ARM64_STR_X(pa->id, SP, (i - 1) * 8);
                            } else {
                                /* For non-pointer types, store address of the value on stack */
                                /* The value should already be on the stack */
                                store(ctx, a, pa, true);  /* Ensure it's on stack */
                                scratch(REG_AT(X9));
                                add_large_imm(ctx, X9, FP, a->stackPos, X10);
                                ARM64_STR_X(X9, SP, (i - 1) * 8);
                            }
                            RUNLOCK(pa);
                        }
                        
                        /* Get virtual object's value from X21 (saved earlier) */
                        scratch(REG_AT(X0));
                        ARM64_LDR_X(X0, X21, 8);  /* X0 = obj->value */
                        
                        /* X1 = field type (ft) */
                        hl_type *ft = robj->t->virt->fields[o->p2].t;
                        scratch(REG_AT(X1));
                        load_imm64(ctx, X1, (int64_t)(intptr_t)ft);
                        
                        /* X2 = hashed field name */
                        int hfield = robj->t->virt->fields[o->p2].hashed_name;
                        scratch(REG_AT(X2));
                        load_imm64(ctx, X2, hfield);
                        
                        /* X3 = args array pointer (SP)
                         * Note: Can't use MOV X3, SP because in ORR instruction, reg 31 is XZR, not SP.
                         * Use ADD X3, SP, #0 instead.
                         */
                        scratch(REG_AT(X3));
                        ARM64_ADD_IMM_X(X3, SP, 0);
                        
                        /* X4 = ret pointer (NULL for pointer types, stack addr for others) */
                        scratch(REG_AT(X4));
                        if (need_dyn) {
                            /* Point to vdynamic at end of args array */
                            int ret_offset = (nargs - 1) * 8;
                            ARM64_ADD_IMM_X(X4, SP, ret_offset);
                        } else {
                            ARM64_MOVZ_X(X4, 0);  /* NULL */
                        }
                        
                        call_native(ctx, hl_dyn_call_obj, 0);
                        
                        /* Handle return value */
                        if (dst->t->kind != HVOID) {
                            if (need_dyn) {
                                /* For non-pointer types, extract value from vdynamic on stack */
                                int ret_offset = (nargs - 1) * 8;
                                if (IS_FLOAT(dst)) {
                                    /* Load from vdynamic.v.d */
                                    ARM64_LDR_D(0, SP, ret_offset + 8);
                                    preg *pd = alloc_cpu(ctx, dst, false);
                                    /* store FPU result */
                                    preg *d0 = REG_AT(VREG(0));
                                    d0->kind = RFPU;
                                    d0->id = 0;
                                    store(ctx, dst, d0, true);
                                } else {
                                    /* Load from vdynamic.v.i or v.i64 */
                                    scratch(REG_AT(X0));
                                    ARM64_LDR_X(X0, SP, ret_offset + 8);
                                    preg *pd = alloc_cpu(ctx, dst, false);
                                    ARM64_MOV_X(pd->id, X0);
                                    store(ctx, dst, pd, true);
                                }
                            } else {
                                /* For pointer types, result is in X0 */
                                preg *pd = alloc_cpu(ctx, dst, false);
                                ARM64_MOV_X(pd->id, X0);
                                store(ctx, dst, pd, true);
                            }
                        }
                        
                        /* Always restore stack since we always allocate at least 16 bytes */
                        ARM64_ADD_IMM_X(SP, SP, paramsSize);
                    }
                    
                    /* Patch jump to end */
                    int end_pos = BUF_POS();
                    int rel_end = (end_pos - jmp_to_end) / 4;
                    *(unsigned int *)(ctx->startBuf + jmp_to_end) = 
                        0x14000000 | (rel_end & 0x3FFFFFF);  /* B */
                    
                    /* CRITICAL: After generating both paths, clear all bindings.
                     * The fast path stored result in dst and cleared X0 binding.
                     * The fallback path may have created different bindings.
                     * Since both paths converge here and dst has the result on stack,
                     * we need to ensure subsequent code loads from stack not stale regs.
                     */
                    discard_regs(ctx, false);
                    
                    break;
                }
                default:
                    printf("OCallMethod: unsupported type kind %d\n", robj->t->kind);
                    ARM64_BRK(0xCAFE);
                    break;
                }
            }
            break;
            
        /* Call this.method */
        case OCallThis:
            {
                vreg *rthis = R(0);
                
                /* Load vtable method BEFORE prepare_call_args clears bindings.
                 * This matches x86 JIT behavior.
                 */
                preg *pthis = alloc_cpu(ctx, rthis, true);
                RLOCK(pthis);
                scratch(REG_AT(X9));
                ARM64_LDR_X(X9, pthis->id, 0);       /* type */
                ARM64_LDR_X(X9, X9, 2 * 8);          /* vobj_proto */
                ARM64_LDR_X(X9, X9, o->p2 * 8);      /* method ptr */
                RUNLOCK(pthis);

                /* Save method pointer to callee-saved X19 before prepare_call_args */
                ARM64_MOV_X(X19, X9);
                
                /* Build args with 'this' as first */
                int nargs = o->p3 + 1;
                int *args = (int *)hl_malloc(&ctx->falloc, sizeof(int) * nargs);
                args[0] = 0;
                for (int i = 0; i < o->p3; i++)
                    args[i + 1] = o->extra[i];
                
                int stackSize = prepare_call_args(ctx, nargs, args);
                
                /* Call via saved method pointer */
                ARM64_BLR(X19);
                
                if (stackSize > 0) ARM64_ADD_IMM_X(SP, SP, stackSize);
                discard_regs(ctx, false);
                
                store_result(ctx, dst);
            }
            break;
            
        /* Enum operations */
        case OMakeEnum:
            {
                hl_enum_construct *c = &dst->t->tenum->constructs[o->p2];
                
                /* Call hl_alloc_enum(type, construct_index) */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                load_imm64(ctx, X0, (int64_t)(intptr_t)dst->t);
                ARM64_MOVZ_X(X1, o->p2);
                call_native(ctx, hl_alloc_enum, 0);
                
                /* Save enum pointer before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                
                /* Copy field values */
                for (int i = 0; i < c->nparams; i++) {
                    vreg *arg = R(o->extra[i]);
                    preg *pa = IS_FLOAT(arg) ? alloc_fpu(ctx, arg, true) : alloc_cpu(ctx, arg, true);
                    int offset = c->offsets[i];
                    
                    if (IS_FLOAT(arg)) {
                        if (arg->t->kind == HF64)
                            ARM64_STR_D(pa->id, X20, offset);
                        else
                            ARM64_STR_S(pa->id, X20, offset);
                    } else {
                        if (arg->size == 8)
                            ARM64_STR_X(pa->id, X20, offset);
                        else
                            ARM64_STR_W(pa->id, X20, offset);
                    }
                }
                
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OEnumAlloc:
            {
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                load_imm64(ctx, X0, (int64_t)(intptr_t)dst->t);
                ARM64_MOVZ_X(X1, o->p2);
                call_native(ctx, hl_alloc_enum, 0);
                
                /* Save result before alloc_cpu might clobber X0 */
                ARM64_MOV_X(X20, X0);
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X20);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OEnumIndex:
            {
                preg *pe = alloc_cpu(ctx, ra, true);
                preg *pd = alloc_cpu(ctx, dst, false);
                /* Enum index is at offset 8 (after type pointer) */
                ARM64_LDR_W(pd->id, pe->id, 8);
                store(ctx, dst, pd, true);
            }
            break;
            
        case OEnumField:
            {
                hl_enum_construct *c = &ra->t->tenum->constructs[o->p3];
                int offset = c->offsets[(int)(intptr_t)o->extra];
                
                preg *pe = alloc_cpu(ctx, ra, true);
                
                if (IS_FLOAT(dst)) {
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF64)
                        ARM64_LDR_D(pd->id, pe->id, offset);
                    else
                        ARM64_LDR_S(pd->id, pe->id, offset);
                    store(ctx, dst, pd, true);
                } else {
                    preg *pd = alloc_cpu(ctx, dst, false);
                    if (dst->size == 8)
                        ARM64_LDR_X(pd->id, pe->id, offset);
                    else if (dst->size == 1)
                        ARM64_LDRB(pd->id, pe->id, offset);
                    else
                        ARM64_LDR_W(pd->id, pe->id, offset);
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        case OSetEnumField:
            {
                hl_enum_construct *c = &dst->t->tenum->constructs[0];
                int offset = c->offsets[o->p2];
                
                preg *pe = alloc_cpu(ctx, dst, true);
                
                if (IS_FLOAT(rb)) {
                    preg *ps = alloc_fpu(ctx, rb, true);
                    if (rb->t->kind == HF64)
                        ARM64_STR_D(ps->id, pe->id, offset);
                    else
                        ARM64_STR_S(ps->id, pe->id, offset);
                } else {
                    preg *ps = alloc_cpu(ctx, rb, true);
                    if (rb->size == 8)
                        ARM64_STR_X(ps->id, pe->id, offset);
                    else if (rb->size == 1)
                        ARM64_STRB(ps->id, pe->id, offset);
                    else
                        ARM64_STR_W(ps->id, pe->id, offset);
                }
            }
            break;
            
        /* Exception handling */
        case OTrap:
            {
                /*
                 * OTrap implementation using setjmp/longjmp for ARM64.
                 *
                 * Structure offsets (ARM64 macOS):
                 *   sizeof(hl_trap_ctx) = 208 bytes
                 *   trap->buf    at offset 0
                 *   trap->prev   at offset 192
                 *   trap->tcheck at offset 200
                 *   tinf->trap_current at offset 24
                 *   tinf->exc_value    at offset 48
                 */
                #define TRAP_SIZE 208
                #define TRAP_OFFSET_PREV 192
                #define TRAP_OFFSET_TCHECK 200
                #define TINF_OFFSET_TRAP_CURRENT 24
                #define TINF_OFFSET_EXC_VALUE 48

                int jenter, jtrap;

                /* Discard all register bindings - we're calling functions */
                discard_regs(ctx, false);

                /* 1. Call hl_get_thread() to get thread info pointer */
                call_native(ctx, hl_get_thread, 0);
                /* Result in X0 = tinf */

                /* 2. Save tinf to callee-saved X19 for use after setjmp */
                ARM64_MOV_X(X19, X0);

                /* 3. Load current trap_current into X1 */
                ARM64_LDR_X(X1, X19, TINF_OFFSET_TRAP_CURRENT);

                /* 4. Allocate trap context on stack (16-byte aligned) */
                int aligned_trap_size = (TRAP_SIZE + 15) & ~15;  /* 208 is already aligned */
                ARM64_SUB_IMM_X(SP, SP, aligned_trap_size);

                /* 5. Store prev = old trap_current to new trap */
                ARM64_STR_X(X1, SP, TRAP_OFFSET_PREV);

                /* 6. Determine tcheck value
                 * Look at the catch handler to see what type it filters.
                 * Pattern: trap E,@catch followed by OCatch or type check code.
                 */
                hl_opcode *cat = f->ops + opCount + 1;
                hl_opcode *next = f->ops + opCount + 1 + o->p2;
                hl_opcode *next2 = f->ops + opCount + 2 + o->p2;
                void *tcheck_val = NULL;

                if (cat->op == OCatch ||
                    (next->op == OGetGlobal && next2->op == OCall2 &&
                     next2->p3 == next->p1 && dst->stack.id == (int)(intptr_t)next2->extra)) {
                    int gindex = cat->op == OCatch ? cat->p1 : next->p2;
                    hl_type *gt = m->code->globals[gindex];
                    while (gt->kind == HOBJ && gt->obj->super) gt = gt->obj->super;
                    if (gt->kind == HOBJ && gt->obj->nfields && gt->obj->fields[0].t->kind == HTYPE) {
                        tcheck_val = m->globals_data + m->globals_indexes[gindex];
                    }
                }

                /* Load tcheck value and store to trap->tcheck */
                if (tcheck_val) {
                    /* Load the type check value from globals */
                    load_imm64(ctx, X2, (int64_t)(intptr_t)tcheck_val);
                    ARM64_LDR_X(X2, X2, 0);  /* Dereference to get actual value */
                } else {
                    ARM64_MOVZ_X(X2, 0);
                }
                ARM64_STR_X(X2, SP, TRAP_OFFSET_TCHECK);

                /* 7. Update tinf->trap_current = &new_trap (SP)
                 * NOTE: Cannot use STR SP directly because register 31 in STR Rt field
                 * is XZR not SP. Copy SP to X1 first, then store X1.
                 */
                ARM64_ADD_IMM_X(X1, SP, 0);  /* X1 = SP */
                ARM64_STR_X(X1, X19, TINF_OFFSET_TRAP_CURRENT);

                /* 8. Call setjmp(trap->buf) where trap->buf is at SP+0 */
                /* X0 = address of trap->buf = SP
                 * NOTE: Cannot use MOV X0, SP because ORR (which MOV aliases to)
                 * treats reg 31 as XZR not SP. Use ADD instead.
                 */
                ARM64_ADD_IMM_X(X0, SP, 0);
                call_native(ctx, hl_setjmp_wrapper, 0);
                /* setjmp returns 0 on first call, non-zero when longjmp is called */

                /* 9. Test return value: if X0 == 0, continue normal path */
                ARM64_CMP_IMM_X(X0, 0);
                jenter = BUF_POS();
                EMIT(0x54000000);  /* B.EQ placeholder - will patch */

                /* 10. Exception caught path (setjmp returned non-zero):
                 *     - Deallocate trap from stack
                 *     - Get exception value from tinf
                 *     - Store to dst
                 *     - Jump to catch handler
                 */
                ARM64_ADD_IMM_X(SP, SP, aligned_trap_size);

                /* Load exc_value from tinf (X19 still has tinf) */
                ARM64_LDR_X(X0, X19, TINF_OFFSET_EXC_VALUE);

                /* Store exception to dst */
                preg *pd = alloc_cpu(ctx, dst, false);
                ARM64_MOV_X(pd->id, X0);
                store(ctx, dst, pd, false);

                /* Jump to catch handler (o->p2 ops ahead) */
                jtrap = BUF_POS();
                EMIT(0x14000000);  /* B placeholder - will patch */
                add_jump(ctx, jtrap, (opCount + 1) + o->p2);

                /* 11. Patch the B.EQ jump to continue here (normal path) */
                {
                    int offset = (BUF_POS() - jenter) / 4;
                    unsigned int *patch = (unsigned int *)(ctx->startBuf + jenter);
                    *patch = 0x54000000 | ((offset & 0x7FFFF) << 5);  /* B.EQ with offset */
                }

                #undef TRAP_SIZE
                #undef TRAP_OFFSET_PREV
                #undef TRAP_OFFSET_TCHECK
                #undef TINF_OFFSET_TRAP_CURRENT
                #undef TINF_OFFSET_EXC_VALUE
            }
            break;

        case OEndTrap:
            {
                /*
                 * OEndTrap: Unlink the current trap and deallocate it.
                 *
                 * Note: If an exception was caught by OTrap, the exception path
                 * already deallocated the trap and jumped to the catch handler.
                 * In that case, trap_current might be NULL or pointing to a
                 * different trap. We need to check if we actually have a trap
                 * to clean up by comparing SP with the expected trap location.
                 *
                 * Simplified approach: Only cleanup if trap_current is not NULL.
                 * If trap_current is NULL, it means we came through the exception
                 * path which already cleaned up, or there's no trap.
                 */
                #define TRAP_SIZE 208
                #define TRAP_OFFSET_PREV 192
                #define TINF_OFFSET_TRAP_CURRENT 24

                int jskip;
                int aligned_trap_size = (TRAP_SIZE + 15) & ~15;

                /* Discard all register bindings */
                discard_regs(ctx, false);

                /* 1. Call hl_get_thread() */
                call_native(ctx, hl_get_thread, 0);
                /* X0 = tinf */

                /* 2. Load current trap from tinf->trap_current */
                ARM64_LDR_X(X1, X0, TINF_OFFSET_TRAP_CURRENT);

                /* 3. If trap_current is NULL, skip cleanup */
                ARM64_CMP_IMM_X(X1, 0);
                jskip = BUF_POS();
                EMIT(0x54000000);  /* B.EQ placeholder */

                /* 4. Load prev from trap->prev */
                ARM64_LDR_X(X2, X1, TRAP_OFFSET_PREV);

                /* 5. Update tinf->trap_current = prev */
                ARM64_STR_X(X2, X0, TINF_OFFSET_TRAP_CURRENT);

                /* 6. Deallocate trap from stack */
                ARM64_ADD_IMM_X(SP, SP, aligned_trap_size);

                /* 7. Patch the B.EQ jump to skip here */
                {
                    int offset = (BUF_POS() - jskip) / 4;
                    unsigned int *patch = (unsigned int *)(ctx->startBuf + jskip);
                    *patch = 0x54000000 | ((offset & 0x7FFFF) << 5);  /* B.EQ with offset */
                }

                #undef TRAP_SIZE
                #undef TRAP_OFFSET_PREV
                #undef TINF_OFFSET_TRAP_CURRENT
            }
            break;
            
        case OCatch:
            /* OCatch is only used for typing, no code generation needed */
            break;
            
        /* Dynamic get/set */
        case ODynGet:
            {
                preg *pobj = alloc_cpu(ctx, ra, true);
                /* Compute hash from field name string at compile time */
                int hash = hl_hash_utf8(m->code->strings[o->p3]);
                
                /* Choose correct function based on destination type */
                void *dynget_fn;
                int needs_type_arg = 1;
                switch (dst->t->kind) {
                case HF32:
                    dynget_fn = hl_dyn_getf;
                    needs_type_arg = 0;
                    break;
                case HF64:
                    dynget_fn = hl_dyn_getd;
                    needs_type_arg = 0;
                    break;
                case HI64:
                    dynget_fn = hl_dyn_geti64;
                    needs_type_arg = 0;
                    break;
                case HI32:
                case HUI16:
                case HUI8:
                case HBOOL:
                    dynget_fn = hl_dyn_geti;
                    break;
                default:
                    dynget_fn = hl_dyn_getp;
                    break;
                }
                
                /* Invalidate vreg bindings before overwriting argument registers */
                scratch(REG_AT(X0));
                scratch(REG_AT(X1));
                if (needs_type_arg) scratch(REG_AT(X2));
                
                /* Args: X0=object, X1=hash, X2=type (for some functions) */
                ARM64_MOV_X(X0, pobj->id);
                load_imm64(ctx, X1, hash);
                if (needs_type_arg)
                    load_imm64(ctx, X2, (int64_t)(intptr_t)dst->t);
                
                call_native(ctx, dynget_fn, 0);
                
                /* Store result - handle float returns differently */
                if (IS_FLOAT(dst)) {
                    /* Float/double result is in V0/D0 */
                    preg *pd = alloc_fpu(ctx, dst, false);
                    if (dst->t->kind == HF32) {
                        if (pd->id != 0)
                            ARM64_FMOV_S(pd->id, 0);
                    } else {
                        if (pd->id != 0)
                            ARM64_FMOV_D(pd->id, 0);
                    }
                    store(ctx, dst, pd, true);
                } else {
                    /* Integer/pointer result is in X0 */
                    ARM64_MOV_X(X20, X0);
                    preg *pd = alloc_cpu(ctx, dst, false);
                    ARM64_MOV_X(pd->id, X20);
                    store(ctx, dst, pd, true);
                }
            }
            break;
            
        case ODynSet:
            {
                /* Compute hash from field name string at compile time */
                int hash = hl_hash_gen(hl_get_ustring(m->code, o->p2), true);
                
                /* Choose correct function and argument setup based on value type */
                void *dynset_fn;
                switch (rb->t->kind) {
                case HF32:
                    dynset_fn = hl_dyn_setf;
                    {
                        preg *pval = alloc_fpu(ctx, rb, true);
                        /* Save float value to callee-saved FPU register first */
                        int saved_val = pval->id;
                        if (saved_val < 8) {
                            ARM64_FMOV_S(8, saved_val);  /* Save to V8 */
                            saved_val = 8;
                        }
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        /* Now load object - may need to reload from stack */
                        preg *pobj = alloc_cpu(ctx, dst, true);
                        ARM64_MOV_X(X0, pobj->id);
                        load_imm64(ctx, X1, hash);
                        /* Float value goes in S0/V0 */
                        if (saved_val != 0)
                            ARM64_FMOV_S(0, saved_val);
                    }
                    break;
                case HF64:
                    dynset_fn = hl_dyn_setd;
                    {
                        preg *pval = alloc_fpu(ctx, rb, true);
                        /* Save double value to callee-saved FPU register first */
                        int saved_val = pval->id;
                        if (saved_val < 8) {
                            ARM64_FMOV_D(8, saved_val);  /* Save to V8 */
                            saved_val = 8;
                        }
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        /* Now load object - may need to reload from stack */
                        preg *pobj = alloc_cpu(ctx, dst, true);
                        ARM64_MOV_X(X0, pobj->id);
                        load_imm64(ctx, X1, hash);
                        /* Double value goes in D0/V0 */
                        if (saved_val != 0)
                            ARM64_FMOV_D(0, saved_val);
                    }
                    break;
                case HI64:
                    dynset_fn = hl_dyn_seti64;
                    {
                        preg *pval = alloc_cpu(ctx, rb, true);
                        /* Save value to X20 (callee-saved) to survive alloc_cpu below */
                        ARM64_MOV_X(X20, pval->id);
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        scratch(REG_AT(X2));
                        /* Now load object - may need to reload from stack */
                        preg *pobj = alloc_cpu(ctx, dst, true);
                        ARM64_MOV_X(X0, pobj->id);
                        load_imm64(ctx, X1, hash);
                        ARM64_MOV_X(X2, X20);
                    }
                    break;
                case HI32:
                case HUI16:
                case HUI8:
                case HBOOL:
                    dynset_fn = hl_dyn_seti;
                    {
                        preg *pval = alloc_cpu(ctx, rb, true);
                        /* Save value to X20 (callee-saved) to survive alloc_cpu below */
                        ARM64_MOV_X(X20, pval->id);
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        scratch(REG_AT(X2));
                        scratch(REG_AT(X3));
                        /* Now load object - may need to reload from stack */
                        preg *pobj = alloc_cpu(ctx, dst, true);
                        ARM64_MOV_X(X0, pobj->id);
                        load_imm64(ctx, X1, hash);
                        load_imm64(ctx, X2, (int64_t)(intptr_t)rb->t);
                        ARM64_MOV_X(X3, X20);
                    }
                    break;
                default:
                    dynset_fn = hl_dyn_setp;
                    {
                        preg *pval = alloc_cpu(ctx, rb, true);
                        /* Save value to X20 (callee-saved) to survive alloc_cpu below */
                        ARM64_MOV_X(X20, pval->id);
                        scratch(REG_AT(X0));
                        scratch(REG_AT(X1));
                        scratch(REG_AT(X2));
                        scratch(REG_AT(X3));
                        /* Now load object - may need to reload from stack */
                        preg *pobj = alloc_cpu(ctx, dst, true);
                        ARM64_MOV_X(X0, pobj->id);
                        load_imm64(ctx, X1, hash);
                        load_imm64(ctx, X2, (int64_t)(intptr_t)rb->t);
                        ARM64_MOV_X(X3, X20);
                    }
                    break;
                }
                call_native(ctx, dynset_fn, 0);
            }
            break;
            
        /* Reference data operations */
        case ORefData:
            {
                preg *pr = alloc_cpu(ctx, ra, true);
                preg *pd = alloc_cpu(ctx, dst, false);
                
                switch (ra->t->kind) {
                case HARRAY:
                    /* Return pointer to array data (skip header) */
                    ARM64_ADD_IMM_X(pd->id, pr->id, sizeof(varray));
                    break;
                default:
                    ARM64_MOV_X(pd->id, pr->id);
                    break;
                }
                store(ctx, dst, pd, false);
            }
            break;
            
        case ORefOffset:
            {
                preg *pr = alloc_cpu(ctx, ra, true);
                RLOCK(pr);
                preg *poff = alloc_cpu(ctx, rb, true);
                RLOCK(poff);
                preg *pd = alloc_cpu(ctx, dst, false);
                
                /* Scale offset by element size */
                int size = hl_type_size(dst->t->tparam);
                preg *tmp = alloc_reg(ctx, RCPU);
                switch (size) {
                case 1:
                    ARM64_ADD_X(pd->id, pr->id, poff->id);
                    break;
                case 2:
                    ARM64_LSL_IMM_X(tmp->id, poff->id, 1);
                    ARM64_ADD_X(pd->id, pr->id, tmp->id);
                    break;
                case 4:
                    ARM64_LSL_IMM_X(tmp->id, poff->id, 2);
                    ARM64_ADD_X(pd->id, pr->id, tmp->id);
                    break;
                case 8:
                    ARM64_LSL_IMM_X(tmp->id, poff->id, 3);
                    ARM64_ADD_X(pd->id, pr->id, tmp->id);
                    break;
                default:
                    /* Multiply offset by size */
                    load_imm64(ctx, tmp->id, size);
                    EMIT(0x9B007C00 | ((poff->id) << 5) | (tmp->id << 16) | (tmp->id)); /* MUL tmp, poff, tmp */
                    ARM64_ADD_X(pd->id, pr->id, tmp->id);
                    break;
                }
                RUNLOCK(pr);
                RUNLOCK(poff);
                store(ctx, dst, pd, false);
            }
            break;
            
        /* Prefetch - hint to cache */
        case OPrefetch:
            /* PRFM instruction - optional, can be NOP */
            ARM64_NOP();
            break;
            
        /* Inline assembly */
        case OAsm:
            {
                switch (o->p1) {
                case 0: /* Emit raw byte - not meaningful on ARM64 (4-byte aligned) */
                    /* Emit as part of a word if needed */
                    break;
                case 1: /* Scratch CPU register */
                    if (o->p2 < RCPU_COUNT)
                        scratch(&ctx->pregs[o->p2]);
                    break;
                case 2: /* Read VM register into physical register */
                    {
                        int ridx = o->p3 - 1;
                        if (ridx >= 0 && ridx < f->nregs) {
                            vreg *r = R(ridx);
                            preg *pd = &ctx->pregs[o->p2];
                            preg *ps = alloc_cpu(ctx, r, true);
                            if (ps->id != pd->id)
                                ARM64_MOV_X(pd->id, ps->id);
                        }
                    }
                    break;
                case 3: /* Write physical register to VM register */
                    {
                        int ridx = o->p3 - 1;
                        if (ridx >= 0 && ridx < f->nregs) {
                            vreg *r = R(ridx);
                            preg *ps = &ctx->pregs[o->p2];
                            store(ctx, r, ps, true);
                        }
                    }
                    break;
                case 4: /* Get stack offset */
                    /* Not commonly used, skip for now */
                    break;
                default:
                    ARM64_BRK(0xA5A5);
                    break;
                }
            }
            break;

        default:
            /* Unsupported opcode - emit breakpoint for debugging */
            printf("ARM64 JIT: Unsupported opcode %s (%d) in function %d at op %d\n", 
                   hl_op_name(o->op), o->op, f->findex, opCount);
            fflush(stdout);
            ARM64_BRK(o->op);
            break;
        }
        
        /* DEBUG: Force all values to stack after each opcode to diagnose register tracking issues */
#ifdef JIT_FORCE_STACK
        discard_regs(ctx, true);
#endif

        /* Validate bindings for crash function - DISABLED */
        
        ctx->opsPos[opCount + 1] = BUF_POS();
        
        /* Record debug offset for this opcode */
        if (debug16 || debug32) {
            int dbg_size = BUF_POS() - codePos;
            if (debug16 && dbg_size > 0xFF00) {
                /* Switch to 32-bit offsets */
                debug32 = (int*)malloc(sizeof(int) * (f->nops + 1));
                if (debug32) {
                    for (int di = 0; di <= opCount; di++)
                        debug32[di] = debug16[di];
                    free(debug16);
                    debug16 = NULL;
                }
            }
            if (debug16) debug16[opCount + 1] = (unsigned short)dbg_size;
            else if (debug32) debug32[opCount + 1] = dbg_size;
        }
    }
    
    /* Patch jumps */
    jlist *j = ctx->jumps;
    int jump_count = 0;
    int max_offset = 0;
    int min_offset = 0;
    while (j) {
        int from = j->pos;
        int to = ctx->opsPos[j->target];
        int offset = to - from;
        jump_count++;
        if (offset > max_offset) max_offset = offset;
        if (offset < min_offset) min_offset = offset;
#ifdef JIT_DEBUG
        printf("JUMP PATCH: from=0x%x target_op=%d to=0x%x offset=%d\n", from, j->target, to, offset); fflush(stdout);
#endif
        
        unsigned int *instr = (unsigned int *)(ctx->startBuf + from);
        unsigned int opcode = *instr & 0xFF000000;
        
        if (opcode == 0x14000000) {
            /* Unconditional branch - 26-bit signed offset (±128MB) */
            if (offset < -0x8000000 || offset > 0x7FFFFFF) {
                printf("ARM64 JIT ERROR: Unconditional branch offset %d (0x%x) out of range!\n", offset, offset);
                fflush(stdout);
            }
            *instr = 0x14000000 | ((offset >> 2) & 0x3FFFFFF);
        } else if ((opcode & 0xFF000000) == 0x54000000) {
            /* Conditional branch - 19-bit signed offset (±1MB) */
            if (offset < -0x100000 || offset > 0xFFFFF) {
                printf("ARM64 JIT ERROR: Conditional branch offset %d (0x%x) out of range at pos 0x%x -> target op %d!\n", 
                       offset, offset, from, j->target);
                fflush(stdout);
            }
            *instr = (*instr & 0xFF00001F) | (((offset >> 2) & 0x7FFFF) << 5);
        }
        
        j = j->next;
    }
    
#ifndef JIT_QUIET
    /* Report jump statistics for large functions */
    if (f->nops > 10000) {
        int func_size = BUF_POS() - ctx->functionPos;
        printf("ARM64 JIT COMPILE: Function %d at offset 0x%x-0x%x has %d ops, %d jumps, size=%d bytes\n",
               f->findex, ctx->functionPos, BUF_POS(), f->nops, jump_count, func_size);
        printf("  Stack frame size: %d bytes, nregs=%d\n", ctx->totalRegsSize, f->nregs);
        /* Check for large stack offsets */
        int max_neg = 0;
        for (int i = 0; i < f->nregs; i++) {
            if (ctx->vregs[i].stackPos < max_neg) max_neg = ctx->vregs[i].stackPos;
        }
        printf("  Max negative stackPos: %d (limit is -4095 for SUB_IMM)\n", max_neg);
        if (max_neg < -4095) {
            printf("  *** WARNING: stackPos exceeds immediate encoding limit! ***\n");
        }
        fflush(stdout);
    }
#endif
    
    /* Track function boundaries for crash debugging */
    if (g_func_table_count < 10000) {
        g_func_table[g_func_table_count].findex = f->findex;
        g_func_table[g_func_table_count].start = ctx->functionPos;
        g_func_table[g_func_table_count].end = BUF_POS();
        g_func_table_count++;
    }
    
#ifndef JIT_QUIET
    /* For function 2851 (called from 4781 before crash), print info */
    if (f->findex == 2851) {
        printf("Function 2851 compiled: stackSize=%d, nregs=%d, nops=%d\n",
               ctx->totalRegsSize, f->nregs, f->nops);
        fflush(stdout);
    }
    
    /* Print info for function 4784 (current crash point) */
    if (f->findex == 4784) {
        printf("Function 4784 compiled: stackSize=%d, nregs=%d, nops=%d\n",
               ctx->totalRegsSize, f->nregs, f->nops);
        /* Print first few ops */
        printf("  First 10 ops:\n");
        for (int i = 0; i < 10 && i < f->nops; i++) {
            printf("    op[%d]: %s (p1=%d p2=%d p3=%d)\n",
                   i, hl_op_name(f->ops[i].op), f->ops[i].p1, f->ops[i].p2, f->ops[i].p3);
        }
        fflush(stdout);
    }
    
    /* For function 4781, dump prologue instructions */
    if (f->findex == 4781) {
        printf("Function 4781: totalRegsSize=%d, nregs=%d, nops=%d\n", 
               ctx->totalRegsSize, f->nregs, f->nops);
        
        /* Check vreg31 stack position */
        if (f->nregs > 31) {
            vreg *r31 = &ctx->vregs[31];
            printf("Function 4781: vreg31 stackPos=%d, size=%d\n", r31->stackPos, r31->size);
        }
        
        printf("Function 4781 prologue (first 20 instructions):\n");
        unsigned int *code = (unsigned int*)(ctx->startBuf + ctx->functionPos);
        for (int i = 0; i < 20 && i < (int)((BUF_POS() - ctx->functionPos) / 4); i++) {
            printf("  0x%04x: %08x\n", i * 4, code[i]);
        }
        fflush(stdout);
    }
    
    /* For function 4781, find which op is at crash offset 0x28c8 */
    if (f->findex == 4781) {
        int crash_offset = 0x28c8;  /* Offset within function from crash analysis */
        int found_op = -1;
        for (int i = 0; i < f->nops; i++) {
            int op_start = ctx->opsPos[i] - ctx->functionPos;
            int op_end = (i + 1 < f->nops) ? ctx->opsPos[i+1] - ctx->functionPos : BUF_POS() - ctx->functionPos;
            if (op_start <= crash_offset && crash_offset < op_end) {
                found_op = i;
                printf("Function 4781: Crash at offset 0x%x is in op[%d] = %s (p1=%d p2=%d p3=%d)\n",
                       crash_offset, i, hl_op_name(f->ops[i].op), f->ops[i].p1, f->ops[i].p2, f->ops[i].p3);
                printf("  Op starts at 0x%x, ends at 0x%x\n", op_start, op_end);
                
                /* Print ops around the crash */
                printf("  Context (ops 430-450):\n");
                for (int j = 430; j <= 450 && j < f->nops; j++) {
                    hl_opcode *op = &f->ops[j];
                    int op_offset = ctx->opsPos[j] - ctx->functionPos;
                    printf("    op[%d] @ 0x%04x: %s (p1=%d p2=%d p3=%d)\n", 
                           j, op_offset, hl_op_name(op->op), op->p1, op->p2, op->p3);
                }
                
                /* Dump raw instructions around crash */
                printf("  Raw instructions around crash (0x%x - 0x%x):\n", crash_offset - 0x20, crash_offset + 0x20);
                unsigned char *code_base = ctx->startBuf + ctx->functionPos;
                int dump_start = (crash_offset - 0x20) & ~3;  /* Align to 4 */
                int dump_end = crash_offset + 0x20;
                if (dump_start < 0) dump_start = 0;
                for (int off = dump_start; off < dump_end; off += 4) {
                    unsigned int instr = *(unsigned int *)(code_base + off);
                    char marker = (off == crash_offset) ? '*' : ' ';
                    printf("    %c0x%04x: %08x\n", marker, off, instr);
                }
                
                break;
            }
        }
        if (found_op < 0) {
            printf("Function 4781: Could not find op at crash offset 0x%x\n", crash_offset);
        }
        fflush(stdout);
    }
#endif
    
    /* Save debug info for this function */
    if (ctx->debug) {
        int fid = (int)(f - m->code->functions);
        ctx->debug[fid].start = codePos;
        ctx->debug[fid].offsets = debug32 ? (void*)debug32 : (void*)debug16;
        ctx->debug[fid].large = debug32 != NULL;
    } else {
        /* No debug context, free debug arrays */
        free(debug16);
        free(debug32);
    }
    
    free(is_jump_target);
    return ctx->functionPos;
}

void hl_jit_init(jit_ctx *ctx, hl_module *m) {
    int i;
    
#ifdef JIT_DEBUG
    printf("ARM64 JIT: Initialized\n");
    fflush(stdout);
#endif
    
    /* Initialize module */
    hl_jit_init_module(ctx, m);
    
    /* Initialize physical registers - set lock to 0 (free) */
    for (i = 0; i < REG_COUNT; i++) {
        preg *r = &ctx->pregs[i];
        r->kind = (i < RCPU_COUNT) ? RCPU : RFPU;
        r->id = (i < RCPU_COUNT) ? i : (i - RCPU_COUNT);
        r->lock = 0;
        r->holds = NULL;
    }
    
    /* Reset currentPos so registers appear available */
    ctx->currentPos = 0;
}

void hl_jit_free(jit_ctx *ctx, h_bool can_reset) {
    if (ctx == NULL) return;
    
    if (can_reset) {
        hl_free(&ctx->falloc);
    } else {
        hl_free(&ctx->falloc);
        hl_free(&ctx->galloc);
        free(ctx->vregs);
        free(ctx->opsPos);
        free(ctx);
    }
}

/* Allocate a new JIT context */
jit_ctx *hl_jit_alloc(void) {
    int i;
    jit_ctx *ctx = (jit_ctx *)malloc(sizeof(jit_ctx));
    if (ctx == NULL) return NULL;
    
    memset(ctx, 0, sizeof(jit_ctx));
    hl_alloc_init(&ctx->falloc);
    hl_alloc_init(&ctx->galloc);
    
    /* Initialize registers */
    for (i = 0; i < RCPU_COUNT; i++) {
        preg *r = &ctx->pregs[i];
        r->id = i;
        r->kind = RCPU;
        r->lock = 0;
        r->holds = NULL;
    }
    for (i = 0; i < RFPU_COUNT; i++) {
        preg *r = &ctx->pregs[RCPU_COUNT + i];
        r->id = i;
        r->kind = RFPU;
        r->lock = 0;
        r->holds = NULL;
    }
    
    return ctx;
}

/* Reset JIT context for recompilation */
void hl_jit_reset(jit_ctx *ctx, hl_module *m) {
    ctx->debug = NULL;
    hl_jit_init_module(ctx, m);
}

/* Patch a method to redirect to a new vtable */
void hl_jit_patch_method(void *old_fun, void **new_fun_table) {
    /* Generate ARM64 code to load address and branch:
       ADRP X9, #page
       ADD X9, X9, #offset  
       LDR X9, [X9]
       BR X9
       
       Simpler approach: use absolute address loading
       MOVZ X9, #imm0
       MOVK X9, #imm1, LSL #16
       MOVK X9, #imm2, LSL #32
       MOVK X9, #imm3, LSL #48
       LDR X9, [X9]
       BR X9
    */
    unsigned int *code = (unsigned int *)old_fun;
    uint64_t addr = (uint64_t)(intptr_t)new_fun_table;
    
    /* MOVZ X9, #imm0 */
    code[0] = 0xD2800009 | ((addr & 0xFFFF) << 5);
    /* MOVK X9, #imm1, LSL #16 */
    code[1] = 0xF2A00009 | (((addr >> 16) & 0xFFFF) << 5);
    /* MOVK X9, #imm2, LSL #32 */
    code[2] = 0xF2C00009 | (((addr >> 32) & 0xFFFF) << 5);
    /* MOVK X9, #imm3, LSL #48 */
    code[3] = 0xF2E00009 | (((addr >> 48) & 0xFFFF) << 5);
    /* LDR X9, [X9] */
    code[4] = 0xF9400129;
    /* BR X9 */
    code[5] = 0xD61F0120;
    
    /* Clear instruction cache */
#ifdef HL_WIN
    FlushInstructionCache(GetCurrentProcess(), code, 6 * sizeof(unsigned int));
#else
    __builtin___clear_cache((char *)code, (char *)(code + 6));
#endif
}

/*
 * ARM64 wrapper for dynamic closure calls via hl_dyn_call_obj fallback
 * This is used when the virtual method pointer is null and we need to 
 * call through the wrapper system.
 * 
 * The wrapper takes: (vclosure_wrapper *c, void **args, vdynamic *ret)
 * where args is an array of void* arguments to pass to the wrapped closure.
 * 
 * This is a simplified implementation that calls hl_dyn_call directly.
 */
static void *arm64_wrapper_call(vclosure_wrapper *c, void **args, vdynamic *ret_storage) {
    int nargs = c->cl.t->fun->nargs;
    vdynamic *dyn_args[64];
    
    /* Convert void* args to vdynamic* for hl_dyn_call */
    for (int i = 0; i < nargs; i++) {
        hl_type *t = c->cl.t->fun->args[i];
        if (hl_is_dynamic(t)) {
            dyn_args[i] = (vdynamic *)args[i];
        } else {
            dyn_args[i] = hl_make_dyn(args[i], t);
        }
    }
    
    /* Call the wrapped function dynamically */
    vdynamic *result = hl_dyn_call(c->wrappedFun, dyn_args, nargs);
    
    /* Convert return value */
    hl_type *tret = c->cl.t->fun->ret;
    if (ret_storage) {
        if (result) {
            *ret_storage = *result;
        } else {
            ret_storage->v.ptr = NULL;
        }
    }
    
    switch (tret->kind) {
    case HVOID:
        return NULL;
    case HUI8:
    case HUI16:
    case HI32:
    case HBOOL:
        return (void *)(intptr_t)hl_dyn_casti(&result, &hlt_dyn, tret);
    case HI64:
        return (void *)(intptr_t)hl_dyn_casti64(&result, &hlt_dyn);
    default:
        return hl_dyn_castp(&result, &hlt_dyn, tret);
    }
}

/* 
 * ARM64 get_wrapper function for hl_setup.get_wrapper
 * Returns the wrapper function to use for dynamic calls through virtuals.
 * For ARM64, we use a C function that handles the call dynamically.
 */
static void *arm64_get_wrapper(hl_type *t) {
    (void)t;  /* Same wrapper for all types on ARM64 */
    return arm64_wrapper_call;
}

/*
 * ARM64 trampoline for calling JIT functions from C.
 *
 * ARM64 ABI uses SEPARATE register banks for integer (X0-X7) and floating-point
 * (D0-D7) arguments. JIT-compiled functions use prepare_call_args() which maps
 * arguments to these separate banks.
 *
 * On GCC/Clang: uses naked inline asm to load both register banks from arrays.
 * On MSVC: uses a C-callable function type with all 8+8 args expanded, relying
 * on the compiler to place them in X0-X7 and D0-D7 per ARM64 ABI.
 */
#ifdef HL_WIN

/*
 * On MSVC ARM64, we can't use inline assembly. Instead, we define a function
 * pointer type that takes all 8 integer + 8 double args explicitly, then call
 * through it with args expanded from the arrays. The ARM64 calling convention
 * guarantees these go into X0-X7 and D0-D7 respectively.
 */
typedef uint64_t (*arm64_jit_func_t)(
    uint64_t, uint64_t, uint64_t, uint64_t,
    uint64_t, uint64_t, uint64_t, uint64_t,
    double, double, double, double,
    double, double, double, double
);

/* Call JIT function with explicit integer and FPU args for proper register placement */
static uint64_t arm64_call_jit_c(void *fun, uint64_t *cpu_args, double *fpu_args) {
    arm64_jit_func_t f = (arm64_jit_func_t)fun;
    return f(
        cpu_args[0], cpu_args[1], cpu_args[2], cpu_args[3],
        cpu_args[4], cpu_args[5], cpu_args[6], cpu_args[7],
        fpu_args[0], fpu_args[1], fpu_args[2], fpu_args[3],
        fpu_args[4], fpu_args[5], fpu_args[6], fpu_args[7]
    );
}

#else /* GCC/Clang */

__attribute__((naked, noinline))
static void arm64_call_jit_trampoline(void) {
    __asm__ volatile(
        /* Save frame pointer and link register */
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"

        /* Save function pointer and array pointers to scratch registers */
        "mov x16, x0\n"       /* x16 = function pointer (IP0, scratch per ABI) */
        "mov x9, x1\n"        /* x9  = cpu_args pointer */

        /* Load FPU arguments from fpu_args array (x2) FIRST, before clobbering x2 */
        "ldp d0, d1, [x2]\n"
        "ldp d2, d3, [x2, #16]\n"
        "ldp d4, d5, [x2, #32]\n"
        "ldp d6, d7, [x2, #48]\n"

        /* Load integer arguments from cpu_args array (x9) */
        "ldp x0, x1, [x9]\n"
        "ldp x2, x3, [x9, #16]\n"
        "ldp x4, x5, [x9, #32]\n"
        "ldp x6, x7, [x9, #48]\n"

        /* Call the JIT function - return value in X0 (int/ptr) or D0 (float/double) */
        "blr x16\n"

        /* Restore frame and return - X0 and D0 are preserved from JIT function */
        "ldp x29, x30, [sp], #16\n"
        "ret\n"
    );
}

#endif /* HL_WIN */

/*
 * ARM64 callback_c2hl - Implementation for calling JIT functions from C.
 * Called by the runtime (hl_call_method / hl_dyn_call) via hl_setup.static_call.
 *
 * Uses the assembly trampoline above to properly set up BOTH integer (X0-X7)
 * and FPU (D0-D7) registers per ARM64 ABI, matching how prepare_call_args()
 * maps arguments during JIT compilation.
 *
 * args[i] semantics (from hl_call_method):
 *   - For scalar types (int, float, etc.): args[i] is a POINTER TO the value
 *   - For pointer types (object, etc.):    args[i] IS the actual pointer value
 */
static int callback_call_count = 0;
#define CALLBACK_DEBUG 0

static void *callback_c2hl_arm64(void *_f, hl_type *t, void **args, vdynamic *ret) {
    callback_call_count++;

#if CALLBACK_DEBUG
    if (callback_call_count <= 20 || callback_call_count % 100 == 0) {
        printf("callback_c2hl_arm64: count=%d, nargs=%d, ret_kind=%d\n",
               callback_call_count, t->fun->nargs, t->fun->ret->kind);
        for (int i = 0; i < t->fun->nargs && i < 8; i++)
            printf("  arg[%d] kind=%d\n", i, t->fun->args[i]->kind);
        fflush(stdout);
    }
#endif

    void **f = (void **)_f;
    void *fun = *f;
    int nargs = t->fun->nargs;

    /* Validate function pointer is in JIT code range */
    extern unsigned char *jit_code_base;
    extern int jit_code_size;
    if (fun < (void*)jit_code_base || fun >= (void*)(jit_code_base + jit_code_size)) {
        /* This might be a native function - let runtime handle it */
        if (ret) ret->v.ptr = NULL;
        return NULL;
    }

    /* Ensure instruction cache is synchronized */
#if defined(__APPLE__) && defined(__aarch64__)
    pthread_jit_write_protect_np(1);
#endif
#ifdef HL_WIN
    __dmb(_ARM64_BARRIER_ISH);
    __isb(_ARM64_BARRIER_SY);
#else
    __asm__ volatile("dsb ish" ::: "memory");
    __asm__ volatile("isb" ::: "memory");
#endif

    /* Track for crash handler */
    last_callback_fun = fun;

    /*
     * Prepare SEPARATE integer and FPU argument arrays using independent indices,
     * exactly matching how the JIT's prepare_call_args() and function prologues
     * map parameters to registers:
     *   - Integer/pointer args → X0, X1, X2, ... (cpuIdx)
     *   - Float/double args   → D0, D1, D2, ... (fpuIdx)
     */
#ifdef HL_WIN
    __declspec(align(16)) uint64_t cpu_args[8] = {0};
    __declspec(align(16)) double   fpu_args[8] = {0};
#else
    uint64_t cpu_args[8] __attribute__((aligned(16))) = {0};
    double   fpu_args[8] __attribute__((aligned(16))) = {0};
#endif
    int cpuIdx = 0;
    int fpuIdx = 0;

    for (int i = 0; i < nargs; i++) {
        void *v = args[i];
        hl_type *at = t->fun->args[i];

        switch (at->kind) {
        case HF32:
            if (fpuIdx < 8) {
                /* v points to a float value; promote to double for D register */
                fpu_args[fpuIdx++] = (double)(*(float*)v);
            }
            break;
        case HF64:
            if (fpuIdx < 8) {
                fpu_args[fpuIdx++] = *(double*)v;
            }
            break;
        case HBOOL:
        case HUI8:
            if (cpuIdx < 8)
                cpu_args[cpuIdx++] = (uint64_t)(*(unsigned char*)v);
            break;
        case HUI16:
            if (cpuIdx < 8)
                cpu_args[cpuIdx++] = (uint64_t)(*(unsigned short*)v);
            break;
        case HI32:
            if (cpuIdx < 8)
                cpu_args[cpuIdx++] = (uint64_t)(int64_t)(*(int*)v);
            break;
        case HI64:
            if (cpuIdx < 8)
                cpu_args[cpuIdx++] = *(uint64_t*)v;
            break;
        default:
            /* Pointer types (HOBJ, HDYN, HREF, etc.) - v IS the actual pointer */
            if (cpuIdx < 8)
                cpu_args[cpuIdx++] = (uint64_t)(uintptr_t)v;
            break;
        }
    }

    /* Call JIT function through the trampoline which loads both
     * X0-X7 (from cpu_args) and D0-D7 (from fpu_args) before branching.
     * On MSVC, uses C-callable function with all args expanded.
     * On GCC/Clang, uses naked asm trampoline. */
    switch (t->fun->ret->kind) {
    case HUI8:
    case HUI16:
    case HI32:
    case HBOOL:
#ifdef HL_WIN
        ret->v.i = (int)arm64_call_jit_c(fun, cpu_args, fpu_args);
#else
        ret->v.i = ((int (*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
        return &ret->v.i;

    case HI64:
#ifdef HL_WIN
        ret->v.i64 = (int64_t)arm64_call_jit_c(fun, cpu_args, fpu_args);
#else
        ret->v.i64 = ((int64_t (*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
        return &ret->v.i64;

    case HF64: {
#ifdef HL_WIN
        /* For float returns, we need the result from D0 - cast function to double-returning */
        typedef double (*jit_func_d_t)(uint64_t, uint64_t, uint64_t, uint64_t,
            uint64_t, uint64_t, uint64_t, uint64_t,
            double, double, double, double, double, double, double, double);
        jit_func_d_t fd = (jit_func_d_t)fun;
        ret->v.d = fd(cpu_args[0], cpu_args[1], cpu_args[2], cpu_args[3],
            cpu_args[4], cpu_args[5], cpu_args[6], cpu_args[7],
            fpu_args[0], fpu_args[1], fpu_args[2], fpu_args[3],
            fpu_args[4], fpu_args[5], fpu_args[6], fpu_args[7]);
#else
        ret->v.d = ((double (*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
        return &ret->v.d;
    }
    case HF32: {
#ifdef HL_WIN
        typedef float (*jit_func_f_t)(uint64_t, uint64_t, uint64_t, uint64_t,
            uint64_t, uint64_t, uint64_t, uint64_t,
            double, double, double, double, double, double, double, double);
        jit_func_f_t ff = (jit_func_f_t)fun;
        ret->v.f = ff(cpu_args[0], cpu_args[1], cpu_args[2], cpu_args[3],
            cpu_args[4], cpu_args[5], cpu_args[6], cpu_args[7],
            fpu_args[0], fpu_args[1], fpu_args[2], fpu_args[3],
            fpu_args[4], fpu_args[5], fpu_args[6], fpu_args[7]);
#else
        ret->v.f = ((float (*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
        return &ret->v.f;
    }
    case HVOID:
#ifdef HL_WIN
        arm64_call_jit_c(fun, cpu_args, fpu_args);
#else
        ((void (*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
        return NULL;

    default:
        /* Pointer/Object return types */
#ifdef HL_WIN
        return (void*)(uintptr_t)arm64_call_jit_c(fun, cpu_args, fpu_args);
#else
        return ((void *(*)(void*, uint64_t*, double*))arm64_call_jit_trampoline)(fun, cpu_args, fpu_args);
#endif
    }
}

/* Main JIT compilation entry point - finalize and return code */
void *hl_jit_code(jit_ctx *ctx, hl_module *m, int *codesize, hl_debug_infos **debug, hl_module *previous) {
    jlist *c;
    int size;
    unsigned char *code;
    
    (void)previous; /* TODO: Handle hot reload */
    
#ifdef JIT_DEBUG
    printf("ARM64 JIT: hl_jit_code called, ctx=%p, startBuf=%p, buf.b=%p\n",
           (void*)ctx, (void*)ctx->startBuf, (void*)ctx->buf.b);
#endif
    
    if (ctx->startBuf == NULL) {
        printf("ARM64 JIT: ERROR - startBuf is NULL!\n");
        return NULL;
    }
    
    size = BUF_POS();
    
    /* Align to page size */
    if (size & 4095) size += 4096 - (size & 4095);
    
#ifdef JIT_DEBUG
    printf("ARM64 JIT: Allocating %d bytes of executable memory, BUF_POS=%d\n", size, BUF_POS());
#endif
    
    code = (unsigned char *)hl_alloc_executable_memory(size);
    if (code == NULL) {
        printf("ARM64 JIT: Failed to allocate executable memory!\n");
        return NULL;
    }
#ifdef JIT_DEBUG
    printf("ARM64 JIT: Got code at %p\n", (void*)code);
#endif

    /* Update global tracking for debug */
    jit_code_base = code;
    jit_code_size = size;
    
#if defined(__APPLE__) && defined(__aarch64__)
    /* Apple Silicon: disable write protection before writing to JIT memory */
    pthread_jit_write_protect_np(0);
#endif
    
    /* Copy generated code */
    memcpy(code, ctx->startBuf, BUF_POS());
    
    *codesize = size;
    *debug = ctx->debug;
    
    /* Patch function calls */
    c = ctx->calls;
    int patch_count = 0;
    while (c) {
        void *target_addr;
        
        if (c->target < 0) {
            /* Static function reference */
            target_addr = ctx->static_functions[-c->target - 1];
            if ((intptr_t)target_addr < 0x100000)
                target_addr = (void *)(code + (intptr_t)target_addr);
#ifdef JIT_DEBUG
            if (patch_count < 5)
                printf("ARM64 JIT: Patch %d: static func %d -> %p\n", patch_count, -c->target - 1, target_addr);
#endif
        } else {
            /* Function pointer - stored as offset at this point */
            intptr_t offset = (intptr_t)m->functions_ptrs[c->target];
            /* Note: offset 0 is valid (function at start of code) */
            /* We can't distinguish "not compiled" from "offset 0" easily here */
            /* For now, assume all functions are compiled - use the offset */
            target_addr = (void *)(code + offset);
            
#ifndef JIT_QUIET
            /* Debug: check if offset looks valid */
            if (offset == 0 && c->target != 0) {
                printf("ARM64 JIT WARNING: Function %d has offset 0 (possibly not compiled yet?)\n", c->target);
                fflush(stdout);
            }
#endif
#ifdef JIT_DEBUG
            printf("ARM64 JIT: Patch %d: func %d offset 0x%lx -> %p (code=%p)\n", patch_count, c->target, (unsigned long)offset, target_addr, code);
            fflush(stdout);
#endif
        }
        patch_count++;
        
        /* Patch the address at c->pos */
        /* The call site stores a 64-bit address that needs patching */
        unsigned int *patch_site = (unsigned int *)(code + c->pos);
        uint64_t addr = (uint64_t)(intptr_t)target_addr;
        
        /* Regenerate MOVZ/MOVK sequence */
        unsigned int movz = 0xD2800009 | ((addr & 0xFFFF) << 5);
        unsigned int movk1 = 0xF2A00009 | (((addr >> 16) & 0xFFFF) << 5);
        unsigned int movk2 = 0xF2C00009 | (((addr >> 32) & 0xFFFF) << 5);
        unsigned int movk3 = 0xF2E00009 | (((addr >> 48) & 0xFFFF) << 5);
        
#ifdef JIT_DEBUG
        if (patch_count < 500) {
            printf("ARM64 JIT: Patching at offset %d: %08x %08x %08x %08x -> addr %llx\n",
                   c->pos, movz, movk1, movk2, movk3, (unsigned long long)addr);
        }
#endif
        
        patch_site[0] = movz;
        patch_site[1] = movk1;
        patch_site[2] = movk2;
        patch_site[3] = movk3;
        
        c = c->next;
    }
    
    /* Patch static closures
     * Note: At this point, m->functions_ptrs contains OFFSETS (not absolute addresses).
     * The conversion to absolute addresses happens in module.c AFTER hl_jit_code returns.
     * So we need to compute absolute addresses ourselves.
     */
    vclosure *cl = ctx->closure_list;
    int closure_count = 0;
    while (cl) {
        closure_count++;
        vclosure *next = cl->value;  /* value is used to link the list during compilation */
        int findex = (int)(intptr_t)cl->fun;  /* fun stores findex during compilation */
        
        /* m->functions_ptrs[findex] contains offset at this point */
        intptr_t offset = (intptr_t)m->functions_ptrs[findex];
        cl->fun = (unsigned char *)code + offset;
        cl->value = NULL;  /* Clear the link */
        cl = next;
    }
#ifndef JIT_QUIET
    printf("ARM64 JIT: Patched %d static closures\n", closure_count);
#endif
    
#if defined(__APPLE__) && defined(__aarch64__)
    /* Apple Silicon: proper cache management sequence
     * 1. Flush data cache to ensure writes are visible
     * 2. Switch to execute mode
     * 3. Invalidate instruction cache
     */
    sys_dcache_flush(code, size);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(code, size);
#elif defined(HL_WIN)
    /* Windows ARM64: flush instruction cache */
    FlushInstructionCache(GetCurrentProcess(), code, size);
#else
    /* Non-Apple Unix: use __builtin___clear_cache */
    __builtin___clear_cache((char *)code, (char *)code + size);
#endif
    
    /* Set up runtime callbacks - must be done once */
    static bool setup_done = false;
    if (!setup_done) {
        hl_setup.static_call = callback_c2hl_arm64;
        hl_setup.static_call_ref = true;
        hl_setup.get_wrapper = arm64_get_wrapper;  /* Enable dynamic fallback for virtuals */
#ifdef HL_WIN
        /* Custom longjmp that bypasses SEH unwinding through JIT frames.
         * Without this, longjmp calls RtlUnwindEx which crashes because
         * JIT code has no registered unwind info. */
        hl_setup.throw_jump = (void(*)(jmp_buf, int))(code + ctx->longjump);
#endif
#ifndef HL_WIN
        /* Install crash handler for debugging using sigaction with SA_SIGINFO */
        struct sigaction act;
        memset(&act, 0, sizeof(act));
        act.sa_sigaction = arm64_crash_handler_siginfo;
        act.sa_flags = SA_SIGINFO;
        sigemptyset(&act.sa_mask);
        sigaction(SIGBUS, &act, NULL);
        sigaction(SIGSEGV, &act, NULL);
        sigaction(SIGTRAP, &act, NULL);
#endif
        setup_done = true;
#ifdef JIT_DEBUG
        printf("ARM64 JIT: Set hl_setup.static_call = %p\n", (void*)callback_c2hl_arm64);
#endif
    }
    
#ifdef JIT_DEBUG
    printf("ARM64 JIT: Compiled %d bytes of code\n", size);
    
    /* Dump first few functions for debugging */
    static int dump_count = 0;
    if (dump_count < 3) {
        printf("\n=== JIT Code Dump (function %d) ===\n", dump_count);
        printf("Code address: %p\n", (void*)code);
        printf("Code size: %d bytes\n", BUF_POS());
        
        /* Dump as hex for manual disassembly */
        unsigned int *instructions = (unsigned int *)code;
        int num_instr = BUF_POS() / 4;
        if (num_instr > 64) num_instr = 64;  /* Limit dump size */
        
        for (int i = 0; i < num_instr; i++) {
            if (i % 4 == 0) printf("\n%04x: ", i * 4);
            printf("%08x ", instructions[i]);
        }
        printf("\n\n");
        
        /* Also write to a file for llvm-objdump */
        char filename[64];
#ifdef HL_WIN
        snprintf(filename, sizeof(filename), "jit_dump_%d.bin", dump_count);
#else
        snprintf(filename, sizeof(filename), "/tmp/jit_dump_%d.bin", dump_count);
#endif
        FILE *f = fopen(filename, "wb");
        if (f) {
            fwrite(code, 1, BUF_POS(), f);
            fclose(f);
            printf("Wrote %s - disassemble with:\n", filename);
            printf("  llvm-objdump -d --triple=aarch64 %s\n\n", filename);
        }
        
        dump_count++;
    }
#endif

#ifndef JIT_QUIET
    printf("ARM64 JIT: Compilation complete, code at %p, size=%d\n", (void*)code, size);
    
    /* Dump functions near crash offset 0x24F7C4 for debugging */
    int target_offset = 0x24F7C4;
    printf("ARM64 JIT: Functions near offset 0x%x:\n", target_offset);
    int func4781_start = 0, func4781_end = 0;
    for (int i = 0; i < g_func_table_count; i++) {
        if (g_func_table[i].findex == 4781) {
            func4781_start = g_func_table[i].start;
            func4781_end = g_func_table[i].end;
        }
        if (g_func_table[i].start <= target_offset && g_func_table[i].end > target_offset) {
            printf("  -> MATCH: findex=%d at 0x%x-0x%x (contains crash addr)\n", 
                   g_func_table[i].findex, g_func_table[i].start, g_func_table[i].end);
            
            /* If it's function 4781, find the specific op */
            if (g_func_table[i].findex == 4781) {
                int offset_in_func = target_offset - g_func_table[i].start;
                printf("  Crash offset within func 4781: 0x%x (%d bytes)\n", offset_in_func, offset_in_func);
            }
        } else if (g_func_table[i].end >= target_offset - 0x200 && 
                   g_func_table[i].start <= target_offset + 0x200) {
            printf("  NEAR: findex=%d at 0x%x-0x%x\n", 
                   g_func_table[i].findex, g_func_table[i].start, g_func_table[i].end);
        }
    }
    fflush(stdout);
#endif
    
    return code;
}

#else
#error "jit_arm64.c should only be compiled on ARM64 platforms"
#endif
