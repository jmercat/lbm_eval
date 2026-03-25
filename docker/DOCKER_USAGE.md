# Docker Usage Guide

This guide covers building and running the `lbm-eval-oss` Docker image,
including how to record evaluation videos.

## Prerequisites

- Docker with NVIDIA Container Toolkit (`nvidia-docker`)
- An NVIDIA GPU with EGL support

## Building the image

```sh
./docker/build.sh              # builds lbm-eval-oss:latest
./docker/build.sh my-tag       # builds lbm-eval-oss:my-tag
```

## Quick start with the sample policy

Run the wave-around sample policy and the evaluation inside the same
container:

```sh
docker run --rm --network host \
  --runtime=nvidia --gpus all \
  --device /dev/dri \
  --group-add video \
  --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -v "$(pwd)/output:/output" \
  --user "$(id -u):$(id -g)" \
  lbm-eval-oss:latest \
  bash -c '
    wave_around_policy_server &
    sleep 2
    evaluate \
      --skill_type=pick_and_place_box \
      --num_evaluations=1 \
      --num_processes=1 \
      --output_directory=/output
  '
```

Results are written to `./output/`.

## Running with an external policy server

The typical setup is two processes: the Docker container runs the
simulation (`evaluate`) and connects via gRPC to an external policy
server running on the host.

### 1. Start the simulation container

```sh
docker run --rm -d --network host \
  --runtime=nvidia --gpus all \
  --device /dev/dri \
  --group-add video \
  --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e SKIP_BUILD=1 \
  -v "$(pwd)/rollouts:/tmp/lbm/rollouts" \
  --user "$(id -u):$(id -g)" \
  lbm-eval-oss:latest \
  bash /opt/anzu/launch_sim.sh PickAndPlaceBox
```

### 2. Start your policy server on the host

Your policy server should listen on `localhost:50051` (the default gRPC
address).

## Using `launch_sim.sh`

The `launch_sim.sh` script inside the container converts a PascalCase
task name to the snake_case skill type expected by `evaluate` and
handles retry logic, S3 uploads, and video recording.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LAUNCH_TASK_NAME` | `BimanualPutRedBellPepperInBin` | Task in PascalCase (or pass as first argument) |
| `LAUNCH_DEMONSTRATION_INDICES` | `100:200` | Episode range as `start:end` |
| `LAUNCH_SAVE_DIR` | `/tmp/lbm/rollouts/` | Output directory inside the container |
| `NUM_PROCESSES` | `1` | Number of parallel evaluation processes |
| `RECORD_VIDEO` | `0` | Set to `1` to save MP4 videos |
| `VIDEO_CAMERA` | _(empty)_ | Comma-separated camera list (see below) |
| `VIDEO_FPS` | `10` | Video frame rate |

## Recording videos

Add `--record_video` to the `evaluate` command, or set `RECORD_VIDEO=1`
when using `launch_sim.sh`.

### Video modes

| Mode | `--video_camera` / `VIDEO_CAMERA` | Output files |
|------|-----------------------------------|--------------|
| Mosaic (default) | _(omitted)_ | `video_mosaic.mp4` |
| Single camera | `scene_left_0` | `video_scene_left_0.mp4` |
| Multiple cameras | `scene_left_0,scene_right_0` | `video_scene_left_0.mp4`, `video_scene_right_0.mp4` |
| All cameras + mosaic | `all,mosaic` | `video_<name>.mp4` for each camera + `video_mosaic.mp4` |

### Available cameras

Camera names are task-dependent. Typical names for the dual-panda setup:

- `scene_left_0` -- left scene camera
- `scene_right_0` -- right scene camera
- `wrist_left_minus` -- left arm wrist camera (minus side)
- `wrist_left_plus` -- left arm wrist camera (plus side)
- `wrist_right_minus` -- right arm wrist camera (minus side)
- `wrist_right_plus` -- right arm wrist camera (plus side)

### Special values

- `mosaic` -- produces a grid of all cameras tiled into one video
- `all` -- expands to every individual camera

### Examples

#### CLI (`evaluate`)

```sh
# Mosaic only:
evaluate ... --record_video

# Two scene cameras:
evaluate ... --record_video \
  --video_camera scene_left_0 \
  --video_camera scene_right_0

