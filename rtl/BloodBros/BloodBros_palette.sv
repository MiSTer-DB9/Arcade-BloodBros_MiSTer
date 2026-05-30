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

/*  Palette RAM Seibu Blood Bros (xBGR_444, 2048 entries).

    MAME: PALETTE(config, m_palette).set_format(palette_device::xBGR_444, 2048);
    Address space CPU: 0x08E800..0x08F7FF (4 KB = 2048 word).

    Layout word 16-bit (Blood Bros xBGR_444):
      bit15:12 : unused (x)
      bit11:8  : B (4-bit)
      bit7:4   : G (4-bit)
      bit3:0   : R (4-bit)

    Espansione 5→8 bit con replica top-bits (standard MiSTer / MAME palette_device).

    Modulo true dual-port:
      Port A (CPU)   : RW byte-enabled (main 68k a $08E800)
      Port B (video) : RO 11-bit index → 24-bit RGB
*/

module BloodBros_palette (
	input  wire         clk,
	// Port A: CPU
	input  wire         a_we,
	input  wire   [1:0] a_be,        // byte enable: a_be[1]=hi byte, a_be[0]=lo byte
	input  wire  [10:0] a_addr,
	input  wire  [15:0] a_din,
	output reg   [15:0] a_dout,
	// Port B: video read
	input  wire  [10:0] b_addr,
	output wire   [7:0] b_r,
	output wire   [7:0] b_g,
	output wire   [7:0] b_b
);

	// Split in due BRAM byte (true dual-port con write byte-enable)
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_hi [0:2047];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_lo [0:2047];

	// synthesis translate_off
	integer i;
	initial begin
		for (i = 0; i < 2048; i = i + 1) begin
			mem_hi[i] = 8'h00;
			mem_lo[i] = 8'h00;
		end
	end
	// synthesis translate_on

	reg [7:0] a_dout_hi, a_dout_lo;
	reg [7:0] b_dout_hi, b_dout_lo;

	always @(posedge clk) begin
		// Port A
		if (a_we & a_be[1]) mem_hi[a_addr] <= a_din[15:8];
		if (a_we & a_be[0]) mem_lo[a_addr] <= a_din[7:0];
		a_dout_hi <= mem_hi[a_addr];
		a_dout_lo <= mem_lo[a_addr];
		// Port B (read-only)
		b_dout_hi <= mem_hi[b_addr];
		b_dout_lo <= mem_lo[b_addr];
	end

	always @(*) a_dout = {a_dout_hi, a_dout_lo};

	// Blood Bros: xBGR_444 → RGB888 (MAME bloodbro.cpp:859 set_format xBGR_444)
	// Layout: bit[11:8]=R, bit[7:4]=G, bit[3:0]=B. 4 bit per canale.
	// Replica 4→8 standard: {nibble, nibble} (MAME palette_device standard expansion)
	wire [15:0] b_word = {b_dout_hi, b_dout_lo};
	wire [3:0] vr4 = b_word[3:0];
	wire [3:0] vg4 = b_word[7:4];
	wire [3:0] vb4 = b_word[11:8];

	assign b_r = {vr4, vr4};
	assign b_g = {vg4, vg4};
	assign b_b = {vb4, vb4};

endmodule
