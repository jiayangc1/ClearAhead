# Sidewalk end and curve cues

## Goal

While assisting, tell a blind or low-vision walker when the sidewalk they are
on is about to end and when it bends, early enough to act on and rarely enough
to trust.

Success: on an ordinary sidewalk in daylight the app says "Path ends
ahead" two or three steps before the pavement stops, and "Path curves
left" or "Path curves right" before a bend. It stays silent mid-block.

## Spoken cues

| Situation | Speech |
|---|---|
| Walking surface stops within about 4 m | "Path ends ahead" |
| Path centre bends left | "Path curves left" |
| Path centre bends right | "Path curves right" |

- Voice only. No tone, no haptic, no overlay.
- Follows the existing voice toggle (`speechEnabled`).
- Collision and ground-hazard speech always wins. A path cue is skipped, not
  queued, while a hazard is being announced.
- The same cue repeats no sooner than 8 seconds later. After a cue, the
  condition must clear for 1.5 seconds before that cue can fire again.
- The word is "path", because the detector reacts to any walking surface
  that ends or bends (a sidewalk, a trail, a carpet edge).

## Detection

The app has no model that knows what a sidewalk is, so the path is read from
how the camera image looks, anchored at the walker's feet.

### 1. Grid

Reduce the camera frame (bi-planar YUV, already delivered to
`ClearAheadEngine.process`) to a portrait grid of 48 columns by 64 rows. Each
cell holds mean luma, mean Cb, mean Cr, and luma variance as a texture
measure. The pixel buffer is landscape and the image is shown rotated right;
the grid is built in the rotated, portrait frame so row 63 is at the feet.
Only the lower 60% of the image is analysed.

### 2. Seed

The seed is the bottom-centre patch: the middle third of the width, the
lowest eight analysed rows. Take the median and spread of each of the four
measures across the patch. If the spread is too wide the walker is standing
on mixed ground and the frame is rejected.

### 3. Region

A cell belongs to the path when each measure is within a tolerance of the
seed median, with the tolerance scaled by the seed's own spread and floored so
a perfectly uniform seed does not reject everything. Luma gets a looser
tolerance than chroma so shadows do not split the path. Keep only cells
connected to the seed (four-way flood fill).

### 4. Rows

For each row take the path run that overlaps the previous (nearer) row's run:
its left edge, right edge, and centre. Stop at the first row where the run is
narrower than three cells or missing.

### 5. Ending

The sidewalk is ending when all of these hold:

- The path stops at some row below the top of the analysed region.
- In the rows just above the stop, fewer than 25% of the cells across the
  last path width look like the seed.
- The depth map at the stop reads as ground that keeps receding, not a
  surface at one depth going up the image. A wall or parked car is the
  obstacle code's job.
- The depth at the stop row is between 0.8 m and 4 m, capped by the
  walker's warning distance. A phone held upright cannot see ground nearer
  than about 2.5 m, and the patch at the feet must still be on the path, so
  a shorter range would never fire for an upright phone.
- The path has not tapered away: its last row is at least half as wide as
  the row four rows nearer.

### 6. Curving

The sidewalk is curving when all of these hold:

- Only rows where both edges of the path are inside the image are used; a
  row cut off by the side of the image has no true centre.
- There are at least 14 such rows and they reach at least 2 m by the depth
  map.
- A straight line fitted to the centre of the nearest third of those rows,
  extended to the farthest row, misses the measured centre there by more than
  three quarters of the path's width at that row (and at least three cells).
- The drift is in one direction: at least 80% of the far half of the rows
  sit on the same side of the line.

Direction is the side the far centre lies on relative to the extended line.

### 7. Staying silent

No reading is produced when:

- image quality is not `good` (low light, covered camera),
- the camera is rotating faster than 0.9 rad/s (the same limit the ground
  hazard check uses),
- the seed is mixed,
- there is no depth map this frame.

### 8. Confirmation

A reading must repeat on consecutive depth frames for 0.5 seconds before it is
spoken. One missed frame is tolerated; two reset the count. For an ending, the
measured distance must not jump by more than 0.8 m between frames.

## Code

### New: `modules/react-native-clear-ahead-vision/ios/WalkablePath.swift`

- `struct PathShape`: `endDistanceMeters: Double?`, `bend: Direction?`.
- `enum WalkablePath` with
  `static func shape(pixelBuffer: CVPixelBuffer, depthMap: DepthMap, maximumDistance: Double) -> PathShape?`.
  Pure: same inputs, same answer. Returns nil when it must stay silent.
- `enum PathCue` (`ends`, `curvesLeft`, `curvesRight`) with a `text`.
- `struct PathCueTracker` with
  `mutating func update(_ shape: PathShape?, now: TimeInterval) -> PathCue?`,
  `mutating func spoke(_ cue: PathCue, now: TimeInterval)` and
  `mutating func reset()`. Owns confirmation, the 8-second repeat limit, and
  the 1.5-second clear. `update` keeps returning a confirmed cue until
  `spoke` is called, so a cue held back by hazard speech is not lost.

### Changed: `ClearAheadEngine.swift`

- Hold a `PathCueTracker`; reset it with the rest of the session state.
- In `process`, after hazard speech is chosen, compute the shape on frames
  that produced a depth map, when the camera is stable and image quality is
  good, and feed the tracker.
- When the tracker returns a cue and no hazard has been spoken in the last
  2.5 seconds, speak it and tell the tracker it was spoken.

### Changed: `Feedback/Feedback.swift`

- Add `speakPathCue`, like `speakWarning` but with an 8-second cooldown.

### Changed: `ClearAheadVision.podspec`

- List the new source file; the podspec names its sources one by one.

### Unchanged

React Native code, the Nitro spec, settings, `SpatialEvent`, and `EventKind`.

## Cost

One pass over a subsampled frame per depth frame: at most a few thousand
pixel reads and a 3,072-cell flood fill. Runs on the queue that already does
the depth work.

## Known limits

- Hard shadows, wet patches, painted markings and pavement the same colour as
  the road cause misses and some false cues.
- A sidewalk that ends at a curb down to a road of similar colour may only be
  caught by the existing ground checks.
- All thresholds above are estimates and need tuning from real walks.

## Verification

No tests are written or run. The change is checked by compiling the iOS
module, then by walking with it.
