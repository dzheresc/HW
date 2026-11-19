# k7_10g: 10GBASE-R link test on both SFP+ cages

Xilinx `ten_gig_eth_pcs_pma` v6.0 (Vivado 2017.4). `pcs_shared` drives SFP A and owns the
QPLL; `pcs_noshared` drives SFP B on the same QPLL. Both send XGMII idle; nothing above the PCS.

Build and run (PowerShell):

    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source gen_ip.tcl    # only after IP changes
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source build.tcl
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source program.tcl   # JTAG, volatile, prints status
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source program.tcl -tclargs 192.168.0.215:3121 noprog  # status only

LEDs: 0 heartbeat, 1 QPLL lock, 2 GT reset done, 3 SFP A block lock, 4 SFP B block lock,
5 heartbeat from the 156.25 MHz core clock.

JTAG status (status_vio): core clock frequency, block lock per cage, and per second counts of
received idle words, local faults and remote faults. All idles with no remote fault means the
link is up in both directions. VIO `probe_out0` is a soft reset.

Licensing: the build prints an "Evaluation License" critical warning naming
`ten_gig_eth_pcs_pma_basekr` (design_linking). That key is only for the optional BASE-KR feature,
which this design does not use (GTX cannot do KR). AMD confirms the warning is safe to ignore in that
case; plain 10GBASE-R is covered by the no-charge `ten_gig_eth_pcs_pma` key in the license file.
See https://adaptivesupport.amd.com/s/question/0D52E00006hplxXSAQ/ and AR 68203.
