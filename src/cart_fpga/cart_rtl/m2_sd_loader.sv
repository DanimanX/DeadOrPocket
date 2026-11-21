// m2_sd_loader: Real SD/SDHC SPI Mode Block Boot Loader for DeadOrPocket Compute Cartridge
// Streams up to 128 MB (64M x 16-bit words) from onboard MicroSD directly into m2_sdram.
//
// Boot Descriptor ("DOP2", 512-byte sector at LBA 0, or automatically followed via MBR Partition 1):
//   Bytes  0.. 3 : Magic "DOP2" (0x44, 0x4F, 0x50, 0x32)
//   Bytes  4.. 7 : total_words[31:0]  (LE, number of 16-bit SDRAM words to stream, <= 64M)
//   Bytes  8..11 : payload_lba[31:0]  (LE, starting 512B LBA of payload; 0 => hdr_lba + 1)
//   Bytes 12..15 : sdram_base[31:0]   (LE, starting 16-bit word address in m2_sdram)
//   Byte  16     : game_id[7:0]       (Model 2 / 2A game ID for m2_2a_inputs / m2_ioz80)
//   Byte  17     : flags[7:0]         ([0]=prog_ext, [1]=board_2a)
//
`default_nettype none

module m2_sd_loader #(
	parameter int unsigned INIT_DIV = 128, // 100 MHz / (2*128) = 390 kHz init clock
	parameter int unsigned FAST_DIV = 2    // 100 MHz / (2*2)   = 25.0 MHz data clock
) (
	input  wire        clk,          // clk_mem (100 MHz)
	input  wire        rst_n,
	input  wire        sdram_ready,

	// Physical MicroSD SPI pins (Mode 0: CPOL=0, CPHA=0)
	output reg         sd_sck,
	output reg         sd_cs_n,
	output reg         sd_mosi,
	input  wire        sd_miso,

	// m2_sdram loader write port (16-bit words @ clk_mem)
	output reg         wr_req,
	output reg  [26:1] wr_addr,
	output reg  [15:0] wr_din,
	input  wire        wr_ack,

	// Parsed boot metadata & status
	output reg         boot_done,
	output reg         boot_err,
	output reg   [6:0] boot_game_id,
	output reg         boot_prog_ext,
	output reg  [25:0] boot_words_loaded
);

	// ---- Byte-level SPI Mode 0 Engine ---------------------------------------
	reg        spi_go;
	reg        spi_fast;
	reg  [7:0] spi_tx;
	reg  [7:0] spi_rx;
	reg        spi_busy;
	reg        spi_done;
	reg  [7:0] spi_div_cnt;
	reg  [3:0] spi_bit_cnt;
	reg        spi_phase; // 0 = setup/rising, 1 = falling
	reg  [7:0] spi_sh;

	wire [7:0] cur_div = spi_fast ? FAST_DIV[7:0] : INIT_DIV[7:0];

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			sd_sck      <= 1'b0;
			sd_mosi     <= 1'b1;
			spi_busy    <= 1'b0;
			spi_done    <= 1'b0;
			spi_rx      <= 8'hFF;
			spi_div_cnt <= 8'd0;
			spi_bit_cnt <= 4'd0;
			spi_phase   <= 1'b0;
			spi_sh      <= 8'hFF;
		end else begin
			spi_done <= 1'b0;
			if (!spi_busy) begin
				sd_sck <= 1'b0;
				if (spi_go) begin
					spi_busy    <= 1'b1;
					spi_sh      <= spi_tx;
					sd_mosi     <= spi_tx[7];
					spi_bit_cnt <= 4'd0;
					spi_phase   <= 1'b0;
					spi_div_cnt <= 8'd1;
				end
			end else begin
				if (spi_div_cnt >= cur_div) begin
					spi_div_cnt <= 8'd1;
					if (!spi_phase) begin
						// Rising edge: sample MISO
						sd_sck    <= 1'b1;
						spi_sh    <= {spi_sh[6:0], sd_miso};
						spi_phase <= 1'b1;
					end else begin
						// Falling edge: shift next MOSI or finish byte
						sd_sck    <= 1'b0;
						spi_phase <= 1'b0;
						if (spi_bit_cnt == 4'd7) begin
							spi_busy <= 1'b0;
							spi_done <= 1'b1;
							spi_rx   <= spi_sh;
							sd_mosi  <= 1'b1;
						end else begin
							spi_bit_cnt <= spi_bit_cnt + 4'd1;
							sd_mosi     <= spi_sh[7];
						end
					end
				end else begin
					spi_div_cnt <= spi_div_cnt + 8'd1;
				end
			end
		end
	end

	// ---- SD/SDHC Protocol & Block Stream FSM --------------------------------
	localparam [4:0]
		ST_WAIT_SDRAM   = 5'd0,
		ST_PWRUP_CLK    = 5'd1,
		ST_SEND_CMD     = 5'd2,
		ST_WAIT_R1      = 5'd3,
		ST_READ_EXTRA   = 5'd4,
		ST_AFTER_CMD    = 5'd5,
		ST_WAIT_TOKEN   = 5'd6,
		ST_HDR_BYTE     = 5'd7,
		ST_HDR_PARSE    = 5'd8,
		ST_DATA_LO      = 5'd9,
		ST_DATA_HI      = 5'd10,
		ST_SDRAM_WR     = 5'd11,
		ST_SKIP_CRC     = 5'd12,
		ST_CMD12_STUFF  = 5'd13,
		ST_WAIT_UNBUSY  = 5'd14,
		ST_DONE         = 5'd15,
		ST_ERROR        = 5'd16;

	// Command phase identifiers
	localparam [3:0]
		PH_CMD0   = 4'd0,
		PH_CMD8   = 4'd1,
		PH_CMD55  = 4'd2,
		PH_ACMD41 = 4'd3,
		PH_CMD58  = 4'd4,
		PH_CMD17  = 4'd5,
		PH_CMD18  = 4'd6,
		PH_CMD12  = 4'd7;

	reg  [4:0] state;
	reg  [3:0] cmd_phase;
	reg  [7:0] cmd_buf [0:5];
	reg  [2:0] cmd_idx;
	reg  [7:0] r1_val;
	reg  [3:0] extra_cnt;
	reg [31:0] extra_val;
	reg  [7:0] retry_cnt;
	reg [15:0] timeout_cnt;

	reg        is_sdhc;
	reg        tried_mbr;
	reg [31:0] hdr_lba;
	reg [31:0] mbr_lba;
	reg  [9:0] byte_idx;
	reg  [7:0] hdr_magic [0:3];
	reg [31:0] hdr_total_words;
	reg [31:0] hdr_payload_lba;
	reg [31:0] hdr_sdram_base;
	reg  [7:0] hdr_gid;
	reg  [7:0] hdr_flags;
	reg [15:0] hdr_sig;

	reg [25:0] words_rem;
	reg  [7:0] word_lo;
	reg  [8:0] blk_word_idx;

	// Helper task-like command loader (inlined via state transitions)
	wire [31:0] cmd17_arg = is_sdhc ? hdr_lba : {hdr_lba[22:0], 9'd0};
	wire [31:0] eff_pl_lba = (hdr_payload_lba == 32'd0) ? (hdr_lba + 32'd1) : hdr_payload_lba;
	wire [31:0] cmd18_arg = is_sdhc ? eff_pl_lba : {eff_pl_lba[22:0], 9'd0};

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state             <= ST_WAIT_SDRAM;
			cmd_phase         <= PH_CMD0;
			sd_cs_n           <= 1'b1;
			spi_go            <= 1'b0;
			spi_fast          <= 1'b0;
			spi_tx            <= 8'hFF;
			cmd_idx           <= 3'd0;
			r1_val            <= 8'hFF;
			extra_cnt         <= 4'd0;
			extra_val         <= 32'd0;
			retry_cnt         <= 8'd0;
			timeout_cnt       <= 16'd0;
			is_sdhc           <= 1'b1;
			tried_mbr         <= 1'b0;
			hdr_lba           <= 32'd0;
			mbr_lba           <= 32'd0;
			byte_idx          <= 10'd0;
			hdr_total_words   <= 32'd0;
			hdr_payload_lba   <= 32'd0;
			hdr_sdram_base    <= 32'd0;
			hdr_gid           <= 8'h16; // Default DOA/VF2 3-button profile
			hdr_flags         <= 8'h03;
			hdr_sig           <= 16'd0;
			words_rem         <= 26'd0;
			word_lo           <= 8'd0;
			blk_word_idx      <= 9'd0;
			wr_req            <= 1'b0;
			wr_addr           <= 26'd0;
			wr_din            <= 16'd0;
			boot_done         <= 1'b0;
			boot_err          <= 1'b0;
			boot_game_id      <= 7'h16;
			boot_prog_ext     <= 1'b1;
			boot_words_loaded <= 26'd0;
		end else begin
			spi_go <= 1'b0;

			case (state)
				ST_WAIT_SDRAM: begin
					sd_cs_n  <= 1'b1;
					spi_fast <= 1'b0;
					if (sdram_ready) begin
						byte_idx <= 10'd0;
						state    <= ST_PWRUP_CLK;
					end
				end

				// 10 dummy bytes (80 clocks) with CS# HIGH
				ST_PWRUP_CLK: begin
					sd_cs_n <= 1'b1;
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (byte_idx == 10'd9) begin
								// Launch CMD0
								sd_cs_n    <= 1'b0;
								cmd_phase  <= PH_CMD0;
								cmd_buf[0] <= 8'h40;
								cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
								cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
								cmd_buf[5] <= 8'h95;
								cmd_idx    <= 3'd0;
								state      <= ST_SEND_CMD;
							end else begin
								byte_idx <= byte_idx + 10'd1;
								spi_tx   <= 8'hFF;
								spi_go   <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Send 6-byte SD command frame
				ST_SEND_CMD: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (cmd_idx == 3'd5) begin
								timeout_cnt <= 16'd0;
								if (cmd_phase == PH_CMD12) begin
									state <= ST_CMD12_STUFF;
								end else begin
									state <= ST_WAIT_R1;
								end
							end else begin
								cmd_idx <= cmd_idx + 3'd1;
								spi_tx  <= cmd_buf[cmd_idx + 3'd1];
								spi_go  <= 1'b1;
							end
						end else begin
							spi_tx <= cmd_buf[cmd_idx];
							spi_go <= 1'b1;
						end
					end
				end

				// CMD12 requires 1 stuff byte before polling R1
				ST_CMD12_STUFF: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							state <= ST_WAIT_R1;
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Poll for R1 response (bit 7 == 0)
				ST_WAIT_R1: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (!spi_rx[7]) begin
								r1_val <= spi_rx;
								if (cmd_phase == PH_CMD8 || cmd_phase == PH_CMD58) begin
									extra_cnt <= 4'd0;
									extra_val <= 32'd0;
									state     <= ST_READ_EXTRA;
								end else begin
									state <= ST_AFTER_CMD;
								end
							end else if (timeout_cnt == 16'd255) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								timeout_cnt <= timeout_cnt + 16'd1;
								spi_tx      <= 8'hFF;
								spi_go      <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Read 4 extra response bytes (R7 for CMD8, R3 for CMD58)
				ST_READ_EXTRA: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							extra_val <= {extra_val[23:0], spi_rx};
							if (extra_cnt == 4'd3) begin
								state <= ST_AFTER_CMD;
							end else begin
								extra_cnt <= extra_cnt + 4'd1;
								spi_tx    <= 8'hFF;
								spi_go    <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Dispatch next SD command based on cmd_phase & response
				ST_AFTER_CMD: begin
					case (cmd_phase)
						PH_CMD0: begin
							if (r1_val == 8'h01) begin
								cmd_phase  <= PH_CMD8;
								cmd_buf[0] <= 8'h48;
								cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
								cmd_buf[3] <= 8'h01; cmd_buf[4] <= 8'hAA;
								cmd_buf[5] <= 8'h87;
								cmd_idx    <= 3'd0;
								state      <= ST_SEND_CMD;
							end else if (retry_cnt == 8'd32) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								retry_cnt <= retry_cnt + 8'd1;
								cmd_idx   <= 3'd0;
								state     <= ST_SEND_CMD;
							end
						end

						PH_CMD8: begin
							// Proceed to CMD55 + ACMD41 (supports both SDv2 and SDv1)
							retry_cnt  <= 8'd0;
							cmd_phase  <= PH_CMD55;
							cmd_buf[0] <= 8'h77;
							cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
							cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
							cmd_buf[5] <= 8'h65;
							cmd_idx    <= 3'd0;
							state      <= ST_SEND_CMD;
						end

						PH_CMD55: begin
							cmd_phase  <= PH_ACMD41;
							cmd_buf[0] <= 8'h69;
							cmd_buf[1] <= 8'h40; cmd_buf[2] <= 8'h00;
							cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
							cmd_buf[5] <= 8'h77;
							cmd_idx    <= 3'd0;
							state      <= ST_SEND_CMD;
						end

						PH_ACMD41: begin
							if (r1_val == 8'h00) begin
								cmd_phase  <= PH_CMD58;
								cmd_buf[0] <= 8'h7A;
								cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
								cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
								cmd_buf[5] <= 8'hFD;
								cmd_idx    <= 3'd0;
								state      <= ST_SEND_CMD;
							end else if (retry_cnt == 8'd255) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								retry_cnt  <= retry_cnt + 8'd1;
								cmd_phase  <= PH_CMD55;
								cmd_buf[0] <= 8'h77;
								cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
								cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
								cmd_buf[5] <= 8'h65;
								cmd_idx    <= 3'd0;
								state      <= ST_SEND_CMD;
							end
						end

						PH_CMD58: begin
							is_sdhc    <= extra_val[30];
							spi_fast   <= 1'b1; // Switch to 25.0 MHz data clock!
							hdr_lba    <= 32'd0;
							tried_mbr  <= 1'b0;
							cmd_phase  <= PH_CMD17;
							cmd_buf[0] <= 8'h51; // CMD17: Read Single Block (LBA 0)
							cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
							cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
							cmd_buf[5] <= 8'hFF;
							cmd_idx    <= 3'd0;
							state      <= ST_SEND_CMD;
						end

						PH_CMD17: begin
							if (r1_val != 8'h00) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								timeout_cnt <= 16'd0;
								byte_idx    <= 10'd0;
								state       <= ST_WAIT_TOKEN;
							end
						end

						PH_CMD18: begin
							if (r1_val != 8'h00) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								timeout_cnt  <= 16'd0;
								blk_word_idx <= 9'd0;
								state        <= ST_WAIT_TOKEN;
							end
						end

						PH_CMD12: begin
							state <= ST_WAIT_UNBUSY;
						end

						default: state <= ST_ERROR;
					endcase
				end

				// Wait for 0xFE Data Block Start Token
				ST_WAIT_TOKEN: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (spi_rx == 8'hFE) begin
								byte_idx     <= 10'd0;
								blk_word_idx <= 9'd0;
								state        <= (cmd_phase == PH_CMD17) ? ST_HDR_BYTE : ST_DATA_LO;
							end else if (timeout_cnt == 16'hFFFF) begin
								boot_err <= 1'b1;
								state    <= ST_ERROR;
							end else begin
								timeout_cnt <= timeout_cnt + 16'd1;
								spi_tx      <= 8'hFF;
								spi_go      <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Read 512 header bytes + 2 CRC bytes (514 total)
				ST_HDR_BYTE: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							case (byte_idx)
								10'd0:   hdr_magic[0]          <= spi_rx;
								10'd1:   hdr_magic[1]          <= spi_rx;
								10'd2:   hdr_magic[2]          <= spi_rx;
								10'd3:   hdr_magic[3]          <= spi_rx;
								10'd4:   hdr_total_words[7:0]  <= spi_rx;
								10'd5:   hdr_total_words[15:8] <= spi_rx;
								10'd6:   hdr_total_words[23:16]<= spi_rx;
								10'd7:   hdr_total_words[31:24]<= spi_rx;
								10'd8:   hdr_payload_lba[7:0]  <= spi_rx;
								10'd9:   hdr_payload_lba[15:8] <= spi_rx;
								10'd10:  hdr_payload_lba[23:16]<= spi_rx;
								10'd11:  hdr_payload_lba[31:24]<= spi_rx;
								10'd12:  hdr_sdram_base[7:0]   <= spi_rx;
								10'd13:  hdr_sdram_base[15:8]  <= spi_rx;
								10'd14:  hdr_sdram_base[23:16] <= spi_rx;
								10'd15:  hdr_sdram_base[31:24] <= spi_rx;
								10'd16:  hdr_gid               <= spi_rx;
								10'd17:  hdr_flags             <= spi_rx;
								// MBR Partition 1 LBA Start (little-endian at offset 454..457)
								10'd454: mbr_lba[7:0]          <= spi_rx;
								10'd455: mbr_lba[15:8]         <= spi_rx;
								10'd456: mbr_lba[23:16]        <= spi_rx;
								10'd457: mbr_lba[31:24]        <= spi_rx;
								10'd510: hdr_sig[7:0]          <= spi_rx;
								10'd511: hdr_sig[15:8]         <= spi_rx;
								default: ;
							endcase
							if (byte_idx == 10'd513) begin
								state <= ST_HDR_PARSE;
							end else begin
								byte_idx <= byte_idx + 10'd1;
								spi_tx   <= 8'hFF;
								spi_go   <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Validate "DOP2" descriptor or follow MBR Partition 1 LBA
				ST_HDR_PARSE: begin
					if (hdr_magic[0] == 8'h44 && hdr_magic[1] == 8'h4F &&
					    hdr_magic[2] == 8'h50 && hdr_magic[3] == 8'h32 &&
					    hdr_total_words != 32'd0) begin
						boot_game_id  <= hdr_gid[6:0];
						boot_prog_ext <= hdr_flags[0];
						words_rem     <= hdr_total_words[25:0];
						wr_addr       <= hdr_sdram_base[25:0];
						// Launch CMD18 Multi-Block Stream
						cmd_phase     <= PH_CMD18;
						cmd_buf[0]    <= 8'h52; // CMD18
						cmd_buf[1]    <= cmd18_arg[31:24];
						cmd_buf[2]    <= cmd18_arg[23:16];
						cmd_buf[3]    <= cmd18_arg[15:8];
						cmd_buf[4]    <= cmd18_arg[7:0];
						cmd_buf[5]    <= 8'hFF;
						cmd_idx       <= 3'd0;
						state         <= ST_SEND_CMD;
					end else if (!tried_mbr && hdr_sig == 16'hAA55 && mbr_lba != 32'd0) begin
						// Follow Partition 1 LBA once
						tried_mbr  <= 1'b1;
						hdr_lba    <= mbr_lba;
						cmd_phase  <= PH_CMD17;
						cmd_buf[0] <= 8'h51;
						cmd_buf[1] <= is_sdhc ? mbr_lba[31:24] : mbr_lba[22:15];
						cmd_buf[2] <= is_sdhc ? mbr_lba[23:16] : mbr_lba[14:7];
						cmd_buf[3] <= is_sdhc ? mbr_lba[15:8]  : {mbr_lba[6:0], 1'b0};
						cmd_buf[4] <= is_sdhc ? mbr_lba[7:0]   : 8'h00;
						cmd_buf[5] <= 8'hFF;
						cmd_idx    <= 3'd0;
						state      <= ST_SEND_CMD;
					end else begin
						boot_err <= 1'b1;
						state    <= ST_ERROR;
					end
				end

				// Stream 16-bit little-endian words (256 words per 512B block) -> m2_sdram
				ST_DATA_LO: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							word_lo <= spi_rx;
							state   <= ST_DATA_HI;
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				ST_DATA_HI: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (words_rem != 26'd0) begin
								wr_din <= {spi_rx, word_lo};
								wr_req <= 1'b1;
								state  <= ST_SDRAM_WR;
							end else begin
								// Finish trailing bytes in current 512B block
								if (blk_word_idx == 9'd255) begin
									byte_idx <= 10'd0;
									state    <= ST_SKIP_CRC;
								end else begin
									blk_word_idx <= blk_word_idx + 9'd1;
									state        <= ST_DATA_LO;
								end
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Pause SPI cleanly until m2_sdram acknowledges the 16-bit write
				ST_SDRAM_WR: begin
					if (wr_ack) begin
						wr_req            <= 1'b0;
						wr_addr           <= wr_addr + 26'd1;
						words_rem         <= words_rem - 26'd1;
						boot_words_loaded <= boot_words_loaded + 26'd1;
						if (blk_word_idx == 9'd255) begin
							byte_idx <= 10'd0;
							state    <= ST_SKIP_CRC;
						end else begin
							blk_word_idx <= blk_word_idx + 9'd1;
							state        <= ST_DATA_LO;
						end
					end
				end

				// Discard 2-byte CRC16 at end of 512B block
				ST_SKIP_CRC: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (byte_idx == 10'd1) begin
								if (words_rem == 26'd0) begin
									// Stop multi-block transfer with CMD12
									cmd_phase  <= PH_CMD12;
									cmd_buf[0] <= 8'h4C; // CMD12
									cmd_buf[1] <= 8'h00; cmd_buf[2] <= 8'h00;
									cmd_buf[3] <= 8'h00; cmd_buf[4] <= 8'h00;
									cmd_buf[5] <= 8'h61;
									cmd_idx    <= 3'd0;
									state      <= ST_SEND_CMD;
								end else begin
									timeout_cnt  <= 16'd0;
									blk_word_idx <= 9'd0;
									state        <= ST_WAIT_TOKEN;
								end
							end else begin
								byte_idx <= byte_idx + 10'd1;
								spi_tx   <= 8'hFF;
								spi_go   <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				// Wait for SD card to release busy (0xFF) after CMD12
				ST_WAIT_UNBUSY: begin
					if (!spi_busy && !spi_go) begin
						if (spi_done) begin
							if (spi_rx == 8'hFF) begin
								sd_cs_n   <= 1'b1;
								boot_done <= 1'b1;
								state     <= ST_DONE;
							end else begin
								spi_tx <= 8'hFF;
								spi_go <= 1'b1;
							end
						end else begin
							spi_tx <= 8'hFF;
							spi_go <= 1'b1;
						end
					end
				end

				ST_DONE: begin
					sd_cs_n   <= 1'b1;
					boot_done <= 1'b1;
				end

				ST_ERROR: begin
					sd_cs_n  <= 1'b1;
					boot_err <= 1'b1;
				end

				default: state <= ST_ERROR;
			endcase
		end
	end

endmodule
`default_nettype wire
