`timescale 1ns/1ps
//=============================================================================
// tb_uart_trx : uart_trx_top 回环自检
//  1) 向 uart_rx_i 发送 'A','B','C'(8-O-1 帧), 在 uart_tx_1 上解码回显, 应相等
//  2) 按下 KEY0, 解码按键字符串, 应为 "DE1-SOC UART OK!\r\n"
//=============================================================================
module tb_uart_trx;
    localparam integer CLK_FREQ = 50_000_000;
    localparam integer BAUD     = 9600;
    localparam integer BITNS    = 104166;              // 1e9/9600

    reg clk = 0, rstn;
    reg rx_line = 1'b1;
    reg key0_n = 1'b1, key1_n = 1'b1;
    wire tx1, tx2, tx3, tx4, tx20, tx21;
    wire [9:0] ledr;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;

    always #10 clk = ~clk;                             // 50MHz

    uart_trx_top #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .DEBOUNCE_MS(2)) dut (
        .clk_50m(clk), .uart_rx_i(rx_line),
        .key0_n(key0_n), .key1_n(key1_n),
        .uart_tx_1(tx1), .uart_tx_2(tx2), .uart_tx_3(tx3),
        .uart_tx_4(tx4), .uart_tx_20(tx20), .uart_tx_21(tx21),
        .ledr(ledr), .hex0(hex0), .hex1(hex1), .hex2(hex2),
        .hex3(hex3), .hex4(hex4), .hex5(hex5));

    // ---- 发送任务: 8-O-1 帧 ----
    task send_byte(input [7:0] d);
        integer i;
        reg p;
        begin
            p = ~(^d);
            rx_line = 1'b0;      #BITNS;
            for (i = 0; i < 8; i = i + 1) begin rx_line = d[i]; #BITNS; end
            rx_line = p;         #BITNS;
            rx_line = 1'b1;      #BITNS;
        end
    endtask

    // ---- 接收/解码任务: 从 tx 线解码 1 字节 ----
    task recv_byte(output [7:0] d);
        integer i;
        reg p;
        begin
            @(negedge tx1);                            // 起始位下降沿
            #(BITNS/2);                                // 到起始位中心
            if (tx1 !== 1'b0) $display("[%0t] WARN: start bit not 0", $time);
            #(BITNS/2);                                // 到 D0 中心
            for (i = 0; i < 8; i = i + 1) begin
                d[i] = tx1;
                #BITNS;
            end
            p = tx1; #BITNS;                           // 校验位
            if (tx1 !== 1'b1) $display("[%0t] WARN: stop bit not 1", $time);
            #BITNS/2;                                  // 停止位中心, 留半位余量
        end
    endtask

    integer errors = 0;
    reg [7:0] echo, g;
    reg [7:0] greet [0:17];
    integer k;

    initial begin
        // 上电复位
        rstn = 1'b0; #1000; rstn = 1'b1;
        #30_000_000;                                    // 等 10ms POR + 消抖稳定

        // ---- 测试1: 回显 3 个字节 ----
        fork
            begin send_byte(8'h41); send_byte(8'h42); send_byte(8'h43); end
            begin
                recv_byte(echo);
                if (echo !== 8'h41) begin $display("FAIL: echo1=%h expect 41", echo); errors=errors+1; end
                recv_byte(echo);
                if (echo !== 8'h42) begin $display("FAIL: echo2=%h expect 42", echo); errors=errors+1; end
                recv_byte(echo);
                if (echo !== 8'h43) begin $display("FAIL: echo3=%h expect 43", echo); errors=errors+1; end
            end
        join
        $display("TEST1 echo A/B/C: %s", errors==0 ? "PASS" : "FAIL");

        // ---- 测试2: 按键字符串 ----
        fork
            begin key0_n = 1'b0; #2_000_000; key0_n = 1'b1; end
            begin
                for (k = 0; k < 18; k = k + 1) begin
                    recv_byte(g);
                    greet[k] = g;
                end
            end
        join
        // 校验字符串
        if (greet[0]!==8'h44 || greet[1]!==8'h45 || greet[2]!==8'h31 ||
            greet[3]!==8'h2D || greet[4]!==8'h53 || greet[5]!==8'h4F ||
            greet[6]!==8'h43 || greet[7]!==8'h20 || greet[8]!==8'h55 ||
            greet[9]!==8'h41 || greet[10]!==8'h52 || greet[11]!==8'h54 ||
            greet[12]!==8'h20 || greet[13]!==8'h4F || greet[14]!==8'h4B ||
            greet[15]!==8'h21 || greet[16]!==8'h0D || greet[17]!==8'h0A) begin
            $display("FAIL: greeting string mismatch: %h %h %h %h ...", greet[0], greet[1], greet[2], greet[3]);
            errors = errors + 1;
        end
        else $display("TEST2 greeting: PASS (DE1-SOC UART OK!\\r\\n)");

        // ---- 测试3: 回显与字符串交错(FIFO 压力) ----
        fork
            begin send_byte(8'h5A); send_byte(8'h5B); end
            begin
                recv_byte(echo);
                if (echo !== 8'h5A) begin $display("FAIL: echo4=%h", echo); errors=errors+1; end
                recv_byte(echo);
                if (echo !== 8'h5B) begin $display("FAIL: echo5=%h", echo); errors=errors+1; end
            end
        join
        $display("TEST3 echo after greeting: %s", errors==0 ? "PASS" : "FAIL");

        // ---- 计数检查: 应收到 3+18+2 = 23 个字符 ----
        // HEX5..HEX2 = 0,0,2,3
        if (hex5 !== ~7'b0111111 || hex4 !== ~7'b0111111 ||
            hex3 !== ~7'b1011011 || hex2 !== ~7'b1001111) begin
            $display("FAIL: count display hex5=%b hex4=%b hex3=%b hex2=%b", hex5, hex4, hex3, hex2);
            errors = errors + 1;
        end
        else $display("TEST4 count=23 display: PASS");

        if (errors == 0) $display("==== ALL TRX TESTS PASSED ====");
        else             $display("==== %0d TEST(S) FAILED ====", errors);
        $finish;
    end
endmodule
