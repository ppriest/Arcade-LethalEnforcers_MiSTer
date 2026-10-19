# jt5911 (ER5911 EEPROM) provenance

From <https://github.com/jotego/jteeprom> at commit `9c68ce841f4ec560ca6f228c8af6301129fd95fa`,
the commit jtcores `f64dbe2fd` pins as its `modules/jteeprom` submodule. **Verbatim.**
GPL-3.0-or-later (header). `.gitattributes` marks this directory `-text`.

| file | |
|---|---|
| `jt5911.sv` | the EEPROM; `PROG=0` is the 128x8 organisation, MAME's `EEPROM_ER5911_8BIT` |
| `jt5911.st` | upstream's state-machine description; not compiled |

The local jtcores checkout has an older `jt5911.sv` from a different submodule commit; this is the
pinned one. Upstream's `ver/top` bench tests `jt9346`, not `jt5911`, so there is no upstream test.
