# Third-party notices

Revine is an independent tweak. It is not affiliated with, endorsed by or associated with Vine, Twitter/X or diVine.
It does not contain the Vine app; users install Vine 2.5.1 themselves. The content shown comes from diVine's public
API (https://api.divine.video) and media server.

## Shipped with the tweak

- **Mbed TLS** - Apache License 2.0. The TLS 1.2 client for every HTTPS request (iOS 6's own stack cannot talk to
  diVine's servers). https://github.com/Mbed-TLS/mbedtls
- **Mozilla CA certificate bundle** (curl.se/ca) - MPL-2.0. The roots TLS connections are checked against.

## Build only

- **Theos** - the build system; not shipped.

## References

- The shape of Vine 2.5.1's API answers follows recordings published with **vinepy** (MIT,
  https://github.com/davoclavo/vinepy) and the community's API notes of 2013-2015.

The license texts of the shipped libraries are installed in `/Library/Application Support/Revine/licenses`.
