// Simple synchronous memory: write on clk, registered (1-cycle) read
module memory #(
    parameter ADDR_W = 8,
    parameter DATA_W = 32
)(
    input  wire              clk,
    input  wire              we,
    input  wire              re,
    input  wire [ADDR_W-1:0] addr,
    input  wire [DATA_W-1:0] wdata,
    output reg  [DATA_W-1:0] rdata
);
    reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

    always @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        if (re) rdata     <= mem[addr];
    end
endmodule
