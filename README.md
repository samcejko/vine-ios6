# Revine

A tweak for jailbroken iOS 6 that brings the original **Vine** app (version 2.5.1) back to life with the content of
[diVine](https://divine.video), the Vine reboot: the archive of classic Vines and new six-second loops.

Vine's servers are gone, so the app starts but shows nothing. Revine answers every request the app makes to its old
servers (`api.vineapp.com`, `config.vineapp.com`, `media.vineapp.com`, `vine.co`) with diVine's content, translated to
the JSON Vine 2.5.1 expects. Nothing in the app is patched: the tweak is an `NSURLProtocol` inside the app.

## What works

- Signing in: any e-mail and password (or Sign up) signs you in as a guest. No account is needed or created.
- Home feed: classic Vines. Popular: what is trending on diVine now.
- Profiles, a user's posts, followers and following, comments, likes and revines lists.
- Hashtags, user and tag search, channels (Classic Vines, New on diVine and diVine's categories), the Explore page.
- Loop counts, likes and comments of the archived Vines as they were.

Liking, commenting, following, revining and posting are refused with a message: they need a diVine account (Nostr
keys), which Vine cannot sign in to yet.

## Installing

1. Install Vine 2.5.1 yourself (a decrypted IPA with AppSync / ipainstaller). Revine does not contain or download Vine.
2. Install the Revine package from the repository http://repo.samcejko.eu/ (or the `.deb` from the releases).
3. Open Vine. No respring needed.

## How it works

- `src/RVURLProtocol.m` takes the app's requests to Vine's hosts and to diVine's media server.
- `src/RVVineAPI.m` maps Vine's endpoints (`timelines/graph`, `timelines/popular`, `users/profiles/<id>`,
  `posts/<id>/comments`, `channels/featured`...) to diVine's public REST API (`https://api.divine.video`).
- `src/RVIDMap.m` turns diVine's 64-character ids into the 64-bit numbers Vine works with, and back.
- `src/Net/` is the TLS 1.2 stack (Mbed TLS) shared with the author's other iOS 6 apps: diVine's servers only accept
  current ciphers, which iOS 6 does not have.

## Building

CI builds the package with Theos (iOS 9.3 SDK, armv7, deployment target 6.0): see `.github/workflows/build.yml`.
Locally: `make package` with Theos and the vendored Mbed TLS (the workflow shows how it is fetched).

## Disclaimer

Revine is an independent project. It is not affiliated with, endorsed by or associated with Vine, Twitter/X or
diVine. Vine is a trademark of its owners. Revine only reads public content through diVine's public API.
