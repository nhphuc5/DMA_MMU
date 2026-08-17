# Automated PicoRV32 firmware build.
#
# Default toolchain: Vitis 2025.1 RV32 GNU tools on Windows.
# Override from the command line when necessary, for example:
#   make TOOLCHAIN=D:/another/path/riscv32-xilinx-elf

SHELL := cmd.exe
.SHELLFLAGS := /C

TOOLCHAIN ?= D:/2025.1/gnu/riscv/nt/riscv64-unknown-elf/x86_64-w64-mingw32/usr/bin/riscv32-xilinx-elf
PREFIX    ?= riscv32-xilinx-elf
PYTHON    ?= python

CXX      := $(TOOLCHAIN)/$(PREFIX)-g++.exe
OBJCOPY  := $(TOOLCHAIN)/$(PREFIX)-objcopy.exe
READELF  := $(TOOLCHAIN)/$(PREFIX)-readelf.exe

PROGRAM     ?= soc_demo
SOURCE      ?= src/$(PROGRAM).cpp
HEADER      := include/soc_map.h
LINKER      := linker.ld
MAKEHEX     := tools/makehex.py
BUILD_DIR   := build
ELF         := $(BUILD_DIR)/$(PROGRAM).elf
BIN         := $(BUILD_DIR)/$(PROGRAM).bin
HEX         := $(BUILD_DIR)/$(PROGRAM).hex
HEX_TMP     := $(BUILD_DIR)/$(PROGRAM).hex.tmp
RAM_WORDS   ?= 16384
IMAGE_PACKER   := tools/pack_images_into_ram.py
IMAGE_MANIFEST := images/manifest.json
SYSTOLIC_IMAGE_PACKER := tools/pack_systolic_image_into_ram.py
SYSTOLIC_IMAGE_SOURCE ?= images/systolic_test_input.png

CXXFLAGS := -std=c++17 -march=rv32i -mabi=ilp32 -Os \
            -ffreestanding -fno-exceptions -fno-rtti \
            -fno-threadsafe-statics -fno-use-cxa-atexit \
            -fno-unwind-tables -fno-asynchronous-unwind-tables \
            -ffunction-sections -fdata-sections -fno-jump-tables \
            -msmall-data-limit=0 -nostdlib -nostartfiles $(FW_DEFINES)

LDFLAGS := -T "$(LINKER)" -Wl,--gc-sections -Wl,--build-id=none

.PHONY: all vc707 image-demo vc707-image-demo systolic-demo \
        systolic-image-dma vc707-systolic-image-dma \
        vc707-systolic-demo verify clean clean-vc707 clean-image-demo \
        clean-vc707-image-demo clean-systolic-demo \
        clean-vc707-systolic-demo clean-systolic-image-dma \
        clean-vc707-systolic-image-dma rebuild help check-tools

all: check-tools $(HEX) verify

# VC707 hardware image: 150 MHz system clock, approximately 115200 baud.
# It is kept in a separate directory so the fast RTL-simulation image remains
# unchanged and both targets can coexist.
vc707:
	@"$(MAKE)" BUILD_DIR=build/vc707 FW_DEFINES=-DSOC_UART_DIVIDER=1300u all

# Dedicated image streams.  These do not replace or modify soc_demo.hex.
image-demo:
	@"$(MAKE)" PROGRAM=soc_image_demo BUILD_DIR=build/image_demo FW_DEFINES=-DSOC_UART_DIVIDER=4u all
	@$(PYTHON) "$(IMAGE_PACKER)" --firmware "build/image_demo/soc_image_demo.bin" --manifest "$(IMAGE_MANIFEST)" --output "build/image_demo/soc_image_demo_with_images.hex" --asset-dir "build/image_demo/images"

vc707-image-demo:
	@"$(MAKE)" PROGRAM=soc_image_demo BUILD_DIR=build/vc707_image_demo FW_DEFINES=-DSOC_UART_DIVIDER=1300u all
	@$(PYTHON) "$(IMAGE_PACKER)" --firmware "build/vc707_image_demo/soc_image_demo.bin" --manifest "$(IMAGE_MANIFEST)" --output "build/vc707_image_demo/soc_image_demo_with_images.hex" --asset-dir "build/vc707_image_demo/images"

systolic-demo:
	@"$(MAKE)" PROGRAM=soc_systolic_demo BUILD_DIR=build/systolic_demo FW_DEFINES=-DSOC_UART_DIVIDER=4u all

vc707-systolic-demo:
	@"$(MAKE)" PROGRAM=soc_systolic_demo BUILD_DIR=build/vc707_systolic_demo FW_DEFINES=-DSOC_UART_DIVIDER=1300u all

