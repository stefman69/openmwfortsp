# TrimUI Smart Pro - OpenMW 0.51 port

When I saw that someone had made a portmaster port for Morrowind I was really excited to put it on my TSPS, but then I found out it likely would not work on the TSP or even if I did install Knulli OS to be able to run it that it would not run very well. Morrowind is my favorite game of all time though, so I thought there has to be a way to get this working. What I initially thought would be just a reworking of the SH launcher file for the game turned into a massive undertaking of retuning the source code for OpenMW and building a binary that actually ran well on this system. Currently this game is playable only on the TrimUI Smart Pro and TrimUI Smart Pro S running either stock OS or Crossmix, though it will likely work on other OS's when I have the time and money to buy new SD cards and patch for them (it may work already, but I can't garauntee that). Instructions for installing the game and a full list of all major changes to stock OpenMW 0.51 is listed below.

## Key fixes in this build

**Texture wobble (resolved).** `gl4es` `GetHardwareExtensions()` begins with
`if(tested) return;`. With `LIBGL_NOTEST=1` - which this device requires, since
probing at init blue-screens it - the flag was set without any detection
running, leaving every `hardext` capability at 0. A Mali-G57 was being driven
as the weakest possible GLES2 device: no depth24, no packed depth stencil, no
derivatives, no NPOT. `TSP_EXTFLAGS` in `src/glx/hardext.c` sets the flags from
the real extension string at first shader compile.

**Distant terrain (partial).** Composite-map FBOs were reporting
`GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT`. Fixed so far: renderable colour
format, depth attachment, read/draw target normalisation, `fbo_read` sync.
Complete framebuffers went 14 -> 440; roughly 25% of terrain renders. The
remainder is still under investigation.
