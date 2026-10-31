//=============================================================================
// 文件名  : uart_tx.v
// 功能    : UART 异步串行发送模块
// 帧格式  : 1 起始位 + 8 数据位(低位先发) + 1 奇校验位 + 1 停止位
//           (与 uart_rx.v 配对, 也与串口助手 9600-8-ODD-1 设置一致)
// 说明    : start 给 1 个时钟脉冲即启动一帧发送, busy 在整个帧期间保持 1;
//           波特率时钟由 CLK_FREQ/BAUD 分频得到。
//=============================================================================
module uart_tx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 9600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,     // 1 时钟脉冲, 启动发送
    input  wire [7:0] data,      // 待发送字节
    output reg        tx,        // 串行输出(空闲为高)
    output reg        busy       // 帧发送期间为 1
);

    localparam integer BITC = CLK_FREQ / BAUD;              // 每个位时间的时钟数
    localparam [2:0] S_IDLE=3'd0, S_START=3'd1, S_DATA=3'd2,
                     S_PAR=3'd3,  S_STOP=3'd4;

    reg [2:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bidx;
    reg [7:0]  sh;
    reg        par;

    always @(posedge clk) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            tx   <= 1'b1;
            busy <= 1'b0;
            cnt  <= 16'd0;
            bidx <= 3'd0;
            sh   <= 8'h00;
            par  <= 1'b1;
        end
        else begin
            case (st)
                S_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    cnt  <= 16'd0;
                    if (start) begin
                        sh   <= data;
                        par  <= ~(^data);        // 奇校验: 数据中 1 的个数为奇时校验位=0
                        bidx <= 3'd0;
                        st   <= S_START;
                        busy <= 1'b1;
                    end
                end

                S_START: begin                   // 起始位 0
                    tx <= 1'b0;
                    if (cnt == BITC-1) begin cnt <= 16'd0; st <= S_DATA; end
                    else               cnt <= cnt + 1'b1;
                end

                S_DATA: begin                    // 8 数据位, 低位先发
                    tx <= sh[bidx];
                    if (cnt == BITC-1) begin
                        cnt <= 16'd0;
                        if (bidx == 3'd7) st <= S_PAR;
                        else              bidx <= bidx + 1'b1;
                    end
                    else cnt <= cnt + 1'b1;
                end

                S_PAR: begin                     // 奇校验位
                    tx <= par;
                    if (cnt == BITC-1) begin cnt <= 16'd0; st <= S_STOP; end
                    else               cnt <= cnt + 1'b1;
                end

                S_STOP: begin                    // 停止位 1, 完成后回 IDLE
                    tx <= 1'b1;
                    if (cnt == BITC-1) begin
                        cnt  <= 16'd0;
                        st   <= S_IDLE;
                        busy <= 1'b0;
                    end
                    else cnt <= cnt + 1'b1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
