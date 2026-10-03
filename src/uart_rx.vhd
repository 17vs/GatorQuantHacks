-- uart_rx.vhd
-- 8N1 UART receiver, LSB first.
--
-- How it works:
--   1. The raw pin is passed through two flip-flops (synchronizer) because it
--      is asynchronous to sys_clk. Without this, a transition landing exactly
--      on a clock edge can make a flip-flop go metastable.
--   2. In IDLE we wait for the line to drop low (start bit).
--   3. We wait HALF a bit and re-check the line. Still low = real start bit,
--      and we are now sitting in the MIDDLE of the start bit.
--   4. From there every full bit-time (CLKS_PER_BIT clocks) lands us in the
--      middle of the next bit. We sample 8 data bits, then the stop bit.
--   5. If the stop bit is high the byte is good: pulse rx_valid for 1 clock.
--
-- 27 MHz / 115200 = 234.375. We use 234: 0.16% error, which drifts only
-- ~1.6% of a bit over a whole byte. The start bit re-aligns every byte.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLKS_PER_BIT : positive := 234
    );
    port (
        clk      : in  std_logic;
        rx       : in  std_logic;                     -- raw asynchronous pin
        rx_valid : out std_logic;                     -- 1-clock pulse per byte
        rx_data  : out std_logic_vector(7 downto 0)   -- valid when rx_valid='1'
    );
end entity;

architecture rtl of uart_rx is

    constant HALF_BIT : natural := CLKS_PER_BIT / 2;

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state : state_t := S_IDLE;

    -- Synchronizer. Initialised high because an idle UART line is high.
    signal rx_meta : std_logic := '1';
    signal rx_sync : std_logic := '1';

    signal clk_cnt : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx : natural range 0 to 7 := 0;
    signal shreg   : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_r : std_logic := '0';

begin

    rx_valid <= valid_r;
    rx_data  <= shreg;

    process (clk)
    begin
        if rising_edge(clk) then
            rx_meta <= rx;
            rx_sync <= rx_meta;

            valid_r <= '0';   -- default: no new byte this clock

            case state is

                when S_IDLE =>
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if rx_sync = '0' then
                        state <= S_START;
                    end if;

                when S_START =>
                    -- Wait half a bit to reach the middle of the start bit.
                    if clk_cnt = HALF_BIT - 1 then
                        clk_cnt <= 0;
                        if rx_sync = '0' then
                            state <= S_DATA;    -- real start bit
                        else
                            state <= S_IDLE;    -- glitch, ignore it
                        end if;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when S_DATA =>
                    if clk_cnt = CLKS_PER_BIT - 1 then
                        clk_cnt <= 0;
                        -- LSB arrives first, so shift in from the top.
                        -- After 8 shifts, bit 0 has reached shreg(0).
                        shreg <= rx_sync & shreg(7 downto 1);
                        if bit_idx = 7 then
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                        end if;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when S_STOP =>
                    if clk_cnt = CLKS_PER_BIT - 1 then
                        clk_cnt <= 0;
                        if rx_sync = '1' then
                            valid_r <= '1';     -- good stop bit: deliver byte
                        end if;                 -- bad stop bit: drop byte
                        state <= S_IDLE;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

            end case;
        end if;
    end process;

end architecture;
