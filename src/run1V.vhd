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
end entity top;

architecture rtl of top is

    constant BIT_CLKS : positive := -- how many FPGA cycles in one UART bit
        (CLK_HZ + BAUD / 2) / BAUD;

    -- Extra idle time between response bytes. -> into clock cycles
    constant GAP_CLKS : positive :=
        (CLK_HZ / 1000 * TX_GAP_US) / 1000;

    subtype byte_t is std_logic_vector(7 downto 0);

    type packet_t is array (0 to 7) of byte_t;
    type window_t is array (0 to 15) of unsigned(15 downto 0);
    type windows_t is array (0 to 1) of window_t;
    type sums_t is array (0 to 1) of unsigned(19 downto 0);
    type prices_t is array (0 to 1) of unsigned(15 downto 0);
    type actions_t is array (0 to 1) of byte_t;
    type heads_t is array (0 to 1) of integer range 0 to 15;

    -- Active-high reset with synchronized release.
    signal reset_pipe : std_logic_vector(1 downto 0) := "11";
    signal rst : std_logic;

    -- UART input synchronizer.
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
        COLLECT,
        SESSION_RESET,
        PROCESS_SLOT1,
        PROCESS_SLOT2,
        TX_START,
        TX_BITS,
        TX_STOP,
        TX_GAP
    );

    signal state : state_t := COLLECT;

    signal request : packet_t :=
        (others => (others => '0'));

    signal response : packet_t :=
        (others => (others => '0'));

    signal byte_count : integer range 0 to 7 := 0;

    -- Item 0 = A (0x11), item 1 = B (0x22).
    signal windows : windows_t :=
        (others => (others => (others => '0')));

    signal sums : sums_t :=
        (others => (others => '0'));

    signal previous : prices_t :=
        (others => (others => '0'));

    signal held_action : actions_t :=
        (others => x"00");

    signal heads : heads_t := (others => 0);

    signal tx_byte_index : integer range 0 to 7 := 0;
    signal tx_bit : integer range 0 to 7 := 0;
    signal tx_timer : integer range 0 to BIT_CLKS - 1 := 0;
    signal gap_timer : integer range 0 to GAP_CLKS - 1 := 0;
    signal tx_line : std_logic := '1';

    signal packet_toggle : std_logic := '0';

