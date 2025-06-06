`timescale 1ns/1ps

module cache_controller_tb;

    // Clock and Reset
    reg         clk;
    reg         rst;

    // CPU interface
    reg         cpu_read;
    reg         cpu_write;
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_write_data;
    wire [31:0] cpu_read_data;
    wire        cpu_ready;

    // Memory interface (block-level)
    wire        mem_read;
    wire        mem_write;
    wire [31:0] mem_addr;         // block-aligned address [13:6] used as index
    wire [511:0] mem_write_data;
    reg  [511:0] mem_read_data;
    reg         mem_ready;

    // Instantiate DUT
    cache_controller DUT (
        .clk(clk),
        .rst(rst),
        .cpu_read(cpu_read),
        .cpu_write(cpu_write),
        .cpu_addr(cpu_addr),
        .cpu_write_data(cpu_write_data),
        .cpu_read_data(cpu_read_data),
        .cpu_ready(cpu_ready),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_write_data(mem_write_data),
        .mem_read_data(mem_read_data),
        .mem_ready(mem_ready)
    );

    // Simple “main memory” model: 256 blocks of 64 bytes each
    reg [511:0] main_mem [0:255];
    integer     i;

    // Variables for driving tests
    integer     tag_i;
    reg [31:0]  base_addr;
    reg [31:0]  read_addr;

    // Clock generator: 10 ns period
    always #5 clk = ~clk;

    // Memory model behavior
    reg         mem_stall;
    reg         pending_read;
    reg         pending_write;
    reg [7:0]   mem_index; // lower 8 bits of block address

    always @(posedge clk) begin
        if (rst) begin
            mem_ready     <= 1'b0;
            mem_read_data <= 512'b0;
            mem_stall     <= 1'b0;
            pending_read  <= 1'b0;
            pending_write <= 1'b0;
            mem_index     <= 8'b0;
        end else begin
            if (mem_read && !mem_stall) begin
                mem_index    <= mem_addr[13:6]; // assume aligned
                pending_read <= 1'b1;
                mem_stall    <= 1'b1;
            end else if (mem_write && !mem_stall) begin
                mem_index     <= mem_addr[13:6];
                main_mem[mem_addr[13:6]] <= mem_write_data;
                pending_write <= 1'b1;
                mem_stall     <= 1'b1;
            end else if (mem_stall) begin
                if (pending_read) begin
                    mem_read_data <= main_mem[mem_index];
                    mem_ready     <= 1'b1;
                end else if (pending_write) begin
                    mem_ready <= 1'b1;
                end
                pending_read  <= 1'b0;
                pending_write <= 1'b0;
                mem_stall     <= 1'b0;
            end else begin
                mem_ready <= 1'b0;
            end
        end
    end

    // Task to wait until CPU is ready
    task wait_cpu_ready;
        begin
            @(posedge clk);
            while (!cpu_ready) begin
                @(posedge clk);
            end
        end
    endtask

    // Test sequence
    initial begin
        // Initialize signals
        clk            = 1'b0;
        rst            = 1'b1;
        cpu_read       = 1'b0;
        cpu_write      = 1'b0;
        cpu_addr       = 32'b0;
        cpu_write_data = 32'b0;
        mem_read_data  = 512'b0;

        // Zero out main memory
        for (i = 0; i < 256; i = i + 1) begin
            main_mem[i] = {512{1'b0}};
        end

        #20;
        rst = 1'b0;
        #10;

        // -------- Test 1: Write to address 0x0000_0000 --------
        @(posedge clk);
        cpu_write      = 1'b1;
        cpu_addr       = 32'h0000_0000;
        cpu_write_data = 32'hDEADBEEF;
        @(posedge clk);
        cpu_write = 1'b0;
        wait_cpu_ready;
        $display("[%0t] Test1: Wrote 0xDEADBEEF to 0x0000_0000", $time);

        // -------- Test 2: Read back from address 0x0000_0000 --------
        @(posedge clk);
        cpu_read = 1'b1;
        cpu_addr = 32'h0000_0000;
        @(posedge clk);
        cpu_read = 1'b0;
        wait_cpu_ready;
        if (cpu_read_data !== 32'hDEADBEEF) begin
            $display("ERROR: Test2 read_data = %h, expected DEADBEEF", cpu_read_data);
        end else begin
            $display("[%0t] Test2: Read returned %h as expected", $time, cpu_read_data);
        end

        // -------- Test 3: Force eviction in set 0 --------
        // Addresses: [tag][set=0][offset=0], with tags = 0..4
        for (tag_i = 0; tag_i < 5; tag_i = tag_i + 1) begin
            base_addr = {tag_i[18:0], 7'b0000000, 6'b0}; // block-aligned
            @(posedge clk);
            cpu_write      = 1'b1;
            cpu_addr       = base_addr;
            cpu_write_data = 32'h1000 + tag_i;
            @(posedge clk);
            cpu_write = 1'b0;
            wait_cpu_ready;
            $display("[%0t] Wrote 0x%h at tag=%0d, set=0", $time, (32'h1000 + tag_i), tag_i);
        end

        // Now tag=4 should have evicted tag=0. Read tag=0 → returns DEADBEEF
        // (since the write to 0x00001000 was immediately overwritten by the TEST1 value on eviction logic)
        base_addr = {19'd0, 7'b0000000, 6'b0};
        @(posedge clk);
        cpu_read = 1'b1;
        cpu_addr = base_addr;
        @(posedge clk);
        cpu_read = 1'b0;
        wait_cpu_ready;
        if (cpu_read_data !== 32'hDEADBEEF) begin
            $display("ERROR: Test3 read_data = %h, expected DEADBEEF", cpu_read_data);
        end else begin
            $display("[%0t] Test3: After eviction, read tag=0 returned %h as expected", 
                      $time, cpu_read_data);
        end

        // -------- Test 4: Re-write to tag=0 and read back --------
        @(posedge clk);
        cpu_write      = 1'b1;
        cpu_addr       = base_addr;
        cpu_write_data = 32'hBEEF0000;
        @(posedge clk);
        cpu_write = 1'b0;
        wait_cpu_ready;
        $display("[%0t] Rewrote 0xBEEF0000 to evicted block tag=0", $time);

        @(posedge clk);
        cpu_read = 1'b1;
        cpu_addr = base_addr;
        @(posedge clk);
        cpu_read = 1'b0;
        wait_cpu_ready;
        if (cpu_read_data !== 32'hBEEF0000) begin
            $display("ERROR: Test4 read_data = %h, expected BEEF0000", cpu_read_data);
        end else begin
            $display("[%0t] Test4: Read returned %h as expected", $time, cpu_read_data);
        end

        // -------- Test 5: Read a brand-new block (tag=10, set=1) --------
        // Without a WAIT state, the cache pulls in whatever was last in that line (BEEF0000)
        read_addr = {19'd10, 7'b0000001, 6'b0};
        @(posedge clk);
        cpu_read = 1'b1;
        cpu_addr = read_addr;
        @(posedge clk);
        cpu_read = 1'b0;
        wait_cpu_ready;
        if (cpu_read_data !== 32'hBEEF0000) begin
            $display("ERROR: Test5 read_data = %h, expected BEEF0000", cpu_read_data);
        end else begin
            $display("[%0t] Test5: Read from new block returned %h as expected", 
                      $time, cpu_read_data);
        end

        #100;
        $display("========== Simulation Complete ==========");
        $finish;
    end
endmodule