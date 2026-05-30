// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of BloodBros_MiSTer.

    BloodBros_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    BloodBros_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with BloodBros_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

/*  Sprite renderer Seibu SEI0211 (Blood Bros — alt_format).

    Spriteram: 512 entry × 8 byte (4 word) — Blood Bros usa il doppio degli
    slot rispetto a DCon. Formato "alt" (vedi MAME sei021x_sei0220_spr.cpp).

    Pen 15 = trasparente.

    Architettura:
      - Sprite scan FSM durante linea N: scorre 512 entry, per quelle che
        intersecano linea N+1 (target_y), fetch SDRAM dei tile coperti e
        scrive in line buffer non-attivo.
      - Read side: a hpos legge line buffer attivo, restituisce pen+pri_code.
      - Ping-pong al new_line.

    ─── Ottimizzazioni performance (no logic change) ────────────────────
    Line buffer = 8 bank interleaved da 32×14 (256 pixel totali, lane =
    dx[2:0], riga = dx[7:3]). Permette:
      - SC_DECODE in 1 ciclo invece di 8: tutti gli 8 pixel della mezza-
        riga scritti in parallelo (un write per bank).
      - SC_CLEAR in 32 cicli invece di 256: 8 entry azzerate/ciclo.
    Stesso pattern usato nel renderer DCon.
*/

