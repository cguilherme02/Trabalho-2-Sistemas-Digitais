--------------------------------------------------------------------------------
-- FILE        : termo_top.vhd
-- PROJECT     : TERMO (Wordle) – EEL480 Digital Systems
-- BOARD       : Digilent Spartan-3AN Starter Kit (XC3S700AN-FGG484)
-- DESCRIPTION : Top-level structural entity.
--               Instantiates and interconnects:
--                  u_kb   – ps2_keyboard    (PS/2 ↔ ASCII)
--                  u_lcd  – lcd_controller  (HD44780 4-bit driver)
--                  u_cmp  – word_comparator (combinational feedback)
--                  u_game – game_controller (game FSM + LCD write helper)
--
--   External signal summary
--   ─────────────────────────────────────────────────────────────
--   clk          : 50 MHz board oscillator
--   rst          : Active-HIGH reset (mapped to BTN_SOUTH / BTN0)
--   ps2_clk      : PS/2 keyboard clock  (open-collector, pulled up)
--   ps2_data     : PS/2 keyboard data   (open-collector, pulled up)
--   lcd_rs/rw/e  : HD44780 control pins
--   lcd_db[7:4]  : HD44780 4-bit data bus (upper nibble)
--   led[0]       : Player-1 word entered
--   led[1]       : Player-2 won
--   led[2]       : Player-2 lost (max attempts)
-- AUTHOR      : EEL480 Group
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity termo_top is
    port (
        -- System
        clk       : in  std_logic;                    -- 50 MHz board clock
        rst       : in  std_logic;                    -- Active-high reset (BTN_SOUTH)
        -- PS/2 keyboard
        ps2_clk   : in  std_logic;                    -- PS/2 clock
        ps2_data  : in  std_logic;                    -- PS/2 data
        -- LCD (4-bit mode, HD44780)
        lcd_rs    : out std_logic;
        lcd_rw    : out std_logic;
        lcd_e     : out std_logic;
        lcd_db    : out std_logic_vector(7 downto 4); -- Only D7..D4 connected
        -- Status LEDs
        led       : out std_logic_vector(2 downto 0)  -- [0]=P1 done, [1]=win, [2]=lose
    );
end entity termo_top;

architecture structural of termo_top is

    ---------------------------------------------------------------------------
    -- Component declarations
    ---------------------------------------------------------------------------
    component ps2_keyboard is
        port (
            clk       : in  std_logic;
            rst       : in  std_logic;
            ps2_clk   : in  std_logic;
            ps2_data  : in  std_logic;
            ascii_out : out std_logic_vector(7 downto 0);
            key_valid : out std_logic
        );
    end component;

    component lcd_controller is
        port (
            clk        : in  std_logic;
            rst        : in  std_logic;
            lcd_char   : in  std_logic_vector(7 downto 0);
            lcd_rs_in  : in  std_logic;
            lcd_send   : in  std_logic;
            lcd_busy   : out std_logic;
            lcd_rs     : out std_logic;
            lcd_rw     : out std_logic;
            lcd_e      : out std_logic;
            lcd_db     : out std_logic_vector(7 downto 4)
        );
    end component;

    component word_comparator is
        port (
            secret_in   : in  std_logic_vector(39 downto 0);
            guess_in    : in  std_logic_vector(39 downto 0);
            feedback    : out std_logic_vector(9  downto 0);
            all_correct : out std_logic
        );
    end component;

    component game_controller is
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            ascii_in     : in  std_logic_vector(7 downto 0);
            key_valid    : in  std_logic;
            lcd_char_out : out std_logic_vector(7 downto 0);
            lcd_rs_out   : out std_logic;
            lcd_send_out : out std_logic;
            lcd_busy     : in  std_logic;
            secret_out   : out std_logic_vector(39 downto 0);
            guess_out    : out std_logic_vector(39 downto 0);
            fb_in        : in  std_logic_vector(9 downto 0);
            win_in       : in  std_logic;
            led_p1_done  : out std_logic;
            led_win      : out std_logic;
            led_lose     : out std_logic
        );
    end component;

    ---------------------------------------------------------------------------
    -- Internal interconnect signals
    ---------------------------------------------------------------------------

    -- PS/2 keyboard → game controller
    signal kb_ascii    : std_logic_vector(7 downto 0);
    signal kb_valid    : std_logic;

    -- Game controller → LCD controller
    signal gc_lcd_char : std_logic_vector(7 downto 0);
    signal gc_lcd_rs   : std_logic;
    signal gc_lcd_send : std_logic;

    -- LCD controller → game controller
    signal lc_busy     : std_logic;

    -- Game controller → word comparator
    signal gc_secret   : std_logic_vector(39 downto 0);
    signal gc_guess    : std_logic_vector(39 downto 0);

    -- Word comparator → game controller
    signal cmp_fb      : std_logic_vector(9 downto 0);
    signal cmp_win     : std_logic;

begin

    ---------------------------------------------------------------------------
    -- u_kb : PS/2 keyboard decoder
    ---------------------------------------------------------------------------
    u_kb : ps2_keyboard
        port map (
            clk       => clk,
            rst       => rst,
            ps2_clk   => ps2_clk,
            ps2_data  => ps2_data,
            ascii_out => kb_ascii,
            key_valid => kb_valid
        );

    ---------------------------------------------------------------------------
    -- u_lcd : HD44780 LCD controller (4-bit mode)
    ---------------------------------------------------------------------------
    u_lcd : lcd_controller
        port map (
            clk        => clk,
            rst        => rst,
            lcd_char   => gc_lcd_char,
            lcd_rs_in  => gc_lcd_rs,
            lcd_send   => gc_lcd_send,
            lcd_busy   => lc_busy,
            lcd_rs     => lcd_rs,
            lcd_rw     => lcd_rw,
            lcd_e      => lcd_e,
            lcd_db     => lcd_db
        );

    ---------------------------------------------------------------------------
    -- u_cmp : purely combinational word comparator
    ---------------------------------------------------------------------------
    u_cmp : word_comparator
        port map (
            secret_in   => gc_secret,
            guess_in    => gc_guess,
            feedback    => cmp_fb,
            all_correct => cmp_win
        );

    ---------------------------------------------------------------------------
    -- u_game : main game FSM
    ---------------------------------------------------------------------------
    u_game : game_controller
        port map (
            clk          => clk,
            rst          => rst,
            ascii_in     => kb_ascii,
            key_valid    => kb_valid,
            lcd_char_out => gc_lcd_char,
            lcd_rs_out   => gc_lcd_rs,
            lcd_send_out => gc_lcd_send,
            lcd_busy     => lc_busy,
            secret_out   => gc_secret,
            guess_out    => gc_guess,
            fb_in        => cmp_fb,
            win_in       => cmp_win,
            led_p1_done  => led(0),
            led_win      => led(1),
            led_lose     => led(2)
        );

end architecture structural;
