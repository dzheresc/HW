# openXC7 flow for the xc7k325t blink design. Runs inside the openxc7 Docker
# image (see build.ps1 / build.sh), with this folder mounted at /work.
#
#   make            -> build/blink.bit (generates the chipdb on first run)
#   make chipdb     -> only build the chipdb
#   make clean      -> remove build/ (keeps the chipdb cache)

TOP      := blink
FAMILY   := kintex7
# Speed grade does not change the bitstream; prjxray-db only ships the package
# pin map for the -1 part of xc7k325tffg676, so that part name is used.
# The chipdb is built per die (xc7k325t) and cached in chipdb/.
DIE      := xc7k325t
PART     := xc7k325tffg676-1

NEXTPNR_ROOT := $(shell dirname $$(dirname $$(command -v nextpnr-himbaechel)))
XL_SHARE     := $(NEXTPNR_ROOT)/share/nextpnr/himbaechel/uarch/xilinx
DB_ROOT      := $(NEXTPNR_ROOT)/share/nextpnr/external/prjxray-db/$(FAMILY)

BUILD    := build
CHIPDIR  := chipdb
CHIPDB   := $(CHIPDIR)/chipdb-$(DIE).bin

.PHONY: all chipdb clean
all: $(BUILD)/$(TOP).bit
chipdb: $(CHIPDB)

$(CHIPDIR)/chipdb-$(DIE).bba:
	mkdir -p $(CHIPDIR)
	python3 $(XL_SHARE)/gen/xilinx_gen.py --xray $(DB_ROOT) --metadata $(XL_SHARE)/meta/$(FAMILY) \
		--device $(DIE) --bba $@.tmp
	mv $@.tmp $@

$(CHIPDB): $(CHIPDIR)/chipdb-$(DIE).bba
	bbasm -l $< $@

$(BUILD)/$(TOP).json: $(TOP).v
	mkdir -p $(BUILD)
	yosys -q -l $(BUILD)/yosys.log -p "synth_xilinx -flatten -abc9 -arch xc7 -top $(TOP); write_json $@" $<

$(BUILD)/$(TOP).fasm: $(BUILD)/$(TOP).json $(TOP).xdc $(CHIPDB)
	nextpnr-himbaechel --device $(PART) --chipdb $(CHIPDB) --json $< \
		-o xdc=$(TOP).xdc -o fasm=$@ --freq 100 -l $(BUILD)/nextpnr.log

$(BUILD)/$(TOP).frames: $(BUILD)/$(TOP).fasm
	fasm2frames --part $(PART) --db-root $(DB_ROOT) $< > $@

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).frames
	xc7frames2bit --part_file $(DB_ROOT)/$(PART)/part.yaml --part_name $(PART) \
		--frm_file $< --output_file $@

clean:
	rm -rf $(BUILD)
