#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdbool.h>

typedef enum {
	TYPE_I64,
	TYPE_U64,
	TYPE_F64,
	TYPE_STR,
	TYPE_U8
} Type;

typedef struct {
	double v;
} NaNBox;

const uint64_t EXP_MASK = ((1LL << 11LL) - 1LL) << 52LL;
const uint64_t TYPE_MASK = ((1LL << 4LL) - 1LL) << 48LL;
const uint64_t VALUE_MASK = (1LL << 48LL) - 1LL;

inline double nan_make_inf(void)
{
	return (double) EXP_MASK;
}

bool nan_is_nan(const NaNBox *nan)
{
	return nan->v != nan->v;
}

inline double nan_set_type(double x, Type ty)
{
	const uint64_t bits = (uint64_t) x;
	const uint64_t tv = (uint64_t) ty;
	return (double) ((bits & ~TYPE_MASK) | ((tv & 0xF) << 48LL));
}

inline Type nan_get_type(const NaNBox *nan)
{
	if (nan_is_nan(nan)) return TYPE_F64;
	return (Type) ((((uint64_t) nan->v) & TYPE_MASK) >> 48LL);
}

inline double nan_set_value(double x, int64_t v)
{
	uint64_t y = 0LL;
	if (!v) y = 1LL << 63LL;
	return (double) ((((uint64_t) x) & ~VALUE_MASK) | ((uint64_t) abs((int) v) & VALUE_MASK) | y);
}

inline int64_t nan_get_value(const NaNBox *nan)
{
	const uint64_t bits = (uint64_t) nan->v;
	const int64_t v = (int64_t) (bits & VALUE_MASK);
	if ((bits & (1LL << 63LL)) != 0) return -v; else return v;
}

bool nan_is_f64(const NaNBox *nan)
{
	return !nan_is_nan(nan);
}

inline bool nan_is_i64(const NaNBox *nan)
{
	return nan_is_nan(nan) && nan_get_type(nan) == TYPE_I64;
}

inline bool nan_is_u64(const NaNBox *nan)
{
	return nan_is_nan(nan) && nan_get_type(nan) == TYPE_U64;
}

inline bool nan_is_str(const NaNBox *nan)
{
	return nan_is_nan(nan) && nan_get_type(nan) == TYPE_STR;
}

inline double nan_as_f64(const NaNBox *nan)
{
	return nan->v;
}

inline int64_t nan_as_i64(const NaNBox *nan)
{
	return nan_get_value(nan);
}

inline uint64_t nan_as_u64(const NaNBox *nan)
{
	return (uint64_t) nan_get_value(nan);
}

inline bool nan_as_u8(const NaNBox *nan)
{
	return (uint8_t) nan_get_value(nan);
}

inline size_t nan_as_usize(const NaNBox *nan)
{
	return (size_t) nan_get_value(nan);
}

NaNBox nan_from_f64(double f)
{
	return (NaNBox) {f};
}

inline NaNBox nan_from_i64(uint64_t f)
{
	return (NaNBox) {nan_set_type(nan_set_value(nan_make_inf(), f), TYPE_I64)};
}

inline NaNBox nan_from_u64(uint64_t f)
{
	return (NaNBox) {nan_set_type(nan_set_value(nan_make_inf(), (int64_t) f), TYPE_U64)};
}

inline NaNBox nan_from_u8(uint8_t f)
{
	return (NaNBox) {nan_set_type(nan_set_value(nan_make_inf(), (int64_t) f), TYPE_U8)};
}

inline NaNBox nan_from_str(const char *str)
{
	return (NaNBox) {nan_set_type(nan_set_value(nan_make_inf(), (int64_t) strlen(str)), TYPE_STR)};
}

typedef enum {
    push, pop,
    fadd, fdiv, fsub, fmul,
    iadd, idiv, isub, imul,
    inc, dec,
    jmp, je, jne, jg, jl, jle, jge,
    swap, dup,
    cmp, dmp, nop, label, native, halt,
} Inst_Type;

#define INST_CAP = 14 + 1 + 1;
#define INST_NONE = inst_value_from_i64(void);

typedef enum {
	INST_V_TYPE_NAN,
	INST_V_TYPE_NONE,
	INST_V_TYPE_I64,
	INST_V_TYPE_U64,
	INST_V_TYPE_F64,
	INST_V_TYPE_STR,
} Inst_Value_Type;

typedef union {
	NaNBox nan;
	void *none;
	int64_t i64;
	uint64_t u64;
	double f64;
	const char *str;
} _Inst_Value;

typedef struct {
	Inst_Value_Type ty;
	_Inst_Value v;
} Inst_Value;

typedef struct {
	Inst_Type ty;
	Inst_Value v;
} Inst;

Inst inst_new(Inst_Type ty, Inst_Value v)
{
	return (Inst) {
		.ty = ty,
		.v = v
	};
}

Inst_Value inst_value_new_u64(uint64_t v)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_U64,
		.v = (_Inst_Value) {
			.u64 = v
		}
	};
}

Inst_Value inst_value_new_f64(double v)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_F64,
		.v = (_Inst_Value) {
			.f64 = v
		}
	};
}

