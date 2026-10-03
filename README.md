# Team VincentVanGPT: GQH Hardware Track

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
| Gowin EDA version | <e.g. V1.9.11.03 Education> |
| Top-level module | `top` (<update if different>) |

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
- <Simulation: tool used, what the testbench checks, golden-model source>
- <On-board: quick test result, robust test result>
- <Soak test: N consecutive robust runs, number of timeouts>
- CSVs are in `results/`.

## Results
| Metric | Ours | Reference |
|---|---|---|
| Total LUTs (Gowin Resource Usage Summary) | <fill in> | 542 |
| Average latency (robust test) | <fill in> ms | 16.626 ms |
| Packet correctness | <x>/84 | |
| Action correctness | <x>/168 | |

## Design notes
- <TX inter-byte gap and how it was chosen>
- <Warm-up handling, window/reset strategy>
- <Any LUT optimizations and measured savings>

## External resources used
<List any libraries, IP cores, starter code, or datasets. If none, write "None
beyond the organizer-supplied .cst and test scripts.">

## Known limitations
<Be honest. If none known, say so.>
