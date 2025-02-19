# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Makefile to build and run AOT tests against the reference system

# Setup build environment
build_dir := build
TVM_ROOT=$(shell cd ../../../../..; pwd)
CRT_ROOT ?= ${TVM_ROOT}/build/standalone_crt
ifeq ($(shell ls -lhd $(CRT_ROOT)),)
$(error "CRT not found. Ensure you have built the standalone_crt target and try again")
endif

FVP_DIR ?= /opt/arm/FVP_Corstone_SSE-300_Ethos-U55/models/Linux64_GCC-6.4/

NPU_MACS ?= 256
NPU_VARIANT ?= U55

MODEL = FVP_Corstone_SSE-300_Ethos-$(NPU_VARIANT)

ARM_CPU ?= ARMCM55
MCPU ?= cortex-m55
MCPU_FLAGS ?=
MFLOAT_ABI ?= hard

DMLC_CORE=${TVM_ROOT}/3rdparty/dmlc-core
ETHOSU_PATH=/opt/arm/ethosu
DRIVER_PATH=${ETHOSU_PATH}/core_driver
CMSIS_PATH=${ETHOSU_PATH}/cmsis
PLATFORM_PATH=${ETHOSU_PATH}/core_platform/targets/corstone-300
PKG_COMPILE_OPTS = -g -Wall -O2 -Wno-incompatible-pointer-types -Wno-format -Werror-implicit-function-declaration -mcpu=${MCPU}${MCPU_FLAGS} -mthumb -mfloat-abi=${MFLOAT_ABI} -std=gnu99
CMAKE = /opt/arm/cmake/bin/cmake
CC = arm-none-eabi-gcc
AR = arm-none-eabi-ar
RANLIB = arm-none-eabi-ranlib
CC_OPTS = CC=$(CC) AR=$(AR) RANLIB=$(RANLIB)
ifeq ($(shell [ -d ${CMSIS_PATH}/CMSIS-NN ]; echo $$?), 0)
	CMSIS_NN_PATH = ${CMSIS_PATH}/CMSIS-NN
else
	CMSIS_NN_PATH = ${CMSIS_PATH}/CMSIS/NN
endif
PKG_CFLAGS = ${PKG_COMPILE_OPTS} \
	${CFLAGS} \
	-I$(build_dir)/../include \
	-I${TVM_ROOT}/src/runtime/contrib/ethosu/bare_metal \
	-I$(CODEGEN_ROOT)/host/include \
	-I${PLATFORM_PATH} \
	-I${DRIVER_PATH}/include \
	-I${CMSIS_PATH}/Device/ARM/${ARM_CPU}/Include/ \
	-I${CMSIS_PATH}/CMSIS/Core/Include \
	-I${CMSIS_NN_PATH}/Include \
	-I${CMSIS_PATH}/CMSIS/DSP/Include \
	-isystem$(STANDALONE_CRT_DIR)/include
DRIVER_CMAKE_FLAGS = -DCMAKE_TOOLCHAIN_FILE=$(ETHOSU_TEST_ROOT)/arm-none-eabi-gcc.cmake \
	-DETHOSU_LOG_SEVERITY=debug \
	-DCMAKE_SYSTEM_PROCESSOR=cortex-m55

PKG_LDFLAGS = -lm -specs=nosys.specs -static -T ${AOT_TEST_ROOT}/corstone300.ld

$(ifeq VERBOSE,1)
QUIET ?=
$(else)
QUIET ?= @
$(endif)

