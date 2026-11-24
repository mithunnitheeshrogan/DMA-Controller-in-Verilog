`timescale 1ns/1ps
//==============================================================================
// Self-checking testbench for dma_controller
//  - behavioural bus arbiter with programmable grant latency + "steal" mode
//  - protocol checker (m_re/m_we only while granted)
//  - guard-word checks (nothing written outside dst range, src untouched)
//==============================================================================
module tb_dma;
    localparam ADDR_W = 8, DATA_W = 32, LEN_W = 8;

    reg         clk = 0, rst_n = 0;
    reg         reg_we = 0;
    reg  [1:0]  reg_addr = 0;
    reg  [31:0] reg_wdata = 0;
    wire [31:0] reg_rdata;

    wire              bus_req;
    reg               bus_gnt;
    wire [ADDR_W-1:0] m_addr;
    wire [DATA_W-1:0] m_wdata, m_rdata;
    wire              m_we, m_re, irq;

    always #5 clk = ~clk;   // 100 MHz

    // ---------------- DUT + memory ----------------
    dma_controller #(ADDR_W, DATA_W, LEN_W) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .bus_req(bus_req), .bus_gnt(bus_gnt),
        .m_addr(m_addr), .m_wdata(m_wdata), .m_we(m_we), .m_re(m_re), .m_rdata(m_rdata),
        .irq(irq)
    );

    memory #(ADDR_W, DATA_W) mem0 (
        .clk(clk), .we(m_we), .re(m_re), .addr(m_addr), .wdata(m_wdata), .rdata(m_rdata)
    );

    // ---------------- Bus arbiter model ----------------
    integer gnt_latency = 2;   // cycles between req and gnt
    reg     steal_en    = 0;   // take bus away after every 3rd write
    integer wait_cnt    = 0;
    integer wr_cnt      = 0;
    integer steal_events = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_gnt <= 0; wait_cnt <= 0; wr_cnt <= 0;
        end else begin
            if (!bus_req) begin
                bus_gnt <= 0; wait_cnt <= 0;
            end else if (!bus_gnt) begin
                if (wait_cnt >= gnt_latency) begin
                    bus_gnt <= 1; wait_cnt <= 0;
                end else
                    wait_cnt <= wait_cnt + 1;
            end else if (steal_en && m_we) begin
                wr_cnt <= wr_cnt + 1;
                if (wr_cnt % 3 == 2) begin
                    bus_gnt <= 0;
                    steal_events <= steal_events + 1;
                end
            end
        end
    end

    // ---------------- Protocol checker ----------------
    integer errors = 0;
    always @(posedge clk) begin
        if ((m_we || m_re) && !bus_gnt) begin
            $display("[%0t] ERROR: bus access without grant", $time);
            errors = errors + 1;
        end
    end

    // ---------------- Helper tasks ----------------
    task reg_write(input [1:0] a, input [31:0] d);
        begin
            @(posedge clk);
            reg_we <= 1; reg_addr <= a; reg_wdata <= d;
            @(posedge clk);
            reg_we <= 0;
        end
    endtask

    task reg_read(input [1:0] a, output [31:0] d);
        begin
            reg_addr <= a;
            @(posedge clk); #1;
            d = reg_rdata;
        end
    endtask

    task init_mem;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                mem0.mem[i] = 32'hDEAD0000 + i;   // background pattern
        end
    endtask

    task fill_src(input integer base, input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                mem0.mem[base+i] = 32'hC0DE0000 + (i*7) + base;
        end
    endtask

    task program_dma(input integer src, input integer dst, input integer len, input irq_en);
        begin
            reg_write(2'd0, src);
            reg_write(2'd1, dst);
            reg_write(2'd2, len);
            reg_write(2'd3, {29'b0, irq_en, 1'b0, 1'b1});   // START (+IRQ_EN)
        end
    endtask

    task wait_done(output integer cycles);
        reg [31:0] st;
        integer n;
        begin
            n = 0; st = 0;
            while (!st[1] && n < 5000) begin
                reg_read(2'd3, st);
                n = n + 1;
            end
            cycles = n;
            if (n >= 5000) begin
                $display("ERROR: timeout waiting for DONE");
                errors = errors + 1;
            end
        end
    endtask

    // Verify copy + guards
    task check_copy(input integer src, input integer dst, input integer len, input [8*40-1:0] name);
        integer i, local_err;
        reg [31:0] exp_data;
        begin
            local_err = 0;
            for (i = 0; i < len; i = i + 1) begin
                exp_data = 32'hC0DE0000 + (i*7) + src;
                if (mem0.mem[dst+i] !== exp_data) begin
                    $display("  MISMATCH dst[%0d]=%h expected %h", dst+i, mem0.mem[dst+i], exp_data);
                    local_err = local_err + 1;
                end
                if (mem0.mem[src+i] !== exp_data) begin
                    $display("  SOURCE CORRUPTED at %0d", src+i);
                    local_err = local_err + 1;
                end
            end
            // guard words either side of destination
            if (dst > 0 && mem0.mem[dst-1] !== (32'hDEAD0000 + dst - 1)) begin
                $display("  GUARD BEFORE dst overwritten"); local_err = local_err + 1;
            end
            if (dst+len < 256 && mem0.mem[dst+len] !== (32'hDEAD0000 + dst + len)) begin
                $display("  GUARD AFTER dst overwritten"); local_err = local_err + 1;
            end
            if (local_err == 0) $display("PASS : %0s", name);
            else begin $display("FAIL : %0s (%0d errors)", name, local_err); errors = errors + local_err; end
        end
    endtask

    // ---------------- Tests ----------------
    reg finished = 0;
    integer cyc;
    reg [31:0] st;
    integer req_seen;

    initial begin
        $display("==== DMA controller testbench ====");
        init_mem;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- T1: basic 16-word copy ----
        gnt_latency = 2; steal_en = 0;
        fill_src(16, 16);
        program_dma(16, 128, 16, 0);
        wait_done(cyc);
        check_copy(16, 128, 16, "T1 basic 16-word copy");
        $display("      (status polls: %0d)", cyc);
        reg_write(2'd3, 32'h2);                        // clear done

        // ---- T2: single word ----
        init_mem; fill_src(40, 1);
        program_dma(40, 200, 1, 0);
        wait_done(cyc);
        check_copy(40, 200, 1, "T2 single-word copy");
        reg_write(2'd3, 32'h2);

        // ---- T3: LEN = 0 -> error, no bus request ----
        req_seen = 0;
        fork
            begin : mon
                repeat (30) begin @(posedge clk); if (bus_req) req_seen = 1; end
            end
            begin
                program_dma(8, 100, 0, 0);
                repeat (5) @(posedge clk);
                reg_read(2'd3, st);
                if (st[2] && !st[0] && !st[1]) $display("PASS : T3 zero-length -> ERROR flag");
                else begin $display("FAIL : T3 status=%b", st[3:0]); errors = errors + 1; end
            end
        join
        if (req_seen) begin $display("FAIL : T3 bus requested for zero length"); errors = errors + 1; end
        reg_write(2'd3, 32'h2);

        // ---- T4: 64 words, zero-latency grant ----
        init_mem; gnt_latency = 0;
        fill_src(0, 64);
        program_dma(0, 100, 64, 0);
        wait_done(cyc);
        check_copy(0, 100, 64, "T4 64-word copy, fast grant");
        reg_write(2'd3, 32'h2);

        // ---- T5: slow grant + bus stolen every 3 writes ----
        init_mem; gnt_latency = 6; steal_en = 1; wr_cnt = 0; steal_events = 0;
        fill_src(20, 32);
        program_dma(20, 150, 32, 0);
        wait_done(cyc);
        check_copy(20, 150, 32, "T5 slow grant + bus steal/regrant");
        $display("      (bus stolen %0d times)", steal_events);
        if (steal_events == 0) begin $display("FAIL : T5 steal never exercised"); errors = errors + 1; end
        steal_en = 0;
        reg_write(2'd3, 32'h2);

        // ---- T6: START / register writes while busy are ignored ----
        init_mem; gnt_latency = 1;
        fill_src(30, 20);
        program_dma(30, 120, 20, 0);
        repeat (10) @(posedge clk);
        reg_write(2'd0, 8'd0);            // try to change SRC while busy
        reg_write(2'd1, 8'd200);          // try to change DST while busy
        reg_write(2'd3, 32'h1);           // try a second START
        wait_done(cyc);
        check_copy(30, 120, 20, "T6 writes/start ignored while busy");
        reg_write(2'd3, 32'h2);

        // ---- T7: back-to-back transfers ----
        init_mem; gnt_latency = 2;
        fill_src(10, 8);
        program_dma(10, 60, 8, 0);
        wait_done(cyc);
        reg_write(2'd3, 32'h2);
        // second transfer: copy the copy
        for (cyc = 0; cyc < 8; cyc = cyc + 1) mem0.mem[100+cyc] = mem0.mem[60+cyc];
        program_dma(60, 180, 8, 0);
        wait_done(cyc);
        begin : t7chk
            integer k, e; e = 0;
            for (k = 0; k < 8; k = k + 1)
                if (mem0.mem[180+k] !== (32'hC0DE0000 + k*7 + 10)) e = e + 1;
            if (e == 0) $display("PASS : T7 back-to-back transfers");
            else begin $display("FAIL : T7"); errors = errors + e; end
        end
        reg_write(2'd3, 32'h2);

        // ---- T8: interrupt behaviour ----
        init_mem; fill_src(50, 4);
        program_dma(50, 90, 4, 1);               // IRQ_EN=1
        if (irq) begin $display("FAIL : T8 irq asserted too early"); errors = errors + 1; end
        wait_done(cyc);
        @(posedge clk); #1;
        if (irq) $display("PASS : T8 irq asserted on completion");
        else begin $display("FAIL : T8 irq not asserted"); errors = errors + 1; end
        reg_write(2'd3, 32'h6);                  // CLR + keep IRQ_EN
        @(posedge clk); #1;
        if (!irq) $display("PASS : T8 irq cleared by CLR");
        else begin $display("FAIL : T8 irq stuck"); errors = errors + 1; end

        // ---- Summary ----
        repeat (5) @(posedge clk);
        if (errors == 0) $display("==== ALL TESTS PASSED ====");
        else             $display("==== %0d ERROR(S) ====", errors);
        finished = 1;
        $stop;
    end

    // global watchdog
    initial begin
        #2_000_000;
        if (!finished) begin
            $display("WATCHDOG TIMEOUT");
            $stop;
        end
    end
endmodule
