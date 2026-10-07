# Infrastructure Health & Benchmark

Version **0.1.8**. Suggested repository: `infrastructure-health-benchmark`.

IIS, SQL, storage, and network diagnostics with synthetic DZI benchmarks and an
OpenSeadragon viewer. This independent project is intended for infrastructure
troubleshooting, not clinical diagnosis or DICOM conformance certification.

## What works without reference images

Quick Test fetches a 1 MiB HTTP sample and four synthetic DZI tiles. The included
`TestDataset` contains synthetic PNG tiles, not captured confocal images.
The scheduled Windows worker collects IIS, storage, and ODBC diagnostics.
Full Benchmark requires a prepared local reference dataset. Without one its
button is disabled. Missing OpenSeadragon prevents viewer-based DZI navigation;
raw synthetic tile retrieval does not require the viewer library.

## Workload terminology

| ID | Meaning | Existing implementation |
|---|---|---|
| single-images | Individual images | File-sequence retrieval |
| xy-mosaic | XY image mosaic | DZI zoom/pan/jump navigation |
| z-stack | Depth sequence | File-sequence retrieval |
| volume | Multiple image planes | Navigation through three sampled DZI planes |

The volume benchmark is not a 3D renderer or a complete volume validation.
File-sequence payloads are transferred as generic binary files, not decoded as
DICOM objects. The names describe intended workloads, not verified acquisition
geometry. Renaming a catalog does not convert its storage format.

DICOM Supplement 226 provides terminology for confocal microscopy, including
mosaics, z-stacks, and tiled pyramidal images. DZI (Deep Zoom Image) is a separate
XML/tile format. This tool does not implement the DICOM IODs simply by using
similar terminology. Neither DICOM nor OpenSeadragon is part of the project name.