begin

    uart_tx_o <= tx_line;

    -- LED0 toggles after each complete response.
    led0_n <= not packet_toggle;

    -- LED1 is on while processing or transmitting.
    led1_n <= '1' when state = COLLECT else '0';

    process(sys_clk, reset_btn)
    begin
        if reset_btn = '1' then
            reset_pipe <= "11";
        elsif rising_edge(sys_clk) then
            reset_pipe <= reset_pipe(0) & '0';
        end if;
    end process;

    rst <= reset_pipe(1);

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

    -- UART receiver: 115200 baud, 8 data bits,
    -- no parity, one stop bit, least-significant bit first.
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
                            -- False start bit.
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

    -- Packet processing and UART transmission.
    process(sys_clk)
        variable item : byte_t;
        variable price : unsigned(15 downto 0);
        variable item_number : integer range 0 to 1;
        variable action : byte_t;

        variable updated_sum : unsigned(19 downto 0);
        variable old_average : unsigned(15 downto 0);
        variable new_average : unsigned(15 downto 0);

        variable packet_index : unsigned(15 downto 0);
        variable action_position : integer range 3 to 5;

    begin
        if rising_edge(sys_clk) then

            if rst = '1' then
                state <= COLLECT;

                request <= (others => (others => '0'));
                response <= (others => (others => '0'));
                byte_count <= 0;

                windows <=
                    (others => (others => (others => '0')));

                sums <= (others => (others => '0'));
                previous <= (others => (others => '0'));
                held_action <= (others => x"00");
                heads <= (others => 0);

                tx_byte_index <= 0;
                tx_bit <= 0;
                tx_timer <= 0;
                gap_timer <= 0;
                tx_line <= '1';
                packet_toggle <= '0';

            else
                case state is

                    when COLLECT =>
                        tx_line <= '1';

                        if rx_valid = '1' then
                            request(byte_count) <= rx_byte;

                            if byte_count = 7 then
                                byte_count <= 0;
                                state <= SESSION_RESET;
                            else
                                byte_count <= byte_count + 1;
                            end if;
                        end if;

                    when SESSION_RESET =>
                        -- Request:
                        -- index_hi, index_lo,
                        -- item1, price1_hi, price1_lo,
                        -- item2, price2_hi, price2_lo.
                        --
                        -- Response:
                        -- index_hi, index_lo,
                        -- item1, action1,
                        -- item2, action2,
                        -- 0x00, 0x00.

                        response(0) <= request(0);
                        response(1) <= request(1);
                        response(2) <= request(2);
                        response(3) <= x"00";
                        response(4) <= request(5);
                        response(5) <= x"00";
                        response(6) <= x"00";
                        response(7) <= x"00";

                        -- Index 0 starts a fresh session.
                        -- Clear state BEFORE processing its prices.
                        if request(0) = x"00" and
                           request(1) = x"00" then

                            windows <=
                                (others =>
                                    (others => (others => '0')));

                            sums <=
                                (others => (others => '0'));

                            previous <=
                                (others => (others => '0'));

                            held_action <= (others => x"00");
                            heads <= (others => 0);
                        end if;

                        state <= PROCESS_SLOT1;

                    when PROCESS_SLOT1 | PROCESS_SLOT2 =>

                        packet_index :=
                            unsigned(request(0)) &
                            unsigned(request(1));

                        if state = PROCESS_SLOT1 then
                            item := request(2);

                            price :=
                                unsigned(request(3)) &
                                unsigned(request(4));

                            action_position := 3;

                        else
                            item := request(5);

                            price :=
                                unsigned(request(6)) &
                                unsigned(request(7));

                            action_position := 5;
                        end if;

                        action := x"00";

                        -- Route by item ID, not packet slot.
                        if item = x"11" or item = x"22" then

                            if item = x"11" then
                                item_number := 0;
                            else
                                item_number := 1;
                            end if;

                            if packet_index < to_unsigned(16, 16) then
                                if packet_index = to_unsigned(0, 16) then
                                    -- Start this item's sum from its first price.
                                    updated_sum := resize(price, 20);
                                else
                                    updated_sum :=
                                        sums(item_number) + resize(price, 20);
                                end if;

                            else
                                -- Floor division by 16.
                                old_average :=
                                    sums(item_number)(19 downto 4);

                                -- Remove oldest price, add current price.
                                updated_sum :=
                                    sums(item_number) -
                                    resize(
                                        windows(item_number)(
                                            heads(item_number)
                                        ),
                                        20
                                    ) +
                                    resize(price, 20);

                                new_average :=
                                    updated_sum(19 downto 4);

                                -- Default: repeat the last action.
                                action := held_action(item_number);

                                if previous(item_number) <= old_average
                                   and price > new_average then

                                    action := x"02"; -- BUY

                                elsif previous(item_number) >= old_average
                                      and price < new_average then

                                    action := x"01"; -- SELL
                                end if;
                            end if;

                            sums(item_number) <= updated_sum;
                            previous(item_number) <= price;
                            held_action(item_number) <= action;

                            if packet_index = to_unsigned(0, 16) then
                                windows(item_number)(0) <= price;
                                heads(item_number) <= 1;
                            else
                                windows(item_number)(heads(item_number)) <= price;

                                if heads(item_number) = 15 then
                                    heads(item_number) <= 0;
                                else
                                    heads(item_number) <= heads(item_number) + 1;
                                end if;
                            end if;
                        end if;

                        response(action_position) <= action;

                        if state = PROCESS_SLOT1 then
                            state <= PROCESS_SLOT2;

                        else
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

end architecture rtl;