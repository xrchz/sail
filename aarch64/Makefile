THIS_MAKEFILE := $(realpath $(lastword $(MAKEFILE_LIST)))
SAIL_DIR:=$(realpath $(dir $(THIS_MAKEFILE))..)
export SAIL_DIR
SAIL_LIB_DIR:=$(SAIL_DIR)/lib
SAIL:=$(SAIL_DIR)/sail

aarch64.lem: no_vector.sail
	$(SAIL) $^ -o aarch64 -lem -lem_lib Aarch64_extras -memo_z3 -undefined_gen -no_lexp_bounds_check
aarch64_types.lem: aarch64.lem

Aarch64.thy: aarch64_extras.lem aarch64_types.lem aarch64.lem
	lem -isa -outdir . -lib $(SAIL_DIR)/src/gen_lib -lib $(SAIL_DIR)/src/lem_interp $^

LOC_FILES:=prelude.sail full/spec.sail decode_start.sail full/decode.sail decode_end.sail main.sail
include ../etc/loc.mk
