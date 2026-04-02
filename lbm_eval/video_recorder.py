"""Video recorder for sim evaluations.

Captures RGB camera frames from each evaluation step and writes them to
MP4 files.  Multiple videos can be produced in a single evaluation run.

Requirements
------------
pip install imageio imageio-ffmpeg

Usage
-----
The recorder plugs into the existing ``evaluate`` CLI via the
``--record_video`` flag::

    # Mosaic of all cameras (default when --record_video is used alone):
    evaluate ... --record_video

    # Single camera only:
    evaluate ... --record_video --video_camera scene_left_0

    # Multiple cameras:
    evaluate ... --record_video --video_camera scene_left_0 --video_camera scene_right_0

    # Multiple cameras AND a mosaic:
    evaluate ... --record_video --video_camera scene_left_0 --video_camera mosaic

    # All individual cameras plus mosaic:
    evaluate ... --record_video --video_camera all --video_camera mosaic

The special name ``mosaic`` produces a grid of all cameras.
The special name ``all`` expands to every individual camera.

Videos are saved as::

    output/<skill_type>/demonstration_<index>/video_<camera_name>.mp4
    output/<skill_type>/demonstration_<index>/video_mosaic.mp4
"""

import math
from pathlib import Path

import imageio
import numpy as np

from anzu.intuitive.visuomotor.bases import NoopRecorder


class VideoRecorder(NoopRecorder):
    """Records evaluation camera frames to MP4 video files.

    Parameters
    ----------
    output_dir:
        Directory where videos will be written.
    cameras:
        List of camera names to record.  Use ``"mosaic"`` for a grid of
        all cameras and ``"all"`` to expand to every individual camera.
        If empty or None, defaults to ``["mosaic"]``.
    fps:
        Frames-per-second of the output videos.
    """

    def __init__(
        self,
        output_dir: str | Path,
        cameras: list[str] | None = None,
        fps: int = 10,
    ):
        self._output_dir = Path(output_dir)
        self._requested_cameras = cameras or ["mosaic"]
        self._fps = fps
        # Resolved on first frame when we know the actual camera names.
        self._resolved = False
        self._targets: list[str] = []  # "mosaic" or actual camera names
        self._frames: dict[str, list[np.ndarray]] = {}

    # -- Recorder interface ---------------------------------------------------

    def record_initial(self, time_step):
        if not self._resolved:
            self._resolve(time_step)
        self._append_frame(time_step)

    def record_step(self, time_step_prev, act, time_step):
        self._append_frame(time_step)

    def stop_recording(self):
        pass

    def save_recording(self, final_info):
        if not self._frames:
            return
        self._output_dir.mkdir(parents=True, exist_ok=True)
        for target, frames in self._frames.items():
            if not frames:
                continue
            video_path = self._output_dir / f"video_{target}.mp4"
            imageio.mimwrite(str(video_path), frames, fps=self._fps)
            print(f"Video saved to {video_path}")
        self._frames = {t: [] for t in self._targets}

    def abort_recording(self):
        self._frames = {t: [] for t in self._targets}

    # -- internal -------------------------------------------------------------

    def _resolve(self, time_step):
        available = list(time_step.obs.visuo.keys())
        print(f"VideoRecorder: available cameras: {available}")

        self._targets = []
        for cam in self._requested_cameras:
            if cam == "all":
                self._targets.extend(available)
            elif cam == "mosaic":
                self._targets.append("mosaic")
            elif cam in available:
                self._targets.append(cam)
            else:
                raise ValueError(
                    f"Camera '{cam}' not found. "
                    f"Available: {available + ['mosaic', 'all']}"
                )
        # Deduplicate while preserving order.
        seen = set()
        deduped = []
        for t in self._targets:
            if t not in seen:
                seen.add(t)
                deduped.append(t)
        self._targets = deduped

        self._frames = {t: [] for t in self._targets}
        self._resolved = True
        print(f"VideoRecorder: will produce videos for: {self._targets}")

    def _append_frame(self, time_step):
        visuo = time_step.obs.visuo
        for target in self._targets:
            if target == "mosaic":
                self._frames[target].append(_make_mosaic(visuo))
            else:
                self._frames[target].append(visuo[target].rgb.array)


def _make_mosaic(visuo: dict) -> np.ndarray:
    """Arrange all camera RGB images into a roughly-square grid.

    Images are resized to the dimensions of the first camera so that the
    mosaic is uniform even when cameras have different resolutions.
    """
    images = [img_set.rgb.array for img_set in visuo.values()]
    if len(images) == 1:
        return images[0]

    # Use the first image's dimensions as the target size.
    target_h, target_w = images[0].shape[:2]
    resized = []
    for img in images:
        if img.shape[0] != target_h or img.shape[1] != target_w:
            # Simple nearest-neighbour resize without extra dependencies.
            row_idx = (np.arange(target_h) * img.shape[0] / target_h).astype(
                int
            )
            col_idx = (np.arange(target_w) * img.shape[1] / target_w).astype(
                int
            )
            img = img[np.ix_(row_idx, col_idx)]
        resized.append(img)

    n = len(resized)
    cols = math.ceil(math.sqrt(n))
    rows = math.ceil(n / cols)

    # Pad with black frames so we fill the grid.
    black = np.zeros_like(resized[0])
    while len(resized) < rows * cols:
        resized.append(black)

    grid_rows = []
    for r in range(rows):
        grid_rows.append(
            np.concatenate(resized[r * cols : (r + 1) * cols], axis=1)
        )
    return np.concatenate(grid_rows, axis=0)
