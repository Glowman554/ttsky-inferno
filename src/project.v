`default_nettype none

module tt_um_toxicfox_inferno (
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input wire ena,
    input wire clk,
    input wire rst_n
);
    wire reset = !rst_n;
    wire valid;
    wire [33:0] address;
    wire write;
    wire [31:0] wdata;
    wire [3:0] wstrb;
    wire [1:0] kind;
    wire ready;
    wire [31:0] rdata;
    wire error;
    wire irq_machine;
    wire irq_supervisor;
    wire irq_software;
    wire irq_timer;
    wire [63:0] time_value;
    wire uart_rx;
    wire uart_tx;
    wire spi_sclk;
    wire spi_mosi;
    wire spi_miso;
    wire spi_cs_n;
    wire flash_cs_n;
    wire ram_a_cs_n;
    wire ram_b_cs_n;
    wire mem_sclk;
    wire mem_mosi;
    wire mem_miso;
    wire retire_valid;
    wire trap_valid;

    RiscV #(
        .RESET_PC(32'h00000000),
        .ENABLE_MMU(1),
        .TLB_ENTRIES(8)
    ) cpu (
        .clk(clk),
        .reset(reset),
        .valid(valid),
        .address(address),
        .write(write),
        .wdata(wdata),
        .wstrb(wstrb),
        .kind(kind),
        .ready(ready), 
        .rdata(rdata), 
        .error(error),
        .irq_machine(irq_machine), 
        .irq_supervisor(irq_supervisor),
        .irq_software(irq_software), 
        .irq_timer(irq_timer),
        .time_value(time_value), 
        .retire_valid(retire_valid),
        .trap_valid(trap_valid)
    );

    TinyPlatform platform (
        .clk(clk),
        .reset(reset),
        .valid(valid),
        .address(address),
        .write(write),
        .wdata(wdata),
        .wstrb(wstrb),
        .kind(kind),
        .ready(ready),
        .rdata(rdata),
        .error(error),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .flash_cs_n(flash_cs_n),
        .ram_a_cs_n(ram_a_cs_n),
        .ram_b_cs_n(ram_b_cs_n),
        .mem_sclk(mem_sclk),
        .mem_mosi(mem_mosi),
        .mem_miso(mem_miso),
        .irq_machine(irq_machine),
        .irq_supervisor(irq_supervisor),
        .irq_software(irq_software),
        .irq_timer(irq_timer),
        .time_value(time_value)
    );

    assign uio_out = {ram_b_cs_n, ram_a_cs_n, 2'b11, mem_sclk, 1'b0, mem_mosi, flash_cs_n};
    assign uio_oe = 8'b11111011;
    assign uo_out = {2'b00, trap_valid, retire_valid, spi_cs_n, spi_mosi, spi_sclk, uart_tx};

    wire _unused = &{ena, ui_in[7:2], uio_in[7:3], uio_in[1:0], 1'b0};

    assign uart_rx = ui_in[1];
    assign spi_miso = ui_in[0];
    assign mem_miso = uio_in[2];
endmodule

`default_nettype wire

module BareMemory (
    input clk,
    input reset,
    input req_valid,
    input [31:0] req_address,
    input req_write,
    input [31:0] req_wdata,
    input [3:0] req_wstrb,
    input [1:0] req_kind,
    input req_atomic,
    input req_sc,
    input sc_reserved_valid,
    input [33:0] sc_reserved_address,
    output req_ready,
    output reg [31:0] req_rdata,
    output reg req_error,
    output req_page_fault,
    output reg sc_success,
    output [33:0] translated_address,
    output valid,
    output [33:0] address,
    output write,
    output [31:0] wdata,
    output [3:0] wstrb,
    output [1:0] kind,
    input ready,
    input [31:0] rdata,
    input error
);
    wire [33:0] physical_address = {2'b00, req_address};
    wire ram_address = req_address >= 32'h40000000 && req_address < 32'h41000000;

    wire sc_failed = req_sc && (!sc_reserved_valid || sc_reserved_address != {physical_address[33:2], 2'b00});
    
    localparam IDLE = 2'd0;
    localparam ACCESS = 2'd1;
    localparam RESPONSE = 2'd2;

    reg [1:0] state;
    wire denied = req_atomic && !ram_address;

    assign translated_address = physical_address;

    assign valid = !reset && state == ACCESS && req_valid && !denied && !sc_failed;
    assign address = {physical_address[33:2], 2'b00};
    assign write = req_write;
    assign wdata = req_wdata;
    assign wstrb = req_write ? req_wstrb : 4'd0;
    
    assign kind = req_kind;
    assign req_ready = !reset && state == RESPONSE && req_valid;
    assign req_page_fault = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            req_rdata <= 0;
            req_error <= 0;
            sc_success <= 0;
        end else begin
            case (state)
                IDLE: if (req_valid) begin
                    req_rdata <= 0;
                    req_error <= 0;
                    sc_success <= 0;
                    state <= ACCESS;
                end

                ACCESS: begin
                    if (denied) begin
                        req_error <= 1;
                        state <= RESPONSE;
                    end else if (sc_failed) begin
                        state <= RESPONSE;
                    end else if (ready) begin
                        req_rdata <= rdata;
                        req_error <= error;
                        sc_success <= req_sc && !error;
                        state <= RESPONSE;
                    end
                end

                RESPONSE: begin
                    if (req_valid) begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

module RiscV #(
    parameter [31:0] RESET_PC = 0,
    parameter TLB_ENTRIES = 2048,
    parameter MEM_WORDS = 8192,
    parameter ENABLE_MMU = 1
) (
    input clk,
    input reset,
    output valid,
    output [33:0] address,
    output write,
    output [31:0] wdata,
    output [3:0] wstrb,
    output [1:0] kind,
    input ready,
    input [31:0] rdata,
    input error,
    input irq_software,
    input irq_timer,
    input irq_machine,
    input irq_supervisor,
    input [63:0] time_value,
    output [1:0] privilege,
    output [1:0] data_privilege,
    output [31:0] satp_value,
    output [31:0] status_value,
    output retire_valid,
    output [31:0] retire_pc,
    output [31:0] retire_instruction,
    output [4:0] retire_rd,
    output [31:0] retire_data,
    output [31:0] pc,
    output trap_valid,
    output trap_interrupt,
    output [4:0] trap_cause,
    output [31:0] trap_pc,
    output [31:0] trap_value
);
    wire clear_reservation;
    wire interrupt_pending;
    wire csr_valid;
    wire csr_commit;
    wire csr_source_zero;
    wire csr_illegal;
    wire system_valid;
    wire system_commit;
    wire system_illegal;
    wire trap_ready;
    wire [4:0] interrupt_cause;
    wire [11:0] csr_address;
    wire [2:0] csr_operation;
    wire [2:0] system_operation;
    wire [31:0] csr_source;
    wire [31:0] csr_rdata;
    wire [31:0] return_pc;
    wire [31:0] trap_vector;
    wire [63:0] pmp_configuration;
    wire [255:0] pmp_addresses;
    wire engine_valid;
    wire engine_ready;
    wire engine_error;
    wire engine_page_fault;
    wire access_rmw;
    wire access_atomic;
    wire access_sc;
    wire [31:0] access_address;
    wire [1:0] access_size;
    wire [33:0] engine_address;
    wire [33:0] translated_address;
    wire [33:0] sc_reserved_address;
    wire [31:0] engine_rdata;
    wire [31:0] engine_wdata;
    wire [3:0] engine_wstrb;
    wire [1:0] engine_kind;
    wire engine_write;
    wire sc_reserved_valid;
    wire sc_success;

    wire csr_writes = csr_operation[1:0] == 1 || !csr_source_zero;

    wire translation_flush = (system_commit && system_operation == 4) ||
        (csr_commit && csr_writes &&
            (csr_address == 12'h180 || csr_address == 12'h3a0 || csr_address == 12'h3a1 ||
             (csr_address >= 12'h3b0 && csr_address <= 12'h3b7)));

    generate if (ENABLE_MMU) begin : translated_memory
    Mmu #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .MEM_WORDS(MEM_WORDS)
    ) memory (
        .clk(clk),
        .reset(reset),
        .tlb_flush(translation_flush),
        .req_valid(engine_valid),
        .req_address(access_address),
        .req_size(access_size),
        .req_write(engine_write),
        .req_wdata(engine_wdata),
        .req_wstrb(engine_wstrb),
        .req_kind(engine_kind),
        .req_rmw(access_rmw),
        .req_atomic(access_atomic),
        .req_sc(access_sc),
        .sc_reserved_valid(sc_reserved_valid),
        .sc_reserved_address(sc_reserved_address),
        .req_privilege(engine_kind == 1 ? privilege : data_privilege),
        .satp(satp_value),
        .sum(status_value[18]),
        .mxr(status_value[19]),
        .pmp_configuration(pmp_configuration),
        .pmp_addresses(pmp_addresses),
        .req_ready(engine_ready),
        .req_rdata(engine_rdata),
        .req_error(engine_error),
        .req_page_fault(engine_page_fault),
        .sc_success(sc_success),
        .translated_address(translated_address),
        .valid(valid),
        .address(address),
        .write(write),
        .wdata(wdata),
        .wstrb(wstrb),
        .kind(kind),
        .ready(ready),
        .rdata(rdata),
        .error(error)
    );
    end else begin : direct_memory
    BareMemory memory (
        .clk(clk),
        .reset(reset),
        .req_valid(engine_valid),
        .req_address(access_address),
        .req_write(engine_write),
        .req_wdata(engine_wdata),
        .req_wstrb(engine_wstrb),
        .req_kind(engine_kind),
        .req_atomic(access_atomic),
        .req_sc(access_sc),
        .sc_reserved_valid(sc_reserved_valid),
        .sc_reserved_address(sc_reserved_address),
        .req_ready(engine_ready),
        .req_rdata(engine_rdata),
        .req_error(engine_error),
        .req_page_fault(engine_page_fault),
        .sc_success(sc_success),
        .translated_address(translated_address),
        .valid(valid),
        .address(address),
        .write(write),
        .wdata(wdata),
        .wstrb(wstrb),
        .kind(kind),
        .ready(ready),
        .rdata(rdata), 
        .error(error)
    );
    end endgenerate

    ExecutionUnit #(
        .RESET_PC(RESET_PC)
    ) engine (
        .valid(engine_valid),
        .address(engine_address),
        .write(engine_write),
        .wdata(engine_wdata),
        .wstrb(engine_wstrb),
        .kind(engine_kind),
        .ready(engine_ready),
        .rdata(engine_rdata),
        .error(engine_error),
        .page_fault(engine_page_fault),
        .clk(clk),
        .reset(reset),
        .access_address(access_address),
        .access_size(access_size),
        .access_rmw(access_rmw),
        .access_atomic(access_atomic),
        .access_sc(access_sc),
        .sc_reserved_valid(sc_reserved_valid),
        .sc_reserved_address(sc_reserved_address),
        .translated_address(translated_address),
        .sc_success(sc_success),
        .privilege(privilege),
        .clear_reservation(clear_reservation),
        .interrupt_pending(interrupt_pending),
        .interrupt_cause(interrupt_cause),
        .csr_valid(csr_valid),
        .csr_commit(csr_commit),
        .csr_address(csr_address),
        .csr_operation(csr_operation),
        .csr_source(csr_source),
        .csr_source_zero(csr_source_zero),
        .csr_rdata(csr_rdata),
        .csr_illegal(csr_illegal),
        .system_valid(system_valid),
        .system_commit(system_commit),
        .system_operation(system_operation),
        .system_illegal(system_illegal),
        .return_pc(return_pc),
        .trap_valid(trap_valid),
        .trap_cause(trap_cause),
        .trap_interrupt(trap_interrupt),
        .trap_pc(trap_pc),
        .trap_value(trap_value),
        .trap_ready(trap_ready),
        .trap_vector(trap_vector),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc),
        .retire_instruction(retire_instruction),
        .retire_rd(retire_rd),
        .retire_data(retire_data),
        .pc(pc)
    );

    CsrFile #(.ENABLE_MMU(ENABLE_MMU)) control (
        .clk(clk),
        .reset(reset),
        .csr_valid(csr_valid),
        .csr_commit(csr_commit),
        .csr_address(csr_address),
        .csr_operation(csr_operation),
        .csr_source(csr_source),
        .csr_source_zero(csr_source_zero),
        .csr_rdata(csr_rdata),
        .csr_illegal(csr_illegal),
        .system_valid(system_valid),
        .system_commit(system_commit),
        .system_operation(system_operation),
        .system_illegal(system_illegal),
        .return_pc(return_pc),
        .context_flush(clear_reservation),
        .trap_valid(trap_valid),
        .trap_interrupt(trap_interrupt),
        .trap_cause(trap_cause),
        .trap_pc(trap_pc),
        .trap_value(trap_value),
        .trap_ready(trap_ready),
        .trap_vector(trap_vector),
        .irq_software(irq_software),
        .irq_timer(irq_timer),
        .irq_machine(irq_machine),
        .irq_supervisor(irq_supervisor),
        .time_value(time_value),
        .retired(retire_valid),
        .privilege(privilege),
        .interrupt_pending(interrupt_pending),
        .interrupt_cause(interrupt_cause),
        .satp_value(satp_value),
        .status_value(status_value),
        .data_privilege(data_privilege),
        .pmp_configuration(pmp_configuration),
        .pmp_addresses(pmp_addresses)
    );
endmodule