# Everything:
evaluate ... --record_video \
  --video_camera all \
  --video_camera mosaic
```

#### Docker with `launch_sim.sh`

```sh
# Mosaic video:
docker run --rm -d --network host \
  --runtime=nvidia --gpus all \
  --device /dev/dri \
  --group-add video \
  --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e RECORD_VIDEO=1 \
  -v "$(pwd)/rollouts:/tmp/lbm/rollouts" \
  --user "$(id -u):$(id -g)" \
  lbm-eval-oss:latest \
  bash /opt/anzu/launch_sim.sh PickAndPlaceBox

# All individual cameras + mosaic:
docker run --rm -d --network host \
  --runtime=nvidia --gpus all \
  --device /dev/dri \
  --group-add video \
  --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e RECORD_VIDEO=1 \
  -e VIDEO_CAMERA=all,mosaic \
  -v "$(pwd)/rollouts:/tmp/lbm/rollouts" \
  --user "$(id -u):$(id -g)" \
  lbm-eval-oss:latest \
  bash /opt/anzu/launch_sim.sh PickAndPlaceBox
```

### Output location

Videos are saved alongside demonstration artifacts:

```
<output_dir>/<skill_type>/demonstration_<index>/video_mosaic.mp4
<output_dir>/<skill_type>/demonstration_<index>/video_scene_left_0.mp4
...
```

When using `launch_sim.sh` without overriding `LAUNCH_SAVE_DIR`, the
default output directory inside the container is `/tmp/lbm/rollouts/`.
Mount a host volume there to retrieve the files:

```sh
-v "$(pwd)/rollouts:/tmp/lbm/rollouts"
```

## Full example: sim container + external policy with video recording

This is a complete working example that runs the simulation in Docker
while the policy inference runs on the host. It records every individual
camera plus a mosaic, and writes videos to `./rollouts/` on the host.

```sh
#!/usr/bin/env bash
set -e -o pipefail

SIM_CID=""
cleanup() {
  set +e
  [[ -n "${SIM_CID}" ]] && docker stop "${SIM_CID}" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# 1. Start the sim container (detached).
SIM_CID="$(docker run --rm -d --network host \
      --runtime=nvidia \
      --gpus all \
      --device /dev/dri \
      --group-add video \
      --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
      -e NVIDIA_DRIVER_CAPABILITIES=all \
      -e SKIP_BUILD=1 \
      -e RECORD_VIDEO=1 \
      -e VIDEO_CAMERA=all,mosaic \
      -v "$(pwd)/rollouts:/tmp/lbm/rollouts" \
      --user "$(id -u):$(id -g)" \
      lbm-eval-oss:latest \
      bash /opt/anzu/launch_sim.sh BimanualPutRedBellPepperInBin)"

# 2. Run your policy server on the host (listening on localhost:50051).
#    Replace this with your own inference command.
python my_policy_server.py --checkpoint experiments/my_model
```

After the run completes, videos appear in:

```
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_mosaic.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_scene_left_0.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_scene_right_0.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_wrist_left_minus.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_wrist_left_plus.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_wrist_right_minus.mp4
rollouts/bimanual_put_red_bell_pepper_in_bin/demonstration_100/video_wrist_right_plus.mp4
...
```

## GPU memory considerations

Each evaluation process consumes GPU memory for Drake's rendering
pipeline. With video recording enabled, frame data is buffered in CPU
memory (not GPU). However, avoid setting `NUM_PROCESSES` too high --
the same GPU memory constraints from the main README apply. If you see
`Unable to eglMakeCurrent: 12291`, reduce `NUM_PROCESSES`.

## Notes and troubleshooting

### Drake robot models are pre-cached

Drake robot models are pre-cached during the Docker image build. There is
no large download on first container start (previously this could take
5-10 minutes).

### File permissions on mounted volumes

The image is built with a UID/GID that matches the build host (set
automatically by `build.sh`). If the files written to a mounted volume
are owned by a different user, pass `--user "$(id -u):$(id -g)"` to
`docker run` so the container process runs as your host user:

```sh
docker run ... --user "$(id -u):$(id -g)" lbm-eval-oss:latest ...
```

The container entrypoint handles output-directory permissions on a
best-effort basis, but explicit `--user` matching is the most reliable
approach.
