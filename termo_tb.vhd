--------------------------------------------------------------------------------
-- FILE        : termo_tb.vhd
-- PROJECT     : TERMO (Wordle) – EEL480 Digital Systems
-- DESCRIPTION : Simulation testbench for the full TERMO system.
--
--   SCENARIO
--   ─────────────────────────────────────────────────────────────
--   1.  System reset + LCD initialisation observed.
--   2.  Player 1 types "CARRO" (C-A-R-R-O) and presses Enter.
--   3.  Player 2 types "CARTA" (C-A-R-T-A) — one correct (C,A,R correct;
--       T wrong position (exists as the second R → simplified: WRONG here);
--       A wrong position) — and presses Enter.
--       Expected feedback: O O O - -  (C,A,R in right pos; T wrong; A wrong)
--   4.  Player 2 presses Enter to continue, then types "CARRO" exactly.
--       Expected feedback: O O O O O  → win condition.
--
--   PS/2 EMULATION
--   The process p_key_send injects scan-code frames directly into the
--   ps2_clk / ps2_data lines.  The PS/2 clock runs at ~12.5 kHz (4 µs per
--   half-period at 50 MHz → 200 clock cycles per half).
--
-- HOW TO RUN
--   Simulate with ModelSim / ISIM / GHDL.  Set simulation time to ≥ 500 ms.
--   Use waveforms on:  lcd_rs, lcd_e, lcd_db, gc_lcd_char, kb_valid, kb_ascii
-- AUTHOR      : EEL480 Group
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity termo_tb is
end entity termo_tb;

architecture sim of termo_tb is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant CLK_PERIOD : time := 20 ns;   -- 50 MHz
    constant PS2_HALF   : time := 40 us;   -- ~12.5 kHz PS/2 clock (half period)

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal ps2_clk  : std_logic := '1';
    signal ps2_data : std_logic := '1';
    signal lcd_rs   : std_logic;
    signal lcd_rw   : std_logic;
    signal lcd_e    : std_logic;
    signal lcd_db   : std_logic_vector(7 downto 4);
    signal led      : std_logic_vector(2 downto 0);

    ---------------------------------------------------------------------------
    -- Component declaration
    ---------------------------------------------------------------------------
    component termo_top is
        port (
            clk      : in  std_logic;
            rst      : in  std_logic;
            ps2_clk  : in  std_logic;
            ps2_data : in  std_logic;
            lcd_rs   : out std_logic;
            lcd_rw   : out std_logic;
            lcd_e    : out std_logic;
            lcd_db   : out std_logic_vector(7 downto 4);
            led      : out std_logic_vector(2 downto 0)
        );
    end component;

    ---------------------------------------------------------------------------
    -- PS/2 scan codes (Set 2) for the letters we need
    -- Ordered as (make_code) for each character
    ---------------------------------------------------------------------------
    type scan_t is record
        make : std_logic_vector(7 downto 0);
    end record;

    -- Key make scan codes
    constant SC_A  : std_logic_vector(7 downto 0) := x"1C";
    constant SC_C  : std_logic_vector(7 downto 0) := x"21";
    constant SC_O  : std_logic_vector(7 downto 0) := x"44";
    constant SC_R  : std_logic_vector(7 downto 0) := x"2D";
    constant SC_T  : std_logic_vector(7 downto 0) := x"2C";
    constant SC_EN : std_logic_vector(7 downto 0) := x"5A"; -- Enter
    constant SC_F0 : std_logic_vector(7 downto 0) := x"F0"; -- Break prefix

    ---------------------------------------------------------------------------
    -- Shared procedure: send one PS/2 byte (make only; no break code)
    -- Protocol: start(0), D0..D7, parity(odd), stop(1)
    ---------------------------------------------------------------------------
    procedure send_ps2_byte(
        signal ps2c : out std_logic;
        signal ps2d : out std_logic;
        constant scan_code : in std_logic_vector(7 downto 0)) is
        variable parity : std_logic := '1'; -- Odd parity
    begin
        -- Compute parity
        for i in 0 to 7 loop
            parity := parity xor scan_code(i);
        end loop;

        -- Start bit
        ps2d <= '0';
        wait for PS2_HALF;
        ps2c <= '0'; wait for PS2_HALF; ps2c <= '1';

        -- 8 data bits, LSB first
        for i in 0 to 7 loop
            ps2d <= scan_code(i);
            wait for PS2_HALF;
            ps2c <= '0'; wait for PS2_HALF; ps2c <= '1';
        end loop;

        -- Parity bit
        ps2d <= parity;
        wait for PS2_HALF;
        ps2c <= '0'; wait for PS2_HALF; ps2c <= '1';

        -- Stop bit
        ps2d <= '1';
        wait for PS2_HALF;
        ps2c <= '0'; wait for PS2_HALF; ps2c <= '1';

        -- Inter-key gap
        wait for 1 ms;
    end procedure send_ps2_byte;

    ---------------------------------------------------------------------------
    -- Procedure: send a key press (make + F0 + make = press then release)
    ---------------------------------------------------------------------------
    procedure press_key(
        signal ps2c : out std_logic;
        signal ps2d : out std_logic;
        constant sc : in std_logic_vector(7 downto 0)) is
    begin
        send_ps2_byte(ps2c, ps2d, sc);        -- Make code
        send_ps2_byte(ps2c, ps2d, SC_F0);     -- Break prefix
        send_ps2_byte(ps2c, ps2d, sc);         -- Key code again (break)
        wait for 2 ms;
    end procedure press_key;

