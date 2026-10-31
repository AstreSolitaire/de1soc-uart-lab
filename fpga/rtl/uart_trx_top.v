//=============================================================================
// 文件名  : uart_trx_top.v
// 工程    : uart_trx  (异步串行通信 - 收发一体自检)
// 平台    : 友晶 DE1-SoC (Cyclone V SoC 5CSEMA5F31C6, 50MHz)
// 功能    :
//   1) 回显(Echo): PC 发来的每个字符, FPGA 原样发回 —— 在串口助手窗口
//      立刻看到自己打的字, 整条链路(收+发+接线)一目了然, 即"直观的串口检测";
//   2) 按键发字符串: 按 KEY[0], FPGA 主动向 PC 连续发送 "DE1-SOC UART OK!\r\n";
//   3) 数码管: HEX5~HEX2 显示累计收到的字符数(十进制),
//      HEX1~HEX0 显示最近一个字符的 ASCII 码(十六进制);
//   4) LED 指示: LEDR[0]=发送活动(每发1字节亮100ms), LEDR[1]=接收活动(100ms),
//      LEDR[2]=1Hz 心跳(程序运行指示), LEDR[3]=正在发送按键字符串;
//   5) KEY[1]=系统复位。
//
// 引脚约定(DE1-SoC):
//   GPIO_0[0] (JP1 第1孔)          = UART RX  (接 USB-TTL 转接器 TXD, 绿线)
//   GPIO_0[1/2/3/4/20/21] 多脚驱动 = UART TX  (接 USB-TTL 转接器 RXD, 白线,
//                                    顶端几个孔中的任何一个都可以插)
//   黑线(GND) 接 2x5 ADC 排针第10脚 或 金色螺丝柱。
//=============================================================================
module uart_trx_top #(
    parameter integer CLK_FREQ    = 50_000_000,
    parameter integer BAUD        = 9600,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire        clk_50m,
    input  wire        uart_rx_i,     // FPGA 接收 (转接器 TXD, 绿线)
    input  wire        key0_n,        // 发送按键字符串, 低有效
    input  wire        key1_n,        // 系统复位, 低有效

    output wire        uart_tx_1,     // GPIO_0[1]  PIN_Y17
    output wire        uart_tx_2,     // GPIO_0[2]  PIN_AD17
    output wire        uart_tx_3,     // GPIO_0[3]  PIN_Y18
    output wire        uart_tx_4,     // GPIO_0[4]  PIN_AK16
    output wire        uart_tx_20,    // GPIO_0[20] PIN_AH19
    output wire        uart_tx_21,    // GPIO_0[21] PIN_AJ20

    output wire [9:0]  ledr,
    output wire [6:0]  hex0,
    output wire [6:0]  hex1,
    output wire [6:0]  hex2,
    output wire [6:0]  hex3,
    output wire [6:0]  hex4,
    output wire [6:0]  hex5
);

    //==================================================================
    // 1. 上电复位(10ms) + 按键消抖
    //==================================================================
    localparam integer POR_MAX = CLK_FREQ / 100;
    reg [19:0] por_cnt;
    initial por_cnt = 20'd0;
    wire por_done = (por_cnt == POR_MAX-1);
    always @(posedge clk_50m) begin
        if (!por_done) por_cnt <= por_cnt + 1'b1;
    end

    wire key0_db, key1_db;
    key_debounce #(.CLK_FREQ(CLK_FREQ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_db0 (
        .clk(clk_50m), .rst_n(por_done), .key_n(key0_n), .key_out(key0_db));
    key_debounce #(.CLK_FREQ(CLK_FREQ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_db1 (
        .clk(clk_50m), .rst_n(por_done), .key_n(key1_n), .key_out(key1_db));

    wire rst_n = por_done & key1_db;

    reg key0_db_d;
    always @(posedge clk_50m) key0_db_d <= key0_db;
    wire key0_pulse = key0_db_d & (~key0_db);           // 按下沿脉冲

    //==================================================================
    // 2. UART 接收
    //==================================================================
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk_50m), .rst_n(rst_n), .rx_i(uart_rx_i),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .parity_err(), .frame_err(), .busy());

    //==================================================================
    // 3. 发送 FIFO(深度16): 回显与按键字符串共用发送通道
    //==================================================================
    reg [7:0] fifo_mem [0:15];
    reg [3:0] fcount, fwr, frd;
    wire      fifo_full = (fcount == 4'd15);

    // 按键字符串 ROM: "DE1-SOC UART OK!\r\n" 共 18 字节
    localparam GREET_LEN = 18;
    function [7:0] greet_rom(input [4:0] i);
        case (i)
            5'd0 : greet_rom = 8'h44; // 'D'
            5'd1 : greet_rom = 8'h45; // 'E'
            5'd2 : greet_rom = 8'h31; // '1'
            5'd3 : greet_rom = 8'h2D; // '-'
            5'd4 : greet_rom = 8'h53; // 'S'
            5'd5 : greet_rom = 8'h4F; // 'O'
            5'd6 : greet_rom = 8'h43; // 'C'
            5'd7 : greet_rom = 8'h20; // ' '
            5'd8 : greet_rom = 8'h55; // 'U'
            5'd9 : greet_rom = 8'h41; // 'A'
            5'd10: greet_rom = 8'h52; // 'R'
            5'd11: greet_rom = 8'h54; // 'T'
            5'd12: greet_rom = 8'h20; // ' '
            5'd13: greet_rom = 8'h4F; // 'O'
            5'd14: greet_rom = 8'h4B; // 'K'
            5'd15: greet_rom = 8'h21; // '!'
            5'd16: greet_rom = 8'h0D; // '\r'
            default: greet_rom = 8'h0A; // '\n'
        endcase
    endfunction

    // 字符串发送状态机
    reg        greet_run;
    reg [4:0]  gidx;
    wire       greet_push = greet_run && !rx_valid && !fifo_full;  // FIFO 满时等待, 不丢字符
    wire [7:0] greet_data = greet_rom(gidx);

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            greet_run <= 1'b0;
            gidx      <= 5'd0;
        end
        else begin
            if (key0_pulse && !greet_run) begin
                greet_run <= 1'b1;
                gidx      <= 5'd0;
            end
            else if (greet_run && greet_push) begin
                if (gidx == GREET_LEN-1) begin
                    greet_run <= 1'b0;
                    gidx      <= 5'd0;
                end
                else gidx <= gidx + 1'b1;
            end
        end
    end

    // ---- FIFO 写指针/计数(单块统一维护, 避免多驱动) ----
    wire       fifo_we   = rx_valid | greet_push;   // 每周期最多写 1 个
    wire [7:0] fifo_wd   = rx_valid ? rx_data : greet_data;
    wire       fifo_wr_en = fifo_we && !fifo_full;

    // ---- 发送弹出握手: 产生 1 周期 start 脉冲, 每脉冲只弹 1 字节 ----
    wire tx_busy;                                   // uart_tx 忙标志(前向声明)
    wire       can_pop = !tx_busy && (fcount != 4'd0);
    reg        start_r, start_d;
    wire       pop_now = start_r & ~start_d;       // start_r 上升沿 = 弹出时刻

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            start_r <= 1'b0;
            start_d <= 1'b0;
        end
        else begin
            start_r <= can_pop;                    // uart_tx 在 IDLE 时锁存 start
            start_d <= start_r;
        end
    end

    // ---- FIFO 指针与计数(单一 always 块) ----
    always @(posedge clk_50m) begin
        if (!rst_n) begin
            fwr    <= 4'd0;
            frd    <= 4'd0;
            fcount <= 4'd0;
        end
        else begin
            if (fifo_wr_en) begin
                fifo_mem[fwr] <= fifo_wd;
                fwr           <= fwr + 1'b1;
            end
            if (pop_now)
                frd <= frd + 1'b1;

            case ({fifo_wr_en, pop_now})
                2'b10  : fcount <= fcount + 1'b1;
                2'b01  : fcount <= fcount - 1'b1;
                2'b11  : fcount <= fcount;         // 同周期一写一读, 计数不变
                default: fcount <= fcount;
            endcase
        end
    end

    //==================================================================
    // 4. UART 发送
    //==================================================================
    wire tx_line;
    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk_50m), .rst_n(rst_n),
        .start(start_r), .data(fifo_mem[frd]),
        .tx(tx_line), .busy(tx_busy));

    //==================================================================
    // 5. LED 指示
    //==================================================================
    localparam [22:0] BLIP_MAX = 23'd100_000;          // 100ms @50MHz
    localparam [24:0] HALF_DIV = 25'd25_000_000;       // 1Hz 心跳
    reg [22:0] rx_blip, tx_blip;
    reg [24:0] hb_cnt;
    reg        hb_ph;

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            rx_blip <= 23'd0; tx_blip <= 23'd0;
        end
        else begin
            if (tx_busy)             tx_blip <= BLIP_MAX;
            else if (tx_blip != 0)   tx_blip <= tx_blip - 1'b1;
            if (rx_valid)            rx_blip <= BLIP_MAX;
            else if (rx_blip != 0)   rx_blip <= rx_blip - 1'b1;
        end
    end

    always @(posedge clk_50m) begin
        if (!rst_n) begin hb_cnt <= 25'd0; hb_ph <= 1'b0; end
        else if (hb_cnt >= HALF_DIV-1'b1) begin hb_cnt <= 25'd0; hb_ph <= ~hb_ph; end
        else hb_cnt <= hb_cnt + 1'b1;
    end

    assign ledr[0] = (tx_blip != 0);     // 发送活动
    assign ledr[1] = (rx_blip != 0);     // 接收活动
    assign ledr[2] = hb_ph;              // 1Hz 心跳 = 程序运行中
    assign ledr[3] = greet_run;          // 正在发送按键字符串
    assign ledr[9:4] = 6'd0;

    //==================================================================
    // 6. 数码管: 收到的字符计数 + 最近字符 ASCII
    //==================================================================
    wire [3:0] cnt_d0, cnt_d1, cnt_d2, cnt_d3;
    bcd_counter u_char_cnt (
        .clk(clk_50m), .rst_n(rst_n), .en(rx_valid),
        .d0(cnt_d0), .d1(cnt_d1), .d2(cnt_d2), .d3(cnt_d3));

    reg [7:0] last_char;
    reg       char_seen;
    always @(posedge clk_50m) begin
        if (!rst_n) begin last_char <= 8'h00; char_seen <= 1'b0; end
        else if (rx_valid) begin last_char <= rx_data; char_seen <= 1'b1; end
    end

    seg7_decode u_hex0 (.bin(last_char[3:0]), .blank(~char_seen), .seg(hex0));
    seg7_decode u_hex1 (.bin(last_char[7:4]), .blank(~char_seen), .seg(hex1));
    seg7_decode u_hex2 (.bin(cnt_d0), .blank(1'b0), .seg(hex2));
    seg7_decode u_hex3 (.bin(cnt_d1), .blank(1'b0), .seg(hex3));
    seg7_decode u_hex4 (.bin(cnt_d2), .blank(1'b0), .seg(hex4));
    seg7_decode u_hex5 (.bin(cnt_d3), .blank(1'b0), .seg(hex5));

    // TX 线驱动到 6 个 GPIO 引脚(覆盖排针两种编号习惯, 白线任选一个孔)
    assign uart_tx_1  = tx_line;
    assign uart_tx_2  = tx_line;
    assign uart_tx_3  = tx_line;
    assign uart_tx_4  = tx_line;
    assign uart_tx_20 = tx_line;
    assign uart_tx_21 = tx_line;

endmodule
