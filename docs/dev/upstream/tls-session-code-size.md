# Draft: make TLS session serialization an optional dependency

This is a local proposal, not an upstream issue that has been submitted.

A small hmssql client that connects, queries one two-field record, and closes
pulls session serialization into a static executable although the application
does not serialize a TLS session. The measurement uses GHC 9.12.4, tls 2.4.6,
serialise 0.2.6.1, Linux x86-64, and the Stack snapshot in this repository.

The GNU link map shows `Network.TLS.Parameters` reaching
`Network.TLS.Session`, and the session object reaching a `Codec.Serialise.Class`
generic decoder. With dependencies compiled without split sections, the linked
code includes these package contributions:

| Package | Input `.text` bytes |
|---|---:|
| vector | 3,283,693 |
| cborg | 904,757 |
| unordered-containers | 547,952 |
| serialise | 406,493 |
| primitive | 292,356 |
| strict | 233,705 |
| hashable | 110,078 |
| these | 79,359 |
| Total | 5,858,393 |

This total is linked package code, not a demonstrated removable amount: some
packages are independently reachable from other libraries, and different build
flags change the result. In particular, hmssql itself uses primitive. The same
link includes 197,566 bytes of zlib and 613,465 bytes of random. Splitting
hmssql's own modules reduces random's reachable code to 438,659 bytes without
changing tls's serialization reachability.

Could the serialization instances live behind an optional build flag or in a
separate module/package that the normal TLS client does not import? This needs an
upstream compatibility plan: moving an existing instance changes which imports
make it available, and disabling it by default would break current users. A flag
whose default preserves the existing API would let size-sensitive consumers opt
out explicitly.

Reproduction: build hmssql, then run `scripts/link-size.sh OUTPUT-DIRECTORY`.
The script retains the executable, compiler log, and GNU link map, and
`scripts/link-map-size.py` reports each package's input text. It never runs the
linked application and requires no database credentials. Split dependency builds
should be reported separately from this unsplit dependency result.
