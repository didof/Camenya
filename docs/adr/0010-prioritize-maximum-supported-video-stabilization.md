# Prioritize maximum supported video stabilization

Camenya automatically selects a stabilization-capable 1080p/30 capture format and requests the strongest recorded-output stabilization mode supported by the active camera, preferring face-aware Cinematic Extended Enhanced when available and falling back through less intensive modes. This deliberately accepts moderate crop, latency, and memory cost because stable portrait talking-head footage is more important to Camenya than maximum field of view, while capability checks and fallback preserve predictable recording on older devices.
