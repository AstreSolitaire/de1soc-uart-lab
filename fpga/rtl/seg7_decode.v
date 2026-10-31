//=============================================================================
// 文件名  : seg7_decode.v
// 功能    : 十六进制 -> 七段数码管译码
// 说明    : DE10-Standard / DE1-SoC 的数码管为共阳极, 段码低电平点亮,
//           段索引与板卡引脚一致: seg[0]=a(上), seg[1]=b, seg[2]=c,
//           seg[3]=d(下), seg[4]=e, seg[5]=f, seg[6]=g(中间)。
//           blank=1 时整位熄灭(用于"尚未收到字符"时消隐)。
//=============================================================================
module seg7_decode (
    input  wire [3:0] bin,
    input  wire       blank,
    output wire [6:0] seg          // 低有效段码
);

    reg [6:0] m;                    // 高有效段码, bit0=a(上)...bit6=g(中), 输出取反后低电平点亮

    always @* begin
        case (bin)
            4'h0: m = 7'b0111111;   // a b c d e f
            4'h1: m = 7'b0000110;   // b c
            4'h2: m = 7'b1011011;   // a b d e g
            4'h3: m = 7'b1001111;   // a b c d g
            4'h4: m = 7'b1100110;   // b c f g
            4'h5: m = 7'b1101101;   // a c d f g
            4'h6: m = 7'b1111101;   // a c d e f g
            4'h7: m = 7'b0000111;   // a b c
            4'h8: m = 7'b1111111;   // 全亮
            4'h9: m = 7'b1101111;   // a b c d f g
            4'hA: m = 7'b1110111;   // a b c e f g
            4'hB: m = 7'b1111100;   // c d e f g
            4'hC: m = 7'b0111001;   // a d e f
            4'hD: m = 7'b1011110;   // b c d e g
            4'hE: m = 7'b1111001;   // a d e f g
            4'hF: m = 7'b1110001;   // a e f g
            default: m = 7'b0000000;
        endcase
    end

    assign seg = blank ? 7'b0000000 : ~m;

endmodule
