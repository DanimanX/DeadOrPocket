// core_top: DeadOrPocket (Sega Model 2 & Model 2A-CRX Hybrid Core) for Analogue Pocket
// Adapted from SpaceFish core_top.v, exposing BOTH Cellular PSRAMs (cram0/cram1),
// 64 MB SDR SDRAM (dram_*), 256 KB Async SRAM (sram_*), and the 30-pin Cartridge Slot.
`default_nettype none

module core_top (

input   wire            clk_74a,
input   wire            clk_74b,

// Cartridge interface (30 pins -> Compute Cartridge)
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
output  wire            cart_pin30_pwroff_reset,
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// Infrared (unused)
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port (unused)
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

// Cellular PSRAM 0 and 1 (2 x 16 MB)
output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

// SDR SDRAM (64 MB, 16-bit)
output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

// Async SRAM (256 KB, 16-bit)
output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

input   wire            vblank,
output  wire            dbg_tx,
input   wire            dbg_rx,
output  wire            user1,
input   wire            user2,
inout   wire            aux_sda,
output  wire            aux_scl,
output  wire            vpll_feed,

// Video & audio to APF scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

// APF bridge bus (clk_74a)
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

// APF controller data
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
);

assign port_ir_tx         = 1'b0;
assign port_ir_rx_disable = 1'b1;
assign bridge_endian_little = 1'b1;

assign port_tran_so     = 1'bz; assign port_tran_so_dir  = 1'b0;
assign port_tran_si     = 1'bz; assign port_tran_si_dir  = 1'b0;
assign port_tran_sck    = 1'bz; assign port_tran_sck_dir = 1'b0;
assign port_tran_sd     = 1'bz; assign port_tran_sd_dir  = 1'b0;

assign dbg_tx    = 1'bZ;
assign user1     = 1'bZ;
assign vpll_feed = 1'bZ;
assign aux_scl   = 1'bZ;

wire [31:0] cmd_bridge_rd_data;
always @(*) begin
	casex (bridge_addr)
		default:      bridge_rd_data <= 32'd0;
		32'hF8xxxxxx: bridge_rd_data <= cmd_bridge_rd_data;
	endcase
end

// APF Host/Target command bridge (reused from SpaceFish)
wire        reset_n;
wire        dataslot_allcomplete;
wire        pll_locked;

core_bridge_cmd icb (
	.clk                    ( clk_74a ),
	.reset_n                ( reset_n ),
	.bridge_endian_little   ( bridge_endian_little ),
	.bridge_addr            ( bridge_addr ),
	.bridge_rd              ( bridge_rd ),
	.bridge_rd_data         ( cmd_bridge_rd_data ),
	.bridge_wr              ( bridge_wr ),
	.bridge_wr_data         ( bridge_wr_data ),
	.status_boot_done       ( pll_locked ),
	.status_setup_done      ( pll_locked ),
	.status_running         ( pll_locked ),
	.dataslot_requestread       ( ),
	.dataslot_requestread_id    ( ),
	.dataslot_requestread_ack   ( 1'b1 ),
	.dataslot_requestread_ok    ( 1'b1 ),
	.dataslot_requestwrite      ( ),
	.dataslot_requestwrite_id   ( ),
	.dataslot_requestwrite_size ( ),
	.dataslot_requestwrite_ack  ( 1'b1 ),
	.dataslot_requestwrite_ok   ( 1'b1 ),
	.dataslot_update            ( ),
	.dataslot_update_id         ( ),
	.dataslot_update_size       ( ),
	.dataslot_update_size_lba48 ( ),
	.dataslot_allcomplete       ( dataslot_allcomplete ),
	.rtc_epoch_seconds          ( ),
	.rtc_date_bcd               ( ),
	.rtc_time_bcd               ( ),
	.rtc_valid                  ( ),
	.savestate_supported        ( 1'b0 ),
	.savestate_addr             ( 32'd0 ),
	.savestate_size             ( 32'd0 ),
	.savestate_maxloadsize      ( 32'd0 ),
	.savestate_start            ( ),
	.savestate_start_ack        ( 1'b0 ),
	.savestate_start_busy       ( 1'b0 ),
	.savestate_start_ok         ( 1'b0 ),
	.savestate_start_err        ( 1'b0 ),
	.savestate_load             ( ),
	.savestate_load_ack         ( 1'b0 ),
	.savestate_load_busy        ( 1'b0 ),
	.savestate_load_ok          ( 1'b0 ),
	.savestate_load_err         ( 1'b0 ),
	.osnotify_inmenu            ( ),
	.target_dataslot_read       ( 1'b0 ),
	.target_dataslot_write      ( 1'b0 ),
	.target_dataslot_getfile    ( 1'b0 ),
	.target_dataslot_openfile   ( 1'b0 ),
	.target_dataslot_ack        ( ),
	.target_dataslot_done       ( ),
	.target_dataslot_err        ( ),
	.target_dataslot_id         ( 16'd0 ),
	.target_dataslot_slotoffset ( 32'd0 ),
	.target_dataslot_bridgeaddr ( 32'd0 ),
	.target_dataslot_length     ( 32'd0 ),
	.target_buffer_param_struct ( 32'd0 ),
	.target_buffer_resp_struct  ( 32'd0 ),
	.datatable_addr             ( 10'd0 ),
	.datatable_wren             ( 1'b0 ),
	.datatable_data             ( 32'd0 ),
	.datatable_q                ( )
);

m2_pocket_top im2 (
	.clk_74a                 ( clk_74a ),
	.apf_reset_n             ( reset_n ),
	.bridge_addr             ( bridge_addr ),
	.bridge_wr               ( bridge_wr ),
	.bridge_wr_data          ( bridge_wr_data ),
	.pad_key                 ( cont1_key ),
	.pad_joy                 ( cont1_joy ),
	.pad_trig                ( cont1_trig ),
	.apf_dataslot_complete   ( dataslot_allcomplete ),
	.video_rgb               ( video_rgb ),
	.video_rgb_clock         ( video_rgb_clock ),
	.video_rgb_clock_90      ( video_rgb_clock_90 ),
	.video_de                ( video_de ),
	.video_skip              ( video_skip ),
	.video_vs                ( video_vs ),
	.video_hs                ( video_hs ),
	.audio_mclk              ( audio_mclk ),
	.audio_lrck              ( audio_lrck ),
	.audio_dac               ( audio_dac ),
	.dram_a                  ( dram_a ),
	.dram_ba                 ( dram_ba ),
	.dram_dq                 ( dram_dq ),
	.dram_dqm                ( dram_dqm ),
	.dram_clk                ( dram_clk ),
	.dram_cke                ( dram_cke ),
	.dram_ras_n              ( dram_ras_n ),
	.dram_cas_n              ( dram_cas_n ),
	.dram_we_n               ( dram_we_n ),
	.cram0_a                 ( cram0_a ),
	.cram0_dq                ( cram0_dq ),
	.cram0_wait              ( cram0_wait ),
	.cram0_clk               ( cram0_clk ),
	.cram0_adv_n             ( cram0_adv_n ),
	.cram0_cre               ( cram0_cre ),
	.cram0_ce0_n             ( cram0_ce0_n ),
	.cram0_ce1_n             ( cram0_ce1_n ),
	.cram0_oe_n              ( cram0_oe_n ),
	.cram0_we_n              ( cram0_we_n ),
	.cram0_ub_n              ( cram0_ub_n ),
	.cram0_lb_n              ( cram0_lb_n ),
	.cram1_a                 ( cram1_a ),
	.cram1_dq                ( cram1_dq ),
	.cram1_wait              ( cram1_wait ),
	.cram1_clk               ( cram1_clk ),
	.cram1_adv_n             ( cram1_adv_n ),
	.cram1_cre               ( cram1_cre ),
	.cram1_ce0_n             ( cram1_ce0_n ),
	.cram1_ce1_n             ( cram1_ce1_n ),
	.cram1_oe_n              ( cram1_oe_n ),
	.cram1_we_n              ( cram1_we_n ),
	.cram1_ub_n              ( cram1_ub_n ),
	.cram1_lb_n              ( cram1_lb_n ),
	.sram_a                  ( sram_a ),
	.sram_dq                 ( sram_dq ),
	.sram_oe_n               ( sram_oe_n ),
	.sram_we_n               ( sram_we_n ),
	.sram_ub_n               ( sram_ub_n ),
	.sram_lb_n               ( sram_lb_n ),
	.cart_tran_bank0         ( cart_tran_bank0 ),
	.cart_tran_bank0_dir     ( cart_tran_bank0_dir ),
	.cart_tran_bank1         ( cart_tran_bank1 ),
	.cart_tran_bank1_dir     ( cart_tran_bank1_dir ),
	.cart_tran_bank2         ( cart_tran_bank2 ),
	.cart_tran_bank2_dir     ( cart_tran_bank2_dir ),
	.cart_tran_bank3         ( cart_tran_bank3 ),
	.cart_tran_bank3_dir     ( cart_tran_bank3_dir ),
	.cart_tran_pin30         ( cart_tran_pin30 ),
	.cart_tran_pin30_dir     ( cart_tran_pin30_dir ),
	.cart_pin30_pwroff_reset ( cart_pin30_pwroff_reset ),
	.cart_tran_pin31         ( cart_tran_pin31 ),
	.cart_tran_pin31_dir     ( cart_tran_pin31_dir ),
	.pll_locked_o            ( pll_locked )
);

endmodule
`default_nettype wire
