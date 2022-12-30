# waveform

Generates unicode waveforms that can be embedded into code comments

```

       0  1  2  3  4  5  6  7  8  9  0  1  2  3  4  5  6  7  8  9  0  1  2  3
       ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆
       ┆  ┆  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┏━━┓  ┆  ┆
CLK    ┆  ┆  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┆  ┆
     ╍╍━━━━━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━┛  ┗━━━━━━╍╍
       ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆
     ╍╍━━━┓  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┏━━━━━━━━━━━━╍╍
/CE    ┆  ┃  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┃  ┆  ┆  ┆  ┆
       ┆  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛  ┆  ┆  ┆  ┆
       ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆
       ┆  ┆  ┏━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┓  ┆  ┆  ┆  ┆  ┆
MOSI ╍╍━━━━━━┫  7  ┃  6  ┃  5  ┃  4  ┃  3  ┃  2  ┃  1  ┃  0  ┣━━━━━━━━━━━━━━━╍╍
       ┆  ┆  ┗━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┛  ┆  ┆  ┆  ┆  ┆
       ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆
       ┆  ┆  ┆  ┏━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┳━━━━━┓  ┆  ┆  ┆  ┆
MISO ╍╍━━━━━━━━━┫  7  ┃  6  ┃  5  ┃  4  ┃  3  ┃  2  ┃  1  ┃  0  ┣━━━━━━━━━━━━╍╍
       ┆  ┆  ┆  ┗━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┻━━━━━┛  ┆  ┆  ┆  ┆
       ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆  ┆
```

The input for this diagram is a text file:

```
CLK  | LLHLHLHLHLHLHLHLHLHLLLL
/CE  | HLLLLLLLLLLLLLLLLLHHHHH
MOSI | ZZB-B-B-B-B-B-B-B-ZZZZZ
MISO | ZZZB-B-B-B-B-B-B-B-ZZZZ
```

Each part after the `|` describes the state on a clock edge.

The allowed states are:

- `L`: edge to low
- `H`: edge to high
- `Z`: edge to high impedance
- `B`: edge to low or high (can be both)
- `-`: no change in the signal
