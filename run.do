# ModelSim run script:  vsim -do run.do   (or:  do run.do  from the transcript)
quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vlog -work work memory.v dma_controller.v tb_dma.v
vsim -voptargs=+acc work.tb_dma

add wave -divider {Clock/Reset}
add wave /tb_dma/clk /tb_dma/rst_n
add wave -divider {CPU regs}
add wave /tb_dma/reg_we /tb_dma/reg_addr /tb_dma/reg_wdata /tb_dma/irq
add wave -divider {Bus handshake}
add wave /tb_dma/bus_req /tb_dma/bus_gnt
add wave -divider {Bus master}
add wave -radix unsigned /tb_dma/m_addr
add wave /tb_dma/m_re /tb_dma/m_we
add wave -radix hex /tb_dma/m_wdata /tb_dma/m_rdata
add wave -divider {DMA internals}
add wave -radix unsigned /tb_dma/dut/state /tb_dma/dut/cnt /tb_dma/dut/cur_src /tb_dma/dut/cur_dst
add wave -radix hex /tb_dma/dut/data_buf

run -all
wave zoom full
