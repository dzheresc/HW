`timescale 1ns / 1ps
`default_nettype none
//------------------------------------------------------------------------------
// tb_blink.v - self-checking testbench for blink.
// CLK_HZ is shrunk to 100 so one "1 Hz" blink is 100 clocks instead of 1e8.
// Prints "TB PASS" or "TB FAIL: <n> errors" and finishes.
//------------------------------------------------------------------------------
module tb_blink;
    localparam integer CLK_HZ   = 100;
    localparam integer BLINK_HZ = 1;
    localparam integer HALF     = CLK_HZ / (2 * BLINK_HZ);   // 50 clocks per tick
    localparam real    T_CLK    = 10.0;                      // ns

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    wire [3:0] led;

    blink #(.CLK_HZ(CLK_HZ), .BLINK_HZ(BLINK_HZ)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .led   (led)
    );

    always #(T_CLK / 2) clk = ~clk;

    integer errors = 0;
    integer i;

    task check(input [3:0] exp, input [8*32-1:0] what);
        begin
            if (led !== exp) begin
                $display("FAIL @%0t: %0s: led=%b exp=%b", $time, what, led, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("tb_blink: HALF=%0d clocks", HALF);

        // 1) outputs low while in reset
        repeat (5) @(posedge clk); #1;
        check(4'd0, "in reset");

        // 2) release reset, wait for first tick, then expect +1 every HALF clocks
        rst_n = 1'b1;
        wait (led == 4'd1);
        for (i = 2; i <= 17; i = i + 1) begin        // ...15, wrap to 0, 1
            repeat (HALF) @(posedge clk); #1;
            check(i[3:0], "count");
        end

        // 3) asynchronous reset mid-run clears LEDs within one clock
        @(negedge clk); rst_n = 1'b0;
        @(posedge clk); #1;
        check(4'd0, "async reset");
        rst_n = 1'b1;

        // 4) counting resumes
        wait (led == 4'd1);
        repeat (HALF) @(posedge clk); #1;
        check(4'd2, "after reset");

        if (errors == 0) $display("TB PASS");
        else             $display("TB FAIL: %0d errors", errors);
        $finish;
    end

    // watchdog
    initial begin
        #(T_CLK * HALF * 40);
        $display("TB FAIL: timeout");
        $finish;
    end
endmodule
`default_nettype wire
