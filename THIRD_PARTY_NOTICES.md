# Third-party notices

The Gallery itself is MIT licensed (see `LICENSE`). It includes material from
the projects below, each under its own licence, reproduced here as those
licences require. Nothing here is copyleft.

PySide6 (LGPL-3.0) and Hammerspoon (MIT) are used at run time but are not
included in this repository; the `qml` kind installs PySide6 into its own
virtual environment on the user's machine. `qml/shim/` is an independent
reimplementation of part of Quickshell's QML API and contains no Quickshell
code.

## Omarchy

- Source: https://github.com/basecamp/omarchy, commit
  `b5589faaf80c6f87c07d4560fca37c4a81722f28`
- Used in: `themes/*/colors.toml` (theme colours), `qml/vendor/qs/` (QML
  components, one documented patch to `Commons/Color.qml`). See
  `themes/UPSTREAM.md` and `qml/vendor/UPSTREAM.md`.
- Licence: MIT

```
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Omarchy's wallpapers

The screenshots in `assets/screenshots/` show desktops on wallpapers that
ship with Omarchy's themes (for example tokyo-night's `1-quattro.webp`,
kanagawa's `1-kanagawa.jpg`, osaka-jade's `1-glowing-city.webp`). They are
the work of their respective artists, and Omarchy states no licence for them
beyond its MIT notice. The image files themselves are not in this
repository: the installer (through `tools/fetch-omarchy-backgrounds.sh`)
downloads them from Omarchy onto your machine.

## Radio Atlas

- Source: https://github.com/AksharP5/omarchy-radio-atlas
- Used in: `patches/akshar.radio-atlas/` (modified copies of the plugin's
  helper scripts, laid over the installed plugin on macOS; see
  `patches/akshar.radio-atlas/PATCH-NOTES.md`). The plugin itself is not
  included; `gallery add` fetches it from upstream.
- Licence: MIT

```
MIT License

Copyright (c) 2026 Akshar Patel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Meteocons

- Source: https://github.com/basmilius/weather-icons (also published as
  https://github.com/basmilius/meteocons)
- Used in: `plugins/gallery.weather/icons/meteocons-line/`,
  `plugins/gallery.weather/icons/meteocons-fill/`
- Licence: MIT

```
MIT License

Copyright (c) 2020-present Bas Milius

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
