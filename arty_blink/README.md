# blink - Arty A7-35T

Minimal Verilog LED blinker for the Digilent Arty A7-35T (`xc7a35ticsg324-1L`),
Vivado 2024.2.

LD4..LD7 count up once per 0.5 s: LD4 blinks at 1 Hz, LD5 at 0.5 Hz, LD6 at
0.25 Hz, LD7 at 0.125 Hz. The RESET button clears the counter.

## Layout

```
src/blink.v                 top module (parameters CLK_HZ, BLINK_HZ)
sim/tb_blink.v              self-checking testbench (prints TB PASS / TB FAIL)
constrs/arty_a7_35.xdc      pins, clock, configuration settings
scripts/create_project.tcl  builds vivado/blink.xpr from the files above
scripts/build.tcl           synth + impl + bitstream -> bin/blink.bit
scripts/sim.tcl             runs the testbench in xsim
scripts/program.tcl         loads bin/blink.bit over USB-JTAG (volatile)
scripts/flash.tcl           writes bin/blink.mcs to the QSPI flash, boots from it
build.cmd                   Windows wrapper for the scripts
```

`vivado/`, `bin/` and `logs/` are generated and not meant to be committed.

## Use

From this directory, with Vivado on the PATH (or via `build.cmd`):

```
vivado -mode batch -source scripts/create_project.tcl   # create vivado/blink.xpr
vivado -mode batch -source scripts/sim.tcl              # testbench, expect "TB PASS"
vivado -mode batch -source scripts/build.tcl            # bitstream -> bin/blink.bit
vivado -mode batch -source scripts/program.tcl          # load FPGA (lost at power-off)
vivado -mode batch -source scripts/flash.tcl            # write flash (survives power-off)
```

or `build.cmd create|sim|build|program|flash`.
For the GUI, run the create step once and open `vivado/blink.xpr`.

The flash on this board is a Micron MT25QL128 (Vivado part
`mt25ql128-spi-x1_x2_x4`). `flash.tcl` also tries the S25FL128S and N25Q128
fitted to other Arty A7 revisions, so it works unchanged on those.

## Pins (Arty A7-35T)

| Port   | Pin | Function                 |
|--------|-----|--------------------------|
| clk    | E3  | 100 MHz oscillator       |
| rst_n  | C2  | RESET button, active low |
| led[0] | H5  | LD4                      |
| led[1] | J5  | LD5                      |
| led[2] | T9  | LD6                      |
| led[3] | T10 | LD7                      |

## Other A7-35T boards

Change `part` in `scripts/create_project.tcl`, swap the XDC, and set `CLK_HZ`
to the board clock. For example Cmod A7-35T: part `xc7a35tcpg236-1`,
12 MHz clock on L17, LEDs on A17 and C16, buttons on A18 and B18.
