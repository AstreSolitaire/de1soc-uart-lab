`timescale 1ns/1ps
//=============================================================================
// tb_switch : 波特率/校验切换功能验证
//  1) 9600 ODD  : 发 'A' 正常
//  2) 9600 EVEN : 发 'B'(偶校验帧) 正常; 发 'C'(奇校验帧) 应奇偶校验错
//  3) 9600 NONE : 发 'D'(无校验帧, 9 位+停止位) 正常
//  4) 38400 ODD : 发 'E' 正常
//  5) 115200 ODD: 发 'F' 正常
//  最终计数应为 5 (B 的奇校验错那次不计)
//=============================================================================
module tb_switch;
    localparam integer BITNS_9600   = 104166;   // 1e9/9600
    localparam integer BITNS_38400  = 26041;    // 1e9/38400
    localparam integer BITNS_115200 = 8680;     // 1e9/115200

    reg clk = 0;
    reg rx_line = 1'b1;
    reg [1:0] sw_baud = 2'b00;
    reg [1:0] sw_par  = 2'b00;
    reg sw_tolerant = 1'b0;
    reg key0_n = 1'b1, key1_n = 1'b1;

    wire [9:0] ledr;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;

    always #10 clk = ~clk;

    uart_rx_monitor_top #(.CLK_FREQ(50_000_000), .DEBOUNCE_MS(2)) dut (
        .clk_50m(clk), .uart_rx(rx_line),
        .key_stop_n(key0_n), .key_rst_n(key1_n),
        .sw_baud(sw_baud), .sw_par(sw_par), .sw_tolerant(sw_tolerant),
        .ledr(ledr), .hex0(hex0), .hex1(hex1), .hex2(hex2),
        .hex3(hex3), .hex4(hex4), .hex5(hex5));

    // 发送任务: bit_ns=位时间, par=校验位(奇/偶自动算), no_par=无校验帧
    task send_byte(input [7:0] d, input integer bit_ns,
                   input use_par, input par_odd, input no_par);
        integer i;
        reg p;
        begin
            p = par_odd ? ~(^d) : (^d);        // 奇: 1 的个数为奇时 p=0; 偶: 相反
            rx_line = 1'b0;      #bit_ns;       // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = d[i];  #bit_ns;      // 数据位
            end
            if (!no_par) begin
                rx_line = use_par ? p : ~p;  #bit_ns;   // 校验位(正确/故意错)
            end
            rx_line = 1'b1;      #bit_ns;       // 停止位
            rx_line = 1'b1;      #bit_ns;       // 帧间空闲
        end
    endtask

    integer errors = 0;
    integer cnt = 0;

    // 统计 rx_valid 脉冲
    always @(posedge clk) begin
        if (dut.rx_valid) cnt = cnt + 1;
    end

    initial begin
        rstn_block;
        #5_000_000;   // 等 5ms(上电复位+消抖完成)

        // ---- 1) 9600 ODD: 发 'A' ----
        send_byte(8'h41, BITNS_9600, 1'b1, 1'b1, 1'b0);
        #1_000_000;
        if (cnt !== 1) begin $display("FAIL T1: cnt=%0d expect 1", cnt); errors=errors+1; end

        // ---- 2) 9600 EVEN: 发 'B'(偶) 正常; 发 'C'(奇帧=校验错) 不计 ----
        sw_par = 2'b01; #500_000;                       // 切到偶校验
        send_byte(8'h42, BITNS_9600, 1'b1, 1'b0, 1'b0); // 偶校验帧
        #1_000_000;
        if (cnt !== 2) begin $display("FAIL T2a: cnt=%0d expect 2", cnt); errors=errors+1; end
        send_byte(8'h43, BITNS_9600, 1'b1, 1'b1, 1'b0); // 奇校验帧(与 EVEN 设置不符)
        #1_000_000;
        if (cnt !== 2) begin $display("FAIL T2b: cnt=%0d expect 2", cnt); errors=errors+1; end
        if (ledr[3] !== 1'b1) begin $display("FAIL T2c: parity err LED off"); errors=errors+1; end

        // ---- 3) 9600 NONE: 发 'D'(无校验帧) ----
        sw_par = 2'b10; #500_000;                       // 切到无校验
        send_byte(8'h44, BITNS_9600, 1'b0, 1'b0, 1'b1); // 无校验帧
        #1_000_000;
        if (cnt !== 3) begin $display("FAIL T3: cnt=%0d expect 3", cnt); errors=errors+1; end

        // ---- 4) 38400 ODD: 发 'E' ----
        sw_baud = 2'b10; sw_par = 2'b00; #500_000;      // 切 38400 + 奇校验
        send_byte(8'h45, BITNS_38400, 1'b1, 1'b1, 1'b0);
        #1_000_000;
        if (cnt !== 4) begin $display("FAIL T4: cnt=%0d expect 4", cnt); errors=errors+1; end

        // ---- 5) 115200 ODD: 发 'F' ----
        sw_baud = 2'b11; #500_000;                      // 切 115200
        send_byte(8'h46, BITNS_115200, 1'b1, 1'b1, 1'b0);
        #2_000_000;
        if (cnt !== 5) begin $display("FAIL T5: cnt=%0d expect 5", cnt); errors=errors+1; end

        // ---- 计数显示: 5 -> HEX3=0, HEX2=5 ----
        if (hex3 !== ~7'b0111111 || hex2 !== ~7'b1101101) begin
            $display("FAIL DISP: hex3=%b hex2=%b (expect 0,5)", hex3, hex2);
            errors = errors + 1;
        end

        if (errors == 0) $display("==== ALL SWITCH TESTS PASSED ====");
        else             $display("==== %0d TEST(S) FAILED ====", errors);
        $finish;
    end

    task rstn_block;
        begin
            key1_n = 1'b0; #2000; key1_n = 1'b1;
        end
    endtask
endmodule
