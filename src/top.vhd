-- top.vhd
-- GQH Hardware Track - Tang Nano 20K (GW2AR-LV18QN88C8/I7)
--
-- Data path:
--   uart_rx_i -> uart_rx -> packet_rx -> ma_core -> packet_tx -> uart_tx -> uart_tx_o
--
-- Port names MUST match 19_tang_nano_20k.cst exactly.
-- Set Project -> Configuration -> Synthesize -> General -> Top Module/Entity
-- to:  top
--
-- The generics only exist so the testbench can run with a faster baud rate.
-- Gowin synthesizes with these defaults. Change TX_GAP_CYCLES here when
-- tuning the inter-byte gap against 22_robust_uart_test.py.

library ieee;
use ieee.std_logic_1164.all;

entity top is
    generic (
        CLKS_PER_BIT      : positive := 234;       -- 27 MHz / 115200 baud
        TX_GAP_CYCLES     : natural  := 2700;      -- 100 us after each byte
        RX_TIMEOUT_LOG2   : positive := 17         -- 2**17 clocks = 4.85 ms partial-packet flush
    );
    port (
        sys_clk   : in  std_logic;   -- pin 4,  27 MHz
        reset_btn : in  std_logic;   -- pin 87, unused (design self-resets on index 0)
        uart_rx_i : in  std_logic;   -- pin 70, BL616 -> FPGA
        uart_tx_o : out std_logic;   -- pin 69, FPGA -> BL616
        led0_n    : out std_logic;   -- pin 15, toggles on every request
        led1_n    : out std_logic    -- pin 16, toggles on every response
    );
end entity;

architecture rtl of top is

    signal rx_valid   : std_logic;
    signal rx_data    : std_logic_vector(7 downto 0);
    signal pkt_valid  : std_logic;
    signal pkt_data   : std_logic_vector(63 downto 0);
    signal resp_valid : std_logic;
    signal resp_data  : std_logic_vector(63 downto 0);
    signal tx_valid   : std_logic;
    signal tx_data    : std_logic_vector(7 downto 0);
    signal tx_ready   : std_logic;

    signal led_rx : std_logic := '0';
    signal led_tx : std_logic := '0';

begin

    u_uart_rx : entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk      => sys_clk,
            rx       => uart_rx_i,
            rx_valid => rx_valid,
            rx_data  => rx_data
        );

    u_packet_rx : entity work.packet_rx
        generic map (TIMEOUT_LOG2 => RX_TIMEOUT_LOG2)
        port map (
            clk       => sys_clk,
            rx_valid  => rx_valid,
            rx_data   => rx_data,
            pkt_valid => pkt_valid,
            pkt_data  => pkt_data
        );

    u_core : entity work.ma_core
        port map (
            clk        => sys_clk,
            pkt_valid  => pkt_valid,
            pkt_data   => pkt_data,
            resp_valid => resp_valid,
            resp_data  => resp_data
        );

    u_packet_tx : entity work.packet_tx
        port map (
            clk        => sys_clk,
            resp_valid => resp_valid,
            resp_data  => resp_data,
            tx_valid   => tx_valid,
            tx_data    => tx_data,
            tx_ready   => tx_ready
        );

    u_uart_tx : entity work.uart_tx
        generic map (
            CLKS_PER_BIT => CLKS_PER_BIT,
            GAP_CYCLES   => TX_GAP_CYCLES
        )
        port map (
            clk      => sys_clk,
            tx_valid => tx_valid,
            tx_data  => tx_data,
            tx_ready => tx_ready,
            tx       => uart_tx_o
        );

    -- Activity LEDs (active low). They flicker during a test run so you can
    -- see at a glance whether requests arrive and responses go out.
    process (sys_clk)
    begin
        if rising_edge(sys_clk) then
            if pkt_valid = '1' then
                led_rx <= not led_rx;
            end if;
            if resp_valid = '1' then
                led_tx <= not led_tx;
            end if;
        end if;
    end process;

    led0_n <= not led_rx;
    led1_n <= not led_tx;

end architecture;