CRT_SRCS = $(shell find $(CRT_ROOT))
C_CODEGEN_SRCS = $(shell find $(abspath $(CODEGEN_ROOT)/host/src/*.c))
CC_CODEGEN_SRCS = $(shell find $(abspath $(CODEGEN_ROOT)/host/src/*.cc))
C_CODEGEN_OBJS = $(subst .c,.o,$(C_CODEGEN_SRCS))
CC_CODEGEN_OBJS = $(subst .cc,.o,$(CC_CODEGEN_SRCS))
CMSIS_STARTUP_SRCS = $(shell find ${CMSIS_PATH}/Device/ARM/${ARM_CPU}/Source/*.c)
CMSIS_NN_SRCS = $(shell find ${CMSIS_NN_PATH}/Source/*/*.c)
UART_SRCS = $(shell find ${PLATFORM_PATH}/*.c)

ifdef ETHOSU_TEST_ROOT
ETHOSU_DRIVER_LIBS = $(wildcard ${DRIVER_PATH}/build/*.a)
ETHOSU_RUNTIME=$(build_dir)/tvm_ethosu_runtime.o
ETHOSU_INCLUDE=-I$(ETHOSU_TEST_ROOT)
endif

aot_test_runner: $(build_dir)/aot_test_runner

$(build_dir)/stack_allocator.o: $(TVM_ROOT)/src/runtime/crt/memory/stack_allocator.c
	$(QUIET)mkdir -p $(@D)
	$(QUIET)$(CC) -c $(PKG_CFLAGS) -o $@  $^

$(build_dir)/crt_backend_api.o: $(TVM_ROOT)/src/runtime/crt/common/crt_backend_api.c
	$(QUIET)mkdir -p $(@D)
	$(QUIET)$(CC) -c $(PKG_CFLAGS) -o $@  $^

$(build_dir)/tvm_ethosu_runtime.o: $(TVM_ROOT)/src/runtime/contrib/ethosu/bare_metal/tvm_ethosu_runtime.c
	$(QUIET)mkdir -p $(@D)
	$(QUIET)$(CC) -c $(PKG_CFLAGS) -o $@  $^

$(build_dir)/libcodegen.a: $(C_CODEGEN_SRCS) $(CC_CODEGEN_SRCS)
	$(QUIET)cd $(abspath $(CODEGEN_ROOT)/host/src) && $(CC) -c $(PKG_CFLAGS) $(C_CODEGEN_SRCS) $(CC_CODEGEN_SRCS)
	$(QUIET)$(AR) -cr $(abspath $(build_dir)/libcodegen.a) $(C_CODEGEN_OBJS) $(CC_CODEGEN_OBJS)
	$(QUIET)$(RANLIB) $(abspath $(build_dir)/libcodegen.a)

${build_dir}/libcmsis_startup.a: $(CMSIS_STARTUP_SRCS)
	$(QUIET)mkdir -p $(abspath $(build_dir)/libcmsis_startup)
	$(QUIET)cd $(abspath $(build_dir)/libcmsis_startup) && $(CC) -c $(PKG_CFLAGS) -D${ARM_CPU} $^
	$(QUIET)$(AR) -cr $(abspath $(build_dir)/libcmsis_startup.a) $(abspath $(build_dir))/libcmsis_startup/*.o
	$(QUIET)$(RANLIB) $(abspath $(build_dir)/libcmsis_startup.a)

${build_dir}/libcmsis_nn.a: $(CMSIS_NN_SRCS)
	$(QUIET)mkdir -p $(abspath $(build_dir)/libcmsis_nn)
	$(QUIET)cd $(abspath $(build_dir)/libcmsis_nn) && $(CC) -c $(PKG_CFLAGS) -D${ARM_CPU} $^
	$(QUIET)$(AR) -cr $(abspath $(build_dir)/libcmsis_nn.a) $(abspath $(build_dir))/libcmsis_nn/*.o
	$(QUIET)$(RANLIB) $(abspath $(build_dir)/libcmsis_nn.a)

${build_dir}/libuart.a: $(UART_SRCS)
	$(QUIET)mkdir -p $(abspath $(build_dir)/libuart)
	$(QUIET)cd $(abspath $(build_dir)/libuart) && $(CC) -c $(PKG_CFLAGS) $^
	$(QUIET)$(AR) -cr $(abspath $(build_dir)/libuart.a) $(abspath $(build_dir))/libuart/*.o
	$(QUIET)$(RANLIB) $(abspath $(build_dir)/libuart.a)

$(build_dir)/aot_test_runner: $(build_dir)/test.c $(build_dir)/crt_backend_api.o $(build_dir)/stack_allocator.o $(build_dir)/libcodegen.a ${build_dir}/libcmsis_startup.a ${build_dir}/libcmsis_nn.a ${build_dir}/libuart.a $(ETHOSU_DRIVER_LIBS) $(ETHOSU_RUNTIME)
	$(QUIET)mkdir -p $(@D)
	$(QUIET)$(CC) $(PKG_CFLAGS) $(ETHOSU_INCLUDE) -o $@ -Wl,--whole-archive $^ -Wl,--no-whole-archive $(PKG_LDFLAGS)

clean:
	$(QUIET)rm -rf $(build_dir)/crt

cleanall:
	$(QUIET)rm -rf $(build_dir)

run: $(build_dir)/aot_test_runner
	$(FVP_DIR)/$(MODEL) -C cpu0.CFGDTCMSZ=15 \
	-C cpu0.CFGITCMSZ=15 -C mps3_board.uart0.out_file=\"-\" -C mps3_board.uart0.shutdown_tag=\"EXITTHESIM\" \
	-C mps3_board.visualisation.disable-visualisation=1 -C mps3_board.telnetterminal0.start_telnet=0 \
	-C mps3_board.telnetterminal1.start_telnet=0 -C mps3_board.telnetterminal2.start_telnet=0 -C mps3_board.telnetterminal5.start_telnet=0 \
	-C ethosu.extra_args="--fast" \
	-C ethosu.num_macs=$(NPU_MACS) $(build_dir)/aot_test_runner

.SUFFIXES:

.DEFAULT: aot_test_runner

.PHONY: run
