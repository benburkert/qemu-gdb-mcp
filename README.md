# qemu-gdb-mcp

MCP server that drives a GDB subprocess attached to QEMU. Built for RISC-V kernel debugging; architecture-agnostic.

## Build

```sh
zig build
```

## Use

Configure your MCP client to launch `zig-out/bin/qemu-gdb-mcp`. Start QEMU with `-s -S`, then call `target_connect` with the GDB binary (e.g. `riscv64-elf-gdb`) and kernel image.

## Tools

`target_connect`, `target_disconnect`, `continue`, `stop`, `step`, `next`, `stepi_no_irq`, `backtrace`, `disassemble`, `read_registers`, `write_register`, `read_csr`, `read_memory`, `write_memory`, `read_page_table`, `set_physical_memory_mode`, `set_breakpoint`, `remove_breakpoint`, `list_breakpoints`, `watchpoint`, `list_threads`, `select_thread`, `lookup_symbol`, `eval_expression`, `info`, `monitor`.
