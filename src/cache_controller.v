`timescale 1ns/1ps

module cache_controller (
    input  wire         clk,
    input  wire         rst,

    // interfata CPU
    input  wire         cpu_read,
    input  wire         cpu_write,
    input  wire [31:0]  cpu_addr,           
    input  wire [31:0]  cpu_write_data,
    output reg  [31:0]  cpu_read_data,       
    output reg          cpu_ready,           

    // interfata memorie (transferuri la nivel de bloc)
    output reg          mem_read,
    output reg          mem_write,
    output reg  [31:0]  mem_addr,
    output reg  [511:0] mem_write_data,
    input  wire [511:0] mem_read_data,
    input  wire         mem_ready
    );

    // parametri locali
    localparam TAG_WIDTH         = 19;
    localparam INDEX_WIDTH       = 7;
    localparam WORD_OFFSET_WIDTH = 4;

    // codificarea starilor FSM (4 biti)
    localparam [3:0]
        STATE_IDLE           = 4'd0,
        STATE_TAG_CHECK      = 4'd1,
        STATE_READ_HIT       = 4'd2,
        STATE_READ_MISS      = 4'd3,
        STATE_WRITE_HIT      = 4'd4,
        STATE_WRITE_MISS     = 4'd5,
        STATE_WRITEBACK      = 4'd6,
        STATE_READ_ALLOC     = 4'd7,
        STATE_READ_ALLOC_WAIT= 4'd8,
        STATE_READ_ALLOC2    = 4'd9,
        STATE_WRITE_ALLOC    = 4'd10,
        STATE_WRITE_ALLOC_WAIT=4'd11,
        STATE_WRITE_ALLOC2   = 4'd12;

    reg [3:0] state;

    // registre pentru stocarea informatiilor
    reg [31:0] req_addr;
    reg [31:0] req_write_data;
    reg        is_write;

    // semnale pentru cache arraz
    reg         ca_read_enable;
    reg         ca_write_enable;
    wire [31:0] ca_read_data;
    wire        ca_hit;
    wire        ca_evict_dirty;
    wire [18:0] ca_evict_tag;
    wire [6:0]  ca_evict_set;
    wire [1:0]  ca_evict_way;
    wire [511:0]ca_evict_data_block;
    reg         ca_alloc_enable;
    reg [31:0]  ca_alloc_addr;
    reg [511:0] ca_alloc_data_block;

    // instantiere cache_array
    cache_array ca (
        .clk(clk),
        .rst(rst),
        .read_enable(ca_read_enable),
        .write_enable(ca_write_enable),
        .addr(req_addr),
        .write_data(req_write_data),
        .read_data(ca_read_data),
        .hit(ca_hit),
        .evict_dirty(ca_evict_dirty),
        .evict_tag(ca_evict_tag),
        .evict_set(ca_evict_set),
        .evict_way(ca_evict_way),
        .evict_data_block(ca_evict_data_block),
        .alloc_enable(ca_alloc_enable),
        .alloc_addr(ca_alloc_addr),
        .alloc_data_block(ca_alloc_data_block)
    );

    wire [TAG_WIDTH-1:0]        req_tag;
    wire [INDEX_WIDTH-1:0]      req_set;
    wire [WORD_OFFSET_WIDTH-1:0] req_word_offset;

    assign req_tag         = req_addr[31:13];
    assign req_set         = req_addr[12:6];
    assign req_word_offset = req_addr[5:2];

    // logica secventiala FSM
    always @(posedge clk) begin
        if (rst) begin
            state            <= STATE_IDLE;
            cpu_ready        <= 1'b0;
            ca_read_enable   <= 1'b0;
            ca_write_enable  <= 1'b0;
            ca_alloc_enable  <= 1'b0;
            mem_read         <= 1'b0;
            mem_write        <= 1'b0;
            mem_addr         <= 32'b0;
            mem_write_data   <= {512{1'b0}};
        end else begin
            cpu_ready        <= 1'b0;
            ca_read_enable   <= 1'b0;
            ca_write_enable  <= 1'b0;
            ca_alloc_enable  <= 1'b0;
            mem_read         <= 1'b0;
            mem_write        <= 1'b0;

            case (state)
                 
                STATE_IDLE: begin
                    if (cpu_read || cpu_write) begin
                        // retine cererea venita de la CPU
                        req_addr       <= cpu_addr;
                        req_write_data <= cpu_write_data;
                        is_write       <= cpu_write;
                        state          <= STATE_TAG_CHECK;
                    end
                end

                 
                STATE_TAG_CHECK: begin
                    // activeaza cache_array pentru verificare hit/miss
                    ca_read_enable  <= ~is_write;
                    ca_write_enable <=  is_write;

                    if (ca_hit) begin
                        // cale hit
                        if (is_write) begin
                            state <= STATE_WRITE_HIT;
                        end else begin
                            state <= STATE_READ_HIT;
                        end
                    end else begin
                        // cale miss
                        if (is_write) begin
                            state <= STATE_WRITE_MISS;
                        end else begin
                            state <= STATE_READ_MISS;
                        end
                    end
                end

                 
                STATE_READ_HIT: begin
                    // returneaza date imediat
                    cpu_read_data <= ca_read_data;
                    cpu_ready     <= 1'b1;
                    state         <= STATE_IDLE;
                end

                 
                STATE_WRITE_HIT: begin
                    // cache_array a scris deja datele si a setat dirty
                    cpu_ready <= 1'b1;
                    state     <= STATE_IDLE;
                end

                 
                STATE_READ_MISS: begin
                    // la read miss, verifica daca este necesara eviction (dirty)
                    if (ca_evict_dirty) begin
                        // efectueaza write-back mai intai
                        mem_write      <= 1'b1;
                        mem_addr       <= {ca_evict_tag, ca_evict_set, {6{1'b0}}};
                        mem_write_data <= ca_evict_data_block;
                        state          <= STATE_WRITEBACK;
                    end else begin
                        // citeste direct din memorie
                        mem_read <= 1'b1;
                        mem_addr <= {req_tag, req_set, {6{1'b0}}};
                        state    <= STATE_READ_ALLOC;
                    end
                end

                 
                STATE_WRITE_MISS: begin
                    // la write miss (write-allocate), trateaza la fel ca read miss
                    if (ca_evict_dirty) begin
                        // scrie mai intai blocul dirty
                        mem_write      <= 1'b1;
                        mem_addr       <= {ca_evict_tag, ca_evict_set, {6{1'b0}}};
                        mem_write_data <= ca_evict_data_block;
                        state          <= STATE_WRITEBACK;
                    end else begin
                        // citeste blocul din memorie
                        mem_read <= 1'b1;
                        mem_addr <= {req_tag, req_set, {6{1'b0}}};
                        state    <= STATE_WRITE_ALLOC;
                    end
                end
                 
                STATE_WRITEBACK: begin
                    if (mem_ready) begin
                        // dupa write-back, citeste noul bloc
                        mem_read <= 1'b1;
                        mem_addr <= {req_tag, req_set, {6{1'b0}}};
                        // in functie de cererea originala, mergi la starea de alocare corespunzatoare
                        if (is_write)
                            state <= STATE_WRITE_ALLOC;
                        else
                            state <= STATE_READ_ALLOC;
                    end
                end
                 
                STATE_READ_ALLOC: begin
                    // asteptare finalizare citire memorie
                    if (mem_ready) begin
                        // incarca blocul citit in cache la urmatorul ciclu de ceas
                        ca_alloc_enable      <= 1'b1;
                        ca_alloc_addr        <= {req_tag, req_set, {6{1'b0}}};
                        ca_alloc_data_block  <= mem_read_data;
                        state <= STATE_READ_ALLOC_WAIT;
                    end
                end
                 
                STATE_READ_ALLOC_WAIT: begin
                    // O ciclu de asteptare pentru a permite cache_array sa scrie blocul
                    state <= STATE_READ_ALLOC2;
                end
                 
                STATE_READ_ALLOC2: begin
                    // efectueaza citirea acum ca blocul este prezent, apoi returneaza date
                    ca_read_enable    <= 1'b1;
                    state             <= STATE_READ_HIT;
                end
                 
                STATE_WRITE_ALLOC: begin
                    // asteptare finalizare citire memorie
                    if (mem_ready) begin
                        // incarca blocul citit in cache la urmatorul ciclu de ceas
                        ca_alloc_enable      <= 1'b1;
                        ca_alloc_addr        <= {req_tag, req_set, {6{1'b0}}};
                        ca_alloc_data_block  <= mem_read_data;
                        state <= STATE_WRITE_ALLOC_WAIT;
                    end
                end
                 
                STATE_WRITE_ALLOC_WAIT: begin
                    // O ciclu de asteptare pentru a permite cache_array sa scrie blocul
                    state <= STATE_WRITE_ALLOC2;
                end
                 
                STATE_WRITE_ALLOC2: begin
                    // efectueaza scrierea acum ca blocul este prezent, apoi returneaza la CPU
                    ca_write_enable  <= 1'b1;
                    state            <= STATE_WRITE_HIT;
                end
                 
                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule