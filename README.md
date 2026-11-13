# TwoLineTime

Two-line clock in the iOS status bar: the time on top, the date below.

- Pick a preset format for each line, or type your own ([nsdateformatter.com](https://nsdateformatter.com)). Line 1 can also stay as iOS draws it; Line 2 can be hidden.
- Seconds that tick, and an optional blinking colon.
- Font size, bold and italic per line, plus a vertical offset.
- Always hides the location indicator, and optionally the Focus icon (Do Not Disturb, Sleep, Work…). The Control Center header keeps it.
- Made for Face ID iPhones, including the Dynamic Island. Does NOT work on Touch ID devices.

## Build

<details>
<summary>Build instructions</summary>

Build the package with roothide's fork of Theos.

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

</details>

## License

TwoLineTime is licensed under the GNU General Public License, version 3 only. See [LICENSE](LICENSE).
