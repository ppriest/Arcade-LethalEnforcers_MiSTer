# jtframe (the tool) provenance

The Go program jotego uses to generate register-decode modules, from
<https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`, path
`modules/jtframe/src/jtframe/`. **Verbatim.** GPL-3.0-or-later. `.gitattributes` marks `src/`
`-text`.

Only the tool is vendored; the HDL this core uses is in `rtl/`, one file at a time.

```
tools/jtframe/build.sh                                    # -> tools/jtframe/jtframe.exe (gitignored)
JTCORES=<jtcores at f64dbe2fd> scripts/regen_mmr.sh --check
```

`build.sh` is KonamiGX's (`89124d4`), unchanged: Go from MSYS2, `GOROOT` defaulting to
`/e/msys64/mingw64/lib/go`, dependencies fetched per `src/go.sum` on the first build.

A jtcores checkout at the same commit is still needed: the tool reads its template from
`$JTFRAME/hdl/inc/mmr.v` and the register maps from each `cfg/mmr.yaml`. A sparse clone of
`modules/jtframe` and `cores/simson` is enough.

The generated `*_mmr.v` files are committed although the generator's template says not to: Quartus
and the benches read `files.qip` and file lists, not jtframe's build system. `regen_mmr.sh --check`
detects drift. Checked: this build regenerates jotego's committed
`cores/simson/hdl/jt053246_mmr.v` byte for byte.
