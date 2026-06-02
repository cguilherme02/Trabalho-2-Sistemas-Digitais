--------------------------------------------------------------------------------
-- FILE        : ps2_keyboard.vhd
-- PROJECT     : TERMO (Wordle) – EEL480 Digital Systems
-- BOARD       : Digilent Spartan-3AN Starter Kit (XC3S700AN-FGG484)
-- DESCRIPTION : PS/2 keyboard interface.
--               Decodes the 11-bit PS/2 serial frame (start, 8 data, parity,
--               stop), filters out break codes (F0 prefix), and converts
--               Set-2 scan codes to 8-bit ASCII.
-- CLK         : 50 MHz system clock
-- AUTHOR      : EEL480 Group
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_keyboard is
    port (
        clk       : in  std_logic;                    -- 50 MHz system clock
        rst       : in  std_logic;                    -- Active-high synchronous reset
        ps2_clk   : in  std_logic;                    -- PS/2 clock line (open-collector)
        ps2_data  : in  std_logic;                    -- PS/2 data line (open-collector)
        ascii_out : out std_logic_vector(7 downto 0); -- ASCII code of last key pressed
        key_valid : out std_logic                     -- Pulses '1' for one clock on valid key
    );
end entity ps2_keyboard;

architecture rtl of ps2_keyboard is

    ---------------------------------------------------------------------------
    -- PS/2 clock synchronisation (3-stage shift register avoids metastability)
    ---------------------------------------------------------------------------
    signal ps2_clk_sync : std_logic_vector(2 downto 0) := (others => '1');

    -- Falling-edge flag: was high two cycles ago, low last cycle
    signal ps2_fall     : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Frame receive state
    ---------------------------------------------------------------------------
    signal bit_cnt   : integer range 0 to 11 := 0;
    -- Receives bits shifted RIGHT: newest bit enters at position 10
    signal shift_reg : std_logic_vector(10 downto 0) := (others => '0');
    signal rx_done   : std_logic := '0';
    signal scan_byte : std_logic_vector(7 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Break-code (key-release) tracking
    ---------------------------------------------------------------------------
    signal got_f0    : std_logic := '0'; -- '1' after receiving 0xF0

    ---------------------------------------------------------------------------
    -- Output registers
    ---------------------------------------------------------------------------
    signal ascii_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_r   : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Scan-code to ASCII look-up function (US QWERTY, Set 2)
    ---------------------------------------------------------------------------
    function scan_to_ascii(sc : std_logic_vector(7 downto 0))
        return std_logic_vector is
    begin
        case sc is
            -- Digits
            when x"45" => return x"30"; -- 0
            when x"16" => return x"31"; -- 1
            when x"1E" => return x"32"; -- 2
            when x"26" => return x"33"; -- 3
            when x"25" => return x"34"; -- 4
            when x"2E" => return x"35"; -- 5
            when x"36" => return x"36"; -- 6
            when x"3D" => return x"37"; -- 7
            when x"3E" => return x"38"; -- 8
            when x"46" => return x"39"; -- 9
            -- Letters A-Z (uppercase only; Shift not implemented)
            when x"1C" => return x"41"; -- A
            when x"32" => return x"42"; -- B
            when x"21" => return x"43"; -- C
            when x"23" => return x"44"; -- D
            when x"24" => return x"45"; -- E
            when x"2B" => return x"46"; -- F
            when x"34" => return x"47"; -- G
            when x"33" => return x"48"; -- H
            when x"43" => return x"49"; -- I
            when x"3B" => return x"4A"; -- J
            when x"42" => return x"4B"; -- K
            when x"4B" => return x"4C"; -- L
            when x"3A" => return x"4D"; -- M
            when x"31" => return x"4E"; -- N
            when x"44" => return x"4F"; -- O
            when x"4D" => return x"50"; -- P
            when x"15" => return x"51"; -- Q
            when x"2D" => return x"52"; -- R
            when x"1B" => return x"53"; -- S
            when x"2C" => return x"54"; -- T
            when x"3C" => return x"55"; -- U
            when x"2A" => return x"56"; -- V
            when x"1D" => return x"57"; -- W
            when x"22" => return x"58"; -- X
            when x"35" => return x"59"; -- Y
            when x"1A" => return x"5A"; -- Z
            -- Control keys
            when x"5A" => return x"0D"; -- Enter (Carriage Return)
            when x"66" => return x"08"; -- Backspace
            when x"29" => return x"20"; -- Space
            -- Unknown / not mapped
            when others => return x"00";
        end case;
    end function scan_to_ascii;

begin

    ---------------------------------------------------------------------------
    -- 3-stage PS/2 clock synchroniser + falling-edge detector
    -- Falling edge = ps2_clk_sync(2)='1' AND ps2_clk_sync(1)='0'
    ---------------------------------------------------------------------------
    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ps2_clk_sync <= (others => '1');
            else
                ps2_clk_sync <= ps2_clk_sync(1 downto 0) & ps2_clk;
            end if;
        end if;
    end process p_sync;

    ps2_fall <= ps2_clk_sync(2) and (not ps2_clk_sync(1));

    ---------------------------------------------------------------------------
    -- PS/2 frame reception
    --
    -- Frame layout (LSB first on the wire):
    --   [0]  Start bit  (always '0')
    --   [1]  D0 (LSB)
    --   ...
    --   [8]  D7 (MSB)
    --   [9]  Odd parity
    --   [10] Stop bit   (always '1')
    --
    -- We shift RIGHT: ps2_data enters at position [10] each cycle.
    -- After 8 data shifts (bit_cnt 1..8):
    --   shift_reg(10) = D7, shift_reg(9) = D6, ..., shift_reg(3) = D0
    -- Parity (bit_cnt=9) is NOT shifted in; stop (bit_cnt=10) triggers capture.
    -- Captured byte = shift_reg(10 downto 3) = D7..D0  (correct MSB-first byte)
    ---------------------------------------------------------------------------
    p_receive : process(clk)
    begin
        if rising_edge(clk) then
            rx_done  <= '0';
            valid_r  <= '0';

            if rst = '1' then
                bit_cnt   <= 0;
                shift_reg <= (others => '0');
                got_f0    <= '0';
                ascii_r   <= (others => '0');
                scan_byte <= (others => '0');
            else
                if ps2_fall = '1' then
                    if bit_cnt = 0 then
                        -- Start bit received: reset shift register
                        shift_reg <= (others => '0');
                        bit_cnt   <= 1;
                    elsif bit_cnt >= 1 and bit_cnt <= 8 then
                        -- Data bits D0..D7 (D0 first off the wire)
                        shift_reg <= ps2_data & shift_reg(10 downto 1);
                        bit_cnt   <= bit_cnt + 1;
                    elsif bit_cnt = 9 then
                        -- Parity bit: counted but not stored in shift_reg
                        bit_cnt <= 10;
                    else
                        -- Stop bit: frame complete, capture byte
                        bit_cnt   <= 0;
                        scan_byte <= shift_reg(10 downto 3); -- D7 downto D0
                        rx_done   <= '1';
                    end if;
                end if;

                -- Process the decoded scan byte (registered, runs one cycle later)
                if rx_done = '1' then
                    if scan_byte = x"F0" then
                        -- Break-code prefix: next byte is a key-release, ignore it
                        got_f0 <= '1';
                    elsif got_f0 = '1' then
                        -- This is the released key scan code; discard it
                        got_f0 <= '0';
                    else
                        -- Key make code: convert to ASCII
                        ascii_r <= scan_to_ascii(scan_byte);
                        if scan_to_ascii(scan_byte) /= x"00" then
                            valid_r <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_receive;

    -- Drive outputs from registered signals
    ascii_out <= ascii_r;
    key_valid <= valid_r;

end architecture rtl;
