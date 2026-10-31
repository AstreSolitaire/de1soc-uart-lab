//=============================================================================
// 文件名  : tb_uart_rx_monitor.v
// 功能    : uart_rx_monitor_top 的自检测试平台(ModelSim / Icarus Verilog 均可)
// 用法    : ModelSim : 新建工程加入 rtl/*.v 与本文件, 仿真顶层选 tb_uart_rx_monitor
//           Icarus  : iverilog -o sim.out rtl/*.v tb/tb_uart_rx_monitor.v && vvp sim.out
// 说明    : 为缩短仿真时间, 测试平台把闪烁频率与按键消抖时间参数改小
//           (BLINK_HZ=1000, DEBOUNCE_MS=2), 其余参数与上板一致(50MHz/9600)。
//=============================================================================
`timescale 1ns/1ps

module tb_uart_rx_monitor;

    localparam integer CLK_FREQ    = 50_000_000;
    localparam integer BAUD        = 9600;
    localparam integer BIT_NS      = 104167;     // 1e9/9600 ≈ 104.17us
    localparam integer BLINK_HZ    = 1000;       // 仅仿真加速用
    localparam integer DEBOUNCE_MS = 2;          // 仅仿真加速用

    // ---------------- 测试信号 ----------------
    reg clk        = 1'b0;
    reg uart_rx    = 1'b1;
    reg key_stop_n = 1'b1;
    reg key_rst_n  = 1'b1;
    reg sw_mode    = 1'b0;

    wire [9:0] ledr;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;

    integer errors = 0;

    always #10 clk = ~clk;                       // 50MHz

    // ---------------- 被测设计 ----------------
    uart_rx_monitor_top #(
        .CLK_FREQ    (CLK_FREQ),
        .BAUD        (BAUD),
        .BLINK_HZ    (BLINK_HZ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) dut (
        .clk_50m    (clk),
        .uart_rx    (uart_rx),
        .key_stop_n (key_stop_n),
        .key_rst_n  (key_rst_n),
        .sw_mode    (sw_mode),
        .ledr       (ledr),
        .hex0       (hex0),
        .hex1       (hex1),
        .hex2       (hex2),
        .hex3       (hex3),
        .hex4       (hex4),
        .hex5       (hex5)
    );

    // ---------------- 七段译码(与 RTL 相同, 用于期望值) ----------------
    function [6:0] seg_of;
        input [3:0] d;
        begin
            case (d)
                4'h0: seg_of = 7'b0111111;
                4'h1: seg_of = 7'b0000110;
                4'h2: seg_of = 7'b1011011;
                4'h3: seg_of = 7'b1001111;
                4'h4: seg_of = 7'b1100110;
                4'h5: seg_of = 7'b1101101;
                4'h6: seg_of = 7'b1111101;
                4'h7: seg_of = 7'b0000111;
                4'h8: seg_of = 7'b1111111;
                4'h9: seg_of = 7'b1101111;
                4'hA: seg_of = 7'b1110111;
                4'hB: seg_of = 7'b1111100;
                4'hC: seg_of = 7'b0111001;
                4'hD: seg_of = 7'b1011110;
                4'hE: seg_of = 7'b1111001;
                default: seg_of = 7'b1110001;
            endcase
        end
    endfunction

    // ---------------- 激励任务 ----------------
    // 发送一个字节: 8 数据位 + 奇校验 + 1 停止位
    task uart_send;
        input [7:0] d;
        input       bad_par;      // 1 = 故意发送错误校验位
        input       stop_bit;     // 0 = 故意发送错误停止位
        integer i;
        reg     p;
        begin
            p = bad_par ? (^d) : ~(^d);          // 奇校验: 数据中 1 的个数为奇时校验位为 0
            uart_rx = 1'b0;      #BIT_NS;        // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = d[i];  #BIT_NS;        // 数据位, 低位在前
            end
            uart_rx = p;         #BIT_NS;        // 校验位
            uart_rx = stop_bit;  #BIT_NS;        // 停止位
            uart_rx = 1'b1;      #2000;          // 空闲
        end
    endtask

    task press_stop;
        begin
            key_stop_n = 1'b0; #10_000_000;
            key_stop_n = 1'b1; #10_000_000;
        end
    endtask

    task press_reset;
        begin
            key_rst_n = 1'b0; #10_000_000;
            key_rst_n = 1'b1; #10_000_000;
        end
    endtask

    // ---------------- 检查任务 ----------------
    task check_count;
        input [15:0] n;
        begin
            if (hex5 !== ~seg_of(n/1000) || hex4 !== ~seg_of((n/100)%10) ||
                hex3 !== ~seg_of((n/10)%10) || hex2 !== ~seg_of(n%10)) begin
                $display("[%0t] FAIL: count expect %0d, got %b %b %b %b",
                         $time, n, hex5, hex4, hex3, hex2);
                errors = errors + 1;
            end
        end
    endtask

    task check_char;
        input [7:0] c;
        begin
            if (hex1 !== ~seg_of(c[7:4]) || hex0 !== ~seg_of(c[3:0])) begin
                $display("[%0t] FAIL: char expect %h, got %b %b", $time, c, hex1, hex0);
                errors = errors + 1;
            end
        end
    endtask

    task check_blink;
        input exp;                 // 期望的闪烁使能(LEDR[2])
        begin
            if (ledr[2] !== exp) begin
                $display("[%0t] FAIL: blink_en expect %b, got %b (ledr=%b)",
                         $time, exp, ledr[2], ledr);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- 测试流程 ----------------
    reg blink_a;
    integer i;

    initial begin
        $display("==== tb_uart_rx_monitor start ====");

        // 0. 上电复位(约 10ms)后: 计数 0000, 字符位消隐, 无闪烁
        #20_000_000;
        check_count(0);
        if (hex0 !== 7'b0000000 || hex1 !== 7'b0000000) begin
            $display("[%0t] FAIL: char should be blank after reset", $time);
            errors = errors + 1;
        end
        check_blink(1'b0);
        $display("[%0t] power-on reset ok", $time);

        // 1. 接收普通字符 'H'
        uart_send(8'h48, 1'b0, 1'b1);
        check_count(1);
        check_char(8'h48);

        // 2. 连续发送 "ello" -> 计数 5
        uart_send(8'h65, 1'b0, 1'b1);   // 'e'
        uart_send(8'h6C, 1'b0, 1'b1);   // 'l'
        uart_send(8'h6C, 1'b0, 1'b1);   // 'l'
        uart_send(8'h6F, 1'b0, 1'b1);   // 'o'
        check_count(5);
        check_char(8'h6F);
        if (ledr[2] !== 1'b0) begin
            $display("[%0t] FAIL: blink should stay off", $time);
            errors = errors + 1;
        end
        $display("[%0t] normal characters ok, count = 5", $time);

        // 3. 发送 "Twin" -> 进入闪烁
        uart_send(8'h54, 1'b0, 1'b1);   // 'T'
        uart_send(8'h77, 1'b0, 1'b1);   // 'w'
        uart_send(8'h69, 1'b0, 1'b1);   // 'i'
        uart_send(8'h6E, 1'b0, 1'b1);   // 'n'
        #5_000;
        check_count(9);
        check_blink(1'b1);

        // 4. 观察 LEDR[0] 是否翻转(半周期 0.5ms)
        blink_a = ledr[0];
        #500_000;
        if (ledr[0] === blink_a) begin
            $display("[%0t] FAIL: ledr[0] not toggling", $time);
            errors = errors + 1;
        end
        else $display("[%0t] Twin detected, ledr[0] blinking", $time);

        // 5. 按下停止键 -> 闪烁关闭, 计数保持
        press_stop();
        check_blink(1'b0);
        check_count(9);
        if (ledr[0] !== 1'b0) begin
            $display("[%0t] FAIL: ledr[0] should be off", $time);
            errors = errors + 1;
        end
        $display("[%0t] stop key ok", $time);

        // 6. 再次发送 "Twin" -> 闪烁重新开启
        uart_send(8'h54, 1'b0, 1'b1);
        uart_send(8'h77, 1'b0, 1'b1);
        uart_send(8'h69, 1'b0, 1'b1);
        uart_send(8'h6E, 1'b0, 1'b1);
        #5_000;
        check_count(13);
        check_blink(1'b1);
        $display("[%0t] Twin re-detected, blink restarted", $time);

        // 7. 校验错误的字节: 不应计数, LEDR[3] 点亮
        uart_send(8'h41, 1'b1, 1'b1);   // 'A' 错误校验
        #500_000;                       // 等待错误指示(300ms 内)
        check_count(13);
        if (ledr[3] !== 1'b1) begin
            $display("[%0t] FAIL: parity error LED not on", $time);
            errors = errors + 1;
        end

        // 8. 停止位错误的字节: 不应计数, LEDR[4] 点亮
        uart_send(8'h42, 1'b0, 1'b0);   // 'B' 错误停止位
        #500_000;
        check_count(13);
        if (ledr[4] !== 1'b1) begin
            $display("[%0t] FAIL: frame error LED not on", $time);
            errors = errors + 1;
        end
        $display("[%0t] parity/frame error detection ok", $time);

        // 9. 按下复位键 -> 全部清零
        press_reset();
        check_count(0);
        check_blink(1'b0);
        if (hex0 !== 7'b0000000 || hex1 !== 7'b0000000) begin
            $display("[%0t] FAIL: char not blanked after reset", $time);
            errors = errors + 1;
        end
        $display("[%0t] reset key ok", $time);

        // 10. 容错模式(SW[0]=1): "T x w i n" 中间插入无关字符也能识别
        sw_mode = 1'b1;
        uart_send(8'h54, 1'b0, 1'b1);   // 'T'
        uart_send(8'h78, 1'b0, 1'b1);   // 'x'
        uart_send(8'h77, 1'b0, 1'b1);   // 'w'
        uart_send(8'h69, 1'b0, 1'b1);   // 'i'
        uart_send(8'h6E, 1'b0, 1'b1);   // 'n'
        #5_000;
        check_count(5);
        check_blink(1'b1);
        $display("[%0t] tolerant mode ok (T-x-w-i-n detected)", $time);

        // 11. 严格模式(SW[0]=0): 同样序列不应识别
        press_reset();
        sw_mode = 1'b0;
        uart_send(8'h54, 1'b0, 1'b1);   // 'T'
        uart_send(8'h78, 1'b0, 1'b1);   // 'x'
        uart_send(8'h77, 1'b0, 1'b1);   // 'w'
        uart_send(8'h69, 1'b0, 1'b1);   // 'i'
        uart_send(8'h6E, 1'b0, 1'b1);   // 'n'
        #5_000;
        check_count(5);
        check_blink(1'b0);
        $display("[%0t] strict mode ok (interleaved chars rejected)", $time);

        // 12. 严格模式连续 "Twin" 仍能识别
        uart_send(8'h54, 1'b0, 1'b1);
        uart_send(8'h77, 1'b0, 1'b1);
        uart_send(8'h69, 1'b0, 1'b1);
        uart_send(8'h6E, 1'b0, 1'b1);
        #5_000;
        check_count(9);
        check_blink(1'b1);
        $display("[%0t] strict mode consecutive Twin ok", $time);

        // 13. 结果汇总
        if (errors == 0) $display("==== ALL TESTS PASSED ====");
        else             $display("==== %0d TEST(S) FAILED ====", errors);
        $finish;
    end

endmodule