- [DICOM Supplement 226 final text](https://dicom.nema.org/medical/dicom/final/sup226_ft_cutaneous_confocal_microscopy.pdf)
- [DICOM Confocal Microscopy Tiled Pyramidal Image IOD](https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_A.90.2.html)
- [OpenSeadragon DZI format documentation](https://openseadragon.github.io/examples/tilesource-dzi/)

## Windows installation

Requires an existing IIS site/application, an `images` virtual directory pointing
to test storage, and elevated **Windows PowerShell 5.1 (64-bit)**. PowerShell 7
can run the offline checks but is not the supported IIS installation host.
The installer does not create the base application, SQL Server or ODBC DSNs.

```powershell
.\Install-InfrastructureHealth.ps1 -SiteName 'Default Web Site' `
    -ApplicationPath '/App' -ImagesVirtualDirectory 'images'
```

Default installation: `%ProgramData%\InfrastructureHealthBenchmark`.
Dashboard: `/App/health/`. Benchmark files: `images/__Infrastructure_Health__/`.
Scheduled task: `Infrastructure Health & Benchmark Diagnostics` (SYSTEM on a new
installation). Configure an appropriate task identity and storage/SQL permissions
for your environment. Generic upgrades preserve an existing task's identity.

The installer writes benchmark files, deploys the dashboard and creates a task.
**Running it on Azure VMs can incur VM, storage, transaction and transfer costs.**
Offline validation and packaging below do not contact Azure.

The dashboard and its JSON can reveal internal hostnames, paths and SQL metadata.
Restrict access using your site's authentication and network controls. It does
not implement Keycloak/MFA itself and must not be exposed anonymously to the
public Internet. Tests consume bandwidth and storage I/O; use test environments.

## Local diagnostics configuration

Edit the installed `config/health.ini`, not the public template. Keep any private
source-side settings under `.local/` (ignored by Git and excluded from releases).

```ini
[Diagnostics]
DsnName=HealthCheck
ImagePathRegistryKey=
ImagePathRegistryValue=image_path
SqlProbeQueryFile=
```

Create the required 32-bit and/or 64-bit System DSNs separately. SQL probes use
Windows integrated authentication as the worker identity. The default query
returns SQL server/database names and a NULL image path; it has no dependency on
an application database table. Optional `SqlProbeQueryFile` points to a trusted,
local, reviewed read-only query returning exactly these three columns in order:
server name, database name, image path. Relative paths resolve beside the INI.
Do not store credentials in that query. Registry lookup is optional and requires
an explicitly configured key. Unconfigured sources and path comparisons remain
unavailable/warning; they do not count as a successful consistency check.
The threshold and sample-size settings remain configurable in the INI.

## Optional reference data

Use authorized test data. Real reference data is never required for Quick Test.
File-sequence preparation selects up to 256 files of at least 64 KiB each.
Prepare a source directory with `single-images`, `z-stack`, `xy-mosaic`, and/or
`volume` subfolders, as described in `ReferenceDataset/README.txt`.

```powershell
.\Prepare-InfrastructureHealthReferenceDataset.ps1 `
    -SourceCasePath 'D:\LocalTestCapture' -Profile Auto
.\Import-InfrastructureHealthReferenceDataset.ps1 `
    -SourcePath '.\ReferenceDataset' -ApplicationPath '/App'
```

Preparation copies file contents. Renaming files or removing source folder names
is **not anonymization**. Do not use identifiable patient data. No images,
`reference.json`, or `files.sha256` from local datasets belong in GitHub Releases.
The installer can still import a locally supplied ReferenceDataset automatically;
the public package builder explicitly excludes it.

Legacy 0.1.7 catalog IDs `vivablock`, `vivastack`, and `vivacube` are mapped to the
new IDs in memory. Payload paths are retained, so old local datasets need not be
renamed. Legacy capture folder patterns are recognized by the preparation tool.
These compatibility strings are input identifiers, not public product branding.

## Upgrade from the previous project name

This is a fresh generic installation namespace, not an automatic in-place upgrade
of 0.1.7. It uses new task, installation and benchmark directory names. Do not
point it at an existing old dashboard with `-Force` to bypass the ownership guard.
Back up local configuration and reference data, retire the old installation with
its own uninstaller while retaining its dataset, then install the generic edition
and import the retained reference dataset. Old and new workers must not write the
same dashboard concurrently. No existing configuration/data is silently renamed.
For later generic upgrades use `Update-InfrastructureHealthInstallation.ps1`.

## OpenSeadragon and dependencies

OpenSeadragon **6.1.0** is pinned with the inherited release ZIP SHA-256 in the
vendor preparation script. It is a viewer dependency, not a dataset format.
The source package contains its license/metadata and a runtime placeholder.

```powershell
.\Prepare-InfrastructureHealthVendor.ps1
```

This downloads the pinned upstream runtime; it does not deploy Azure resources.
The installer also attempts the pinned download when needed. For offline IIS
installation, prepare the runtime first. Verify the vendor license and hash;
see `Web/vendor/openseadragon/6.1.0/`. No upstream runtime is silently upgraded.

## Offline validation and public packaging

Requires Python 3.11+ and Node.js for behavior tests; PowerShell for parser checks.

```powershell
py -3.11 Scripts/check_public.py
node Tests/test_workloads.cjs
.\Tests\Test-Project.ps1
.\Tests\Test-ReferenceDataset.ps1
py -3.11 -m unittest discover -s Tests -p "test_*.py"
py -3.11 Scripts/build_release.py
```

The builder reads an explicit `public-files.txt` allowlist, verifies the pinned
synthetic dataset, and creates a versioned ZIP and SHA256SUMS under `dist/`.
It excludes reference payloads even when present locally. An optional prepared
OpenSeadragon runtime is not included in this source package; the installer or
vendor preparation script obtains it separately. Review allowed source files for
private values before publication; automated checks cannot prove their absence.
GitHub publication and the CloudLab release-download integration are separate
steps. No repository, release, or Azure resource is created by these commands.

## Validation status

Offline checks exercise JavaScript catalog compatibility, PowerShell parsing,
configuration helpers, generic workload IDs and release exclusions. Windows IIS,
32/64-bit ODBC, scheduled tasks and real browser performance require a Windows
smoke test. This version has not been deployed to Azure.
Some newly generalized UI descriptions use English fallback in other locales.

## Third-party names and licensing

Third-party names in compatibility code identify supported input formats only.
All trademarks and product designations belong to their respective owners.
This is not an official product of any imaging-system manufacturer.
The original project code and documentation are licensed under the
[MIT License](LICENSE), copyright (c) 2026 DanielP-1337.

OpenSeadragon remains licensed under **BSD-3-Clause**. The project MIT license
does not replace or relicense third-party components. Retain OpenSeadragon's
copyright notices, license conditions and disclaimer when redistributing its
source or binaries. Do not imply endorsement by its copyright holders or
contributors. The upstream notice is included in
[Web/vendor/openseadragon/6.1.0/LICENSE.txt](Web/vendor/openseadragon/6.1.0/LICENSE.txt)
and is deployed with the dashboard.

Optional local reference datasets are not distributed by this project and are
not covered by this project's MIT license. Obtain any necessary rights for
those datasets separately.

## Repository line endings

All text files, including PowerShell scripts, use **LF** in Git and in checkouts.
`.gitattributes` makes this independent of `core.autocrlf`; `.editorconfig` applies
the same convention in supporting editors. PNG files remain binary. In particular,
`TestDataset/benchmark.dzi` retains stable bytes for the synthetic dataset hash
check. After applying these rules to an existing checkout, stage normalization
with `git add --renormalize .`. This updates the index; it does not immediately
rewrite every working-tree file.