module CsrFile #(
    parameter ENABLE_MMU = 1
) (
    input clk,
    input reset,
    input csr_valid,
    input csr_commit,
    input [11:0] csr_address,
    input [2:0] csr_operation,
    input [31:0] csr_source,
    input csr_source_zero,
    output reg [31:0] csr_rdata,
    output csr_illegal,
    input system_valid,
    input system_commit,
    input [2:0] system_operation,
    output system_illegal,
    output [31:0] return_pc,
    output context_flush,
    input trap_valid,
    input trap_interrupt,
    input [4:0] trap_cause,
    input [31:0] trap_pc,
    input [31:0] trap_value,
    output trap_ready,
    output [31:0] trap_vector,
    input irq_software,
    input irq_timer,
    input irq_machine,
    input irq_supervisor,
    input [63:0] time_value,
    input retired,
    output reg [1:0] privilege,
    output reg interrupt_pending,
    output reg [4:0] interrupt_cause,
    output [31:0] satp_value,
    output [31:0] status_value,
    output [1:0] data_privilege,
    output [63:0] pmp_configuration,
    output [255:0] pmp_addresses
);
    localparam [31:0] STATUS_MASK = 32'h007e19aa;
    localparam [31:0] SSTATUS_MASK = 32'h000c0122;
    localparam [31:0] IRQ_MASK = 32'h00000aaa;
    localparam [31:0] DELEG_IRQ_MASK = 32'h00000222;
    localparam [31:0] DELEG_EXCEPTION_MASK = 32'h0000b3ff;

    reg [31:0] mstatus;
    reg [31:0] mie;
    reg [31:0] mideleg;
    reg [31:0] medeleg;
    reg [31:0] mtvec;
    reg [31:0] stvec;
    reg [31:0] mepc;
    reg [31:0] sepc;
    reg [31:0] mcause;
    reg [31:0] scause;
    reg [31:0] mtval;
    reg [31:0] stval;
    reg [31:0] mscratch;
    reg [31:0] sscratch;
    reg [31:0] satp;
    reg [31:0] mcounteren;
    reg [31:0] scounteren;
    reg [31:0] mcountinhibit;
    reg [31:0] software_pending;
    reg [63:0] mcycle;
    reg [63:0] minstret;
    reg menvcfg_fiom;
    reg senvcfg_fiom;
    wire [31:0] mip = software_pending |
        (irq_software ? 32'h8 : 0) | (irq_timer ? 32'h80 : 0) |
        (irq_machine ? 32'h800 : 0) | (irq_supervisor ? 32'h200 : 0);

    wire csr_write = csr_operation[1:0] == 1 || !csr_source_zero;
    reg csr_known;

    reg counter_denied;
    reg [31:0] rmw_base;
    reg [31:0] csr_wdata;

    wire write_fire = csr_valid && csr_commit && !csr_illegal && csr_write && !reset;
    wire system_fire = system_valid && system_commit && !system_illegal && !reset;

    wire pmp_known;
    wire [31:0] pmp_read;

    generate if (ENABLE_MMU) begin : with_pmp
    PmpRegisters pmp (
        .clk(clk),
        .reset(reset),
        .address(csr_address),
        .write_enable(write_fire),
        .write_data(csr_wdata),
        .known(pmp_known),
        .read_data(pmp_read),
        .configuration(pmp_configuration),
        .addresses(pmp_addresses)
    );
    end else begin : without_pmp
        assign pmp_known = 1'b0;
        assign pmp_read = 32'd0;
        assign pmp_configuration = 64'd0;
        assign pmp_addresses = 256'd0;
    end endgenerate

    wire delegate_trap = privilege != 3 && (trap_interrupt ? mideleg[trap_cause] : medeleg[trap_cause]);
    wire [31:0] target_vector = delegate_trap ? stvec : mtvec;

    assign trap_ready = !reset;
    assign trap_vector = {target_vector[31:2], 2'b0} + ((trap_interrupt && target_vector[1:0] == 1) ? {25'd0, trap_cause, 2'b0} : 32'd0);
    assign return_pc = system_operation == 1 ? mepc : sepc;

    assign satp_value = ENABLE_MMU ? satp : 32'd0;
    assign status_value = mstatus;
    assign data_privilege = privilege == 3 && mstatus[17] ? mstatus[12:11] : privilege;

    assign context_flush = (write_fire && csr_address == 12'h180) ||
        (system_fire && (system_operation == 1 || system_operation == 2 || system_operation == 4));

    assign csr_illegal = csr_valid && (!csr_known || counter_denied ||
        csr_address[9:8] > privilege ||
        (csr_address[11:10] == 3 && csr_write) ||
        (csr_address == 12'h180 && privilege == 1 && mstatus[20]) ||
        (csr_operation[1:0] == 0));
    assign system_illegal = system_valid &&
        ((system_operation == 1 && privilege != 3) ||
         (system_operation == 2 && (privilege == 0 || (privilege == 1 && mstatus[22]))) ||
         (system_operation == 3 && (privilege == 0 || (privilege != 3 && mstatus[21]))) ||
         (system_operation == 4 && (privilege == 0 || (privilege == 1 && mstatus[20]))) ||
         system_operation == 0 || system_operation > 4);

    always @(*) begin
        csr_rdata = 0;
        csr_known = 1;
        counter_denied = 0;
        case (csr_address)
            12'h100: csr_rdata = mstatus & SSTATUS_MASK;
            12'h104: csr_rdata = mie & mideleg;
            12'h105: csr_rdata = stvec;
            12'h106: csr_rdata = scounteren;
            12'h10a: csr_rdata = {31'd0, senvcfg_fiom};
            12'h140: csr_rdata = sscratch;
            12'h141: csr_rdata = sepc;
            12'h142: csr_rdata = scause;
            12'h143: csr_rdata = stval;
            12'h144: csr_rdata = mip & mideleg;
            12'h180: csr_rdata = ENABLE_MMU ? satp : 32'd0;
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = 32'h40141105;  // fixed RV32 IMAC, S, U
            12'h302: csr_rdata = medeleg;
            12'h303: csr_rdata = mideleg;
            12'h304: csr_rdata = mie;
            12'h305: csr_rdata = mtvec;
            12'h306: csr_rdata = mcounteren;
            12'h30a: csr_rdata = {31'd0, menvcfg_fiom};
            12'h310: csr_rdata = 0;  // mstatush: little-endian, no virtualization
            12'h31a: csr_rdata = 0;  // menvcfgh
            12'h320: csr_rdata = mcountinhibit;
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            12'h344: csr_rdata = mip;
            12'hb00, 12'hc00: csr_rdata = mcycle[31:0];
            12'hb80, 12'hc80: csr_rdata = mcycle[63:32];
            12'hb02, 12'hc02: csr_rdata = minstret[31:0];
            12'hb82, 12'hc82: csr_rdata = minstret[63:32];
            12'hc01: csr_rdata = time_value[31:0];
            12'hc81: csr_rdata = time_value[63:32];
            12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: csr_rdata = 0;

            default: begin
                csr_known = pmp_known;
                csr_rdata = pmp_read;
            end
        endcase

        if ((csr_address >= 12'hc00 && csr_address <= 12'hc02) || (csr_address >= 12'hc80 && csr_address <= 12'hc82)) begin
            if (privilege != 3 && !mcounteren[csr_address[1:0]]) begin
                counter_denied = 1;
            end

            if (privilege == 0 && !scounteren[csr_address[1:0]]) begin
                counter_denied = 1;
            end
        end


        rmw_base = csr_rdata;
        if (csr_address == 12'h344) begin
            rmw_base = software_pending;
        end

        if (csr_address == 12'h144) begin
            rmw_base = software_pending & mideleg;
        end

        case (csr_operation[1:0])
            1: csr_wdata = csr_source;
            2: csr_wdata = rmw_base | csr_source;
            3: csr_wdata = rmw_base & ~csr_source;
            default: csr_wdata = rmw_base;
        endcase
    end

    wire [31:0] machine_eligible = (privilege != 3 || mstatus[3]) ? (mie & mip & ~mideleg) : 32'd0;
    wire [31:0] supervisor_eligible = (privilege == 0 || (privilege == 1 && mstatus[1])) ? (mie & mip & mideleg) : 32'd0;
    wire [31:0] eligible = machine_eligible != 0 ? machine_eligible : supervisor_eligible;

    always @(*) begin
        interrupt_pending = 1;
        interrupt_cause = 0;
        if (eligible[11]) begin
            interrupt_cause = 11;
        end else if (eligible[3]) begin
            interrupt_cause = 3;
        end else if (eligible[7]) begin
            interrupt_cause = 7;
        end else if (eligible[9]) begin
            interrupt_cause = 9;
        end else if (eligible[1]) begin
            interrupt_cause = 1;
        end else if (eligible[5]) begin
            interrupt_cause = 5;
        end else begin
            interrupt_pending = 0;
        end
    end

    function [31:0] normalize_status(input [31:0] value);
        begin
            normalize_status = value & STATUS_MASK;
            if (value[12:11] == 2) begin
                normalize_status[12:11] = 0;
            end
        end
    endfunction

    function [31:0] normalize_vector(input [31:0] value);
        normalize_vector = {value[31:2], value[1:0] == 1 ? 2'b01 : 2'b00};
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            privilege <= 3;
            mstatus <= 0;
            mie <= 0;
            mideleg <= 0;
            medeleg <= 0;
            mtvec <= 0;
            stvec <= 0;
            mepc <= 0;
            sepc <= 0;
            mcause <= 0;
            scause <= 0;
            mtval <= 0;
            stval <= 0;
            mscratch <= 0;
            sscratch <= 0;
            satp <= 0;
            mcounteren <= 0;
            scounteren <= 0;
            mcountinhibit <= 0;
            software_pending <= 0;
            mcycle <= 0;
            minstret <= 0;
            menvcfg_fiom <= 0;
            senvcfg_fiom <= 0;
        end else begin
            if (!mcountinhibit[0]) begin
                mcycle <= mcycle + 64'd1;
            end

            if (retired && !mcountinhibit[2]) begin
                minstret <= minstret + 64'd1;
            end

            if (write_fire) begin
                case (csr_address)
                    12'h100: mstatus <= normalize_status((mstatus & ~SSTATUS_MASK) | (csr_wdata & SSTATUS_MASK));
                    12'h104: mie <= (mie & ~mideleg) | (csr_wdata & mideleg);
                    12'h105: stvec <= normalize_vector(csr_wdata);
                    12'h106: scounteren <= csr_wdata & 7;
                    12'h10a: senvcfg_fiom <= csr_wdata[0];
                    12'h140: sscratch <= csr_wdata;
                    12'h141: sepc <= {csr_wdata[31:1], 1'b0};
                    12'h142: scause <= csr_wdata;
                    12'h143: stval <= csr_wdata;
                    12'h144: software_pending <= (software_pending & ~(mideleg & 2)) | (csr_wdata & mideleg & 2);
                    12'h180: if (ENABLE_MMU) satp <= csr_wdata & 32'h803fffff;  // ASIDLEN=0
                    12'h300: mstatus <= normalize_status(csr_wdata);
                    12'h302: medeleg <= csr_wdata & DELEG_EXCEPTION_MASK;
                    12'h303: mideleg <= csr_wdata & DELEG_IRQ_MASK;
                    12'h304: mie <= csr_wdata & IRQ_MASK;
                    12'h305: mtvec <= normalize_vector(csr_wdata);
                    12'h306: mcounteren <= csr_wdata & 7;
                    12'h30a: menvcfg_fiom <= csr_wdata[0];
                    12'h320: mcountinhibit <= csr_wdata & 5;
                    12'h340: mscratch <= csr_wdata;
                    12'h341: mepc <= {csr_wdata[31:1], 1'b0};
                    12'h342: mcause <= csr_wdata;
                    12'h343: mtval <= csr_wdata;
                    12'h344: software_pending <= csr_wdata & DELEG_IRQ_MASK;
                    12'hb00: mcycle[31:0] <= csr_wdata;
                    12'hb80: mcycle[63:32] <= csr_wdata;
                    12'hb02: minstret[31:0] <= csr_wdata;
                    12'hb82: minstret[63:32] <= csr_wdata;
                    default: ;
                endcase
            end

            if (trap_valid && trap_ready) begin
                if (delegate_trap) begin
                    sepc <= {trap_pc[31:1], 1'b0};
                    scause <= {trap_interrupt, 26'd0, trap_cause};
                    stval <= trap_value;
                    mstatus[5] <= mstatus[1];
                    mstatus[1] <= 0;
                    mstatus[8] <= privilege == 1;
                    privilege <= 1;
                end else begin
                    mepc <= {trap_pc[31:1], 1'b0};
                    mcause <= {trap_interrupt, 26'd0, trap_cause};
                    mtval <= trap_value;
                    mstatus[7] <= mstatus[3];
                    mstatus[3] <= 0;
                    mstatus[12:11] <= privilege;
                    privilege <= 3;
                end
            end else if (system_fire) begin
                if (system_operation == 1) begin
                    privilege <= mstatus[12:11];
                    mstatus[3] <= mstatus[7];
                    mstatus[7] <= 1;
                    mstatus[12:11] <= 0;
                    if (mstatus[12:11] != 3) begin
                        mstatus[17] <= 0;
                    end
                end else if (system_operation == 2) begin
                    privilege <= mstatus[8] ? 1 : 0;
                    mstatus[1] <= mstatus[5];
                    mstatus[5] <= 1;
                    mstatus[8] <= 0;
                    mstatus[17] <= 0;
                end
            end
        end
    end
endmodule

module Decompress (
    input [15:0] c,
    output reg [31:0] instruction
);
    localparam [6:0] OP_IMM = 7'h13;
    localparam [6:0] OP = 7'h33;
    localparam [6:0] LUI = 7'h37;
    localparam [6:0] LOAD = 7'h03;
    localparam [6:0] STORE = 7'h23;
    localparam [6:0] LOAD_FP = 7'h07;
    localparam [6:0] STORE_FP = 7'h27;
    localparam [6:0] BRANCH = 7'h63;
    localparam [6:0] JALR = 7'h67;
    localparam [6:0] JAL = 7'h6f;

    wire [4:0] rd = c[11:7];
    wire [4:0] rs2 = c[6:2];
    wire [4:0] rd_short = {2'b01, c[4:2]};
    wire [4:0] rs1_short = {2'b01, c[9:7]};

    wire [11:0] imm6 = {{7{c[12]}}, c[6:2]};
    wire [11:0] addi4spn_imm = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00};
    wire [11:0] word_offset = {5'b0, c[5], c[12:10], c[6], 2'b00};
    wire [11:0] double_offset = {4'b0, c[6:5], c[12:10], 3'b000};
    wire [11:0] lwsp_offset = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
    wire [11:0] ldsp_offset = {3'b0, c[4:2], c[12], c[6:5], 3'b000};
    wire [11:0] swsp_offset = {4'b0, c[8:7], c[12:9], 2'b00};
    wire [11:0] sdsp_offset = {3'b0, c[9:7], c[12:10], 3'b000};
    wire [11:0] addi16sp_imm = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0};
    wire [20:0] jump_offset = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
    wire [12:0] branch_offset = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};

    function [31:0] i_type(input [11:0] imm, input [4:0] rs1, input [2:0] funct3, input [4:0] dest, input [6:0] opcode);
        i_type = {imm, rs1, funct3, dest, opcode};
    endfunction

    function [31:0] s_type(input [11:0] imm, input [4:0] src, input [4:0] rs1, input [2:0] funct3, input [6:0] opcode);
        s_type = {imm[11:5], src, rs1, funct3, imm[4:0], opcode};
    endfunction

    function [31:0] r_type(input [6:0] funct7, input [4:0] src, input [4:0] rs1, input [2:0] funct3, input [4:0] dest);
        r_type = {funct7, src, rs1, funct3, dest, OP};
    endfunction

    function [31:0] b_type(input [12:0] imm, input [4:0] rs1, input [2:0] funct3);
        b_type = {imm[12], imm[10:5], 5'd0, rs1, funct3, imm[4:1], imm[11], BRANCH};
    endfunction

    function [31:0] j_type(input [20:0] imm, input [4:0] dest);
        j_type = {imm[20], imm[10:1], imm[11], imm[19:12], dest, JAL};
    endfunction

    always @(*) begin
        instruction = 32'd0;

        case ({c[1:0], c[15:13]})
            // Quadrant 0
            5'b00_000: if (addi4spn_imm != 0) begin
                instruction = i_type(addi4spn_imm, 5'd2, 3'd0, rd_short, OP_IMM);
            end
            5'b00_001: instruction = i_type(double_offset, rs1_short, 3'd3, rd_short, LOAD_FP);
            5'b00_010: instruction = i_type(word_offset, rs1_short, 3'd2, rd_short, LOAD);
            5'b00_011: instruction = i_type(word_offset, rs1_short, 3'd2, rd_short, LOAD_FP);
            5'b00_101: instruction = s_type(double_offset, rd_short, rs1_short, 3'd3, STORE_FP);
            5'b00_110: instruction = s_type(word_offset, rd_short, rs1_short, 3'd2, STORE);
            5'b00_111: instruction = s_type(word_offset, rd_short, rs1_short, 3'd2, STORE_FP);

            // Quadrant 1
            5'b01_000: instruction = i_type(imm6, rd, 3'd0, rd, OP_IMM);
            5'b01_001: instruction = j_type(jump_offset, 5'd1);
            5'b01_010: instruction = i_type(imm6, 5'd0, 3'd0, rd, OP_IMM);
            5'b01_011: begin
                if (rd == 2) begin
                    if (addi16sp_imm != 0) begin
                        instruction = i_type(addi16sp_imm, 5'd2, 3'd0, 5'd2, OP_IMM);
                    end
                end else if (imm6 != 0) begin
                    instruction = {{15{c[12]}}, c[6:2], rd, LUI};
                end
            end
            5'b01_100: begin
                case (c[11:10])
                    2'b00: if (!c[12]) begin
                        instruction = i_type({7'h00, c[6:2]}, rs1_short, 3'd5, rs1_short, OP_IMM);
                    end
                    2'b01: if (!c[12]) begin
                        instruction = i_type({7'h20, c[6:2]}, rs1_short, 3'd5, rs1_short, OP_IMM);
                    end
                    2'b10: instruction = i_type(imm6, rs1_short, 3'd7, rs1_short, OP_IMM);
                    2'b11: begin
                        if (!c[12]) begin
                            case (c[6:5])
                                2'b00: instruction = r_type(7'h20, rd_short, rs1_short, 3'd0, rs1_short);
                                2'b01: instruction = r_type(7'h00, rd_short, rs1_short, 3'd4, rs1_short);
                                2'b10: instruction = r_type(7'h00, rd_short, rs1_short, 3'd6, rs1_short);
                                2'b11: instruction = r_type(7'h00, rd_short, rs1_short, 3'd7, rs1_short);
                            endcase
                        end
                    end
                endcase
            end
            5'b01_101: instruction = j_type(jump_offset, 5'd0);
            5'b01_110: instruction = b_type(branch_offset, rs1_short, 3'd0);
            5'b01_111: instruction = b_type(branch_offset, rs1_short, 3'd1);

            // Quadrant 2
            5'b10_000: if (!c[12]) begin
                instruction = i_type({7'h00, c[6:2]}, rd, 3'd1, rd, OP_IMM);
            end
            5'b10_001: instruction = i_type(ldsp_offset, 5'd2, 3'd3, rd, LOAD_FP);
            5'b10_010: if (rd != 0) begin
                instruction = i_type(lwsp_offset, 5'd2, 3'd2, rd, LOAD);
            end
            5'b10_011: instruction = i_type(lwsp_offset, 5'd2, 3'd2, rd, LOAD_FP);
            5'b10_100: begin
                if (!c[12]) begin
                    if (rs2 == 0) begin
                        if (rd != 0) begin
                            instruction = i_type(12'd0, rd, 3'd0, 5'd0, JALR);
                        end
                    end else begin
                        instruction = r_type(7'h00, rs2, 5'd0, 3'd0, rd);
                    end
                end else begin
                    if (rs2 == 0) begin
                        if (rd == 0) begin
                            instruction = 32'h00100073;
                        end else begin
                            instruction = i_type(12'd0, rd, 3'd0, 5'd1, JALR);
                        end
                    end else begin
                        instruction = r_type(7'h00, rs2, rd, 3'd0, rd);
                    end
                end
            end
            5'b10_101: instruction = s_type(sdsp_offset, rs2, 5'd2, 3'd3, STORE_FP);
            5'b10_110: instruction = s_type(swsp_offset, rs2, 5'd2, 3'd2, STORE);
            5'b10_111: instruction = s_type(swsp_offset, rs2, 5'd2, 3'd2, STORE_FP);

            default: ;
        endcase
    end
endmodule

module ExecutionUnit #(
    parameter [31:0] RESET_PC = 0
) (
    input clk,
    input reset,
    output valid,
    output [33:0] address,
    output write,
    output [31:0] wdata,
    output [3:0] wstrb,
    output [1:0] kind,
    output [31:0] access_address,
    output [1:0] access_size,
    output access_rmw,
    output access_atomic,
    output access_sc,
    output reg sc_reserved_valid,
    output reg [33:0] sc_reserved_address,
    input [33:0] translated_address,
    input sc_success,
    input page_fault,
    input ready,
    input [31:0] rdata,
    input error,
    input [1:0] privilege,
    input clear_reservation,
    input interrupt_pending,
    input [4:0] interrupt_cause,
    output csr_valid,
    output csr_commit,
    output [11:0] csr_address,
    output [2:0] csr_operation,
    output [31:0] csr_source,
    output csr_source_zero,
    input [31:0] csr_rdata,
    input csr_illegal,
    output system_valid,
    output system_commit,
    output [2:0] system_operation,
    input system_illegal,
    input [31:0] return_pc,
    output trap_valid,
    output reg [4:0] trap_cause,
    output reg trap_interrupt,
    output reg [31:0] trap_pc,
    output reg [31:0] trap_value,
    input trap_ready,
    input [31:0] trap_vector,
    output reg retire_valid,
    output reg [31:0] retire_pc,
    output reg [31:0] retire_instruction,
    output reg [4:0] retire_rd,
    output reg [31:0] retire_data,
    output reg [31:0] pc
);
    localparam FETCH = 0;
    localparam EXECUTE = 1;
    localparam MEMORY = 2;
    localparam TRAP = 3;
    localparam MULDIV = 4;
    localparam ATOMIC_READ = 5;
    localparam ATOMIC_WRITE = 6;
    localparam BOUNDARY = 7;
    localparam FETCH_HIGH = 8;

    reg [3:0] state;
    reg [31:0] instruction;
    reg [31:0] raw_instruction;
    reg compressed;
    reg [15:0] fetch_low;

    reg [31:0] registers[0:31];

    wire [4:0] rs1 = instruction[19:15];
    wire [4:0] rs2 = instruction[24:20];

    wire [4:0] rd = instruction[11:7];

    wire [31:0] a = rs1 == 0 ? 0 : registers[rs1];
    wire [31:0] b = rs2 == 0 ? 0 : registers[rs2];

    wire [2:0] funct3 = instruction[14:12];
    wire [6:0] funct7 = instruction[31:25];

    wire [31:0] imm_i = {{20{instruction[31]}}, instruction[31:20]};
    wire [31:0] imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
    wire [31:0] imm_b = {{19{instruction[31]}}, instruction[31], instruction[7], instruction[30:25], instruction[11:8], 1'b0};
    wire [31:0] imm_u = {instruction[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};

    wire register_arithmetic = instruction[6:0] == 7'h33;
    wire subtract = register_arithmetic && funct3 == 0 && funct7 == 7'h20;
    
    wire [31:0] add_operand = register_arithmetic ? b : instruction[6:0] == 7'h23 ? imm_s : imm_i;
    wire [31:0] data_sum = a + (add_operand ^ {32{subtract}}) + subtract;

    wire [31:0] pc_offset = instruction[6:0] == 7'h17 ? imm_u :
                            instruction[6:0] == 7'h6f ? imm_j : imm_b;
    wire [31:0] pc_sum = pc + pc_offset;

    function [31:0] reverse_bits(input [31:0] value);
        integer bit_index;
        begin
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                reverse_bits[bit_index] = value[31-bit_index];
            end
        end
    endfunction

    wire shift_left = funct3 == 1;
    wire shift_arithmetic = funct3 == 5 && funct7 == 7'h20;
    wire [4:0] shift_amount = register_arithmetic ? b[4:0] : instruction[24:20];
    wire [31:0] shift_input = shift_left ? reverse_bits(a) : a;
    wire signed [32:0] shift_signed_input = {shift_arithmetic && a[31], shift_input};
    wire [31:0] shift_output = shift_signed_input >>> shift_amount;
    wire [31:0] shift_result = shift_left ? reverse_bits(shift_output) : shift_output;

    reg illegal;
    reg reg_write;
    reg memory_op;
    reg store;
    reg jump;
    reg branch_taken;
    reg ecall;
    reg ebreak;
    reg muldiv_op;
    reg atomic;
    reg csr_op;

    reg [2:0] decoded_system;
    reg [31:0] result;
    reg [31:0] next_pc;

    reg [31:0] effective_address;
    reg [31:0] mem_address;
    reg [31:0] mem_wdata;
    reg [31:0] mem_next_pc;
    reg [3:0] mem_wstrb;
    reg [2:0] mem_funct3;
    reg [4:0] mem_rd;
    reg mem_write;

    reg reservation_valid;

    reg [1:0] previous_privilege;
    reg [33:0] reservation_address;
    reg [31:0] atomic_old;
    reg [4:0] atomic_operation;
    reg [31:0] atomic_updated;

    wire is_lr = instruction[31:27] == 5'b00010;
    wire is_sc = instruction[31:27] == 5'b00011;

    wire [31:0] shifted_read = rdata >> {mem_address[1:0], 3'b000};
    reg [31:0] load_result;

    integer i;

    wire muldiv_done;
    wire [31:0] muldiv_result;

    MulDiv muldiv (
        .clk(clk),
        .reset(reset),
        .start(state == EXECUTE && muldiv_op && !illegal && !reset),
        .operation(funct3),
        .lhs(a),
        .rhs(b),
        .busy(),
        .done(muldiv_done),
        .result(muldiv_result)
    );

    wire [31:0] seq_pc = pc + (compressed ? 32'd2 : 32'd4);
    wire [31:0] fetch_address = state == FETCH_HIGH ? {pc[31:2] + 30'd1, 2'b00} : {pc[31:2], 2'b00};
    wire [15:0] fetch_half = pc[1] ? rdata[31:16] : rdata[15:0];
    wire [31:0] expanded;

    Decompress decompress (
        .c(fetch_half),
        .instruction(expanded)
    );

    wire data_state = state == MEMORY || state == ATOMIC_READ || state == ATOMIC_WRITE;

    assign valid = !reset && ((state == FETCH && !pc[0]) || state == FETCH_HIGH || data_state);
    assign address = {2'b0, (data_state ? {mem_address[31:2], 2'b0} : fetch_address)};

    assign write = (state == MEMORY && mem_write) || state == ATOMIC_WRITE;
    assign wdata = mem_wdata;
    assign wstrb = write ? mem_wstrb : 4'b0;

    assign kind = state == FETCH || state == FETCH_HIGH ? 2'd1 : 2'd0;

    assign access_address = data_state ? mem_address : fetch_address;
    assign access_size = state == MEMORY ? mem_funct3[1:0] : 2'd2;
    assign access_rmw = (state == ATOMIC_READ || state == ATOMIC_WRITE) && atomic_operation != 2 && atomic_operation != 3;
    assign access_atomic = state == ATOMIC_READ || state == ATOMIC_WRITE;
    assign access_sc = state == ATOMIC_WRITE && atomic_operation == 3;

    assign trap_valid = !reset && state == TRAP;
    assign csr_valid = !reset && state == EXECUTE && csr_op;
    assign csr_commit = csr_valid && !csr_illegal;
    assign csr_address = instruction[31:20];
    assign csr_operation = funct3;
    assign csr_source = funct3[2] ? {27'd0, rs1} : a;
    assign csr_source_zero = rs1 == 0;
    assign system_valid = !reset && state == EXECUTE && decoded_system != 0;
    assign system_commit = system_valid && !system_illegal;
    assign system_operation = decoded_system;

    always @(*) begin
        illegal = 0;
        reg_write = 0;
        memory_op = 0;
        store = 0;
        jump = 0;
        branch_taken = 0;
        ecall = 0;
        ebreak = 0;
        muldiv_op = 0;
        atomic = 0;
        csr_op = 0;
        decoded_system = 0;
        result = 0;
        next_pc = seq_pc;
        effective_address = 0;

        case (instruction[6:0])
            7'h37: begin
                reg_write = 1;
                result = imm_u;
            end

            7'h17: begin
                reg_write = 1;
                result = pc_sum;
            end

            7'h6f: begin
                reg_write = 1;
                result = seq_pc;
                next_pc = pc_sum;
                jump = 1;
            end

            7'h67: begin
                if (funct3 != 0) begin
                    illegal = 1;
                end

                reg_write = 1;
                result = seq_pc;
                next_pc = data_sum & 32'hfffffffe;
                jump = 1;
            end

            7'h63: begin
                case (funct3)
                    0: branch_taken = a == b;
                    1: branch_taken = a != b;
                    4: branch_taken = $signed(a) < $signed(b);
                    5: branch_taken = $signed(a) >= $signed(b);
                    6: branch_taken = a < b;
                    7: branch_taken = a >= b;
                    default: illegal = 1;
                endcase

                if (branch_taken) begin
                    next_pc = pc_sum;
                    jump = 1;
                end
            end

            7'h03: begin
                memory_op = 1;
                effective_address = data_sum;
                if (funct3 != 0 && funct3 != 1 && funct3 != 2 && funct3 != 4 && funct3 != 5) begin
                    illegal = 1;
                end
            end

            7'h23: begin
                memory_op = 1;
                store = 1;
                effective_address = data_sum;
                if (funct3 > 2) begin
                    illegal = 1;
                end
            end

            7'h2f: begin
                atomic = 1;
                effective_address = a;
                if (funct3 != 2) begin
                    illegal = 1;
                end

                case (instruction[31:27])
                    0, 1, 3, 4, 8, 12, 16, 20, 24, 28: ;

                    2: begin
                        if (rs2 != 0) begin
                            illegal = 1;
                        end
                    end

                    default: illegal = 1;
                endcase
            end

            7'h13: begin
                reg_write = 1;
                case (funct3)
                    0: result = data_sum;
                    2: result = $signed(a) < $signed(imm_i);
                    3: result = a < imm_i;
                    4: result = a ^ imm_i;
                    6: result = a | imm_i;
                    7: result = a & imm_i;

                    1: begin
                        result = shift_result;
                        if (funct7 != 0) begin
                            illegal = 1;
                        end
                    end

                    5: begin
                        if (funct7 == 0) begin
                            result = shift_result;
                        end else if (funct7 == 7'h20) begin
                            result = shift_result;
                        end else begin
                            illegal = 1;
                        end
                    end
                endcase
            end

            7'h33: begin
                reg_write = 1;
                if (funct7 == 1) begin
                    muldiv_op = 1;
                end else begin
                    case (funct3)
                        0: begin
                            if (funct7 == 0) begin
                                result = data_sum;
                            end else if (funct7 == 7'h20) begin
                                result = data_sum;
                            end else begin
                                illegal = 1;
                            end
                        end

                        1: result = shift_result;
                        2: result = $signed(a) < $signed(b);
                        3: result = a < b;
                        4: result = a ^ b;

                        5: begin
                            if (funct7 == 0) begin
                                result = shift_result;
                            end else if (funct7 == 7'h20) begin
                                result = shift_result;
                            end else begin
                                illegal = 1;
                            end
                        end

                        6: result = a | b;
                        7: result = a & b;
                    endcase

                    if (funct3 != 0 && funct3 != 5 && funct7 != 0) begin
                        illegal = 1;
                    end
                end
            end

            7'h0f: begin
                if (funct3 != 0 && funct3 != 1) begin
                    illegal = 1;
                end
            end

            7'h73: begin
                if (instruction == 32'h00000073) begin
                    ecall = 1;
                end else if (instruction == 32'h00100073) begin
                    ebreak = 1;
                end else if (funct3 == 1 || funct3 == 2 || funct3 == 3 || funct3 == 5 || funct3 == 6 || funct3 == 7) begin
                    csr_op = 1;
                end else if (instruction == 32'h30200073) begin
                    decoded_system = 1;  // MRET
                end else if (instruction == 32'h10200073) begin
                    decoded_system = 2;  // SRET
                end else if (instruction == 32'h10500073) begin
                    decoded_system = 3;  // WFI
                end else if (instruction[31:25] == 7'h09 && funct3 == 0 && rd == 0) begin
                    decoded_system = 4;  // SFENCE.VMA
                end else begin
                    illegal = 1;
                end
            end

            default: illegal = 1;
        endcase
    end

    always @(*) begin
        case (atomic_operation)
            0: atomic_updated = rdata + mem_wdata;
            1: atomic_updated = mem_wdata;
            4: atomic_updated = rdata ^ mem_wdata;
            8: atomic_updated = rdata | mem_wdata;
            12: atomic_updated = rdata & mem_wdata;
            16: atomic_updated = $signed(rdata) < $signed(mem_wdata) ? rdata : mem_wdata;
            20: atomic_updated = $signed(rdata) > $signed(mem_wdata) ? rdata : mem_wdata;
            24: atomic_updated = rdata < mem_wdata ? rdata : mem_wdata;
            28: atomic_updated = rdata > mem_wdata ? rdata : mem_wdata;
            default: atomic_updated = mem_wdata;
        endcase
    end

    always @(*) begin
        case (mem_funct3)
            0: load_result = {{24{shifted_read[7]}}, shifted_read[7:0]};
            1: load_result = {{16{shifted_read[15]}}, shifted_read[15:0]};
            2: load_result = rdata;
            4: load_result = {24'b0, shifted_read[7:0]};
            5: load_result = {16'b0, shifted_read[15:0]};
            default: load_result = 0;
        endcase
    end

    task raise_trap(input [4:0] cause, input [31:0] value);
        begin
            state <= TRAP;
            trap_interrupt <= 0;
            trap_cause <= cause;
            trap_pc <= pc;
            trap_value <= value;
            reservation_valid <= 0;
        end
    endtask

    task retire(input [31:0] new_pc, input wr, input [4:0] dest, input [31:0] value);
        begin
            if (wr && dest != 0) begin
                registers[dest] <= value;
            end

            pc <= new_pc;
            state <= BOUNDARY;
            retire_valid <= 1;
            retire_pc <= pc;
            retire_instruction <= instruction;
            retire_rd <= wr ? dest : 0;
            retire_data <= wr && dest != 0 ? value : 0;
        end
    endtask

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= BOUNDARY;
            pc <= RESET_PC;
            instruction <= 32'h00000013;
            raw_instruction <= 32'h00000013;
            compressed <= 0;
            fetch_low <= 0;
            mem_address <= 0;
            mem_wdata <= 0;
            mem_wstrb <= 0;
            mem_next_pc <= 0;
            mem_rd <= 0;
            mem_funct3 <= 0;
            mem_write <= 0;
            reservation_valid <= 0;
            reservation_address <= 0;
            atomic_old <= 0;
            atomic_operation <= 0;
            previous_privilege <= 3;
            sc_reserved_valid <= 0;
            sc_reserved_address <= 0;
            trap_interrupt <= 0;
            trap_cause <= 0;
            trap_pc <= 0;
            trap_value <= 0;
            retire_valid <= 0;
            retire_pc <= 0;
            retire_instruction <= 0;
            retire_rd <= 0;
            retire_data <= 0;
            for (i = 0; i < 32; i = i + 1) begin
                registers[i] <= 0;
            end
        end else begin
            retire_valid <= 0;
            registers[0] <= 0;

            case (state)
                BOUNDARY: begin
                    if (interrupt_pending) begin
                        state <= TRAP;
                        trap_interrupt <= 1;
                        trap_cause <= interrupt_cause;
                        trap_pc <= pc;
                        trap_value <= 0;
                        reservation_valid <= 0;
                    end else begin
                        state <= FETCH;
                    end
                end

                FETCH: begin
                    if (pc[0]) begin
                        raise_trap(0, pc);
                    end else if (ready) begin
                        if (error) begin
                            raise_trap(page_fault ? 12 : 1, pc);
                        end else if (fetch_half[1:0] != 2'b11) begin
                            instruction <= expanded;
                            raw_instruction <= {16'd0, fetch_half};
                            compressed <= 1;
                            state <= EXECUTE;
                        end else if (pc[1]) begin
                            fetch_low <= fetch_half;
                            state <= FETCH_HIGH;
                        end else begin
                            instruction <= rdata;
                            raw_instruction <= rdata;
                            compressed <= 0;
                            state <= EXECUTE;
                        end
                    end
                end

                FETCH_HIGH: begin
                    if (ready) begin
                        if (error) begin
                            raise_trap(page_fault ? 12 : 1, {pc[31:2] + 30'd1, 2'b00});
                        end else begin
                            instruction <= {rdata[15:0], fetch_low};
                            raw_instruction <= {rdata[15:0], fetch_low};
                            compressed <= 0;
                            state <= EXECUTE;
                        end
                    end
                end

                EXECUTE: begin
                    if (illegal) begin
                        raise_trap(2, raw_instruction);
                    end else if (csr_op && csr_illegal) begin
                        raise_trap(2, raw_instruction);
                    end else if (decoded_system != 0 && system_illegal) begin
                        raise_trap(2, raw_instruction);
                    end else if (csr_op) begin
                        retire(next_pc, 1, rd, csr_rdata);
                    end else if (decoded_system != 0) begin
                        if (decoded_system == 1 || decoded_system == 2) begin
                            reservation_valid <= 0;
                            retire(return_pc, 0, 0, 0);
                        end else begin
                            if (decoded_system == 4) begin
                                reservation_valid <= 0;
                            end

                            retire(next_pc, 0, 0, 0);
                        end
                    end else if (ecall) begin
                        raise_trap(privilege == 0 ? 8 : privilege == 1 ? 9 : 11, 0);
                    end else if (ebreak) begin
                        raise_trap(3, pc);
                    end else if (muldiv_op) begin
                        state <= MULDIV;
                    end else if (atomic) begin
                        if (effective_address[1:0] != 0) begin
                            raise_trap(is_lr ? 4 : 6, effective_address);
                        end else begin
                            mem_address <= effective_address;
                            mem_wdata <= b;
                            mem_wstrb <= 15;
                            mem_rd <= rd;
                            mem_next_pc <= next_pc;
                            atomic_operation <= instruction[31:27];

                            if (is_sc) begin
                                sc_reserved_valid <= reservation_valid;
                                sc_reserved_address <= reservation_address;
                                reservation_valid <= 0;
                                state <= ATOMIC_WRITE;
                            end else begin
                                state <= ATOMIC_READ;
                            end
                        end
                    end else if (memory_op) begin
                        if (store) begin
                            reservation_valid <= 0;
                        end

                        if ((funct3[1:0] == 1 && effective_address[0]) || (funct3[1:0] == 2 && effective_address[1:0] != 0)) begin
                            raise_trap(store ? 6 : 4, effective_address);
                        end else begin
                            mem_address <= effective_address;
                            mem_wdata <= b << {effective_address[1:0], 3'b0};
                            mem_wstrb <= (funct3 == 0 ? 4'b0001 : funct3 == 1 ? 4'b0011 : 4'b1111) << effective_address[1:0];
                            mem_funct3 <= funct3;
                            mem_rd <= rd;
                            mem_write <= store;
                            mem_next_pc <= next_pc;
                            state <= MEMORY;
                        end
                    end else begin
                        retire(next_pc, reg_write, rd, result);
                    end
                end

                MEMORY: begin
                    if (ready) begin
                        if (error) begin
                            raise_trap(page_fault ? (mem_write ? 15 : 13) : (mem_write ? 7 : 5), mem_address);
                        end else begin
                            retire(mem_next_pc, !mem_write, mem_rd, load_result);
                        end
                    end
                end

                TRAP: begin
                    if (trap_ready) begin
                        pc <= trap_vector;
                        state <= BOUNDARY;
                    end
                end

                MULDIV: begin
                    if (muldiv_done) begin
                        retire(seq_pc, 1, rd, muldiv_result);
                    end
                end

                ATOMIC_READ: begin
                    if (ready) begin
                        if (error) begin
                            raise_trap(page_fault ? (atomic_operation == 2 ? 13 : 15) : (atomic_operation == 2 ? 5 : 7), mem_address);
                        end else if (atomic_operation == 2) begin
                            reservation_valid <= 1;
                            reservation_address <= {translated_address[33:2], 2'b0};
                            retire(mem_next_pc, 1, mem_rd, rdata);
                        end else begin
                            reservation_valid <= 0;
                            atomic_old <= rdata;
                            mem_wdata <= atomic_updated;
                            state <= ATOMIC_WRITE;
                        end
                    end
                end

                ATOMIC_WRITE: begin
                    if (ready) begin
                        if (error) begin
                            raise_trap(page_fault ? 15 : 7, mem_address);
                        end else begin
                            retire(mem_next_pc, 1, mem_rd, atomic_operation == 3 ? (sc_success ? 0 : 1) : atomic_old);
                        end
                    end
                end
            endcase

            previous_privilege <= privilege;
            if (clear_reservation || privilege != previous_privilege) begin
                reservation_valid <= 0;
            end
        end
    end
endmodule

module Mmu #(
    parameter TLB_ENTRIES = 2048,
    parameter MEM_WORDS = 8192
) (
    input clk,
    input reset,
    input tlb_flush,
    input req_valid,
    input [31:0] req_address,
    input [1:0] req_size,
    input req_write,
    input [31:0] req_wdata,
    input [3:0] req_wstrb,
    input [1:0] req_kind,
    input req_rmw,
    input req_atomic,
    input req_sc,
    input sc_reserved_valid,
    input [33:0] sc_reserved_address,
    input [1:0] req_privilege,
    input [31:0] satp,
    input sum,
    input mxr,
    input [63:0] pmp_configuration,
    input [255:0] pmp_addresses,
    output req_ready,
    output reg [31:0] req_rdata,
    output reg req_error,
    output reg req_page_fault,
    output reg sc_success,
    output [33:0] translated_address,
    output valid,
    output [33:0] address,
    output write,
    output [31:0] wdata,
    output [3:0] wstrb,
    output [1:0] kind,
    input ready,
    input [31:0] rdata,
    input error
);
    localparam IDLE = 0;
    localparam WALK_CHECK = 1;
    localparam WALK = 2;
    localparam ACCESS_CHECK = 3;
    localparam ACCESS = 4;
    localparam RESPONSE = 5;
    localparam TLB_LOOKUP = 6;

    reg [2:0] state;
    reg [31:0] va;
    reg [31:0] data;
    reg [33:0] pa;
    reg [33:0] pte_address;
    reg [33:0] reserved_address;
    reg [1:0] size;
    reg [1:0] mode;
    reg [1:0] access_kind;
    reg [3:0] strobes;

    reg store;
    reg rmw;
    reg atomic;
    reg sc;
    reg reserved_valid;
    reg permit_sum;
    reg permit_mxr;
    reg level;

    wire fetch = access_kind == 1;
    wire needs_write = store || rmw || sc;
    wire leaf = rdata[1] || rdata[3];
    wire pte_invalid = !rdata[0] || (!rdata[1] && rdata[2]);

    function page_denied(input [7:0] flags, input [1:0] privilege_mode, input instruction_access, input write_needed, input read_needed,
                         input allow_user_data, input allow_execute_read);
        begin
            page_denied = (privilege_mode == 0 && !flags[4]) ||
                (privilege_mode == 1 && flags[4] && (instruction_access || !allow_user_data)) ||
                (instruction_access ? !flags[3] :
                    ((write_needed && !flags[2]) ||
                     (read_needed && !(flags[1] || (allow_execute_read && flags[3]))))) ||
                !flags[6] || (write_needed && !flags[7]);
        end
    endfunction

    wire leaf_fault = page_denied(rdata[7:0], mode, fetch, needs_write, !store || rmw, permit_sum, permit_mxr) ||
        (level && rdata[19:10] != 0);

    localparam TLB_STORAGE = TLB_ENTRIES > 0 ? TLB_ENTRIES : 1;
    localparam TLB_INDEX_BITS = TLB_ENTRIES > 1 ? $clog2(TLB_ENTRIES) : 1;
    localparam [31:0] TLB_LAST_INDEX = TLB_STORAGE - 1;

    (* ram_style = "block", syn_ramstyle = "block_ram" *) reg [63:0] tlb_mem[0:TLB_STORAGE-1];
    reg [63:0] tlb_record;
    reg [13:0] tlb_generation;
    reg tlb_clearing;
    reg [TLB_INDEX_BITS-1:0] tlb_clear_index;

    reg [31:0] cached_satp;
    reg [31:0] walk_satp;
    reg discard_fill;
    wire invalidate = tlb_flush || cached_satp != satp;

    function [TLB_INDEX_BITS-1:0] cache_index(input [19:0] vpn);
        reg [31:0] index_value;
        begin
            index_value = {12'd0, vpn} % TLB_STORAGE;
            cache_index = index_value[TLB_INDEX_BITS-1:0];
        end
    endfunction

    wire [TLB_INDEX_BITS-1:0] lookup_index = cache_index(req_address[31:12]);
    wire [TLB_INDEX_BITS-1:0] fill_index = cache_index(va[31:12]);
    wire [21:0] leaf_ppn = level ? {rdata[31:20], va[21:12]} : rdata[31:10];
    wire fill = TLB_ENTRIES > 0 && state == WALK && ready && !error &&
        !pte_invalid && leaf && !leaf_fault && !invalidate &&
        !discard_fill && !tlb_clearing && walk_satp == satp;

    always @(posedge clk) begin
        if (!reset && !tlb_clearing && state == IDLE && req_valid && TLB_ENTRIES > 0) begin
            tlb_record <= tlb_mem[lookup_index];
        end
        if (!reset && tlb_clearing) begin
            tlb_mem[tlb_clear_index] <= 64'd0;
        end else if (!reset && fill) begin
            tlb_mem[fill_index] <= {tlb_generation, va[31:12], leaf_ppn, rdata[7:0]};
        end
    end

    wire tlb_hit = TLB_ENTRIES > 0 && !tlb_clearing && !invalidate &&
        !discard_fill && walk_satp == satp &&
        tlb_record[63:50] == tlb_generation && tlb_record[49:30] == va[31:12];
    wire [33:0] hit_address = {tlb_record[29:8], va[11:0]};
    wire hit_denied = page_denied(tlb_record[7:0], mode, fetch, needs_write,
                                 !store || rmw, permit_sum, permit_mxr);

    wire pmp_allowed;

    function is_ram(input [33:0] a);
        is_ram = a[33:32] == 0 && (a < MEM_WORDS * 4 || (a >= 34'h040000000 && a < 34'h048000000));
    endfunction

    wire walk_denied = !pmp_allowed || !is_ram(pte_address);
    wire access_denied = !pmp_allowed || (atomic && !is_ram(pa));
    wire sc_failed = sc && (!reserved_valid || reserved_address != {pa[33:2], 2'b0});

    PmpCheck protection (
        .configuration(pmp_configuration),
        .addresses(pmp_addresses),
        .address(state == WALK_CHECK ? pte_address : pa),
        .size(state == WALK_CHECK ? 2'd2 : size),
        .privilege(state == WALK_CHECK ? 2'd1 : mode),
        .execute(state != WALK_CHECK && fetch),
        .read_access(state == WALK_CHECK || (!fetch && (!store || rmw))),
        .write_access(state != WALK_CHECK && needs_write),
        .allowed(pmp_allowed)
    );

    assign req_ready = !reset && state == RESPONSE && req_valid;
    assign translated_address = pa;
    assign valid = !reset && (state == WALK || state == ACCESS);
    assign address = state == WALK ? pte_address : {pa[33:2], 2'b0};
    assign write = state == ACCESS && store;
    assign wdata = data;
    assign wstrb = write ? strobes : 4'd0;
    assign kind = state == WALK ? 2'd2 : access_kind;

    task fault(input page);
        begin
            req_error <= 1;
            req_page_fault <= page;
            sc_success <= 0;
            state <= RESPONSE;
        end
    endtask

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            va <= 0;
            pa <= 0;
            data <= 0;
            size <= 0;
            mode <= 3;
            pte_address <= 0;
            reserved_address <= 0;
            reserved_valid <= 0;
            access_kind <= 0;
            strobes <= 0;
            store <= 0;
            rmw <= 0;
            atomic <= 0;
            sc <= 0;
            permit_sum <= 0;
            permit_mxr <= 0;
            level <= 1;
            req_rdata <= 0;
            req_error <= 0;
            req_page_fault <= 0;
            sc_success <= 0;
            tlb_generation <= 14'd1;
            tlb_clearing <= TLB_ENTRIES > 0;
            tlb_clear_index <= 0;
            cached_satp <= 0;
            walk_satp <= 0;
            discard_fill <= 0;
        end else begin
            cached_satp <= satp;

            if (tlb_clearing) begin
                if (tlb_clear_index == TLB_LAST_INDEX[TLB_INDEX_BITS-1:0]) begin
                    tlb_clearing <= 0;
                    tlb_clear_index <= 0;
                end else begin
                    tlb_clear_index <= tlb_clear_index + 1'b1;
                end
            end

            if (invalidate) begin
                if (TLB_ENTRIES > 0 && !tlb_clearing) begin
                    if (&tlb_generation) begin
                        tlb_generation <= 14'd1;
                        tlb_clearing <= 1;
                        tlb_clear_index <= 0;
                    end else begin
                        tlb_generation <= tlb_generation + 1'b1;
                    end
                end
                if (state != IDLE) begin
                    discard_fill <= 1;
                end
            end

            case (state)
                IDLE: begin
                    if (req_valid && !tlb_clearing) begin
                        va <= req_address;
                        size <= req_size;
                        store <= req_write;
                        data <= req_wdata;
                        strobes <= req_wstrb;
                        access_kind <= req_kind;
                        rmw <= req_rmw;
                        atomic <= req_atomic;
                        sc <= req_sc;
                        reserved_valid <= sc_reserved_valid;
                        reserved_address <= sc_reserved_address;
                        walk_satp <= satp;
                        discard_fill <= 0;
                        mode <= req_privilege;
                        permit_sum <= sum;
                        permit_mxr <= mxr;
                        req_rdata <= 0;
                        req_error <= 0;
                        req_page_fault <= 0;
                        sc_success <= 0;

                        if (req_privilege == 3 || !satp[31]) begin
                            pa <= {2'd0, req_address};
                            state <= ACCESS_CHECK;
                        end else if (TLB_ENTRIES > 0) begin
                            state <= TLB_LOOKUP;
                        end else begin
                            pte_address <= {satp[21:0], 12'd0} + {22'd0, req_address[31:22], 2'd0};
                            level <= 1;
                            state <= WALK_CHECK;
                        end
                    end
                end

                TLB_LOOKUP: begin
                    if (tlb_hit) begin
                        pa <= hit_address;
                        if (hit_denied) begin
                            fault(1);
                        end else begin
                            state <= ACCESS_CHECK;
                        end
                    end else begin
                        pte_address <= {walk_satp[21:0], 12'd0} + {22'd0, va[31:22], 2'd0};
                        level <= 1;
                        state <= WALK_CHECK;
                    end
                end

                WALK_CHECK: begin
                    if (walk_denied) begin
                        fault(0);
                    end else begin
                        state <= WALK;
                    end
                end

                WALK: begin
                    if (ready) begin
                        if (error) begin
                            fault(0);
                        end else if (pte_invalid) begin
                            fault(1);
                        end else if (leaf) begin
                            if (leaf_fault) begin
                                fault(1);
                            end else begin
                                pa <= level ? {rdata[31:20], va[21:0]} : {rdata[31:10], va[11:0]};
                                state <= ACCESS_CHECK;
                            end
                        end else if (!level || rdata[7:6] != 0 || rdata[4]) begin
                            fault(1);
                        end else begin
                            pte_address <= {rdata[31:10], 12'd0} + {22'd0, va[21:12], 2'd0};
                            level <= 0;
                            state <= WALK_CHECK;
                        end
                    end
                end

                ACCESS_CHECK: begin
                    if (access_denied) begin
                        fault(0);
                    end else if (sc_failed) begin
                        sc_success <= 0;
                        state <= RESPONSE;
                    end else begin
                        state <= ACCESS;
                    end
                end

                ACCESS: begin
                    if (ready) begin
                        if (error) begin
                            fault(0);
                        end else begin
                            req_rdata <= rdata;
                            sc_success <= sc;
                            state <= RESPONSE;
                        end
                    end
                end

                RESPONSE: begin
                    if (req_valid) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule

module MulDiv (
    input clk,
    input reset,
    input start,
    input [2:0] operation,
    input [31:0] lhs,
    input [31:0] rhs,
    output reg busy,
    output reg done,
    output reg [31:0] result
);
    reg [2:0] op;
    reg [5:0] count;

    reg negate_product;
    reg negate_quotient;
    reg negate_remainder;

    reg [63:0] accumulator;
    reg [63:0] multiplicand;
    reg [31:0] multiplier;
    reg [31:0] dividend;
    reg [31:0] divisor;
    reg [31:0] quotient;
    reg [32:0] remainder;

    wire signed_lhs = operation == 1 || operation == 2 || operation == 4 || operation == 6;
    wire signed_rhs = operation == 1 || operation == 4 || operation == 6;

    wire [31:0] abs_lhs = signed_lhs && lhs[31] ? (~lhs + 32'd1) : lhs;
    wire [31:0] abs_rhs = signed_rhs && rhs[31] ? (~rhs + 32'd1) : rhs;
    wire [63:0] sum = accumulator + (multiplier[0] ? multiplicand : 64'd0);
    wire [63:0] product = negate_product ? (~sum + 64'd1) : sum;
    wire [32:0] shifted_remainder = {remainder[31:0], dividend[31]};

    wire subtract = shifted_remainder >= {1'b0, divisor};

    wire [32:0] next_remainder = subtract ? shifted_remainder - {1'b0, divisor} : shifted_remainder;
    wire [31:0] next_quotient = {quotient[30:0], subtract};
    wire [31:0] signed_quotient = negate_quotient ? (~next_quotient + 32'd1) : next_quotient;
    wire [31:0] signed_remainder = negate_remainder ? (~next_remainder[31:0] + 32'd1) : next_remainder[31:0];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0;
            done <= 0;
            result <= 0;
            op <= 0;
            count <= 0;
            negate_product <= 0;
            negate_quotient <= 0;
            negate_remainder <= 0;
            accumulator <= 0;
            multiplicand <= 0;
            multiplier <= 0;
            dividend <= 0;
            divisor <= 0;
            quotient <= 0;
            remainder <= 0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                op <= operation;
                count <= 0;
                negate_product <= (signed_lhs && lhs[31]) ^ (signed_rhs && rhs[31]);
                negate_quotient <= signed_lhs && (lhs[31] ^ rhs[31]);
                negate_remainder <= signed_lhs && lhs[31];
                accumulator <= 0;
                multiplicand <= {32'd0, abs_lhs};
                multiplier <= abs_rhs;
                dividend <= abs_lhs;
                divisor <= abs_rhs;
                quotient <= 0;
                remainder <= 0;
                if (operation[2] && rhs == 0) begin
                    result <= operation[1] ? lhs : 32'hffffffff;
                    done <= 1;
                end else begin
                    busy <= 1;
                end
            end else if (busy) begin
                count <= count + 1;
                if (!op[2]) begin
                    accumulator <= sum;
                    multiplicand <= multiplicand << 1;
                    multiplier <= multiplier >> 1;
                    if (count == 31) begin
                        result <= op == 0 ? product[31:0] : product[63:32];
                    end
                end else begin
                    remainder <= next_remainder;
                    quotient <= next_quotient;
                    dividend <= dividend << 1;
                    if (count == 31) begin
                        result <= op[1] ? signed_remainder : signed_quotient;
                    end
                end
                if (count == 31) begin
                    busy <= 0;
                    done <= 1;
                end
            end
        end
    end
endmodule

module PmpRegisters (
    input clk,
    input reset,
    input [11:0] address,
    input write_enable,
    input [31:0] write_data,
    output reg known,
    output reg [31:0] read_data,
    output [63:0] configuration,
    output [255:0] addresses
);
    reg [7:0] cfg[0:7];
    reg [31:0] addr[0:7];
    integer i;
    integer j;
    genvar n;

    generate
        for (n = 0; n < 8; n = n + 1) begin : packed_entries
            assign configuration[n*8 +: 8] = cfg[n];
            assign addresses[n*32 +: 32] = addr[n];
        end
    endgenerate

    function [7:0] normalize(input [7:0] v);
        begin
            normalize = v & 8'h9f;
            if (v[1:0] == 2'b10) begin
                normalize[1] = 0;  // W without R is reserved
            end
        end
    endfunction

    always @(*) begin
        known = 0;
        read_data = 0;
        if (address == 12'h3a0 || address == 12'h3a1) begin
            known = 1;
            for (j = 0; j < 4; j = j + 1) begin
                read_data[j*8 +: 8] = cfg[(address == 12'h3a1 ? 4 : 0)+j];
            end
        end

        if (address == 12'h3a2 || address == 12'h3a3 || (address >= 12'h3b8 && address <= 12'h3bf)) begin
            known = 1; 
        end

        for (j = 0; j < 8; j = j + 1) begin
            if (address == 12'h3b0 + j) begin
                known = 1;
                read_data = addr[j];
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 8; i = i + 1) begin
                cfg[i] <= 0;
                addr[i] <= 0;
            end
        end else if (write_enable) begin
            for (i = 0; i < 8; i = i + 1) begin
                if (!cfg[i][7]) begin
                    if (address == 12'h3a0 + i / 4) begin
                        cfg[i] <= normalize(write_data[(i%4)*8 +: 8]);
                    end

                    if (address == 12'h3b0 + i) begin
                        if (i == 7) begin
                            addr[i] <= write_data;
                        end else if (!(cfg[i+1][7] && cfg[i+1][4:3] == 1)) begin
                            addr[i] <= write_data;
                        end
                    end
                end
            end
        end
    end
endmodule

module PmpCheck (
    input [63:0] configuration,
    input [255:0] addresses,
    input [33:0] address,
    input [1:0] size,
    input [1:0] privilege,
    input execute,
    input read_access,
    input write_access,
    output reg allowed
);
    integer entry;
    reg found;

    wire [35:0] napot_mask[0:7];
    genvar region;
    genvar mask_bit;

    generate
        for (region = 0; region < 8; region = region + 1) begin : napot_masks
            assign napot_mask[region][2:0] = 3'b111;
            assign napot_mask[region][35] = 1'b0;
            for (mask_bit = 3; mask_bit < 35; mask_bit = mask_bit + 1) begin : prefix
                assign napot_mask[region][mask_bit] = &addresses[region*32 +: mask_bit-2];
            end
        end
    endgenerate

    reg [7:0] cfg;
    reg [31:0] encoded;
    reg [35:0] lower;
    reg [35:0] upper;
    reg [35:0] first_byte;
    reg [35:0] end_byte;

    always @(*) begin
        allowed = privilege == 3;
        found = 0;
        cfg = 0;
        encoded = 0;
        lower = 0;
        upper = 0;
        first_byte = {2'd0, address};
        end_byte = first_byte + (36'd1 << size);

        for (entry = 0; entry < 8; entry = entry + 1) begin
            cfg = configuration[entry*8 +: 8];
            encoded = addresses[entry*32 +: 32];
            lower = 0;
            upper = 0;

            case (cfg[4:3])
                1: begin
                    if (entry != 0) begin
                        lower = {2'd0, addresses[(entry-1)*32 +: 32], 2'd0};
                    end

                    upper = {2'd0, encoded, 2'd0};
                end

                2: begin
                    lower = {2'd0, encoded, 2'd0};
                    upper = lower + 4;
                end

                3: begin
                    lower = {2'd0, encoded, 2'd0} & ~napot_mask[entry];
                    upper = ({2'd0, encoded, 2'd0} | napot_mask[entry]) + 36'd1;
                end

                default: ;
            endcase

            if (!found && cfg[4:3] != 0 && lower < upper && first_byte < upper && end_byte > lower) begin
                found = 1;
                allowed = first_byte >= lower && end_byte <= upper &&
                    ((privilege == 3 && !cfg[7]) ||
                     ((!execute || cfg[2]) && (!read_access || cfg[0]) && (!write_access || cfg[1])));
            end
        end

        if (size == 3 || privilege == 2) begin
            allowed = 0;
        end
    end
endmodule

module Clint #(
    parameter [31:0] BASE_ADDRESS = 32'h02000000
) (
    input clk,
    input reset,
    input [31:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    input write_enable,
    output reg [31:0] read_data,
    output irq_software,
    output irq_timer,
    output [63:0] time_value
);
    wire [31:0] word_address = {address[31:2], 2'b00};
    reg msip;
    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    integer lane;

    assign irq_software = msip;
    assign irq_timer = mtime >= mtimecmp;
    assign time_value = mtime;

    always @(*) begin
        case (word_address)
            BASE_ADDRESS: read_data = {31'd0, msip};
            BASE_ADDRESS + 32'h4000: read_data = mtimecmp[31:0];
            BASE_ADDRESS + 32'h4004: read_data = mtimecmp[63:32];
            BASE_ADDRESS + 32'hbff8: read_data = mtime[31:0];
            BASE_ADDRESS + 32'hbffc: read_data = mtime[63:32];
            default: read_data = 0;
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            msip <= 0;
            mtime <= 0;
            mtimecmp <= 64'hffff_ffff_ffff_ffff;
        end else begin
            mtime <= mtime + 64'd1;
            if (write_enable) begin
                if (word_address == BASE_ADDRESS && write_mask[0]) begin
                    msip <= write_data[0];
                end
                
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (write_mask[lane]) begin
                        case (word_address)
                            BASE_ADDRESS + 32'h4000: mtimecmp[lane*8 +: 8] <= write_data[lane*8 +: 8];
                            BASE_ADDRESS + 32'h4004: mtimecmp[32+lane*8 +: 8] <= write_data[lane*8 +: 8];
                            BASE_ADDRESS + 32'hbff8: mtime[lane*8 +: 8] <= write_data[lane*8 +: 8];
                            BASE_ADDRESS + 32'hbffc: mtime[32+lane*8 +: 8] <= write_data[lane*8 +: 8];
                            default: ;
                        endcase
                    end
                end
            end
        end
    end
endmodule

module DdrAdapter #(
    parameter CACHE_BYTES = 4096
) (
    input clk,
    input reset,
    input valid,
    input [33:0] address,
    input write,
    input [31:0] wdata,
    input [3:0] wstrb,
    output ready,
    output [31:0] rdata,
    output error,
    input ddr_clk,
    input ddr_calib,
    input ddr_cmd_ready,
    output [2:0] ddr_cmd,
    output ddr_cmd_en,
    output [27:0] ddr_addr,
    input ddr_wr_data_rdy,
    output [127:0] ddr_wr_data,
    output ddr_wr_data_en,
    output ddr_wr_data_end,
    output [15:0] ddr_wr_data_mask,
    input [127:0] ddr_rd_data,
    input ddr_rd_data_valid
);
    (* async_reg = "true" *) reg [1:0] calib_sync;
    reg cooldown;
    wire done;
    wire bad = address[33:32] != 0 || address[31:0] < 32'h40000000 || address[31:0] >= 32'h48000000 || address[1:0] != 0;

    wire bridge_reset = reset || !calib_sync[1];
    wire start = valid && !bad && !bridge_reset && !cooldown;
    assign ready = valid && !reset && !cooldown && (bad || !calib_sync[1] || done);
    assign error = valid && !reset && (bad || !calib_sync[1]);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            calib_sync <= 0;
            cooldown <= 0;
        end else begin
            calib_sync <= {calib_sync[0], ddr_calib};
            cooldown <= valid && ready;
        end
    end

    wire mem_start;
    wire mem_clear;
    wire mem_write;
    wire [27:0] mem_address;
    wire [31:0] mem_write_data;
    wire [3:0] mem_write_mask;
    wire [127:0] mem_read_line;
    wire mem_done;

    DdrCache #(.CACHE_BYTES(CACHE_BYTES)) cache (
        .clk(clk),
        .reset(bridge_reset),
        .start(start),
        .clear(valid && ready),
        .write(write),
        .address(address[27:0]),
        .write_data(wdata),
        .write_mask(wstrb),
        .read_data(rdata),
        .read_line(),
        .done(done),
        .mem_start(mem_start),
        .mem_clear(mem_clear),
        .mem_write(mem_write),
        .mem_address(mem_address),
        .mem_write_data(mem_write_data),
        .mem_write_mask(mem_write_mask),
        .mem_read_line(mem_read_line),
        .mem_done(mem_done)
    );

    DdrBridge bridge (
        .clk(clk),
        .reset(bridge_reset),
        .start(mem_start),
        .clear(mem_clear),
        .write(mem_write),
        .address(mem_address),
        .write_data(mem_write_data),
        .write_mask(mem_write_mask),
        .read_data(),
        .read_line(mem_read_line),
        .done(mem_done),
        .ddr_clk(ddr_clk),
        .ddr_calib(ddr_calib),
        .ddr_cmd_ready(ddr_cmd_ready),
        .ddr_cmd(ddr_cmd),
        .ddr_cmd_en(ddr_cmd_en),
        .ddr_addr(ddr_addr),
        .ddr_wr_data_rdy(ddr_wr_data_rdy),
        .ddr_wr_data(ddr_wr_data),
        .ddr_wr_data_en(ddr_wr_data_en),
        .ddr_wr_data_end(ddr_wr_data_end),
        .ddr_wr_data_mask(ddr_wr_data_mask),
        .ddr_rd_data(ddr_rd_data),
        .ddr_rd_data_valid(ddr_rd_data_valid)
    );
endmodule

module DdrCache #(
    parameter CACHE_BYTES = 4096
) (
    input clk,
    input reset,

    input start,
    input clear,
    input write,
    input [27:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    output [31:0] read_data,
    output reg [127:0] read_line,
    output reg done,

    output mem_start,
    output mem_clear,
    output mem_write,
    output [27:0] mem_address,
    output [31:0] mem_write_data,
    output [3:0] mem_write_mask,
    input [127:0] mem_read_line,
    input mem_done
);
    localparam LINE_COUNT = CACHE_BYTES / 16;
    localparam INDEX_BITS = $clog2(LINE_COUNT);
    localparam INDEX_WIDTH = INDEX_BITS == 0 ? 1 : INDEX_BITS;
    localparam TAG_BITS = 28 - 4 - INDEX_BITS;

    // synthesis translate_off
    initial begin
        if (CACHE_BYTES < 16 || CACHE_BYTES >= 268435456 ||
            (CACHE_BYTES & (CACHE_BYTES - 1)) != 0) begin
            $fatal(1, "CACHE_BYTES must be a power of two from 16 to 134217728");
        end
    end
    // synthesis translate_on

    reg pending;
    reg lookup_pending;
    reg req_write;
    reg [27:0] req_address;
    reg [31:0] req_data;
    reg [3:0] req_mask;

    reg [LINE_COUNT-1:0] cache_valid;
    wire [127:0] lookup_line;
    reg [TAG_BITS-1:0] lookup_tag;
    reg lookup_valid;

    wire [INDEX_WIDTH-1:0] address_index = INDEX_BITS == 0 ? {INDEX_WIDTH{1'b0}} : address[INDEX_WIDTH+3:4];
    wire [INDEX_WIDTH-1:0] req_index = INDEX_BITS == 0 ? {INDEX_WIDTH{1'b0}} : req_address[INDEX_WIDTH+3:4];
    wire [TAG_BITS-1:0] req_tag = req_address[27:INDEX_BITS+4];

    wire accept = start && !pending && !lookup_pending && !done;
    wire cache_hit = lookup_valid && lookup_tag == req_tag;
    wire cache_fill = pending && mem_done && !req_write;
    wire cache_store = lookup_pending && cache_hit && req_write;

    assign read_data = read_line[req_address[3:2]*32 +: 32];
    assign mem_start = pending;
    assign mem_clear = pending && mem_done;
    assign mem_write = req_write;
    assign mem_address = req_address;
    assign mem_write_data = req_data;
    assign mem_write_mask = req_mask;

    (* ram_style = "block", syn_ramstyle = "block_ram" *) reg [TAG_BITS-1:0] cache_tags [0:LINE_COUNT-1];

    always @(posedge clk) begin
        if (accept) begin
            lookup_tag <= cache_tags[address_index];
        end

        if (cache_fill) begin
            cache_tags[req_index] <= req_tag;
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : banks
            (* ram_style = "block", syn_ramstyle = "block_ram" *) reg [31:0] mem [0:LINE_COUNT-1];
            reg [31:0] lookup_word;

            wire bank_write = cache_fill || (cache_store && req_address[3:2] == bank);
            wire [31:0] store_word = {
                req_mask[3] ? req_data[31:24] : lookup_word[31:24],
                req_mask[2] ? req_data[23:16] : lookup_word[23:16],
                req_mask[1] ? req_data[15:8] : lookup_word[15:8],
                req_mask[0] ? req_data[7:0] : lookup_word[7:0]
            };
            wire [31:0] bank_data = cache_fill ? mem_read_line[bank*32 +: 32] : store_word;

            assign lookup_line[bank*32 +: 32] = lookup_word;

            always @(posedge clk) begin
                if (accept) begin
                    lookup_word <= mem[address_index];
                end

                if (bank_write) begin
                    mem[req_index] <= bank_data;
                end
            end
        end
    endgenerate

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pending <= 0;
            lookup_pending <= 0;
            lookup_valid <= 0;
            cache_valid <= 0;
            done <= 0;
            req_write <= 0;
            req_address <= 0;
            req_data <= 0;
            req_mask <= 0;
            read_line <= 0;
        end else begin
            if (accept) begin
                req_write <= write;
                req_address <= address;
                req_data <= write_data;
                req_mask <= write_mask;
                lookup_valid <= cache_valid[address_index];
                lookup_pending <= 1;
            end

            if (lookup_pending) begin
                lookup_pending <= 0;
                if (!req_write && cache_hit) begin
                    read_line <= lookup_line;
                    done <= 1;
                end else begin
                    pending <= 1;
                end
            end

            if (pending && mem_done) begin
                if (!req_write) begin
                    read_line <= mem_read_line;
                    cache_valid[req_index] <= 1;
                end
                pending <= 0;
                done <= 1;
            end

            if (clear) begin
                done <= 0;
            end
        end
    end
endmodule

module DdrBridge (
    input clk,
    input reset,

    input start,
    input clear,
    input write,
    input [27:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    output [31:0] read_data,
    output reg [127:0] read_line,
    output reg done,

    input ddr_clk,
    input ddr_calib,
    input ddr_cmd_ready,
    output [2:0] ddr_cmd,
    output ddr_cmd_en,
    output [27:0] ddr_addr,
    input ddr_wr_data_rdy,
    output [127:0] ddr_wr_data,
    output ddr_wr_data_en,
    output ddr_wr_data_end,
    output [15:0] ddr_wr_data_mask,
    input [127:0] ddr_rd_data,
    input ddr_rd_data_valid
);
    localparam CMD_WRITE = 3'd0;
    localparam CMD_READ = 3'd1;

    // ----------------------- core domain -----------------------
    reg req_toggle;
    reg pending;
    reg req_write;
    reg [27:0] req_address;
    reg [31:0] req_data;
    reg [3:0] req_mask;

    reg [127:0] ddr_result;
    reg ack_toggle;

    (* async_reg = "true" *) reg [2:0] ack_sync;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            req_toggle <= 0;
            pending <= 0;
            done <= 0;
            req_write <= 0;
            req_address <= 0;
            req_data <= 0;
            req_mask <= 0;
            read_line <= 0;
            ack_sync <= 0;
        end else begin
            ack_sync <= {ack_sync[1:0], ack_toggle};

            if (start && !pending && !done) begin
                req_write <= write;
                req_address <= address;
                req_data <= write_data;
                req_mask <= write_mask;
                req_toggle <= !req_toggle;
                pending <= 1;
            end

            if (pending && (ack_sync[2] != ack_sync[1])) begin
                read_line <= ddr_result;
                pending <= 0;
                done <= 1;
            end

            if (clear) begin
                done <= 0;
            end
        end
    end

    assign read_data = read_line[req_address[3:2]*32 +: 32];

    // ----------------------- DDR domain -----------------------
    wire [26:0] word = req_address[27:1];
    assign ddr_addr = {1'b0, word[12:10], word[26:13], word[9:3], 3'b000};

    wire [1:0] lane = req_address[3:2];
    assign ddr_wr_data = {4{req_data}};
    assign ddr_wr_data_mask = ~({12'd0, req_mask} << {lane, 2'b00});

    (* async_reg = "true" *) reg [2:0] req_sync;
    (* async_reg = "true" *) reg [1:0] ddr_reset_sync;
    wire ddr_reset = ddr_reset_sync[1];

    reg write_pending;
    reg command_pending;
    reg reading;

    assign ddr_cmd = req_write ? CMD_WRITE : CMD_READ;
    assign ddr_cmd_en = command_pending && ddr_calib && ddr_cmd_ready;
    assign ddr_wr_data_en = write_pending && ddr_calib && ddr_wr_data_rdy;
    assign ddr_wr_data_end = ddr_wr_data_en;

    always @(posedge ddr_clk or posedge reset) begin
        if (reset) begin
            ddr_reset_sync <= 2'b11;
        end else begin
            ddr_reset_sync <= {ddr_reset_sync[0], 1'b0};
        end
    end

    always @(posedge ddr_clk) begin
        if (ddr_reset) begin
            req_sync <= 0;
            ack_toggle <= 0;
            write_pending <= 0;
            command_pending <= 0;
            reading <= 0;
            ddr_result <= 0;
        end else begin
            req_sync <= {req_sync[1:0], req_toggle};

            if (req_sync[2] != req_sync[1]) begin
                write_pending <= req_write;
                command_pending <= !req_write;
            end

            if (ddr_wr_data_en) begin
                write_pending <= 0;
                command_pending <= 1;
            end

            if (ddr_cmd_en) begin
                command_pending <= 0;
                if (req_write) begin
                    ack_toggle <= !ack_toggle;
                end else begin
                    reading <= 1;
                end
            end

            if (reading && ddr_rd_data_valid) begin
                ddr_result <= ddr_rd_data;
                reading <= 0;
                ack_toggle <= !ack_toggle;
            end
        end
    end
endmodule

module Gpio #(
    parameter BASE_ADDRESS = 32'h80000000
) (
    input clk,
    input reset,

    input [31:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    input write_enable,
    
    input [31:0] pins_in,
    output [31:0] pins_in_sync,
    output [31:0] irq_rise,
    
    output reg [31:0] pins_out,
    output reg [31:0] pins_oe,
    
    output reg [31:0] read_data
);
    (* async_reg = "true" *) reg [31:0] pins_meta;
    (* async_reg = "true" *) reg [31:0] pins_sync;
    reg [31:0] pins_previous;

    assign pins_in_sync = pins_sync;
    assign irq_rise = pins_sync & ~pins_previous;

    wire oe_enable = (address == BASE_ADDRESS);
    wire rw_enable = (address == BASE_ADDRESS + 4);

    always @* begin
        if (oe_enable) begin
            read_data = pins_oe;
        end else if (rw_enable) begin
            read_data = pins_sync;
        end else begin
            read_data = 0;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pins_meta <= 0;
            pins_sync <= 0;
            pins_previous <= 0;
            pins_out <= 0;
            pins_oe <= 0;
        end else begin
            pins_meta <= pins_in;
            pins_sync <= pins_meta;
            pins_previous <= pins_sync;

            if (write_enable && oe_enable) begin
                if (write_mask[0]) begin
                    pins_oe[7:0] <= write_data[7:0];
                end

                if (write_mask[1]) begin
                    pins_oe[15:8] <= write_data[15:8];
                end

                if (write_mask[2]) begin
                    pins_oe[23:16] <= write_data[23:16];
                end

                if (write_mask[3]) begin
                    pins_oe[31:24] <= write_data[31:24];
                end
            end

            if (write_enable && rw_enable) begin
                if (write_mask[0]) begin
                    pins_out[7:0] <= write_data[7:0];
                end

                if (write_mask[1]) begin
                    pins_out[15:8] <= write_data[15:8];
                end

                if (write_mask[2]) begin
                    pins_out[23:16] <= write_data[23:16];
                end

                if (write_mask[3]) begin
                    pins_out[31:24] <= write_data[31:24];
                end
            end
        end
    end
endmodule
module Platform #(
    parameter MEM_WORDS = 8192,
    parameter MEM_INIT_FILE = "",
    parameter ROM = 0
) (
    input clk,
    input reset,
    input valid,
    input [33:0] address,
    input write,
    input [31:0] wdata,
    input [3:0] wstrb,
    input [1:0] kind,
    output ready,
    output reg [31:0] rdata,
    output error,
    output ddr_valid,
    output [33:0] ddr_address,
    output ddr_write,
    output [31:0] ddr_wdata,
    output [3:0] ddr_wstrb,
    input ddr_ready,
    input [31:0] ddr_rdata,
    input ddr_error,
    input [31:0] gpio_in,
    output [31:0] gpio_out,
    output [31:0] gpio_oe,
    input rx,
    output tx,
    input rx1,
    output tx1,
    output spi0_sclk,
    output spi0_mosi,
    input spi0_miso,
    output spi0_cs_n,
    output spi1_sclk,
    output spi1_mosi,
    input spi1_miso,
    output spi1_cs_n,
    output irq_machine,
    output irq_supervisor,
    output irq_software,
    output irq_timer,
    output [63:0] time_value
);

    wire [31:0] a = address[31:0];

    wire ram_sel = a < MEM_WORDS * 4;
    wire ddr_sel = a >= 32'h40000000 && a < 32'h48000000;
    wire gpio_sel = a >= 32'h80000000 && a < 32'h80000008;
    wire uart0_sel = a >= 32'h80000008 && a < 32'h80000014;
    wire uart1_sel = a >= 32'h80000020 && a < 32'h8000002c;
    wire spi0_sel = a >= 32'h80000040 && a < 32'h80000050;
    wire spi1_sel = a >= 32'h80000060 && a < 32'h80000070;
    wire clint_sel = a >= 32'h02000000 && a < 32'h02010000;
    wire plic_sel = a >= 32'h0c000000 && a < 32'h10000000;

    wire mmio_sel = gpio_sel || uart0_sel || uart1_sel || spi0_sel || spi1_sel || clint_sel || plic_sel;

    wire bad = address[33:32] != 0 || a[1:0] != 0 || kind == 3 ||
               (!ram_sel && !ddr_sel && !mmio_sel) ||
               (kind != 0 && (mmio_sel || write)) || (ROM && ram_sel && write);

    reg ram_read_pending;
    wire [31:0] ram_data;
    wire [31:0] gpio_data;
    wire [31:0] uart0_data;
    wire [31:0] uart1_data;
    wire [31:0] spi0_data;
    wire [31:0] spi1_data;
    wire [31:0] clint_data;
    wire [31:0] plic_data;

    wire uart0_irq;
    wire uart1_irq;
    wire [31:0] gpio_irq;

    wire commit = valid && ready && !error;
    wire wr_commit = commit && write;
    wire rd_commit = commit && !write;

    assign ready = valid && !reset && (bad || (ddr_sel ? ddr_ready : (ram_sel && !write ? ram_read_pending : 1'b1)));
    assign error = valid && !reset && (bad || (ddr_sel && ddr_error));
    assign ddr_valid = valid && !reset && !bad && ddr_sel;
    assign ddr_address = address;
    assign ddr_write = write;
    assign ddr_wdata = wdata;
    assign ddr_wstrb = wstrb;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ram_read_pending <= 0;
        end else if (valid && ready) begin
            ram_read_pending <= 0;
        end else if (valid && !bad && ram_sel && !write) begin
            ram_read_pending <= 1;
        end
    end

    always @(*) begin
        rdata = 0;
        if (!bad) begin
            if (ram_sel) begin
                rdata = ram_data;
            end else if (ddr_sel) begin
                rdata = ddr_rdata;
            end else if (gpio_sel) begin
                rdata = gpio_data;
            end else if (uart0_sel) begin
                rdata = uart0_data;
            end else if (uart1_sel) begin
                rdata = uart1_data;
            end else if (spi0_sel) begin
                rdata = spi0_data;
            end else if (spi1_sel) begin
                rdata = spi1_data;
            end else if (clint_sel) begin
                rdata = clint_data;
            end else if (plic_sel) begin
                rdata = plic_data;
            end
        end
    end

    Sram #(
        .MEM_WORDS(MEM_WORDS),
        .MEM_INIT_FILE(MEM_INIT_FILE)
    ) ram (
        .clk(clk),
        .address(a),
        .read_data(ram_data),
        .read_enable(valid && !reset && !bad && ram_sel && !write && !ram_read_pending),
        .write_enable(wr_commit && ram_sel),
        .write_data(wdata),
        .write_mask(wstrb)
    );

    Gpio gpio (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && gpio_sel),
        .pins_in(gpio_in),
        .pins_in_sync(),
        .irq_rise(gpio_irq),
        .pins_out(gpio_out),
        .pins_oe(gpio_oe),
        .read_data(gpio_data)
    );

    Uart uart0 (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && uart0_sel),
        .read_commit(rd_commit && uart0_sel),
        .rx(rx),
        .tx(tx),
        .rx_valid(uart0_irq),
        .read_data(uart0_data)
    );

    Uart #(
        .BASE_ADDRESS(32'h80000020)
    ) uart1 (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && uart1_sel),
        .read_commit(rd_commit && uart1_sel),
        .rx(rx1),
        .tx(tx1),
        .rx_valid(uart1_irq),
        .read_data(uart1_data)
    );

    Spi spi0 (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && spi0_sel),
        .sclk(spi0_sclk),
        .mosi(spi0_mosi),
        .miso(spi0_miso),
        .cs_n(spi0_cs_n),
        .read_data(spi0_data)
    );

    Spi #(
        .BASE_ADDRESS(32'h80000060)
    ) spi1 (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && spi1_sel),
        .sclk(spi1_sclk),
        .mosi(spi1_mosi),
        .miso(spi1_miso),
        .cs_n(spi1_cs_n),
        .read_data(spi1_data)
    );

    Clint clint (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && clint_sel),
        .read_data(clint_data),
        .irq_software(irq_software),
        .irq_timer(irq_timer),
        .time_value(time_value)
    );
    
    Plic plic (
        .clk(clk),
        .reset(reset),
        .irq_sources({gpio_irq, uart1_irq, uart0_irq}),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && plic_sel),
        .read_commit(rd_commit && plic_sel),
        .read_data(plic_data),
        .irq_machine(irq_machine),
        .irq_supervisor(irq_supervisor)
    );
endmodule

module TinyPlatform (
    input wire clk,
    input wire reset,
    input wire valid,
    input wire [33:0] address,
    input wire write,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    input wire [1:0] kind,
    output wire ready,
    output reg [31:0] rdata,
    output wire error,
    input wire uart_rx,
    output wire uart_tx,
    output wire spi_sclk,
    output wire spi_mosi,
    input wire spi_miso,
    output wire spi_cs_n,
    output wire flash_cs_n,
    output wire ram_a_cs_n,
    output wire ram_b_cs_n,
    output wire mem_sclk,
    output wire mem_mosi,
    input wire mem_miso,
    output wire irq_machine,
    output wire irq_supervisor,
    output wire irq_software,
    output wire irq_timer,
    output wire [63:0] time_value
);
    wire [31:0] a = address[31:0];
    wire flash_sel = a < 32'h01000000;
    wire ram_sel = a >= 32'h40000000 && a < 32'h41000000;
    wire uart_sel = a >= 32'h80000008 && a < 32'h80000014;
    wire spi_sel = a >= 32'h80000040 && a < 32'h80000050;
    wire clint_sel = a >= 32'h02000000 && a < 32'h02010000;
    wire plic_sel = a >= 32'h0c000000 && a < 32'h10000000;

    wire mmio_sel = uart_sel || spi_sel || clint_sel || plic_sel;
    wire mem_sel = flash_sel || ram_sel;
    
    wire bad = address[33:32] != 0 || a[1:0] != 0 || kind == 3 ||
               !(mem_sel || mmio_sel) || (write && flash_sel) ||
               (kind != 0 && (mmio_sel || write));

    wire mem_valid = valid && !reset && !bad && mem_sel;
    wire mem_ready;

    wire [31:0] mem_data;
    wire [31:0] uart_data;
    wire [31:0] spi_data;
    wire [31:0] clint_data;
    wire [31:0] plic_data;
    
    wire uart_irq;
    
    wire commit = valid && ready && !error;
    wire wr_commit = commit && write;
    wire rd_commit = commit && !write;

    assign ready = valid && !reset && (bad || (mem_sel ? mem_ready : 1'b1));
    assign error = valid && !reset && bad;

    always @(*) begin
        rdata = 0;
        if (!bad) begin
            if (mem_sel) begin
                rdata = mem_data;
            end else if (uart_sel) begin 
                rdata = uart_data;
            end else if (spi_sel) begin
                rdata = spi_data;
            end else if (clint_sel) begin
                rdata = clint_data;
            end else if (plic_sel) begin
                rdata = plic_data;
            end
        end
    end

    SerialMemory memory (
        .clk(clk),
        .reset(reset),
        .valid(mem_valid),
        .address(a),
        .write(write),
        .wdata(wdata),
        .wstrb(wstrb),
        .ready(mem_ready),
        .rdata(mem_data),
        .flash_cs_n(flash_cs_n),
        .ram_a_cs_n(ram_a_cs_n),
        .ram_b_cs_n(ram_b_cs_n),
        .sclk(mem_sclk),
        .mosi(mem_mosi),
        .miso(mem_miso)
    );

    Uart uart (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && uart_sel),
        .read_commit(rd_commit && uart_sel),
        .rx(uart_rx),
        .tx(uart_tx),
        .rx_valid(uart_irq),
        .read_data(uart_data)
    );

    Spi spi (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && spi_sel),
        .sclk(spi_sclk),
        .mosi(spi_mosi),
        .miso(spi_miso),
        .cs_n(spi_cs_n),
        .read_data(spi_data)
    );

    Clint clint (
        .clk(clk),
        .reset(reset),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && clint_sel),
        .read_data(clint_data),
        .irq_software(irq_software),
        .irq_timer(irq_timer),
        .time_value(time_value)
    );

    Plic #(.NUM_SOURCES(1)) plic (
        .clk(clk),
        .reset(reset),
        .irq_sources(uart_irq),
        .address(a),
        .write_data(wdata),
        .write_mask(wstrb),
        .write_enable(wr_commit && plic_sel),
        .read_commit(rd_commit && plic_sel),
        .read_data(plic_data),
        .irq_machine(irq_machine),
        .irq_supervisor(irq_supervisor)
    );
endmodule

module Plic #(
    parameter NUM_SOURCES = 34,
    parameter [31:0] BASE_ADDRESS = 32'h0c000000
) (
    input clk,
    input reset,
    input [NUM_SOURCES:1] irq_sources,
    input [31:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    input write_enable,
    input read_commit,
    output reg [31:0] read_data,
    output irq_machine,
    output irq_supervisor
);
    localparam ID_BITS = $clog2(NUM_SOURCES + 1);

    wire [31:0] offset = {address[31:2], 2'b00} - BASE_ADDRESS;
    wire in_range = address >= BASE_ADDRESS && offset < 32'h04000000;

    reg [2:0] priorities[1:NUM_SOURCES];
    reg [NUM_SOURCES:1] enables[0:1];
    reg [2:0] thresholds[0:1];
    reg [NUM_SOURCES:1] pending;
    reg [NUM_SOURCES:1] in_service;
    reg [NUM_SOURCES:1] owner;

    wire [ID_BITS-1:0] selected[0:1];
    localparam TREE_LEAVES = 1 << $clog2(NUM_SOURCES);
    wire [NUM_SOURCES:1] eligible[0:1];

    integer rc;
    integer rs;
    integer wc;
    integer ws;

    assign irq_machine = |eligible[0];
    assign irq_supervisor = |eligible[1];

    genvar context_id;
    genvar node;

    generate
        for (context_id = 0; context_id < 2; context_id = context_id + 1) begin : contexts
            wire [ID_BITS+2:0] winner[1:2*TREE_LEAVES-1];

            for (node = 0; node < TREE_LEAVES; node = node + 1) begin : leaves
                if (node < NUM_SOURCES) begin : source
                    localparam [ID_BITS-1:0] SOURCE_ID = node + 1;

                    assign eligible[context_id][node+1] = pending[node+1] &&
                        !in_service[node+1] && enables[context_id][node+1] &&
                        priorities[node+1] > thresholds[context_id];
                    assign winner[TREE_LEAVES+node] = eligible[context_id][node+1] ? {priorities[node+1], SOURCE_ID} : 0;
                end else begin : padding
                    assign winner[TREE_LEAVES+node] = 0;
                end
            end

            for (node = 1; node < TREE_LEAVES; node = node + 1) begin : branches
                assign winner[node] = winner[2*node][ID_BITS+2:ID_BITS] >= winner[2*node+1][ID_BITS+2:ID_BITS] ?
                    winner[2*node] : winner[2*node+1];
            end

            assign selected[context_id] = winner[1][ID_BITS-1:0];
        end
    endgenerate

    always @(*) begin
        read_data = 0;
        if (in_range) begin
            for (rs = 1; rs <= NUM_SOURCES; rs = rs + 1) begin
                if (offset == rs * 4) begin
                    read_data = {29'd0, priorities[rs]};
                end

                if (offset == 32'h1000 + (rs / 32) * 4) begin
                    read_data[rs % 32] = pending[rs];
                end
            end

            for (rc = 0; rc < 2; rc = rc + 1) begin
                for (rs = 1; rs <= NUM_SOURCES; rs = rs + 1) begin
                    if (offset == 32'h2000 + rc * 32'h80 + (rs / 32) * 4) begin
                        read_data[rs % 32] = enables[rc][rs];
                    end
                end

                if (offset == 32'h200000 + rc * 32'h1000) begin
                    read_data = {29'd0, thresholds[rc]};
                end

                if (offset == 32'h200004 + rc * 32'h1000) begin
                    read_data = selected[rc];
                end
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pending <= 0;
            in_service <= 0;
            owner <= 0;
            for (wc = 0; wc < 2; wc = wc + 1) begin
                enables[wc] <= 0;
                thresholds[wc] <= 0;
            end

            for (ws = 1; ws <= NUM_SOURCES; ws = ws + 1) begin
                priorities[ws] <= 0;
            end
        end else begin
            pending <= pending | (irq_sources & ~in_service);

            if (in_range) begin
                for (wc = 0; wc < 2; wc = wc + 1) begin
                    if (read_commit && offset == 32'h200004 + wc * 32'h1000 && selected[wc] != 0) begin
                        pending[selected[wc]] <= 0;
                        in_service[selected[wc]] <= 1;
                        owner[selected[wc]] <= wc != 0;
                    end

                    if (write_enable) begin
                        if (offset == 32'h200000 + wc * 32'h1000 && write_mask[0]) begin
                            thresholds[wc] <= write_data[2:0];
                        end

                        for (ws = 1; ws <= NUM_SOURCES; ws = ws + 1) begin
                            if (offset == 32'h200004 + wc * 32'h1000 &&
                                write_mask[0] && write_data == ws &&
                                in_service[ws] && owner[ws] == (wc != 0) &&
                                enables[wc][ws]) begin
                                in_service[ws] <= 0;
                            end

                            if (offset == 32'h2000 + wc * 32'h80 + (ws / 32) * 4 && write_mask[(ws % 32) / 8]) begin
                                enables[wc][ws] <= write_data[ws % 32];
                            end
                        end
                    end
                end

                if (write_enable && write_mask[0]) begin
                    for (ws = 1; ws <= NUM_SOURCES; ws = ws + 1) begin
                        if (offset == ws * 4) begin
                            priorities[ws] <= write_data[2:0];
                        end
                    end
                end
            end
        end
    end
endmodule

// Flash: W25Q128JV, 0x00000000-0x00ffffff, read-only.
// PSRAM: two APS6404L chips, 0x40000000-0x40ffffff.
module SerialMemory #(
    parameter STARTUP_CYCLES = 4096
) (
    input wire clk,
    input wire reset,
    input wire valid,
    input wire [31:0] address,
    input wire write,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire ready,
    output wire [31:0] rdata,
    output wire flash_cs_n,
    output wire ram_a_cs_n,
    output wire ram_b_cs_n,
    output wire sclk,
    output wire mosi,
    input wire miso
);
    localparam IDLE = 3'd0;
    localparam SETUP = 3'd1;
    localparam SAMPLE = 3'd2;
    localparam GAP = 3'd3;
    localparam DONE = 3'd4;
    localparam INIT_DONE = 3'd4;

    reg [2:0] state;
    reg [12:0] startup_count;
    reg startup_done;
    reg [2:0] init_step;
    reg is_flash;
    reg bank_b;
    reg req_write;
    reg [23:0] word_offset;
    reg [31:0] write_word;
    reg [3:0] remaining_mask;
    reg [1:0] lane;
    reg [39:0] tx_shift;
    reg [31:0] rx_shift;
    reg [6:0] bit_count;

    function [1:0] first_lane;
        input [3:0] mask;
        begin
            if (mask[0]) begin
                first_lane = 0;
            end else if (mask[1]) begin
                first_lane = 1;
            end else if (mask[2]) begin
                first_lane = 2;
            end else begin
                first_lane = 3;
            end
        end
    endfunction

    wire active = state == SETUP || state == SAMPLE;
    assign flash_cs_n = !(active && is_flash);
    assign ram_a_cs_n = !(active && !is_flash && !bank_b);
    assign ram_b_cs_n = !(active && !is_flash && bank_b);

    assign sclk = state == SAMPLE;
    assign mosi = tx_shift[39];
    assign ready = state == DONE;

    assign rdata = {rx_shift[7:0], rx_shift[15:8], rx_shift[23:16], rx_shift[31:24]};

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            startup_count <= 0;
            startup_done <= 0;
            init_step <= 0;
            is_flash <= 0;
            bank_b <= 0;
            req_write <= 0;
            word_offset <= 0;
            write_word <= 0;
            remaining_mask <= 0;
            lane <= 0;
            tx_shift <= 0;
            rx_shift <= 0;
            bit_count <= 0;
        end else begin
            if (!startup_done) begin
                if (startup_count == STARTUP_CYCLES - 1) begin
                    startup_done <= 1;
                end else begin
                    startup_count <= startup_count + 1'b1;
                end
            end

            case (state)
                IDLE: if (startup_done && init_step != INIT_DONE) begin
                    is_flash <= 0;
                    bank_b <= init_step[1];
                    req_write <= 1;
                    remaining_mask <= 0;
                    tx_shift <= {init_step[0] ? 8'h99 : 8'h66, 32'b0};
                    bit_count <= 32;
                    state <= SETUP;
                end else if (startup_done && valid) begin
                    is_flash <= address[31:24] == 0;
                    bank_b <= address[23];
                    req_write <= write;
                    word_offset <= address[23:0];
                    write_word <= wdata;
                    rx_shift <= 0;
                    bit_count <= 0;

                    if (write) begin
                        if (wstrb == 0) begin
                            state <= DONE;
                        end else begin
                            lane <= first_lane(wstrb);
                            remaining_mask <= wstrb & ~(4'b0001 << first_lane(wstrb));
                            tx_shift <= {8'h02, 1'b0, address[22:2], first_lane(wstrb), wdata[first_lane(wstrb)*8 +: 8]};
                            state <= SETUP;
                        end
                    end else begin
                        tx_shift <= {8'h03, address[31:24] == 0 ? address[23:0] : {1'b0, address[22:0]}, 8'h00};
                        state <= SETUP;
                    end
                end

                SETUP: state <= SAMPLE;
                
                SAMPLE: begin
                    if (!req_write && bit_count >= 32) begin
                        rx_shift <= {rx_shift[30:0], miso};
                    end

                    tx_shift <= {tx_shift[38:0], 1'b0};
                    bit_count <= bit_count + 1'b1;
                    
                    if (init_step != INIT_DONE && bit_count == 39) begin
                        init_step <= init_step + 1'b1;
                        state <= IDLE;
                    end else if ((req_write && bit_count == 39) || (!req_write && bit_count == 63)) begin
                        state <= req_write && remaining_mask != 0 ? GAP : DONE;
                    end else begin
                        state <= SETUP;
                    end
                end

                GAP: begin
                    lane <= first_lane(remaining_mask);
                    remaining_mask <= remaining_mask & ~(4'b0001 << first_lane(remaining_mask));
                    tx_shift <= {8'h02, 1'b0, word_offset[22:2], first_lane(remaining_mask), write_word[first_lane(remaining_mask)*8 +: 8]};
                    bit_count <= 0;
                    state <= SETUP;
                end

                DONE: if (!valid) begin
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule

module Spi #(
    parameter BASE_ADDRESS = 32'h80000040
) (
    input clk,
    input reset,

    input [31:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    input write_enable,

    output reg sclk,
    output mosi,
    input miso,
    output cs_n,

    output reg [31:0] read_data
);
    wire [31:0] word_address = {address[31:2], 2'b00};

    reg [15:0] divider;
    reg cpol;
    reg cpha;
    reg cs;

    reg busy;
    reg [15:0] count;
    reg [3:0] edge_index;
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;

    assign mosi = tx_shift[7];
    assign cs_n = !cs;

    wire ctrl_write = write_enable && word_address == BASE_ADDRESS;
    wire cs_write = write_enable && word_address == BASE_ADDRESS + 4;
    wire start = write_enable && word_address == BASE_ADDRESS + 8 && write_mask[0] && !busy;

    wire leading_edge = !edge_index[0];
    wire sample_edge = leading_edge ^ cpha;
    wire shift_edge = !sample_edge && edge_index != 0;

    always @* begin
        case (word_address)
            BASE_ADDRESS: read_data = {14'd0, cpha, cpol, divider};
            BASE_ADDRESS + 4: read_data = {31'd0, cs};
            BASE_ADDRESS + 8: read_data = {24'd0, rx_shift};
            BASE_ADDRESS + 12: read_data = {31'd0, busy};
            default: read_data = 0;
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            divider <= 16'd67;
            cpol <= 0;
            cpha <= 0;
            cs <= 0;
            sclk <= 0;
            busy <= 0;
            count <= 0;
            edge_index <= 0;
            tx_shift <= 8'hff;
            rx_shift <= 0;
        end else begin
            if (ctrl_write) begin
                if (write_mask[0]) begin
                    divider[7:0] <= write_data[7:0];
                end

                if (write_mask[1]) begin
                    divider[15:8] <= write_data[15:8];
                end

                if (write_mask[2]) begin
                    cpol <= write_data[16];
                    cpha <= write_data[17];
                    if (!busy) begin
                        sclk <= write_data[16];
                    end
                end
            end

            if (cs_write && write_mask[0]) begin
                cs <= write_data[0];
            end

            if (start) begin
                tx_shift <= write_data[7:0];
                count <= divider;
                edge_index <= 0;
                busy <= 1;
            end else if (busy) begin
                if (count != 0) begin
                    count <= count - 1'b1;
                end else begin
                    count <= divider;
                    sclk <= !sclk;
                    edge_index <= edge_index + 1'b1;

                    if (sample_edge) begin
                        rx_shift <= {rx_shift[6:0], miso};
                    end

                    if (shift_edge) begin
                        tx_shift <= {tx_shift[6:0], 1'b1};
                    end

                    if (edge_index == 15) begin
                        busy <= 0;
                    end
                end
            end
        end
    end
endmodule

module Sram #(
    parameter MEM_WORDS = 8192,
    parameter MEM_INIT_FILE = "firmware.hex"
) (
    input clk,

    input read_enable,
    input [31:0] address,
    
    output reg [31:0] read_data,
    
    input write_enable,
    input [31:0] write_data,
    input [3:0] write_mask
);
    localparam ADDR_BITS = $clog2(MEM_WORDS);

    (* ram_style = "block", syn_ramstyle = "block_ram" *) reg [31:0] mem [0:MEM_WORDS-1];
    wire in_range = address < MEM_WORDS * 4;
    wire [ADDR_BITS-1:0] word_address = address[ADDR_BITS+1:2];
    
    initial begin
        if (MEM_INIT_FILE != "") begin
            $readmemh(MEM_INIT_FILE, mem);
        end
    end
    
    always @(posedge clk) begin
        if (read_enable) begin
            read_data <= in_range ? mem[word_address] : 32'd0;
        end
        
        if (write_enable && in_range) begin
            if (write_mask[0]) begin
                mem[word_address][7:0] <= write_data[7:0];
            end

            if (write_mask[1]) begin
                mem[word_address][15:8] <= write_data[15:8];
            end

            if (write_mask[2]) begin
                mem[word_address][23:16] <= write_data[23:16];
            end

            if (write_mask[3]) begin
                mem[word_address][31:24] <= write_data[31:24];
            end
        end
    end
endmodule
module Uart #(
    parameter BASE_ADDRESS = 32'h80000008
) (
    input clk,
    input reset,

    input [31:0] address,
    input [31:0] write_data,
    input [3:0] write_mask,
    input write_enable,
    input read_commit,

    input rx,
    output tx,
    output rx_valid,
    output reg [31:0] read_data
);
    wire [31:0] word_address = {address[31:2], 2'b00};
    reg [31:0] scaler;
    wire tx_busy;
    wire tx_start;
    wire rx_clear;
    wire [7:0] rx_data;

    assign tx_start = write_enable && word_address == BASE_ADDRESS + 4 && write_mask[0];
    assign rx_clear = read_commit && word_address == BASE_ADDRESS + 8;

    always @* begin
        case (word_address)
            BASE_ADDRESS: read_data = scaler;
            BASE_ADDRESS + 4: read_data = {31'd0, tx_busy};
            BASE_ADDRESS + 8: read_data = {16'd0, rx_data, 7'd0, rx_valid};
            default: read_data = 0;
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            scaler <= 0;
        end else if (write_enable && word_address == BASE_ADDRESS) begin
            if (write_mask[0]) begin
                scaler[7:0] <= write_data[7:0];
            end

            if (write_mask[1]) begin
                scaler[15:8] <= write_data[15:8];
            end

            if (write_mask[2]) begin
                scaler[23:16] <= write_data[23:16];
            end

            if (write_mask[3]) begin
                scaler[31:24] <= write_data[31:24];
            end
        end
    end

    UartTx tx_unit (
        .clk(clk),
        .reset(reset),
        .scaler(scaler),
        .start(tx_start),
        .data(write_data[7:0]),
        .tx(tx),
        .busy(tx_busy)
    );

    UartRx rx_unit (
        .clk(clk),
        .reset(reset),
        .scaler(scaler),
        .rx(rx),
        .clear(rx_clear),
        .data(rx_data),
        .valid(rx_valid)
    );
endmodule

module UartTx (
    input clk,
    input reset,
    input [31:0] scaler,
    input start,
    input [7:0] data,
    output reg tx,
    output reg busy
);
    localparam IDLE = 2'd0;
    localparam START = 2'd1;
    localparam DATA = 2'd2;
    localparam STOP = 2'd3;

    reg [1:0] state;
    reg [31:0] count;
    reg [31:0] frame_scaler;
    reg [7:0] payload;
    reg [2:0] bitpos;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            tx <= 1'b1;
            busy <= 1'b0;
            count <= 0;
            frame_scaler <= 0;
            payload <= 0;
            bitpos <= 0;
        end else if (state == IDLE) begin
            busy <= 1'b0;
            if (start) begin
                payload <= data;
                frame_scaler <= scaler;
                count <= scaler;
                bitpos <= 0;
                tx <= 1'b0;
                busy <= 1'b1;
                state <= START;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            count <= frame_scaler;
            case (state)
                START: begin
                    tx <= payload[0];
                    state <= DATA;
                end
                
                DATA: if (bitpos == 7) begin
                    tx <= 1'b1;
                    state <= STOP;
                end else begin
                    bitpos <= bitpos + 1'b1;
                    tx <= payload[bitpos + 1'b1];
                end

                STOP: state <= IDLE;

                default: begin
                    state <= IDLE;
                    tx <= 1'b1;
                end
            endcase
        end
    end
endmodule

module UartRx (
    input clk,
    input reset,
    input [31:0] scaler,
    input rx,
    input clear,
    output reg [7:0] data,
    output reg valid
);
    localparam IDLE = 2'd0;
    localparam START = 2'd1;
    localparam DATA = 2'd2;
    localparam STOP = 2'd3;

    reg [1:0] state;
    reg [31:0] count;
    reg [2:0] bitpos;
    reg [7:0] shift;
    (* async_reg = "true" *) reg rx_meta;
    (* async_reg = "true" *) reg rx_sync;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            count <= 0;
            bitpos <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
            rx_meta <= 1;
            rx_sync <= 1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;

            if (clear) begin
                valid <= 1'b0;
            end

            case (state)
                IDLE: if (!rx_sync && !valid) begin
                    count <= (scaler + 1'b1) >> 1;
                    bitpos <= 0;
                    state <= START;
                end

                START: if (count != 0) begin
                    count <= count - 1'b1;
                end else if (!rx_sync) begin
                    count <= scaler;
                    state <= DATA;
                end else begin
                    state <= IDLE;
                end
                
                DATA: if (count != 0) begin
                    count <= count - 1'b1;
                end else begin
                    count <= scaler;
                    shift[bitpos] <= rx_sync;
                    if (bitpos == 7) state <= STOP;
                    else bitpos <= bitpos + 1'b1;
                end
                
                STOP: if (count != 0) begin
                    count <= count - 1'b1;
                end else begin
                    if (rx_sync) begin
                        data <= shift;
                        valid <= 1'b1;
                    end
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule

