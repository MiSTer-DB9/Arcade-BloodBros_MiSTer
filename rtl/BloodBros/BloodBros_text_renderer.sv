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

/*  Text layer renderer Seibu D-Con (8x8, 4bpp, 64x32).

    Specifiche da MAME (src/mame/seibu/dcon.cpp):

      // get_text_tile_info
      tile  = textram[tile_index];
      color = (tile >> 12) & 0xf;
      tile  = tile & 0xfff;
      tileinfo.set(0, tile, color, 0);

      // create
      m_text_layer = create(... TILEMAP_SCAN_ROWS, 8, 8, 64, 32);
      m_text_layer->set_transparent_pen(15);

      // GFXDECODE
      GFXDECODE_ENTRY("txtiles", 0, dcon_charlayout, 1024+768, 16);
      // → color base = 0x700, 16 colorset

      // sdgndmps_map dispatcher
      m_text_layer->set_scrollx(0, 128);
      m_text_layer->set_scrolly(0, 0);

      // dcon_charlayout
      8x8, RGN_FRAC(1,2), 4 bpp,
      planes  = { 0, 4, 0x80000, 0x80004 },     // bit-offset
      x_bits  = { 3,2,1,0, 11,10,9,8 },         // pixel→bit-offset
      y_bits  = { 0,16,32,...,7*16 },
      tile_size = 128 bit (= 16 byte per metà)

    Char ROM mapping in SDRAM (vedi MRA):
      0x080000..0x08FFFF (64KB): planes 0,1 (= ROM 911-a08.66)
      0x090000..0x09FFFF (64KB): planes 2,3 (= ROM 911-a07.73)

    Cache strategy: 128KB BRAM totali (32 M10K), tutti i 4096 char,
    caricati durante MRA download via ioctl_addr 0x080000..0x09FFFF.

    Pixel decode per (col, row) di char idx:
      byte_lo = char_lo[idx*16 + row*2 + (col>=4 ? 1 : 0)]
      byte_hi = char_hi[idx*16 + row*2 + (col>=4 ? 1 : 0)]
      sub     = 3 - (col & 3)
      pen[0]  = byte_lo[sub]
      pen[1]  = byte_lo[sub+4]
      pen[2]  = byte_hi[sub]
      pen[3]  = byte_hi[sub+4]

    Pen finale a palette = 0x700 + (color << 4) + pen, transparent se pen==15.
*/

