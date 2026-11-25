// FPGA die temperature from the SYSMONE4 (default mode: on-chip sensors sampled
// continuously), read over DRP every ~1 ms. JTAG access to the SYSMON keeps working.
// xst_temp is quasi-static (false path to the register-read clock domain).
// Temperature (deg C) = code * 509.3140064 / 65536 - 280.2308787 (UG580, internal reference).
`default_nettype none
module temp_mon (
  input  wire        dclk,           // free-running, here CFGMCLK (~50 MHz)
  output reg  [15:0] xst_temp = 16'd0
);
  reg  [15:0] cnt = 16'd0;
  reg         den = 1'b0, busy = 1'b0;
  wire [15:0] dout;
  wire        drdy;
  always @(posedge dclk) begin
    den <= 1'b0;
    cnt <= cnt + 1'b1;
    if (cnt == 16'd0 && !busy) begin den <= 1'b1; busy <= 1'b1; end
    if (drdy) begin xst_temp <= dout; busy <= 1'b0; end
  end
  SYSMONE4 #(
    .INIT_40(16'h0000),     // average off, no external channels
    .INIT_41(16'h0000),     // default mode: temperature + supplies, calibration on
    .INIT_42(16'h1400),     // ADCCLK = DCLK / 20 (2.5 MHz at 50 MHz)
    .SIM_MONITOR_FILE("design.txt")
  ) sysmon (
    .DCLK(dclk), .DEN(den), .DWE(1'b0), .DADDR(8'h00), .DI(16'd0), .DO(dout), .DRDY(drdy),
    .RESET(1'b0), .CONVST(1'b0), .CONVSTCLK(1'b0),
    .VP(1'b0), .VN(1'b0), .VAUXP(16'd0), .VAUXN(16'd0),
    .ALM(), .OT(), .BUSY(), .CHANNEL(), .EOC(), .EOS(), .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(),
    .MUXADDR(), .ADC_DATA(), .I2C_SCLK(1'b1), .I2C_SDA(1'b1), .I2C_SCLK_TS(), .I2C_SDA_TS(),
    .SMBALERT_TS()
  );
endmodule
`default_nettype wire
