# Team ClockCycleGang: GQH Hardware Track

## Team
- Vincent Schifano
- Daniel Cao
- Himmet Dhaliwal
- Avi Patel

## Description
A hardware moving-average crossing detector. The FPGA receives 8-byte UART
requests containing prices for Item A (0x11) and Item B (0x22), keeps an
independent 16-price window per item, and replies with 8 bytes containing a
BUY / SELL / NONE action for each item.

## What runs on the FPGA
Everything: UART RX/TX, packet parsing, item routing by ID, the two 16-sample
windows and 20-bit rolling sums, crossing detection, last-action hold, session
reset on index 0, and response generation. No host software runs during judging.

## Hardware and tools
| Item | Value |
|---|---|
| Board | Tang Nano 20K |
| FPGA part | GW2AR-LV18QN88C8/I7 |
| HDL | VHDL |
| Gowin EDA version | V1.9.11.03 Education |
| Top-level module | `top` () |

## Repository layout
```
README.md
src/          HDL source
constraints/  19_tang_nano_20k.cst (organizer-supplied)
testbench/    simulation testbenches
gowin/        Gowin project files
bitstream/    final .fs (built from this exact source)
results/      test CSVs, soak-test logs
```

## Build and program
1. Open `gowin/<project>.gprj` in Gowin EDA.
2. Confirm Top Module/Entity is `top` (Project > Configuration > Synthesize > General).
3. Run Synthesize, then Place & Route (both must finish without errors).
4. Tools > Programmer > Scan Device > select GW2AR-18C.
5. Access Mode: SRAM Mode. Operation: SRAM Program. File: `bitstream/<project>.fs`.
6. Click Program/Configure.

Fallback: `openFPGALoader -b tangnano20k bitstream/<project>.fs`

## Inputs, outputs, and how to reproduce
- Request (8 bytes, big-endian): index(2) item1(1) price1(2) item2(1) price2(2)
- Response (8 bytes): index(2) item1(1) action1(1) item2(1) action2(1) 0x0000
- Example: request `00 10 11 00 50 22 00 C8` -> index 16, A=80, B=200.
- To reproduce: program the board, set `PORT` in `21_quick_uart_test.py` and
  `22_robust_uart_test.py` to your COM port, then run quick test, then robust test.

## Testing and verification
- **Simulation:** No HDL simulation was performed. On-board validation
  used the organizer-provided Python tests and their moving-average
  software reference models as the golden model.

- **On-board:** Quick UART test: PASS. Robust UART test: 84/84 scored
  packets correct, 168/168 actions correct, and zero timeouts.

- **Soak test:** 10 robust runs, all achieving 100% correctness.
  Across 1,000 received packets: zero timeouts, 840/840 scored packets
  correct, and 1,680/1,680 scored actions correct.
  Overall average round-trip latency: 16.743 ms.

- CSVs and per-run summaries are in `results/`.

## Results
| Metric | Ours | Reference |
|---|---|---|
| Total LUTs (Gowin Resource Usage Summary) | 298 | 542 |
| Average latency (robust test) | 16.638 ms | 16.626 ms |
| Packet correctness | 84/84 | |
| Action correctness | 168/168 | |

## Design notes
TX inter-byte gap: The transmitter adds 1 ms of idle time between response bytes to address the guide’s warning about dropped or corrupted bytes in the BL616 USB bridge. This setting was retained after the UART tests passed without timeouts. The optimized design’s measured average round-trip latency was 16.630 ms.

Warm-up and reset strategy: Indices 0–15 fill each item’s independent 16-price window and return NONE. Index 0 clears both items’ sums, previous prices, held actions, buffer pointers, and all 32 price-memory entries. Each first sample explicitly initializes its item’s sum. From index 16 onward, circular buffers replace the oldest price, and rolling sums calculate floor-divided averages for crossing detection. Routing follows item IDs, so packet slots may swap.

LUT optimizations and measured savings: Replaced the resettable price-window arrays with a shared 32 × 16-bit synchronous block RAM, cleared one entry per clock through its write port. Internal actions use two bits, and buffer pointers use four-bit wrapping counters. Total LUT usage fell from 604 to 305, saving 299 LUTs (49.5%). The optimized design passed the robust test with 84/84 correct packets, 168/168 correct actions, and zero timeouts.

## External resources used
Used the organizer-supplied .cst and test scripts. AI assistance: Claude was used for project planning, ChatGPT was used for creation of VHDL file, All final HDL was reviewed, simulated, and tested on hardware by the team.

## Known limitations
None known
