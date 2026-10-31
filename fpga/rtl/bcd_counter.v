//=============================================================================
// 文件名  : bcd_counter.v
// 功能    : 4 位十进制(BCD)字符计数器, 收到 1 个有效字符加 1
// 说明    : 直接用 BCD 计数, 省去二进制转十进制除法电路;
//           计数到 9999 后饱和不再增加(对应思考题(4)的溢出处理)。
//=============================================================================
module bcd_counter (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,           // 加 1 使能(单周期)
    output reg  [3:0] d0,   // 个位 BCD           // 个位
    output reg  [3:0] d1,           // 十位
    output reg  [3:0] d2,           // 百位
    output reg  [3:0] d3            // 千位
);

    always @(posedge clk) begin
        if (!rst_n) begin
            d0 <= 4'd0;
            d1 <= 4'd0;
            d2 <= 4'd0;
            d3 <= 4'd0;
        end
        else if (en) begin
            if (d0 != 4'd9) begin
                d0 <= d0 + 1'b1;                    // 个位未满 9, 直接加 1
            end
            else begin
                d0 <= 4'd0;                         // 个位进位
                if (d1 != 4'd9) begin
                    d1 <= d1 + 1'b1;
                end
                else begin
                    d1 <= 4'd0;
                    if (d2 != 4'd9) begin
                        d2 <= d2 + 1'b1;
                    end
                    else begin
                        d2 <= 4'd0;
                        if (d3 != 4'd9) begin
                            d3 <= d3 + 1'b1;        // 9999 后保持 (饱和计数)
                        end
                    end
                end
            end
        end
    end

endmodule