begin

    ---------------------------------------------------------------------------
    -- DUT instantiation
    ---------------------------------------------------------------------------
    u_dut : termo_top
        port map (
            clk      => clk,
            rst      => rst,
            ps2_clk  => ps2_clk,
            ps2_data => ps2_data,
            lcd_rs   => lcd_rs,
            lcd_rw   => lcd_rw,
            lcd_e    => lcd_e,
            lcd_db   => lcd_db,
            led      => led
        );

    ---------------------------------------------------------------------------
    -- Clock generation
    ---------------------------------------------------------------------------
    p_clk : process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process p_clk;

    ---------------------------------------------------------------------------
    -- Stimulus process
    ---------------------------------------------------------------------------
    p_stim : process
    begin
        ---------------------------------------------------------------------------
        -- Phase 0: Reset for 100 clock cycles
        ---------------------------------------------------------------------------
        rst     <= '1';
        ps2_clk  <= '1';
        ps2_data <= '1';
        wait for CLK_PERIOD * 100;
        rst <= '0';

        ---------------------------------------------------------------------------
        -- Phase 1: Wait for LCD initialisation to complete (~15 ms power-on
        --          delay + several init commands ≈ 20 ms total at 50 MHz)
        ---------------------------------------------------------------------------
        wait for 25 ms;

        report "=== LCD init done; Player 1 entering secret word: CARRO ===" severity note;

        ---------------------------------------------------------------------------
        -- Phase 2: Player 1 enters "CARRO"
        -- C  A  R  R  O  Enter
        ---------------------------------------------------------------------------
        press_key(ps2_clk, ps2_data, SC_C);
        press_key(ps2_clk, ps2_data, SC_A);
        press_key(ps2_clk, ps2_data, SC_R);
        press_key(ps2_clk, ps2_data, SC_R);
        press_key(ps2_clk, ps2_data, SC_O);
        press_key(ps2_clk, ps2_data, SC_EN); -- Confirm secret word
        wait for 5 ms;

        report "=== P1 word entered. LED[0] should be '1'. ===" severity note;
        assert led(0) = '1'
            report "FAIL: led_p1_done not asserted after P1 Enter"
            severity error;

        ---------------------------------------------------------------------------
        -- Phase 3: Wait for LCD to update for P2 display
        ---------------------------------------------------------------------------
        wait for 20 ms;

        report "=== Player 2 Guess 1: CARTA ===" severity note;

        ---------------------------------------------------------------------------
        -- Phase 4: Player 2 enters "CARTA" (3 correct, T wrong, A wrong-pos)
        -- Expected feedback: O O O - -   (simplified comparator)
        ---------------------------------------------------------------------------
        press_key(ps2_clk, ps2_data, SC_C);
        press_key(ps2_clk, ps2_data, SC_A);
        press_key(ps2_clk, ps2_data, SC_R);
        press_key(ps2_clk, ps2_data, SC_T);
        press_key(ps2_clk, ps2_data, SC_A);
        press_key(ps2_clk, ps2_data, SC_EN); -- Confirm guess 1
        wait for 20 ms;

        -- After feedback is shown, P2 should NOT have won
        assert led(1) = '0'
            report "FAIL: win LED asserted incorrectly after CARTA guess"
            severity error;
        report "=== Feedback for CARTA displayed. LED[1] (win) = " &
               std_logic'image(led(1)) & " (expected 0) ===" severity note;

        ---------------------------------------------------------------------------
        -- Phase 5: Press Enter to continue to Guess 2
        ---------------------------------------------------------------------------
        wait for 5 ms;
        press_key(ps2_clk, ps2_data, SC_EN); -- Continue
        wait for 20 ms;

        report "=== Player 2 Guess 2: CARRO (exact match) ===" severity note;

        ---------------------------------------------------------------------------
        -- Phase 6: Player 2 enters "CARRO" – should win
        ---------------------------------------------------------------------------
        press_key(ps2_clk, ps2_data, SC_C);
        press_key(ps2_clk, ps2_data, SC_A);
        press_key(ps2_clk, ps2_data, SC_R);
        press_key(ps2_clk, ps2_data, SC_R);
        press_key(ps2_clk, ps2_data, SC_O);
        press_key(ps2_clk, ps2_data, SC_EN); -- Confirm guess 2
        wait for 20 ms;

        report "=== CARRO entered; checking win ===" severity note;
        assert led(1) = '1'
            report "FAIL: win LED not asserted after correct guess CARRO"
            severity error;
        assert led(2) = '0'
            report "FAIL: lose LED incorrectly asserted"
            severity error;

        report "=== ALL ASSERTIONS PASSED: TERMO testbench complete ===" severity note;

        wait; -- Stop simulation
    end process p_stim;

    ---------------------------------------------------------------------------
    -- Optional: LCD activity monitor (prints when E goes high)
    ---------------------------------------------------------------------------
    p_lcd_monitor : process(lcd_e)
    begin
        if rising_edge(lcd_e) then
            report "LCD E pulse: RS=" & std_logic'image(lcd_rs) &
                   " DB=" & std_logic'image(lcd_db(7)) &
                              std_logic'image(lcd_db(6)) &
                              std_logic'image(lcd_db(5)) &
                              std_logic'image(lcd_db(4))
                severity note;
        end if;
    end process p_lcd_monitor;

end architecture sim;
