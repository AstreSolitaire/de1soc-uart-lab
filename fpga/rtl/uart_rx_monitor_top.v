//=============================================================================
// 文件名  : uart_rx_monitor_top.v
// 工程    : uart_rx_monitor  (异步串行通信 - 数据接收与监测)
// 平台    : 友晶 DE10-Standard / DE1-SoC  (Cyclone V SoC, 50MHz)
// 功能    :
//   1) 接收 PC 串口(8 数据位 / 奇校验 / 1 停止位)发来的字符;
//   2) 数码管 HEX5~HEX2 显示累计接收字符数(十进制 0000~9999, 饱和计数),
//      HEX1~HEX0 显示最近一个字符的 ASCII 码(十六进制);
//   3) 连续收到字符串 "Twin" 后 LEDR[0] 以 1Hz 周期闪烁(LEDR[2] 常亮指示已识别);
//   4) KEY[0] 停止闪烁, KEY[1] 系统整体复位;
//   5) 监测功能: 奇校验错 / 停止位(帧)错 分别点亮 LEDR[3] / LEDR[4];
//      LEDR[1] 为接收活动指示;
//   6) 可配置功能(拨码开关, 需与串口助手设置一致):
//      SW[1:0] 波特率 00=9600 01=19200 10=38400 11=115200 (LEDR[9:8] 显示)
//      SW[3:2] 校验   00=奇 01=偶 1x=无               (LEDR[7:6] 显示)
//      SW[4]   'Twin'识别 0=严格 1=容错               (LEDR[5]  显示)。
//
// 显示约定:
//   HEX5 HEX4 HEX3 HEX2 | HEX1 HEX0
//   千   百   十   个   | 高4位 低4位   (最近字符 ASCII 码)
//=============================================================================
module uart_rx_monitor_top #(
    parameter integer CLK_FREQ = 50_000_000,   // 系统时钟 50MHz
    parameter integer BLINK_HZ = 1,            // LED 闪烁频率(Hz)
    parameter integer DEBOUNCE_MS = 20         // 按键消抖时间(ms)
)(
    input  wire        clk_50m,      // 50MHz 系统时钟
    input  wire        uart_rx,      // UART 接收引脚(接 USB-TTL 的 TX)
    input  wire        key_stop_n,   // KEY[0] 停止闪烁, 低有效
    input  wire        key_rst_n,    // KEY[1] 系统复位, 低有效
    input  wire [1:0]  sw_baud,      // SW[1:0] 波特率: 00=9600 01=19200 10=38400 11=115200
    input  wire [1:0]  sw_par,       // SW[3:2] 校验: 00=奇 01=偶 1x=无
    input  wire        sw_tolerant,  // SW[4] 'Twin'识别: 0=严格连续 1=允许插入无关字符

    output wire [9:0]  ledr,
    output wire [6:0]  hex0,
    output wire [6:0]  hex1,
    output wire [6:0]  hex2,
    output wire [6:0]  hex3,
    output wire [6:0]  hex4,
    output wire [6:0]  hex5
);

    //==================================================================
    // 1. 上电复位: 上电后保持约 10ms 复位, 保证所有寄存器进入确定状态
    //==================================================================
    localparam integer POR_MAX = CLK_FREQ / 100;        // 10ms

    reg [19:0] por_cnt;
    initial por_cnt = 20'd0;

    wire por_done = (por_cnt == (POR_MAX-1));

    always @(posedge clk_50m) begin
        if (!por_done) por_cnt <= por_cnt + 1'b1;
    end

    //==================================================================
    // 2. 按键消抖与系统复位
    //==================================================================
    wire key_stop_db;       // 消抖后的停止按键, 低有效 (对应板上 KEY[0])
    wire key_rst_db;        // 消抖后的复位按键, 低有效 (对应板上 KEY[1])

    key_debounce #(
        .CLK_FREQ    (CLK_FREQ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) u_db_stop (
        .clk     (clk_50m),
        .rst_n   (por_done),
        .key_n   (key_stop_n),
        .key_out (key_stop_db)
    );

    key_debounce #(
        .CLK_FREQ    (CLK_FREQ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) u_db_rst (
        .clk     (clk_50m),
        .rst_n   (por_done),
        .key_n   (key_rst_n),
        .key_out (key_rst_db)
    );

    // 系统同步复位: 上电复位完成 且 复位键未按下
    wire rst_n = por_done & key_rst_db;   // 系统复位: 上电复位完成 且 KEY[1] 未按下(低有效)

    // 停止按键按下沿 -> 单周期脉冲
    // 按键状态打一拍, 用于生成"按下沿"单周期脉冲
    reg key_stop_db_d;
    always @(posedge clk_50m) begin
        key_stop_db_d <= key_stop_db;
    end
    wire stop_pulse = key_stop_db_d & (~key_stop_db);  // 停止键按下瞬间产生 1 个时钟脉冲

    //==================================================================
    // 3. UART 接收
    //==================================================================
    wire [7:0] rx_data;      // 接收到的 8 位字符
    wire       rx_valid;     // 字节有效脉冲(每收 1 字节 1 个时钟)
    wire       parity_err;
    wire       frame_err;

    // 波特率分频值选择: bit_div = 50MHz/(波特率*16), 四舍五入取整
    reg [15:0] bit_div;
    always @* begin
        case (sw_baud)
            2'b00  : bit_div = 16'd326;   //   9600 bps
            2'b01  : bit_div = 16'd163;   //  19200 bps
            2'b10  : bit_div = 16'd81;    //  38400 bps
            default: bit_div = 16'd27;    // 115200 bps
        endcase
    end
    wire [1:0] par_mode = sw_par;         // 校验模式直通: 00=奇 01=偶 1x=无

    uart_rx #(
        .CLK_FREQ (CLK_FREQ)
    ) u_uart_rx (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .rx_i       (uart_rx),
        .bit_div    (bit_div),
        .par_mode   (par_mode),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .parity_err (parity_err),
        .frame_err  (frame_err),
        .busy       ()
    );

    //==================================================================
    // 4. "Twin" 字符串识别 + 闪烁使能
    //==================================================================
    wire twin_hit;           // 'Twin' 命中脉冲(单时钟)

    twin_detect u_twin_detect (
        .clk         (clk_50m),
        .rst_n       (rst_n),
        .char_en     (rx_valid),
        .char_data   (rx_data),
        .tolerant_en (sw_tolerant),
        .hit         (twin_hit)
    );

    reg blink_en;                       // 闪烁使能: 识别到 Twin 置位, 停止键清零

    always @(posedge clk_50m) begin
        if (!rst_n)             blink_en <= 1'b0;
        else if (twin_hit)      blink_en <= 1'b1;
        else if (stop_pulse)    blink_en <= 1'b0;
    end

    //==================================================================
    // 5. 闪烁时钟: 每半个周期翻转一次, 得到 BLINK_HZ 的方波
    //==================================================================
    localparam [31:0] HALF_DIV_W = CLK_FREQ / (2*BLINK_HZ);
    localparam [24:0] HALF_DIV   = HALF_DIV_W[24:0];   // 50MHz/1Hz 时为 25_000_000

    reg [24:0] blink_cnt;
    reg        blink_ph;

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            blink_cnt <= 25'd0;
            blink_ph  <= 1'b0;
        end
        else if (blink_cnt >= (HALF_DIV-1'b1)) begin
            blink_cnt <= 25'd0;
            blink_ph  <= ~blink_ph;
        end
        else begin
            blink_cnt <= blink_cnt + 1'b1;
        end
    end

    //==================================================================
    // 6. 接收活动指示 / 错误指示(十进制计数 + 指示延时)
    //==================================================================
    localparam [31:0] ACT_MAX_W = (CLK_FREQ / 1000) * 100;    // 100ms 活动指示
    localparam [31:0] ERR_MAX_W = (CLK_FREQ / 1000) * 300;    // 300ms 错误指示
    localparam [22:0] ACT_MAX   = ACT_MAX_W[22:0];            // 50MHz 时为 5_000_000
    localparam [23:0] ERR_MAX   = ERR_MAX_W[23:0];            // 50MHz 时为 15_000_000

    reg [22:0] act_cnt;
    reg [23:0] perr_cnt;
    reg [23:0] ferr_cnt;

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            act_cnt  <= 23'd0;
            perr_cnt <= 24'd0;
            ferr_cnt <= 24'd0;
        end
        else begin
            // 收到字符后指示灯点亮 100ms
            if (rx_valid)            act_cnt <= ACT_MAX;
            else if (act_cnt != 0)   act_cnt <= act_cnt - 1'b1;

            // 校验错 / 帧错指示灯点亮 300ms
            if (parity_err)          perr_cnt <= ERR_MAX;
            else if (perr_cnt != 0)  perr_cnt <= perr_cnt - 1'b1;

            if (frame_err)           ferr_cnt <= ERR_MAX;
            else if (ferr_cnt != 0)  ferr_cnt <= ferr_cnt - 1'b1;
        end
    end

    //==================================================================
    // 7. 字符计数(BCD)与最近字符锁存
    //==================================================================
    wire [3:0] cnt_d0, cnt_d1, cnt_d2, cnt_d3;   // BCD 四位: 个/十/百/千

    bcd_counter u_char_cnt (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .en    (rx_valid),
        .d0    (cnt_d0),
        .d1    (cnt_d1),
        .d2    (cnt_d2),
        .d3    (cnt_d3)
    );

    reg [7:0] last_char;
    reg       char_seen;

    always @(posedge clk_50m) begin
        if (!rst_n) begin
            last_char <= 8'h00;
            char_seen <= 1'b0;
        end
        else if (rx_valid) begin
            last_char <= rx_data;
            char_seen <= 1'b1;
        end
    end

    //==================================================================
    // 8. LED 输出
    //==================================================================
    assign ledr[0]    = blink_en & blink_ph;    // Twin 已识别: 1Hz 闪烁
    assign ledr[1]    = (act_cnt != 0);         // 正在接收字符(活动指示)
    assign ledr[2]    = blink_en;               // 常亮: 闪烁功能处于开启状态
    assign ledr[3]    = (perr_cnt != 0);        // 奇校验错误
    assign ledr[4]    = (ferr_cnt != 0);        // 停止位错误(帧错)
    assign ledr[9:5]  = 5'b00000;

    //==================================================================
    // 9. 数码管显示
    //==================================================================
    seg7_decode u_hex0 (.bin(last_char[3:0]), .blank(~char_seen), .seg(hex0));  // 字符低 4 位
    seg7_decode u_hex1 (.bin(last_char[7:4]), .blank(~char_seen), .seg(hex1));  // 字符高 4 位
    seg7_decode u_hex2 (.bin(cnt_d0),         .blank(1'b0),       .seg(hex2));  // 个位
    seg7_decode u_hex3 (.bin(cnt_d1),         .blank(1'b0),       .seg(hex3));  // 十位
    seg7_decode u_hex4 (.bin(cnt_d2),         .blank(1'b0),       .seg(hex4));  // 百位
    seg7_decode u_hex5 (.bin(cnt_d3),         .blank(1'b0),       .seg(hex5));  // 千位

endmodule
