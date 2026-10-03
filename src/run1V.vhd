-- GQH Hardware Track
-- Team: Clock Cycle Gang
-- Authors: Vincent Schifano, Avi Patel, Daniel Cao, Himmet Dhaliwal
-- Board: Tang Nano 20K
-- Top entity: top
-- Clock: 27 MHz
-- UART: 115200 baud, 8N1
-- Implements two independent 16-price moving-average engines.
-- Index 0 automatically starts a new session.
-- Price histories use synchronous block RAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    generic (
        CLK_HZ    : positive := 27_000_000;
        BAUD      : positive := 115_200;
        TX_GAP_US : positive := 1000
    );
    port (
        sys_clk   : in  std_logic;
        reset_btn : in  std_logic;
        uart_rx_i : in  std_logic;
        uart_tx_o : out std_logic;
        led0_n    : out std_logic;
        led1_n    : out std_logic
    );
end entity;

architecture rtl of top is

    constant BIT_CLKS : positive :=
        (CLK_HZ + BAUD / 2) / BAUD;

    constant GAP_CLKS : positive :=
        (CLK_HZ / 1000 * TX_GAP_US) / 1000;

    subtype byte_t is std_logic_vector(7 downto 0);
    subtype action_t is unsigned(1 downto 0);

    type packet_t is array (0 to 7) of byte_t;
    type sums_t is array (0 to 1) of unsigned(19 downto 0);
    type prices_t is array (0 to 1) of unsigned(15 downto 0);
    type actions_t is array (0 to 1) of action_t;
    type heads_t is array (0 to 1) of unsigned(3 downto 0);

    -- One RAM holds both 16-price windows.
    -- Item A: addresses 0 through 15.
    -- Item B: addresses 16 through 31.
    type ram_t is array (0 to 31) of
        std_logic_vector(15 downto 0);

    signal price_ram : ram_t;

    attribute syn_ramstyle : string;
    attribute syn_ramstyle of price_ram : signal is "block_ram";

    signal ram_addr : unsigned(4 downto 0);
    signal ram_din : std_logic_vector(15 downto 0);
    signal ram_q : std_logic_vector(15 downto 0);
    signal ram_we : std_logic;
    signal ram_re : std_logic;

    signal reset_pipe : std_logic_vector(1 downto 0) := "11";
    signal rst : std_logic;

    signal rx_meta : std_logic := '1';
    signal rx_sync : std_logic := '1';

    type rx_state_t is (
        RX_IDLE,
        RX_START,
        RX_BITS,
        RX_STOP
    );

    signal rx_state : rx_state_t := RX_IDLE;
    signal rx_timer : integer range 0 to BIT_CLKS - 1 := 0;
    signal rx_bit : integer range 0 to 7 := 0;
    signal rx_shift : byte_t := (others => '0');
    signal rx_byte : byte_t := (others => '0');
    signal rx_valid : std_logic := '0';

    type state_t is (
        CLEAR_RAM,
        COLLECT,
        PREPARE,
        LOAD_SLOT1,
        LOAD_SLOT2,
        READ_OLDEST,
        CALCULATE,
        COMMIT,
        TX_START,
        TX_BITS,
        TX_STOP,
        TX_GAP
    );

    signal state : state_t := CLEAR_RAM;

    signal clear_addr : unsigned(4 downto 0) :=
        (others => '0');

    signal resume_packet : std_logic := '0';

    signal request : packet_t :=
        (others => (others => '0'));

    signal response : packet_t :=
        (others => (others => '0'));

    signal byte_count : integer range 0 to 7 := 0;

    signal sums : sums_t :=
        (others => (others => '0'));

    signal previous : prices_t :=
        (others => (others => '0'));

    signal held_action : actions_t :=
        (others => (others => '0'));

    signal heads : heads_t :=
        (others => (others => '0'));

    signal slot2 : std_logic := '0';
    signal active_item : integer range 0 to 1 := 0;
    signal active_valid : std_logic := '0';

    signal current_price : unsigned(15 downto 0) :=
        (others => '0');

    signal pending_sum : unsigned(19 downto 0) :=
        (others => '0');

    signal pending_action : action_t :=
        (others => '0');

    signal warmup : std_logic;
    signal first_sample : std_logic;

    signal tx_byte_index : integer range 0 to 7 := 0;
    signal tx_bit : integer range 0 to 7 := 0;
    signal tx_timer : integer range 0 to BIT_CLKS - 1 := 0;
    signal gap_timer : integer range 0 to GAP_CLKS - 1 := 0;
    signal tx_line : std_logic := '1';

    signal packet_toggle : std_logic := '0';

