# spacedisplay-zig

Fast and lightweight terminal app to scan and analyze used disk space written in Zig. 

Previous implementation in Rust can be found [here](https://github.com/funbiscuit/spacedisplay-rs).

> Zig app is WIP so it lacks some features of Rust app.

## Features

* Fast scanning and low memory footprint (~6MiB per 100k directories, number of files doesn't matter)
* Terminal UI that allows to use it through SSH
* Full mouse support (if terminal supports it)
* Small (~0.5MB on Linux with debug-info stripped), static binary without extra dependencies

## Installation

### From source

To build `spacedisplay` from source you'll need zig 0.15.2 installed.

```shell
zig build -Doptimize=ReleaseSafe
```

Built binary will be in `zig-out/bin/spacedisplay`. Copy it somewhere in your `PATH`.

If you need smaller binary you can strip debug info, but then you'll not get any stacktraces if you encounter any bugs.

## Basic usage

Run the binary in your terminal and give it a path to scan. For example:

```shell
spacedisplay ~
```

Keyboard controls:

|         Key          | Action                                                     |
|:--------------------:|------------------------------------------------------------|
|        Ctrl+C        | Quit                                                       |
|       Home/End       | Jump to first/last file/dir                                |
|       Up/Down        | Move up and down inside files list                         |
|     Enter, Right     | Open selected directory                                    |
| Esc, Backspace, Left | Go to the parent directory                                 |

If your terminal supports it, you can also move around with your mouse.

# Performance

`spacedisplay` is efficient in both speed and memory footprint. So scan speed is mainly
limited by disk access to gather metadata.
Here are some test results with time in seconds that takes to fully scan root partition.

|   Platform   | Files+Dirs | spacedisplay | File Manager |
|:------------:|:----------:|:------------:|:------------:|
| Ubuntu 24.04 |    850K    |     1.3s     |     9.3s     |

In test above default file manager is Files in Ubuntu.

`spacedisplay` is also lightweight in terms of memory usage. Most memory is used only to store scanned directory tree
(without files) and directory names. To scan ~100k dirs it takes ~6MiB of RAM (measured in Ubuntu 24.04). Exact amount
of memory depends on how long directory names are but given such low consumption it shouldn't be a problem ever.

# Performance tests

Performance of `spacedisplay` can be measured (relatively to other tools) via `performance.sh`. For performance
measurement [hyperfine](https://github.com/sharkdp/hyperfine) is used.
It will also measure performance of [spacedisplay-rs](https://github.com/funbiscuit/spacedisplay-rs) if it is
found in `zig-out` dir under name `spacedisplay-rs`.

This script doesn't measure actual hard drive speed since warmup is used and filesystem information is cached
at OS level. On first run scan time will be much higher due to slow calls to hard drive.

Results on some platforms:

## Ubuntu 24.04 (750k files)

| Command            |      Mean [s] | Min [s] | Max [s] |    Relative |
|:-------------------|--------------:|--------:|--------:|------------:|
| `spacedisplay-zig` | 1.331 ± 0.021 |   1.312 |   1.381 |        1.00 |
| `spacedisplay-rs`  | 2.129 ± 0.024 |   2.096 |   2.168 | 1.60 ± 0.03 |
| `du -sh`           | 1.356 ± 0.016 |   1.326 |   1.379 | 1.02 ± 0.02 |
