# Third-Party Notices

This file records third-party material used by NEXUS-32 and the applicable
license terms. Third-party licenses remain in force for the material they
cover; the repository MIT License does not replace them.

## PicoRV32

- **Project:** PicoRV32
- **Upstream:** https://github.com/YosysHQ/picorv32
- **Pinned revision:** `ef203c2b0a3fb793280f5114941416c425c5b461`
- **Distribution model:** PicoRV32 is not distributed in this repository's
  Git history. The `/vendor/picorv32/` directory is ignored by Git and is
  created locally by `scripts/vendor_picorv32.sh` during provisioning. A
  provisioned checkout contains `picorv32.v`, `COPYING`, and `REVISION.txt`.
- **License:** ISC License
- **License text after provisioning:** `vendor/picorv32/COPYING`

The exact license notice required for the provisioned PicoRV32 source is:

```text
ISC License

Copyright (C) 2015 - 2021  Claire Xenia Wolf <claire@yosyshq.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

The notice above was verified against the locally provisioned
`vendor/picorv32/COPYING` and the `COPYING` file at the pinned upstream
revision. The provisioning script records the upstream URL and pinned commit
in `vendor/picorv32/REVISION.txt`.

## Digilent Basys 3 constraints

`constraints/basys3.xdc` contains the clock, center-button, and four LED pin
assignments for the Basys 3 rev-B board. The assignments match the
corresponding entries in Digilent's `Basys-3-Master.xdc` from the
`Digilent/digilent-xdc` repository. The project file is a reduced, adapted
constraint file: it renames ports for this project, converts the selected
assignments into active Tcl commands, adds the project clock declaration, and
omits the unused board interfaces.

The upstream `digilent-xdc` repository identifies its material as MIT-licensed
and provides this notice in `License.txt`:

```text
MIT License

Copyright (c) 2017 Digilent

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

The repository history shows `constraints/basys3.xdc` was added as a new file
by the project author, but that history does not establish independent
authorship of the pin assignments. Accordingly, this notice records the file
as adapted from Digilent's master constraints rather than as independently
authored or as a verbatim copy.

## Repository scope

Except for third-party components identified in this file and any files
carrying their own notices, project-authored NEXUS-32 material is offered
under the repository's MIT License. This statement does not relicense
third-party material or make an authorship determination for files whose
provenance is not established by the repository evidence.
