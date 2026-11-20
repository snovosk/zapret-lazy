# Third-party notices

zlazy is an independent, unofficial companion application for
zapret-discord-youtube. It is not affiliated with, endorsed by or maintained by
the authors of zapret-discord-youtube (Flowseal), zapret (bol-van), WinDivert
(basil00) or PS2EXE. The upstream projects retain their own copyrights and
licenses.

## What zlazy ships and what it does not

- The zlazy repository and release files (`zlazy.exe`, `zlazy-setup.exe`,
  `zlazy-<version>.zip`) contain zlazy's own code, the PS2EXE script and
  runtime host described below, documentation and graphics.
- They do **not** contain zapret, winws, WinDivert or any other upstream
  binary. On first start zlazy downloads the official
  zapret-discord-youtube release archive from GitHub (Flowseal). Its contents
  keep their upstream licenses and are not relicensed as part of zlazy.

## Flowseal/zapret-discord-youtube and bol-van/zapret

- https://github.com/Flowseal/zapret-discord-youtube
- https://github.com/bol-van/zapret
- MIT License. Copyright (c) 2016-2026 bol-van, Copyright (c) 2024-2026
  Flowseal. The full upstream notice is preserved in `licenses/Zapret-MIT.txt`.
- Parts of zlazy's PowerShell code re-implement behaviour and reuse data of the
  upstream scripts `service.bat` and `utils/test zapret.ps1`: winws argument
  parsing, the Game Filter and IPSet switching rules, the list of check targets
  and the reachability check method. These adapted portions are used under the
  MIT License above, whose notice is included with every zlazy distribution.
- At runtime zlazy reads `.service/version.txt` from the upstream repository,
  downloads the official release archive and, only when the IPSet mode needs a
  fresh list, `.service/ipset-service.txt`.

## WinDivert

- https://github.com/basil00/WinDivert
- Distributed by upstream under the user's choice of LGPLv3 or GPLv2.
- WinDivert is part of the upstream zapret release that zlazy downloads; zlazy
  does not ship, link to or modify it. Its license text is reproduced in
  `licenses/WinDivert-LICENSE.txt` for reference; source code is available from
  the upstream repository.

## PS2EXE

- https://github.com/MScholtes/PS2EXE
- PS2EXE-GUI v0.5.0.34, written by Ingo Karstein, reworked and GUI support by
  Markus Scholtes.
- Microsoft Limited Public License version 1.1, preserved in
  `licenses/PS2EXE-Ms-LPL-1.1.txt`.
- `build/tools/ps2exe.ps1` is included unmodified, with its original notices.
- `zlazy.exe` and `zlazy-setup.exe` are produced with PS2EXE and contain its
  compiled runtime host. That portion remains under the Ms-LPL 1.1, including
  its platform limitation: it may be used only on Microsoft Windows. It is not
  covered by zlazy's MIT License.

## Graphics

- The fox logo, icons, widget layout (`assets/`, `design/`) and screenshots
  were created for zlazy and are provided under zlazy's MIT License.
- Consolas and other system fonts are used from Windows and are not
  distributed.

## Project code

The original zlazy code is provided under the MIT License in `LICENSE`.
Third-party components remain under their respective licenses.
