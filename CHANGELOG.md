# Changelog

## 0.1.8 - Generic project edition

- Rename the project to Infrastructure Health & Benchmark.
- Generic workload IDs: single-images, xy-mosaic, z-stack, volume.
- Read legacy catalog IDs at the viewer boundary without changing payload URLs.
- Accept generic capture folders and legacy capture folder names.
- Make IIS application path, ODBC DSN, optional registry lookup and optional SQL
  image-path query configurable. Default SQL query checks connectivity only.
- New generic installation directory, task name, benchmark directory and exports.
- Exclude private reference data and local settings from source/release packaging.
- Add offline validation, packaging checks, and synthetic dataset integrity checks.
- Correct Quick Test / Full Benchmark documentation.

This edition derives from 0.1.7. It is not an automatic migration of an existing
installation under the old product name. See README.md before installation.