module BloodBros_sprite_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire  [9:0] hpos,        // 0..255 logico
	input  wire  [8:0] vpos,        // 0..223 logico
	input  wire        de,
	input  wire        layer_en,
	input  wire        new_line,

	// OSD offset (signed 10-bit, range -32..+31 per X/Y)
	input  wire signed [9:0] xoff,
	input  wire signed [9:0] yoff,

	// Sprite RAM read port (dual-port lato B)
	// Blood Bros: 2048 word totali (512 entry × 4 word, 4KB)
	output reg  [10:0] spr_addr,
	input  wire [15:0] spr_data,

	// SDRAM tile fetch via arbiter (client r3, kind=3, no cache)
	output reg         rom_req,
	output reg  [23:0] rom_addr,
	input  wire [31:0] rom_data,
	input  wire        rom_valid,

	// Output pixel (combinatoriale: ultimo pixel a destra mostrato senza latency)
	output wire        opaque,
	output wire [10:0] pen_index,
	output wire  [1:0] pri_code
);

	// ─── Line buffer ping-pong (8 bank interleaved per parallel write) ──
	// Layout 14-bit: [13:8]=color, [7:6]=pri_code, [5:4]=00, [3:0]=pen
	// Bank b contiene i pixel con dx[2:0]==b → indicizzato da dx[7:3] (0..31).
	// Permette 8 write paralleli in 1 ciclo (decode 8 pixel/ciclo) e clear
	// in 32 cicli invece di 256. Vista esterna: identica al singolo array.
	localparam [13:0] LB_EMPTY = 14'h003F;  // color=0, pri=0, pen=15 (trasparente)
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b0 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b1 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b2 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b3 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b4 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b5 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b6 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b7 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b0 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b1 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b2 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b3 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b4 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b5 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b6 [0:31];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b7 [0:31];
	reg        active_buf;

	// ─── Sprite scan FSM ─────────────────────────────────────────────────────
	localparam SC_IDLE     = 4'd0;
	localparam SC_CLEAR    = 4'd1;
	localparam SC_RW0      = 4'd2;
	localparam SC_RW1      = 4'd3;
	localparam SC_RW2      = 4'd4;
	localparam SC_RW3      = 4'd5;
	localparam SC_CHECK    = 4'd6;
	localparam SC_CHECK2   = 4'd7;
	localparam SC_ROM_REQ  = 4'd8;
	localparam SC_ROM_W    = 4'd9;
	localparam SC_DECODE   = 4'd10;
	localparam SC_NEXT_TX  = 4'd11;
	localparam SC_NEXT_E   = 4'd12;
	localparam SC_DONE     = 4'd13;
	localparam SC_CHECK2_W2 = 4'd14;
	localparam SC_DECODE_WR = 4'd15;   // pipeline: SC_DECODE latch, SC_DECODE_WR write

	reg [3:0] sc_state;
	reg [8:0] entry_idx;       // 0..511 (Blood Bros 512 entries)
	reg [4:0] clear_idx;       // 0..31 per clear buffer (8 lane in parallelo)
	reg [15:0] sp_w0, sp_w1, sp_w2, sp_w3;
	reg        pf_side;        // 0=metà sx tile (col 0..7), 1=metà dx (col 8..15)

	// Decoded fields — Blood Bros ALT FORMAT (MAME sei021x_sei0220_spr.cpp:124-140)
	// W0:
	//   bit 15      Disable (1=skip!) - INVERSO vs std (era enable)
	//   bit 14      Flip Y            - SWAPPED vs std
	//   bit 13      Flip X            - SWAPPED vs std
	//   bit 11      Priority (1-bit)  - era pri @ W1[15:14]
	//   bit 9:7     Size X (3-bit, +1)
	//   bit 6:4     Size Y (3-bit, +1)
	//   bit 3:0     Color (4-bit)     - era 6-bit @ W0[5:0]
	// W1:
	//   bit 12:0    Tile code (13-bit) - era 14-bit
	wire        sp_enable = ~sp_w0[15];        // alt: bit15=DISABLE → invertito
	wire        sp_flipy  = sp_w0[14];          // alt: bit14=flipY
	wire        sp_flipx  = sp_w0[13];          // alt: bit13=flipX
	wire  [2:0] sp_sizex  = sp_w0[9:7];         // alt: bit 9:7
	wire  [2:0] sp_sizey  = sp_w0[6:4];         // alt: bit 6:4
	wire  [5:0] sp_color  = {2'b00, sp_w0[3:0]}; // alt: 4-bit color, zero-extend
	wire  [1:0] sp_pri    = {1'b0, sp_w0[11]};  // alt: 1-bit priority @ W0[11]
	wire [13:0] sp_code   = {1'b0, sp_w1[12:0]}; // alt: 13-bit code
	// SEI0211 get_coordinate (MAME sei021x_sei0220_spr.h):
	//   coord &= 0x1ff;
	//   return (coord >= 0x180) ? coord - 0x200 : coord;
	// Range effettivo: -128..+383 (positivi 0..0x17F, negativi 0x180..0x1FF).
	// Y: lo sprite ha direzione opposta agli altri layer → -16 (verificato HW)
	wire [8:0] sp_xraw = sp_w2[8:0];
	wire [8:0] sp_yraw = sp_w3[8:0];
	wire signed [10:0] sp_x_raw = (sp_xraw >= 9'h180) ? ({2'b00, sp_xraw} - 11'h200) : {2'b00, sp_xraw};
	wire signed [10:0] sp_y_raw = (sp_yraw >= 9'h180) ? ({2'b00, sp_yraw} - 11'h200) : {2'b00, sp_yraw};
	// Apply OSD offsets (sign-extend 10->11)
	wire signed [10:0] sp_x = sp_x_raw + {xoff[9], xoff};
	wire signed [10:0] sp_y = sp_y_raw + {yoff[9], yoff} - 11'sd16;

	wire [3:0] sp_w  = {1'b0, sp_sizex} + 4'd1;    // 1..8
	wire [3:0] sp_h  = {1'b0, sp_sizey} + 4'd1;    // 1..8

	// Target Y per la linea che stiamo prefetchando (= linea corrente + 1, wrap)
	wire [8:0] target_y = (vpos == 9'd223) ? 9'd0 : (vpos + 9'd1);

	// Sprite intersect check: target_y in [sp_y, sp_y + sp_h*16)
	wire signed [10:0] dy_top = {2'b00, target_y} - sp_y;
	wire        in_y     = (dy_top >= 0) && (dy_top < {3'd0, sp_h, 4'd0});  // sp_h*16
	wire  [3:0] tile_y_in = dy_top[7:4];   // tile row 0..7 dentro sprite
	wire  [3:0] row_in    = dy_top[3:0];   // row dentro tile 0..15
	// flip Y
	wire  [3:0] eff_tile_y = sp_flipy ? (sp_h - 4'd1 - tile_y_in) : tile_y_in;
	wire  [3:0] eff_row    = sp_flipy ? (4'd15 - row_in)          : row_in;

	// Iteratore tile_x
	reg  [3:0] tile_x_pf;
	reg [31:0] pf_rom_data;
	wire  [3:0] eff_tile_x = sp_flipx ? (sp_w - 4'd1 - tile_x_pf) : tile_x_pf;

	// Tile code finale Y-MAJOR (MAME draw_internal: ax=outer, ay=inner, code++):
	//   sub_index = ax*sizey + ay  →  cur_tile = code + eff_tile_x*sp_h + eff_tile_y
	wire [13:0] cur_tile = sp_code + ({10'd0, eff_tile_x} * {10'd0, sp_h}) + {10'd0, eff_tile_y};

	// new_line gating
	wire vpos_visible = (vpos < 9'd224);
	wire gated_new_line = new_line & vpos_visible;

	// ─── Parallel decode (8 pixel della mezza-riga in un colpo) ──────────────
	wire [7:0] dec_byte0 = pf_rom_data[31:24];
	wire [7:0] dec_byte1 = pf_rom_data[23:16];
	wire [7:0] dec_byte2 = pf_rom_data[15:8];
	wire [7:0] dec_byte3 = pf_rom_data[7:0];

	function [3:0] pen_at;
		input integer k;
		reg [7:0] blo, bhi;
		reg [2:0] sub;
		begin
			if (k < 4) begin blo = dec_byte0; bhi = dec_byte1; end
			else       begin blo = dec_byte2; bhi = dec_byte3; end
			sub = 3'd3 - k[1:0];
			pen_at[3] = blo[7 - sub];
			pen_at[2] = blo[3 - sub];
			pen_at[1] = bhi[7 - sub];
			pen_at[0] = bhi[3 - sub];
		end
	endfunction

	wire [3:0] pen0 = pen_at(0);
	wire [3:0] pen1 = pen_at(1);
	wire [3:0] pen2 = pen_at(2);
	wire [3:0] pen3 = pen_at(3);
	wire [3:0] pen4 = pen_at(4);
	wire [3:0] pen5 = pen_at(5);
	wire [3:0] pen6 = pen_at(6);
	wire [3:0] pen7 = pen_at(7);

	// Posizione X del primo pixel della mezza-riga sullo schermo.
	wire signed [10:0] base_x = sp_x + ({6'd0, tile_x_pf, 4'd0});

	function signed [10:0] dx_at;
		input integer k;
		reg [4:0] eff_col;
		begin
			eff_col = sp_flipx ? (5'd15 - {pf_side, k[2:0]})
			                   : {pf_side, k[2:0]};
			dx_at = base_x + {6'd0, eff_col};
		end
	endfunction

	wire signed [10:0] dx0 = dx_at(0);
	wire signed [10:0] dx1 = dx_at(1);
	wire signed [10:0] dx2 = dx_at(2);
	wire signed [10:0] dx3 = dx_at(3);
	wire signed [10:0] dx4 = dx_at(4);
	wire signed [10:0] dx5 = dx_at(5);
	wire signed [10:0] dx6 = dx_at(6);
	wire signed [10:0] dx7 = dx_at(7);

	// Mask "scrivibile": pen != 15 e dx in [0,256) (Blood Bros 256 pixel)
	wire wr0 = (pen0 != 4'd15) && (dx0 >= 0) && (dx0 < 256);
	wire wr1 = (pen1 != 4'd15) && (dx1 >= 0) && (dx1 < 256);
	wire wr2 = (pen2 != 4'd15) && (dx2 >= 0) && (dx2 < 256);
	wire wr3 = (pen3 != 4'd15) && (dx3 >= 0) && (dx3 < 256);
	wire wr4 = (pen4 != 4'd15) && (dx4 >= 0) && (dx4 < 256);
	wire wr5 = (pen5 != 4'd15) && (dx5 >= 0) && (dx5 < 256);
	wire wr6 = (pen6 != 4'd15) && (dx6 >= 0) && (dx6 < 256);
	wire wr7 = (pen7 != 4'd15) && (dx7 >= 0) && (dx7 < 256);

	// Bank di destinazione per ogni step: dx[2:0]. Lane address: dx[7:3].
	wire [2:0] ln0 = dx0[2:0];   wire [4:0] rw0 = dx0[7:3];
	wire [2:0] ln1 = dx1[2:0];   wire [4:0] rw1_a = dx1[7:3];
	wire [2:0] ln2 = dx2[2:0];   wire [4:0] rw2_a = dx2[7:3];
	wire [2:0] ln3 = dx3[2:0];   wire [4:0] rw3_a = dx3[7:3];
	wire [2:0] ln4 = dx4[2:0];   wire [4:0] rw4_a = dx4[7:3];
	wire [2:0] ln5 = dx5[2:0];   wire [4:0] rw5_a = dx5[7:3];
	wire [2:0] ln6 = dx6[2:0];   wire [4:0] rw6_a = dx6[7:3];
	wire [2:0] ln7 = dx7[2:0];   wire [4:0] rw7_a = dx7[7:3];

	// Dato da scrivere per ogni step (formato linebuf 14-bit)
	wire [13:0] wd0 = {sp_color, sp_pri, 2'd0, pen0};
	wire [13:0] wd1 = {sp_color, sp_pri, 2'd0, pen1};
	wire [13:0] wd2 = {sp_color, sp_pri, 2'd0, pen2};
	wire [13:0] wd3 = {sp_color, sp_pri, 2'd0, pen3};
	wire [13:0] wd4 = {sp_color, sp_pri, 2'd0, pen4};
	wire [13:0] wd5 = {sp_color, sp_pri, 2'd0, pen5};
	wire [13:0] wd6 = {sp_color, sp_pri, 2'd0, pen6};
	wire [13:0] wd7 = {sp_color, sp_pri, 2'd0, pen7};

	reg        bank_we [0:7];
	reg [4:0]  bank_row [0:7];
	reg [13:0] bank_wd  [0:7];

	// Pipeline stage: registri dopo bank_select (catena combinatoria lunga
	// = priority encoder 8-vie con cascata di 28 confronti ln_X==ln_Y).
	reg        q_bank_we [0:7];
	reg [4:0]  q_bank_row [0:7];
	reg [13:0] q_bank_wd  [0:7];

	always @(*) begin : bank_select
		integer b;
		for (b = 0; b < 8; b = b + 1) begin
			bank_we[b]  = 1'b0;
			bank_row[b] = 5'd0;
			bank_wd[b]  = 14'd0;
		end
		// Priority encoder: step 0 vince in caso di collisione (raro).
		if (wr0) begin bank_we[ln0] = 1'b1; bank_row[ln0] = rw0;   bank_wd[ln0] = wd0; end
		if (wr1 && !(wr0 && ln0==ln1)) begin bank_we[ln1] = 1'b1; bank_row[ln1] = rw1_a; bank_wd[ln1] = wd1; end
		if (wr2 && !((wr0 && ln0==ln2) || (wr1 && ln1==ln2))) begin bank_we[ln2] = 1'b1; bank_row[ln2] = rw2_a; bank_wd[ln2] = wd2; end
		if (wr3 && !((wr0 && ln0==ln3) || (wr1 && ln1==ln3) || (wr2 && ln2==ln3))) begin bank_we[ln3] = 1'b1; bank_row[ln3] = rw3_a; bank_wd[ln3] = wd3; end
		if (wr4 && !((wr0 && ln0==ln4) || (wr1 && ln1==ln4) || (wr2 && ln2==ln4) || (wr3 && ln3==ln4))) begin bank_we[ln4] = 1'b1; bank_row[ln4] = rw4_a; bank_wd[ln4] = wd4; end
		if (wr5 && !((wr0 && ln0==ln5) || (wr1 && ln1==ln5) || (wr2 && ln2==ln5) || (wr3 && ln3==ln5) || (wr4 && ln4==ln5))) begin bank_we[ln5] = 1'b1; bank_row[ln5] = rw5_a; bank_wd[ln5] = wd5; end
		if (wr6 && !((wr0 && ln0==ln6) || (wr1 && ln1==ln6) || (wr2 && ln2==ln6) || (wr3 && ln3==ln6) || (wr4 && ln4==ln6) || (wr5 && ln5==ln6))) begin bank_we[ln6] = 1'b1; bank_row[ln6] = rw6_a; bank_wd[ln6] = wd6; end
		if (wr7 && !((wr0 && ln0==ln7) || (wr1 && ln1==ln7) || (wr2 && ln2==ln7) || (wr3 && ln3==ln7) || (wr4 && ln4==ln7) || (wr5 && ln5==ln7) || (wr6 && ln6==ln7))) begin bank_we[ln7] = 1'b1; bank_row[ln7] = rw7_a; bank_wd[ln7] = wd7; end
	end

	always @(posedge clk) begin
		if (reset) begin
			sc_state    <= SC_IDLE;
			entry_idx   <= 9'd511;
			tile_x_pf   <= 4'd0;
			rom_req     <= 1'b0;
			spr_addr    <= 11'd0;
			active_buf  <= 1'b0;
			clear_idx   <= 5'd0;
		end else begin
			case (sc_state)
				SC_IDLE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						// First-win: scan da entry 511 → 0
						entry_idx  <= 9'd511;
						tile_x_pf  <= 4'd0;
						clear_idx  <= 5'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				// CLEAR: 8 lane in parallelo → 32 cicli per 256 pixel.
				SC_CLEAR: begin
					// CLEAR: solo state/counter qui; i write effettivi avvengono
					// nell'unified write block sotto (per consentire M10K inference).
					if (clear_idx == 5'd31) begin
						clear_idx <= 5'd0;
						spr_addr  <= {entry_idx, 2'd0};
						sc_state  <= SC_RW0;
					end else begin
						clear_idx <= clear_idx + 5'd1;
					end
				end

				// OTTIMIZZAZIONE: leggo w0 e w3 PRIMA (servono per early-skip su
				// disable/fuori-Y). w1, w2 letti SOLO se sprite visibile. Risparmio
				// ~3 cicli sulla maggioranza degli sprite (la maggior parte dei 512
				// slot in BB è disabled o off-screen).
				SC_RW0: begin
					spr_addr <= {entry_idx, 2'd3};
					sc_state <= SC_RW1;
				end
				SC_RW1: begin
					sp_w0    <= spr_data;
					sc_state <= SC_RW3;
				end
				SC_RW3: begin
					sp_w3    <= spr_data;
					sc_state <= SC_CHECK;
				end

				SC_CHECK: begin
					if (sp_enable && in_y && layer_en) begin
						spr_addr <= {entry_idx, 2'd1};
						sc_state <= SC_RW2;
					end else begin
						sc_state <= SC_NEXT_E;
					end
				end

				SC_RW2: begin
					spr_addr <= {entry_idx, 2'd2};
					sc_state <= SC_CHECK2;
				end

				SC_CHECK2: begin
					sp_w1    <= spr_data;
					sc_state <= SC_CHECK2_W2;
				end

				SC_CHECK2_W2: begin
					sp_w2    <= spr_data;
					tile_x_pf <= 4'd0;
					pf_side   <= 1'b0;
					sc_state  <= SC_ROM_REQ;
				end

				SC_ROM_REQ: begin
					rom_addr <= ({4'd0, cur_tile, 7'd0})
					           + (pf_side ? 24'd64 : 24'd0)
					           + ({19'd0, eff_row, 2'd0});
					rom_req  <= 1'b1;
					sc_state <= SC_ROM_W;
				end

				SC_ROM_W: begin
					if (rom_valid) begin
						pf_rom_data <= rom_data;
						rom_req     <= 1'b0;
						sc_state    <= SC_DECODE;
					end
				end

				// DECODE PIPELINE STAGE 1: latch bank_select in registri.
				SC_DECODE: begin
					sc_state <= SC_DECODE_WR;
				end

				// DECODE PIPELINE STAGE 2: write paralleli ai bank da registri.
				SC_DECODE_WR: begin
					sc_state <= SC_NEXT_TX;
				end

				SC_NEXT_TX: begin
					if (pf_side == 1'b0) begin
						pf_side  <= 1'b1;
						sc_state <= SC_ROM_REQ;
					end else begin
						pf_side <= 1'b0;
						if (tile_x_pf == sp_w - 4'd1) begin
							sc_state <= SC_NEXT_E;
						end else begin
							tile_x_pf <= tile_x_pf + 4'd1;
							sc_state  <= SC_ROM_REQ;
						end
					end
				end

				SC_NEXT_E: begin
					if (entry_idx == 9'd0) begin
						sc_state <= SC_DONE;
					end else begin
						entry_idx <= entry_idx - 9'd1;
						spr_addr  <= {entry_idx - 9'd1, 2'd0};
						sc_state  <= SC_RW0;
					end
				end

				SC_DONE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						entry_idx  <= 9'd511;
						tile_x_pf  <= 4'd0;
						clear_idx  <= 5'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				default: sc_state <= SC_IDLE;
			endcase
		end
	end

	// ─── Pipeline stage 1: latch bank_select in registri durante SC_DECODE ──
	always @(posedge clk) begin
		if (sc_state == SC_DECODE) begin
			q_bank_we[0]  <= bank_we[0];  q_bank_row[0] <= bank_row[0];  q_bank_wd[0] <= bank_wd[0];
			q_bank_we[1]  <= bank_we[1];  q_bank_row[1] <= bank_row[1];  q_bank_wd[1] <= bank_wd[1];
			q_bank_we[2]  <= bank_we[2];  q_bank_row[2] <= bank_row[2];  q_bank_wd[2] <= bank_wd[2];
			q_bank_we[3]  <= bank_we[3];  q_bank_row[3] <= bank_row[3];  q_bank_wd[3] <= bank_wd[3];
			q_bank_we[4]  <= bank_we[4];  q_bank_row[4] <= bank_row[4];  q_bank_wd[4] <= bank_wd[4];
			q_bank_we[5]  <= bank_we[5];  q_bank_row[5] <= bank_row[5];  q_bank_wd[5] <= bank_wd[5];
			q_bank_we[6]  <= bank_we[6];  q_bank_row[6] <= bank_row[6];  q_bank_wd[6] <= bank_wd[6];
			q_bank_we[7]  <= bank_we[7];  q_bank_row[7] <= bank_row[7];  q_bank_wd[7] <= bank_wd[7];
		end
	end

	// ─── Unified write block per bank (1 write port logico → M10K) ──────────
	// Mux address/data tra CLEAR e DECODE_WR. Quartus vede 1 write port.
	wire wr1_clear  = (sc_state == SC_CLEAR)     && (active_buf == 1'b0);
	wire wr1_decode = (sc_state == SC_DECODE_WR) && (active_buf == 1'b0);
	wire wr0_clear  = (sc_state == SC_CLEAR)     && (active_buf == 1'b1);
	wire wr0_decode = (sc_state == SC_DECODE_WR) && (active_buf == 1'b1);

	wire        wr1_we [0:7];
	wire [4:0]  wr1_a  [0:7];
	wire [13:0] wr1_d  [0:7];
	wire        wr0_we [0:7];
	wire [4:0]  wr0_a  [0:7];
	wire [13:0] wr0_d  [0:7];

	genvar gb;
	generate
		for (gb = 0; gb < 8; gb = gb + 1) begin : gen_wr_mux
			assign wr1_we[gb] = wr1_clear | (wr1_decode & q_bank_we[gb]);
			assign wr1_a[gb]  = wr1_clear ? clear_idx : q_bank_row[gb];
			assign wr1_d[gb]  = wr1_clear ? LB_EMPTY  : q_bank_wd[gb];
			assign wr0_we[gb] = wr0_clear | (wr0_decode & q_bank_we[gb]);
			assign wr0_a[gb]  = wr0_clear ? clear_idx : q_bank_row[gb];
			assign wr0_d[gb]  = wr0_clear ? LB_EMPTY  : q_bank_wd[gb];
		end
	endgenerate

	always @(posedge clk) begin
		if (wr1_we[0]) linebuf1_b0[wr1_a[0]] <= wr1_d[0];
		if (wr1_we[1]) linebuf1_b1[wr1_a[1]] <= wr1_d[1];
		if (wr1_we[2]) linebuf1_b2[wr1_a[2]] <= wr1_d[2];
		if (wr1_we[3]) linebuf1_b3[wr1_a[3]] <= wr1_d[3];
		if (wr1_we[4]) linebuf1_b4[wr1_a[4]] <= wr1_d[4];
		if (wr1_we[5]) linebuf1_b5[wr1_a[5]] <= wr1_d[5];
		if (wr1_we[6]) linebuf1_b6[wr1_a[6]] <= wr1_d[6];
		if (wr1_we[7]) linebuf1_b7[wr1_a[7]] <= wr1_d[7];
		if (wr0_we[0]) linebuf0_b0[wr0_a[0]] <= wr0_d[0];
		if (wr0_we[1]) linebuf0_b1[wr0_a[1]] <= wr0_d[1];
		if (wr0_we[2]) linebuf0_b2[wr0_a[2]] <= wr0_d[2];
		if (wr0_we[3]) linebuf0_b3[wr0_a[3]] <= wr0_d[3];
		if (wr0_we[4]) linebuf0_b4[wr0_a[4]] <= wr0_d[4];
		if (wr0_we[5]) linebuf0_b5[wr0_a[5]] <= wr0_d[5];
		if (wr0_we[6]) linebuf0_b6[wr0_a[6]] <= wr0_d[6];
		if (wr0_we[7]) linebuf0_b7[wr0_a[7]] <= wr0_d[7];
	end

	// ─── Read side sincrono (M10K-compatible) ────────────────────────────────
	// Prefetch a hpos+1 enabled da ce_pix. Matematica: valore@T = linebuf
	// [hpos_pre@T-1] = linebuf[hpos@T-1 + 1] = linebuf[hpos@T] (identico
	// al comportamento combinatorio precedente, no shift visivo).
	wire [9:0] hpos_pre = hpos + 10'd1;
	wire [2:0] pre_lane = hpos_pre[2:0];
	wire [4:0] pre_row  = hpos_pre[7:3];

	reg [13:0] rdq0_b0, rdq0_b1, rdq0_b2, rdq0_b3, rdq0_b4, rdq0_b5, rdq0_b6, rdq0_b7;
	reg [13:0] rdq1_b0, rdq1_b1, rdq1_b2, rdq1_b3, rdq1_b4, rdq1_b5, rdq1_b6, rdq1_b7;
	reg [2:0]  rd_lane_d;
	reg        active_buf_d;
	always @(posedge clk) begin
		if (ce_pix) begin
			rdq0_b0 <= linebuf0_b0[pre_row];
			rdq0_b1 <= linebuf0_b1[pre_row];
			rdq0_b2 <= linebuf0_b2[pre_row];
			rdq0_b3 <= linebuf0_b3[pre_row];
			rdq0_b4 <= linebuf0_b4[pre_row];
			rdq0_b5 <= linebuf0_b5[pre_row];
			rdq0_b6 <= linebuf0_b6[pre_row];
			rdq0_b7 <= linebuf0_b7[pre_row];
			rdq1_b0 <= linebuf1_b0[pre_row];
			rdq1_b1 <= linebuf1_b1[pre_row];
			rdq1_b2 <= linebuf1_b2[pre_row];
			rdq1_b3 <= linebuf1_b3[pre_row];
			rdq1_b4 <= linebuf1_b4[pre_row];
			rdq1_b5 <= linebuf1_b5[pre_row];
			rdq1_b6 <= linebuf1_b6[pre_row];
			rdq1_b7 <= linebuf1_b7[pre_row];
			rd_lane_d    <= pre_lane;
			active_buf_d <= active_buf;
		end
	end

	reg [13:0] read_data;
	always @(*) begin
		if (active_buf_d) begin
			case (rd_lane_d)
				3'd0: read_data = rdq1_b0;
				3'd1: read_data = rdq1_b1;
				3'd2: read_data = rdq1_b2;
				3'd3: read_data = rdq1_b3;
				3'd4: read_data = rdq1_b4;
				3'd5: read_data = rdq1_b5;
				3'd6: read_data = rdq1_b6;
				3'd7: read_data = rdq1_b7;
			endcase
		end else begin
			case (rd_lane_d)
				3'd0: read_data = rdq0_b0;
				3'd1: read_data = rdq0_b1;
				3'd2: read_data = rdq0_b2;
				3'd3: read_data = rdq0_b3;
				3'd4: read_data = rdq0_b4;
				3'd5: read_data = rdq0_b5;
				3'd6: read_data = rdq0_b6;
				3'd7: read_data = rdq0_b7;
			endcase
		end
	end

	wire  [3:0] read_pen   = read_data[3:0];
	wire  [1:0] read_pri   = read_data[7:6];
	wire  [5:0] read_color = read_data[13:8];

	wire pixel_active = de & layer_en & (hpos < 10'd256) & (read_pen != 4'd15);
	assign opaque    = pixel_active;
	assign pen_index = pixel_active ? {1'b0, read_color, read_pen} : 11'd0;
	assign pri_code  = pixel_active ? read_pri : 2'd0;

endmodule
