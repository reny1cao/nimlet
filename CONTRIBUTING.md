# Contributing to Nimlet

Thanks for looking. Nimlet is maintained by one person outside working hours,
so this file is mostly about making a contribution cheap to review.

## Before you start

- **Bugs:** open an issue with the bug template. "Copy diagnostics" from the
  Mac menu bar answers most of the first round of questions.
- **Features and anything larger than a small fix:** open an issue first and
  describe the problem before writing the code. Nimlet deliberately does fewer
  things than it could. A short conversation up front is cheaper than a PR that
  can't be merged.
- **Security:** never in a public issue. See [SECURITY.md](SECURITY.md).

## Building

You need a Mac with Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and, for the relay, Node 22.

```bash
make test         # unit tests (macOS, no signing needed)
make host         # the Mac menu bar app, Debug
make remote       # the iPhone app for the Simulator
make tool         # the `nimlet` CLI
make relay-test   # the push relay and connect relay (Node)
```

CI runs all but the last ([.github/workflows/ci.yml](.github/workflows/ci.yml)).
Only `make host` signs anything, and by default it asks for the official
Developer ID certificate; set your own identity as below.

### Signing with your own team

The project is generated from `project.yml`, and the official team and bundle
identifiers are set in `Signing/Base.xcconfig`. To build for your own devices,
create `Signing/Local.xcconfig`. It is ignored by Git and overrides the base
file:

```
DEVELOPMENT_TEAM = ABCDE12345
NIMLET_BUNDLE_ID_PREFIX = com.example.nimlet
NIMLET_MAC_SIGN_IDENTITY = Apple Development
```

Then run `make project` again. A bundle prefix of your own is needed because
`com.renyicao.mice.*` is registered to the official team. The iPhone app and
its notification extension share a keychain group derived from these two
values. Push notifications also need your own APNs key and relay; see
[Relay/README.md](Relay/README.md).

`NIMLET_MAC_SIGN_IDENTITY` signs the Mac app. Official builds use Developer ID
because notarization requires it; to run on your own Mac, `Apple Development`
or `-` (sign to run locally) is enough. macOS ties the Accessibility grant to
the signature, and a `-` signature changes with every build, so with `-` expect
to grant Accessibility again after rebuilding.

### Names you will see

The project used to be called Mice. Targets, types and folders are named
Nimlet, but some identifiers that shipped builds depend on still say `mice`:
bundle identifiers, Bonjour service types, `mice.*` defaults keys, the keychain
group, the `MICE_*` build settings and the built product names (`Mice.app`,
`MiceRemote.app`). Changing any of them would orphan existing pairings, keys or
settings on users' devices, so leave them as they are unless your change
includes a migration.

## Making a change

- Keep a PR to one change. A refactor and a fix in the same PR are two PRs.
- Match the surrounding code: its naming, its comment density, and the habit
  of saying *why* in a comment when the why isn't obvious.
- Add or update tests in `Tests/NimletTests` for anything with logic in it.
  Wire-format and policy code (`Shared/`) is expected to be covered.
- **The wire protocol is shared by two apps that update independently.** If you
  change a message, bump `NimletProtocol.version`, say what changed in the
  comment above it, and keep decoding what older peers send
  (`Tests/NimletTests/LegacyDecodingTests.swift` shows the pattern).
- Anything that changes what leaves the device, what is stored, or who can
  connect needs a matching update to [PRIVACY.md](PRIVACY.md) or
  [SECURITY.md](SECURITY.md) in the same PR.
- Write commit messages as a sentence about the behaviour that changed
  ("Keep a hung front app from stalling the host's main thread"), not about the
  files that changed.

## License

Nimlet is licensed under the [Apache License 2.0](LICENSE). By submitting a
contribution you agree that it is licensed under the same terms, as described
in section 5 of the license. Please don't submit code you don't have the right
to license this way, including code copied from projects under incompatible
licenses.

The name "Nimlet" and its icon are not covered by the license; see
[Trademarks](README.md#trademarks).

## Conduct

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
