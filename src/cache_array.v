`timescale 1ns/1ps

module cache_array (
    input  wire         clk,
    input  wire         rst,

    // semnale acces CPU
    input  wire         read_enable,
    input  wire         write_enable,
    input  wire [31:0]  addr,                       
    input  wire [31:0]  write_data,
    output reg  [31:0]  read_data,
    output reg          hit,

    // semnale pentru eviction
    output reg          evict_dirty,
    output reg  [18:0]  evict_tag,
    output reg  [6:0]   evict_set,              
    output reg  [1:0]   evict_way,              
    output reg  [511:0] evict_data_block,

    // semnale alocare bloc nou
    input  wire         alloc_enable,
    input  wire [31:0]  alloc_addr,
    input  wire [511:0] alloc_data_block
);

    // parametri cache
    localparam NUM_SETS         = 128;
    localparam NUM_WAYS         = 4;

    // 64 bytes / 4 bytes
    localparam WORDS_PER_BLOCK  = 16;           
    localparam TAG_WIDTH        = 19;
    localparam INDEX_WIDTH      = 7;

    // 16 words - 4 bits
    localparam WORD_OFFSET_WIDTH= 4;            

    // Address decomposition
    wire [TAG_WIDTH-1:0]       tag_in;
    wire [INDEX_WIDTH-1:0]     set_index;
    wire [WORD_OFFSET_WIDTH-1:0] word_offset;

    // Top 19 bits
    assign tag_in     = addr[31:13];
    
    // urmatorii 7 bits
    assign set_index  = addr[12:6];

    // urmatorii 4 bits
    assign word_offset= addr[5:2];

    // array de storage
    reg [TAG_WIDTH-1:0]         tag_array       [0:NUM_SETS-1][0:NUM_WAYS-1];
    reg                         valid_array     [0:NUM_SETS-1][0:NUM_WAYS-1];
    reg                         dirty_array     [0:NUM_SETS-1][0:NUM_WAYS-1];
    reg [31:0]                  data_array      [0:NUM_SETS-1][0:NUM_WAYS-1][0:WORDS_PER_BLOCK-1];
    reg [1:0]                   lru_counter     [0:NUM_SETS-1][0:NUM_WAYS-1]; // 2-bit: 0 = MRU, 3 = LRU

    integer                     i, j, k;

    // variabile pentru calea de citire
    reg [1:0]                   hit_way;
    reg                         found;
    reg [1:0]                   vi_way;
    reg                         found_invalid;

    // variabile pentru calea de scriere
    reg [1:0]                   hit_way_w;
    reg                         found_w;
    reg [1:0]                   vi_way_w;
    reg                         found_invalid_w;

    // variabile pentru calea de alocare
    reg [TAG_WIDTH-1:0]         a_tag;
    reg [INDEX_WIDTH-1:0]       a_set;
    reg [1:0]                   way_to_alloc;
    reg                         found_invalid_a;
    integer                     w;

    // LRU helper task
    task update_lru_on_access;
        input [INDEX_WIDTH-1:0] idx;
        input [1:0]            accessed_way;
        integer                w2;
        begin
            for (w2 = 0; w2 < NUM_WAYS; w2 = w2 + 1) begin
                if (valid_array[idx][w2]) begin
                    if (lru_counter[idx][w2] < lru_counter[idx][accessed_way]) begin
                        lru_counter[idx][w2] = lru_counter[idx][w2] + 1;
                    end
                end
            end
            lru_counter[idx][accessed_way] = 2'b00; // marcat ca accesat recent
        end
    endtask

    // LRU helper update task
    task update_lru_on_alloc;
        input [INDEX_WIDTH-1:0] idx;
        input [1:0]            allocated_way;
        integer                w2;
        begin
            for (w2 = 0; w2 < NUM_WAYS; w2 = w2 + 1) begin
                if (valid_array[idx][w2]) begin
                    lru_counter[idx][w2] = lru_counter[idx][w2] + 1;
                end
            end
            lru_counter[idx][allocated_way] = 2'b00;
        end
    endtask

    // logica secventiala FSM
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                for (j = 0; j < NUM_WAYS; j = j + 1) begin
                    valid_array[i][j]      <= 1'b0;
                    dirty_array[i][j]      <= 1'b0;
                    tag_array[i][j]        <= {TAG_WIDTH{1'b0}};
                    lru_counter[i][j]      <= 2'b11; // incepe ca cel mai recent
                    for (k = 0; k < WORDS_PER_BLOCK; k = k + 1) begin
                        data_array[i][j][k] <= 32'b0;
                    end
                end
            end
            hit               <= 1'b0;
            read_data         <= 32'b0;
            evict_dirty       <= 1'b0;
            evict_tag         <= {TAG_WIDTH{1'b0}};
            evict_set         <= {INDEX_WIDTH{1'b0}};
            evict_way         <= 2'b00;
            evict_data_block  <= {WORDS_PER_BLOCK*32{1'b0}};
        end else begin
            // default
            hit <= 1'b0;

            // calea de citire
            if (read_enable) begin
                // cauta hit
                found    = 1'b0;
                hit_way  = 2'b00;
                for (j = 0; j < NUM_WAYS; j = j + 1) begin
                    if (valid_array[set_index][j] && (tag_array[set_index][j] == tag_in)) begin
                        found   = 1'b1;
                        hit_way = j[1:0];
                    end
                end

                if (found) begin
                    hit       <= 1'b1;
                    read_data <= data_array[set_index][hit_way][word_offset];
                    update_lru_on_access(set_index, hit_way);
                end else begin
                    // miss
                    found_invalid = 1'b0;
                    vi_way        = 2'b00;
                    for (j = 0; j < NUM_WAYS; j = j + 1) begin
                        if (!valid_array[set_index][j]) begin
                            found_invalid = 1'b1;
                            vi_way        = j[1:0];
                        end
                    end
                    if (!found_invalid) begin
                        for (j = 0; j < NUM_WAYS; j = j + 1) begin
                            if (lru_counter[set_index][j] == 2'b11) begin
                                vi_way = j[1:0];
                            end
                        end
                    end

                    evict_set         <= set_index;
                    evict_way         <= vi_way;
                    evict_tag         <= tag_array[set_index][vi_way];
                    evict_dirty       <= dirty_array[set_index][vi_way];

                    for (k = 0; k < WORDS_PER_BLOCK; k = k + 1) begin
                        evict_data_block[k*32 +: 32] <= data_array[set_index][vi_way][k];
                    end
                end
            end

            // calea de scriere
            if (write_enable) begin
                // cauta hit
                found_w    = 1'b0;
                hit_way_w  = 2'b00;
                for (j = 0; j < NUM_WAYS; j = j + 1) begin
                    if (valid_array[set_index][j] && (tag_array[set_index][j] == tag_in)) begin
                        found_w   = 1'b1;
                        hit_way_w = j[1:0];
                    end
                end

                if (found_w) begin
                    hit                       <= 1'b1;
                    data_array[set_index][hit_way_w][word_offset] <= write_data;
                    dirty_array[set_index][hit_way_w]            <= 1'b1;
                    update_lru_on_access(set_index, hit_way_w);
                end else begin
                    found_invalid_w = 1'b0;
                    vi_way_w        = 2'b00;
                    for (j = 0; j < NUM_WAYS; j = j + 1) begin
                        if (!valid_array[set_index][j]) begin
                            found_invalid_w = 1'b1;
                            vi_way_w        = j[1:0];
                        end
                    end
                    if (!found_invalid_w) begin
                        for (j = 0; j < NUM_WAYS; j = j + 1) begin
                            if (lru_counter[set_index][j] == 2'b11) begin
                                vi_way_w = j[1:0];
                            end
                        end
                    end

                    evict_set         <= set_index;
                    evict_way         <= vi_way_w;
                    evict_tag         <= tag_array[set_index][vi_way_w];
                    evict_dirty       <= dirty_array[set_index][vi_way_w];
                    for (k = 0; k < WORDS_PER_BLOCK; k = k + 1) begin
                        evict_data_block[k*32 +: 32] <= data_array[set_index][vi_way_w][k];
                    end
                end
            end

            // calea de alocare
            if (alloc_enable) begin
                a_tag = alloc_addr[31:13];
                a_set = alloc_addr[12:6];

                found_invalid_a = 1'b0;
                way_to_alloc    = 2'b00;
                for (w = 0; w < NUM_WAYS; w = w + 1) begin
                    if (!valid_array[a_set][w]) begin
                        found_invalid_a = 1'b1;
                        way_to_alloc    = w[1:0];
                    end
                end
                if (!found_invalid_a) begin
                    for (w = 0; w < NUM_WAYS; w = w + 1) begin
                        if (lru_counter[a_set][w] == 2'b11) begin
                            way_to_alloc = w[1:0];
                        end
                    end
                end

                tag_array[a_set][way_to_alloc]   <= a_tag;
                valid_array[a_set][way_to_alloc] <= 1'b1;
                dirty_array[a_set][way_to_alloc] <= 1'b0;

                for (k = 0; k < WORDS_PER_BLOCK; k = k + 1) begin
                    data_array[a_set][way_to_alloc][k] <= alloc_data_block[k*32 +: 32];
                end

                update_lru_on_alloc(a_set, way_to_alloc);
            end
        end
    end
endmodule