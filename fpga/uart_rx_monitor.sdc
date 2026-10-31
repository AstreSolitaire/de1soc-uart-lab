# =============================================================================
#  uart_rx_monitor.sdc  时序约束
#  系统只有一个 50MHz 时钟; 串口、按键、拨码开关均为异步输入,
#  已在 RTL 内部做两级同步(串口)或消抖(按键), 因此不做输入延时分析。
# =============================================================================

create_clock -name clk50m -period 20.000 [get_ports {clk_50m}]

# 异步输入端口: 不作为时序路径起点分析
set_false_path -from [get_ports {uart_rx}]
set_false_path -from [get_ports {key_stop_n}]
set_false_path -from [get_ports {key_rst_n}]
set_false_path -from [get_ports {sw_mode}]

# 输出到 LED / 数码管为静态显示, 无需输出延时约束