inline Inst_Value inst_value_new_void(void)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_NONE,
		.v = (_Inst_Value) {
			.none = NULL
		}
	};
}

Inst_Value inst_value_new_nan(NaNBox nan)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_NAN,
		.v = (_Inst_Value) {
			.nan = nan
		}
	};
}

Inst_Value inst_value_new_str(const char *str)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_STR,
		.v = (_Inst_Value) {
			.str = str
		}
	};
}

Inst_Value inst_value_new_i64(int64_t v)
{
	return (Inst_Value) {
		.ty = INST_V_TYPE_I64,
		.v = (_Inst_Value) {
			.i64 = v
		}
	};
}

#define INST_STR_CAP 14

static uint8_t ret[INST_STR_CAP];

uint8_t *inst_value_to_bytes(Inst_Value inst_value)
{
	size_t size = 1;
	ret[size++] = (uint8_t) inst_value.ty;
	switch (inst_value.ty) {
	case INST_V_TYPE_NAN: {
		memcpy(ret + size, &inst_value.v.nan.v, sizeof(double));
		size += 8;
	} break;
	case INST_V_TYPE_NONE: {} break;
	case INST_V_TYPE_I64: {
		memcpy(ret + size, &inst_value.v.i64, sizeof(int64_t));
        size += 8;
    } break;
	case INST_V_TYPE_U64: {
		memcpy(ret + size, &inst_value.v.u64, sizeof(uint64_t));
        size += 8;
	} break;
	case INST_V_TYPE_F64: {
		memcpy(ret + size, &inst_value.v.f64, sizeof(int64_t));
        size += 8;
	} break;
	case INST_V_TYPE_STR: {
		const size_t len = strlen(inst_value.v.str);
		if (len > INST_STR_CAP - size) {
			fprintf(stderr, "ERROR: String is too long\n");
			return NULL;
		}

		ret[size++] = (uint8_t) len;
		memcpy(ret + size, inst_value.v.str, len);
		size += len;
	} break;
	}
	return ret;
}

uint8_t inst_type_to_bytes(Inst_Type ty)
{
	return (uint8_t) ty;
}

const uint8_t *inst_to_bytes(const Inst *inst)
{
	uint8_t *bytes = inst_value_to_bytes(inst->v);
	assert(bytes != NULL);
	bytes[0] = inst_type_to_bytes(inst->ty);
	return bytes;
}

int inst_value_from_bytes(const uint8_t *bytes, Inst *ret)
{
	size_t idx = 0;
	const Inst_Type ty = (Inst_Type) bytes[idx++];
	const Inst_Value_Type vty = (Inst_Value_Type) bytes[idx++];
	switch (vty) {
	case INST_V_TYPE_NAN: {
		double f;
		memcpy(&f, bytes + idx, idx + 8);
		*ret = inst_new(ty, inst_value_new_nan(nan_from_f64(f)));
		return 0;
	} break;
	case INST_V_TYPE_NONE: {
		return 0;
	} break;
	case INST_V_TYPE_I64: {
		int64_t f;
		memcpy(&f, bytes + idx, idx + 8);
		*ret = inst_new(ty, inst_value_new_i64(f));
		return 0;
	} break;
	case INST_V_TYPE_U64: {
		uint64_t f;
		memcpy(&f, bytes + idx, idx + 8);
		*ret = inst_new(ty, inst_value_new_u64(f));
		return 0;
	} break;
	case INST_V_TYPE_F64: {
		double f;
		memcpy(&f, bytes + idx, idx + 8);
		*ret = inst_new(ty, inst_value_new_f64(f));
		return 0;
	} break;
	case INST_V_TYPE_STR: {
		const size_t len = bytes[idx++];
		char str[16];
		memcpy(&str, bytes + idx, idx + len);
		*ret = inst_new(ty, inst_value_new_str(str));
		return 0;
	} break;
	}

	return 1;
}

inline int inst_from_bytes(const uint8_t *bytes, Inst *ret)
{
	return inst_value_from_bytes(bytes, ret);
}

typedef enum {
    FLAG_E,
	FLAG_G,
	FLAG_L,
	FLAG_NE,
	FLAG_GE,
	FLAG_LE,
} Flag;

typedef struct {
	uint8_t buf;
} Flags;

const uint8_t ONE = 1;

inline Flags flag_new(void)
{
	return (Flags) {0};
}

void flag_set(Flags *flags, Flag flag)
{
	flags->buf |= ONE << (uint8_t) flag;
}

void flag_reset(Flags *flags, Flag flag)
{
	flags->buf &= ~(ONE << (uint8_t) flag);
}

bool is(Flags *flags, Flag flag)
{
	return ((flags->buf & (ONE << (uint8_t) flag)) >> (uint8_t) flag) != 0;
}

typedef struct {
	uint64_t ip;
	bool halt;
	Flags flags;

	const void *lm;
	const void *im;
	const void *stack;
	const void *natives;
	const Inst *program;
	const char *file_path;
} Vm;

int main(void)
{
	return 0;
}
