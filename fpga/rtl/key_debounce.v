//=============================================================================
// 文件名  : key_debounce.v
// 功能    : 按键消抖模块(低电平有效)
// 原理    : 板载机械按键按下/释放时会有 5~20ms 的抖动。模块用计数器对
//           "输入与当前稳定输出不一致"的时间计时, 只有连续保持不一致达到
//           DEBOUNCE_MS 毫秒, 才承认输入变化, 否则计数器清零。
//=============================================================================
module key_debounce #(
    parameter integer CLK_FREQ    = 50_000_000,   // 系统时钟频率(Hz)
    parameter integer DEBOUNCE_MS = 20            // 消抖时间(ms)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,      // 原始按键输入, 低有效
    output reg  key_out     // 消抖后输出, 低有效
);

    localparam integer CNT_MAX = (CLK_FREQ / 1000) * DEBOUNCE_MS;   // 50MHz/20ms 时为 1_000_000

    reg [23:0] cnt;      // 稳定计时器: 50MHz x 20ms = 100 万个时钟, 24 位足够

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt     <= 24'd0;
            key_out <= 1'b1;            // 按键未按下 = 高电平
        end
        else if (key_n != key_out) begin
            if (cnt >= (CNT_MAX-1)) begin
                cnt     <= 24'd0;
                key_out <= key_n;       // 稳定保持足够时间, 承认新电平
            end
            else begin
                cnt <= cnt + 1'b1;
            end
        end
        else begin
            cnt <= 24'd0;               // 电平一致(或抖动返回), 重新计时
        end
    end

endmodule
