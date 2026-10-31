//=============================================================================
// 文件名  : twin_detect.v
// 功能    : 字符串 "Twin" 序列检测
// 说明    : 提供两种识别方式, 由 tolerant_en 选择:
//           tolerant_en = 0 : 严格模式 —— 4 字节移位寄存器, 只有连续收到
//                             'T''w''i''n' 才命中(指导书基本要求);
//           tolerant_en = 1 : 容错模式 —— 有限状态机, 允许字符之间插入
//                             无关字符(如 "Txxwin" 也能识别), 对应思考题(2)。
//           命中时 hit 输出 1 个时钟周期的脉冲。
//=============================================================================
module twin_detect (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       char_en,        // 收到新字符使能(等于 uart 的 rx_valid)
    input  wire [7:0] char_data,      // 新字符
    input  wire       tolerant_en,    // 1 = 容错模式, 0 = 严格连续模式
    output wire       hit             // 命中 "Twin", 单周期脉冲
);

    // "Twin" 的 ASCII 码
    localparam [7:0] C_T = 8'h54,   // 'T'
                     C_W = 8'h77,   // 'w'
                     C_I = 8'h69,   // 'i'
                     C_N = 8'h6E;   // 'n'

    //------------------------------------------------------------------
    // 严格模式: 4 字节移位寄存器 + 连续比对
    //------------------------------------------------------------------
    reg [31:0] sr;

    always @(posedge clk) begin
        if (!rst_n)             sr <= 32'd0;
        else if (char_en)       sr <= {sr[23:0], char_data};
    end

    wire [31:0] sr_next = {sr[23:0], char_data};
    wire        strict_hit = char_en && (sr_next == {C_T, C_W, C_I, C_N});

    //------------------------------------------------------------------
    // 容错模式: 状态机 p 表示已匹配到 "Twin" 的第几个字符。
    // 未匹配到期望字符时保持当前进度(即忽略插入的无关字符),
    // 只有遇到 'T' 才重新从第 2 个字符开始尝试。
    //------------------------------------------------------------------
    reg [1:0] p;

    always @(posedge clk) begin
        if (!rst_n) begin
            p <= 2'd0;
        end
        else if (char_en) begin
            case (p)
                2'd0: p <= (char_data == C_T) ? 2'd1 : 2'd0;
                2'd1: p <= (char_data == C_W) ? 2'd2 : 2'd1;
                2'd2: p <= (char_data == C_I) ? 2'd3 :
                           (char_data == C_T) ? 2'd1 : 2'd2;
                2'd3: p <= (char_data == C_N) ? 2'd0 :
                           (char_data == C_T) ? 2'd1 : 2'd3;
                default: p <= 2'd0;
            endcase
        end
    end

    wire tolerant_hit = char_en && (p == 2'd3) && (char_data == C_N);

    assign hit = tolerant_en ? tolerant_hit : strict_hit;

endmodule