module BloodBros_text_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	// Video timing
	input  wire  [9:0] hpos,        // 0..383
	input  wire  [8:0] vpos,        // 0..262
	input  wire        de,
	input  wire        layer_en,

	// CRTC scroll (SD Gundam Text: 128 X, 0 Y; lasciamo input parametrico)
	input  wire [15:0] scroll_x,
	input  wire [15:0] scroll_y,

	// OSD offset di rendering (debug pixel-hunting)
	input  wire signed [9:0] xoff,
	input  wire signed [9:0] yoff,

	// Text VRAM read port (4KB = 2Kw, 64*32 grid)
	output reg  [10:0] vram_addr,   // 0..2047
	input  wire [15:0] vram_data,

	// Char ROM download via ioctl (WIDE=1 → 2 byte/word a indirizzi pari)
	// rom_dl_addr = byte address relativo al txtiles (0..0x1FFFF), [0]=0
	// rom_dl_data = {byte_high, byte_low}: byte_low scritto a addr, byte_high a addr+1
	//   bit[16] = 0 → metà bassa (plane 0,1)
	//   bit[16] = 1 → metà alta  (plane 2,3)
	input  wire        rom_dl_wr,
	input  wire [16:0] rom_dl_addr,
	input  wire [15:0] rom_dl_data,

	// Output pixel (combinatoriale: riduce latency totale di 1 ce_pix → match DCon)
	output wire        opaque,
	output wire [10:0] pen_index    // 0x700 + (color<<4) + pen
);

	// ── Char ROM cache: 64KB lo + 64KB hi organizzati come 32Kw 16-bit ──────
	// (Organizzazione naturale per Quartus → infer M10K word-mode veloce)
	// rom_dl_addr[16:1] = word index (0..32767), rom_dl_addr[16] = mezzo
	reg [15:0] charrom_lo [0:32767];
	reg [15:0] charrom_hi [0:32767];
	always @(posedge clk) begin
		if (rom_dl_wr) begin
			if (rom_dl_addr[16] == 1'b0) charrom_lo[rom_dl_addr[15:1]] <= rom_dl_data;
			else                          charrom_hi[rom_dl_addr[15:1]] <= rom_dl_data;
		end
	end

	// ── Pipeline ──────────────────────────────────────────────────────────────
	// Stage 0: input hpos/vpos → calc tile coords, emit vram_addr
	// Stage 1: vram_data registered, calc charrom addr
	// Stage 2: charrom byte_lo/byte_hi registered, decode pen
	// Stage 3: pen + color → pen_index latched

	// --- Stage 0: tile coords ---
	// Gate spaziale: tilemap text 32×32 = 256 px = larghezza schermo BB.
	// Il "wrap" mod 32 cadrebbe in mezzo allo schermo con xoff≠0 → "1UP" tagliato.
	// Soluzione: eff_x signed, marco fuori-range [0..255] → trasparente.
	// Wrap quindi cade SEMPRE a hpos=0 (off-screen) qualsiasi sia xoff.
	// Compensazione latency pipeline: 3 ce_pix tra hpos input e pen visualizzato
	// dal composite. Senza anticipo, screen X=0 mostra pen del tile letto a
	// timing_hpos=46 (HBLANK 0x3FE) → "1" appare a X=3 invece di X=0.
	// Con +3, screen X=0 mostra pen di hpos input=3 → ma de_s2=0 ancora per i
	// primi 3 pixel screen. Per allineare, devo anche bypassare il de_s2 latency:
	// uso direttamente il `de` corrente nell'output (sotto).
	wire signed [10:0] eff_x_s = $signed({1'b0, hpos}) + 11'sd3 + $signed(scroll_x[10:0])
	                            + $signed({xoff[9], xoff});
	wire signed [10:0] eff_y_s = $signed({1'b0, 1'b0, vpos}) + $signed(scroll_y[10:0])
	                            + $signed({yoff[9], yoff});
	wire        x_in_range_s0 = (eff_x_s >= 11'sd0) && (eff_x_s < 11'sd384);
	wire  [4:0] tile_x_s0 = eff_x_s[7:3];
	wire  [4:0] tile_y_s0 = eff_y_s[7:3];
	wire  [2:0] row_s0    = eff_y_s[2:0];
	wire  [2:0] col_s0    = eff_x_s[2:0];

	always @(posedge clk) begin
		if (ce_pix) vram_addr <= {1'b0, tile_y_s0, tile_x_s0};
	end

	// --- Stage 1: vram_data, decode tile + color ---
	reg [2:0] row_s1, col_s1;
	reg       de_s1, layer_en_s1, x_in_range_s1;
	always @(posedge clk) begin
		if (ce_pix) begin
			row_s1        <= row_s0;
			col_s1        <= col_s0;
			de_s1         <= de;
			layer_en_s1   <= layer_en;
			x_in_range_s1 <= x_in_range_s0;
		end
	end

	wire [11:0] tile_idx_s1 = vram_data[11:0];
	wire  [3:0] tile_clr_s1 = vram_data[15:12];

	wire [14:0] crom_word_s1 = ({3'd0, tile_idx_s1}) << 3
	                          | ({12'd0, row_s1});
	wire        crom_byte_sel_s1 = col_s1[2];

	// --- Stage 2: charrom word read ---
	reg [15:0] crom_lo_word_s2, crom_hi_word_s2;
	reg        crom_byte_sel_s2;
	reg [2:0]  col_s2;
	reg [3:0]  tile_clr_s2;
	reg        de_s2, layer_en_s2, x_in_range_s2;
	always @(posedge clk) begin
		if (ce_pix) begin
			crom_lo_word_s2  <= charrom_lo[crom_word_s1];
			crom_hi_word_s2  <= charrom_hi[crom_word_s1];
			crom_byte_sel_s2 <= crom_byte_sel_s1;
			col_s2           <= col_s1;
			tile_clr_s2      <= tile_clr_s1;
			de_s2            <= de_s1;
			layer_en_s2      <= layer_en_s1;
			x_in_range_s2    <= x_in_range_s1;
		end
	end

	wire [7:0] crom_lo_s2 = crom_byte_sel_s2 ? crom_lo_word_s2[15:8] : crom_lo_word_s2[7:0];
	wire [7:0] crom_hi_s2 = crom_byte_sel_s2 ? crom_hi_word_s2[15:8] : crom_hi_word_s2[7:0];

	// --- Stage 3: pen decode ---
	wire [1:0] sub = 2'd3 - col_s2[1:0];
	wire pen0 = crom_lo_s2[3 - {1'b0, sub}];
	wire pen1 = crom_lo_s2[7 - {1'b0, sub}];
	wire pen2 = crom_hi_s2[3 - {1'b0, sub}];
	wire pen3 = crom_hi_s2[7 - {1'b0, sub}];
	wire [3:0] pen = {pen3, pen2, pen1, pen0};

	// Output stage combinatoriale (no reg finale): elimina 1 ce_pix di latency,
	// uguale a DCon_text_renderer.sv. Senza questo, il pen mostrato a screen col 0
	// corrisponde a hpos=-1 (HBLANK 0x3FF), che con tile_x=eff_x[7:3]=31 produce
	// il tile della colonna sbagliata → "1" di 1UP tagliato/wrappato.
	// `de` e `layer_en` corrente (non `_s2`): vedere commento eff_x_s sopra.
	// Latency pen compensata da +3 in eff_x_s, gate `de` deve essere CORRENTE
	// (rispetta visarea screen reale).
	wire pixel_active = de & layer_en & (pen != 4'd15);
	assign opaque    = pixel_active;
	assign pen_index = pixel_active ? (11'h700 + {3'd0, tile_clr_s2, pen}) : 11'd0;

endmodule