# End-to-end 64x64 image pipeline.  It uses 256 KiB of BRAM because firmware,
# tiled input, INT32 scratch results and reconstructed output coexist.
systolic-image-dma:
	@"$(MAKE)" PROGRAM=soc_systolic_image_dma BUILD_DIR=build/systolic_image_dma FW_DEFINES=-DSOC_UART_DIVIDER=4u RAM_WORDS=65536 all
	@$(PYTHON) "$(SYSTOLIC_IMAGE_PACKER)" --firmware "build/systolic_image_dma/soc_systolic_image_dma.bin" --image "$(SYSTOLIC_IMAGE_SOURCE)" --output "build/systolic_image_dma/soc_systolic_image_dma_with_image.hex" --asset-dir "build/systolic_image_dma/assets" --ram-bytes 262144

vc707-systolic-image-dma:
	@"$(MAKE)" PROGRAM=soc_systolic_image_dma BUILD_DIR=build/vc707_systolic_image_dma FW_DEFINES=-DSOC_UART_DIVIDER=1300u RAM_WORDS=65536 all
	@$(PYTHON) "$(SYSTOLIC_IMAGE_PACKER)" --firmware "build/vc707_systolic_image_dma/soc_systolic_image_dma.bin" --image "$(SYSTOLIC_IMAGE_SOURCE)" --output "build/vc707_systolic_image_dma/soc_systolic_image_dma_with_image.hex" --asset-dir "build/vc707_systolic_image_dma/assets" --ram-bytes 262144

check-tools:
	@"$(CXX)" --version >nul
	@"$(OBJCOPY)" --version >nul
	@"$(READELF)" --version >nul
	@$(PYTHON) --version >nul

$(BUILD_DIR):
	@$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"

$(ELF): $(SOURCE) $(HEADER) $(LINKER) | $(BUILD_DIR)
	@echo [1/4] C++ to ELF32 RV32I
	@"$(CXX)" $(CXXFLAGS) -I"include" $(LDFLAGS) -o "$@" "$(SOURCE)"

$(BIN): $(ELF)
	@echo [2/4] ELF to raw binary
	@"$(OBJCOPY)" -O binary "$<" "$@"

$(HEX): $(BIN) $(MAKEHEX)
	@echo [3/4] Binary to 64-KiB AXI-RAM HEX image
	@$(PYTHON) "$(MAKEHEX)" "$(BIN)" $(RAM_WORDS) > "$(HEX_TMP)"
	@$(PYTHON) -c "import os; os.replace(r'$(HEX_TMP)', r'$(HEX)')"

verify: $(ELF)
	@echo [4/4] Verify ELF class, machine, and ISA
	@"$(READELF)" -h "$(ELF)" | findstr /C:"Class:" /C:"Machine:"
	@"$(READELF)" -A "$(ELF)" | findstr /C:"Tag_RISCV_arch:"
	@echo SUCCESS: $(SOURCE) -^> $(ELF) -^> $(BIN) -^> $(HEX)

clean:
	@echo Cleaning generated firmware files
	@$(PYTHON) -c "import os; [os.remove(p) for p in [r'$(ELF)', r'$(BIN)', r'$(HEX)', r'$(HEX_TMP)'] if os.path.exists(p)]"

clean-vc707:
	@"$(MAKE)" BUILD_DIR=build/vc707 clean

clean-image-demo:
	@"$(MAKE)" PROGRAM=soc_image_demo BUILD_DIR=build/image_demo clean

clean-vc707-image-demo:
	@"$(MAKE)" PROGRAM=soc_image_demo BUILD_DIR=build/vc707_image_demo clean

clean-systolic-demo:
	@"$(MAKE)" PROGRAM=soc_systolic_demo BUILD_DIR=build/systolic_demo clean

clean-vc707-systolic-demo:
	@"$(MAKE)" PROGRAM=soc_systolic_demo BUILD_DIR=build/vc707_systolic_demo clean

clean-systolic-image-dma:
	@"$(MAKE)" PROGRAM=soc_systolic_image_dma BUILD_DIR=build/systolic_image_dma clean

clean-vc707-systolic-image-dma:
	@"$(MAKE)" PROGRAM=soc_systolic_image_dma BUILD_DIR=build/vc707_systolic_image_dma clean

rebuild:
	@"$(MAKE)" clean
	@"$(MAKE)" all

help:
	@echo make all       - Build ELF, BIN and HEX, then verify RV32I
	@echo make verify    - Inspect the existing ELF target
	@echo make clean     - Delete generated ELF, BIN and HEX
	@echo make rebuild   - Clean and build everything again
	@echo make vc707     - Build the 150-MHz VC707/115200-baud firmware image
	@echo make image-demo       - Build simulation firmware plus three RAM images
	@echo make vc707-image-demo - Build VC707 firmware plus three RAM images
	@echo make systolic-demo       - Build fast-simulation 4x4 matrix demo
	@echo make vc707-systolic-demo - Build 150-MHz VC707 4x4 matrix demo
	@echo make systolic-image-dma       - Build 256-KiB image/DMA/systolic simulation image
	@echo make vc707-systolic-image-dma - Build 256-KiB VC707 image/DMA/systolic image
