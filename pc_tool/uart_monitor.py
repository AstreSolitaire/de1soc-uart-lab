#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# 串口监测软件 (UART Monitor)  —— 配合 DE1-SoC 异步串行通信实验使用
#
# 功能:
#   1) 自动检测并列出所有可用串口(标注 USB-TTL 转接器);
#   2) 打开/关闭串口, 波特率/数据位/校验/停止位可配置(默认 9600/8/奇校验/1);
#   3) 发送区: 手动输入发送(回车或点按钮), 支持 ASCII / HEX 两种格式;
#   4) 接收区: 实时显示收到的数据(带时间戳, 可切换 ASCII/HEX);
#   5) 统计: RX/TX 字节计数, 连接时长;
#   6) 实验快捷键: 一键发送 Hello / Twin / 12345 (配合板上数码管计数实验);
#   7) 日志保存: 接收区内容一键保存为文本文件。
#
# 运行环境: Windows + Python3 + pyserial  (pip install pyserial)
# 启动:     python uart_monitor.py
#=============================================================================
import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox, filedialog
import serial
import serial.tools.list_ports
import threading
import queue
import datetime
import time

APP_TITLE = "串口监测软件 - DE1-SoC 异步串行通信实验"
TS = lambda: datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

#-----------------------------------------------------------------------------
class UartMonitor(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("880x640")
        self.minsize(760, 560)

        self.ser        = None          # serial.Serial 实例
        self.rx_thread  = None          # 接收线程
        self.rx_queue   = queue.Queue() # 接收队列(线程->UI)
        self.rx_count   = 0
        self.tx_count   = 0
        self.t_connect  = None
        self.closing    = False

        self._build_ui()
        self.refresh_ports()
        self.after(80, self._poll_rx)   # UI 定时刷新

    #-------------------------------------------------------------------------
    # 界面
    #-------------------------------------------------------------------------
    def _build_ui(self):
        # ---- 第一行: 串口配置 ----
        top = ttk.LabelFrame(self, text=" 串口配置 ")
        top.pack(fill="x", padx=8, pady=(8, 4))

        ttk.Label(top, text="串口:").grid(row=0, column=0, padx=4, pady=6, sticky="e")
        self.cmb_port = ttk.Combobox(top, width=22, state="readonly")
        self.cmb_port.grid(row=0, column=1, padx=2)
        ttk.Button(top, text="刷新", width=6, command=self.refresh_ports)\
            .grid(row=0, column=2, padx=2)

        ttk.Label(top, text="波特率:").grid(row=0, column=3, padx=(14, 0), sticky="e")
        self.cmb_baud = ttk.Combobox(top, width=9, state="readonly",
            values=["9600", "19200", "38400", "57600", "115200"])
        self.cmb_baud.set("9600")
        self.cmb_baud.grid(row=0, column=4, padx=2)

        ttk.Label(top, text="校验:").grid(row=0, column=5, padx=(14, 0), sticky="e")
        self.cmb_par = ttk.Combobox(top, width=6, state="readonly",
            values=["奇校验(ODD)", "无校验(NONE)", "偶校验(EVEN)"])
        self.cmb_par.set("奇校验(ODD)")
        self.cmb_par.grid(row=0, column=6, padx=2)

        ttk.Label(top, text="数据位:").grid(row=0, column=7, padx=(14, 0), sticky="e")
        self.cmb_data = ttk.Combobox(top, width=4, state="readonly", values=["8"])
        self.cmb_data.set("8")
        self.cmb_data.grid(row=0, column=8, padx=2)

        ttk.Label(top, text="停止位:").grid(row=0, column=9, padx=(14, 0), sticky="e")
        self.cmb_stop = ttk.Combobox(top, width=4, state="readonly", values=["1"])
        self.cmb_stop.set("1")
        self.cmb_stop.grid(row=0, column=10, padx=2)

        self.btn_open = ttk.Button(top, text="打开串口", width=10,
                                   command=self.toggle_open)
        self.btn_open.grid(row=0, column=11, padx=(18, 4))

        for c in range(12):
            top.columnconfigure(c, weight=0)
        top.columnconfigure(1, weight=1)

        # ---- 第二行: 实验快捷发送 ----
        quick = ttk.LabelFrame(self, text=" 实验快捷发送 (发往开发板, 观察数码管计数与 LED) ")
        quick.pack(fill="x", padx=8, pady=4)
        self.quick_btns = []
        for i, (txt, arg) in enumerate([("Hello", b"Hello"), ("Twin", b"Twin"),
                                        ("12345", b"12345"), ("DE1-SOC", b"DE1-SOC")]):
            b = ttk.Button(quick, text=txt, width=12,
                           command=lambda a=arg: self.send_data(a))
            b.grid(row=0, column=i, padx=8, pady=6)
            self.quick_btns.append(b)
        ttk.Label(quick, text="提示: 发 'Twin' 后板上 LEDR[0] 会以 1Hz 闪烁")\
            .grid(row=0, column=5, padx=16)

        # ---- 接收区 ----
        rx_frame = ttk.LabelFrame(self, text=" 接收区 ")
        rx_frame.pack(fill="both", expand=True, padx=8, pady=4)
        self.txt_rx = scrolledtext.ScrolledText(rx_frame, height=14, font=("Consolas", 10))
        self.txt_rx.pack(fill="both", expand=True, padx=4, pady=4)
        self.txt_rx.configure(state="disabled")

        rx_opt = ttk.Frame(rx_frame)
        rx_opt.pack(fill="x", padx=4, pady=(0, 4))
        self.var_hex_rx = tk.BooleanVar(value=False)
        ttk.Checkbutton(rx_opt, text="十六进制显示", variable=self.var_hex_rx)\
            .pack(side="left")
        # 乱码(不可打印字节)统一显示为 FF, 避免接收区出现乱码方块
        self.var_garb = tk.BooleanVar(value=True)
        ttk.Checkbutton(rx_opt, text="乱码显示为 FF", variable=self.var_garb)\
            .pack(side="left", padx=12)
        self.var_ts = tk.BooleanVar(value=True)
        ttk.Checkbutton(rx_opt, text="时间戳", variable=self.var_ts).pack(side="left", padx=12)
        ttk.Button(rx_opt, text="清空接收区", width=12, command=self._clear_rx)\
            .pack(side="left", padx=12)
        ttk.Button(rx_opt, text="保存日志...", width=12, command=self._save_log)\
            .pack(side="left", padx=12)

        # ---- 发送区 ----
        tx_frame = ttk.LabelFrame(self, text=" 发送区 ")
        tx_frame.pack(fill="x", padx=8, pady=4)
        self.ent_tx = ttk.Entry(tx_frame, font=("Consolas", 11))
        self.ent_tx.pack(side="left", fill="x", expand=True, padx=4, pady=6)
        self.ent_tx.bind("<Return>", lambda e: self._send_from_entry())
        self.var_hex_tx = tk.BooleanVar(value=False)
        ttk.Checkbutton(tx_frame, text="HEX", variable=self.var_hex_tx).pack(side="left", padx=4)
        self.btn_send = ttk.Button(tx_frame, text="发送", width=10,
                                   command=self._send_from_entry, state="disabled")
        self.btn_send.pack(side="left", padx=6)

        # ---- 状态栏 ----
        st = ttk.Frame(self)
        st.pack(fill="x", padx=8, pady=(2, 8))
        self.lbl_status = ttk.Label(st, text="状态: 串口未打开", font=("Microsoft YaHei", 9))
        self.lbl_status.pack(side="left")
        self.lbl_stat   = ttk.Label(st, text="RX: 0 字节   TX: 0 字节",
                                    font=("Microsoft YaHei", 9))
        self.lbl_stat.pack(side="right")

    #-------------------------------------------------------------------------
    # 串口操作
    #-------------------------------------------------------------------------
    def refresh_ports(self):
        ports = serial.tools.list_ports.comports()
        self.cmb_port["values"] = []
        items, guess = [], None
        for p in ports:
            desc = (p.description or "") + " " + (p.manufacturer or "")
            tag  = " ← USB-TTL 转接器" if ("Prolific" in desc or "CH340" in desc
                                           or "CP210" in desc or "FT232" in desc) else ""
            items.append(f"{p.device}  ({p.description[:36]}){tag}")
            if tag and guess is None:
                guess = items[-1]
        self.cmb_port["values"] = items
        if guess:
            self.cmb_port.set(guess)
        elif items:
            self.cmb_port.set(items[0])
        else:
            self.cmb_port.set("")
            messagebox.showwarning("未检测到串口", "没有找到任何串口设备。\n"
                                   "请确认 USB-TTL 转接器已插入电脑 USB 口。")

    def _parity(self):
        return {"奇校验(ODD)":  serial.PARITY_ODD,
                "无校验(NONE)": serial.PARITY_NONE,
                "偶校验(EVEN)": serial.PARITY_EVEN}[self.cmb_par.get()]

    def toggle_open(self):
        if self.ser is None:
            self._open()
        else:
            self._close()

    def _open(self):
        port = self.cmb_port.get().split(" ")[0]
        if not port:
            messagebox.showwarning("提示", "请先选择串口")
            return
        try:
            self.ser = serial.Serial(
                port=port,
                baudrate=int(self.cmb_baud.get()),
                bytesize=serial.EIGHTBITS,
                parity=self._parity(),
                stopbits=1,
                timeout=0.1)
        except Exception as e:
            messagebox.showerror("打开失败", f"无法打开 {port}:\n{e}")
            self.ser = None
            return
        self.rx_count = self.tx_count = 0
        self.t_connect = time.time()
        self.btn_open.configure(text="关闭串口")
        self.btn_send.configure(state="normal")
        for b in self.quick_btns:
            b.configure(state="normal")
        self.lbl_status.configure(
            text=f"状态: 已连接 {port} @ {self.cmb_baud.get()} "
                 f"8{ {'奇校验(ODD)':'O','无校验(NONE)':'N','偶校验(EVEN)':'E'}[self.cmb_par.get()] }1")
        self._log_rx(f"—— {TS()}  串口已打开: {port} "
                     f"({self.cmb_baud.get()}-8-{self.cmb_par.get()}-1) ——")
        self.rx_thread = threading.Thread(target=self._rx_loop, daemon=True)
        self.rx_thread.start()

    def _close(self):
        if self.ser:
            self.ser.close()
            self.ser = None
        self.btn_open.configure(text="打开串口")
        self.btn_send.configure(state="disabled")
        for b in self.quick_btns:
            b.configure(state="disabled")
        dur = ""
        if self.t_connect:
            dur = f", 连接时长 {time.time()-self.t_connect:.0f} 秒"
        self.lbl_status.configure(text="状态: 串口未打开")
        self._log_rx(f"—— {TS()}  串口已关闭{dur} ——")

    def _rx_loop(self):
        """接收线程: 读串口 -> 入队"""
        while self.ser and self.ser.is_open and not self.closing:
            try:
                n = self.ser.in_waiting
                data = self.ser.read(n if n > 0 else 1)
                if data:
                    self.rx_count += len(data)
                    self.rx_queue.put(data)
            except Exception:
                break

    def _poll_rx(self):
        """UI 线程: 从队列取数据并显示"""
        try:
            while True:
                data = self.rx_queue.get_nowait()
                if self.var_hex_rx.get():
                    txt = " ".join(f"{b:02X}" for b in data)
                elif self.var_garb.get():
                    # 只显示可打印 ASCII(含回车/换行/制表), 其余一律显示为 FF
                    parts = []
                    for b in data:
                        if b in (0x0A, 0x0D, 0x09) or 0x20 <= b <= 0x7E:
                            parts.append(chr(b))
                        else:
                            parts.append("FF")
                    txt = "".join(parts)
                else:
                    txt = data.decode("ascii", errors="replace")
                self._log_rx((f"[{TS()}] " if self.var_ts.get() else "") + txt)
                self.lbl_stat.configure(
                    text=f"RX: {self.rx_count} 字节   TX: {self.tx_count} 字节"
                         + (f"   时长 {time.time()-self.t_connect:.0f}s"
                            if self.t_connect else ""))
        except queue.Empty:
            pass
        self.after(80, self._poll_rx)

    #-------------------------------------------------------------------------
    # 发送
    #-------------------------------------------------------------------------
    def _send_from_entry(self):
        s = self.ent_tx.get().strip()
        if not s:
            return
        try:
            data = bytes.fromhex(s.replace(" ", "")) if self.var_hex_tx.get() \
                   else s.encode("ascii", errors="replace")
        except ValueError:
            messagebox.showerror("格式错误", "HEX 发送格式应为 2 位十六进制, 如: 54 77 69 6E")
            return
        self.send_data(data)
        self.ent_tx.delete(0, tk.END)

    def send_data(self, data: bytes):
        if self.ser is None or not self.ser.is_open:
            messagebox.showwarning("提示", "请先打开串口")
            return
        try:
            self.ser.write(data)
            self.tx_count += len(data)
            self._log_rx(f"[{TS()}] TX → {' '.join(chr(b) if 32<=b<127 else f'{b:02X}' for b in data)}")
            self.lbl_stat.configure(text=f"RX: {self.rx_count} 字节   TX: {self.tx_count} 字节"
                                         + (f"   时长 {time.time()-self.t_connect:.0f}s"
                                            if self.t_connect else ""))
        except Exception as e:
            messagebox.showerror("发送失败", str(e))

    #-------------------------------------------------------------------------
    # 接收区辅助
    #-------------------------------------------------------------------------
    def _log_rx(self, s):
        self.txt_rx.configure(state="normal")
        self.txt_rx.insert(tk.END, s + "\n")
        self.txt_rx.see(tk.END)
        self.txt_rx.configure(state="disabled")

    def _clear_rx(self):
        self.txt_rx.configure(state="normal")
        self.txt_rx.delete("1.0", tk.END)
        self.txt_rx.configure(state="disabled")

    def _save_log(self):
        fn = filedialog.asksaveasfilename(defaultextension=".txt",
            initialfile=f"uart_log_{datetime.datetime.now():%Y%m%d_%H%M%S}.txt",
            filetypes=[("文本文件", "*.txt")])
        if fn:
            with open(fn, "w", encoding="utf-8") as f:
                f.write(self.txt_rx.get("1.0", tk.END))
            messagebox.showinfo("已保存", f"日志已保存到:\n{fn}")

    #-------------------------------------------------------------------------
    def on_close(self):
        self.closing = True
        if self.ser and self.ser.is_open:
            self.ser.close()
        self.destroy()

#-----------------------------------------------------------------------------
if __name__ == "__main__":
    app = UartMonitor()
    app.protocol("WM_DELETE_WINDOW", app.on_close)
    app.mainloop()
