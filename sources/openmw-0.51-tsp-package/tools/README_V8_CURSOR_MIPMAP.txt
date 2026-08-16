OpenMW 0.51 TSP v8 - software cursor + POT-safe mipmaps
=======================================================

Install:
  /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51

Then run once:
  /mnt/SDCARD/data/ports/openmw51/tools/apply-runtime-profile-v8.sh

Cursor:
  SDL hardware cursor = disabled
  MyGUI framebuffer cursor = enabled
  No extra cursor image should be required.

Texture experiment:
  LIBGL_MIPMAP=2
  LIBGL_FORCENPOT=0
  LIBGL_NOTEST=1

  POT Texture2D  -> mipmap filtering allowed
  NPOT Texture2D -> base filtering only

settings.cfg:
  texture mag filter = linear
  texture min filter = linear
  texture mipmap = nearest
  anisotropy = 1

Test:
  - lily pads
  - known wobbling boulder
  - distant water while stationary
  - distant water while moving
  - small bog ponds at increasing distance
  - menu pointer movement/clicks
  - resize pointer shapes
  - inventory drag/drop

Preserved:
  direct framebuffer v2
  NiLOD v4
  v7 dense water
  v7 memory trim
  Project Atlas/MOP
  near clip 15