begin

    uart_tx_o <= tx_line;

    led0_n <= not packet_toggle;

    led1_n <= '1' when state = COLLECT else '0';

    first_sample <= '1'
        when request(0) = x"00" and request(1) = x"00"
        else '0';

    warmup <= '1'
        when request(0) = x"00" and unsigned(request(1)) < 16
        else '0';

    -- Select a RAM address.
    -- The first sample always uses position zero for its item.
    ram_addr <=
        clear_addr when state = CLEAR_RAM else
        to_unsigned(active_item, 1) & "0000"
            when first_sample = '1' else
        to_unsigned(active_item, 1) & heads(active_item);

    ram_din <=
        (others => '0') when state = CLEAR_RAM else
        std_logic_vector(current_price);

    ram_we <= '1'
        when rst = '0' and
            (state = CLEAR_RAM or
             (state = COMMIT and active_valid = '1'))
        else '0';

    ram_re <= '1' when state = READ_OLDEST else '0';

    -- Synchronous RAM.
    -- Clear entries through this write port instead of
    -- resetting the whole array in a single assignment.
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if ram_we = '1' then
                price_ram(to_integer(ram_addr)) <= ram_din;
            end if;

            if ram_re = '1' then
                ram_q <= price_ram(to_integer(ram_addr));
            end if;
        end if;
    end process;

    -- Reset assertion and synchronized release.
    process(sys_clk, reset_btn)
    begin
        if reset_btn = '1' then
            reset_pipe <= "11";
        elsif rising_edge(sys_clk) then
            reset_pipe <= reset_pipe(0) & '0';
        end if;
    end process;

    rst <= reset_pipe(1);

    -- Synchronize the asynchronous UART input.
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if rst = '1' then
                rx_meta <= '1';
                rx_sync <= '1';
            else
                rx_meta <= uart_rx_i;
                rx_sync <= rx_meta;
            end if;
        end if;
    end process;

    -- UART receiver: 115200 baud, 8N1, LSB first.
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            rx_valid <= '0';

            if rst = '1' then
                rx_state <= RX_IDLE;
                rx_timer <= 0;
                rx_bit <= 0;
                rx_shift <= (others => '0');
                rx_byte <= (others => '0');

            else
                case rx_state is

                    when RX_IDLE =>
                        if rx_sync = '0' then
                            rx_timer <= BIT_CLKS / 2 - 1;
                            rx_state <= RX_START;
                        end if;

                    when RX_START =>
                        if rx_timer /= 0 then
                            rx_timer <= rx_timer - 1;

                        elsif rx_sync = '0' then
                            rx_timer <= BIT_CLKS - 1;
                            rx_bit <= 0;
                            rx_state <= RX_BITS;

                        else
                            rx_state <= RX_IDLE;
                        end if;

                    when RX_BITS =>
                        if rx_timer /= 0 then
                            rx_timer <= rx_timer - 1;

                        else
                            rx_shift(rx_bit) <= rx_sync;
                            rx_timer <= BIT_CLKS - 1;

                            if rx_bit = 7 then
                                rx_state <= RX_STOP;
                            else
                                rx_bit <= rx_bit + 1;
                            end if;
                        end if;

                    when RX_STOP =>
                        if rx_timer /= 0 then
                            rx_timer <= rx_timer - 1;

                        else
                            if rx_sync = '1' then
                                rx_byte <= rx_shift;
                                rx_valid <= '1';
                            end if;

                            rx_state <= RX_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Packet processing, moving averages, and transmission.
    process(sys_clk)
        variable item : byte_t;
        variable new_sum : unsigned(19 downto 0);
        variable old_avg : unsigned(15 downto 0);
        variable new_avg : unsigned(15 downto 0);
        variable action : action_t;

    begin
        if rising_edge(sys_clk) then

            if rst = '1' then
                state <= CLEAR_RAM;
                clear_addr <= (others => '0');
                resume_packet <= '0';

                request <= (others => (others => '0'));
                response <= (others => (others => '0'));
                byte_count <= 0;

                sums <= (others => (others => '0'));
                previous <= (others => (others => '0'));
                held_action <= (others => (others => '0'));
                heads <= (others => (others => '0'));

                slot2 <= '0';
                active_item <= 0;
                active_valid <= '0';

                current_price <= (others => '0');
                pending_sum <= (others => '0');
                pending_action <= (others => '0');

                tx_byte_index <= 0;
                tx_bit <= 0;
                tx_timer <= 0;
                gap_timer <= 0;
                tx_line <= '1';
                packet_toggle <= '0';

            else
                case state is

                    when CLEAR_RAM =>
                        -- RAM writes zero to clear_addr on this clock.
                        if clear_addr = 31 then
                            if resume_packet = '1' then
                                state <= LOAD_SLOT1;
                            else
                                state <= COLLECT;
                            end if;
                        else
                            clear_addr <= clear_addr + 1;
                        end if;

                    when COLLECT =>
                        tx_line <= '1';

                        if rx_valid = '1' then
                            request(byte_count) <= rx_byte;

                            if byte_count = 7 then
                                byte_count <= 0;
                                state <= PREPARE;
                            else
                                byte_count <= byte_count + 1;
                            end if;
                        end if;

                    when PREPARE =>
                        -- Echo index and item IDs.
                        response(0) <= request(0);
                        response(1) <= request(1);
                        response(2) <= request(2);
                        response(3) <= x"00";
                        response(4) <= request(5);
                        response(5) <= x"00";
                        response(6) <= x"00";
                        response(7) <= x"00";

                        if first_sample = '1' then
                            -- Start a new session automatically.
                            sums <= (others => (others => '0'));
                            previous <= (others => (others => '0'));
                            held_action <= (others => (others => '0'));
                            heads <= (others => (others => '0'));

                            clear_addr <= (others => '0');
                            resume_packet <= '1';
                            state <= CLEAR_RAM;
                        else
                            state <= LOAD_SLOT1;
                        end if;

                    when LOAD_SLOT1 | LOAD_SLOT2 =>
                        if state = LOAD_SLOT1 then
                            slot2 <= '0';
                            item := request(2);

                            current_price <=
                                unsigned(request(3)) &
                                unsigned(request(4));
                        else
                            slot2 <= '1';
                            item := request(5);

                            current_price <=
                                unsigned(request(6)) &
                                unsigned(request(7));
                        end if;

                        active_valid <= '1';

                        if item = x"11" then
                            active_item <= 0;
                        elsif item = x"22" then
                            active_item <= 1;
                        else
                            active_valid <= '0';
                        end if;

                        state <= READ_OLDEST;

                    when READ_OLDEST =>
                        -- RAM registers the oldest price this clock.
                        -- It is available during CALCULATE.
                        state <= CALCULATE;

                    when CALCULATE =>
                        action := to_unsigned(0, 2);
                        new_sum := (others => '0');

                        if active_valid = '1' then

                            if warmup = '1' then
                                if first_sample = '1' then
                                    new_sum :=
                                        resize(current_price, 20);
                                else
                                    new_sum :=
                                        sums(active_item) +
                                        resize(current_price, 20);
                                end if;

                            else
                                old_avg :=
                                    sums(active_item)(19 downto 4);

                                new_sum :=
                                    sums(active_item) -
                                    resize(unsigned(ram_q), 20) +
                                    resize(current_price, 20);

                                new_avg := new_sum(19 downto 4);

                                -- No crossing repeats the previous action.
                                action := held_action(active_item);

                                if previous(active_item) <= old_avg
                                   and current_price > new_avg then

                                    action := to_unsigned(2, 2);

                                elsif previous(active_item) >= old_avg
                                      and current_price < new_avg then

                                    action := to_unsigned(1, 2);
                                end if;
                            end if;
                        end if;

                        pending_sum <= new_sum;
                        pending_action <= action;
                        state <= COMMIT;

                    when COMMIT =>
                        -- RAM writes the current price this clock.
                        if active_valid = '1' then
                            sums(active_item) <= pending_sum;
                            previous(active_item) <= current_price;
                            held_action(active_item) <= pending_action;

                            if first_sample = '1' then
                                heads(active_item) <= to_unsigned(1, 4);
                            else
                                -- Four-bit addition wraps 15 back to 0.
                                heads(active_item) <=
                                    heads(active_item) + 1;
                            end if;
                        end if;

                        if slot2 = '0' then
                            response(3) <=
                                "000000" &
                                std_logic_vector(pending_action);

                            state <= LOAD_SLOT2;

                        else
                            response(5) <=
                                "000000" &
                                std_logic_vector(pending_action);

                            tx_byte_index <= 0;
                            tx_line <= '0';
                            tx_timer <= BIT_CLKS - 1;
                            state <= TX_START;
                        end if;

                    when TX_START =>
                        if tx_timer /= 0 then
                            tx_timer <= tx_timer - 1;

                        else
                            tx_line <= response(tx_byte_index)(0);
                            tx_bit <= 0;
                            tx_timer <= BIT_CLKS - 1;
                            state <= TX_BITS;
                        end if;

                    when TX_BITS =>
                        if tx_timer /= 0 then
                            tx_timer <= tx_timer - 1;

                        else
                            tx_timer <= BIT_CLKS - 1;

                            if tx_bit = 7 then
                                tx_line <= '1';
                                state <= TX_STOP;

                            else
                                tx_bit <= tx_bit + 1;

                                tx_line <=
                                    response(tx_byte_index)(tx_bit + 1);
                            end if;
                        end if;

                    when TX_STOP =>
                        if tx_timer /= 0 then
                            tx_timer <= tx_timer - 1;

                        elsif tx_byte_index = 7 then
                            packet_toggle <= not packet_toggle;
                            state <= COLLECT;

                        else
                            gap_timer <= GAP_CLKS - 1;
                            state <= TX_GAP;
                        end if;

                    when TX_GAP =>
                        if gap_timer /= 0 then
                            gap_timer <= gap_timer - 1;

                        else
                            tx_byte_index <= tx_byte_index + 1;
                            tx_line <= '0';
                            tx_timer <= BIT_CLKS - 1;
                            state <= TX_START;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;
