//=============================================================================
// 文件名  : uart_rx.v
// 功能    : UART 异步串行接收模块(波特率/校验模式可运行时切换)
// 帧格式  : 1 起始位 + 8 数据位(低位先发) + [奇/偶校验位] + 1 停止位
//           校验位由 par_mode 决定是否存在与如何校验:
//             2'b00 = 奇校验(ODD) : 数据+校验位中 1 的个数为奇
//             2'b01 = 偶校验(EVEN): 数据+校验位中 1 的个数为偶
//             2'b1x = 无校验(NONE): 帧中不含校验位, D7 后直接是停止位
// 采样方式: 16 倍过采样, 位中心连续采样 3 次并三取二表决
// 波特率  : 由 bit_div 输入运行时给定 —— bit_div = CLK_FREQ/(BAUD*16) 的四舍五入值
//           (拨码开关切换波特率即切换 bit_div, 帧与帧之间切换安全)
// 说明    :
//   1) 异步输入先经过两级触发器同步(rx_meta/rx_sync), 再做下降沿检测,
//      避免亚稳态直接进入状态机;
//   2) os_cnt 把每个位时间等分为 16 份, 在 os_cnt==6/7/8 三个点采样,
//      对应位中心附近, 表决结果 = 3 个采样值中多数值, 可滤除边沿抖动;
//   3) 一帧结束后做校验判定与停止位判定:
//        - 校验错  -> parity_err 输出 1 个时钟脉冲, 该字节不输出;
//        - 停止位错 -> frame_err  输出 1 个时钟脉冲, 该字节不输出。
//=============================================================================
module uart_rx #(
    parameter integer CLK_FREQ = 50_000_000   // 系统时钟频率(Hz)
)(
    input  wire        clk,
    input  wire        rst_n,        // 同步复位, 低有效
    input  wire        rx_i,         // UART 接收引脚(空闲为高)
    input  wire [15:0] bit_div,      // 1/16 位时间的时钟数 = CLK_FREQ/(BAUD*16)
    input  wire [1:0]  par_mode,     // 00=奇校验 01=偶校验 1x=无校验
    output reg  [7:0]  rx_data,      // 收到的一个字节
    output reg         rx_valid,     // 字节有效, 单时钟脉冲
    output reg         parity_err,   // 校验错, 单时钟脉冲
    output reg         frame_err,    // 停止位错, 单时钟脉冲
    output wire        busy          // 正在接收一帧
);

    localparam integer OS = 16;        // 过采样倍数

    // 状态机编码
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_PAR   = 3'd3,
                     S_STOP  = 3'd4;

    //------------------------------------------------------------------
    // 1. 异步输入同步 + 下降沿检测
    //------------------------------------------------------------------
    reg rx_meta, rx_sync, rx_sync_d;

    always @(posedge clk) begin
        rx_meta   <= rx_i;
        rx_sync   <= rx_meta;
        rx_sync_d <= rx_sync;
    end

    //------------------------------------------------------------------
    // 2. 16 倍过采样节拍: clk_cnt 计 bit_div 个时钟, os_cnt 计 16 个节拍
    //    (start_edge 到来时计数器清零, 实现与起始位的对齐)
    //------------------------------------------------------------------
    reg [15:0] clk_cnt;
    reg [3:0]  os_cnt;
    reg [2:0]  state;

    wire start_edge = (state == S_IDLE) && (rx_sync_d == 1'b1) && (rx_sync == 1'b0);

    always @(posedge clk) begin
        if (!rst_n) begin
            clk_cnt <= 16'd0;
            os_cnt  <= 4'd0;
        end
        else if (start_edge) begin          // 检测到起始位下降沿, 对齐采样节拍
            clk_cnt <= 16'd0;
            os_cnt  <= 4'd0;
        end
        else if (clk_cnt >= bit_div-1'b1) begin  // 一个 1/16 位时间到(分频值运行时可变)
            clk_cnt <= 16'd0;
            os_cnt  <= os_cnt + 1'b1;        // 4 位, 15 后自然回绕到 0
        end
        else begin
            clk_cnt <= clk_cnt + 1'b1;
        end
    end

    // 每个位时间内, os_cnt==8 窗口的第一个时钟即为判决时刻(位中心)
    wire bit_tick = (clk_cnt == 16'd0) && (os_cnt == 4'd8);

    //------------------------------------------------------------------
    // 3. 位中心 3 点采样与三取二表决
    //------------------------------------------------------------------
    reg  s_a, s_b;                                  // os_cnt = 6 / 7 时的采样值
    wire vote = (s_a & s_b) | (s_b & rx_sync) | (s_a & rx_sync);

    //------------------------------------------------------------------
    // 4. 接收状态机
    //------------------------------------------------------------------
    reg [2:0]  bidx;                     // 当前接收的位序号(0~7)
    reg [7:0]  sh;                       // 数据位移位寄存器(低位先收)
    reg        par_bit;                  // 校验位暂存
    wire       no_par  = par_mode[1];    // 无校验模式
    wire       par_odd = ~par_mode[0];   // 00=奇(odd), 01=偶(even)

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            bidx       <= 3'd0;
            sh         <= 8'h00;
            par_bit    <= 1'b0;
            s_a        <= 1'b1;              // 空闲为高, 避免误判
            s_b        <= 1'b1;
            rx_data    <= 8'h00;
            rx_valid   <= 1'b0;
            parity_err <= 1'b0;
            frame_err  <= 1'b0;
        end
        else begin
            rx_valid   <= 1'b0;               // 默认输出单周期脉冲
            parity_err <= 1'b0;
            frame_err  <= 1'b0;

            if (os_cnt == 4'd6)      s_a <= rx_sync;
            else if (os_cnt == 4'd7) s_b <= rx_sync;

            // 空闲态随时监测起始位下降沿(节拍计数器同时被清零对齐)
            if (state == S_IDLE) begin
                if (start_edge) state <= S_START;
            end
            // 其余状态只在位中心判决时刻(bit_tick)动作
            else if (bit_tick) begin
                case (state)
                    //--------------------------------------------------
                    S_START: begin                  // 起始位中心应为 0
                        if (vote == 1'b0) begin
                            bidx <= 3'd0;
                            state <= S_DATA;
                        end
                        else begin                  // 干扰毛刺, 重新等待起始位
                            state <= S_IDLE;
                        end
                    end

                    //--------------------------------------------------
                    S_DATA: begin                   // 8 数据位, 低位先收
                        sh[bidx] <= vote;
                        if (bidx == 3'd7)
                            state <= no_par ? S_STOP : S_PAR;  // 无校验时跳过校验位
                        else
                            bidx <= bidx + 1'b1;
                    end

                    //--------------------------------------------------
                    S_PAR: begin                    // 奇/偶校验位
                        par_bit <= vote;
                        state   <= S_STOP;
                    end

                    //--------------------------------------------------
                    S_STOP: begin                   // 停止位必须为 1
                        if (vote == 1'b1) begin
                            // 校验判定: 只在奇/偶模式下检查, 无校验模式直接有效
                            if (no_par ||
                                (par_odd  && ((^{sh, par_bit}) == 1'b1)) ||
                                (~par_odd && ((^{sh, par_bit}) == 1'b0))) begin
                                rx_data  <= sh;
                                rx_valid <= 1'b1;
                            end
                            else begin
                                parity_err <= 1'b1;   // 校验错, 丢弃该字节
                            end
                        end
                        else begin
                            frame_err <= 1'b1;        // 停止位错(帧错), 丢弃
                        end
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    assign busy = (state != S_IDLE);     // 一帧接收期间为 1

endmodule
