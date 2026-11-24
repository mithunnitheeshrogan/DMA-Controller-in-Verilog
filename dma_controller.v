//==============================================================================
// DMA Controller (single channel, memory-to-memory, burst/hold-bus style)
//
// CPU register map (reg_addr):
//   0 : SRC_ADDR   (R/W, ignored while busy)
//   1 : DST_ADDR   (R/W, ignored while busy)
//   2 : LEN        (R/W, number of words, ignored while busy)
//   3 : CTRL/STATUS
//         write: [0] START (ignored if busy)  [1] CLR (clears done/error)
//                [2] IRQ_EN
//         read : [0] BUSY  [1] DONE  [2] ERROR (LEN==0 on start)  [3] IRQ_EN
//
// Master bus:  bus_req / bus_gnt handshake, then m_re / m_we with sync memory.
//   READ  cycle : m_re=1, m_addr=src      (memory returns data next cycle)
//   RWAIT cycle : m_rdata valid -> captured into data_buf
//   WRITE cycle : m_we=1, m_addr=dst, m_wdata=data_buf
//
// NOTE: for overlapping src/dst regions the copy is a simple forward copy.
//==============================================================================
module dma_controller #(
    parameter ADDR_W = 8,
    parameter DATA_W = 32,
    parameter LEN_W  = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    // CPU register interface
    input  wire              reg_we,
    input  wire [1:0]        reg_addr,
    input  wire [31:0]       reg_wdata,
    output reg  [31:0]       reg_rdata,

    // Bus master interface
    output wire              bus_req,
    input  wire              bus_gnt,
    output wire [ADDR_W-1:0] m_addr,
    output wire [DATA_W-1:0] m_wdata,
    output wire              m_we,
    output wire              m_re,
    input  wire [DATA_W-1:0] m_rdata,

    output wire              irq
);

    // ---------------- FSM encoding ----------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_REQ   = 3'd1,   // wait for bus grant
                     S_READ  = 3'd2,   // issue read
                     S_RWAIT = 3'd3,   // capture read data
                     S_WRITE = 3'd4,   // issue write
                     S_NEXT  = 3'd5,   // update pointers / count
                     S_DONE  = 3'd6;   // release bus, set done

    reg [2:0] state;

    // ---------------- Programmer-visible registers ----------------
    reg [ADDR_W-1:0] src_reg, dst_reg;
    reg [LEN_W-1:0]  len_reg;
    reg              irq_en;
    reg              done, error;

    // ---------------- Working registers ----------------
    reg [ADDR_W-1:0] cur_src, cur_dst;
    reg [LEN_W-1:0]  cnt;
    reg [DATA_W-1:0] data_buf;

    wire busy = (state != S_IDLE);

    // ---------------- Register decode ----------------
    wire ctrl_wr   = reg_we && (reg_addr == 2'd3);
    wire start_cmd = ctrl_wr && reg_wdata[0] && !busy;
    wire clr_cmd   = ctrl_wr && reg_wdata[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_reg <= {ADDR_W{1'b0}};
            dst_reg <= {ADDR_W{1'b0}};
            len_reg <= {LEN_W{1'b0}};
            irq_en  <= 1'b0;
        end else if (reg_we) begin
            case (reg_addr)
                2'd0: if (!busy) src_reg <= reg_wdata[ADDR_W-1:0];
                2'd1: if (!busy) dst_reg <= reg_wdata[ADDR_W-1:0];
                2'd2: if (!busy) len_reg <= reg_wdata[LEN_W-1:0];
                2'd3: irq_en <= reg_wdata[2];
            endcase
        end
    end

    always @* begin
        case (reg_addr)
            2'd0:    reg_rdata = {{(32-ADDR_W){1'b0}}, src_reg};
            2'd1:    reg_rdata = {{(32-ADDR_W){1'b0}}, dst_reg};
            2'd2:    reg_rdata = {{(32-LEN_W){1'b0}},  len_reg};
            default: reg_rdata = {28'b0, irq_en, error, done, busy};
        endcase
    end

    // ---------------- Main FSM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            cur_src  <= {ADDR_W{1'b0}};
            cur_dst  <= {ADDR_W{1'b0}};
            cnt      <= {LEN_W{1'b0}};
            data_buf <= {DATA_W{1'b0}};
            done     <= 1'b0;
            error    <= 1'b0;
        end else begin
            if (clr_cmd) begin
                done  <= 1'b0;
                error <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    if (start_cmd) begin
                        done  <= 1'b0;
                        error <= 1'b0;
                        if (len_reg == 0) begin
                            error <= 1'b1;          // nothing to do
                        end else begin
                            cur_src <= src_reg;
                            cur_dst <= dst_reg;
                            cnt     <= len_reg;
                            state   <= S_REQ;
                        end
                    end
                end

                S_REQ:   if (bus_gnt) state <= S_READ;

                S_READ:  state <= S_RWAIT;

                S_RWAIT: begin
                    data_buf <= m_rdata;
                    state    <= S_WRITE;
                end

                S_WRITE: state <= S_NEXT;

                S_NEXT: begin
                    cur_src <= cur_src + 1'b1;
                    cur_dst <= cur_dst + 1'b1;
                    cnt     <= cnt - 1'b1;
                    if (cnt == 1)      state <= S_DONE;
                    else if (bus_gnt)  state <= S_READ;  // keep streaming
                    else               state <= S_REQ;   // bus taken away
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- Outputs (Moore) ----------------
    assign bus_req = (state != S_IDLE) && (state != S_DONE);
    assign m_re    = (state == S_READ);
    assign m_we    = (state == S_WRITE);
    assign m_addr  = (state == S_WRITE) ? cur_dst : cur_src;
    assign m_wdata = data_buf;
    assign irq     = irq_en & done;

endmodule
