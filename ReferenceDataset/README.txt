Optional local reference data

No real images are distributed in this project. Quick Test uses TestDataset.
Full Benchmark needs a prepared reference.json catalog and the referenced files.
Prepare-InfrastructureHealthReferenceDataset.ps1 accepts these capture folders:
  single-images  (individual payload files)
  z-stack        (depth sequence payload files)
  xy-mosaic      (DZI descriptor plus pyramid tiles)
  volume         (at least three xy-mosaic* subfolders; benchmark samples three)
Profiles: Auto, All, SingleField (single-images and z-stack only).
Legacy capture names and catalog IDs are recognized at the input boundary.
Preparation normalizes names, but does NOT anonymize file contents or pixels.
Use only authorized, non-sensitive test data. Do not commit data or manifests.
The public package includes only this README and the example DZI descriptor.
